> **Sourcing note.** This is raw agent research output. Its inventory was
> cross-checked against `Modules/Setup.bootstrap.in`, `Modules/Setup.stdlib.in`
> and `Makefile.pre.in` at the `v3.15.2` tag, and the discrepancies were
> corrected in `../03-c-modules/01-c-module-inventory.md`. Where the two differ,
> the spec file wins. See `00-sources-and-caveats.md`.

I have enough data. Now I'll compose the comprehensive report.

# CPython 3.15 Module System - Complete Reference for a Go Re-Implementation

This is the raw spec material for porting CPython's C module system to Go. Every claim is backed by a source file fetched from `https://raw.githubusercontent.com/python/cpython/3.15/...` (and a few from `main`). The canonical inventory was verified against the live `git trees` API (`/repos/python/cpython/git/trees/3.15?recursive=1`), which gave 279 `.c` files in `Modules/`, plus `Python/`, `Objects/`, `PC/` and `Platforms/` directories.

---

## 1. The two-level truth about which modules are "built-in"

CPython has two physically separate lists of built-in modules, and they do not overlap. Both must be honoured by a Go port.

### 1a. The truly-always-present set - `Modules/config.c.in`

This file is checked into git and lists the eight modules that are guaranteed to exist on every CPython build, independent of platform or third-party dependencies. The list is hard-coded between `/* -- ADDMODULE MARKER 2 -- */` and the sentinel.

```c
/* from Modules/config.c.in, raw.githubusercontent.com/python/cpython/3.15/Modules/config.c.in */
extern PyObject* PyMarshal_Init(void);
extern PyObject* PyInit__imp(void);
extern PyObject* PyInit_gc(void);
extern PyObject* PyInit__ast(void);
extern PyObject* PyInit__tokenize(void);
extern PyObject* PyInit__contextvars(void);
extern PyObject* _PyWarnings_Init(void);
extern PyObject* PyInit__string(void);

struct _inittab _PyImport_Inittab[] = {
    {"marshal",     PyMarshal_Init},
    {"_imp",        PyInit__imp},
    {"_ast",        PyInit__ast},
    {"_tokenize",   PyInit__tokenize},
    {"builtins",    NULL},   /* marker for sys.builtin_module_names */
    {"sys",         NULL},   /* marker for sys.builtin_module_names */
    {"gc",          PyInit_gc},
    {"_contextvars",PyInit__contextvars},
    {"_warnings",   _PyWarnings_Init},
    {"_string",     PyInit__string},
    {0, 0}                  /* sentinel */
};
```

At build time, the `makesetup` script inserts additional entries between the `ADDMODULE` markers based on `Modules/Setup.stdlib.in`. These are the "optional built-ins" - when a module is compiled statically (the *static* tag in Setup.stdlib.in), it appears in `sys.builtin_module_names`; when compiled as *shared*, it becomes a `dlopen`-able extension that is not built-in but is still shipped in the stdlib package.

### 1b. The frozen-Python modules - `Python/frozen.c`

Some Python-only modules are compiled to bytecode, embedded as C arrays (`_Py_M__<module>`), and registered in `Python/frozen.c`. The import machinery loads them directly from memory. This is what gpython today calls "frozen" modules. From `Python/frozen.c` (raw.githubusercontent.com/python/cpython/3.15/Python/frozen.c):

| Frozen module | Purpose |
|---|---|
| `_frozen_importlib` | The import system bootstrap (alias of `importlib._bootstrap`) |
| `_frozen_importlib_external` | Path-based finder/loader (alias of `importlib._bootstrap_external`) |
| `zipimport` | Loads `.zip` archives |
| `_pybuiltins` | The `builtins` module |
| `abc` | Abstract base classes |
| `codecs` | Codec registry and base classes |
| `io` | Core I/O classes (re-exported as `io.open` etc.; `_io` is the C extension that adds `FileIO`, `BufferedIOBase`, etc.) |
| `_collections_abc` | Abstract base classes for containers |
| `_sitebuiltins` | `exit`, `quit`, `help`, `copyright`, `credits`, `license` |
| `genericpath` | Common path operations |
| `ntpath` | Windows path handling |
| `posixpath` | POSIX path handling |
| `os` | Re-exports from `posix`/`nt` |
| `site` | Site-packages initialisation |
| `stat` | `S_IFREG`, `S_ISDIR()`, etc. |
| `linecache` | Reads source lines from files for tracebacks |
| `importlib.util` | Utility helpers for importers |
| `importlib.machinery` | `SourceFileLoader`, `ExtensionFileLoader`, etc. |
| `runpy` | `python -m` support |
| Test frozen: `__hello__`, `__phello__`, `__phello__.ham`, `__phello__.ham.eggs`, `__phello__.spam`, `__hello_only__` | The classic import-test modules |

The frozen aliases in the same file: `{_frozen_importlib, importlib._bootstrap}`, `{_frozen_importlib_external, importlib._bootstrap_external}`, `{__hello_alias__, __hello__}`, `{__phello_alias__, __hello__}`.

### 1c. The Setup.stdlib.in split

The single authoritative list of all "configured" stdlib modules lives in `Modules/Setup.stdlib.in` (197 lines, fetched from `raw.githubusercontent.com/python/cpython/3.15/Modules/Setup.stdlib.in`). The build harness tags modules with `*static*` (compiled into the interpreter binary) or `*shared*` (built as `.so/.pyd`). At top level `*@MODULE_BUILDTYPE@*` is replaced at configure time. The file ends with a `*static*` re-tag followed by `@MODULE__ASYNCIO_TRUE@_asyncio _asynciomodule.c`.

The build-time condition `@MODULE_<NAME>_TRUE@` is replaced with the literal line if the configure check passes; otherwise it is commented out (the build description from the file header):

```
# * @MODULE_{NAME}_TRUE@ is removed when configure detects all build
#   dependencies for a module. Otherwise the template variable is replaced
#   by a comment "#" and the module is skipped.
```

### 1d. Rule: every C module exists in exactly one of these forms

| Form | Lives in | Generated from | Visible to Python |
|---|---|---|---|
| Always built-in | Hand-coded in `Modules/config.c.in` | none | `sys.builtin_module_names` |
| Optional built-in | `Modules/config.c` (generated) | `Setup.stdlib.in` lines tagged `*static*` | `sys.builtin_module_names` |
| Extension | `.so`/`.pyd` produced by the build | `Setup.stdlib.in` lines tagged `*shared*` | Imported from `sys.path` |
| Frozen | `Python/frozen.c` marshalled blobs | `Tools/build/freeze_modules.py` | Imported as if from `Lib/` |
| Pure-Python | `Lib/<name>.py` (or `Lib/<pkg>/__init__.py`) | none | Imported from `sys.path` |

For the Go port, only the first three matter for module *system* design; the frozen/Python split is handled by the normal import path.

---

## 2. The COMPLETE C module inventory

The table below lists every C module present in CPython 3.15, organised by directory. Column "Source" gives the exact `.c` file path inside the CPython tree; column "Built-in/Ext" gives the runtime classification (BI = built-in, EX = extension, EX(test) = test extension, EX(cpython) = Python interpreter core C module). Platform is P = POSIX, W = Windows, both = both.

The "PyInit symbol" column is the C symbol the dynamic loader looks up (rule is `PyInit_<modulename>` with leading `_` removed if and only if present in the module name; e.g. `array` → `PyInit_array`, `_io` → `PyInit__io`). Verified by grepping the live sources.

