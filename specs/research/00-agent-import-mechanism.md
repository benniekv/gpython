> **Sourcing note.** This is raw agent research output. It cites the CPython
> `main` branch, which is 3.16.0a2+dev, not the 3.15 release. Where it differs
> from the spec files in `../`, the spec files win: they were written afterwards
> against the `v3.15.2` tag and the discrepancies were corrected. See
> `00-sources-and-caveats.md` for the full account.

Now I have everything I need. Let me write the comprehensive report.

---

# CPython Import Mechanism - Source-of-Truth Reference for Re-implementation in Go

This report covers the CPython import machinery as it exists on the `main` branch (post-3.14, current development towards 3.16). The reference version is functionally equivalent to CPython 3.14.x - the implementation has been stable across 3.12 / 3.13 / 3.14 with the same architecture. All line/function citations point at files fetched from `https://raw.githubusercontent.com/python/cpython/main/...` unless otherwise noted.

Targeted source files (with byte counts):
- `Python/import.c` - 172 KB - entry points, module creation, sys.modules, locks, frozen dispatch, bytecode exec, extension reload
- `Python/importdl.c` - 16 KB - name-encoding hooks (PyInit_/PyModExport_), `_PyImport_GetModuleExportHooks`, `_PyImport_RunModInitFunc`
- `Python/dynload_shlib.c` - 3 KB - POSIX `dlopen`/`dlsym` path
- `Python/frozen.c` - 6 KB - frozen module tables (`_PyImport_FrozenBootstrap`, `_PyImport_FrozenStdlib`, `_PyImport_FrozenTest`, aliases)
- `Python/bltinmodule.c` - 106 KB - builtins module registration; the `__import__` Python function lives here
- `Python/modsupport.c` - 21 KB - `PyModule_*` helpers (referenced where needed)
- `Include/internal/pycore_import.h` - internal API table
- `Lib/importlib/_bootstrap.py` - the pure-Python import front end
- `Lib/importlib/_bootstrap_external.py` - `FileFinder`, `PathFinder`, `SourceLoader`, `ExtensionFileLoader`, `NamespacePath`, etc.
- `Lib/importlib/util.py` - public `find_spec`, `resolve_name`, `LazyLoader`
- `Lib/importlib/abc.py` - ABCs (`MetaPathFinder`, `PathEntryFinder`, `ResourceLoader`, `InspectLoader`, `ExecutionLoader`, `SourceLoader`)
- `Lib/importlib/machinery.py` - public constants (`SOURCE_SUFFIXES`, `EXTENSION_SUFFIXES`, `BYTECODE_SUFFIXES`, re-exports)
- `Lib/importlib/_abc.py` - minimal `Loader` ABC (used to break the `_bootstrap → abc` cycle)
- `Lib/importlib/metadata/__init__.py` - `importlib.metadata` API
- `Lib/importlib/resources/__init__.py` - `importlib.resources` public surface
- `Modules/xxmodule.c` - reference for both single-phase and multi-phase extension init
- `Lib/site.py` - `sys.path` finalisation, `.pth` and `.start` processing

---

## 1. The full import pipeline

### 1.1 Top-level call chain

```
caller                 | IMPORT_NAME opcode                    | C API
import X               | PyImport_ImportModuleLevelObject      | PyImport_Import(name)
                       |   -> _PyImport_GetAbsName             |
                       |   -> import_find_and_load             |
                       |     -> import_find_and_load_with_name |
                       |       -> importlib._bootstrap._find_and_load  (PyObject_CallMethodObjArgs)
                       |         -> _resolve_parents           |  (wait on parents)
                       |         -> _find_and_load_unlocked    |
                       |           -> _find_spec               |  -> sys.meta_path[*].find_spec
                       |           -> _load_unlocked           |  -> module_from_spec + loader.exec_module
                       |       -> remove_importlib_frames      |  (strip importlib frames)
                       |   -> _handle_fromlist (if fromlist)   |
```

### 1.2 IMPORT_NAME → C → Python - exactly how the opcode works

`IMPORT_NAME(namei)` resolves `__import__` from the calling frame's globals (the `builtins` module's `__import__` function, installed into `globals()['__builtins__']`), and calls it with `(name, globals, locals, fromlist, level)` - where `globals`/`locals`/`fromlist`/`level` come from the code object (namei encodes the fromlist operand as a names-index). See `Python/bltinmodule.c` (`builtin___import___impl`) for the exact C bridge.

The Python-level `__import__` itself is defined in `Lib/importlib/_bootstrap.py:54308`. It is registered into `builtins.__dict__` during `_setup()` (in `_bootstrap.py:56049`) and again by `_PyImport_InitDefaultImportFunc()` in `Python/import.c:111835` which caches the function pointer in the interpreter state for fast-path lookups.

### 1.3 `PyImport_ImportModuleLevelObject` - the C-level dispatch

The C function `PyImport_ImportModuleLevelObject` (`Python/import.c:123448`, ~100 lines) is a direct port of the Python-level `importlib.__import__ + _gcd_import` flow for speed. It does NOT call into Python for the simple cases - it has inline equivalents of:

| Step | Python (importlib) | C port |
|---|---|---|
| Resolve abs name | `_calc___package__` + `_resolve_name` | `_PyImport_GetAbsName(tstate, name, globals, level)` (`Python/import.c:123063`) |
| Look in `sys.modules` | `sys.modules.get(name, _NEEDS_LOADING)` | `import_get_module(tstate, abs_name)` |
| Fast init check | `_is_initializing` | `import_ensure_initialized(tstate->interp, mod, abs_name)` |
| Load if missing | `_find_and_load` | `import_find_and_load(tstate, abs_name)` |
| Handle fromlist | `_handle_fromlist` | `importlib._bootstrap._handle_fromlist` (called back into Python via `PyObject_CallMethodObjArgs`) |

`import_find_and_load` is a thin wrapper that calls `import_find_and_load_with_name` with `importlib._bootstrap._find_and_load` as the callable (`Python/import.c:122875`).

### 1.4 `__import__` Python function - exact algorithm

`Lib/importlib/_bootstrap.py:54308`:

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
            cut_off = len(name) - len(name.partition('.')[0])
            return sys.modules[module.__name__[:len(module.__name__)-cut_off]]
    elif hasattr(module, '__path__'):
        return _handle_fromlist(module, fromlist, _gcd_import)
    else:
        return module
```

The return-value rules:
- `import a.b.c` (no fromlist) returns `sys.modules['a']`.
- `from a.b.c import d` returns `sys.modules['a.b.c']` (because `a.b.c` has `__path__` ... it doesn't, but the rule is `hasattr(module, '__path__')`).
- `from a.b.c import d` when `a.b.c` is not a package: returns `a.b.c` directly without calling `_handle_fromlist` - `d` is then looked up by `IMPORT_FROM` (which falls back to `sys.modules['a.b.c.d']`).
- `from . import b` (`level=1`, `name=''`): the `elif not name:` branch returns the resolved package itself.

### 1.5 `_gcd_import` - the common path

`Lib/importlib/_bootstrap.py:51304`:

```python
def _gcd_import(name, package=None, level=0):
    _sanity_check(name, package, level)
    if level > 0:
        name = _resolve_name(name, package, level)
    return _find_and_load(name, _gcd_import)
```

This is shared by `__import__`, `importlib.import_module` (`Lib/importlib/__init__.py`), and the internal bootstrap. It always returns the *fully-qualified* module - never the topmost package.

### 1.6 `sys.meta_path` / `sys.path_hooks` / `sys.path_importer_cache` chain

`sys.meta_path` is a list of `MetaPathFinder` instances consulted in order. At interpreter startup (`_bootstrap.py:57500` + `_bootstrap_external.py:58399`):

```
sys.meta_path = [
    BuiltinImporter,         # _bootstrap.py
    FrozenImporter,          # _bootstrap.py
    ...,                     # user-added finders
    PathFinder,              # _bootstrap_external.py (last by default)
]
```

`_bootstrap.py:_install` (line 57500) appends `BuiltinImporter` and `FrozenImporter`. `_bootstrap_external.py:_install` (line 58399) appends `PathFinder` last - and the latter is called via `_install_external_importers()` after `_frozen_importlib_external` is imported.

`sys.path_hooks` is a list of callables taking a path entry and returning a finder (or raising `ImportError`). Default: `[FileFinder.path_hook(*_get_supported_file_loaders())]` (one entry, from `_bootstrap_external.py:_install`). The default entry raises `ImportError` for non-directories, which makes `PathFinder` skip non-directory entries.

`sys.path_importer_cache` is a `dict[path_entry → finder | None]`. `PathFinder._path_importer_cache(path)` (`_bootstrap_external.py:42464`) lazily populates this cache by trying each path hook in `sys.path_hooks`. The cache is flushed by `importlib.invalidate_caches()` (which calls `PathFinder.invalidate_caches()`, then `MetadataPathFinder.invalidate_caches()`, then bumps `NamespacePath._epoch`).

### 1.7 `PathFinder` - `sys.path`/`__path__` traversal

`Lib/importlib/_bootstrap_external.py:42464`. The `find_spec` method:

```python
@classmethod
def find_spec(cls, fullname, path=None, target=None):
    if path is None:
        path = sys.path
    spec = cls._get_spec(fullname, path, target)
    if spec is None:
        return None
    elif spec.loader is None:
        namespace_path = spec.submodule_search_locations
        if namespace_path:
            spec.origin = None
            spec.submodule_search_locations = NamespacePath(fullname, namespace_path, cls._get_spec)
            return spec
        else:
            return None
    else:
        return spec
