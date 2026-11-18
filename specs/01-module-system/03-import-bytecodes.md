# 03 - The Import Bytecodes and the Lazy Import Protocol

## Overview

This file specifies how the compiler emits import statements and how the
interpreter executes them. It covers three things the earlier files do not:

1. **The exact bytecode** emitted for `import a`, `import a.b as c`,
   `from a import b` and `from a import *`.
2. **The `IMPORT_FROM` fallback to `sys.modules`** and the exact error messages
   it produces.
3. **The lazy import protocol** (PEP 810), which is new in 3.15 and is encoded
   in the `IMPORT_NAME` opcode argument.

The 3.15 compiler no longer lives in `Python/compile.c`. That file is now a
thin front end; the code generator moved to **`Python/codegen.c`**, and the
opcode implementations moved to **`Python/bytecodes.c`**. A re-implementation
should follow that split.

Everything here was read from the CPython **v3.15.2** source.

## Sources

- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/codegen.c` -
  the code generator. Contains `codegen_import` and `codegen_from_import`.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/bytecodes.c` -
  the opcode implementations. Contains the `IMPORT_NAME` and `IMPORT_FROM`
  handlers.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/ceval.c` -
  `_PyEval_ImportFrom`, `_PyEval_ImportName`, `_PyEval_LazyImportName` and
  `_PyEval_LazyImportFrom`.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/opcode_ids.h` -
  the opcode numbers: `IMPORT_FROM` is 71, `IMPORT_NAME` is 72.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Parser/Python.asdl` -
  the `Import` and `ImportFrom` node definitions.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap.py` -
  the Python-level `__import__`.

## Spec

### The two import AST nodes

From `Parser/Python.asdl`:

```
          | Import(alias* names, int? is_lazy)
          | ImportFrom(expr? module, alias* names, int? level, int? is_lazy)
```

Both carry an `is_lazy` field, new in 3.15.

### The opcode arguments

`IMPORT_NAME` takes an opcode argument that packs four things:

| Bits | Meaning |
|---|---|
| `oparg >> 2` | Index into `co_names` of the module name |
| `oparg & 0x03` | The import mode (see below) |

The three modes, from the `bytecodes.c` handler:

```c
        inst(IMPORT_NAME, (level, fromlist -- res)) {
            PyObject *name = GETITEM(FRAME_CO_NAMES, oparg >> 2);
            PyObject *res_o;
            if (!(oparg & 0x02)) {
                res_o = _PyEval_LazyImportName(tstate, BUILTINS(), GLOBALS(),
                                LOCALS(), name,
                                PyStackRef_AsPyObjectBorrow(fromlist),
                                PyStackRef_AsPyObjectBorrow(level),
                                oparg & 0x01);

            }
            else {
                res_o = _PyEval_ImportName(tstate, BUILTINS(), GLOBALS(),
                                LOCALS(), name,
                                PyStackRef_AsPyObjectBorrow(fromlist),
                                PyStackRef_AsPyObjectBorrow(level));
            }
```

| `oparg & 0x03` | Mode | Emitted when |
|---|---|---|
| `0` | Eager | A plain module-scope `import a` |
| `1` | Lazy | `lazy import a` at module scope |
| `2` | Forced eager | Inside a `try`/`except` block, inside a function, or `from a import *` |
| `3` | Lazy, but forced eager at runtime | Reserved; the compiler emits `2` for the forced cases and `1` for lazy |

**The mode is chosen by the compiler, not the runtime.** The rules, from
`codegen_import`:

```c
        if (s->v.Import.is_lazy) {
            RETURN_IF_ERROR(codegen_validate_lazy_import(c, loc));
            ADDOP_NAME_CUSTOM(c, loc, IMPORT_NAME, alias->name, names, 2, 1);
        } else {
            if (_PyCompile_InExceptionHandler(c) ||
                _PyCompile_ScopeType(c) != COMPILE_SCOPE_MODULE) {
                // force eager import in try/except block
                ADDOP_NAME_CUSTOM(c, loc, IMPORT_NAME, alias->name, names, 2, 2);
            } else {
                ADDOP_NAME_CUSTOM(c, loc, IMPORT_NAME, alias->name, names, 2, 0);
            }
        }
```