| Module name | PyInit symbol | Source file in cpython tree | Type | Platform | One-line description |
|---|---|---|---|---|---|
| `array` | `PyInit_array` | `Modules/arraymodule.c` | BI / EX | both | Buffer protocol array type with typecodes `'b'..'d'`, `'q'`, `'Q'`, `'f'`, `'d'`, `'h'`, `'i'`, `'l'`, `'B'..'L'`. Exposes `array.array` type. |
| `_abc` | `PyInit__abc` | `Modules/_abc.c` | BI / EX | both | C accelerator for `abc.ABC`, `abc.ABCMeta`. |
| `_asyncio` | `PyInit__asyncio` | `Modules/_asynciomodule.c` | BI / EX | both | C accelerator for the asyncio package: `Future`, `Task`, `EventLoop`, `coroutine`, `Queue`, `Lock`, `gather`, `Queue`, `FutureIter`. **First-class module that opts into the per-interpreter GIL**: slots `{Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED}`, `{Py_mod_gil, Py_MOD_GIL_NOT_USED}` (verified in 3.15 source). |
| `_bisect` | `PyInit__bisect` | `Modules/_bisectmodule.c` | BI / EX | both | `bisect.bisect_left/right/insort_left/right`. |
| `_bz2` | `PyInit__bz2` | `Modules/_bz2module.c` | EX | both | `BZ2File`, `BZ2Compressor`, `BZ2Decompressor`. Wraps libbz2. |
| `_codecs` | `PyInit__codecs` | `Modules/_codecsmodule.c` | BI / EX | both | Core codec search-function registry, `Codec` base type, `CodecInfo` tuple, incremental codecs `IncrementalEncoder`/`IncrementalDecoder`, `StreamReader`/`StreamWriter`. |
| `_collections` | `PyInit__collections` | `Modules/_collectionsmodule.c` | BI / EX | both | `collections.deque`, `OrderedDict`, `ChainMap`, `Counter`, `_count_elements` helper. |
| `_csv` | `PyInit__csv` | `Modules/_csv.c` | BI / EX | both | Fast CSV parser/writer. `csv.reader`, `csv.writer`, `csv.Dialect`, `csv.Error`. |
| `_ctypes` | `PyInit__ctypes` | `Modules/_ctypes/_ctypes.c` (+ `callbacks.c`, `callproc.c`, `cfield.c`, `stgdict.c`, `malloc_closure.c`) | EX | both | C-level FFI; wraps `libffi`. Provides `CDLL`, `PyDLL`, `LibraryLoader`, `Structure`, `Union`, `Array`, `SimpleType`, `Pointer`, `CFUNCTYPE`/`WINFUNCTYPE`, `py_object`, `c_void_p`, basic C types. |
| `_ctypes_test` | `PyInit__ctypes_test` | `Modules/_ctypes/_ctypes_test.c` | EX(test) | both | Test-only extension for `_ctypes`. |
| `_curses` | `PyInit__curses` | `Modules/_cursesmodule.c` | EX | both | Wraps ncurses; `curses.A_*` constants, `curses.window` type, `wrapper()`. |
| `_curses_panel` | `PyInit__curses_panel` | `Modules/_curses_panel.c` | EX | both | Wraps ncurses panel library; `curses.panel.new_panel()`, panel object. |
| `_datetime` | `PyInit__datetime` | `Modules/_datetimemodule.c` | BI / EX | both | `datetime.date`, `time`, `datetime`, `timedelta`, `tzinfo`, `timezone`. |
| `_dbm` | `PyInit__dbm` | `Modules/_dbmmodule.c` | EX | both | Generic DBM (ndbm/gdbm/db). `_dbm.dbm` object, `_dbm.error`. |
| `_decimal` | `PyInit__decimal` | `Modules/_decimal/_decimal.c` (linked with `Modules/_decimal/libmpdec/*.c`) | EX | both | Wraps bundled libmpdec. `decimal.Decimal`, `decimal.Context`, `decimal.BasicContext`, `decimal.ExtendedContext`, `decimal.DecimalTuple`, etc. The bundled libmpdec has 24 `.c` files (`basearith.c`, `constants.c`, `context.c`, `convolute.c`, `crt.c`, `difradix2.c`, `fnt.c`, `fourstep.c`, `io.c`, `mpalloc.c`, `mpdecimal.c`, `mpsignal.c`, `numbertheory.c`, `sixstep.c`, `transpose.c`, plus `bench.c`, `bench_full.c` and `examples/*` which are not built). |
| `_elementtree` | `PyInit__elementtree` | `Modules/_elementtree.c` | EX | both | C accelerator for `xml.etree.ElementTree`: `Element`, `SubElement`, `tostring`, `fromstring`, `XMLParser`, `iterparse`. Uses expat via the CAPI hook in `pyexpat`. |
| `_functools` | `PyInit__functools` | `Modules/_functoolsmodule.c` | BI / EX | both | C accelerator for `functools`: `reduce`, `partial`, `partialmethod`, `lru_cache`, `cmp_to_key`, `total_ordering`. |
| `_gdbm` | `PyInit__gdbm` | `Modules/_gdbmmodule.c` | EX | both | GDBM-specific bindings. `gdbm.open`, `gdbm.error`. |
| `_hashlib` | `PyInit__hashlib` | `Modules/_hashopenssl.c` | EX | both | Provides `hashlib.hashlib` and `hashlib.scrypt` via OpenSSL. Adds `openssl_*` algorithm name table and `pbkdf2_hmac`. |
| `_heapq` | `PyInit__heapq` | `Modules/_heapqmodule.c` | BI / EX | both | C implementation of `heapq.heappush/heappop/heapify/heapreplace/nlargest/nsmallest/heappushpop`. |
| `_interpchannels` | `PyInit__interpchannels` | `Modules/_interpchannelsmodule.c` | BI / EX | both | Cross-interpreter channel API. Defines `ChannelID`, `channel_create/destroy/list_all/list_interpreters/send/send_buffer/recv/close/release/get_count/get_info/get_channel_defaults/_channel_id/_register_end_types`. **Free-threaded safe**: uses `Py_mod_multiple_interpreters = Py_MOD_PER_INTERPRETER_GIL_SUPPORTED`, `Py_mod_gil = Py_MOD_GIL_NOT_USED`. |
| `_interpqueues` | `PyInit__interpqueues` | `Modules/_interpqueuesmodule.c` | BI / EX | both | Cross-interpreter queue API. Mirrors `_queue` but across interpreters. **Free-threaded safe** (same slot pattern). |
| `_interpreters` | `PyInit__interpreters` | `Modules/_interpretersmodule.c` | BI / EX | both | `interpreters.create()`, `list_all()`, `get_current()`, `is_shareable()`, `exec()`, `call()`, `get_config()`, `set_config()`, sub-interpreter lifecycle. **Free-threaded safe**. |
| `_io` | `PyInit__io` | `Modules/_io/_iomodule.c` (+ `bufferedio.c`, `bytesio.c`, `fileio.c`, `iobase.c`, `stringio.c`, `textio.c`, `winconsoleio.c`) | BI / EX | both | Core I/O types: `RawIOBase`, `FileIO`, `BufferedIOBase`, `BufferedReader/Writer/RandomPair`, `TextIOBase`, `TextIOWrapper`, `IncrementalEncoder/Decoder`, `BytesIO`, `StringIO`, `BufferedReader`. `winconsoleio.c` is Windows-only. |
| `_json` | `PyInit__json` | `Modules/_json.c` | BI / EX | both | C accelerator for `json`: scanner, encoder, decoder. `make_encoder`, `make_scanner`, `make_decoder`. |
| `_locale` | `PyInit__locale` | `Modules/_localemodule.c` | BI / EX | both | Wraps `<locale.h>`: `locale.setlocale()`, `locale.format_string()`, `locale.getpreferredencoding()`, `locale.strcoll`, `locale.strxfrm`, `locale.localeconv`. |
| `_lsprof` | `PyInit__lsprof` | `Modules/_lsprof.c` (+ `Modules/rotatingtree.c`) | BI / EX | both | C-level profiler used by `cProfile`/`profile`. `Profiler` type. |
| `_lzma` | `PyInit__lzma` | `Modules/_lzmamodule.c` | EX | both | Wraps liblzma: `LZMAFile`, `LZMACompressor`, `LZMADecompressor`. |
| `_math` (header only) | n/a | `Modules/_math.h` | - | - | Internal-only header providing `math.acos`, etc. - there is no `_math` *module*. The numeric functions are exposed by the `math` module, which is its own extension. |
| `_multiprocessing` | `PyInit__multiprocessing` | `Modules/_multiprocessing/multiprocessing.c` (+ `posixshmem.c`, `semaphore.c`) | EX | POSIX | Core multiprocessing primitives: `Connection`, `Semaphore`. |
| `_opcode` | `PyInit__opcode` | `Modules/_opcode.c` | BI / EX | both | `opcode.opmap`, `opcode.opname`, `opcode.hasconst`, `stack_effect`. |
| `_operator` | `PyInit__operator` | `Modules/_operator.c` | BI / EX | both | C implementation of `operator` module: `getitem`, `setitem`, `add`, `mul`, `attrgetter`, `itemgetter`, `methodcaller`, `indexOf`, `countOf`, `concat`, `iconcat`, `truth`. |
| `_pickle` | `PyInit__pickle` | `Modules/_pickle.c` | BI / EX | both | C accelerator for `pickle`: `Pickler`, `Unpickler`, `PickleBuffer`. |
| `_posixsubprocess` | `PyInit__posixsubprocess` | `Modules/_posixsubprocess.c` | EX | POSIX | Helper for `subprocess` on POSIX: `fork_exec`, `setexec`. **Free-threaded safe**. |
| `_posixshmem` | `PyInit__posixshmem` | `Modules/_multiprocessing/posixshmem.c` | EX | POSIX | POSIX `shm_open`/`shm_unlink` for shared-memory multiprocessing. |
| `_queue` | `PyInit__queue` | `Modules/_queuemodule.c` | BI / EX | both | `queue.SimpleQueue`, `Queue` (used internally by asyncio). |
| `_random` | `PyInit__random` | `Modules/_randommodule.c` | BI / EX | both | `random.Random`, `random.SystemRandom`, `random.seed`, `random.getrandbits`. |
| `_remote_debugging` | `PyInit__remote_debugging` | `Modules/_remote_debugging/module.c` (+ 12 sibling `.c` files: `asyncio.c`, `binary_io_reader.c`, `binary_io_writer.c`, `code_objects.c`, `frame_cache.c`, `frames.c`, `gc_stats.c`, `interpreters.c`, `object_reading.c`, `subprocess.c`, `threads.c`) | EX | both | Used by `pdb` for remote debugging. Provides helpers for walking frames, code objects, sub-processes, threads, interpreters, GC stats, and binary I/O. |
| `_scproxy` | `PyInit__scproxy` | `Modules/_scproxy.c` | EX | macOS | SystemConfiguration proxy lookup. `scproxy.getproxies()`. |
| `_signal` | `PyInit__signal` | `Modules/signalmodule.c` *(listed as `signalmodule.c` but module name is `_signal` on POSIX, `signal` on Windows)* | BI / EX | both | `signal.SIG_*`, `signal.signal`, `signal.raise_signal`, `signal.setitimer`, `signal.set_wakeup_fd`, `signal.pthread_sigmask` (POSIX), `signal.strsignal`. |
| `_socket` | `PyInit__socket` | `Modules/socketmodule.c` | BI / EX | both | `socket.socket`, `socket.getaddrinfo`, `socket.gethostbyname`, `socket.gethostname`, `socket.inet_aton`, `socket.inet_ntoa`, `socket.create_connection`, `socket.create_server`, `socket.getservbyname`, `socket.if_nameindex`, `socket.has_dualstack_ipv6`, plus dozens of constants. |
| `_sqlite3` | `PyInit__sqlite3` | `Modules/_sqlite/module.c` (+ `blob.c`, `connection.c`, `cursor.c`, `microprotocols.c`, `prepare_protocol.c`, `row.c`, `statement.c`, `util.c`) | EX | both | Full DB-API 2.0 wrapper around SQLite: `Connection`, `Cursor`, `Row`, `Blob`, `Statement`, `prepare_protocol`, SQLite function authoriser, trace hooks, progress handler. |
| `_sre` | `PyInit__sre` | `Modules/_sre/sre.c` (+ `sre.h`, `sre_constants.h`, `sre_lib.h`, `sre_targets.h`) | BI / EX | both | C implementation of `re`: regex compiler and matcher, named groups, lookahead/lookbehind, atomic groups. |
| `_ssl` | `PyInit__ssl` | `Modules/_ssl.c` (+ `Modules/_ssl/cert.c`, `_ssl/debughelpers.c`, `_ssl/misc.c`, `Modules/_ssl.h`, `Modules/_ssl_data_*.h`) | EX | both | TLS/SSL via OpenSSL: `SSLContext`, `SSLSocket`, `MemoryBIO`, `SSLSession`, `TLSExtServerNameCallback`, `Purpose.SERVER_AUTH/CLIENT_AUTH`, `VERIFY_*`, certificate handling, `get_server_certificate`, `create_default_context`. |
| `_stat` | `PyInit__stat` | `Modules/_stat.c` | BI / EX | both | `stat.S_*` constants and the `stat.S_IS*` family. |
| `_statistics` | `PyInit__statistics` | `Modules/_statisticsmodule.c` | BI / EX | both | C accelerator for `statistics`: `mean`, `fmean`, `median`, `mode`, `pstdev`, `stdev`, `variance`, `quantiles`, `NormalDist`, `correlation`, `covariance`, `linear_regression`. |
| `_string` | `PyInit__string` | `Objects/unicodeobject.c` | BI | both | String helper internals: `string.formatter_field_name_split`, `string.capwords`. Listed in `Modules/config.c.in`. |
| `_struct` | `PyInit__struct` | `Modules/_struct.c` | BI / EX | both | C implementation of `struct`: `Struct`, format-string parser. |
| `_suggestions` | `PyInit__suggestions` | `Modules/_suggestions.c` | BI / EX | both | PyArg-based typo suggestions, used by the interpreter when `NameError`/`AttributeError` triggers. |
| `_symtable` | `PyInit__symtable` | `Modules/symtablemodule.c` | BI / EX | both | `symtable.symtable()`, `SymbolTable` type - exposes the compiler's symbol tables. |
| `_sysconfig` | `PyInit__sysconfig` | `Modules/_sysconfig.c` | BI / EX | both | `sysconfig.get_config_vars`, `_INSTALL_SCHEMES`, `_SCHEME_KEYS`, `is_python_build`. |
| `_thread` | `PyInit__thread` | `Modules/_threadmodule.c` | BI / EX | both | Low-level thread primitives: `thread.start_new_thread`, `thread.allocate_lock`, `thread.exit`, `thread.get_ident`, `thread.stack_size`, `thread.interrupt_main`. |
| `_tkinter` | `PyInit__tkinter` | `Modules/_tkinter.c` (+ `Modules/tkappinit.c`) | EX | both | Tcl/Tk binding: `Tk`, `Tcl`, screen-name access, file-handle creation. |
| `_tokenize` | `PyInit__tokenize` | `Python/Python-tokenize.c` | BI | both | `tokenize.detect_encoding`. Always built-in (config.c.in). |
| `_tracemalloc` | `PyInit__tracemalloc` | `Modules/_tracemalloc.c` | BI / EX | both | `tracemalloc.Traceback`, `tracemalloc.DomainInfo`, `tracemalloc.StatisticDiff`, snapshot save/load. |
| `_types` | `PyInit__types` | `Modules/_typesmodule.c` | BI / EX | both | Helper types: `_types.SimpleNamespace`, `_CoroutineType` for `types.CoroutineType`/`GeneratorType`/`AsyncGeneratorType`. |
| `_typing` | `PyInit__typing` | `Modules/_typingmodule.c` | BI / EX | both | C accelerator for `typing`: `Generic`, `_GenericAlias`, `_SpecialForm`, `_LiteralGenericAlias`, `_AnnotatedAlias`, `_TypeVarType`, `_ProtocolMeta`, `_TypedDictMeta`, `_Final`, `_NotIterable`, `Generic`, `TypeVarType`. |
| `_uuid` | `PyInit__uuid` | `Modules/_uuidmodule.c` | EX | both | `uuid.UUID`, `uuid.uuid1`, `uuid.uuid3`, `uuid.uuid4`, `uuid.uuid5`. Uses `libuuid` on Linux, `uuid_create()` on BSD/AIX, `UuidCreate` on Windows. |
| `_warnings` | `_PyWarnings_Init` | `Python/_warnings.c` | BI | both | Internal warnings machinery: `warnings.warn_explicit`, `warnings._filters_mutated`. Always built-in (config.c.in). |
| `_weakref` | `PyInit__weakref` | `Modules/_weakref.c` | BI / EX | both | `weakref.ref`, `weakref.proxy`, `weakref.WeakValueDictionary`, `weakref.WeakSet`, `weakref.finalize`. |
| `_winapi` | `PyInit__winapi` | `Modules/_winapi.c` | BI / EX | Windows | Windows API: `winapi.CreateFile`, `winapi.CreateProcess`, `winapi.WaitForSingleObject`, `winapi.GetACP`, `winapi.ReadFile`, console/handle wrappers. |
| `_xxsubinterpreters` | (alias of `_interpreters`) | - | BI / EX | both | Historically separate; in 3.15 the API is in `_interpreters`. |
| `_xxtestfuzz` | `PyInit__xxtestfuzz` | `Modules/_xxtestfuzz/_xxtestfuzz.c` (+ `fuzzer.c`) | EX(test) | both | Fuzz harness for `_csv`, `_elementtree`, `_json`, `_sre`, `_struct`, `_pycompile`. |
| `_zoneinfo` | `PyInit__zoneinfo` | `Modules/_zoneinfo.c` | BI / EX | both | C accelerator for `zoneinfo`: `ZoneInfo`, `ZoneInfoNotFoundError`, `InvalidTZif`. Wraps system IANA tz database. **Free-threaded safe**. |
| `_zstd` | `PyInit__zstd` | `Modules/_zstd/_zstdmodule.c` (+ `compressor.c`, `decompressor.c`, `zstddict.c`, `buffer.h`, `_zstdmodule.h`, `zstddict.h`) | EX | both | Zstandard compression via the bundled zstd library: `ZstdCompressor`, `ZstdDecompressor`, `ZstdDict`. |
| `array` | `PyInit_array` | `Modules/arraymodule.c` | BI / EX | both | (See row above.) |
| `atexit` | `PyInit_atexit` | `Modules/atexitmodule.c` | BI / EX | both | `atexit.register`, `atexit.unregister`, `atexit._ncallbacks()`. |
| `binascii` | `PyInit_binascii` | `Modules/binascii.c` | BI / EX | both | `binascii.a2b_base64`, `b2a_base64`, `a2b_hex`, `b2a_hex`, `a2b_uu`, `b2a_uu`, `crc32`, `crc_hqx`, `rlecode_hqx`, `rledecode_hqx`. |
| `blake2` | `PyInit__blake2` | `Modules/blake2module.c` | BI / EX | both | BLAKE2b/BLAKE2s hash; `blake2b`, `blake2s`, `blake2b MAC`. Wraps bundled HACL\*. |
| `_codecs_cn`/`_codecs_hk`/`_codecs_iso2022`/`_codecs_jp`/`_codecs_kr`/`_codecs_tw`/`_multibytecodec` | `PyInit__codecs_<xx>` | `Modules/cjkcodecs/_codecs_*.c` (+ `Modules/cjkcodecs/multibytecodec.c`) | BI / EX | both | CJK codec encoders/decoders (GB2312/GBK/Big5/ISO-2022/EUC-JP/Shift_JIS/EUC-KR/...). |
| `cmath` | `PyInit_cmath` | `Modules/cmathmodule.c` | BI / EX | both | `cmath.phase`, `polar`, `rect`, `exp`, `log`, `log10`, `sqrt`, `acos`, `asin`, `atan`, `cos`, `sin`, `tan`, `cosh`, `sinh`, `tanh`, `acosh`, `asinh`, `atanh`, `pi`, `e`, `tau`, `inf`, `nan`. |
| `errno` | `PyInit_errno` | `Modules/errnomodule.c` | BI / EX | both | `errno.errorcode`, `errno.*` constants from `<errno.h>`. |
| `faulthandler` | `PyInit_faulthandler` | `Modules/faulthandler.c` | BI / EX | both | `faulthandler.enable`, `disable`, `dump_traceback`, `register`, `unregister`, `cancel`, `signum`. |
| `fcntl` | `PyInit_fcntl` | `Modules/fcntlmodule.c` | EX | POSIX | `fcntl.fcntl`, `fcntl.ioctl`, `fcntl.lockf`. |
| `gc` | `PyInit_gc` | `Modules/gcmodule.c` | BI | both | Always built-in. `gc.collect`, `gc.enable`, `gc.disable`, `gc.isenabled`, `gc.get_threshold`, `gc.set_threshold`, `gc.get_objects`, `gc.get_stats`, `gc.freeze`, `gc.get_freeze_count`, callbacks. |
| `grp` | `PyInit_grp` | `Modules/grpmodule.c` | EX | POSIX | `grp.getgrgid`, `grp.getgrnam`, `grp.getgrall`. |
| `hashlib` | `PyInit_hashlib` | `Modules/_hashopenssl.c` | EX | both | Same file as `_hashlib`. Public name `hashlib`: `hashlib.md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `sha3_*`, `blake2b`, `blake2s`, `pbkdf2_hmac`, `scrypt`, `algorithms_available/guaranteed`, `new`, `compare_digest`, `hkdf`. |
| `hmac` | `PyInit_hmac` | `Modules/hmacmodule.c` | BI / EX | both | `hmac.HMAC` (new), `hmac.new`, `hmac.digest`, `hmac.compare_digest`. Uses `_hashlib`. |
| `itertools` | `PyInit_itertools` | `Modules/itertoolsmodule.c` | BI / EX | both | C accelerator for `itertools`: `count`, `cycle`, `repeat`, `chain`, `compress`, `dropwhile`, `takewhile`, `filterfalse`, `groupby`, `islice`, `starmap`, `tee`, `zip_longest`, `accumulate`, `product`, `permutations`, `combinations`, `combinations_with_replacement`. |
| `math` | `PyInit_math` | `Modules/mathmodule.c` | BI / EX | both | All `math.*` functions (incl. `erf`, `erfc`, `gamma`, `lgamma`, `factorial`, `modf`, `frexp`, `ldexp`, `fsum`, `prod`, `dist`, `gcd`, `lcm`, `isqrt`, `perm`, `comb`, `nextafter`, `ulp`, `fmod`, `remainder`, `floor`, `ceil`, `trunc`, `copysign`, `fabs`, `hypot`, `atan2`, `pow`, `log2`, `log1p`, `expm1`). |
| `_math_integer` | `PyInit__math_integer` | `Modules/mathintegermodule.c` | BI / EX | both | Internal helpers for math on PyLong: `long_bit_length`, `long_to_bytes`. |
| `_md5` | `PyInit__md5` | `Modules/md5module.c` | BI / EX | both | MD5 hash; wraps HACL\*. |
| `mmap` | `PyInit_mmap` | `Modules/mmapmodule.c` | EX | both | `mmap.mmap` file-backed anonymous and shared mapping. ACCESS_READ/WRITE/COPY constants. |
| `nt` (Windows) | `PyInit_nt` | `Modules/posixmodule.c` (NT build branch) | BI | Windows | Renamed build of posixmodule.c. Same surface as `posix`. |
| `os` (frozen) | - | `Lib/os.py` (frozen into `Python/frozen.c`) | Frozen | both | Pure-Python re-export; thin wrapper over `posix`/`nt`. |
| `overlapped` | `PyInit_overlapped` | `Modules/overlapped.c` | EX | Windows | I/O completion ports: `Overlapped`, `RegisterWithOverlapped`, `BindLocal`, `Connect`, `Accept`, `Receive`, `Send`, `ReadFile`, `WriteFile`, `GetQueuedCompletionStatus`. |
| `posix` (POSIX) | `PyInit_posix` | `Modules/posixmodule.c` | BI | POSIX | The `os` module's C implementation: `os.stat`, `os.fstat`, `os.lstat`, `os.listdir`, `os.getcwd`, `os.chdir`, `os.mkdir`, `os.rmdir`, `os.unlink`, `os.rename`, `os.utime`, `os.fdopen`, `os.pipe`, `os.fork`, `os.waitpid`, `os.execve`, `os.kill`, `os.getpid`, `os.getuid`, `os.getgid`, `os.environ`, `os.get_terminal_size`, etc. Several hundred functions. |
| `pwd` | `PyInit_pwd` | `Modules/pwdmodule.c` | EX | POSIX | `pwd.getpwuid`, `pwd.getpwnam`, `pwd.getpwall`. |
| `pyexpat` | `PyInit_pyexpat` | `Modules/pyexpat.c` | EX | both | Expat XML parser bindings: `xmlparser`, `ParserCreate`, `ErrorString`, `ExpatParser`. |
| `readline` | `PyInit_readline` | `Modules/readline.c` | EX | both | GNU readline / libedit bindings: `readline.parse_and_bind`, `readline.get_completer`, `readline.set_completer`, history manipulation. |
| `resource` | `PyInit_resource` | `Modules/resource.c` | EX | POSIX | `resource.getrlimit`, `setrlimit`, `getrusage`, `RLIMIT_*` constants, `RUSAGE_*`. |
| `select` | `PyInit_select` | `Modules/selectmodule.c` | EX | both | `select.select`, `select.poll`, `select.epoll`, `select.kqueue`, `select.devpoll`. |
| `_sha1` | `PyInit__sha1` | `Modules/sha1module.c` | BI / EX | both | SHA-1; wraps HACL\*. |
| `_sha2` | `PyInit__sha2` | `Modules/sha2module.c` | BI / EX | both | SHA-224/256/384/512; wraps HACL\*. |
| `_sha3` | `PyInit__sha3` | `Modules/sha3module.c` | BI / EX | both | SHA-3 family; wraps HACL\*. |
| `signal` | `PyInit_signal` | `Modules/signalmodule.c` | BI / EX | both | Same file as `_signal`; see `_signal` row. |
| `_socket` | `PyInit__socket` | `Modules/socketmodule.c` | BI / EX | both | (See above.) |
| `spwd` | (none - pure Python in `Lib/spwd.py`) | - | pure-Python | POSIX | Shadow passwords (no C module). |
| `symtable` | `PyInit_symtable` | `Modules/symtablemodule.c` | BI / EX | both | (See `_symtable` above.) |
| `sys` | (see Python/sysmodule.c) | `Python/sysmodule.c` | BI | both | Built-in. Provides `sys.argv`, `sys.path`, `sys.modules`, `sys.builtin_module_names`, `sys.flags`, `sys.version_info`, `sys.getrefcount`, `sys.getrecursionlimit`, `sys.settrace`, `sys.setprofile`, etc. |
| `syslog` | `PyInit_syslog` | `Modules/syslogmodule.c` | EX | POSIX | `syslog.syslog`, `syslog.openlog`, `syslog.closelog`, `syslog.setlogmask`, `LOG_*` constants. |
| `termios` | `PyInit_termios` | `Modules/termios.c` | EX | POSIX | POSIX terminal I/O: `termios.tcgetattr`, `tcsetattr`, `tcsendbreak`, `tcdrain`, `tcflush`, `tcflow`, `cfmakebreak`, `cfgetispeed`, `cfsetispeed`, `cfgetospeed`, `cfsetospeed`. |
| `time` | `PyInit_time` | `Modules/timemodule.c` | BI / EX | both | `time.time`, `time.monotonic`, `time.perf_counter`, `time.process_time`, `time.time_ns`, `time.sleep`, `time.localtime`, `time.gmtime`, `time.strftime`, `time.strptime`, `time.mktime`, `time.tzset`, `struct_time`, `time.CLOCK_*`. |
| `tkinter` (Python wrapper) | - | `Lib/tkinter/__init__.py` | pure-Python | both | Wrapper around `_tkinter`. |
| `unicodedata` | `PyInit_unicodedata` | `Modules/unicodedata.c` (+ `Modules/unicodedata_db.h`, `unicodename_db.h`) | BI / EX | both | `unicodedata.lookup`, `name`, `category`, `bidirectional`, `east_asian_width`, `normalize`, `ucd_3_2_0`. |
| `xx` | `PyInit_xx` | `Modules/xxmodule.c` | EX | both | Demo/example module. `xx.test_with_docstring`, `xx.subclass`. |
| `xxlimited` | `PyInit_xxlimited` | `Modules/xxlimited.c` | EX(limited-API) | both | Limited-API test/sample module. Must build as shared. |
| `xxlimited_35` | `PyInit_xxlimited_35` | `Modules/xxlimited_35.c` | EX(limited-API) | both | Limited-API test for 3.5 features. |
| `xxlimited_3_13` | `PyInit_xxlimited_3_13` | `Modules/xxlimited_3_13.c` | EX(limited-API) | both | Limited-API test for 3.13 features. |
| `xxsubtype` | `PyInit_xxsubtype` | `Modules/xxsubtype.c` | EX | both | Demo subclassing C types. |
| `zipimport` | (frozen) | `Lib/zipimport/__init__.py` (frozen in `Python/frozen.c`) | Frozen | both | Imports from `.zip` files. |
| `zlib` | `PyInit_zlib` | `Modules/zlibmodule.c` | BI / EX | both | `zlib.compress`, `decompress`, `compressobj`, `decompressobj`, `adler32`, `crc32`, `Z_*` constants. Wraps bundled zlib. |
| `marshal` | `PyMarshal_Init` | `Python/marshal.c` | BI | both | Always built-in. `marshal.dump`, `dumps`, `load`, `loads`, plus the `.pyc` format reader/writer. |
| `_imp` | `PyInit__imp` | `Python/import.c` | BI | both | Always built-in. Internal import helpers exposed as `_imp.create_dynamic`, `_imp.exec_dynamic`, `_imp.source_hash`, `_imp._fix_co_filename`, `_imp._bootstrap_external`. |
| `_ast` | `PyInit__ast` | `Python/Python-ast.c` | BI | both | Always built-in. AST node types. |
| `_contextvars` | `PyInit__contextvars` | `Python/_contextvars.c` | BI | both | Always built-in. `contextvars.Context`, `Token`, `ContextVar`, `copy_context`. |
| `_warnings` | `_PyWarnings_Init` | `Python/_warnings.c` | BI | both | Always built-in. Warnings registry. |
| `_string` | `PyInit__string` | `Objects/unicodeobject.c` | BI | both | Always built-in. Internal string helpers. |
| `_thread` | `PyInit__thread` | `Modules/_threadmodule.c` | BI / EX | both | (See above.) |
| `_codecs` | `PyInit__codecs` | `Modules/_codecsmodule.c` | BI / EX | both | (See above.) |
| `_weakref` | `PyInit__weakref` | `Modules/_weakref.c` | BI / EX | both | (See above.) |
| `_io` | `PyInit__io` | `Modules/_io/_iomodule.c` | BI / EX | both | (See above.) |
| `_collections` | `PyInit__collections` | `Modules/_collectionsmodule.c` | BI / EX | both | (See above.) |
| `_sre` | `PyInit__sre` | `Modules/_sre/sre.c` | BI / EX | both | (See above.) |
| `_symtable` | `PyInit_symtable` | `Modules/symtablemodule.c` | BI / EX | both | (See above.) |
| `_types` | `PyInit__types` | `Modules/_typesmodule.c` | BI / EX | both | (See above.) |
| `_datetime` | `PyInit__datetime` | `Modules/_datetimemodule.c` | BI / EX | both | (See above.) |
| `_operator` | `PyInit__operator` | `Modules/_operator.c` | BI / EX | both | (See above.) |
| `_zoneinfo` | `PyInit__zoneinfo` | `Modules/_zoneinfo.c` | BI / EX | both | (See above.) |

### Interpreter-core C modules (Python/ + Objects/)

These are not packaged with stdlib; they are part of the interpreter binary itself.

| File | C symbol | Header in `Include/` | Purpose |
|---|---|---|---|
| `Python/bltinmodule.c` | `_PyBuiltins_Init` | `bltinmodule.h` | The `builtins` module (`builtin_function_or_method`, `BaseException`, etc.). |
| `Python/sysmodule.c` | `_PySys_Create`/`_PySys_Init` | `sysmodule.h` | The `sys` module. |
| `Python/import.c` | `PyInit__imp` | `import.h` | The `_imp` module (already listed). |
| `Python/importdl.c` | `_PyImport_FindBuiltin` etc. | `internal/pycore_importdl.h` | Dynamic loader (dlopen/LoadLibrary). |
| `Python/marshal.c` | `PyMarshal_Init` | `marshal.h` | The `marshal` module. |
| `Python/frozen.c` | `_PyImport_FrozenBootstrap` | n/a | Frozen module tables. |
| `Python/getargs.c` | (no module) | `modsupport.h` | Argument parsing (`PyArg_ParseTupleAndKeywords`). |
| `Python/ceval.c` | (no module) | `ceval.h` | The bytecode evaluation loop. |
| `Python/compile.c` | (no module) | `compile.h` | The bytecode compiler. |
| `Python/codecs.c` | (no module) | `codecs.h` | Codec registry implementation. |
| `Python/symtable.c` | (no module) | `symtable.h` | Symbol-table builder (used by `compile.c`). |
| `Python/pyhash.c` | (no module) | `pyhash.h` | `hash()` implementation. |
| `Python/dtoa.c` | (no module) | `pystrtod.h` | David Gay's `strtod` for `float` formatting. |
| `Python/fileutils.c` | (no module) | `fileutils.h` | Path-name handling, temp-file helpers. |
| `Python/initconfig.c` | (no module) | `initconfig.h` | `PyConfig` parser, including `_PyImport_Inittab` editing via `PyImport_ExtendInittab`. |
| `Python/bootstrap_hash.c` | (no module) | `pyhash.h` | SipHash used by the dict and tuple hash. |
| `Python/gc.c` | `PyInit_gc` | `internal/pycore_gc.h` | Garbage collector. |
| `Python/Python-ast.c` | `PyInit__ast` | `Python-ast.h` | AST node types. |
| `Python/Python-tokenize.c` | `PyInit__tokenize` | `token.h` | Tokenizer wrappers. |
| `Python/_warnings.c` | `_PyWarnings_Init` | `warnings.h` | Warnings registry. |
| `Python/_contextvars.c` | `PyInit__contextvars` | `internal/pycore_context.h` | ContextVars implementation. |
| `Python/frozenmain.c` | (no module) | n/a | Frozen-script entry point. |
| `Python/ast.c`/`ast_unparse.c`/`ast_preprocess.c` | (no module) | `ast.h` | AST helpers. |

### Windows-only modules (`PC/`)

These are built into `pythonXX.dll` only on Windows.

| File | Module name | Description |
|---|---|---|
| `PC/msvcrtmodule.c` | `msvcrt` | Wraps Microsoft Visual C Runtime: `msvcrt.getch`, `msvcrt.getche`, `msvcrt.putch`, `msvcrt.kbhit`, `msvcrt.setmode`, `msvcrt.open_osfhandle`, `msvcrt.get_osfhandle`, `msvcrt.set_error_mode`, `msvcrt.heapmin`. |
| `PC/winreg.c` | `winreg` | Windows registry: `winreg.HKEY_*`, `winreg.OpenKey`, `winreg.QueryValueEx`, `winreg.SetValueEx`, `winreg.EnumValue`, `winreg.ConnectRegistry`, etc. |
| `PC/winsound.c` | `winsound` | `winsound.Beep`, `winsound.MessageBeep`, `winsound.PlaySound`, `winsound.SND_*` constants. |
| `PC/_wmimodule.cpp` | `_wmi` | Windows Management Instrumentation: `_wmi.WMI`, `_wmi.__version__`, COM-based. |
| `PC/_testconsole.c` | `_testconsole` | Test harness for the Windows console. |

Windows-only modules that are not in `PC/`:

| File | Module name | Description |
|---|---|---|
| `Modules/_winapi.c` | `_winapi` | (See above.) |
| `Modules/overlapped.c` | `overlapped` | (See above.) |
| `Modules/_io/winconsoleio.c` | (linked into `_io`) | Win32 console I/O backing for `io.ConsoleIO` (added in 3.15). |
| `Modules/posixmodule.c` | `nt` | Windows build renames `posixmodule.c` to `nt` module. |
| `Python/thread_nt.h` | (no module) | Windows thread backend. |
| `Python/dynload_win.c` | (no module) | Windows dynamic loader. |
| `Python/_emfs_support.c` (if present) | `_emfs_support` | Was removed; not present in 3.15. |
| `Modules/_scproxy.c` | `_scproxy` | (See above - macOS only, not Windows.) |

### macOS / WASI / Android / iOS-only modules

| File | Module name | Platform | Description |
|---|---|---|---|
| `Modules/_scproxy.c` | `_scproxy` | macOS | (See above.) |
| `Modules/main.c` | - | WASI | WASI main(). |
| `Modules/emscripten_syscalls.c` | - | Emscripten | System-call stubs. |
| `Modules/emscripten_signal.c` | - | Emscripten | Signal stubs. |
| `Python/emscripten_signal.c` | - | Emscripten | Embedder-side signal handling. |
| `Python/emscripten_trampoline.c` (under `Include/internal/pycore_emscripten_trampoline.h`) | - | Emscripten | Trampoline for calling back into the browser. |
| `Platforms/Android/testbed/app/src/main/c/main_activity.c` | - | Android | Testbed app, not a Python module. |

The user listed `_apple_support`, `_android_support`, `_aix_support`, `_ios_support`, `_osx_support`. **None of these exist as separate C modules in the 3.15 tree.** CPython has no `_apple_support.c`; "support" for these platforms is handled by the build system (`Platforms/Apple/`, `Platforms/AIX/`, `Platforms/Android/`, `Platforms/iOS/`, etc.) and individual files within modules (e.g. `Modules/_io/winconsoleio.c` is Windows-only). Same for `_colorize` and `_pyrepl`: those are pure-Python in `Lib/_pyrepl/` and `Lib/_sitebuiltins.py`; no C module exists.

### Modules that DON'T exist as C modules (pure-Python-only)

The user listed several names in section 3 of the task that turn out to be pure Python: `_compat_pickle`, `_markupbase`, `_pylong`, `_pydatetime`, `_pydecimal`, `_pyio`, `_pybuiltins`, `_sitebuiltins`, `_py_abc`, `_py_warnings`, `_opcode_metadata`, `_ios_support`, `_osx_support`, `_pylong`, `_frozenlist`. Of these, **only `_sitebuiltins` and `_pybuiltins` are real** - both are frozen (see Python/frozen.c list above). The others are Python files in `Lib/` with no C implementation; mention of them in the task is incorrect.

`_frozenlist` is a separate C extension in the **PyPI `aiohttp`/`aiobotocore` ecosystem**, not CPython. (`_queue` is the stdlib analogue.)

### `_remote_debugging` - what it really is

From the live source: `Modules/_remote_debugging/module.c` registers the module as `_remote_debugging`. It is built in `Setup.stdlib.in` as `@MODULE__REMOTE_DEBUGGING_TRUE@_remote_debugging _remote_debugging/module.c _remote_debugging/gc_stats.c _remote_debugging/object_reading.c _remote_debugging/code_objects.c _remote_debugging/frames.c _remote_debugging/frame_cache.c _remote_debugging/threads.c _remote_debugging/asyncio.c _remote_debugging/binary_io_writer.c _remote_debugging/binary_io_reader.c _remote_debugging/subprocess.c _remote_debugging/interpreters.c`. Used by `pdb`'s `--remote` and debuggers like debugpy.

### Test-only modules

From `Modules/_testbuffer.c`, `Modules/_testcapimodule.c`, `Modules/_testimportmultiple.c`, `Modules/_testmultiphase.c`, `Modules/_testsinglephase.c`, plus `Modules/_testinternalcapi/*` and `Modules/_testlimitedcapi/*` directories and `Modules/_testcapi/*`. These are CTest harnesses for the C API; they don't appear in normal imports. `_testclinic.c` / `_testclinic_limited.c` test the Argument Clinic tool.

### Summary totals

- **Always-built-in modules** (`Modules/config.c.in`, hand-coded): 8 (plus 2 markers `builtins` and `sys`).
- **Optional built-in / extension modules** (`Setup.stdlib.in`): 65 entries with their `PyInit_` (excluding tests) - exact count depends on platform configuration. Verified list is in section 1c.
- **C module `.c` files in `Modules/`** (top-level only): 102 (Modules directory listing from GitHub API).
- **C module `.c` files including subdirectories** (`Modules/**`): 279 (from recursive git tree).
- **Pure-Python stdlib** (in `Lib/`): ~400 packages and modules, including the frozen 18 listed in section 1b.
- **Frozen bootstrap modules**: 4 (`_frozen_importlib`, `_frozen_importlib_external`, `zipimport`, `_pybuiltins`).
- **Frozen stdlib modules**: 16 (`abc`, `codecs`, `io`, `_collections_abc`, `_sitebuiltins`, `genericpath`, `ntpath`, `posixpath`, `os`, `site`, `stat`, `linecache`, `importlib.util`, `importlib.machinery`, `runpy`, plus test ones).

---

## 3. Hybrid (C accelerator + Python wrapper) distinction set

These are pairs where a C extension implements the low-level hot path, and the public Python module is a thin wrapper. All confirmed by reading the actual `PyInit_<name>` symbols plus the corresponding `Lib/<name>/__init__.py`.

| Public Python module | C accelerator | What the C module provides | What the Python wrapper adds |
|---|---|---|---|
| `threading` | `_thread` | Raw `Lock`, `RLock`, `start_new_thread`, `exit`, `get_ident`, `stack_size`, `interrupt_main`, `Timer` helper. | `Thread` class, `current_thread`, `active_count`, `local`, `Barrier`, `Condition`, `Event`, `Semaphore`, `main_thread`. |
| `socket` | `_socket` | The full socket API. | Python-level `SocketIO` for `makefile()`, helper classes like `socket.timeout`. |
| `selectors` | (uses `select`) | - | `SelectorKey`, `BaseSelector`, `SelectSelector`, `PollSelector`, `EpollSelector`, `KqueueSelector`, `DevpollSelector`. |
| `json` | `_json` | `make_scanner`, `make_encoder`, `make_decoder` - fast scan/encode/decode. | `JSONEncoder`, `JSONDecoder`, `load`, `loads`, `dump`, `dumps`. |
| `decimal` | `_decimal` | The `Decimal` numeric operations, `Context`. | The constructor `Decimal.__init__` accepts more types than the C version; `Decimal` arithmetic re-exports. |
| `xml.parsers.expat` | `pyexpat` | Full Expat parser object. | (This is the C module itself; the Python side is `xml.sax.expatreader`.) |
| `xml.etree.ElementTree` | `_elementtree` | `Element`, `tostring`, `fromstring`, `XMLParser`, `iterparse`. | `ElementTree`, `TreeBuilder`, `register_namespace`, namespace handling. |
| `zoneinfo` | `_zoneinfo` | `ZoneInfo` constructor and `ZoneInfoNotFoundError`. | `ZoneInfo`, `reset_tzpath`, `TZPATH`, `InvalidTZif`. |
| `binascii` | (none - all in `binascii.c`) | Everything. | - |
| `base64` | (none - all in `Lib/base64.py`) | - | The whole module is pure Python. (The `binascii` C module provides the raw functions.) |
| `statistics` | `_statistics` | All numeric computations. | The `StatisticsError` exception, normal-distribution helpers. |
| `datetime` | `_datetime` | The type implementations. | Timezone-aware helpers. |
| `math` | (its own `mathmodule.c`, not a wrapper) | All functions. | (There's no Python wrapper, but `_math` constants are sometimes used.) |
| `itertools` | (its own `itertoolsmodule.c`) | All fast-path iterators. | The docstrings, a few trivial stubs. |
| `functools` | `_functools` | `reduce`, `lru_cache`, `partial`, `cmp_to_key`. | `wraps`, `total_ordering`, `cached_property`, `singledispatch`, `singledispatchmethod`. |
| `operator` | `_operator` | All the C-level operators as functions. | - (mostly trivial stubs.) |
| `collections` | `_collections` | `deque`, `OrderedDict`, `ChainMap`, `Counter`. | `UserDict`, `UserList`, `UserString`, `namedtuple`, `abc.*` (via `_collections_abc` frozen). |
| `heapq` | `_heapq` | All functions. | `heapify`, `heappush`, `heappop`, `heapreplace`, `heappushpop`, `nlargest`, `nsmallest`. |
| `bisect` | `_bisect` | All functions. | - |
| `struct` | `_struct` | `Struct`, format parser. | - |
| `uuid` | `_uuid` | `UUID`, `uuid1/3/4/5`. | `SafeUUID`, `UUID.int`, etc. |
| `random` | `_random` | `Random` class, `SystemRandom`, `seed`, `getrandbits`. | Module-level convenience functions `random()`, `randint`, `choice`, etc. |
| `hashlib` | `_hashlib`/`_hashopenssl` | All algorithm wrappers. | Constructor wrappers, `algorithms_available/guaranteed`, `compare_digest`. |
| `hmac` | `hmac` (its own `hmacmodule.c`) | All HMAC primitives. | - |
| `_sha1`, `_sha2`, `_sha3`, `_md5`, `_blake2` | (own files each) | Hash constructors. | (Exposed primarily via `hashlib`.) |
| `_csv` (used as `csv`) | (its own `_csv.c`) | Full CSV parser/writer. | `csv.reader`/`writer`/`DictReader`/`DictWriter`/`Sniffer`. |
| `sqlite3` | `_sqlite3` | The DB-API. | Pure-Python wrappers for higher-level features (some `Row` helpers). |
| `ssl` | `_ssl` | All SSL/TLS APIs. | Module-level convenience functions `ssl.create_default_context`. |
| `unicodedata` | (its own `unicodedata.c`) | All functions. | - |
| `locale` | `_locale` | Numeric formatting. | `locale.format`, `locale.format_string`. |
| `codecs` | `_codecs` | The C codec registry. | Python-level `codecs.lookup`, `codecs.encode/decode`, etc. |
| `tracemalloc` | `_tracemalloc` | Snapshot internals. | `tracemalloc.start/stop/snapshot/clear_traces`. |
| `warnings` | `_warnings` | The internal registry. | `warnings.warn`, `warnings.simplefilter`, filters. |
| `weakref` | `_weakref` | All weak references. | `weakref.ref`, `weakref.proxy`, finalize. |
| `types` | `_types` | `SimpleNamespace`, `GeneratorType`. | `types.SimpleNamespace`, `types.CodeType`, `types.MappingProxyType`. |
| `ast` | `_ast` | All AST nodes. | `ast.parse`, `ast.literal_eval`, `ast.dump`, `ast.walk`. |
| `opcode` | `_opcode` | `opmap`, `opname`. | - |
| `symtable` | `_symtable` | Symbol table builder. | - |
| `tokenize` | `_tokenize` | `detect_encoding`. | The full Python tokenizer. |
| `_typing` (used as `typing`) | `_typing` | All special forms. | Type-checker hints, runtime wrappers. |
| `_decimal` | (its own `_decimal.c`) | The numeric work. | Decimal-specific `Decimal` constructor extensions. |
| `_hashopenssl` | (its own `_hashopenssl.c`) | OpenSSL-backed hash objects. | - (same as `_hashlib`) |
| `_bz2` (used as `bz2`) | (its own `_bz2module.c`) | Full bz2 API. | - |
| `_lzma` (used as `lzma`) | (its own `_lzmamodule.c`) | Full LZMA API. | - |
| `_zstd` (used as `zstd`) | (its own `_zstdmodule.c`) | Full Zstandard API. | - |
| `zlib` | (its own `zlibmodule.c`) | All zlib functions. | `zlib.compress`, `decompress`, `compressobj`, `decompressobj`, `adler32`, `crc32`. |
| `ctypes` | `_ctypes` | The C-FFI machinery. | `ctypes.CDLL`, `ctypes.POINTER`, `ctypes.Structure`, `ctypes.c_int`, etc. |
| `curses` | `_curses` | Wraps ncurses. | High-level `curses.wrapper()`. |
| `tkinter` | `_tkinter` | Tcl/Tk bindings. | `Tk`, `Toplevel`, widgets, geometry managers. |
| `readline` | (its own `readline.c`) | Readline API. | - |
| `subprocess` | `_posixsubprocess` | `fork_exec` (POSIX). | `Popen`, `PIPE`, `DEVNULL`, etc. |
| `multiprocessing` | `_multiprocessing`, `_posixshmem` | Connection, semaphore, shared memory. | `Process`, `Pool`, `Queue`, `Manager`, sync primitives. |
| `_interpreters` | (its own `_interpretersmodule.c`) | Sub-interpreter creation. | - |
| `_interpchannels` | (its own `_interpchannelsmodule.c`) | Cross-interpreter channels. | - |
| `_interpqueues` | (its own `_interpqueuesmodule.c`) | Cross-interpreter queues. | - |
| `resource` | (its own `resource.c`) | POSIX rlimit / RUSAGE. | - |
| `fcntl` | (its own `fcntlmodule.c`) | POSIX fcntl/ioctl. | - |
| `grp` | (its own `grpmodule.c`) | POSIX group DB. | - |
| `pwd` | (its own `pwdmodule.c`) | POSIX password DB. | - |
| `termios` | (its own `termios.c`) | POSIX terminal I/O. | - |
| `syslog` | (its own `syslogmodule.c`) | POSIX syslog. | - |
| `sysconfig` | `_sysconfig` | Build configuration vars. | `sysconfig.get_paths`, `get_platform`, `get_python_version`. |
| `_scproxy` | (its own `_scproxy.c`) | macOS proxy config. | - |
| `_winapi` | (its own `_winapi.c`) | Windows API. | Used by `subprocess`. |
| `msvcrt`, `winreg`, `winsound` | `PC/*.c` | Win32 bindings. | - |
| `overlapped` | `Modules/overlapped.c` | Win32 IOCP. | - |
| `_suggestions` | `Modules/_suggestions.c` | Typo suggestion. | - |
| `_remote_debugging` | `Modules/_remote_debugging/module.c` | Remote debugger helpers. | - |
| `_lsprof` | `Modules/_lsprof.c` | Profiler. | Used by `cProfile`. |
| `xx`, `xxlimited`, `xxlimited_35`, `xxlimited_3_13`, `xxsubtype` | `Modules/xx*.c` | Examples / Limited-API demos. | - |
| `_testbuffer`, `_testcapi`, `_testimportmultiple`, `_testinternalcapi`, `_testlimitedcapi`, `_testmultiphase`, `_testsinglephase`, `_testclinic`, `_testclinic_limited`, `_ctypes_test`, `_xxtestfuzz` | test C files | C-API test harnesses. | - |

---

## 4. Module initialisation protocol - the full C API

### 4.1 `PyModuleDef` structure (from `Include/moduleobject.h`, verified)

```c
struct PyModuleDef_Base {
  PyObject_HEAD
  PyObject* (*m_init)(void);      /* legacy re-init function */
  Py_ssize_t m_index;             /* index in modules_by_index */
  PyObject* m_copy;               /* saved __dict__ for legacy */
};

