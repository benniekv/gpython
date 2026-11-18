# 02 - The Module Object Model and the Extension Protocol

## Overview

This file specifies the module object model and the extension-module initialisation
protocol, both of which a Go re-implementation must reproduce exactly.

The module object model is the set of special attributes every module carries
(`__name__`, `__file__`, `__spec__`, `__loader__`, `__package__`, `__path__`,
`__builtins__`, `__doc__`) and the rules for when each is set.

The extension protocol is the C-level contract between the interpreter and a
compiled module. Python 3.15 introduced a **unified slot mechanism**
(`Include/slots.h`, `Include/slots_generated.h`) that supersedes the older
`PyModuleDef_Slot` array. This is new in 3.15 and a Go implementation targeting
3.15 semantics should model the unified form.

Everything here was read from the CPython **v3.15.2** source.

## Sources

- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/moduleobject.h` -
  `PyModuleDef`, `PyModuleDef_Slot`, the `Py_MOD_*` constants (4,046 bytes).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/slots.h` -
  the new unified `PySlot` structure (56 lines).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/slots_generated.h` -
  the generated slot IDs, including the `Py_mod_*` values.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/cpython/import.h` -
  `_inittab` and `_frozen`.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/modsupport.h` -
  the `PyModule_Add*` family (160 lines).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Objects/moduleobject.c` -
  the slot dispatch switch.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/import.c` -
  the module-creation sequence, quoted verbatim in the source comment at line
  840 onward.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/modsupport.c` -
  the module-creation helpers.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap.py` -
  `_init_module_attrs`, `module_from_spec`.

## Spec

### The module object

A module is an instance of `ModuleType`. Its state is a single `__dict__`, which
holds both the module's own attributes and the special import attributes. There
is no separate slot for `__name__` - it is an ordinary dict entry.

```c
PyAPI_DATA(PyTypeObject) PyModule_Type;

#define PyModule_Check(op) PyObject_TypeCheck((op), &PyModule_Type)
#define PyModule_CheckExact(op) Py_IS_TYPE((op), &PyModule_Type)
```

(`Include/moduleobject.h`)

### The special attributes and when they are set

`_init_module_attrs(spec, module, *, override=False)` sets these. The order and
the conditions matter.

| Attribute | Condition | Value |
|---|---|---|
| `__name__` | always | `spec.name` |
| `__loader__` | always | `spec.loader` |
| `__package__` | if `None` (or `override`) | `spec.parent` |
| `__spec__` | always | the spec object |
| `__path__` | if `spec.submodule_search_locations is not None` | that list |
| `__file__` | if `spec._set_fileattr` and origin is not None | `spec.origin` |
| `__cached__` | if `spec._set_fileattr` and `spec.cached` is not None | `spec.cached` |
| `__builtins__` | if `None` (or `override`) | the builtins dict |
| `__doc__` | if `None` (or `override`) | `spec.loader.get_doc(spec)` |

The rules in words:

- **`__name__` and `__loader__` are always set**, overwriting any existing value.
- **`__package__`, `__builtins__` and `__doc__` are only set when currently
  `None`**, unless `override` is true.
- **`__path__` exists only for packages.** Its presence is what makes a module a
  package, and it is the test used throughout the import machinery
  (`hasattr(module, '__path__')`).
- **`__file__` is absent for namespace packages**, because their spec has
  `origin = None`.

### The `ModuleSpec`

| Field | Meaning |
|---|---|
| `name` | The fully-qualified module name |
| `loader` | The loader, or `None` for namespace packages |
| `origin` | The file path, or `None` |
| `submodule_search_locations` | The `__path__` list, or `None` for non-packages |
| `loader_state` | Arbitrary state passed from `create_module` to `exec_module` |
| `cached` | The bytecode cache path, or `None` |
| `parent` | The parent package's name; `''` for a top-level module |
| `_initializing` | `True` while the module body is executing |
| `_set_fileattr` | Whether `__file__` and `__cached__` should be set |
| `_uninitialized_submodules` | The list of children currently being imported |

`parent` is derived from the name: `'a.b.c'` → `'a.b'`; `'a'` → `''`.

### The inittab (builtin modules)

```c
struct _inittab {
    const char *name;           /* ASCII encoded string */
    PyObject* (*initfunc)(void);
};
// This is not used after Py_Initialize() is called.
PyAPI_DATA(struct _inittab *) PyImport_Inittab;
PyAPI_FUNC(int) PyImport_ExtendInittab(struct _inittab *newtab);
```

(`Include/cpython/import.h`)

The inittab is a static array of `{name, initfunc}` pairs terminated by a
`NULL` name. `PyImport_ExtendInittab` appends to it; it must be called before
`Py_Initialize` or it raises a fatal error.

The builtin module's init function has the signature `PyObject *(*)(void)` and
returns the module object.

### The frozen module table

```c
/* This structure is included verbatim in the public documentation
   (Doc/c-api/import.rst). */