and from `codegen_from_import`:

```c
    if (s->v.ImportFrom.is_lazy) {
        alias_ty alias = asdl_seq_GET(s->v.ImportFrom.names, 0);
        if (PyUnicode_READ_CHAR(alias->name, 0) == '*') {
            return _PyCompile_Error(c, LOC(s), "cannot lazy import *");
        }
        RETURN_IF_ERROR(codegen_validate_lazy_import(c, LOC(s)));
        ADDOP_NAME_CUSTOM(c, LOC(s), IMPORT_NAME, from, names, 2, 1);
    } else {
        alias_ty alias = asdl_seq_GET(s->v.ImportFrom.names, 0);
        if (_PyCompile_InExceptionHandler(c) ||
            _PyCompile_ScopeType(c) != COMPILE_SCOPE_MODULE ||
            PyUnicode_READ_CHAR(alias->name, 0) == '*') {
            // forced non-lazy import due to try/except or import *
            ADDOP_NAME_CUSTOM(c, LOC(s), IMPORT_NAME, from, names, 2, 2);
        } else {
            ADDOP_NAME_CUSTOM(c, LOC(s), IMPORT_NAME, from, names, 2, 0);
        }
    }
```

### The compile-time rules

| Rule | Error message |
|---|---|
| A lazy import outside module scope | `lazy imports only allowed in module scope` |
| A lazy `from a import *` | `cannot lazy import *` |

The scope check:

```c
codegen_validate_lazy_import(compiler *c, location loc)
{
    if (_PyCompile_ScopeType(c) != COMPILE_SCOPE_MODULE) {
        return _PyCompile_Error(
            c, loc, "lazy imports only allowed in module scope");
    }

    return SUCCESS;
}
```

**Three things force an eager import**, even when the source says `lazy`:

1. Being inside a `try`/`except`/`finally` handler.
2. Being outside module scope.
3. Being `from a import *`.

### The emitted bytecode

#### `import a`

```c
    ADDOP_LOAD_CONST(c, loc, zero);     // level = 0
    ADDOP_LOAD_CONST(c, loc, Py_None);   // fromlist = None
    ADDOP_NAME_CUSTOM(c, loc, IMPORT_NAME, alias->name, names, 2, mode);
    // then STORE_NAME (or STORE_FAST etc. depending on scope)
```

Note the fromlist is `None`, not `()`. That is the "no fromlist" marker.

#### `import a.b as c`

The `Import` node stores `a.b` as a single name. The `as` form needs the
individual components, so the compiler parses the string:

```c
    /* The Import node stores a module name like a.b.c as a single
       string.  This is convenient for all cases except
         import a.b.c as d
       where we need to parse that string to extract the individual
       module names.

       XXX Perhaps change the representation to make this case simpler?
     */
```

The emitted sequence is `IMPORT_NAME` followed by attribute lookups that
extract `b` from the returned top-level package `a`, then `STORE_NAME c`.

#### `from a import b`

```c
    ADDOP_LOAD_CONST_NEW(c, LOC(s), PyLong_FromLong(s->v.ImportFrom.level));
    // build a tuple of the names
    ADDOP_LOAD_CONST_NEW(c, LOC(s), names);
    ADDOP_NAME_CUSTOM(c, LOC(s), IMPORT_NAME, from, names, 2, mode);
    // then for each name:
    ADDOP_NAME(c, LOC(s), IMPORT_FROM, alias->name, names);
    // then STORE_NAME (or the asname)
```

The `fromlist` is a **tuple of the imported names**, not `None`. That is what
makes `__import__` call `_handle_fromlist`.

#### `from a import *`