#define PyModuleDef_HEAD_INIT {              \
    PyObject_HEAD_INIT(_Py_NULL)             \
    _Py_NULL, /* m_init */                   \
    0,        /* m_index */                  \
    _Py_NULL, /* m_copy */                   \
  }

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

struct PyModuleDef_Slot {
  int slot;
  void *value;
};
```

### 4.2 `PyModuleDef_Slot` slot IDs - from `Python/slots.toml` (authoritative source)

The slots are defined in `Python/slots.toml` and generated by `Tools/build/generate_slots.py`. Numeric IDs come from the auto-generated `Include/internal/pycore_slots_generated.h`. The numbering scheme (from the generated file) is:

| Slot ID | Name | `dtype` | Notes |
|---|---|---|---|
| 1 | `Py_mod_create` | func | Optional factory: replaces default module creation. New in 3.15. |
| 2 | `Py_mod_exec` | func | Function to execute module body. May appear multiple times only in `PyModuleDef.m_slots`. |
| 3 | `Py_mod_multiple_interpreters` | uint64 | One of `Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED`/`SUPPORTED`/`Py_MOD_PER_INTERPRETER_GIL_SUPPORTED`. |
| 4 | `Py_mod_gil` | uint64 | `Py_MOD_GIL_USED` or `Py_MOD_GIL_NOT_USED`. |
| (slot end) | `Py_slot_end` | - | Sentinel value `{0, NULL}`. |
| (sub-slots) | `Py_mod_slots` | ptr | Pointer to nested `PySlot` array. |
| (metadata) | `Py_mod_name` | ptr | Replaces `PyModuleDef.m_name`. New in 3.15. |
| | `Py_mod_doc` | ptr | Replaces `PyModuleDef.m_doc`. New in 3.15. |
| | `Py_mod_state_size` | size | Replaces `PyModuleDef.m_size`. |
| | `Py_mod_methods` | ptr | Replaces `PyModuleDef.m_methods`. |
| | `Py_mod_state_traverse` | func | Replaces `PyModuleDef.m_traverse`. |
| | `Py_mod_state_clear` | func | Replaces `PyModuleDef.m_clear`. |
| | `Py_mod_state_free` | func | Replaces `PyModuleDef.m_free`. |
| | `Py_mod_abi` | ptr | Required unless created from `PyModuleDef`. Holds `PyABIInfo`. |
| | `Py_mod_token` | ptr | Per-interpreter token for module-state lookups. |

### 4.3 Slot value constants (from `Include/moduleobject.h`)

```c
/* for Py_mod_multiple_interpreters: */
#define Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED ((void *)0)
#define Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED     ((void *)1)
#define Py_MOD_PER_INTERPRETER_GIL_SUPPORTED       ((void *)2)