struct _frozen {
    const char *name;                 /* ASCII encoded string */
    const unsigned char *code;
    int size;
    int is_package;
};

PyAPI_DATA(const struct _frozen *) PyImport_FrozenModules;
```

(`Include/cpython/import.h`)

A frozen module carries its **marshalled bytecode**, not source. `is_package`
marks it as a package (so `__path__` is set). `PyImport_FrozenModules` is a
pointer that an embedding application can replace with its own table.

CPython 3.15 freezes `importlib._bootstrap`, `importlib._bootstrap_external`,
`zipimport`, and the `encodings` package. The frozen tables are
`_PyImport_FrozenBootstrap`, `_PyImport_FrozenStdlib` and `_PyImport_FrozenTest`
(`Include/internal/pycore_import.h`), with aliasing via `_PyImport_FrozenAliases`.

### The `PyModuleDef` structure (legacy multi-phase)

```c
#ifndef _Py_OPAQUE_PYOBJECT
typedef struct PyModuleDef_Base {
  PyObject_HEAD
  /* The function used to re-initialize the module.
     This is only set for legacy (single-phase init) extension modules
     and only used for those that support multiple initializations
     (m_size >= 0).
     It is set by _PyImport_LoadDynamicModuleWithSpec()
     and _imp.create_builtin(). */
  PyObject* (*m_init)(void);
  /* The module's index into its interpreter's modules_by_index cache.
     This is set for all extension modules but only used for legacy ones.
     (See PyInterpreterState.modules_by_index for more info.)
     It is set by PyModuleDef_Init(). */
  Py_ssize_t m_index;
  /* A copy of the module's __dict__ after the first time it was loaded.
     This is only set/used for legacy modules that do not support
     multiple initializations.
     It is set by fix_up_extension() in import.c. */
  PyObject* m_copy;
} PyModuleDef_Base;

#define PyModuleDef_HEAD_INIT {  \
    PyObject_HEAD_INIT(_Py_NULL) \
    _Py_NULL, /* m_init */       \
    0,        /* m_index */      \
    _Py_NULL, /* m_copy */       \
  }
#endif  // _Py_OPAQUE_PYOBJECT

struct PyModuleDef {
  PyModuleDef_Base m_base;
  const char* m_name;
  const char* m_doc;
  Py_ssize_t m_size;
  PyMethodDef *m_methods;
  PyModuleDef_Slot *m_slots;
  traverseproc m_traverse;
  inquiry m_clear;
  freefunc m_free;
};
```

(`Include/moduleobject.h`)

Key points:

- **`m_size > 0` requests per-module state.** The state is a block of
  `m_size` bytes, retrieved with `PyModule_GetState(module)`. `m_size == 0`
  means no state. `m_size == -1` means "global state shared across
  interpreters".
- **`m_methods` is a `PyMethodDef` array.** The methods are added to the module
  dict automatically by `PyModule_FromDefAndSpec`.
- **`m_slots` is the legacy slot array** (the `PyModuleDef_Slot` form). It is
  superseded in 3.15 by the unified `PySlot` form.
- **`m_traverse`, `m_clear`, `m_free`** are the GC hooks for the module state.

### The legacy `PyModuleDef_Slot`

```c
/* New in 3.5 */
struct PyModuleDef_Slot {
    int slot;
    void *value;
};
```

(`Include/moduleobject.h`)

The legacy slot IDs, from `Include/slots_generated.h`:

```c
#define Py_mod_create _Py_SLOT_COMPAT_VALUE(1, 84)
#define Py_mod_exec _Py_SLOT_COMPAT_VALUE(2, 85)
#define Py_mod_multiple_interpreters _Py_SLOT_COMPAT_VALUE(3, 86)
#define Py_mod_gil _Py_SLOT_COMPAT_VALUE(4, 87)
```

(The `_Py_SLOT_COMPAT_VALUE(old, new)` form carries both the historical ID and
the new unified ID, so old and new slot tables interoperate.)

### The unified `PySlot` mechanism (new in 3.15)

```c
typedef void (*_Py_funcptr_t)(void);