The star form does **not** use an `IMPORT_FROM` opcode. It uses an intrinsic:

```c
    for (Py_ssize_t i = 0; i < n; i++) {
        alias_ty alias = asdl_seq_GET(s->v.ImportFrom.names, i);
        identifier store_name;

        if (i == 0 && PyUnicode_READ_CHAR(alias->name, 0) == '*') {
            assert(n == 1);
            ADDOP_I(c, LOC(s), CALL_INTRINSIC_1, INTRINSIC_IMPORT_STAR);
            ADDOP(c, NO_LOCATION, POP_TOP);
            return SUCCESS;
        }

        ADDOP_NAME(c, LOC(s), IMPORT_FROM, alias->name, names);
```

**There is no `IMPORT_STAR` opcode in 3.15.** It was replaced by
`CALL_INTRINSIC_1` with the `INTRINSIC_IMPORT_STAR` intrinsic. Verified
against the 3.15.2 `Include/opcode_ids.h`: the only import opcodes are
`IMPORT_FROM` (71) and `IMPORT_NAME` (72).

A Go implementation that ports the 3.14 opcode set will be wrong here.

### The `IMPORT_FROM` opcode

```c
        inst(IMPORT_FROM, (from -- from, res)) {
            PyObject *name = GETITEM(FRAME_CO_NAMES, oparg);
            PyObject *res_o;
            if (PyLazyImport_CheckExact(PyStackRef_AsPyObjectBorrow(from))) {
                res_o = _PyEval_LazyImportFrom(
                    tstate, frame, PyStackRef_AsPyObjectBorrow(from), name);
            }
            else {
                res_o = _PyEval_ImportFrom(
                    tstate, PyStackRef_AsPyObjectBorrow(from), name);
            }

            ERROR_IF(res_o == NULL);
            res = PyStackRef_FromPyObjectSteal(res_o);
        }
```

The opcode leaves the source module on the stack (`from -- from, res`), so the
compiler emits a `POP_TOP` (or the value is consumed by a `STORE`).

### The `IMPORT_FROM` fallback

`_PyEval_ImportFrom` in `Python/ceval.c`:

```c
_PyEval_ImportFrom(PyThreadState *tstate, PyObject *v, PyObject *name)
{
    PyObject *x;
    PyObject *fullmodname, *mod_name, *origin, *mod_name_or_unknown, *errmsg, *spec;

    if (PyObject_GetOptionalAttr(v, name, &x) != 0) {
        return x;
    }
    /* Issue #17636: in case this failed because of a circular relative
       import, try to fallback on reading the module directly from
       sys.modules. */
    if (PyObject_GetOptionalAttr(v, &_Py_ID(__name__), &mod_name) < 0) {
        return NULL;
    }
    if (mod_name == NULL || !PyUnicode_Check(mod_name)) {
        Py_CLEAR(mod_name);
        goto error;
    }
    fullmodname = PyUnicode_FromFormat("%U.%U", mod_name, name);
    ...
    x = PyImport_GetModule(fullmodname);
    ...
    return x;
```

The algorithm:

1. **Try the attribute first.** `getattr(module, name)`. If it works, that is
   the result.
2. **Fall back to `sys.modules`.** Build `"<module.__name__>.<name>"` and look
   it up in `sys.modules`. This is the fix for issue #17636, and it is what
   makes `from a import b` work during a circular import, when `a.b` is in
   `sys.modules` but not yet set as an attribute of `a`.

**This is the second place where the `sys.modules` entry for the parent
package matters.** The `from` list handling in `_handle_fromlist` also
consults `sys.modules`.

### The `IMPORT_FROM` error messages

When the attribute lookup fails and the `sys.modules` fallback fails, the error
message depends on the module's state. All four are verbatim from
`Python/ceval.c`:

| Condition | Message |
|---|---|
| The module has no `__spec__` | `cannot import name 'x' from 'm' (unknown location)` |
| The module is still initializing, with a known origin | `cannot import name 'x' from partially initialized module 'm' (most likely due to a circular import) ('<origin>')` |
| The module is still initializing, no origin | `cannot import name 'x' from partially initialized module 'm' (most likely due to a circular import)` |
| Fully initialized, with an origin | `cannot import name 'x' from 'm' ('<origin>')` |
| Fully initialized, no origin | `cannot import name 'x' from 'm' (unknown location)` |
| The module shadows a stdlib module | `cannot import name 'x' from 'm' (consider renaming '<origin>' since it has the same name as the standard library module named 'm' and prevents importing that standard library module)` |
| The module shadows a non-stdlib module and is initializing | `cannot import name 'x' from 'm' (consider renaming '<origin>' if it has the same name as a library you intended to import)` |

The "partially initialized module" message is the one to get right: it is the
canonical symptom of a circular import, and users search for it by name.

The stdlib-shadowing detection uses `sys.stdlib_module_names`, which is a
**frozenset** of the standard library's top-level module names. A module whose
name is in that set, and which was loaded from a file rather than from the
stdlib directory, gets the special message. This is why the error mentions
"the standard library module named 'm'".

The error is raised with `_PyErr_SetImportErrorWithNameFrom(errmsg, mod_name,
origin, name)`, which sets the `ImportError`'s `name` and `path` attributes.

### The `IMPORT_NAME` opcode and the `__import__` call

The opcode calls `_PyEval_ImportName`, which is the C fast path. It mirrors
the Python-level `__import__` but avoids the Python call for the common case.

The Python-level `__import__` is what the `import` statement calls when the
C fast path defers to it. It lives in `Lib/importlib/_bootstrap.py` and is
documented in `01-module-system/01-import-pipeline.md`.

**The C fast path and the Python path must agree.** A Go implementation has
the choice: implement the whole thing in Go (recommended, since gpython is
pure Go), or keep a Python-visible `__import__` for compatibility. gpython
already has a `py/builtins` module, so the `__import__` builtin must exist
there and must accept the keyword arguments `name`, `globals`, `locals`,
`fromlist` and `level`.

### The lazy import protocol

Lazy imports (PEP 810) are new in 3.15. The pieces:

**At compile time:** the `IMPORT_NAME` opcode carries mode `1` instead of `0`.

**At runtime:** `_PyEval_LazyImportName` creates a **lazy proxy object** rather
than importing the module. The proxy is placed on the stack in place of the
module.

**At attribute access:** `IMPORT_FROM` checks whether the object on the stack is
a lazy proxy:

```c
            if (PyLazyImport_CheckExact(PyStackRef_AsPyObjectBorrow(from))) {
                res_o = _PyEval_LazyImportFrom(
                    tstate, frame, PyStackRef_AsPyObjectBorrow(from), name);
            }
```

If it is, `_PyEval_LazyImportFrom` performs the real import at that point and
then does the attribute lookup.

**The internal C API**, from `Include/internal/pycore_import.h`:

```c
extern PyObject * _PyImport_LoadLazyImportTstate(
    PyThreadState *tstate, PyObject *lazy_import);
// Bind a pending child on module before removing its registration. Return a
// new reference, NULL without an exception if absent, or NULL on error.
// Set recheck_dict if a concurrent lookup may have already bound the child.
extern PyObject * _PyImport_TryLoadLazySubmodule(
    PyObject *module, PyObject *attr_name, int suppress, int *recheck_dict);
extern int _PyImport_ClearLazySubmodule(
    PyThreadState *tstate, PyObject *name, int bind);
extern PyObject * _PyImport_LazyImportModuleLevelObject(
    PyThreadState *tstate, PyObject *name, PyObject *builtins,
    PyObject *globals, PyObject *locals, PyObject *fromlist, int level);
```

**The Python-level hook:** `_imp._set_lazy_attributes(module, name)` is called
at the end of `_find_and_load_unlocked`, and it sets the lazy attributes on
the module.

