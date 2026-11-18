# 01 - The Import Pipeline

## Overview

This file specifies CPython's import pipeline in enough detail to re-implement it
in Go. It covers the path from the `import` statement to a fully-initialised
module object, including every stage, the exact order of operations, and the
behaviours that a naive re-implementation gets wrong.

The reference implementation is split across two languages. The orchestration is
in Python (`Lib/importlib/_bootstrap.py`); the parts that need the C runtime are
in C (`Python/import.c`, `Python/importdl.c`). A Go implementation should follow
the same split in spirit: an orchestrator that is easy to read, and a small
native layer for the things Go cannot do natively.

Everything in this file was read from the CPython **v3.15.2** source.

## Sources

- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap.py` -
  the pure-Python import orchestrator (1553 lines).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap_external.py` -
  the path finders and file loaders (58,607 bytes).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/import.c` -
  the C-level import machinery (173,821 bytes).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/importdl.c` -
  the dynamic extension loader.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/internal/pycore_import.h` -
  the internal import structures.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/xxmodule.c` and
  `Modules/xxsubtype.c` - the reference C extension modules.

All line numbers below refer to the files as fetched from the `v3.15.2` tag.

## Spec

### The two entry points

CPython has two public ways to import, and they differ in a way that matters.

**`importlib.import_module(name, package=None)`** - returns the module named
`name` itself. `import_module('a.b')` returns `sys.modules['a.b']`.

**`__import__(name, globals=None, locals=None, fromlist=(), level=0)`** - returns
the **top-level** package when `fromlist` is empty, and the named module
otherwise. This is the function the `import` statement calls.

Both converge on `_gcd_import`, which is described in the CPython source as "the
greatest common denominator of functionality between import_module and
__import__".

```python
def _gcd_import(name, package=None, level=0):
    _sanity_check(name, package, level)
    if level > 0:
        name = _resolve_name(name, package, level)
    return _find_and_load(name, _gcd_import)
```

(`_bootstrap.py:1377`)

### The full pipeline

```
import statement
  └─ IMPORT_NAME opcode
       └─ builtins.__import__(name, globals, locals, fromlist, level)
            └─ _gcd_import(name, package, level)
                 ├─ _sanity_check(name, package, level)
                 ├─ _resolve_name(name, package, level)      [only if level > 0]
                 └─ _find_and_load(name, _gcd_import)
                      ├─ _resolve_parents(name, import_)       [3.15: lock ordering]
                      ├─ _get_module_lock(name).acquire()
                      └─ _find_and_load_unlocked(name, import_)
                           ├─ import parent package (if any)
                           ├─ _find_spec(name, path)
                           │    └─ for finder in sys.meta_path:
                           │         spec = finder.find_spec(name, path, target)
                           │         if spec is not None: break
                           ├─ _load_unlocked(spec)
                           │    ├─ module = module_from_spec(spec)
                           │    ├─ sys.modules[spec.name] = module
                           │    ├─ spec.loader.exec_module(module)
                           │    ├─ module = sys.modules.pop(spec.name)
                           │    └─ sys.modules[spec.name] = module
                           ├─ setattr(parent_module, child, module)
                           └─ _imp._set_lazy_attributes(module, name)
```

The `_find_spec` step:

```python
def _find_spec(name, path, target=None):
    meta_path = sys.meta_path
    ...
    is_reload = name in sys.modules
    for finder in meta_path:
        with _ImportLockContext():
            try:
                find_spec = finder.find_spec
            except AttributeError:
                continue
            else:
                spec = find_spec(name, path, target)
        if spec is not None:
            # The parent import may have set a submodule of this name. ...
            if not is_reload and name in sys.modules:
                module = sys.modules[name]
                try:
                    __spec__ = module.__spec__
                except AttributeError:
                    pass
                else:
                    if __spec__ is None:
                        raise ModuleNotFoundError(...)
                    return __spec__
            else:
                return spec
    else:
        return None
```

(`_bootstrap.py:1140`)