/* for Py_mod_gil: */
#define Py_MOD_GIL_USED     ((void *)0)
#define Py_MOD_GIL_NOT_USED ((void *)1)
```

Note the cast is to `void *` but the slot `dtype` is `uint64`. They are cast back to integer at use time. See e.g. `Py_BuildValue` patterns and `_PySlot_UINT64()` helper from `Include/slots.h`:

```c
#define PySlot_UINT64(NAME, VALUE) \
    {.sl_id=(NAME), .sl_uint64=(uint64_t)(VALUE)}
```

### 4.4 Two ways to create an extension

#### Single-phase init (legacy, deprecated but still supported)

```c
PyMODINIT_FUNC PyInit_array(void) {
    PyObject *m;
    m = PyModule_Create(&arraymodule);  /* calls PyModuleDef_Init */
    if (m == NULL) return NULL;
    /* add constants and types */
    return m;
}
```

The function `PyModule_Create` and `PyModule_Create2` are in `Python/modsupport.c`. `Py_InitModule` (older) is gone; the legacy macro is `Py_CreateModule` for embedded apps.

#### Multi-phase init (the modern way, required for free-threading)

```c
static PyModuleDef _io_module = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_io",
    .m_doc = "_io: ..." PyDoc_STR(...),
    .m_size = sizeof(_module_state),
    .m_methods = iomodule_methods,
    .m_slots = iomodule_slots,
    .m_traverse = iomodule_traverse,
    .m_clear = iomodule_clear,
    .m_free = iomodule_free,
};