struct PySlot {
    uint16_t sl_id;
    uint16_t sl_flags;
    _Py_ANONYMOUS union {
        uint32_t sl_reserved; // must be 0
    };
    _Py_ANONYMOUS union {
        void *sl_ptr;
        _Py_funcptr_t sl_func;
        Py_ssize_t sl_size;
        int64_t sl_int64;
        uint64_t sl_uint64;
    };
};

#define PySlot_OPTIONAL 0x0001
#define PySlot_STATIC 0x0002
#define PySlot_INTPTR 0x0004

#define Py_slot_invalid 0xffff

#define PySlot_DATA(NAME, VALUE) \
    {.sl_id=(NAME), .sl_flags=PySlot_INTPTR, .sl_ptr=(void*)(VALUE)}

#define PySlot_FUNC(NAME, VALUE) \
    {.sl_id=(NAME), .sl_func=(_Py_funcptr_t)(VALUE)}

#define PySlot_SIZE(NAME, VALUE) \
    {.sl_id=(NAME), .sl_size=(Py_ssize_t)(VALUE)}

#define PySlot_INT64(NAME, VALUE) \
    {.sl_id=(NAME), .sl_int64=(int64_t)(VALUE)}

#define PySlot_UINT64(NAME, VALUE) \
    {.sl_id=(NAME), .sl_uint64=(uint64_t)(VALUE)}

#define PySlot_STATIC_DATA(NAME, VALUE) \
    {.sl_id=(NAME), .sl_flags=PySlot_STATIC, .sl_ptr=(VALUE)}