```

`_get_spec` walks every entry in `path`, asks `_path_importer_cache(entry)` for a finder, then `finder.find_spec(fullname, target)`. Each entry that returns a spec with `loader is None` but non-empty `submodule_search_locations` (a directory portion) contributes to a list of namespace portions. If at least one such portion is found, the final returned spec is a **namespace package spec** with `loader=None` and `submodule_search_locations=NamespacePath(...)`. Otherwise, returns `None`.

### 1.8 `FileFinder` - concrete path-entry finder

`Lib/importlib/_bootstrap_external.py:47832`. Constructor takes `(path, *loader_details)` where each `loader_details` is `(loader_class, suffixes_tuple)`. The default registration is from `_get_supported_file_loaders()` (line 57604):

```python
[
    (ExtensionFileLoader, _imp.extension_suffixes()),  # e.g. ['.cpython-314-x86_64-linux-gnu.so', ...]
    (SourceFileLoader, SOURCE_SUFFIXES),                # ['.py']  (+ '.pyw' on Windows)
    (SourcelessFileLoader, BYTECODE_SUFFIXES),          # ['.pyc']
]
```

`FileFinder.find_spec(fullname)`:
1. Strips off the dotted prefix; the last component (`tail_module`) is searched.
2. Caches `_path_cache = set(os.listdir(path))` keyed on `path`'s mtime.
3. If `tail_module` is a directory, look for `__init__.{suffix}` in it - if found, return a package spec.
4. If not, look for `tail_module.{suffix}` for each `(suffix, loader_class)` in `_loaders`. First hit wins.
5. If a directory exists but no `__init__`, return a spec with `loader=None` and `submodule_search_locations=[base_path]` - this is how a *single* namespace package portion is created by FileFinder. `PathFinder._get_spec` then merges these across path entries into a full `NamespacePath`.

---

## 2. Finders

### 2.1 `BuiltinImporter` (`_bootstrap.py:33024`)

`find_spec(fullname, path=None, target=None)`:
- Calls `_imp.is_builtin(fullname)`. If true, returns `spec_from_loader(fullname, cls, origin='built-in')`.
- Else `None`.

`create_module(spec)`: calls `_imp.create_builtin(spec)` (which calls `create_builtin()` in `Python/import.c:81875`). For "core" modules (`sys`, `builtins`), the result is a fully-populated module; otherwise it is the result of the user's `PyInit_<name>` call (single-phase) or a fresh module from `PyModuleDef` (multi-phase).

`exec_module(module)`: calls `_imp.exec_builtin(module)` which is `exec_builtin_or_dynamic` (`Python/import.c:30215`), which in turn calls `PyModule_Exec(mod)` - runs the `Py_mod_exec` slot.

`get_code` / `get_source` return `None`. `is_package` returns `False`.

### 2.2 `FrozenImporter` (`_bootstrap.py:34425`)

`find_spec`:
1. Calls `_imp.find_frozen(fullname)`.
2. Returns `None` if not frozen.
3. Else returns a spec with `loader_state = SimpleNamespace(filename=..., origname=...)` and `origin='frozen'`. If frozen is a package, `spec.submodule_search_locations` is pre-populated with `sys._stdlib_dir/<name>`.

`_fix_up_module(module)` is invoked by `_setup()` (line 56049) for modules already present in `sys.modules` at boot. It adjusts `__file__`, `__path__`, etc., based on `sys._stdlib_dir`.

`create_module(spec)`: returns `_new_module(spec.name)`, optionally setting `__file__ = spec.loader_state.filename`.

`exec_module(module)`: calls `_imp.get_frozen_object(name)` to get the code object, then `exec(code, module.__dict__)`.

### 2.3 `PathFinder` - see §1.7.

### 2.4 (Windows only) `WindowsRegistryFinder` - `Lib/importlib/_bootstrap_external.py:23724`. Not relevant for POSIX.

### 2.5 `MetadataPathFinder` (importlib.metadata) - `Lib/importlib/metadata/__init__.py`

A `MetaPathFinder` subclass. It is **not** added to `sys.meta_path` at startup - it self-registers when `importlib.metadata` is first imported (in modern CPython this happens lazily). It implements `find_distributions(context)` not `find_spec()`. `PathFinder.find_distributions` is a delegating shim that calls into it.

### 2.6 Loader/finder registration via ABCs - `Lib/importlib/abc.py`

`abc.py:_register(abstract_cls, *classes)` calls `abc.ABCMeta.register(abstract_cls, cls)` AND, if `_frozen_importlib` is available, also registers the frozen counterpart. The registrations are:
- `MetaPathFinder`: `BuiltinImporter, FrozenImporter, PathFinder, WindowsRegistryFinder`.
- `PathEntryFinder`: `FileFinder`.
- `InspectLoader`: `BuiltinImporter, FrozenImporter, NamespaceLoader`.
- `ExecutionLoader`: `ExtensionFileLoader, AppleFrameworkLoader`.
- `FileLoader` (concrete): `SourceFileLoader, SourcelessFileLoader`.
- `SourceLoader` (concrete): `SourceFileLoader`.

---

## 3. Loaders

### 3.1 Loader protocol

The `Loader` ABC (`Lib/importlib/_abc.py`) defines only `create_module(spec)`. Other protocol methods are added by the various ABCs and concrete loaders. The complete set:

| Method | ABC / provider | Purpose |
|---|---|---|
| `create_module(spec)` | `Loader` | Return a new module to use; `None` means "use default" |
| `exec_module(module)` | `Loader` (implicit) | Populate the module |
| `is_package(fullname)` | `InspectLoader` | Is this a package? |
| `get_code(fullname)` | `InspectLoader` | Compiled code object |
| `get_source(fullname)` | `InspectLoader` | Source text |
| `source_to_code(data, path, fullname)` | `InspectLoader` (static) | Compile source |
| `get_data(path)` | `ResourceLoader` | Bytes for a resource path |
| `get_filename(fullname)` | `ExecutionLoader` | Path to file (for `__file__`) |
| `get_resource_reader(module)` | `ResourceReader` (PEP 302) | For `importlib.resources` |

`Loader.create_module` defaults to `None` (use default semantics - `_new_module` in `_bootstrap.py:1492`). But the loader contract requires that *if* `exec_module` is defined, then `create_module` MUST also be defined; otherwise `_bootstrap.module_from_spec` raises `ImportError`. This is enforced at line 29007 (`if hasattr(spec.loader, 'exec_module')` without `create_module` → error).

### 3.2 `SourceFileLoader` - source files (`.py`)

`Lib/importlib/_bootstrap_external.py:35818`. Subclasses `FileLoader, SourceLoader`. The hot path is `SourceLoader.get_code(fullname)` (`_bootstrap_external.py:26784`):

1. Read source path mtime+size via `path_stats(path)`.
2. Compute `cache_from_source(source_path)` - the bytecode cache filename.
3. Read bytecode file. Validate with `_classify_pyc` → returns flags (bits: 0=hash-based, 1=check_source).
4. If hash-based, recompute source hash and compare; if timestamp-based, compare mtime and size.
5. If invalid, fall through to read source and recompile.
6. If valid, return `_compile_bytecode(data[16:], ...)`.
7. If `sys.dont_write_bytecode` is False, write the compiled bytecode back to the cache.

`SourceLoader.get_source(fullname)`: `get_data(path)` then `decode_source(bytes)`.

`SourceFileLoader.set_data(path, data)`: atomic write via `_write_atomic`; creates parent directories if missing; ignores permission errors silently.

### 3.3 `SourcelessFileLoader` - pure bytecode (`.pyc`)

`Lib/importlib/_bootstrap_external.py:36567`. `get_code(fullname)`: read `.pyc`, validate magic+flags with `_classify_pyc`, then `_compile_bytecode(data[16:], ...)`. `get_source` returns `None`. Used for `.pyc` files that lack a corresponding source - typical for files installed in `__pycache__` after a `compileall`.

### 3.4 `ExtensionFileLoader` - shared-library modules

`Lib/importlib/_bootstrap_external.py:36567`. The loader protocol is the most interesting for extensions:

```python
def create_module(self, spec):
    """Create an uninitialized extension module"""
    module = _bootstrap._call_with_frames_removed(
        _imp.create_dynamic, spec)
    return module

def exec_module(self, module):
    """Initialize an extension module"""
    _bootstrap._call_with_frames_removed(_imp.exec_dynamic, module)

def is_package(self, fullname):
    file_name = _path_split(self.path)[1]
    return any(file_name == '__init__' + suffix
               for suffix in EXTENSION_SUFFIXES)
```

`_imp.create_dynamic(spec)` calls C `exec_create_dynamic` which goes through `_PyImport_FindSharedFuncptr` and `_PyImport_RunModInitFunc`. The `module` returned from `create_module` is **already initialized** in the single-phase case (legacy `Py_InitModule`); in the multi-phase case, `create_module` returns an uninitialized module object built from the `PyModuleDef`, and `exec_module` runs `Py_mod_exec`.

### 3.5 Extension module protocols

#### 3.5.1 Legacy single-phase init (`PyInit_<name>`)

The classic C extension pattern (still supported but deprecated for multi-phase work):

```c
PyMODINIT_FUNC
PyInit_xx(void)
{
    return PyModule_Create(&xxmodule);  // calls PyModuleDef_Init internally
}
```

The init function returns a *populated* `PyObject*` (a `PyModuleObject`). On POSIX, this is what `_PyImport_FindSharedFuncptr` resolves via `dlsym(handle, "PyInit_xx")`.

CPython detects single-phase vs multi-phase by inspecting the return value: if it's a `PyModuleObject`, single-phase; if it's a `PyModuleDef` (subclass of `PyModule_Type` initialised with `PyModuleDef_HEAD_INIT`), multi-phase. See `_PyImport_RunModInitFunc` (`Python/importdl.c:386`).

#### 3.5.2 Multi-phase init (PEP 489)

The `PyModuleDef` carries a slot table. From `Modules/xxmodule.c:12807`:

```c
static int xx_exec(PyObject *m)
{
    Null_Type.tp_base = &PyBaseObject_Type;
    Str_Type.tp_base = &PyUnicode_Type;
    if (PyType_Ready(&Xxo_Type) < 0) { return -1; }
    if (ErrorObject == NULL) {
        ErrorObject = PyErr_NewException("xx.error", NULL, NULL);
        if (ErrorObject == NULL) { return -1; }
    }
    int rc = PyModule_AddType(m, (PyTypeObject *)ErrorObject);
    Py_DECREF(ErrorObject);
    if (rc < 0) { return -1; }
    if (PyModule_AddType(m, &Str_Type) < 0) { return -1; }
    if (PyModule_AddType(m, &Null_Type) < 0) { return -1; }
    return 0;
}

static struct PyModuleDef_Slot xx_slots[] = {
    _Py_ABI_SLOT,                                 /* required first slot */
    {Py_mod_exec, xx_exec},
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    {0, NULL},                                    /* sentinel */
};

static struct PyModuleDef xxmodule = {
    PyModuleDef_HEAD_INIT,
    "xx",
    module_doc,
    0,                                            /* m_size = 0, no per-module state */
    xx_methods,
    xx_slots,
    NULL, NULL, NULL
};

PyMODINIT_FUNC PyInit_xx(void)
{
    return PyModuleDef_Init(&xxmodule);
}
```

Multi-phase protocol rules:
- The init function (`PyInit_<name>`) returns the result of `PyModuleDef_Init(&def)`, i.e., the `PyModuleDef*` itself. CPython detects this (it's an instance of `PyModuleDef_Type`, not a `PyModuleObject`).
- CPython then calls `PyModule_FromDefAndSpec(def, spec)` to create an *uninitialized* module. Module state (`m_size > 0`) is allocated here.
- Each slot in `def->m_slots` is run in order. Slots without an entry point are skipped.
- The `Py_mod_exec` slot is the main "init" hook - it gets the module object and adds attributes, types, etc.
- `_Py_ABI_SLOT` is a marker inserted by the build to ensure the build's ABI version matches at load time.

#### 3.5.3 Slot IDs (from `Include/moduleobject.h`)

The slot IDs a module can register:

| Slot ID | Value type | Effect |
|---|---|---|
| `Py_mod_create` | `int (*)(PyObject *, PyModuleDef *)` | Custom module creation (replaces `create_module` machinery) |
| `Py_mod_exec` | `int (*)(PyObject *)` | Main init function (run after creation) |
| `Py_mod_multiple_interpreters` | `int` (`Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED = 0`, `Py_MOD_PER_INTERPRETER_GIL_SUPPORTED = 1`, `Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED = 2`) | Subinterpreter compatibility |
| `Py_mod_gil` | `int` (`Py_MOD_GIL_NOT_USED = 0`) | Module does not need the GIL after init (PEP 703 prep) |
| `Py_mod_free` | `void (*)(PyObject *)` | Free per-module state when module is unloaded (multi-interp support) |
| `Py_mod_state` | `Py_ssize_t` | Optional per-module state size override |

`Py_mod_multiple_interpreters`:
- `Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED` (0): only the main interpreter may import this module.
- `Py_MOD_PER_INTERPRETER_GIL_SUPPORTED` (1): can be loaded in multiple interpreters, with a per-interpreter GIL.
- `Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED` (2): can be loaded in multiple interpreters, sharing the main GIL.

The `_PyImport_CheckSubinterpIncompatibleExtensionAllowed` check in `import_run_extension` (Python/import.c) enforces these flags when crossing from main to subinterpreter.

`Py_mod_gil`: when set to `Py_MOD_GIL_NOT_USED`, the interpreter may drop the GIL after the module's init function returns. `_PyImport_CheckGILForModule` (`Python/import.c:51741`) and `_PyImport_EnableGILAndWarn` handle the warning if the module was actually loaded with the GIL held.

### 3.6 `NamespaceLoader` (`_bootstrap_external.py:41623`)

```python
class NamespaceLoader:
    def __init__(self, name, path, path_finder):
        self._path = NamespacePath(name, path, path_finder)
    def is_package(self, fullname): return True
    def get_source(self, fullname): return ''
    def get_code(self, fullname): return compile('', '<string>', 'exec', dont_inherit=True, module=fullname)
    def create_module(self, spec): pass  # use default semantics
    def exec_module(self, module): pass
    def get_resource_reader(self, module):
        from importlib.readers import NamespaceReader
        return NamespaceReader(self._path)