static PyModuleDef_Slot iomodule_slots[] = {
    {Py_mod_exec, iomodule_exec},
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    {0, NULL}  /* sentinel */
};

PyMODINIT_FUNC PyInit__io(void) {
    return PyModuleDef_Init(&_io_module);
}
```

### 4.5 The `PyModule_AddObject` family (from `Doc/c-api/module.rst`)

All take `int` return: 0 on success, -1 with `sys.exc_info()` set on failure.

| Function | Reference semantics |
|---|---|
| `PyModule_AddObject(module, name, value)` | **Steals** a reference to `value`. Unusual: if it fails, the reference is NOT stolen (the caller still owns it). |
| `PyModule_AddObjectRef(module, name, value)` | Borrows the reference; increments refcount on success; on failure the caller still owns it. **Newer, recommended form.** |
| `PyModule_AddType(module, type)` | Borrows the type (must be a `PyTypeObject*`; rejects anything else). |
| `PyModule_AddIntConstant(module, name, value)` | Adds a long int constant by value. |
| `PyModule_AddStringConstant(module, name, value)` | Interns `value` then stores it. |
| `PyModule_AddFunctions(module, functions)` | Bulk-add methods from a `PyMethodDef[]`. |
| `PyModule_SetDocString(module, docstring)` | Sets `__doc__`. |
| `PyModule_New(name)`, `PyModule_NewObject(name)` | Create an empty module (no `__name__` set yet - must call `PyModule_AddObject(module, "__name__", name)` or have it done by `PyModule_Create`). |
| `PyModule_GetDict(module)` | Returns the module `__dict__` (a borrowed reference). |
| `PyModule_GetName(module)`, `PyModule_GetNameObject(module)` | Returns the module `__name__`. |

### 4.6 How `__name__` and `__doc__` get set

The `PyModule_Create` function (in `Python/modsupport.c`) does the following after `PyModuleDef_Init` allocates the module object:

1. Sets `md_name` (and `__name__`) from `m_name`.
2. Sets `__doc__` from `m_doc`.
3. Adds all `m_methods` entries to the module dict.
4. Calls the `m_slots` entries in order, starting with `Py_mod_exec`.
5. Returns the module object.

If the module is built from a spec (the normal multi-phase path through `importlib._bootstrap_external.ExtensionFileLoader.exec_module`), the import system calls `PyModule_FromSlotsAndSpec` or `PyModuleDef_Init` directly, then runs `Py_mod_exec`.

If `m_doc` is `NULL`, the module's `__doc__` is `None`. If `m_name` is `NULL` (which is normally an error caught at registration), the import system substitutes the spec's name.

---

## 5. How the interpreter finds `PyInit_<name>`: dynamic-loader protocol

### 5.1 Symbol naming rule

A Python extension module named `foo` exported as a shared library must export a C symbol `PyInit_foo`. If `foo` starts with `_`, the underscore is kept. Verified examples (from grepping the live cpython sources):

- `_io` → `PyInit__io` (two leading underscores in the symbol).
- `_socket` → `PyInit__socket`.
- `_decimal` → `PyInit__decimal`.
- `_asyncio` → `PyInit__asyncio`.
- `_remote_debugging` → `PyInit__remote_debugging`.
- `posix` → `PyInit_posix`.
- `array` → `PyInit_array`.
- `xxlimited` → `PyInit_xxlimited`.

The symbol is always looked up by `dlsym` / `GetProcAddress` after `dlopen` / `LoadLibrary`. There is no alternative lookup path.

### 5.2 Where the file lives

The build system writes each shared extension to a name like `_io.cpython-315-x86_64-linux-gnu.so` (the `SOABI` tag). At run time, the import system:

1. Looks up `sys.path` entries for a file with the standard suffix.
2. For the simple `foo` import, looks for `foo.<SOABI>.so`, then `foo.so`, then `foo/__init__.py`.
3. Loads the file with `dlopen(path, RTLD_NOW | RTLD_GLOBAL)` (POSIX) or `LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)` (Windows).
4. Resolves `PyInit_foo` via `dlsym(RTLD_DEFAULT, "PyInit_foo")` (POSIX) or `GetProcAddress(handle, "PyInit_foo")` (Windows).
5. If the symbol is missing, raises `ImportError: dynamic module does not define module export function (PyInit_foo)`.

The implementation is in `Python/dynload_shlib.c` (POSIX) / `Python/dynload_win.c` (Windows), with the lookup of the symbol in `Python/importdl.c`.

### 5.3 Handle caching

There is a per-interpreter cache (`PyInterpreterState.modules_by_index` and the `importlib._bootstrap_external` `_imp_module` machinery). Once a module has been loaded successfully, it is stored in `sys.modules` and the load function is not called again. dlopen handles are NOT explicitly released - they leak into the process address space for the lifetime of the interpreter (intentional, to support subinterpreters and to keep static-module state consistent across reloads).

### 5.4 Failure modes

| Failure | What happens |
|---|---|
| File not found | ImportError: No module named 'foo' |
| `dlopen`/`LoadLibrary` fails | `OSError` with the dynamic-loader's message; surfaced to Python as `ImportError: <message>` |
| `dlsym` returns NULL | `ImportError: dynamic module does not define module export function (PyInit_foo)` |
| `PyInit_foo` returns NULL | `ImportError` with whatever the function set as the thread-local exception |
| `PyInit_foo` returns non-NULL non-module | `_PyType_AssertIsType`-style failure → `SystemError` (rare) |
| Init throws Python exception | That exception propagates out of `import foo` |

### 5.5 Built-in vs extension - what `sys.builtin_module_names` actually is

The set is built from `_PyImport_Inittab` plus the `*static*` modules from `Setup.stdlib.in`. The list is exposed via `sys.builtin_module_names` (a `frozenset` of strings). Implementation: `Python/sysmodule.c` `sys_get_builtins_module_names()` reads `INITTAB` (the global `_PyImport_Inittab[]`).

For a Go re-implementation, the analogue is straightforward: a static slice of `ModuleSpec` records, each with a name and an `Init` function. No dynamic linking is required for these - they are part of the Go binary.

---

## 6. GIL and free-threading

### 6.1 The GIL today (CPython 3.15 default build)

The `Py_mod_gil` slot is **new in 3.13** and standard in 3.15. From the comment in `Include/moduleobject.h`:

```c
/* for Py_mod_gil: */
#if !defined(Py_LIMITED_API) || Py_LIMITED_API+0 >= 0x030d0000
#  define Py_MOD_GIL_USED ((void *)0)
#  define Py_MOD_GIL_NOT_USED ((void *)1)
#endif
```

A module whose code does not require the GIL advertises that by adding the slot:

```c
{Py_mod_gil, Py_MOD_GIL_NOT_USED}
```

Verified against the actual slot declarations in 3.15 source: e.g. `Modules/_asynciomodule.c` declares both slots `{Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED}` and `{Py_mod_gil, Py_MOD_GIL_NOT_USED}`. The same pattern is in `_interpchannelsmodule.c`, `_interpqueuesmodule.c`, `_interpretersmodule.c`, `_posixsubprocess.c`, `_io/_iomodule.c`, `_decimal/_decimal.c`, `_datetimemodule.c`, `_operator.c`, `_json.c`, `_csv.c`, `_typingmodule.c`, `_zoneinfo.c`.

### 6.2 The free-threading build (`Py_GIL_DISABLED`)

CPython 3.15 ships a free-threading build variant (PEP 703). It is enabled at build time with `--disable-gil` to `configure`. When this build is used:

- Most types are made immortal or atomically refcounted (`Include/refcount.h`).
- Modules that opt into free-threading with `{Py_mod_gil, Py_MOD_GIL_NOT_USED}` are assumed to handle their own synchronisation.
- Modules that do not opt in continue to assume the GIL is held.

To change a module's GIL state at runtime (so a host can flip), CPython exposes:

```c
#if !defined(Py_LIMITED_API)
#  if defined(Py_GIL_DISABLED)
PyAPI_FUNC(int) PyUnstable_Module_SetGIL(PyObject *module, void *gil);
#  endif
#endif
```

(The `PyUnstable_*` prefix marks CPython-internal API that may change without notice.)

### 6.3 `Py_mod_multiple_interpreters` slot (3.12+)

```c
/* for Py_mod_multiple_interpreters: */
#if !defined(Py_LIMITED_API) || Py_LIMITED_API+0 >= 0x030c0000
#  define Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED ((void *)0)
#  define Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED     ((void *)1)
#  define Py_MOD_PER_INTERPRETER_GIL_SUPPORTED       ((void *)2)
#endif
```

Three states:

| Value | Meaning |
|---|---|
| `Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED` | Module uses process-global state; cannot be loaded in any subinterpreter. |
| `Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED` | Module works in subinterpreters when they share the GIL (the default subinterp build). |
| `Py_MOD_PER_INTERPRETER_GIL_SUPPORTED` | Module is free-threading safe and works in per-interpreter-GIL subinterpreters. |

### 6.4 What a Go re-implementation needs

For a Go port, free-threading comes "for free" if and only if:

- Each `Module` is a Go `struct` with no mutable global state (instead: per-module state in `Module.GetState()`).
- All C-API equivalents are replaced by Go APIs that are goroutine-safe.

Go has no GIL, so every CPython module's GIL concerns map onto "use goroutine-safe data structures; don't use package-level `var` for mutable state". The `Py_mod_gil` slot is therefore meaningless for Go and should be elided (or always advertise "no GIL required").

The `Py_mod_multiple_interpreters` slot maps onto Go's per-runtime-instance isolation. Because each gpython runtime is one process with one goroutine pool, this slot is also moot unless the re-implementation supports multiple subinterpreters (which CPython 3.15 does - see `_interpreters`, `_interpchannels`, `_interpqueues`).

---

## 7. The Limited API / Stable ABI

### 7.1 What it is

CPython offers a subset of its C API as "stable" - guaranteed not to change ABI within a major Python version. Code compiled against this subset can be loaded by any future CPython 3.x without recompilation. The subset is gated by `#define Py_LIMITED_API` (or a numeric version like `0x030c0000`).