Note the `with _ImportLockContext():` inside the loop. The meta path is walked
under the import lock, but each finder is called under its own acquisition so a
finder can call back into the import system.

### The sanity check

```python
def _sanity_check(name, package, level):
    """Verify arguments are "sane"."""
    if not isinstance(name, str):
        raise TypeError(f'module name must be str, not {type(name)}')
    if level < 0:
        raise ValueError('level must be >= 0')
    if level > 0:
        if not isinstance(package, str):
            raise TypeError('__package__ not set to a string')
        elif not package:
            raise ImportError('attempted relative import with no known parent '
                              'package')
    if not name and level == 0:
        raise ValueError('Empty module name')
```

(`_bootstrap.py:1187`)

Four distinct error types, in this order: `TypeError` for a non-string name,
`ValueError` for a negative level, `TypeError` for a non-string package,
`ImportError` for an empty package with a positive level, `ValueError` for an
empty name with level zero.

### Relative import resolution

```python
def _resolve_name(name, package, level):
    bits = package.rsplit('.', level - 1)
    if len(bits) < level:
        raise ImportError('attempted relative import beyond top-level package')
    base = bits[0]
    return f'{base}.{name}' if name else base
```

The arithmetic: `package.rsplit('.', level - 1)` splits off `level - 1`
components from the right. With `package='a.b.c'`:

| `level` | `bits` | resolved base | full name (with `name='x'`) |
|---|---|---|---|
| 1 | `['a.b.c']` | `a.b.c` | `a.b.c.x` |
| 2 | `['a.b', 'c']` | `a.b` | `a.b.x` |
| 3 | `['a', 'b', 'c']` | `a` | `a.x` |
| 4 | `['a', 'b', 'c']` | - | `ImportError: attempted relative import beyond top-level package` |

Level 0 means absolute and never reaches this function.

### The `__package__` calculation

```python
def _calc___package__(globals):
    package = globals.get('__package__')
    spec = globals.get('__spec__')
    if package is not None:
        if spec is not None and package != spec.parent:
            _warnings.warn("__package__ != __spec__.parent "
                           f"({package!r} != {spec.parent!r})",
                           DeprecationWarning, stacklevel=3)
        return package
    elif spec is not None:
        return spec.parent
    else:
        _warnings.warn("can't resolve package from __spec__ or __package__, "
                       "falling back on __name__ and __path__",
                       ImportWarning, stacklevel=3)
        package = globals['__name__']
        if '__path__' not in globals:
            package = package.rpartition('.')[0]
    return package
```

(`_bootstrap.py:1429`)

The precedence is `__package__` → `__spec__.parent` → `__name__` (minus the last
component, unless the module has `__path__`, i.e. is a package). A mismatch
between `__package__` and `__spec__.parent` raises a `DeprecationWarning`.

### `__import__` itself

```python
def __import__(name, globals=None, locals=None, fromlist=(), level=0):
    if level == 0:
        module = _gcd_import(name)
    else:
        globals_ = globals if globals is not None else {}
        package = _calc___package__(globals_)
        module = _gcd_import(name, package, level)
    if not fromlist:
        # Return up to the first dot in 'name'.
        if level == 0:
            return _gcd_import(name.partition('.')[0])
        elif not name:
            return module
        else:
            # Figure out where to slice the module's name up to the first dot
            # in 'name'.
            cut_off = len(name) - len(name.partition('.')[0])
            # Slice end needs to be positive to alleviate need to special-case
            # when ``'.' not in name``.
            return sys.modules[module.__name__[:len(module.__name__)-cut_off]]
    elif hasattr(module, '__path__'):
        return _handle_fromlist(module, fromlist, _gcd_import)
    else:
        return module
```

(`_bootstrap.py:1456`)

**The `locals` argument is ignored.** The docstring says so explicitly: "The
'locals' argument is ignored."

**The return value depends on `fromlist`:**