```

`create_module` and `exec_module` are no-ops - the namespace package is *just* a module object with `__path__` set; it has no executable code.

`get_resource_reader` returns a `NamespaceReader` so `importlib.resources.files(nspackage)` works.

### 3.7 The dispatch from `ModuleSpec` to loader

`ModuleSpec` (`_bootstrap.py:20729`) has these key fields:
- `name`: absolute dotted name
- `loader`: the loader (or `None` for namespace packages)
- `origin`: source/extension path (`'built-in'`/`'frozen'` for those, or a real path)
- `submodule_search_locations`: list of paths the package searches, or `None`
- `_initializing`: True between insert into `sys.modules` and removal
- `_uninitialized_submodules`: list of in-progress child names (for circular import detection)
- `_set_fileattr`: bool - controls whether `__file__` is set
- `_cached`: path to bytecode cache

`module_from_spec(spec)` (`_bootstrap.py:29007`):
```python
def module_from_spec(spec):
    module = None
    if hasattr(spec.loader, 'create_module'):
        module = spec.loader.create_module(spec)
    elif hasattr(spec.loader, 'exec_module'):
        raise ImportError('loaders that define exec_module() '
                          'must also define create_module()')
    if module is None:
        module = _new_module(spec.name)
    _init_module_attrs(spec, module)
    return module
```

---

## 4. Module object model - attribute setting

`_init_module_attrs(spec, module, *, override=False)` (`_bootstrap.py:26484`) sets the module attributes. The order and rules are exactly:

| Attribute | When set | Value |
|---|---|---|
| `__name__` | if `override or __name__ is None` | `spec.name` |
| `__loader__` | if `override or __loader__ is None` | `spec.loader` (with namespace-loader shim if loader is None) |
| `__package__` | if `override or __package__ is None` | `spec.parent` |
| `__spec__` | always | `spec` |
| `__path__` | if `override or __path__ is None` and `spec.submodule_search_locations is not None` | `spec.submodule_search_locations` |
| `__file__` | if `override or __file__ is None` and `spec.has_location` | `spec.origin` |

All assignments are wrapped in `try: ... except AttributeError: pass` because the module might disallow attribute setting.

`override=True` is used by `_exec(spec, module)` (the second-pass init used by `importlib.reload()`).

The namespace package hack at `_init_module_attrs:14`: when the spec has `loader=None` but non-`None` `submodule_search_locations`, `_init_module_attrs` synthesises a `NamespaceLoader` and assigns it to `spec.loader`, so the module's `__loader__` looks reasonable. The comment in source notes this was added for `bpo-32305`.

`spec.parent` is computed from `name`:
- If the spec is a package (`submodule_search_locations is not None`), `parent = name`.
- Otherwise `parent = name.rpartition('.')[0]`.

For example: spec `numpy.linalg` (not a package) → `parent = 'numpy'`. Spec `numpy` (a package) → `parent = 'numpy'`. Spec `numpy.linalg._umath_linalg` (not a package) → `parent = 'numpy.linalg'`.

---

## 5. `sys.modules` semantics

### 5.1 Initialisation

`sys.modules` is created during interpreter startup as a dict in `Python/import.c:5701` (`_PyImport_InitModules`). It is populated by `_PyImport_FixupBuiltin` for `sys` and `builtins`, by `_PyImport_FrozenBootstrap` for the bootstrap frozen modules, then by `_setup()` (`_bootstrap.py:56049`) which iterates `sys.modules.items()` and sets specs/loaders for already-known modules.

### 5.2 The `sys.modules` dance in `_load_unlocked`

`_load_unlocked(spec)` (`_bootstrap.py:31374`):

```python
def _load_unlocked(spec):
    module = module_from_spec(spec)
    spec._initializing = True
    try:
        sys.modules[spec.name] = module
        try:
            if spec.loader is None:
                if spec.submodule_search_locations is None:
                    raise ImportError('missing loader', name=spec.name)
                # A namespace package so do nothing.
            else:
                spec.loader.exec_module(module)
        except:
            try:
                del sys.modules[spec.name]
            except KeyError:
                pass
            raise
        # Move the module to the end of sys.modules for shutdown ordering.
        module = sys.modules.pop(spec.name)
        sys.modules[spec.name] = module
        _verbose_message('import {!r} # {!r}', spec.name, spec.loader)
    finally:
        spec._initializing = False
    return module
```

Critical rules:

1. **`sys.modules[spec.name] = module` happens BEFORE `exec_module`.** This is the "partially initialized module is visible during its own import" rule. Any reentrant import (circular) that does `sys.modules.get(name)` will see the not-yet-executed module.
2. **`spec._initializing = True` is set BEFORE the sys.modules insert.** `_is_initializing(m)` checks this flag.
3. **On exception**, `sys.modules[spec.name]` is removed. This is what "removal from sys.modules on failure" means.
4. **After success**, the entry is moved to the end of `sys.modules` (`pop` + reinsert). This matters for clean-up order at shutdown: the last-inserted module is the first to be torn down. Note: this means `sys.modules` is insertion-ordered at end-of-load.
5. **`spec._initializing = False` is in `finally`** - so even if `del sys.modules` raises, the flag is reset.

### 5.3 The `import a.b as c` vs `import a.b` distinction

Both statements bind `a.b` to `c` in the local namespace. Both go through `__import__` with `fromlist=()`, so both end up calling `_gcd_import('a.b')` and returning `sys.modules['a']` (the topmost package). The C compiler emits `IMPORT_NAME('a.b')` followed by `STORE_NAME('c')`. There is no difference at the import-system level - the difference is purely in what the *bytecode does with the returned module object* (in both cases it stores it; the original `a.b` is rebound to `c`).

### 5.4 Fast-path: module already in `sys.modules`

In `_find_and_load` (`_bootstrap.py:48212`), the first check is:
```python
module = sys.modules.get(name, _NEEDS_LOADING)
if module is _NEEDS_LOADING or _is_initializing(module):
    ... go through locking/loading ...
else:
    # already loaded and not initializing - return it
```

For the *partially initialized* case (module in sys.modules with `__spec__._initializing=True`), the path goes into the locking branch and waits for the loader to finish, OR (if a deadlock is detected) accepts the partial module.

### 5.5 Submodule attribute binding

In `_find_and_load_unlocked` (`_bootstrap.py:44173`), after a successful load, the parent module gets the child as an attribute:

```python
if parent:
    parent_module = sys.modules[parent]
    try:
        setattr(parent_module, child, module)
    except AttributeError:
        msg = f"Cannot set an attribute on {parent!r} for child module {child!r}"
        _warnings.warn(msg, ImportWarning)
```

So `sys.modules['a.b']` is bound, AND `sys.modules['a'].b = sys.modules['a.b']`. Both are kept in sync. Note the `ImportWarning` for "Cannot set an attribute" - this fires for unusual modules (e.g. a class-based module replacement, or a C module whose `__getattr__` raises).

### 5.6 The C-level sys.modules critical section

`import_add_module_lock_held` (`Python/import.c:12077`) wraps dict insertion in `Py_BEGIN_CRITICAL_SECTION(modules)`. This is the per-interpreter critical-section lock that the import system relies on (separate from the global import lock - see §11).

---

## 6. Relative imports

### 6.1 The `__package__` machinery

`__import__(name, globals, locals, fromlist, level)` first computes the package:

- If `level == 0`: pass `package=None`, `level=0` to `_gcd_import`.
- If `level > 0`: call `_calc___package__(globals)` (`_bootstrap.py:53325`).

`_calc___package__(globals)`:
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

For `from . import b` in `pkg/sub/mod.py`, the compiler emits `IMPORT_NAME('b', level=1)` and the calling frame's globals contain `__package__ = 'pkg.sub'` (or `__spec__.parent = 'pkg.sub'`).

For code with `from .b import c` in `pkg/__init__.py`, the compiler emits `IMPORT_NAME('.b', level=1)` which expands to `pkg.b`.

### 6.2 `_resolve_name(name, package, level)`

`_bootstrap.py:41509`:
```python
def _resolve_name(name, package, level):
    """Resolve a relative module name to an absolute one."""
    bits = package.rsplit('.', level - 1)
    if len(bits) < level:
        raise ImportError('attempted relative import beyond top-level package')
    base = bits[0]
    return f'{base}.{name}' if name else base
```

The math: `package.rsplit('.', level - 1)` splits off `level-1` from the right. So:
- `package='a.b.c'`, `level=1` → `bits=['a.b.c']` → `base='a.b.c'`, full=`'a.b.c.<name>'`.
- `package='a.b.c'`, `level=2` → `bits=['a.b', 'c']` → `base='a.b'`, full=`'a.b.<name>'`.
- `package='a.b.c'`, `level=3` → `bits=['a', 'b', 'c']` → `base='a'`, full=`'a.<name>'`.
- `package='a.b.c'`, `level=4` → `bits=['a', 'b', 'c']` → `len(bits)=3 < level=4` → raise.

For `from . import x` (the "import from current package" form), `name=''`, so the return is `base` - i.e., the package itself. That's why `from . import x` imports `x` from the current package.

### 6.3 Public `importlib.util.resolve_name`

`Lib/importlib/util.py:716`:
```python
def resolve_name(name, package):
    if not name.startswith('.'):
        return name
    elif not package:
        raise ImportError(f'no package specified for {repr(name)} '
                          '(required for relative module names)')
    level = 0
    for character in name:
        if character != '.':
            break
        level += 1
    return _resolve_name(name[level:], package, level)
```

This handles the dotted-prefix syntax (`.foo`, `..bar`, `...baz`). It first strips the dots, computes the level, then delegates to `_resolve_name`.

### 6.4 `from import import name` with level=0

`from os import path` at the top of `__main__` works because `__name__ == '__main__'`, `__package__` is empty/`None`, `level=0` (no leading dots), so `_gcd_import('os')` is called directly. The implicit `globals()['__package__']` is ignored when level=0.

---

## 7. `from X import Y` semantics - `_handle_fromlist`

`_bootstrap.py:51823`:

```python
def _handle_fromlist(module, fromlist, import_, *, recursive=False):
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

Behaviour summary:
1. Validate every fromlist item is a string.
2. `'*'` expands to `module.__all__` (when present); recursion prevents infinite loops on `__all__` containing `'*'`.
3. For every other name `x`:
   - If `hasattr(module, x)` is True: do nothing (the attribute is already there, possibly from a previous import).
   - Else: try `import(module.name + '.' + x)` - i.e., look for a submodule.
   - On `ModuleNotFoundError`: ignore it ONLY if `exc.name == '<module>.<x>'` AND `sys.modules.get('<module>.<x>', _NEEDS_LOADING) is not None`. The "is not None" here is critical: `sys.modules.get` returns `None` if missing, so the test passes only if the submodule **exists in sys.modules** (even partially-initialized). This is the "import from list swallows only ImportError-as-not-found, not actual errors" rule.
   - Any other exception propagates.

### 7.1 The submodule vs attribute rule

`from a import b` where `a.b` is both an attribute of `a` AND a submodule:
- The attribute is checked first via `hasattr(module, x)`. If true, `_handle_fromlist` does NOT trigger a submodule import. So `from os import path` does not trigger `import os.path` - `path` is already an attribute of `os`.
- The submodule `os.path` IS still in `sys.modules` (it was imported at interpreter startup by `os` itself), but no fresh import attempt happens.

### 7.2 The `hasattr(module, x)` subtlety

`hasattr` returns True if `getattr` doesn't raise `AttributeError`. So:
- A module-level `__getattr__` (PEP 562) that returns something for `x` makes `from a import x` work without importing `a.x`.
- An `AttributeError` from `__getattr__` triggers the submodule import attempt.

### 7.3 IMPORT_FROM bytecode

`IMPORT_FROM(namei)` pops the top-of-stack module (from a prior `IMPORT_NAME`), gets `module.namei`, and pushes the result. If `getattr` raises `AttributeError`, the CPython interpreter falls back to `sys.modules[module.__name__ + '.' + namei]` and uses that. If neither yields an attribute, `ModuleNotFoundError` is raised.

This is the interpreter-level counterpart to `_handle_fromlist` for the case where `module` does NOT have `__path__` (so `_handle_fromlist` is not called by `__import__`).

---

## 8. Namespace packages (PEP 420)

### 8.1 `NamespacePath` class

`_bootstrap_external.py:38298`:

```python
class NamespacePath:
    """Represents a namespace package's path."""
    _epoch = 0   # bumped by PathFinder.invalidate_caches()

    def __init__(self, name, path, path_finder):
        self._name = name
        self._path = path
        self._last_parent_path = tuple(self._get_parent_path())
        self._last_epoch = self._epoch
        self._path_finder = path_finder

    def _find_parent_path_names(self):
        parent, dot, me = self._name.rpartition('.')
        if dot == '':
            return 'sys', 'path'           # top-level: parent path is sys.path
        return parent, '__path__'           # nested: parent.__path__

    def _get_parent_path(self):
        parent_module_name, path_attr_name = self._find_parent_path_names()
        try:
            module = sys.modules[parent_module_name]
        except KeyError as e:
            raise ModuleNotFoundError(
                f"{parent_module_name!r} must be imported before finding {self._name!r}.",
                name=parent_module_name,
            ) from e
        else:
            return getattr(module, path_attr_name)

    def _recalculate(self):
        parent_path = tuple(self._get_parent_path())
        if parent_path != self._last_parent_path or self._epoch != self._last_epoch:
            spec = self._path_finder(self._name, parent_path)
            if spec is not None and spec.loader is None:
                if spec.submodule_search_locations:
                    self._path = spec.submodule_search_locations
            self._last_parent_path = parent_path
            self._last_epoch = self._epoch
        return self._path
```

`NamespacePath` is a *live* list-like object. Every time you iterate (`for p in ns.__path__`), `__getitem__`, `__len__`, `__contains__`, `append`, `__setitem__`, it triggers `_recalculate()` which re-runs `path_finder(self._name, parent_path)`. This is how namespace packages dynamically discover new portions when `sys.path` changes at runtime.

The `self._epoch` mechanism is the cache-bust hook: `PathFinder.invalidate_caches()` increments `NamespacePath._epoch`, so the next iteration of any namespace path re-runs the search.

`_path_finder` is `PathFinder._get_spec` (the closure `_bootstrap_external.py:63`).

### 8.2 PEP 420 rules implemented

1. **No `__init__.py**: a directory may serve as a namespace package if it has no `__init__.py`. `FileFinder.find_spec` returns a spec with `loader=None`, `submodule_search_locations=[base_path]` in this case.
2. **Multiple portions**: a name may be found across multiple `sys.path` entries; all portions are concatenated into the namespace package's `__path__`. `PathFinder._get_spec` accumulates them; the resulting spec has `submodule_search_locations=NamespacePath(name, all_portions, _get_spec)`.
3. **Precedence**: if any of the contributing directories has a regular package (`__init__.py`), the namespace package is shadowed by that regular package. This happens because `FileFinder.find_spec` checks `__init__.{suffix}` first; if found, returns a spec with a non-None loader, which makes `PathFinder._get_spec` return early with that spec.
4. **Empty name**: `import a.b.c` where `a.b.c` is a namespace package - `_find_and_load_unlocked` calls `module_from_spec(spec)` which calls `_init_module_attrs(spec, module)`; since `spec.loader is None` and `submodule_search_locations is not None`, the loader-exec branch is skipped. The result is a module with `__path__ = NamespacePath(...)` and no other state.
5. **Submodule search**: when you do `import a.b.c` (c is a submodule of a), `_find_and_load_unlocked` looks up `parent_module.__path__` to find c. If `a.b` is a namespace package, `parent_module.__path__` is a `NamespacePath` - iteration over it triggers the recalculation, which finds `a.b.c` even if `a.b` has no `__init__.py`.
6. **`__file__` and `__path__` for namespace packages**: namespace packages have `__file__=None` (set explicitly by `_init_module_attrs`) and `__path__=NamespacePath(...)`. `__loader__` is a `NamespaceLoader` instance.

### 8.3 Value of `__package__` in a namespace package

A namespace package's `__spec__.parent` is its own name (because `submodule_search_locations is not None`). So `__package__ == __name__` for a namespace package. This is the same as for a regular package.

E.g. namespace package `zope` (no `__init__.py` anywhere): `zope.__package__ == 'zope'`, `zope.__spec__.parent == 'zope'`.

---

## 9. Frozen modules

### 9.1 Where frozen modules live

`Python/frozen.c`:
```c
static const struct _frozen bootstrap_modules[] = {
    {"_frozen_importlib", _Py_M__importlib__bootstrap, (int)sizeof(_Py_M__importlib__bootstrap), false},
    {"_frozen_importlib_external", _Py_M__importlib__bootstrap_external, (int)sizeof(_Py_M__importlib__bootstrap_external), false},
    {"zipimport", _Py_M__zipimport, (int)sizeof(_Py_M__zipimport), false},
    {"_pybuiltins", _Py_M__builtins, (int)sizeof(_Py_M__builtins), false},
    {0, 0, 0}
};

static const struct _frozen stdlib_modules[] = {
    {"abc", ...},
    {"codecs", ...},
    {"io", ...},
    {"_collections_abc", ...},
    {"_sitebuiltins", ...},
    {"genericpath", ...},
    {"ntpath", ...},
    {"posixpath", ...},
    {"os", ...},
    {"site", ...},
    {"stat", ...},
    {"linecache", ...},
    {"importlib.util", ...},
    {"importlib.machinery", ...},
    {"runpy", ...},
    {0, 0, 0}
};

const struct _frozen *_PyImport_FrozenBootstrap = bootstrap_modules;
const struct _frozen *_PyImport_FrozenStdlib = stdlib_modules;
```

The `_Py_M__<name>` byte arrays are generated by `Tools/build/freeze_modules.py` (run via `make regen-frozen` or `make regen-importlib`).

The `_frozen_importlib` and `_frozen_importlib_external` modules are special - they ARE the importlib bootstrap, baked into the interpreter as bytes. This is what makes the bootstrap possible: even before any filesystem or builtin module can be loaded, the import system has its own implementation as frozen bytes.

### 9.2 The aliases

`Python/frozen.c:121`:
```c
static const struct _module_alias aliases[] = {
    {"_frozen_importlib", "importlib._bootstrap"},
    {"_frozen_importlib_external", "importlib._bootstrap_external"},
    {"_pybuiltins", "builtins"},
    {"__hello_alias__", "__hello__"},
    {"__phello_alias__", "__hello__"},
    {"__phello_alias__.spam", "__hello__"},
    {"__phello__.__init__", "<__phello__"},
    {"__phello__.ham.__init__", "<__phello__.ham"},
    {"__hello_only__", NULL},
    {0, 0}
};
```

Aliases map a frozen module name to its canonical origin name. `resolve_module_alias` (in `Python/import.c:94209`) returns true if the name matches an alias and writes the canonical name into `info->origname`. The FrozenImporter uses this to set `__file__` based on the canonical origin.

### 9.3 Bootstrap order

`init_importlib` in `Python/import.c:106390`:

```c
static int
init_importlib(PyThreadState *tstate, PyObject *sysmod)
{
    if (PyImport_ImportFrozenModule("_frozen_importlib") <= 0) {
        return -1;
    }
    PyObject *importlib = PyImport_AddModuleRef("_frozen_importlib");
    IMPORTLIB(interp) = importlib;

    PyObject *imp_mod = bootstrap_imp(tstate);   // creates the _imp module
    if (_PyImport_SetModuleString("_imp", imp_mod) < 0) {
        Py_DECREF(imp_mod);
        return -1;
    }

    PyObject *value = PyObject_CallMethod(importlib, "_install",
                                          "OO", sysmod, imp_mod);
    Py_DECREF(imp_mod);
    Py_DECREF(value);

    return 0;
}
```

So the sequence is:
1. Load `_frozen_importlib` from the bootstrap frozen table (no Python source needed).
2. Set `IMPORTLIB(interp)` to that module.
3. Create the `_imp` C extension module (containing `create_builtin`, `exec_builtin`, `find_frozen`, `get_frozen_object`, `is_builtin`, `is_frozen`, `is_frozen_package`, `create_dynamic`, `exec_dynamic`, `source_hash`, `pyc_magic_number_token`, `extension_suffixes`, etc. - `_imp_module_exec` lives in `Python/import.c`).
4. Call `_frozen_importlib._install(sys, _imp)` which:
   - Calls `_setup(sys, _imp)` - populates specs on existing modules, loads `_thread`, `_warnings`, `_weakref`.
   - Appends `BuiltinImporter` and `FrozenImporter` to `sys.meta_path`.

5. Later (during site init), `_frozen_importlib._install_external_importers()` is called which:
   - Imports `_frozen_importlib_external`.
   - Calls `_install(bootstrap_module)` which appends `PathFinder` to `sys.meta_path` and adds `FileFinder.path_hook(...)` to `sys.path_hooks`.

### 9.4 `look_up_frozen` and the search order

`Python/import.c:98561` (function `look_up_frozen`):
```c
const struct _frozen *p;
// Always check bootstrap first.
for (p = _PyImport_FrozenBootstrap; ; p++) { /* ... */ }
// Then any user-added frozen modules.
if (PyImport_FrozenModules != NULL) {
    for (p = PyImport_FrozenModules; ; p++) { /* ... */ }
}
// Then stdlib frozen.
if (use_frozen()) {
    for (p = _PyImport_FrozenStdlib; ; p++) { /* ... */ }
    for (p = _PyImport_FrozenTest; ; p++) { /* ... */ }
}
return NULL;
```

`PyImport_FrozenModules` is a public pointer that embedding applications can set to override the frozen module table. `use_frozen()` checks `PyConfig.use_frozen_modules` (default True; can be disabled with `-X frozen_modules=off` or programmatically).

### 9.5 Frozen vs builtin

- A **builtin** module is one whose `PyInit_<name>` is in the inittab (`PyImport_Inittab`) - built into the interpreter binary, loaded via the C-level builtin mechanism (`create_builtin` → `lookup_inittab_entry` → `import_run_extension`).
- A **frozen** module is one whose compiled bytecode is embedded in the binary as a `struct _frozen` entry. The data is unmarshalled to a code object at load time and `exec()`'d into the module's `__dict__`.
- Both use `BuiltinImporter.find_spec` (for builtins) and `FrozenImporter.find_spec` (for frozen). Both have `origin` set to the literal string `'built-in'` or `'frozen'`.
- `sys.builtin_module_names` contains only builtin names (not frozen). `_imp.is_builtin(name)` returns True only for builtins; `_imp.is_frozen(name)` returns True for both builtins (which can also be looked up as frozen if registered in both tables) and frozen.
- Frozen modules can be packages (e.g. `__phello__` in the test table) - they get `__path__` set to `[sys._stdlib_dir/<name>]`.

---

## 10. Extension module loading on POSIX

### 10.1 The full path from import to `_init`

```
_extension_loader_info_init(name, spec, origin=DYNAMIC)   # Python/importdl.c:99
  -> info.name = "<dotted.module.name>"
  -> info.name_encoded = shortname (after last dot) ASCII-encoded,
                          '-' replaced with '_'
  -> info.filename = spec.origin   # the full path to the .so
  -> info.filename_encoded = PyUnicode_EncodeFSDefault(spec.origin)

_PyImport_GetModuleExportHooks(info, fp, &modinit, &modexport)  # importdl.c:338
  -> findfuncptr("PyModExport", shortname, info, fp)  # try PyModExport_<shortname> first
  -> if not found, findfuncptr("PyInit", shortname, info, fp)  # PyInit_<shortname>

_PyImport_RunModInitFunc(p0, info, &res)   # importdl.c:386
  -> const char *oldcontext = _PyImport_SwapPackageContext(info->newcontext);
  -> PyObject *m = p0();                   # CALL the init function
  -> _PyImport_SwapPackageContext(oldcontext);
  -> if m == NULL: SINGLEPHASE (set PyErr if not set)
     else if PyObject_TypeCheck(m, &PyModuleDef_Type): MULTIPHASE; res.def = (PyModuleDef*)m
     else if non-ASCII name: error
     else: SINGLEPHASE; res.module = m; res.def = _PyModule_GetDefOrNull(m)
```

For POSIX:
```
_PyImport_FindSharedFuncptr(prefix, shortname, path_buf, fp)   # dynload_shlib.c:55
  -> char funcname[258] = LEAD_UNDERSCORE + prefix + "_" + shortname   # "PyInit_xx" or "PyModExport_xx"
  -> void *handle = dlopen(pathname, dlopenflags);     # dlopenflags = _PyImport_GetDLOpenFlags(...)
  -> dl_funcptr p = (dl_funcptr) dlsym(handle, funcname);   # returns NULL if symbol missing
  -> return p;