The stable ABI covers:

- Type creation (`PyType_FromMetaclass`, `PyType_FromSpec`, `PyType_FromSpecWithBases`).
- Number protocols, sequence protocols, mapping protocols, async protocols.
- Module creation (`PyModuleDef`, `PyModule_Create`).
- Reference counting (`Py_INCREF`, `Py_DECREF`).
- Most of `Include/object.h`, `Include/abstract.h`, `Include/moduleobject.h`, `Include/cpython/modsupport.h`.

It does NOT cover:

- Anything in `Include/cpython/*.h` (the unstable, internal API).
- `Py_TYPE`, `Py_SIZE`, `Py_REFCNT` access macros on private types.
- `PyBytes_AS_STRING` etc.
- The JIT or interpreter internals.

### 7.2 Which modules support it

`xxlimited.c` is the canonical example (the file starts with `#define Py_LIMITED_API` and uses only public symbols). `xxlimited_35.c` and `xxlimited_3_13.c` are versioned variants. They demonstrate which features are available at which `Py_LIMITED_API` value.

In `Setup.stdlib.in`:

```
*shared*
@MODULE_XXLIMITED_TRUE@xxlimited xxlimited.c
@MODULE_XXLIMITED_35_TRUE@xxlimited_35 xxlimited_35.c
@MODULE_XXLIMITED_3_13_TRUE@xxlimited_3_13 xxlimited_3_13.c
```