| `fromlist` | Module has `__path__` | Returns |
|---|---|---|
| empty | either | The **top-level** package (`a` for `a.b.c`) |
| non-empty | yes (a package) | The module itself, after `_handle_fromlist` |
| non-empty | no (a plain module) | The module itself |

This is why `import a.b` binds `a` in the namespace, while
`import a.b as x` binds `a.b` - the `as` form compiles to `IMPORT_NAME` followed
by `IMPORT_FROM` (which pulls the attribute `b` off the returned module `a`),
not to a different import call.

**`globals` is only consulted when `level > 0`.** For an absolute import the
`globals` argument is ignored entirely.

### `from X import Y` and the fromlist

```python
def _handle_fromlist(module, fromlist, import_, *, recursive=False):
    # The hell that is fromlist ...
    for x in fromlist:
        if not isinstance(x, str):
            if recursive:
                where = module.__name__ + '.__all__'
            else:
                where = "``from list''"
            raise TypeError(f"Item in {where} must be str, "
                            f"not {type(x).__name__}")
        elif x == '*':
            if not recursive and hasattr(module, '__all__'):
                _handle_fromlist(module, module.__all__, import_,
                                 recursive=True)
        elif not hasattr(module, x):
            from_name = f'{module.__name__}.{x}'
            try:
                _call_with_frames_removed(import_, from_name)
            except ModuleNotFoundError as exc:
                # Backwards-compatibility dictates we ignore failed
                # imports triggered by fromlist for modules that don't
                # exist.
                if (exc.name == from_name and
                    sys.modules.get(from_name, _NEEDS_LOADING) is not None):
                    continue
                raise
    return module
```

(`_bootstrap.py:1392`)

The rules, in order:

1. **A non-string item in the fromlist raises `TypeError`.** The message names
   the source: `from list` normally, `module.__name__.__all__` when recursing.
2. **`'*'` expands to `module.__all__`** and recurses, but only if `__all__`
   exists and only once (the `recursive` flag prevents infinite recursion).
3. **If the module already has the attribute, nothing happens.** The submodule is
   NOT imported. This is why `from os import path` works when `os.path` was
   already imported - and why `from os import path` does *not* trigger an import
   of `os.path` when `os` defines a `path` attribute of its own.
4. **If the module lacks the attribute, a submodule import is attempted.**
5. **A `ModuleNotFoundError` for the submodule is swallowed** in one specific
   case: when `exc.name` equals the full submodule name AND
   `sys.modules.get(from_name)` is not `None`. The `is not None` test (not
   `is _NEEDS_LOADING`) means the submodule is *present in `sys.modules`* - the
   `sys.modules` entry was created but the import failed. In that case the
   error is ignored and the loop continues; the subsequent `IMPORT_FROM` then
   raises `AttributeError` instead.

This last rule is subtle and is the source of the classic
`ImportError: cannot import name 'x' from 'pkg'` versus `AttributeError`
difference.

### `sys.modules` and the module cache

The module cache is `sys.modules`, a plain dict. The critical rules:

**A partially-initialised module IS visible in `sys.modules` during its own
import.** This is what makes circular imports work at all: module `a` can
`import b` while `b` is still executing, and `b` can then see `a`'s partially
built namespace.

The `_initializing` flag on the spec tracks this:

```python
# Return whether module (a sys.modules value) is still executing.
def _is_initializing(module):
    return getattr(getattr(module, '__spec__', None), '_initializing', False)
```

(`_bootstrap.py:1274`)

**The spec's `_initializing` flag is set BEFORE the module is put in
`sys.modules`.** This ordering is load-bearing: it is what lets another thread
that finds the module in `sys.modules` know to wait rather than treat it as
ready.

**On failure, the module is removed from `sys.modules`.** In `_load_unlocked`:

```python
try:
    ...
    sys.modules[spec.name] = module
    try:
        if spec.loader is None:
            ...
        else:
            spec.loader.exec_module(module)
    except BaseException:
        try:
            del sys.modules[spec.name]
        except KeyError:
            pass
        raise
    # Move the module to the end of sys.modules.
    # We don't ensure that the import-related module attributes get
    # set in the sys.modules replacement case.  Such modules are on
    # their own.
    module = sys.modules.pop(spec.name)
    sys.modules[spec.name] = module
    ...
```