```

Where `dlopenflags` defaults to `RTLD_NOW` (with `_PyImport_GetDLOpenFlags` as the read accessor and `_PyImport_SetDLOpenFlags` for the setter). The `LEAD_UNDERSCORE` macro adds `"_"` on OpenBSD/NetBSD (non-ELF), empty elsewhere.

### 10.2 The shared-library search path

The search path is NOT `LD_LIBRARY_PATH`. The file's full path comes from `spec.origin` (set by `FileFinder` when it sees the matching suffix in a path entry's directory). For an extension installed in `site-packages/foo.cpython-314-x86_64-linux-gnu.so`:

1. `FileFinder.find_spec('foo', target=None)` walks its `_loaders` list.
2. For `ExtensionFileLoader` and each suffix in `EXTENSION_SUFFIXES` (which is `_imp.extension_suffixes()`), it builds `<path>/foo<suffix>` and tests `os.path.isfile`.
3. The first match is used as `spec.origin`. That absolute path is passed to `dlopen`.

The list of suffix candidates comes from `_PyImport_DynLoadFiletab` (`Python/dynload_shlib.c:30`):

```c
const char *_PyImport_DynLoadFiletab[] = {
    ".cpython-314-x86_64-linux-gnu.so",  // SOABI
    ".abi3.so",                          // stable ABI (PYTHON_ABI_STRING)
    ".abi3t.so",                         // stable ABI, free-threading
    ".so",                               // plain
    NULL,
};
```

Note: a file in `sys.path` directory is loaded by `dlopen(<path>/foo.so)` - no `LD_LIBRARY_PATH` lookup because `dlopen` with an absolute path (or `./`-prefixed relative path) does not search the dynamic linker path. `_PyImport_FindSharedFuncptr` (`dynload_shlib.c:65`) prepends `./` if there's no `/` in the filename - this forces `dlopen` to treat it as a relative path in CWD rather than searching `LD_LIBRARY_PATH`.

### 10.3 Init-function discovery (PEP 489)

For multi-phase modules, the symbol is `PyModExport_<shortname>` (the "modexport" hook, see `Python/importdl.c:18`):
```c
static const struct hook_prefixes ascii_only_prefixes = {
    "PyInit", "PyModExport"};
static const struct hook_prefixes nonascii_prefixes = {
    "PyInitU", "PyModExportU"};   // for non-ASCII module names (Punycode)
```

For non-ASCII module names (e.g. `foo.бар`), the encoded shortname is Punycode (`encoded = PyUnicode_AsEncodedString(name, "punycode", NULL)`) with `-` → `_`, and the symbol becomes `PyInitU_<encoded>`. Non-ASCII names require multi-phase init - `_PyImport_RunModInitFunc` rejects single-phase init for non-ASCII names.

### 10.4 Subinterpreter handling

`import_run_extension` (`Python/import.c:66730`) is a complex function (~250 lines). Key behaviour:

1. Switch to the main interpreter to run the init function (so single-phase init's static type creation happens in a known-good allocator).
2. Detect single vs multi-phase from the init return.
3. For single-phase: copy the dict via `def->m_base.m_copy` for reload; cache the def by `(filename, name)` in `_PyRuntime.imports.extensions`.
4. For multi-phase: `PyModule_FromDefAndSpec(def, spec)` to create a fresh per-interpreter module.
5. Switch back to the original interpreter.

This is what makes the GIL-disabled (free-threaded) build of Python 3.13+ able to use subinterpreters with their own GIL.

### 10.5 The `extensions_cache`

`Python/import.c` has:
- `_extensions_cache_init(interp)` - hash table mapping `(path, name)` → `struct extensions_cache_value { PyModuleDef *def; ... }`.
- `_extensions_cache_get(path, name)` - used by `import_find_extension` to fast-path reloading single-phase extensions without calling the init function again.
- `update_global_state_for_extension(...)` - populates the cache after a successful single-phase init.

`reload_singlephase_extension` (`Python/import.c:61502`) reads from the cache to recreate a module from `def->m_base.m_copy` (the preserved dict).

---

## 11. The import lock

### 11.1 Two levels of locking

**Global import lock** (`_PyRecursiveMutex_Lock(&IMPORT_LOCK(interp))`): serialises all finders (`_ImportLockContext` is a Python wrapper used inside `_find_spec` and elsewhere).

**Per-module RLock** (`_ModuleLock`): serialises the load of a single module, allowing re-entry from the same thread.

### 11.2 `_ModuleLock` (`_bootstrap.py:7854`)

```python
class _ModuleLock:
    def __init__(self, name):
        self.lock = _thread.RLock()
        self.wakeup = _thread.allocate_lock()
        self.name = name
        self.owner = None
        self.count = []   # list of True, supports re-entrant acquire
        self.waiters = []
```

A full reproduction is given in `_bootstrap.py:7854-15773`. Critical behaviours:

1. **Re-entrant on the same thread**: `self.count.append(True)` is appended for each acquire; `self.owner = tid` is the thread id. A thread holding the lock can re-acquire it without blocking.
2. **Deadlock detection**: `has_deadlock()` walks the global `_blocking_on` dict (a `_WeakValueDictionary` mapping `tid → ModuleLock`) to detect cycles: thread A waiting on lock L1, where L1 is owned by thread B, where B is waiting on a lock L2, where L2 is owned by A. Raises `_DeadlockError`.
3. **Waiters counter**: increments when a thread blocks on `self.wakeup.acquire()`. `release()` pops one waiter and releases `self.wakeup` to unblock one.
4. **The lock is per-module**, allocated lazily in `_get_module_lock` (line 16632) and stored in a module-level `_module_locks` dict (a `WeakValueDictionary`). When the lock's reference count drops to zero, a weakref callback removes it from the dict.

### 11.3 The deadlock avoidance dance in `_find_and_load`

`_bootstrap.py:48212`:

```python
def _find_and_load(name, import_, *, lazy_submodule=False):
    module = sys.modules.get(name, _NEEDS_LOADING)
    if module is _NEEDS_LOADING or _is_initializing(module):
        if module is not _NEEDS_LOADING:
            # Already in sys.modules, but partial. Wait.
            lock = _get_module_lock(name)
            try:
                lock.acquire()
            except _DeadlockError:
                # Accept partial module.
                pass
            else:
                # Re-check sys.modules under lock.
                try:
                    module = sys.modules.get(name, _NEEDS_LOADING)
                finally:
                    lock.release()

        if module is _NEEDS_LOADING:
            # No one is loading; we are.
            _resolve_parents(name, import_)   # CRUCIAL: do this BEFORE taking name's lock.
            lock = _get_module_lock(name)
            try:
                lock.acquire()
            except _DeadlockError:
                module = sys.modules.get(name, _NEEDS_LOADING)
                if module is _NEEDS_LOADING:
                    raise
            else:
                try:
                    module = sys.modules.get(name, _NEEDS_LOADING)
                    if module is _NEEDS_LOADING:
                        return _find_and_load_unlocked(name, import_, ...)
                finally:
                    lock.release()
    else:
        # Already in sys.modules, fully initialized.
        ...
    if module is None:
        raise ModuleNotFoundError(f'import of {name} halted; None in sys.modules', name=name)
    return module
```

The pattern is "always check sys.modules first under the lock; accept partial on deadlock."

### 11.4 `_resolve_parents` - why deadlock avoidance works

`_bootstrap.py:47332`:

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

`_resolve_parents` is called BEFORE the module takes its own lock. This breaks the deadlock scenario where thread T1 holds lock A and wants lock B, while thread T2 holds lock B and wants lock A - because the parent-package load happens without name's lock held. This addresses `gh-83065` and `gh-159963`.

### 11.5 `_lock_unlock_module(name)` (`_bootstrap.py:17937`)

Acquire and immediately release the module lock. Used to wait for another thread to finish loading the module. Catches `_DeadlockError` to accept partial modules.

### 11.6 The "frame stripping" trick

`_call_with_frames_removed(f, *args, **kwds)` (`_bootstrap.py:18480`) is a no-op Python wrapper. Its purpose is to be a recognisable call site for `remove_importlib_frames` in `Python/import.c:113863`, which walks the traceback and removes frames from `importlib._bootstrap` and `importlib._bootstrap_external` that end with a `_call_with_frames_removed` call.

This is purely cosmetic for user tracebacks.

### 11.7 The C-level import lock

The Python-level `_ModuleLock` is separate from the C-level global import lock. The C-level lock is `_PyRecursiveMutex_Lock(&IMPORT_LOCK(interp))` (`Python/import.c:5220`). It's exposed via:
- `_imp.acquire_lock()` / `_imp.release_lock()` - the `_imp_lock_held_impl`, `_imp_acquire_lock_impl`, `_imp_release_lock_impl` methods.
- `_get_module_lock` calls `_imp.acquire_lock()` around the `_module_locks` dict access (line 16644).

The C-level lock is recursive (so `acquire_lock` can be called multiple times from the same thread) and is independent of the GIL. It's used to protect the module-lock dict itself.

---

## 12. `import` statement bytecode semantics

CPython compiles `import X` and `from X import Y` into a small set of bytecodes:

### 12.1 `IMPORT_NAME(namei)`

Argument: index into the names tuple. Pops nothing, pushes the module returned by `builtins.__import__(name, globals, locals, fromlist, level)`. The `fromlist` and `level` operands are pushed by the compiler as hidden items on the stack:
- For `import a.b`: `fromlist` = empty tuple, `level` = 0.
- For `import a.b as c`: same as above.
- For `from a.b import c, d`: `fromlist` = `('c', 'd')`, `level` = 0.
- For `from . import b`: `name` = `'b'`, `level` = 1.
- For `from .. import b`: `level` = 2.

The compiler materialises these as a `(name, fromlist, level)` triple via `compiler_make_import_block` (in `Python/compile.c`); the bytecode evaluation effectively does `builtins.__import__(name, globals, locals, fromlist, level)`.

### 12.2 `IMPORT_FROM(namei)`

Pops a module from the stack, pushes `getattr(module, name)`. On `AttributeError`, falls back to `sys.modules[module.__name__ + '.' + name]`. If that lookup succeeds, the result is pushed; otherwise `ModuleNotFoundError` is raised.

So `from os import path` works even if `path` is a submodule that hasn't been imported yet, because the IMPORT_FROM fallback imports `os.path` from `sys.modules`. But it does NOT trigger a fresh import - it only checks `sys.modules`. If `os.path` was never imported at all, the `getattr` succeeds (because `os.path` IS an attribute of `os`), so no `sys.modules` lookup is needed.

### 12.3 `IMPORT_STAR(namei)`

Pops a module from the stack. Equivalent to `from <module> import *`. Calls `__import__(<module>, globals, locals, [], 0)`, then iterates `module.__all__` (or `dir(module)` if `__all__` is missing) and binds each name. Names starting with `_` are skipped unless they appear in `__all__`.

Note: `IMPORT_STAR` uses an empty `fromlist` and `level=0`. The `__import__` call returns the topmost package (e.g. `os`, not `os.path`). Then the bytecode reads each attribute from that module. This means `from os.path import *` first calls `__import__('os.path', ...)` which returns `sys.modules['os']`, then iterates `os.__all__` (or `dir(os)`) and binds names from `os`, NOT `os.path`. To import everything from a submodule, you'd need `from os.path import *` - which the compiler compiles as `IMPORT_NAME('os.path')` followed by `IMPORT_STAR` operating on the `os.path` module.

### 12.4 `STORE_NAME` / `STORE_FAST`

After `IMPORT_NAME`, the result is bound by a follow-up `STORE_NAME`, `STORE_FAST`, `STORE_GLOBAL`, or `STORE_DEREF`. The `as c` suffix in `import a.b as c` simply changes the STORE target to `c` instead of `a`.

---

## 13. `__import__` keyword arguments

`__import__(name, globals=None, locals=None, fromlist=(), level=0)`. From `_bootstrap.py:54308`:

| Parameter | Type | Used? | Effect |
|---|---|---|---|
| `name` | `str` | required | Module name to import (may be relative: `'.foo'`, `'..bar'`) |
| `globals` | `dict` or `None` | optional | The calling frame's globals. Used ONLY to compute `__package__`/`__spec__.parent` when `level > 0`. Ignored at `level=0`. |
| `locals` | any | ignored | Kept for API compatibility only. |
| `fromlist` | iterable of `str` | optional | Names to import as attributes of the returned module (for `from X import Y`). Empty for plain `import X`. |
| `level` | `int` | required | Number of dots in a relative import. `0` = absolute. Negative raises `ValueError`. |

### 13.1 How `globals['__name__']` and `globals['__package__']` are consulted

When `level > 0`:
1. Compute `package = _calc___package__(globals)`.
2. `_calc___package__` reads `globals.get('__package__')` first.
3. If that's `None`, it falls back to `globals.get('__spec__').parent`.
4. If both are missing, it issues an `ImportWarning` and uses `globals['__name__'].rpartition('.')[0]` (the parent's name from `__name__`). For a top-level module, `__name__` has no dot, so `rpartition('.')[0]` returns `''`, and `_sanity_check` raises `ImportError('attempted relative import with no known parent package')`.

### 13.2 `level=0` ignores globals

```python
if level == 0:
    module = _gcd_import(name)