**The lazy import type:** `types.LazyImportType` is the public name for the
proxy type. The `sys` module gains `sys.set_lazy_imports`,
`sys.set_lazy_imports_filter` and `sys.lazy_imports`. The `-X lazy_imports`
flag and the `PYTHON_LAZY_IMPORTS` environment variable control the default.

**The scope rules are enforced at compile time**, not at runtime. This
matters: a Go implementation that defers the check to runtime would accept
programs CPython rejects.

### The `__spec__` difference between `import_module` and `__import__`

`importlib.import_module('a.b')` returns the module `a.b` itself, with a
fully-formed `__spec__`.

`__import__('a.b')` with an empty fromlist returns the **top-level package**
`a`. The `__spec__` of `a.b` is still set correctly in `sys.modules`; it is
just that the caller received `a` instead.

A Go implementation must not conflate the two. `import_module` is
`_gcd_import` with the fully-qualified name; `__import__` is `_gcd_import`
plus the top-level truncation.

### The `importlib.resources` and `importlib.metadata` APIs

**`importlib.resources`** is a **package** in 3.15 (`Lib/importlib/resources/`),
not a module. Its public surface:

| API | Purpose |
|---|---|
| `files(anchor)` | A `Traversable` for a package's resources |
| `as_file(traversable)` | A context manager yielding a real filesystem path |
| `as_binary(traversable)` | A context manager yielding the bytes |
| `as_data(traversable)` | A context manager yielding a data blob |
| `Traversable` | The protocol: `iterdir`, `read_bytes`, `read_text`, `is_dir`, `is_file`, `joinpath`, `open`, `name` |

**`importlib.metadata`** discovers installed distribution metadata:

| API | Purpose |
|---|---|
| `version(distribution_name)` | The version string |
| `metadata(distribution_name)` | The full metadata mapping |
| `files(distribution_name)` | The installed file list |
| `requires(distribution_name)` | The requirements |
| `entry_points(group=...)` | The entry points |
| `distribution(distribution_name)` | The `Distribution` object |
| `distributions()` | All discovered distributions |

Both are built on the import system's `get_resource_reader` protocol, which is
why the module system work is a prerequisite for them.

### Module-level `__getattr__` and `__dir__` (PEP 562)

A module may define a module-level `__getattr__(name)` function. When an
attribute is not found in the module's `__dict__`, the interpreter calls it.

This is how `os` provides `os.path` without importing `posixpath` eagerly, and
how many stdlib modules provide lazy attributes.

The lookup order for a module attribute:

1. The module's `__dict__`.
2. The module's `__getattr__` (PEP 562), if defined.
3. `AttributeError`.

`__dir__` on a module works the same way: a module-level `__dir__` function
provides the listing for `dir(module)`.

**The interaction with the import machinery:** PEP 562's `__getattr__` is
consulted by `IMPORT_FROM`'s first step (`getattr(module, name)`). If the
module defines `__getattr__`, the attribute lookup may succeed even though
the submodule was never imported. That is why the `sys.modules` fallback in
`_PyEval_ImportFrom` still matters.

### The `sys.path` initialisation and `.pth` processing

The order at interpreter startup:

1. `Py_Initialize` computes the path configuration. `Modules/getpath.c`
   implements the `PYTHONHOME` search and the landmark discovery.
2. `sys.path` is seeded with the computed entries.
3. The `site` module is imported, unless `-S` is given.

`site.py` then:

- Adjusts `sys.path[0]` for the invocation mode.
- Adds the user site directory (`~/.local/lib/pythonX.Y/site-packages` on
  POSIX).
- Adds the system site-packages directories.
- Processes the `.pth` files in each site directory, in alphabetical order.
- Imports `sitecustomize` if present, then `usercustomize` if present.

**`.pth` file processing.** Each line of a `.pth` file is one of:

| Line | Effect |
|---|---|
| Blank, or starting with `#` | Ignored |
| Starting with `import ` | Executed as `import <the rest>`. A failure is printed but does not stop startup. |
| Anything else | Treated as a path and **appended to `sys.path`**, resolved relative to the `.pth` file's directory. |

**PEP 829 (3.15) adds `.start` files**, which replace the executable `import`
lines in `.pth` files. A `.start` file contains a path to a Python source file
that is executed at startup.

The default `sys.path_hooks` entry is a single `FileFinder.path_hook` created
from the supported file loaders. It raises `ImportError` for a path entry that
is not a directory, which is how `PathFinder` skips non-directory entries.

### `importlib.invalidate_caches()`

The finder caches directory listings, keyed on the directory's mtime. When a
module is created on disk after the interpreter started, the cached listing is
stale.

`importlib.invalidate_caches()` walks `sys.meta_path` and calls
`invalidate_caches()` on every finder that has it. `PathFinder.invalidate_caches()`
does two things:

1. Calls `invalidate_caches()` on every finder in `sys.path_importer_cache`.
2. Increments `NamespacePath._epoch`, which invalidates the cached namespace
   package path computations.

**A Go implementation needs the same two effects.** The mtime-keyed directory
cache alone is not enough, because a namespace package's `__path__` is
computed lazily and cached separately.

## Verification

**1. Confirm the opcode numbers and the absence of `IMPORT_STAR`.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/opcode_ids.h \
  | grep -E "IMPORT"
```

Expect exactly two lines: `IMPORT_FROM` (71) and `IMPORT_NAME` (72). Expect
**no** `IMPORT_STAR`.

**2. Confirm the star import uses an intrinsic.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/codegen.c \
  | grep -B3 -A3 "INTRINSIC_IMPORT_STAR"
```

**3. Confirm the `IMPORT_NAME` mode bits.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/bytecodes.c \
  | grep -A12 "inst(IMPORT_NAME"
```

Expect the `_PyEval_LazyImportName` branch guarded by `!(oparg & 0x02)`.

**4. Confirm the compile-time lazy rules.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/codegen.c \
  | grep -E "lazy imports only allowed in module scope|cannot lazy import \*"
```

**5. Confirm the `IMPORT_FROM` fallback and the error messages.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/ceval.c \
  | grep -E "partially initialized module|consider renaming|_PyImport_GetModule"
```

Expect the `sys.modules` fallback via `PyImport_GetModule`.

**6. Confirm the runtime behaviour of the `IMPORT_FROM` fallback.**

```bash
mkdir -p /tmp/fb && cd /tmp/fb
cat > pkg.py <<'EOF'
import sys
from . import other          # circular: other is in sys.modules but not yet an attribute
EOF
cat > other.py <<'EOF'
value = 42
EOF
python3.15 -c "import sys; sys.path.insert(0,'/tmp/fb'); import pkg; print('ok')"
```

**7. Confirm the circular-import error message shape.**

```bash
mkdir -p /tmp/circ2 && cd /tmp/circ2
cat > a.py <<'EOF'
from b import thing
EOF
cat > b.py <<'EOF'
from a import missing
EOF
python3.15 -c "import sys; sys.path.insert(0,'/tmp/circ2'); import a"
```

Expect an `ImportError` whose message contains
`cannot import name 'missing' from partially initialized module 'a'`.

**8. Confirm the compile-time rejection of a lazy import outside module scope.**

```bash
printf 'def f():\n    lazy import os\n' > /tmp/lz.py
python3.15 -c "compile(open('/tmp/lz.py').read(), 'lz.py', 'exec')"
```

Expect a `SyntaxError` containing `lazy imports only allowed in module scope`.

**9. Confirm the `.pth` handling rules.**

```bash
mkdir -p /tmp/sitepth && printf '/tmp\n# a comment\n\nimport sys\n' > /tmp/sitepth/x.pth
python3.15 -S -c "
import site, sys
site.addsitedir('/tmp/sitepth')
print('/tmp' in sys.path)
"
```

Expect `True`.