**The module is popped and re-inserted at the end of `sys.modules` after a
successful import.** This makes `sys.modules` insertion-ordered by *completion*
time, not start time. A module that took a long time to execute appears later
in the dict than one that started later but finished earlier.

### The parent/child relationship

```python
    if parent:
        # Set the module as an attribute on its parent.
        parent_module = sys.modules[parent]
        try:
            setattr(parent_module, child, module)
        except AttributeError:
            msg = f"Cannot set an attribute on {parent!r} for child module {child!r}"
            _warnings.warn(msg, ImportWarning)
```

(`_bootstrap.py:1253`)

After `import a.b` succeeds, `sys.modules['a'].b is sys.modules['a.b']`. This is
a **side effect of the import**, not of the `import` statement's binding. It is
why `from a import b` works even when `b` is a submodule.

A module that cannot have the attribute set (a module with `__slots__`-like
behaviour, or a namespace path) produces an `ImportWarning`, not an error.

### The "not a package" error

```python
        try:
            path = parent_module.__path__
        except AttributeError:
            if lazy_submodule:
                return None
            msg = f'{_ERR_MSG_PREFIX}{name!r}; {parent!r} is not a package'
            raise ModuleNotFoundError(msg, name=name) from None
```

(`_bootstrap.py:1223`)

`ModuleNotFoundError: No module named 'a.b'; 'a' is not a package`. The
`name=name` keyword sets `exc.name`, which `importlib.util.resolve_name` and
the fromlist logic above depend on.

### The locking model (3.15)

3.15 reworked the import locks to fix deadlocks. The structure is:

**`_resolve_parents`** - called *before* taking the target module's lock:

```python
def _resolve_parents(name, import_):
    # Wait for each ancestor package that another thread is still
    # initializing, outermost first.
    parts = name.split('.')
    for i in range(1, len(parts) - 1):
        ancestor = '.'.join(parts[:i])
        if _is_initializing(sys.modules.get(ancestor)):
            _lock_unlock_module(ancestor)
    # Import the immediate parent, or wait for it likewise.
    parent = name.rpartition('.')[0]
    if parent:
        module = sys.modules.get(parent, _NEEDS_LOADING)
        if module is _NEEDS_LOADING or _is_initializing(module):
            _call_with_frames_removed(import_, parent)
```

(`_bootstrap.py:1283`)

The comment names the bugs it fixes: gh-83065 and gh-159963. The rule is that
**no thread holds a submodule's lock while waiting for its parent**. Ancestors
are handled outermost-first.

**`_find_and_load`** takes the per-module lock:

```python
def _find_and_load(name, import_, *, lazy_submodule=False):
    # Optimization: we avoid unneeded module locking if the module
    # already exists in sys.modules and is fully initialized.
    module = sys.modules.get(name, _NEEDS_LOADING)
    if module is _NEEDS_LOADING or _is_initializing(module):
        if module is not _NEEDS_LOADING:
            # Wait for the thread executing the module.
            lock = _get_module_lock(name)
            try:
                lock.acquire()
            except _DeadlockError:
                # A circular import split across threads: accept the
                # partially initialized module.
                pass
            else:
                try:
                    module = sys.modules.get(name, _NEEDS_LOADING)
                finally:
                    lock.release()
        ...
```

(`_bootstrap.py:1302`)

**The `_DeadlockError` handling is the interesting part.** If acquiring the
module lock would deadlock (because the current thread already holds it, via a
circular import split across threads), the import **proceeds anyway** and
accepts a partially-initialised module. This is deliberate: a deadlock is worse
than a partially-initialised module.

There is a second `_DeadlockError` catch in the "not yet loaded" path, which
re-raises if no module appeared in `sys.modules`.