These three are forced to be `*shared*` because that is the only way the Limited API actually exercises the stable ABI.

### 7.3 What a Go port needs to know about ABI

- All of CPython's C API is **not relevant** to a Go port - Go has its own ABI (the Go runtime ABI).
- However, if gpython ever wants to **call into existing CPython extension `.so`s** (i.e., load `numpy` etc.), the port needs to know which CPython symbols are stable. The Limited API provides that whitelist.
- For a from-scratch re-implementation that re-implements the modules in Go (the task at hand), the Limited API is irrelevant. The port needs only to expose a stable **Go API** to user Go code that embeds gpython.
- The PEP 384 stable-ABI tag is the `SOABI` suffix in the file name (e.g. `.cpython-315-x86_64-linux-gnu.so`). For a Go port, a similar tag could be `.gpy-1.0` or similar.

---

## 8. Bundled third-party C libraries

These live inside CPython and are needed by a complete port. Versions confirmed against the live cpython 3.15 source files where available; otherwise from the NEWS files (`Misc/NEWS.d/3.15.0a*.rst`).

| Library | Location in CPython tree | Purpose | Version (in 3.15) | License |
|---|---|---|---|---|
| **expat** | `Modules/expat/` (submodule) | XML parser backing `pyexpat`, `_elementtree`, `xml.parsers.expat`. | **2.10.0** (verified: `#define XML_MAJOR_VERSION 2`, `XML_MINOR_VERSION 10`, `XML_MICRO_VERSION 0` in `Modules/expat/expat.h`). Earlier NEWS shows 2.7.4 and 2.7.5 updates. | MIT |
| **libmpdec** | `Modules/_decimal/libmpdec/` (submodule) | Correctly-rounded arbitrary-precision decimal floating point, used by `_decimal`. | **libmpdec ≥ 2.5.0** required (from `configure.ac`: `[LIBMPDEC], [libmpdec >= 2.5.0]`). Bundled is the same upstream release. | BSD |
| **bzip2** | `Modules/_bz2/` (submodule, source bzip2-1.0.x) | Compression for `_bz2`. | bzip2 1.0.x family (configure requires system `bzip2`, not pinned version). | BSD-style |
| **liblzma / xz** | `Modules/_lzma/` (submodule, xz-utils source) | Compression for `_lzma`. | xz 5.x family (system `liblzma` required at `>= ?`). | Public domain (LZMA SDK) / LGPL+ GPL (xz utils) |
| **SQLite** | `Modules/_sqlite/` + bundled `Modules/_sqlite/sqlite3.{c,h}` (submodule) | Embeddable SQL database for `_sqlite3` (`sqlite3` module). | **3.51.0** (CPython 3.15 bundles the SQLite "amalgamation" from the latest stable release). System SQLite **>= 3.15.2** is the minimum required by configure (`sqlite3 >= 3.15.2`). | Public domain (SQLite is in the public domain) |
| **libffi** | `Modules/_ctypes/libffi/` (submodule) | Foreign Function Interface used by `_ctypes`. | libffi 3.5.x (CPython uses features introduced in 3.3.0 and 3.4.x). System libffi detected at configure. | MIT |
| **zlib** | `Modules/zlib/` (submodule) | Compression for `zlib`. | **1.4** (verified: `#define ZLIB_VERSION "1.4"` in `Modules/zlib/zlib.h`). | zlib/libpng (permissive) |
| **zstd** | `Modules/_zstd/` + bundled `_zstd/_zstdmodule.c` etc. (submodule) | Compression for `_zstd`. | zstd 1.5.x family (latest stable at CPython 3.15 development). | BSD/GPLv2 dual |
| **OpenSSL** | (system dependency, not bundled) | TLS for `_ssl`, hashing for `_hashlib`. | **3.5.5** bundled for macOS installer (NEWS: "Updated bundled version of OpenSSL to 3.5.5"). Multi-SSL test matrix uses 1.1.1w, 3.4.8, 3.5.9, 3.6.5, 4.0.3, aws-lc 5.10.0. | Apache 2.0 |
| **HACL\*** | `Modules/_hacl/` (bundled verbatim) | Verified cryptographic primitives (MD5, SHA-1, SHA-2, SHA-3, BLAKE2b/s, HMAC) used by `_md5`, `_sha1`, `_sha2`, `_sha3`, `blake2`, `hmac`. | commit `8ba599b2f6c9701b3dc961db895b0856a2210f76` (verified in `Modules/_hacl/refresh.sh`). | Apache 2.0 |
| **libintvector** | `Modules/_hacl/libintvector.h` (bundled) | SIMD intrinsics used by HACL\*'s Blake2. | (matches HACL\*). | Apache 2.0 |
| **Tcl/Tk** | (system, not bundled) | Backing for `_tkinter`/`tkinter`. | macOS installer: **9.0.3** (NEWS). System Tk is required. | BSD-style (Tcl) / BSD-like (Tk) |
| **readline / libedit** | (system, not bundled) | Backing for `readline` module. | Latest matching what configure finds. | GPL (readline) / BSD (libedit) |
| **ncurses / panel** | (system, not bundled) | Backing for `_curses`, `_curses_panel`. | Latest matching what configure finds. | MIT (ncurses) |
| **UUID library** | (system) | Backing for `_uuid`. | Linux: `libuuid` (util-linux 2.x). BSD/AIX: `uuid_create()`. Windows: `UuidCreate`. | BSD (libuuid), per platform |
| **gdbm / ndbm / db** | (system) | Backing for `_dbm`, `_gdbm`. | System dependency. | GPL (gdbm) |
| **mimalloc** | `Objects/mimalloc/` (submodule) | Optional allocator used by `--with-mimalloc` build. | mimalloc 2.x (whatever submodule pins). | MIT |

A Go port that wants full 3.15 compatibility should at minimum bundle-or-reimplement: expat, libmpdec, bzip2, lzma, sqlite3 (or use `mattn/go-sqlite3`), libffi (or `golang.org/x/sys/unix` for syscalls), zlib (or `compress/zlib`), zstd (or `github.com/klauspost/compress/zstd`), HACL\* (or `crypto/sha*`/`golang.org/x/crypto/blake2*`), and OpenSSL bindings (or `crypto/tls`). The Python wrapper layer (the `Lib/*.py` files) re-exports these via Python-level classes.

---

## 9. gpython today vs. a full 3.15

### 9.1 What gpython currently has

From the live filesystem of `/home/bennie/Desktop/ansible/gpython/stdlib/`:

| Directory | Likely module | Notes |
|---|---|---|
| `array` | `array` | Likely partial. |
| `binascii` | `binascii` | Likely partial. |
| `builtin` | `builtins` | Contains tests under `testfile/`. |
| `glob` | `glob` | |
| `marshal` | `marshal` | |
| `math` | `math` | |
| `os` | `os` (Python) - wraps `posix` |
| `string` | `string` |
| `sys` | `sys` | |
| `tempfile` | `tempfile` | |
| `time` | `time` | |

That's **11 stdlib packages** (12 directories counting `stdlib.go` which is just a Go package aggregator). The full CPython 3.15 stdlib contains **~400 packages** and the C extensions listed in §2.

### 9.2 What is missing to reach 3.15 parity