```

`globals` is not consulted. This means:
- `from os import path` at top of `__main__` works regardless of `__main__.__package__`.
- Inside `pkg/__init__.py`, `from os import path` also works (level=0, no relative needed).
- Only `from . import sibling` / `from .sub import x` (level>=1) uses globals.

### 13.3 The C-level port

`PyImport_ImportModuleLevelObject` (`Python/import.c:123448`) takes `name, globals, locals, fromlist, level` and follows the same algorithm - except it does the work inline rather than calling back into Python.

---

## 14. `sys.path` initialisation

### 14.1 The startup sequence

1. **C-side path construction** (`Python/getpath.c`, not fetched but well-documented): builds the default `sys.path` from compiled-in paths (`PYTHONPATH` env var, install prefix, executable path, `Modules/config.c` defines).
2. **`Py_Initialize` → `_PyImport_InitCore`** (`Python/import.c:148035`): creates `sys.modules`, `sys.path`, etc.
3. **`init_importlib`** (line 106390): loads `_frozen_importlib` and the `_imp` module, calls `_install`.
4. **`site.py:main`** (`Lib/site.py:41371`, called by the bootstrap at end of `_Py_InitializeEx`): extends `sys.path` with `site-packages`, `.pth` files, etc.

### 14.2 `PYTHONPATH`

`getpath.c` reads the `PYTHONPATH` environment variable. It splits on the platform's path separator (`:` on POSIX, `;` on Windows) and prepends each entry to `sys.path`. The exact order is determined by `getpath.c`'s algorithm.

### 14.3 `python -m` vs `python script.py` - the `sys.path[0]` difference

- `python script.py`: `sys.path[0]` = the directory containing `script.py` (the script's dirname, resolved to absolute path).
- `python -m foo.bar`: `sys.path[0]` = `''` (empty string), which `PathFinder._path_importer_cache('')` (line 42464) treats as the current working directory at the moment of import (CWD is fetched fresh on each call, not cached, to handle `os.chdir`).

So `python -m foo` adds CWD to `sys.path[0]`, while `python foo.py` adds the script's directory.

### 14.4 `site.py` and `.pth` files

`Lib/site.py:main` (line 41371) is called automatically when `site` is imported (which the interpreter does during startup unless `-S` is given). It:

1. Removes duplicates from `sys.path` via `removeduppaths()`.
2. Calls `_venv(state)` if running in a venv (adds the venv's site-packages).
3. Calls `state.addusersitepackages()` and `state.addsitepackages()`.
4. Calls `state.process()`:
   - `_extend_syspath()`: appends sitedirs and `.pth`-line paths to `sys.path`.
   - `_exec_imports()`: for each `.pth` file with `import x` lines (DEPRECATED, silenced in 3.18/3.19, warned in 3.20+), `exec(line)`.
   - `_execute_start_entrypoints()`: for each `.start` file, runs entry points like `pkg.mod:func()` (PEP 829).

The `.pth` file syntax: one path per line; lines starting with `#` are comments; `import xyz` lines (deprecated) get exec'd; lines starting with `import` will be ignored/warned in future.

### 14.5 `sys.path_hooks` defaults

After `_bootstrap_external._install()` runs:
```python
sys.path_hooks = [
    FileFinder.path_hook(*_get_supported_file_loaders()),
]
```

This is the only default entry. Custom hooks (e.g. zipimport, .zip path support, custom loaders) are added by the user or by other stdlib modules.

### 14.6 `sys.path_importer_cache`

Initially empty. Populated lazily by `PathFinder._path_importer_cache(entry)` (line 42464). Entries are `path → FileFinder(path, ...)` (or `None` for paths that don't yield a finder). The cache is invalidated by `importlib.invalidate_caches()` and by changes in CWD (any relative path entry is dropped on every `invalidate_caches` call).

### 14.7 `sys.meta_path` initial state

After both `_install()` calls:
```python
sys.meta_path = [
    BuiltinImporter,
    FrozenImporter,
    # ... user-added finders may go here ...
    PathFinder,
]
```

`importlib.metadata.MetadataPathFinder` is NOT in the default `sys.meta_path`. It's added when `importlib.metadata` is imported, which happens automatically in many code paths via `importlib.resources` etc.

---

## 15. Import-related module attributes

### 15.1 The attributes and when they're set

| Attribute | Set by | When | Value |
|---|---|---|---|
| `__name__` | `_init_module_attrs` | module_from_spec / _exec | `spec.name` |
| `__loader__` | `_init_module_attrs` | module_from_spec / _exec | `spec.loader` (NamespaceLoader if nspackage) |
| `__spec__` | `_init_module_attrs` | module_from_spec / _exec | `spec` itself |
| `__package__` | `_init_module_attrs` | module_from_spec / _exec | `spec.parent` |
| `__path__` | `_init_module_attrs` | module_from_spec / _exec | `spec.submodule_search_locations` (packages only) |
| `__file__` | `_init_module_attrs` | module_from_spec / _exec | `spec.origin` if `spec.has_location` |
| `__cached__` | set later by `_fix_up_module` or by `SourceLoader` writing bytecode | after first import | path to bytecode cache file |
| `__builtins__` | set by `_exec_code_in_module` (module_dict_for_exec in import.c) | at exec time | the builtins module dict (or the builtins module) |
| `__doc__` | set by Python source; for extension modules, by `Py_mod_exec` or `PyModule_Add` | during exec | usually |
| `__origname__` | set by `PyImport_ImportFrozenModuleObject` | during frozen load | original frozen name before alias resolution |
| `__initializing__` | n/a | n/a | this attribute does NOT exist; the spec's `_initializing` is the marker |

### 15.2 Setting order: BEFORE exec vs AFTER

`_init_module_attrs` is called by `module_from_spec` BEFORE the module is inserted in `sys.modules` and BEFORE `exec_module`. So the module has `__name__`, `__loader__`, `__spec__`, `__package__`, `__path__`, `__file__` (when applicable) available during its own module body.

The module-level code can REASSIGN these - they are simple attribute writes. If it does, the new values win (override).

The `_exec(spec, module)` function (used by `importlib.reload()`) calls `_init_module_attrs(spec, module, override=True)` to force-reset the attrs. `module_from_spec` (used for fresh imports) calls without `override`.

### 15.3 PEP 562: module-level `__getattr__` and `__dir__`

Defined in `Python/bltinmodule.c` (`builtin___getattr___impl`):

```c
static PyObject *
builtin___getattr___impl(PyObject *module, PyObject *name)
{
    // Defer to module's __getattr__ if defined.
    ...
}

static PyObject *
builtin___dir___impl(PyObject *module)
{
    // Standard dir() with module's __dir__ if defined.
    ...
}
```

When a module defines a module-level `def __getattr__(name)` function, every `getattr(module, name)` first checks the module's `__dict__`, and if missing, calls `module.__getattr__(name)`. `from module import name` (IMPORT_FROM) uses `getattr`, so this applies.

For `import a.b` to fall back to importing `a.b` as a submodule (the `_handle_fromlist` step), `hasattr(module, 'b')` must be False. If `module.__getattr__('b')` returns something non-AttributeError, `hasattr` returns True and the submodule is NOT imported. This is the documented interaction: module-level `__getattr__` can shadow submodule imports.

Module-level `__dir__` is similar: if defined, `dir(module)` calls `module.__dir__()` and the resulting list is used.

### 15.4 `__cached__`

Set by `SourceFileLoader.set_data` (which writes `.pyc` files) and by `_fix_up_module` (`_bootstrap_external.py:56843`) for reloaded modules. `ModuleSpec.cached` is computed lazily: when first read, it calls `_bootstrap_external._get_cached(self.origin)` to compute the canonical `.pyc` path.

`__cached__` is a string path; if `spec.has_location` is False (built-in/frozen), `__cached__` is not set.

### 15.5 `__builtins__`

`__builtins__` is set in `module_dict_for_exec` (`Python/import.c:90901`):

```c
static PyObject *
module_dict_for_exec(PyThreadState *tstate, PyObject *name)
{
    PyObject *m, *d;

    m = import_add_module(tstate, name);
    if (m == NULL)
        return NULL;
    d = PyModule_GetDict(m);
    int r = PyDict_Contains(d, &_Py_ID(__builtins__));
    if (r == 0) {
        r = PyDict_SetItem(d, &_Py_ID(__builtins__), PyEval_GetBuiltins());
    }
    ...
}
```

This is what makes every module see `__builtins__` pointing to the builtins dict (or the builtins module, in `__main__`). For `__main__` only, `__builtins__` is the module, not the dict - this is a deliberate quirk so that `__main__.__builtins__` can be assigned and mutated.

### 15.6 `__doc__`

For Python source modules, the first string literal in the module body becomes `__doc__` (handled by the compiler, not the import system). For extension modules, set explicitly in the `Py_mod_exec` slot via `PyModule_SetDocString` or `PyModule_Add`.

---

## 16. `importlib.metadata` and `importlib.resources`

### 16.1 `importlib.metadata` API

`Lib/importlib/metadata/__init__.py`. Public surface:

| Function | Purpose |
|---|---|
| `metadata(distribution_name)` | Return parsed `PackageMetadata` for the distribution |
| `version(distribution_name)` | Return version string |
| `files(distribution_name)` | List of `PackagePath` objects (None if not enumerated) |
| `requires(distribution_name)` | List of PEP 508 requirement strings |
| `entry_points(**params)` | Iterable of `EntryPoint` matching params |
| `distributions(**kwargs)` | All `Distribution` objects on `sys.path` |
| `distribution(name)` | Single `Distribution` |
| `packages_distributions()` | Mapping of top-level package name → distribution name(s) |

### 16.2 The `Distribution` class hierarchy

`Distribution` (abstract, in `metadata/__init__.py`):
- abstract `read_text(filename) -> Optional[str]`
- abstract `locate_file(path) -> SimplePath`
- `metadata` property: parses METADATA/PKG-INFO into a `PackageMetadata`.
- `version` property: returns `metadata['Version']`.
- `entry_points` property: parses `entry_points.txt`.
- `files` property: parses RECORD (or installed-files.txt / SOURCES.txt for eggs).
- `_normalized_name`: PEP 503 normalization (`re.sub(r'[-_.]+', '-', name).lower().replace('-', '_')`).
- `from_name(name)`: find a distribution by package name (raises `PackageNotFoundError`).
- `discover(context)`: iterates all `DistributionFinder`s registered on `sys.meta_path` (those that implement `find_distributions`).

`DistributionFinder(MetaPathFinder)`: abstract base. Subclass `MetadataPathFinder` is registered as a `MetaPathFinder` and provides the actual lookup logic:

```python
class MetadataPathFinder(DistributionFinder):
    @classmethod
    def find_distributions(cls, context=DistributionFinder.Context()):
        found = cls._search_paths(context.name, context.path)
        return map(PathDistribution, found)

    @classmethod
    def _search_paths(cls, name, paths):
        prepared = Prepared(name)
        return itertools.chain.from_iterable(
            path.search(prepared) for path in map(FastPath, paths))

    @classmethod
    def invalidate_caches(cls):
        FastPath.__new__.cache_clear()
```

`PathDistribution`: a `Distribution` backed by a `pathlib.Path` to a `.dist-info` or `.egg-info` directory. `read_text(filename)` opens `<dist-info-path>/<filename>` (e.g. `METADATA`, `entry_points.txt`, `RECORD`).

### 16.3 The `FastPath` cache

`FastPath` is an `lru_cache`-decorated class that caches directory listings (`os.listdir`) for performance. Cleared on `MetadataPathFinder.invalidate_caches()`.

### 16.4 `importlib.resources`

`Lib/importlib/resources/__init__.py` is a thin shim. The real work is in `Lib/importlib/resources/_common.py` and `_functional.py` (not fetched in depth here).

Public surface:
| Function | Purpose |
|---|---|
| `files(package)` | Return a `Traversable` for the package (file/dir/zip namespace) |
| `as_file(traversable)` | Context manager: materialise the traversable to a real FS path |
| `open_binary(package, resource)` | Open a resource for reading bytes |
| `open_text(package, resource, encoding='utf-8', errors='strict')` | Open a resource for reading text |
| `read_binary(package, resource)` | Read resource as bytes |
| `read_text(package, resource, ...)` | Read resource as text |
| `contents(package)` | Iterable of resource names |
| `is_resource(package, name)` | Is `name` a resource of `package`? |
| `path(package, resource)` | Get a real FS path for `resource` |

The implementation uses `ResourceReader` (the PEP 302 protocol), which loaders can implement:
- `FileLoader.get_resource_reader(module)` returns a `FileReader` for `SourceFileLoader` etc.
- `NamespaceLoader.get_resource_reader(module)` returns a `NamespaceReader`.

---

## 17. Peculiar / surprising behaviour - gotchas for the re-implementer

### 17.1 `import a.b` vs `import a.b as c`

Both bind `c` (or `a.b`) to the topmost package `sys.modules['a']` (NOT `sys.modules['a.b']`). This is because `IMPORT_NAME` calls `__import__('a.b', ..., fromlist=())` which returns the topmost dotted prefix. The bytecode then stores that result under the chosen name.

For `import a.b.c as d`: `d = sys.modules['a']`. The names `a.b` and `a.b.c` are NOT bound in the local namespace (only `d` is).

For `from a.b.c import d as e`: `e = sys.modules['a.b.c'].d` (or `sys.modules['a.b.c.d']` if `d` is a submodule and `a.b.c` is a package).

### 17.2 `__spec__` on a module imported by `importlib.import_module` vs `__import__`

Both end up calling `_find_and_load`, which calls `_load_unlocked`, which calls `module_from_spec(spec)` then `_init_module_attrs(spec, module)` - so the resulting `__spec__` is identical. The difference is purely in the call site:

- `__import__(...)` is the user-facing callable in `builtins`.
- `importlib.import_module(name, package=None)` is a thin wrapper that calls `_gcd_import(name, package, level)` directly (in `Lib/importlib/__init__.py`).

Both call `_find_and_load`, both end up with the same `__spec__`. There is no "importlib sets a different __spec__" behaviour - the spec is set by `_init_module_attrs` regardless of caller.

### 17.3 `import a.b` when `a` is a package but `b` is not importable

`import a.b` for a package `a` and non-existent `b`:

1. `_find_and_load('a.b')` is called.
2. `_resolve_parents('a.b', ...)` calls `_gcd_import('a')` to make sure `a` is in `sys.modules` with `__path__`.
3. `_find_and_load_unlocked` runs:
   - `parent = 'a'`, `path = sys.modules['a'].__path__`.
   - `child = 'b'`.
   - `spec = _find_spec('a.b', path)` - calls `PathFinder.find_spec('a.b', path)` which walks the path entries looking for `a/b.{suffix}` or `a/b/__init__.{suffix}`. None found → returns `None`.
   - Raises `ModuleNotFoundError("No module named 'a.b'", name='a.b')`.

So `import a.b` raises `ModuleNotFoundError` for the full dotted name, not just the leaf.

### 17.4 The `sys.modules` entry for the parent package

After `import a.b`, `sys.modules` contains BOTH:
- `sys.modules['a']` - the parent package module.
- `sys.modules['a.b']` - the submodule.

The submodule is also set as an attribute on the parent: `sys.modules['a'].b = sys.modules['a.b']`. If the parent's `__setattr__` fails (e.g. it has a custom `__setattr__` that raises), an `ImportWarning` is issued but the import still succeeds.

### 17.5 `from a import b` when `b` is both an attribute and a submodule

`_handle_fromlist` checks `hasattr(module, x)` first. If the attribute exists, NO submodule import attempt is made. So if `a.b` was previously imported and is in `sys.modules` AND bound as `a.b`, then `from a import b` returns the already-imported `a.b` without re-importing.

But the user's `from a import b` does NOT trigger an import if `b` is already an attribute. This means `b` is not "freshly imported" by the from statement - it was imported previously (e.g. by `a`'s `__init__.py`) and is now just being looked up.