**The re-check after the lock.** After acquiring the lock, `sys.modules` is
consulted *again* while still holding the lock, so another thread cannot have
begun loading it again. The module is gone if the loading thread failed.

### The audit event

```python
        if module is _NEEDS_LOADING:
            sys.audit(
                "import",
                name,
                None,
                getattr(sys, "path", None),
                getattr(sys, "meta_path", None),
                getattr(sys, "path_hooks", None)
            )
```

(`_bootstrap.py:1330`)

Every first-time import raises the `import` audit event with the module name,
`None` for the filename, and the three path lists. An audit hook that raises
aborts the import.

### The meta path

`sys.meta_path` is the ordered list of finders. The default is:

```python
sys.meta_path = [
    BuiltinImporter,       # built-in and frozen modules
    FrozenImporter,        # (folded into BuiltinImporter in 3.12+)
    PathFinder,            # the filesystem
]
```

`PathFinder` is **always last**. It is the only finder that consults
`sys.path`. A user can insert finders before it to intercept imports, or remove
it to disable filesystem imports entirely.

Each finder implements `find_spec(name, path, target)`. The finder is called
with `path` = the parent package's `__path__` for submodules, and `None` for
top-level modules.

The `sys.path_hooks` list provides the path-entry finders. `PathFinder` iterates
`sys.path`, and for each entry asks each path hook for a finder. The result is
cached in `sys.path_importer_cache`, keyed by the path entry.

### The path finders and loaders

From `Lib/importlib/_bootstrap_external.py`:

| Finder | Finds | Loader |
|---|---|---|
| `BuiltinImporter` | Modules built into the interpreter (via `PyImport_Inittab`) | `BuiltinImporter` itself |
| `FrozenImporter` | Modules frozen into the binary | `FrozenImporter` |
| `FileFinder` | Files on `sys.path` | `SourceFileLoader`, `SourcelessFileLoader`, `ExtensionFileLoader` |

`FileFinder` is created per path entry by the path hook, and caches the
directory listing in `sys.path_importer_cache`. The cache is invalidated by
`importlib.invalidate_caches()`, which calls `find_spec`'s `invalidate_caches`
on every cached finder.

The loader selection inside `FileFinder.find_spec`:

1. Look for `<name>/__init__.<suffix>` - a package. The suffix order is
   `.py`, `.pyc` (sourceless), then the extension suffix.
2. Look for `<name>.<suffix>` - a plain module.
3. If a directory exists with the name but no `__init__`, it is a **namespace
   package** (PEP 420).

### The loaders

| Loader | `get_code` | `get_source` | `is_package` | Notes |
|---|---|---|---|---|
| `SourceFileLoader` | Compiles the source; writes a `.pyc` | Yes | Checks for `__init__` | Writes the bytecode cache atomically |
| `SourcelessFileLoader` | Reads the `.pyc` directly | `None` | Checks for `__init__` | Validates the magic number and flags |
| `ExtensionFileLoader` | `None` (the extension loads itself) | `None` | Checks for `__init__` | `dlopen`s the shared library |

The loader protocol in 3.15 is the two-method form:

- `create_module(spec)` - returns a module object, or `None` to use the default.
- `exec_module(module)` - populates the module.

The older single-method form (`load_module`) is deprecated. The `_load_unlocked`
path uses `module_from_spec`, which calls `create_module`, then `_init_module_attrs`,
then `exec_module`.

### The module object model

`ModuleType` has a `__dict__`. The special attributes are:

| Attribute | Set when | Value |
|---|---|---|
| `__name__` | before exec | `spec.name` |
| `__loader__` | before exec | `spec.loader` |
| `__package__` | before exec | `spec.parent` |
| `__spec__` | before exec | the spec itself |
| `__path__` | before exec, packages only | `spec.submodule_search_locations` |
| `__file__` | before exec, source modules only | `spec.origin` |
| `__builtins__` | before exec | the builtins dict or module |
| `__doc__` | before exec | `spec.loader.get_doc(spec)` |