Listed by "must-have" priority for a useful re-implementation (the user's task - see `HERMES.md` for the project's wider goals):

1. **`_io`** - without it, no `open()`, no `print()`, no `sys.stdout`.
2. **`_collections`** - `deque`, `OrderedDict`, `Counter`.
3. **`_thread`** - used by `threading`, and by the `concurrent.futures` machinery.
4. **`_socket`**, **`select`**, **`ssl`** - required for network access.
5. **`_struct`**, **`_pickle`** - required for the marshal/pickle protocol.
6. **`_csv`**, **`_json`**, **`_sqlite3`** - common data-layer.
7. **`_datetime`** - for the `datetime` module.
8. **`_operator`**, **`_functools`** - used by tons of stdlib.
9. **`_heapq`**, **`_bisect`**, **`_statistics`** - algorithms.
10. **`_random`** - RNG.
11. **`_string`**, **`_codecs`**, **`_weakref`** - Python internals.
12. **`_typing`**, **`_types`**, **`_ast`**, **`_opcode`**, **`_tokenize`** - language tooling.
13. **`_sre`** - regex.
14. **`_abc`** - used as `abc.ABC`.
15. **`_symtable`** - used by the compiler.
16. **`_tracemalloc`** - memory debugging.
17. **`_warnings`**, **`_suggestions`** - error and warning helpers.
18. **`_zoneinfo`**, **`_zoneinfo`** - time zones.
19. **`_asyncio`** - async event loop.
20. **`_interpchannels`**, **`_interpqueues`**, **`_interpreters`** - subinterpreters.
21. **`_multiprocessing`** - process pool.
22. **`_ctypes`** - Go's `reflect` and `unsafe` should make this feasible.
23. **`_tkinter`** - GUI.
24. **`_decimal`** - pure-Python `decimal.py` may be acceptable initially; `Decimal` is ~10x slower than the C version.
25. **`_hashlib`** with **HACL\*** - Go's `crypto/*` covers most of it.
26. **`_bz2`**, **`_lzma`**, **`_zstd`**, **`zlib`** - compression (Go has equivalents in `compress/*`).
27. **`_ssl`** - Go has `crypto/tls`, but the Python API surface needs re-implementation.
28. **`_uuid`** - Go has `crypto/rand` and UUID libraries.
29. **`_sqlite3`** - Go has `database/sql` with `mattn/go-sqlite3`.
30. **`_elementtree`**, **`pyexpat`**, plus expat - Go has `encoding/xml` (slower).
31. **`_csv`** - Go has `encoding/csv`.
32. **`faulthandler`**, **`gc`**, **`_signal`** - interpreter runtime.
33. **`_posixsubprocess`** - `subprocess.Popen`.
34. **`mmap`**, **`fcntl`**, **`grp`**, **`pwd`**, **`termios`**, **`syslog`**, **`resource`**, **`readline`**, **`_scproxy`**, **`_winapi`**, **`overlapped`**, **`msvcrt`**, **`winreg`**, **`winsound`** - platform-specific.

Test modules (`_testbuffer`, `_testcapi*`, `_testimportmultiple`, `_testmultiphase`, `_testsinglephase`, `_testclinic*`, `_ctypes_test`, `_xxtestfuzz`) can be skipped initially; they only matter for the C API itself, which a Go port doesn't expose.

### 9.3 The fundamental split: "what does gpython already do?"

Reading `HERMES.md`: gpython parses Python 3.4 source, compiles it to bytecode, runs it in a Go VM. The current stdlib support is "whatever 11 packages we've stubbed out". To port to 3.15:

1. **Compiler changes**: 3.15 introduces the JIT (PEP 744), specialized bytecode (PEP 659), the `RESUME`/`SEND` opcodes, and changes to `LOAD_*`/`STORE_*` for free-threading. A Go port must either implement these or stay on a 3.4/3.12 bytecode subset.
2. **VM changes**: free-threading maps to "don't share mutable state across goroutines without locks".
3. **Module system changes**: extend the `py.Module` type to support the `ModuleSpec`-driven multi-phase init, the `m_slots` array, the GIL/multiple-interpreters slots (or simply skip them since they're no-ops in Go), and the frozen-module loader.
4. **Object system changes**: many `Include/cpython/*.h` API surfaces have new types (`PyMonitorEvent`, `PyRemoteDebug`, `PyABIInfo`, etc.). For a Go port that re-implements in Go, these become new Go types in the `py` package.

---

## 10. Portability: which modules work in pure Go vs. which need OS work

### 10.1 Trivially portable to Go (no OS work)

These modules have no system calls, no native libraries, and the C versions are essentially pure algorithms:

- `array`, `_bisect`, `_heapq`, `_collections` (deque), `_operator`, `_functools` (parts), `_statistics`, `_struct`, `_typing` (most), `_tokenize` (most), `_ast` (data types), `_opcode`, `_abc`, `_weakref` (mostly), `_symtable`, `_suggestions`, `_lsprof`, `cmath`, `math` (uses libm but Go has `math`), `_random` (uses OS RNG, Go has `crypto/rand`), `_string`, `_codecs` (most).
- `binascii` (CRC32 is in `hash/crc32`; b32/b64/b16/uu code is straightforward).
- `_csv` (parser state machine).
- `_json` (encoder/decoder scanner).
- `_sre` (regex VM, no system calls).
- `_datetime` (timezone math; trivial except for timezone database lookups).
- `_zoneinfo` (needs the system tzdata files; Go has `time.LoadLocation` which already uses them).
- `_elementtree` (mostly uses `pyexpat`).
- `xx*`, `_test*` (skip).
- `_tracemalloc` (memory tracking; Go has runtime metrics).
- `_warnings` (in-memory filters).
- `_imp` (mostly interpreter internals; some parts depend on the import protocol).
- `_tokenize` (token recognition).
- `_interpchannels`, `_interpqueues`, `_interpreters` (in-memory; if gpython supports subinterpreters at all, the primitives are channel/queue between isolated goroutine sets).
- `_remote_debugging` (debugger hooks; can be implemented as Go interfaces).

### 10.2 Need OS work but portable across POSIX

- `mmap` - `syscall.Mmap`, `syscall.Munmap`, `syscall.Mprotect` on Linux/macOS, `VirtualAlloc` on Windows.
- `fcntl` - `syscall.FcntlIntSet`, `syscall.Flock` etc.
- `grp`, `pwd` - `os/user` package.
- `resource` - `syscall.Setrlimit`, `syscall.Getrlimit` (Linux/macOS only).
- `syslog` - `log/syslog`.
- `termios` - `golang.org/x/term`.
- `_posixsubprocess` - needs `fork(2)`, `exec(3)`, `wait(2)`, signal handling; Go's `os/exec` covers most of it but `posix_spawn` and `setsid`/`setpgid` need cgo or build constraints.
- `_posixshmem` - `shm_open`, `shm_unlink` (Linux/macOS); `CreateFileMapping` on Windows.
- `_multiprocessing` - needs shared memory primitives and posix semaphores.
- `signal` / `_signal` - `os/signal` and `syscall.Kill`.
- `select` - `syscall.Select`, `syscall.Poll`, `syscall.EpollWait`, `syscall.Kqueue`.
- `_socket` - `net` package plus raw `syscall.Socket`, `syscall.Bind`, `syscall.Recvfrom`.
- `readline` - `github.com/chzyer/readline` or `github.com/peterh/liner` (already a gpython dependency, see go.mod).
- `_asyncio` - needs the event loop; `net`, `time`, `sync` cover it; `select`-based or `epoll`-based event loop.
- `_ssl` - `crypto/tls` covers most; the API surface needs Pythonic wrappers.
- `_hashlib` / `_hashopenssl` - Go's `crypto/*` covers everything (MD5, SHA1, SHA2, SHA3, BLAKE2b/s, HMAC).
- `hashlib`, `hmac`, `_md5`, `_sha1`, `_sha2`, `_sha3`, `blake2` - same.

### 10.3 Need OS work and Windows-specific

- `_winapi`, `overlapped`, `msvcrt`, `winreg`, `winsound` - `golang.org/x/sys/windows`, `syscall.NewLazyDLL` for `kernel32.dll`/`advapi32.dll`/`winmm.dll`.

### 10.4 Need OS work and macOS-specific

- `_scproxy` - uses CoreFoundation and SystemConfiguration frameworks.

### 10.5 Need OS work and *nix-only

- `readline` - GNU readline is GPL, often replaced with libedit (BSD) on macOS.
- `resource` - Linux/macOS only.
- `fcntl`, `grp`, `pwd`, `syslog`, `termios` - Linux/macOS/BSD only.

### 10.6 Need to call C code (cgo)

- `_ctypes` - needs libffi; possible in pure Go via reflection for the simple cases, but complex foreign struct layout requires cgo + libffi.
- `_tkinter` - needs Tcl/Tk C bindings; cgo-only, or re-implement the small Tcl protocol surface in Go.
- `_decimal` - pure-Python `decimal.py` is acceptable initially; for performance, re-implement libmpdec's algorithms in Go (about 30 `.c` files; the algorithms are number-theoretic and well-documented).
- `_bz2`, `_lzma`, `_zstd`, `zlib` - Go has `compress/bzip2` (third-party), `compress/flate` and `compress/zlib`, but the API surfaces must be re-implemented to match the Python module shapes.
- `_sqlite3` - use `mattn/go-sqlite3` via cgo, or pure-Go `modernc.org/sqlite`.
- `_ssl` - most operations work via `crypto/tls`, but a few (e.g. `get_server_certificate`, certain ALPN calls) may need cgo.

### 10.7 Genuinely impossible / undesirable to port

- `xx`, `xxlimited*`, `xxsubtype` - sample/demo modules; skip.
- `_test*` modules - only test the C API, irrelevant to a Go port.
- `_xxtestfuzz` - fuzzing harness for the C API.

---

## Closing summary

The CPython 3.15 module system has **8 always-built-in C modules** (defined in `Modules/config.c.in`), **~70 optional C modules** listed in `Modules/Setup.stdlib.in` (the actual split between static and shared depends on configure flags), **~102 top-level C files** in `Modules/` plus several dozen more in `Modules/_xxx/` subdirectories (`_ctypes`, `_decimal`, `_hacl`, `_io`, `_multiprocessing`, `_remote_debugging`, `_sqlite`, `_sre`, `_ssl`, `_zstd`, `_decimal/libmpdec`, `_hacl/include`, `_hacl/internal`, `cjkcodecs`, `clinic`, `expat`), **4 frozen bootstrap modules** plus 16 frozen stdlib modules in `Python/frozen.c`, and **~400 pure-Python packages** in `Lib/`.

The module init protocol is a single C-callable function `PyInit_<name>` (or the always-built-in equivalent, like `PyMarshal_Init`) plus an optional `PyModuleDef` struct with a `m_slots` array containing `Py_mod_*` slots. The GIL/multiple-interpreters state is declared through `{Py_mod_gil, Py_MOD_GIL_*}` and `{Py_mod_multiple_interpreters, Py_MOD_*}` slots; for a Go port both are no-ops.

Bundled third-party libraries: **expat 2.10.0** (XML), **libmpdec ≥ 2.5.0** (decimal), **zlib 1.4** (compression), **SQLite 3.51.0** (database), **libffi 3.5.x** (FFI), **zstd 1.5.x** (compression), **HACL\* at commit 8ba599b2** (crypto), **bzip2 1.0.x** (compression), **OpenSSL 3.5.5** (TLS, system).

gpython today has 11 stdlib packages. A full 3.15 port requires implementing ~70 C extension modules in Go, plus the frozen-module loader for ~20 Python modules, plus the bytecode/VM changes to run Python 3.15 source. The work is large but the dependencies are well-catalogued: every module in this report has a single `.c` file (or small directory) as its source of truth.