If `b` is NOT an attribute of `a`, then `_handle_fromlist` calls `import_('a.b')` (via `_call_with_frames_removed`). The submodule import goes through the normal `_find_and_load` path.

### 17.6 `importlib.invalidate_caches()`

`Lib/importlib/__init__.py:invalidate_caches()` (not fetched in depth but well-documented): calls `path_importer_cache.clear()` and `meta_path[*].invalidate_caches()`. The behaviour in `PathFinder.invalidate_caches` (`_bootstrap_external.py:42464`):

```python
@staticmethod
def invalidate_caches():
    for name, finder in list(sys.path_importer_cache.items()):
        if finder is None or not _path_isabs(name):
            del sys.path_importer_cache[name]
        elif hasattr(finder, 'invalidate_caches'):
            finder.invalidate_caches()
    NamespacePath._epoch += 1   # invalidate namespace packages
    from importlib.metadata import MetadataPathFinder
    MetadataPathFinder.invalidate_caches()
```

Notes:
- Drops `None` entries (failed lookups) - next time the path is queried, the hooks are tried again.
- Drops non-absolute entries (because CWD might have changed).
- Calls `invalidate_caches()` on each `FileFinder` (which resets `_path_mtime`).
- Bumps `NamespacePath._epoch` so namespace package `__path__` re-evaluates.
- Invalidates `MetadataPathFinder`'s `FastPath` cache.

The C-level `_imp.invalidate_caches()` is a no-op (it's just there for compatibility).

### 17.7 The "partially initialized module" error message

There is no literal "partially initialized module" error message in CPython. The phrase "partially initialized module object" appears only in comments (in `_bootstrap.py:_lock_unlock_module`, `_find_and_load`, and `_find_and_load_unlocked`).

The user-visible failure modes for circular imports:
1. `ModuleNotFoundError("import of X halted; None in sys.modules", name='X')` - raised by `_find_and_load` if `sys.modules[name]` is `None` (explicit None, not missing).
2. AttributeError or other errors raised inside the module body during the second pass through the import machinery.
3. `_DeadlockError("deadlock detected by _ModuleLock('X')")` - only if `has_deadlock()` triggers; usually converted to a partial module by callers.

So "partially initialized module" is a concept that exists in the implementation but not in any error message - a re-implementer should know it but won't see it as a literal string.

### 17.8 `__package__` in a namespace package

For a namespace package `x` (no `__init__.py`):
- `x.__package__ == x.__name__` (because `spec.parent` returns `name` for packages).
- `x.__path__` is a `NamespacePath` object.
- `x.__file__` is `None` (set explicitly by `_init_module_attrs`).
- `x.__loader__` is a `NamespaceLoader`.

For a submodule of a namespace package `x.y`:
- `x.y.__package__ == 'x'` (because `spec.parent = 'x.y'.rpartition('.')[0] = 'x'`).
- `x.y.__path__` doesn't exist (it's not a package itself).
- `x.y.__file__` is set if `x/y/__init__.py` exists OR if `x/y.py` exists - depending on which `FileFinder` resolved the spec.

### 17.9 `python -m` vs `python script.py` - `sys.path[0]` again

This was covered in §14.3 but is critical enough to repeat:
- `python script.py`: `sys.path[0]` = absolute dirname of `script.py`.
- `python -m foo`: `sys.path[0]` = `''` (empty string → CWD).
- `python -c "..."`: `sys.path[0]` = `''` (empty string → CWD).
- `python -`: `sys.path[0]` = `''` (empty string → CWD).

The `''` is converted to CWD by `PathFinder._path_importer_cache('')` (line 42464), which fetches CWD at lookup time (not cached, because CWD can change via `os.chdir`).

### 17.10 The bytecode filename in `co_filename`

For a `.pyc`-only import (SourcelessFileLoader), `get_code` calls `_imp._fix_co_filename(code, source_path)` which mutates `code.co_filename` to point to the (non-existent) source path. This is for tracebacks: even a sourceless import reports a sensible `co_filename`.

For the bytecode cache file produced by SourceFileLoader, `_imp._fix_co_filename` is also called to point `co_filename` at the source file (so tracebacks show the `.py` location).

### 17.11 The `__origname__` attribute on frozen modules

After loading a frozen module via `PyImport_ImportFrozenModuleObject`, the module's `__dict__` contains `__origname__ = '<canonical name>'` (e.g. for `__phello__.spam`, `__origname__` is `'__phello__.spam'`). This is a transient marker used by `_setup()` to set `__file__` correctly. After `_setup` finishes, `__origname__` is removed via `vars(module).pop('__origname__', None)` (`_bootstrap.py:34425`, `FrozenImporter._fix_up_module`).

### 17.12 The `os.add_dll_directory` hook (Windows only)

Windows has a special `os.add_dll_directory` mechanism that adds paths to the DLL search order. Not relevant for POSIX but worth noting if the re-implementer wants Windows support.

### 17.13 `_imp.override_frozen_modules_for_tests`

`_imp._override_frozen_modules_for_tests` is a testing-only hook to swap out the frozen module table. Not relevant to normal operation.

### 17.14 The audit hook

`_PySys_Audit("import", name, None, sys.path, sys.meta_path, sys.path_hooks)` is fired inside `_find_and_load` before the actual import begins. Audit subscribers (e.g. for security logging) can intercept the import and raise to abort it. The hook is registered in `Python/audit.py` (or `Python/sysaudit.py` in older versions) and is part of the PEP 578 audit system.

### 17.15 The order of `sys.path_importer_cache` invalidation

`importlib.invalidate_caches()` is NOT safe to call from inside an audit hook during an active import. Doing so can cause the cache to be repopulated mid-iteration, leading to `RuntimeError`. CPython itself avoids this by holding the global import lock around `_find_spec`.

### 17.16 Lazy imports (`PyImport_SetLazyImportsMode`)

Python 3.12+ added lazy module loading via `PyImport_SetLazyImportsMode(1)` (3.15 has `PyImport_ImportModuleAttr` and `PyImport_ImportModuleAttrString` for deferred attribute imports - see `Python/import.c:152234` and `152506`). A module loaded lazily has its class replaced by `_LazyModule` (`Lib/importlib/util.py:6154`) on first attribute access. Not directly part of the basic import mechanism, but worth noting for completeness.

### 17.17 The `_uninitialized_submodules` circular-import tracker

`ModuleSpec._uninitialized_submodules` is a list of submodule names currently being imported. When `_find_and_load_unlocked` starts loading `parent.child`, it does `parent_spec._uninitialized_submodules.append('child')` before calling `_load_unlocked(spec)`, and pops it afterwards. This list is used by the C-level circular-import tracking (`ensure_lazy_pending_submodules`, `_PyImport_ClearLazySubmodule`).

### 17.18 The `_blocking_on` global

`_bootstrap._blocking_on` is a `_WeakValueDictionary` mapping `thread_id → _ModuleLock` indicating which module lock each thread is currently trying to acquire. Populated by `_BlockingOnManager` (a context manager used in `_ModuleLock.acquire`) and consulted by `_has_deadlocked` for deadlock detection.

### 17.19 Reference cycles in the import system

CPython's import system has several intentional reference cycles:
- `sys.modules` holds the module, the module's `__dict__` holds functions, the functions close over `sys` and other modules.
- `BuiltinImporter` / `FrozenImporter` are held by `sys.meta_path`, but their `find_spec` etc. methods don't reference user modules.
- `spec.loader` references the loader; `module.__loader__` references the spec (via `module.__spec__`).

The import-related state is torn down in a specific order at interpreter finalisation (`_PyImport_Fini`, `_PyImport_Fini2`, `_PyImport_FiniCore`, `_PyImport_FiniExternal` - see `Python/import.c:147381-151582`). Order matters: `_PyImport_ClearCore` clears `sys.modules` and other state, `_PyImport_FiniExternal` tears down the extension cache.