`_init_module_attrs(spec, module, *, override=False)` sets these. The
`override` flag controls whether an existing value wins. The rule is that
`__name__` and `__loader__` are always set, while the others are set only if
currently `None` (unless `override`).

For a **package**, `__path__` is set to `spec.submodule_search_locations`, which
is a `_NamespacePath` for namespace packages and a plain list otherwise.

For a **namespace package**, `__file__` is `None` and `__path__` is a
`_NamespacePath` object whose contents change as new portions are discovered.
The `__path__` of a namespace package is recomputed, not cached.

### The `__spec__` object

`ModuleSpec` carries:

| Field | Meaning |
|---|---|
| `name` | The fully-qualified module name |
| `loader` | The loader, or `None` for namespace packages |
| `origin` | The file path, or `None` |
| `submodule_search_locations` | The `__path__` list, or `None` for non-packages |
| `loader_state` | Arbitrary state passed between `create_module` and `exec_module` |
| `cached` | The cached bytecode, if any |
| `_initializing` | True while the module is executing |
| `parent` | The parent package's name |
| `_set_fileattr` | Whether to set `__file__` |
| `_uninitialized_submodules` | Children currently being imported |

The `parent` field is computed by `_bootstrap._calc___package__` at spec
creation: for a top-level module, `parent` is `''`; for `a.b.c`, `parent` is
`'a.b'`.

### The relative-import base

The `level` and `package` arguments to `__import__` come from the calling
frame's globals. The compiler emits `IMPORT_NAME` with a level constant, and the
interpreter supplies the calling frame's globals and locals.

The `__package__` used is the one computed by `_calc___package__` from the
calling frame's globals. In practice, for a module `a/b/c.py`:
- `__package__` is `'a.b'`
- `__spec__.parent` is `'a.b'`
- `__name__` is `'a.b.c'`

So `from . import x` (level 1) resolves to `a.b.x`, and `from .. import x`
(level 2) resolves to `a.x`.

### `sys.path` initialisation

The order of operations at interpreter startup:

1. `Py_Initialize` computes the path configuration from `PYTHONHOME`,
   `PYTHONPATH`, the compiled-in prefix, and the `landmark` search.
   `Modules/getpath.c` implements this.
2. `sys.path` is seeded with the computed entries.
3. The `site` module is imported (unless `-S` is given). `site.py`:
   - Removes the script's directory or `''` handling for `-m`.
   - Adds the user site directory (`~/.local/lib/pythonX.Y/site-packages`).
   - Adds the system site-packages directories.
   - Processes `.pth` files in each site directory, in alphabetical order.
4. `sitecustomize` is imported if present.
5. `usercustomize` is imported if present.

**`.pth` file processing** is a real behaviour that a re-implementation must
get right. A `.pth` file has one command per line:

- A line starting with `import ` is executed as `import <the rest>`.
- Any other non-blank, non-comment line is treated as a path and appended to
  `sys.path`, relative to the `.pth` file's directory.
- Blank lines and lines starting with `#` are ignored.
- A line starting with `import ` that raises is silently ignored (the error is
  printed but does not stop startup).

**`sys.path[0]` differs between invocation modes:**

| Invocation | `sys.path[0]` |
|---|---|
| `python script.py` | The script's directory |
| `python -m module` | The **current working directory** |
| `python -c "code"` | `''` (the current working directory) |
| `python` (REPL) | `''` (the current working directory) |
| Embedded | Configurable, defaults to `''` |

This is why `python -m pytest` finds the local package but `python pytest` does
not.

### The C-level machinery

The Python layer calls into C for these operations:

| C function | Purpose |
|---|---|
| `_imp.create_builtin` | Instantiate a builtin module from the inittab |
| `_imp.create_dynamic` | `dlopen` a shared library and run its init function |
| `_imp.exec_builtin` | Run a builtin module's init function |
| `_imp.exec_dynamic` | Run a dynamic module's exec slot |
| `_imp.init_frozen` | Instantiate a frozen module |
| `_imp.is_frozen` | Test whether a name is frozen |
| `_imp.is_builtin` | Test whether a name is a builtin |
| `_imp.create_dynamic_spec` | Build a spec for an extension module |
| `_imp.source_hash` | Compute the source hash for the bytecode cache |
| `_imp._fix_co_filename` | Rewrite the `co_filename` of a code object |
| `_imp.acquire_lock` / `release_lock` | The module lock, in the GIL build |
| `_imp._set_lazy_attributes` | Set the lazy-submodule attributes |

The C-level entry point is `PyImport_ImportModuleLevelObject`, which is what
the `IMPORT_NAME` opcode calls in some builds, and `import_module_level` in
`Python/import.c`.

### The extension module init protocol

For a C extension, the interpreter:

1. Finds the shared library (`<name>.<EXT_SUFFIX>` on each `sys.path` entry).
2. `dlopen`s it (or `LoadLibrary` on Windows).
3. Looks up the symbol `PyInit_<name>`, where `<name>` is the module name with
   dots replaced by underscores.
4. Calls it. It returns a `PyObject*`:
   - For the **multi-phase** protocol, it returns a `PyModuleDef` (a static
     struct).
   - For the **single-phase** protocol, it returns a module object directly.

The multi-phase handshake, from `Python/import.c`:

- `PyModule_FromDefAndSpec(def, spec)` creates an *uninitialised* module. Module
  state (`m_size > 0`) is allocated here.
- Each slot in `def->m_slots` is run in order. Slots without an entry point are
  skipped.
- The `Py_mod_exec` slot is the main init hook.
- `_Py_ABI_SLOT` is a marker inserted by the build so the build's ABI version
  must match at load time.

The slot IDs, from `Include/moduleobject.h`:

| Slot | Purpose |
|---|---|
| `Py_mod_create` | `int (*)(PyObject **module, void *spec)` - create the module |
| `Py_mod_exec` | `int (*)(PyObject *module)` - populate it |
| `Py_mod_multiple_interpreters` | `int (*)(void)` - may the module be loaded in multiple interpreters |
| `Py_mod_gil` | `int (*)(void)` - does the module support the free-threaded build |
| `Py_mod_free` | `int (*)(void)` - the module is free-threading safe and never requests the GIL |

### `importlib.resources` and `importlib.metadata`

`importlib.resources` is a **package** in 3.15 (`Lib/importlib/resources/`), not
a module. It provides:

- `files(package)` - a `Traversable` for a package's resources.
- `as_file`, `as_binary`, `as_data` - context managers yielding real paths or
  bytes.
- `importlib.resources.abc.Traversable` - the protocol: `iterdir`, `read_bytes`,
  `read_text`, `is_dir`, `is_file`, `joinpath`, `open`, `name`.

`importlib.metadata` discovers installed distribution metadata:

- `version(name)`, `metadata(name)`, `files(name)`, `requires(name)`.
- `Distribution.discover()` - the finder chain.
- `entry_points(group=...)` - the entry-point API.

Both are built on the import system's `get_resource_reader` protocol, which is
why the module system work is a prerequisite.

### Behaviours a naive re-implementation gets wrong

1. **`__import__` returns the top-level package, not the named module**, when
   `fromlist` is empty. `import a.b` binds `a`.
2. **`locals` is ignored** by `__import__`.
3. **`globals` is ignored** when `level == 0`.
4. **A partially-initialised module is visible in `sys.modules`.** Circular
   imports depend on this.
5. **`sys.modules` is ordered by completion, not start.** The module is popped
   and re-inserted after a successful exec.
6. **A failed import removes the module from `sys.modules`.**
7. **`from X import Y` only imports the submodule `X.Y` if `X` lacks the
   attribute `Y`.** An existing attribute wins.
8. **A failed submodule import inside a fromlist is swallowed** when the
   submodule is present in `sys.modules` (the `sys.modules` entry exists but
   the import failed). The result is an `AttributeError`, not an
   `ImportError`.
9. **A submodule becomes an attribute of its parent** as a side effect of the
   import, not of the binding.