#define PySlot_END {0, 0, {0}, {_Py_NULL}}
```

(`Include/slots.h`)

The full slot ID set, from `Include/slots_generated.h`:

| Slot ID | Meaning | Value type |
|---|---|---|
| `Py_mod_create` | Create the module object | function pointer |
| `Py_mod_exec` | Populate the module | function pointer |
| `Py_mod_multiple_interpreters` | Multi-interpreter support | uint64 |
| `Py_mod_gil` | Free-threading support | uint64 |
| `Py_mod_slots` | (marker) | - |
| `Py_mod_name` | Module name | pointer |
| `Py_mod_doc` | Module docstring | pointer |
| `Py_mod_state_size` | State size | ssize |
| `Py_mod_methods` | Method table | pointer |
| `Py_mod_state_traverse` | GC traverse hook | function pointer |
| `Py_mod_state_clear` | GC clear hook | function pointer |
| `Py_mod_state_free` | State destructor | function pointer |
| `Py_mod_abi` | ABI compatibility marker | pointer |
| `Py_mod_token` | One-time init token | pointer |

**This is a 3.15 change.** A 3.14 implementation would have only the
`PyModuleDef_Slot` array with `Py_mod_create`, `Py_mod_exec`,
`Py_mod_multiple_interpreters` and `Py_mod_gil`. The 3.15 form unifies the
module-definition metadata (name, doc, methods, state size) into the same slot
array, so a module can be defined entirely by slots with no `PyModuleDef`
struct at all.

### The slot dispatch

From `Objects/moduleobject.c`:

```c
switch (it.current.sl_id) {
    case Py_slot_invalid:
        goto error;
    case Py_mod_create:
        create = (createfunc_t)it.current.sl_func;
        break;
    case Py_mod_exec:
        if (!original_def) {
            if (m_exec) {
                PyErr_Format(
                    PyExc_SystemError,
                    "module %s has multiple Py_mod_exec slots",
                    name);
                goto error;
            }
            m_exec = (_Py_modexecfunc)it.current.sl_func;
        }
        break;
    case Py_mod_multiple_interpreters:
        multiple_interpreters = it.current.sl_uint64;
        break;
    case Py_mod_gil:
        {
            uint64_t val = it.current.sl_uint64;
            requires_gil = (val != (uint64_t)Py_MOD_GIL_NOT_USED);
        }
        break;
    case Py_mod_abi:
        if (PyABIInfo_Check(it.current.sl_ptr, name) < 0) {
            goto error;
        }
        break;
    ...
```

Key behaviours:

- **More than one `Py_mod_exec` slot is a `SystemError`**, not a silent
  last-one-wins.
- **`Py_mod_gil` uses a uint64**, and `Py_MOD_GIL_NOT_USED` means the module
  does not require the GIL. The default when the slot is absent is that the
  module **does** require the GIL.

### The `Py_MOD_*` constants

```c
/* for Py_mod_multiple_interpreters: */
#define Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED ((void *)0)
#define Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED ((void *)1)
#define Py_MOD_PER_INTERPRETER_GIL_SUPPORTED ((void *)2)

/* for Py_mod_gil: */
#define Py_MOD_GIL_USED ((void *)0)
#define Py_MOD_GIL_NOT_USED ((void *)1)
```

(`Include/moduleobject.h`)

Three levels of multi-interpreter support:

| Value | Meaning |
|---|---|
| `Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED` | The module cannot be loaded in a subinterpreter at all |
| `Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED` | The module can be loaded in multiple interpreters, sharing global state |
| `Py_MOD_PER_INTERPRETER_GIL_SUPPORTED` | The module supports a per-interpreter GIL |

And two levels of GIL use:

| Value | Meaning |
|---|---|
| `Py_MOD_GIL_USED` | The module uses the GIL (the default when the slot is absent) |
| `Py_MOD_GIL_NOT_USED` | The module is free-threading safe and never requests the GIL |

### The ABI marker

```c
#ifdef Py_BUILD_CORE
// For internal use in stdlib. Needs C99 compound literals.
// Defined here to avoid every stdlib module including pycore_modsupport.h
#define _Py_ABI_SLOT {Py_mod_abi, (void*) &(PyABIInfo) _PyABIInfo_DEFAULT}
#endif
```

(`Include/cpython/modsupport.h`)

The `_Py_ABI_SLOT` marker is inserted into the stdlib modules' slot arrays so
the build's ABI version must match at load time. A module built against a
different ABI is rejected at load rather than crashing.

### The module creation sequence

This is the authoritative sequence, quoted from the comment block in
`Python/import.c` (starting at line 840).

**Multi-phase init (`PyModInit_*`, returning a `PyModuleDef`):**

```
(6). every time:
     A. _imp_create_dynamic_impl() -> import_find_extension()  (not found)
     B. _imp_create_dynamic_impl() -> _PyImport_GetModuleExportHooks()
     C.   _PyImport_GetModuleExportHooks():  load <module init func>
     D. _imp_create_dynamic_impl() -> import_run_extension()
     E.     import_run_extension() -> _PyImport_RunModInitFunc()
     F.       _PyImport_RunModInitFunc():  call <module init func>
     G.     import_run_extension() -> PyModule_FromDefAndSpec()

     PyModule_FromDefAndSpec():
     H.      PyModule_FromDefAndSpec(): gather/check moduledef slots
     I.      if there's a Py_mod_create slot:
               1. PyModule_FromDefAndSpec():  call its function
     J.      else:
               1. PyModule_FromDefAndSpec() -> PyModule_NewObject()
     K:      PyModule_FromDefAndSpec():  set mod->md_def
     L:      PyModule_FromDefAndSpec() -> _add_methods_to_object()
     M:      PyModule_FromDefAndSpec() -> PyModule_SetDocString()

(10). every time:
     A. _imp_exec_dynamic_impl() -> exec_builtin_or_dynamic()
     B.   if mod->md_state == NULL (including if m_size == 0):
              1. exec_builtin_or_dynamic() -> PyModule_Exec()
              2.   PyModule_Exec():  allocate mod->md_state
              3.   if there's a Py_mod_exec slot:
                     1. PyModule_Exec():  call its function
```

**Multi-phase init via the slots array (`PyModExport_*`):**

```
(6). every time:
     ...
     F.     import_run_modexport():  call <module init func>
     G.     import_run_modexport() -> PyModule_FromSlotsAndSpec()
     H.       PyModule_FromSlotsAndSpec(): create temporary PyModuleDef-like
     I.       PyModule_FromSlotsAndSpec() -> PyModule_FromDefAndSpec()
```

**Single-phase init (legacy):**

```
(3). every time:
     A. _imp_create_dynamic_impl() -> import_find_extension()  (not found)
     B. _imp_create_dynamic_impl() -> _PyImport_GetModuleExportHooks()
     C.   _PyImport_GetModuleExportHooks():  load <module init func>
     D. _imp_create_dynamic_impl() -> import_run_extension()
     E.     import_run_extension() -> _PyImport_RunModInitFunc()
     F.       _PyImport_RunModInitFunc():  call <module init func>

(8). only the first time:
     A. fixup_extension_object() -> fixup_extension()
     B.   fixup_extension():  add the module to sys.modules
     C.   fixup_extension():  add to modules_by_index
```

The important structural facts:

1. **The create step and the exec step are separate.** `create` runs once per
   interpreter; `exec` runs every time the module is initialised in an
   interpreter.
2. **Without a `Py_mod_create` slot, `PyModule_NewObject()` makes a plain
   module.**
3. **`_add_methods_to_object()` runs during create**, so the module's methods
   are present before `exec_module`.
4. **`PyModule_SetDocString()` runs during create.**
5. **Module state is allocated during exec**, not create.
6. **Single-phase modules are cached globally.** The second and later
   initialisations of a single-phase module reuse the first module object's
   `__dict__` (via `m_copy`).

### The `PyModule_Add*` family

```c
// Add an attribute with name 'name' and value 'obj' to the module 'mod.
// On success, return 0.
// On error, raise an exception and return -1.
PyAPI_FUNC(int) PyModule_AddObjectRef(PyObject *mod, const char *name, PyObject *value);

// Similar to PyModule_AddObjectRef() but steal a reference to 'value'.
PyAPI_FUNC(int) PyModule_Add(PyObject *mod, const char *name, PyObject *value);

// Similar to PyModule_AddObjectRef() and PyModule_Add() but steal
// a reference to 'value' on success and only on success.
// Errorprone. Should not be used in new code.
PyAPI_FUNC(int) PyModule_AddObject(PyObject *mod, const char *, PyObject *value);

PyAPI_FUNC(int) PyModule_AddIntConstant(PyObject *, const char *, long);
PyAPI_FUNC(int) PyModule_AddStringConstant(PyObject *, const char *, const char *);
PyAPI_FUNC(int) PyModule_AddType(PyObject *module, PyTypeObject *type);

#define PyModule_AddIntMacro(m, c) PyModule_AddIntConstant((m), #c, (c))
#define PyModule_AddStringMacro(m, c) PyModule_AddStringConstant((m), #c, (c))

PyAPI_FUNC(int) PyModule_SetDocString(PyObject *, const char *);
PyAPI_FUNC(int) PyModule_AddFunctions(PyObject *, PyMethodDef *);
PyAPI_FUNC(int) PyModule_ExecDef(PyObject *module, PyModuleDef *def);
```

(`Include/modsupport.h`)

The ownership rules:

| Function | Reference semantics |
|---|---|
| `PyModule_AddObjectRef` | Borrows. The caller keeps its reference. |
| `PyModule_Add` | Steals on success only. On failure the caller still owns it. |
| `PyModule_AddObject` | Steals on success only. **Documented as error-prone; do not use in new code.** |

`PyModule_AddType` (3.9+) is the type-safe variant: it increments the type's
reference count rather than stealing it.

### The `PyModule_Create2` macro

```c
#define Py_CLEANUP_SUPPORTED 0x20000

PyAPI_FUNC(PyObject *) PyModule_Create2(PyModuleDef*, int apiver);

#ifdef Py_LIMITED_API
#define PyModule_Create(module) \
        PyModule_Create2((module), PYTHON_ABI_VERSION)
#else
#define PyModule_Create(module) \
        PyModule_Create2((module), PYTHON_API_VERSION)
#endif
```

(`Include/modsupport.h`)

The API version is checked at module creation. A module built against a
different API version is rejected.

### The `PyMethodDef` structure

```c
struct PyMethodDef {
    const char  *ml_name;
    PyCFunction  ml_meth;
    int          ml_flags;
    const char  *ml_doc;
};
```

The `ml_flags` select the calling convention:

| Flag | Convention |
|---|---|
| `METH_VARARGS` | `(self, *args)` |
| `METH_KEYWORDS` | `(self, *args, **kwargs)` - requires `METH_VARARGS` or `METH_FASTCALL` |
| `METH_NOARGS` | `(self)` |
| `METH_O` | `(self, arg)` |
| `METH_FASTCALL` | `(self, *args)` in a C array, vectorcall protocol |
| `METH_METHOD` | `(self, obj, *args)` - the `self` is a bound method's object |
| `METH_CLASS` | The function is a classmethod |
| `METH_STATIC` | The function is a staticmethod |
| `METH_COEXIST` | The function coexists with a dict entry of the same name |
| `METH_FASTCALL | METH_KEYWORDS` | `(self, *args, **kwargs)` in the vectorcall protocol |

`METH_FASTCALL` is the modern default for new code because it avoids building a
tuple for the arguments.

### The two init function types

```c
/* The module init function. */
typedef PyObject *(*PyModInitFunction)(void);
typedef PySlot *(*PyModExportFunction)(void);
```

(`Include/internal/pycore_importdl.h`)

**`PyModInitFunction`** returns a `PyObject *`. For the multi-phase protocol it
returns a `PyModuleDef *`; for the single-phase protocol it returns the module
object itself.

**`PyModExportFunction`** returns a `PySlot *` - a slot array. This is the
**new 3.15 export-hook form**, and it is the mechanism that lets a module be
defined entirely by slots with no `PyModuleDef` struct.

The loader looks up both symbols:

```c
extern int _PyImport_GetModuleExportHooks(
    struct _Py_ext_module_loader_info *info,
    FILE *fp, PyModInitFunction *modinit, PyModExportFunction *modexport);
```

(`Include/internal/pycore_importdl.h`)

The runtime side of the export hook:

```c
static PyObject *
import_run_modexport(PyThreadState *tstate, PyModExportFunction ex0,
                     struct _Py_ext_module_loader_info *info,
                     PyObject *spec)
{
    /* This is like import_run_extension, but avoids interpreter switching
     * and code for for single-phase modules.
     */
    PySlot *slots = ex0();
    if (!slots) {
        if (!PyErr_Occurred()) {
            PyErr_Format(
                PyExc_SystemError,
                "module export hook for module %R failed without setting an exception",
                info->name);
        }
        return NULL;
    }
    if (PyErr_Occurred()) {
        PyErr_Format(
            PyExc_SystemError,
            "module export hook for module %R raised unreported exception",
            info->name);
    }
    PyObject *result = PyModule_FromSlotsAndSpec(slots, spec);
```

(`Python/import.c:2085`)

Two failure modes are normalised into `SystemError`: a hook that returns NULL
without setting an exception, and a hook that raises without reporting it.

`PyModule_FromSlotsAndSpec` is new in 3.15 and is limited-API-safe:

```c
#if !defined(Py_LIMITED_API) || Py_LIMITED_API+0 >= _Py_PACK_VERSION(3, 15)
PyAPI_FUNC(PyObject *) PyModule_FromSlotsAndSpec(const PySlot *slots,
                                                 PyObject *spec);
PyAPI_FUNC(int) PyModule_Exec(PyObject *module);
PyAPI_FUNC(int) PyModule_GetStateSize(PyObject *module, Py_ssize_t *result);
PyAPI_FUNC(int) PyModule_GetToken(PyObject *module, void **result);
#endif
```

(`Include/moduleobject.h`)

### The extension loading sequence (POSIX)

From `Python/importdl.c` and `Include/internal/pycore_import.h`:

1. `import_find_extension()` searches each `sys.path` entry for
   `<name>.<EXT_SUFFIX>`. `EXT_SUFFIX` is `.cpython-<XY>-<platform>-<abi>.so`
   on Linux, `.pyd` on Windows.
2. `_PyImport_GetModuleExportHooks()` opens the shared library:
   - POSIX: `dlopen(pathname, _Py_DLOPEN_FLAGS)` where the flags are
     `RTLD_NOW` if available, else `RTLD_LAZY`.
   - Windows: `LoadLibraryExW(pathname, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)`.
3. The init symbol is `PyInit_<name>`, where `<name>` has dots replaced by
   underscores. A module `foo.bar` looks for `PyInit_foo_bar`.
4. `dlsym(handle, "PyInit_foo_bar")` retrieves it. If the symbol is absent,
   the import fails with `ImportError: dynamic module does not define module
   export function (PyInit_foo)`.
5. The handle is cached in a per-module map so the library is not reopened.
6. The init function is called. For the multi-phase protocol it returns a
   `PyModuleDef *`; for the single-phase protocol it returns a `PyObject *`
   that is the module itself.

The `dlopen` flags, from `Include/internal/pycore_import.h`:

```c
#ifdef HAVE_DLOPEN
#  include <dlfcn.h>              // RTLD_NOW, RTLD_LAZY
#  if HAVE_DECL_RTLD_NOW
#    define _Py_DLOPEN_FLAGS RTLD_NOW
#  else
#    define _Py_DLOPEN_FLAGS RTLD_LAZY
#  endif
#  define DLOPENFLAGS_INIT .dlopenflags = _Py_DLOPEN_FLAGS,
```

### The free-threading model

Python 3.13 introduced a free-threaded build (`Py_GIL_DISABLED`). The
module-level contract is the `Py_mod_gil` slot:

- **Absent** → the module requires the GIL. The interpreter enables the GIL
  around the module's execution.
- **`Py_MOD_GIL_NOT_USED`** → the module never touches the GIL. It is safe in
  the free-threaded build without a per-module GIL.
- **`Py_MOD_GIL_USED`** → the module uses the GIL explicitly.

The slot values are `uint64` in the unified scheme.

In the free-threaded build there is also:

```c
#if !defined(Py_LIMITED_API)
#  if defined(Py_GIL_DISABLED)
PyAPI_FUNC(int) PyUnstable_Module_SetGIL(PyObject *module, void *gil);
#  endif
#endif
```

(`Include/moduleobject.h`)

This lets a module acquire a per-module GIL at runtime. The name is
`PyUnstable_` prefixed because the API is not stable.

### The limited API (stable ABI)

`Py_LIMITED_API` restricts the C API to a stable subset. The gate is
`Py_LIMITED_API+0 >= 0x030X0000`, where `030X0000` encodes the minimum
version. For example:

```c
#if !defined(Py_LIMITED_API) || Py_LIMITED_API+0 >= 0x03050000
PyAPI_FUNC(PyObject *) PyModuleDef_Init(PyModuleDef*);
PyAPI_DATA(PyTypeObject) PyModuleDef_Type;
#endif
```

A Go implementation does not need the limited API itself, but it does need to
know **which module APIs are stable**, because a stable API is a commitment
that a module written against it keeps working. The 3.15 additions that are
limited-API-safe are worth knowing:

| API | Minimum version |
|---|---|
| `PyModule_AddObjectRef` | 3.10 |
| `PyModule_Add` | 3.13 |
| `PyModule_AddType` | 3.9 |
| `PyModuleDef_Init`, `PyModuleDef_Type` | 3.5 |
| `PyModule_SetDocString`, `PyModule_AddFunctions`, `PyModule_ExecDef` | 3.5 |
| `Py_mod_multiple_interpreters` constants | 3.12 |
| `Py_mod_gil` constants | 3.13 |
| `PyModule_FromSlotsAndSpec`, `PyModule_Exec`, `PyModule_GetStateSize`, `PyModule_GetToken` | 3.15 |

### The `imp` module's C surface

The pure-Python import layer calls into C through `_imp`. The complete method
table, from `Python/import.c` (`imp_methods[]`, line 5609):

| `_imp` member | Purpose |
|---|---|
| `extension_suffixes` | The list of valid extension suffixes on this platform |
| `lock_held` | Whether the global import lock is currently held |
| `acquire_lock` | Acquire the global import lock |
| `release_lock` | Release the global import lock |
| `find_frozen` | Find a frozen module by name |
| `get_frozen_object` | Instantiate a frozen module from its marshalled code |
| `is_frozen_package` | Whether a frozen module is a package |
| `create_builtin` | Instantiate a builtin module from the inittab |
| `init_frozen` | Initialise a frozen module |
| `is_builtin` | Test whether a name is a builtin |
| `is_frozen` | Test whether a name is frozen |
| `_frozen_module_names` | The names of all frozen modules |
| `_override_frozen_modules_for_tests` | Test hook: replace the frozen tables |
| `_override_multi_interp_extensions_check` | Test hook: override the multi-interpreter extension check |
| `create_dynamic` | `dlopen` and create an extension module |
| `exec_dynamic` | Run an extension's exec slot |
| `exec_builtin` | Run a builtin's init function |
| `_fix_co_filename` | Rewrite a code object's filename |
| `source_hash` | Compute the source hash for the bytecode cache |
| `_set_lazy_attributes` | Set the lazy-submodule attributes |
| `check_hash_based_pycs` | The `--check-hash-based-pycs` mode, as a module constant |
| `pyc_magic_number_token` | The bytecode magic number, as a module constant |

Note that `_imp` does **not** expose `create_module`, `exec_module`,
`create_dynamic_spec` or `init_frozen` under those names in 3.15; the actual
names are `create_builtin`, `init_frozen`, `create_dynamic` and `exec_dynamic`
as listed above.

This is the seam between the two languages. A Go implementation should have an
equivalent internal package that the orchestrator calls, with the same
division of labour: the orchestrator handles policy, the native layer handles
the things that need the runtime.

For reference, the `_imp` module's own definition shows the canonical slot
usage, including the ABI marker:

```c
static PyModuleDef_Slot imp_slots[] = {
     _Py_ABI_SLOT,
    {Py_mod_exec, imp_module_exec},
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    {0, NULL}
};

static struct PyModuleDef imp_module = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_imp",
    .m_doc = doc_imp,
    .m_size = 0,
    .m_methods = imp_methods,
    .m_slots = imp_slots,
};
```

### The lazy import machinery (3.15)

3.15 adds lazy submodule imports. The internal C API, from
`Include/internal/pycore_import.h`:

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

The Python-side entry is `_find_and_load_lazy_submodule(name, import_)`, which
calls `_find_and_load(..., lazy_submodule=True)`. In that mode, a missing
specifier returns `None` instead of raising `ModuleNotFoundError`.

### Go design notes

A Go implementation of this model maps as follows:

| CPython concept | Go equivalent |
|---|---|
| `PyModuleDef` | A Go struct describing the module: name, doc, methods, state size, slots |
| `PyMethodDef` | A Go slice of `{Name, Fn, Flags, Doc}` where `Fn` is `func(self *py.Module, args []py.Object) (py.Object, error)` |
| `Py_mod_exec` | A Go function `func(m *py.Module) error` run after the module is registered in `sys.modules` |
| `Py_mod_create` | A Go function `func(spec *py.Spec) (*py.Module, error)` |
| Module state (`m_size > 0`) | A `[]byte` or a typed struct pointer stored on the Go module object |
| `Py_mod_gil` | Not applicable - Go has goroutines, not a GIL. But the free-threading semantics (no shared mutable state without synchronisation) still apply |
| `Py_mod_multiple_interpreters` | Relevant: gpython supports multi-context, so the module state must be per-context |
| `Py_mod_abi` | A Go analogue: a version constant that must match the host |
| The inittab | A Go slice of `{Name string, Init func() (*Module, error)}` |
| The frozen table | A Go slice of `{Name string, Code []byte, IsPackage bool}` |

**The multi-context interaction is the important design point.** gpython runs
multiple independent interpreter contexts in one process. CPython's builtin
modules with `m_size == -1` (global state) are shared across subinterpreters.
In gpython, the equivalent decision is per-module: does the module hold state
that must be per-context, or can it be shared? Because gpython's contexts are
goroutine-isolated rather than OS-thread-isolated, a shared module's state
needs a mutex.

## Verification

**1. Confirm the module attribute rules on a real interpreter.**

```bash
python3.15 -c "
import xml.etree.ElementTree as ET
m = ET
print('__name__     :', m.__name__)
print('__package__  :', m.__package__)
print('__loader__   :', type(m.__loader__).__name__)
print('__spec__.parent:', m.__spec__.parent)
print('__path__     :', m.__path__ is not None)
print('__file__     :', m.__file__ is not None)
"
```

**2. Confirm the namespace package has no `__file__`.**

```bash
mkdir -p /tmp/nspkg2 && cd /tmp && python3.15 -c "
import nspkg2
print('__file__:', nspkg2.__file__)
print('__path__:', list(nspkg2.__path__))
print('__spec__.origin:', nspkg2.__spec__.origin)
"
```

Expect `__file__` `None` and a non-empty `__path__`.

**3. Confirm the `Py_mod_*` slot IDs exist as claimed.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/slots_generated.h \
  | grep -E "define Py_mod_"
```

Expect `Py_mod_create`, `Py_mod_exec`, `Py_mod_multiple_interpreters`,
`Py_mod_gil`, `Py_mod_slots`, `Py_mod_name`, `Py_mod_doc`, `Py_mod_state_size`,
`Py_mod_methods`, `Py_mod_state_traverse`, `Py_mod_state_clear`,
`Py_mod_state_free`, `Py_mod_abi`, `Py_mod_token`.

**4. Confirm the `PyModuleDef` layout.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/moduleobject.h \
  | grep -A12 "^struct PyModuleDef {"
```

Expect `m_base`, `m_name`, `m_doc`, `m_size`, `m_methods`, `m_slots`,
`m_traverse`, `m_clear`, `m_free`.

**5. Confirm the module creation sequence is unchanged.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/import.c \
  | grep -n -A40 "for multi-phase init modules from PyModInit_\*"
```

Expect the `PyModule_FromDefAndSpec` steps H through M, and the separate
`PyModule_Exec` step under "(10). every time".

**6. Confirm the reference extension modules exist and their init symbols follow
the naming rule.**

```bash
for f in xxmodule xxsubtype _testmultiphase _testsinglephase; do
  echo "--- $f ---"
  curl -s "https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/$f.c" \
    | grep -E "^PyInit_|Py_mod_exec|Py_mod_create|Py_mod_gil"
done
```

**7. Confirm the multi-phase handshake at runtime.** The `xx` module is a
multi-phase reference implementation:

```bash
python3.15 -c "
import xx
print(xx.__doc__)
print([n for n in dir(xx) if not n.startswith('__')])
"
```