---

## 18. Internal C structures and APIs (for the Go engineer)

### 18.1 The `_import_state` (per-interpreter)

`struct _import_state` is defined in `Include/internal/pycore_interp_structs.h` (referenced but not fetched here). Key fields:

| Field | Purpose |
|---|---|
| `modules` | The `sys.modules` dict |
| `modules_by_index` | Array of modules indexed by `PyModuleDef.m_base.m_index` (used by `PyState_FindModule`) |
| `modules_by_index_check`, `modules_by_index_get`, etc. | Accessors for `modules_by_index` |
| `inittab` | The `_inittab[]` table (copy of `PyImport_Inittab`, can be extended by `PyImport_ExtendInittab`) |
| `last_module_index` | Counter incremented by `_PyImport_GetNextModuleIndex` for new module defs |
| `extensions` | The `extensions_cache` hashtable |
| `dlopenflags` | dlopen flags (default `RTLD_NOW`) |
| `find_and_load` | Telemetry state for `-X importtime` |
| `import_level`, `accumulated` | Same |
| `lazy_modules` | Set of lazily-imported module names |
| `has_lazy_submodules` | Atomic flag indicating lazy submodule tracking is active |

### 18.2 The `_import_runtime_state` (per-runtime)

In `Include/internal/pycore_runtime.h` (referenced but not fetched). Contains:
- `inittab`, `last_module_index`, `extensions` (overridden at interpreter init from per-interpreter state).

### 18.3 Key public C API (from `Include/Python.h`)

| Function | File | Purpose |
|---|---|---|
| `PyImport_Import(name)` | import.c | Top-level: returns module, sets up `__import__` call |
| `PyImport_ImportModuleLevel(name, globals, locals, fromlist, level)` | import.c | C-string variant |
| `PyImport_ImportModuleLevelObject(name, globals, locals, fromlist, level)` | import.c | PyObject variant - fast path |
| `PyImport_ImportFrozenModule(name)` | import.c | Load frozen module by name |
| `PyImport_ImportFrozenModuleObject(name)` | import.c | Same, returns full result |
| `PyImport_AddModule(name)` | import.c | Add to sys.modules (or get existing) |
| `PyImport_AddModuleObject(name)` | import.c | Same with PyObject name |
| `PyImport_AddModuleRef(name)` | import.c | Add and return strong reference |
| `PyImport_GetModule(name)` | import.c | Lookup sys.modules[name], raise if None |
| `PyImport_GetModuleDict()` | import.c | Get sys.modules dict |
| `PyImport_ExecCodeModule(name, co)` | import.c | Run code object as module (legacy) |
| `PyImport_ExecCodeModuleObject(name, co, pathname, cpathname)` | import.c | Same, with path info |
| `PyImport_ExecCodeModuleWithPathnames(...)` | import.c | Legacy variant |
| `PyImport_ExecCodeModuleEx(name, co, pathname)` | import.c | Legacy variant |
| `PyImport_ReloadModule(m)` | import.c | Reload module |
| `PyImport_CreateModuleFromInitfunc(spec, initfunc)` | import.c | Create extension module from init function |
| `PyImport_ExtendInittab(newtab)` | import.c | Extend builtin module table (pre-init) |
| `PyImport_AppendInittab(name, initfunc)` | import.c | Same |
| `PyImport_GetImporter(path)` | import.c | Get the path importer for a path |
| `PyImport_GetMagicNumber()` | import.c | Return bytecode magic number |
| `PyImport_GetMagicTag()` | import.c | Return magic tag string |
| `PyImport_SetLazyImportsMode(int)` | import.c | Enable/disable lazy module import |
| `PyImport_GetLazyImportsMode()` | import.c | Query lazy import mode |
| `PyImport_SetLazyImportsFilter(...)` | import.c | Filter which modules are lazy |
| `PyImport_GetLazyImportsFilter()` | import.c | Get the filter |
| `PyImport_ImportModuleAttr(name, attr)` | import.c | `from name import attr` (lazy) |
| `PyImport_ImportModuleAttrString(name, attr)` | import.c | Same with C-string attr |

### 18.4 The `_imp` module's C methods

The `_imp` module is exposed by `Python/import.c` via `imp_module_exec` (line 172032) and `PyInit__imp` (line 172873). Methods (each has a `*_impl` static and is wrapped by clinic-generated code):

- `_lock_held` / `acquire_lock` / `release_lock` - global import lock
- `_fix_co_filename` - mutate `code.co_filename`
- `create_builtin(spec)` - call a builtin init function
- `extension_suffixes` - return `EXTENSION_SUFFIXES`
- `init_frozen(name)` - load frozen module by name
- `find_frozen(name)` - check if name is frozen (returns tuple `(module, is_package, origname)` or None)
- `get_frozen_object(name)` - get the code object for a frozen module
- `is_frozen_package(name)` - is this frozen module a package?
- `is_builtin(name)` - is this a builtin module?
- `is_frozen(name)` - is this a frozen module?
- `_frozen_module_names` - list all frozen module names
- `_override_frozen_modules_for_tests(...)` - testing hook
- `create_dynamic(spec)` - load extension module (returns module)
- `exec_dynamic(module)` - execute extension module (calls slots)
- `exec_builtin(module)` - execute builtin module (calls slots)
- `source_hash(key, source)` - compute hash for hash-based pyc
- `pyc_magic_number_token` - attribute exposing the magic number token

Plus `_imp` has attributes:
- `_imp.builtin_module_names` (a frozenset/tuple of builtin module names - exposed via `_PyImport_GetBuiltinModuleNames`)
- `_imp.pyc_magic_number_token` (an integer token used for hash computation)
- `_imp.check_hash_based_pycs` ('default', 'always', 'never')
- `_imp.source_hash(key, source)`
- `_imp.extension_suffixes()`

---

## 19. Glossary of subtle bits

**`__class__` swap for lazy modules**: when a module is loaded via `LazyLoader`, its `__class__` is replaced with `_LazyModule`. The first attribute access triggers the real load and restores the original `__class__`.

**`__spec__._initializing`**: the marker flag that distinguishes "in sys.modules but not yet executed" from "fully initialized". Set in `_load_unlocked` before `sys.modules[name] = module`, cleared in `finally`.

**`__spec__._uninitialized_submodules`**: a list used for circular-import diagnostics. Populated in `_find_and_load_unlocked` for parent-child relations.

**`__spec__.cached`**: lazy property on `ModuleSpec` that computes the bytecode cache path via `_get_cached(origin)` on first access.

**`__spec__.loader_state`**: free-form state the loader can stash. Used by `FrozenImporter` to remember the filename/origname; by `LazyLoader` to remember the loader and lock.

**`spec._set_fileattr`**: bool flag controlling whether `__file__` is set. Set by `spec_from_file_location`, `spec_from_loader`, `_spec_from_module`.

**`spec._cached`**: raw storage for `cached` (the property).

**`sys.meta_path` ordering**: the order of `BuiltinImporter, FrozenImporter, ..., PathFinder` matters. A user-added finder that goes AFTER `PathFinder` would never be called for `sys.path` lookups, because `PathFinder` always returns a spec (or None) for `sys.path` searches. Inserting a finder BEFORE `PathFinder` lets it intercept non-builtin, non-frozen names.

**`sys.path_hooks` ordering**: same idea. `FileFinder.path_hook(...)` is the default and goes first (or wherever added). Custom hooks (zipimport, .zip files, etc.) typically go AFTER it so they can intercept specific path patterns.

**`sys.modules.get(name, _NEEDS_LOADING)`**: the use of `_NEEDS_LOADING = object()` (a unique sentinel) lets `_find_and_load` distinguish "module is in sys.modules" (initialised or not) from "module is not in sys.modules" (needs loading) without confusing them with `None` (which is a valid sentinel meaning "imported and set to None").

**`module is None`**: a module CAN be set to `None` in `sys.modules` to indicate "an import attempt was made and failed, do not retry". The `import X halted; None in sys.modules` error is the user-facing consequence.

**`import X` where `X` is a `None` module**: `sys.modules.get('X') is None` triggers the halt message. This is the way to "memoize" a failed import: assign `sys.modules['X'] = None`.

---

## 20. What a Go re-implementation needs to track (cheat sheet)

For each module import:

```
1. Parse name into parts (parent, child).
2. If level > 0:
   a. Compute package from globals['__package__'] / globals['__spec__'].parent / globals['__name__'].
   b. Apply _resolve_name to get absolute name.
3. If name is in sys.modules and __spec__._initializing is False: return it.
4. If name is in sys.modules and _initializing is True:
   a. Acquire module lock; if deadlock, return partial module.
   b. Re-check sys.modules; if still initializing, wait for lock release.
5. If not in sys.modules:
   a. _resolve_parents: import (or wait for) each ancestor package.
   b. Acquire module lock.
   c. Re-check sys.modules (race against other threads).
   d. If still missing: run _find_and_load_unlocked.
6. _find_and_load_unlocked:
   a. parent_module = sys.modules[parent] (or import parent first).
   b. path = parent_module.__path__ if exists.
   c. spec = _find_spec(name, path) → iterates sys.meta_path finders.
   d. _find_spec → for each finder, find_spec(name, path, target); first non-None wins.
   e. PathFinder.find_spec → for each path entry, _path_importer_cache → FileFinder.find_spec.
   f. If no loader but non-empty portions: return namespace spec.
   g. If no spec: raise ModuleNotFoundError.
   h. module = module_from_spec(spec) → create_module or default + _init_module_attrs.
   i. spec._initializing = True; sys.modules[name] = module (partial visible).
   j. spec.loader.exec_module(module).
   k. On exception: del sys.modules[name]; re-raise.
   l. Move to end of sys.modules; spec._initializing = False.
   m. Setattr(parent_module, child, module).
7. Handle fromlist (if any):
   a. For each name in fromlist:
      - If hasattr(module, name): pass.
      - Else: try import(module.name + '.' + name); on ModuleNotFoundError, swallow.
8. Return topmost package (for empty fromlist) or full module (for non-empty fromlist).
```

This is the minimum. Real CPython has many edge cases; the rest of this document covers them.

---

## Appendix: Source citations

All citations are from `https://raw.githubusercontent.com/python/cpython/main/...` fetched on the date of this report.

- `Lib/importlib/_bootstrap.py`: 58,008 chars fetched.
- `Lib/importlib/_bootstrap_external.py`: 58,690 chars fetched.
- `Lib/importlib/util.py`: 11,430 chars fetched.
- `Lib/importlib/abc.py`: 8,187 chars fetched.
- `Lib/importlib/machinery.py`: 2,228 chars fetched.
- `Lib/importlib/_abc.py`: minimal `Loader` ABC.
- `Lib/importlib/metadata/__init__.py`: full distribution metadata API.
- `Lib/importlib/resources/__init__.py`: shim (full implementation in `_common.py` and `_functional.py`, not fetched in depth here but referenced in `importlib.readers.NamespaceReader` and `importlib.readers.FileReader`).
- `Lib/site.py`: 1,189 lines fetched; covers `sys.path` finalisation and `.pth`/`.start` processing (PEP 829).
- `Python/import.c`: 172,952 chars fetched.
- `Python/importdl.c`: 15,601 chars fetched.
- `Python/dynload_shlib.c`: 3,209 chars fetched (POSIX dlopen path).
- `Python/frozen.c`: 6,486 chars fetched (frozen module tables and aliases).
- `Python/bltinmodule.c`: 106,340 chars fetched (`__import__` and `__lazy_import__` Python functions live here).
- `Modules/xxmodule.c`: 13,015 chars fetched (multi-phase init example).
- `Include/internal/pycore_import.h`: full internal API.

**Unverified**: `Python/getpath.c` (sys.path construction at C level - well-documented but not fetched here), `Python/getsyspathpath.c` (Windows-specific - out of scope), `Python/sysaudit.py` (audit event definitions), `Lib/importlib/__init__.py` (`import_module`, `invalidate_caches` - small shim file), `Lib/importlib/resources/_common.py` and `_functional.py` (resources implementation - only the public shim was fetched), `Lib/importlib/readers.py` (FileReader, NamespaceReader, MultiplexedPath, etc.).

If any of these become critical, they should be fetched separately.