10. **`spec._initializing` is set before the module enters `sys.modules`.**
11. **A deadlock during module locking is tolerated**, not avoided - the import
    proceeds with a partially-initialised module.
12. **Ancestors are locked outermost-first, before the child's lock is taken.**
    This is the fix for gh-83065 and gh-159963.
13. **`__package__` takes precedence over `__spec__.parent`**, and a mismatch
    warns.
14. **`import a.b` when `a` is not a package** raises
    `ModuleNotFoundError: No module named 'a.b'; 'a' is not a package`, with
    `exc.name` set.
15. **Namespace packages have `__file__ is None`** and a live `__path__` that
    grows as portions are found.
16. **`sys.path[0]` is the CWD for `-m` and `-c`,** and the script's directory
    for a script file.
17. **The `import` audit event fires before the import,** with `None` as the
    filename argument.
18. **A module that cannot have a child attribute set** raises an
    `ImportWarning`, not an exception.

## Verification

**1. Verify the pipeline order with a trace hook.**

```bash
python3.15 -c "
import sys
class Tracer:
    def find_module(self, name, path=None): return None
    def find_spec(self, name, path=None, target=None):
        print('FIND', name, path)
        return None
sys.meta_path.insert(0, Tracer())
import xml.etree.ElementTree
"
```

Expect `FIND` lines for `xml`, then `xml.etree`, then `xml.etree.ElementTree`,
in that order.

**2. Verify the `__import__` return-value rule.**

```bash
python3.15 -c "
import xml.etree.ElementTree as ET
print(ET.__name__)
import xml.etree.ElementTree
print(xml.etree.ElementTree.__name__)
"
```

**3. Verify the partially-initialised module rule.**

```bash
cat > /tmp/circ_a.py <<'EOF'
import sys
print("A start")
import circ_b
print("A sees B:", hasattr(sys.modules['circ_b'], 'ready'))
EOF
cat > /tmp/circ_b.py <<'EOF'
import sys
print("B sees A in sys.modules:", 'circ_a' in sys.modules)
ready = True
EOF
cd /tmp && python3.15 circ_a.py
```

Expect `B sees A in sys.modules: True`.

**4. Verify `from X import Y` prefers an existing attribute.**

Use a package whose submodule is genuinely lazy. `xml` imports `xml.etree`
on demand, so `xml.etree` is absent from `sys.modules` until asked for:

```bash
python3.15 -c "
import sys, xml
print('xml.etree' in sys.modules)   # False
from xml import etree
print('xml.etree' in sys.modules)   # True - the submodule WAS imported
"
```

The converse case needs a package that defines an attribute with the same name
as a submodule. `os` is the classic: `os.path` is the module `posixpath`,
already bound as an attribute, so `from os import path` does **not** trigger a
new import.

```bash
python3.15 -c "
import sys, os
print(os.path is sys.modules['posixpath'])   # True - bound as an attribute
"
```

Both behaviours are governed by the single rule in `_handle_fromlist`: the
submodule is imported **only if the parent lacks the attribute**.

**5. Verify the namespace package `__file__` rule.**

```bash
mkdir -p /tmp/nspkg && cd /tmp && python3.15 -c "
import nspkg
print(nspkg.__file__)
print(list(nspkg.__path__))
"
```

Expect `None` and a path list containing `/tmp/nspkg`.

**6. Verify `sys.path[0]` per invocation mode.**

```bash
cd /tmp && printf 'import sys\nprint(repr(sys.path[0]))\n' > /tmp/pp.py
python3.15 /tmp/pp.py      # '/tmp'   (script directory)
python3.15 -m pp           # ''       (cwd)
python3.15 -c "import sys; print(repr(sys.path[0]))"   # '' (cwd)
```

**7. Verify the module lock ordering is present in the 3.15 source.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap.py \
  | grep -n "_resolve_parents\|_DeadlockError"
```

Expect `_resolve_parents` defined and two `_DeadlockError` catches.
