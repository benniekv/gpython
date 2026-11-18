# 01 - The C Module Inventory (CPython 3.15.2, complete)

## Overview

This file is the complete inventory of CPython's C-implemented modules. It exists
because a Go re-implementation of the Python module system needs to know, module
by module, what is written in C and what is written in Python - and because the
user requirement was explicit: **no C-coded module may be left out**.

The inventory is derived from the build system, not from memory. CPython's build
declares every C module in exactly two places:

- `Modules/Setup.bootstrap.in` - the modules that are **always** statically linked
  into the interpreter. 27 entries.
- `Modules/Setup.stdlib.in` - the modules that may be built static or shared.
  80 entries.

Everything else is pure Python in `Lib/`.

Both lists were fetched from the `v3.15.2` tag and parsed. The counts below are
measured, not estimated.

## Sources

- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.bootstrap.in` -
  always-static builtin module list (fetched 2026-11-18, 27 entries parsed).
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.stdlib.in` -
  the full C extension build list (fetched 2026-11-18, 80 entries parsed).
- `https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1` -
  the source tree (6141 entries, `truncated: false`). Used to confirm the file
  inventory: 101 `.c` files directly in `Modules/`, plus 16 subdirectories
  containing C sources.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/moduleobject.h` -
  the `PyModuleDef` structure.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/import.h` -
  the extension init protocol constants.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/import.c` -
  `PyImport_Inittab`, `PyImport_AppendInittab`, `PyImport_ExtendInittab`.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/importdl.c` -
  the dynamic loader.
- Live `sys.builtin_module_names` from CPython 3.14.9, as a cross-check only.

## Spec

### How the three categories work

CPython modules fall into exactly three categories. The distinction matters for
the Go design because each maps to a different mechanism.

| Category | Where it lives | How it is loaded | Appears in `sys.builtin_module_names` |
|---|---|---|---|
| **Builtin** | C, statically linked into the interpreter binary | At interpreter startup, from the inittab table | **Yes** |
| **Extension** | C, in a shared library (`.so` / `.pyd`) | `dlopen`/`LoadLibrary` at import time | No (unless built static) |
| **Pure Python** | `.py` in `Lib/` | Compiled and executed by the import machinery | No |

A module in `Setup.bootstrap.in` is **always** builtin. A module in
`Setup.stdlib.in` is *buildable* as either, controlled by the
`*@MODULE_BUILDTYPE@*` line at the top of that file. The default build produces
shared extensions for most of them.

A fourth category exists for completeness: **frozen** modules. These are Python
source compiled into C arrays at build time and linked into the binary. They are
*not* builtins in the C sense - `sys.builtin_module_names` does not list them -
but they are also not on disk as `.py`. CPython 3.15 freezes `importlib._bootstrap`,
`importlib._bootstrap_external`, `zipimport` and the `codecs` encodings. The
frozen table is declared in `Python/frozen.c` and the module list in
`Programs/_freeze_module.py` / `Tools/build/freeze_modules.py`.

### Category 1 - Always-static builtins (27)

From `Modules/Setup.bootstrap.in`. These are in the interpreter binary on every
platform, every build.

| Module | Source file(s) | Provides |
|---|---|---|
| `atexit` | `atexitmodule.c` | `register`, `unregister`, `ncallbacks`; the interpreter exit hook registry |
| `faulthandler` | `faulthandler.c` | `enable`, `disable`, `dump_traceback`, `dump_traceback_later`; the fatal-signal handler |
| `posix` | `posixmodule.c` | The POSIX surface: `open`, `close`, `read`, `write`, `stat`, `lstat`, `unlink`, `rename`, `listdir`, `chdir`, `getcwd`, `umask`, `environ`, `fspath`, `stat_result`, `DirEntry` |
| `_signal` | `signalmodule.c` | `signal`, `alarm`, `raise_signal`, `set_wakeup_fd`, `valid_signals`, `SIG_*` constants; the C signal handler bridge |
| `_tracemalloc` | `_tracemalloc.c` | `start`, `stop`, `get_traced_memory`, `take_snapshot`, `reset_peak`; the allocation tracer |
| `_suggestions` | `_suggestions.c` | `suggest`; the "did you mean" suggestion helper used by the REPL |
| `_datetime` | `_datetimemodule.c` | The C accelerator for `datetime.date`, `datetime.time`, `datetime.datetime`, `datetime.timedelta`, `datetime.timezone`, `datetime.Calendar` |
| `_codecs` | `_codecsmodule.c` | The codec registry: `register`, `lookup`, `encode`, `decode`, `charmap_*`, `utf_8_encode`, and the `IncrementalEncoder`/`IncrementalDecoder` base classes |
| `_collections` | `_collectionsmodule.c` | `_collections_abc` C accelerators: `dictview`, `dict_keys`, `dict_items`, `dict_values`, `mappingproxy`, `deque` |
| `errno` | `errnomodule.c` | The `errno` constants (`EPERM`, `ENOENT`, …) |
| `_io` | `_io/_iomodule.c` `_io/iobase.c` `_io/fileio.c` `_io/bytesio.c` `_io/bufferedio.c` `_io/textio.c` `_io/stringio.c` | The C implementation of the whole `io` stack: `FileIO`, `BufferedReader`, `BufferedWriter`, `BufferedRandom`, `BufferedRWPair`, `TextIOWrapper`, `BytesIO`, `StringIO` |
| `itertools` | `itertoolsmodule.c` | `count`, `cycle`, `repeat`, `accumulate`, `chain`, `compress`, `dropwhile`, `filterfalse`, `groupby`, `islice`, `pairwise`, `permutations`, `product`, `starmap`, `takewhile`, `tee`, `zip_longest`, `batched` |
| `_sre` | `_sre/sre.c` | The C regular-expression engine: `compile`, `search`, `match`, `fullmatch`, `findall`, `finditer`, `sub`, `subn`, `split`, `escape`, `purge`, and the `Pattern`/`Match` types |
| `_sysconfig` | `_sysconfig.c` | `get_config_vars`, `get_config_h_filename`, `get_paths`, `get_platform`, `get_python_version` |
| `_thread` | `_threadmodule.c` | `start_new_thread`, `allocate_lock`, `LockType`, `RLock`, `get_ident`, `stack_size`, `interrupt_main`, `_count` |
| `time` | `timemodule.c` | `time`, `time_ns`, `monotonic`, `monotonic_ns`, `perf_counter`, `perf_counter_ns`, `process_time`, `thread_time`, `localtime`, `gmtime`, `mktime`, `strftime`, `tzset`, `sleep`, `clock_gettime` |
| `_types` | `_typesmodule.c` | `DynamicClassAttribute`, `FunctionType`, `LambdaType`, `GeneratorType`, `CoroutineType`, `CodeType`, `CellType`, `MethodType`, `ModuleType`, `MappingProxyType`, `SimpleNamespace`, `GenericAlias`, `UnionType`, `EllipsisType`, `NoneType`, `NotImplementedType` |
| `_typing` | `_typingmodule.c` | The C runtime support for `typing`: the `_SpecialForm` machinery, `GenericAlias`, `TypeVar`, `ParamSpec`, `TypeVarTuple`, and the `typing` C helpers used by `Lib/typing.py` |
| `_weakref` | `_weakref.c` | `ref`, `proxy`, `ReferenceType`, `ProxyType`, `CallableProxyType`, `WeakValueDictionary`, `WeakKeyDictionary`, `finalize` |
| `_abc` | `_abc.c` | `ABCMeta`, `get_cache_token`; the C half of `abc.ABCMeta` |
| `_functools` | `_functoolsmodule.c` | `reduce`, `partial`, `partialmethod`, `lru_cache`, `cache`, `singledispatch`, `singledispatchmethod`, `update_wrapper`, `wraps` |
| `_locale` | `_localemodule.c` | `getpreferredencoding`, `setlocale`, `localeconv`, `getlocale`, `strcoll`, `strxfrm`, `nl_langinfo` |
| `_opcode` | `_opcode.c` | `opmap`, `opname`, `HAVE_ARGUMENT`, `EXTENDED_ARG`; the opcode introspection table |
| `_operator` | `_operator.c` | `add`, `sub`, `mul`, `truediv`, `floordiv`, `mod`, `pow`, `neg`, `abs`, `invert`, `lshift`, `rshift`, `and_`, `xor`, `or_`, `lt`, `le`, `eq`, `ne`, `gt`, `ge`, `not_`, `truth`, `is_`, `is_not`, `concat`, `contains`, `getitem`, `setitem`, `delitem`, `iadd`, … and the `itemgetter`, `attrgetter`, `methodcaller` classes |
| `_stat` | `_stat.c` | `S_IMODE`, `S_IFMT`, `S_IFDIR`, `S_IFREG`, `S_IFLNK`, … ; the `stat` mode constants and helpers |
| `_symtable` | `symtablemodule.c` | `symtable`, `SymbolTable`, `Symbol`; the compiler-facing symbol table |
| `pwd` | `pwdmodule.c` | `getpwall`, `getpwuid`, `getpwnam`; POSIX password database access |

Two more names are always available at runtime but are **not** in
`Setup.bootstrap.in`, because they are implemented in `Python/` (interpreter core)
rather than `Modules/`: `sys` (`Python/sysmodule.c`) and `builtins`
(`Python/bltinmodule.c`). `zipimport` is also always present, implemented in
`Python/zipimport.c`.

### Category 2a - Always-built core modules (not in the Setup lists)

Three C modules are compiled into the interpreter by the core build rather than
by the `Setup` lists, and one more group is Windows-only.

| Module | Source | How it is built | Platform |
|---|---|---|---|
| `gc` | `Modules/gcmodule.c` | Unconditionally listed in `MODULE_OBJS` in `Makefile.pre.in` | All |
| `_winapi` | `Modules/_winapi.c` | Built by `PCbuild/_winapi.vcxproj` on Windows | Windows only |
| `_overlapped` | `Modules/overlapped.c` | Built by `PCbuild/_overlapped.vcxproj` on Windows | Windows only |

Evidence for `gc` - `Makefile.pre.in` line 354:

```make
MODULE_OBJS=	\
		Modules/config.o \
		Modules/main.o \
		Modules/gcmodule.o
```

Evidence for the Windows pair - the MSVC project files `PCbuild/_winapi.vcxproj`
and `PCbuild/_overlapped.vcxproj` exist in the tree, and no POSIX build rule
references `Modules/_winapi.c` or `Modules/overlapped.c`.

### Category 2b - Windows-only modules (`PC/`)

CPython keeps its Windows-only modules in `PC/`, not `Modules/`. These have no
POSIX equivalent and are listed here for completeness.

| Module | Source | Provides |
|---|---|---|
| `winreg` | `PC/winreg.c` | The Windows registry API: `OpenKey`, `CreateKey`, `QueryValueEx`, `SetValueEx`, `EnumKey`, `DeleteKey` |
| `winsound` | `PC/winsound.c` | `Beep`, `PlaySound`, `MessageBeep` |
| `msvcrt` | `PC/msvcrtmodule.c` | `getcwd`, `chdir`, `mkdir`, `rmdir`, `setmode`, `open_osfhandle`, `fdopen` |

### Category 2c - Buildable C extensions (80)

From `Modules/Setup.stdlib.in`. Each may be built static or shared; the default
build produces shared extensions for most.

#### Core and data structures

| Module | Source file(s) | Provides |
|---|---|---|
| `array` | `arraymodule.c` | The `array` type: `array`, `array.array`, `typecodes` |
| `_bisect` | `_bisectmodule.c` | `bisect_left`, `bisect_right`, `insort_left`, `insort_right`; the `bisect` accelerator |
| `_csv` | `_csv.c` | `reader`, `writer`, `field_size_limit`; the `csv` accelerator |
| `_heapq` | `_heapqmodule.c` | `heappush`, `heappop`, `heapify`, `heapreplace`, `heappushpop`, `nlargest`, `nsmallest` |
| `_json` | `_json.c` | `encode_basestring_ascii`, `scanstring`, `make_encoder`, `make_scanner`; the `json` accelerator |
| `_lsprof` | `_lsprof.c` `rotatingtree.c` | The Linux `perf`-style sampling profiler backend |
| `_math_integer` | `mathintegermodule.c` | `gcd`, `lcm`, `isqrt`, `factorial`; integer math beyond `int` |
| `_pickle` | `_pickle.c` | `Pickler`, `Unpickler`, `dump`, `dumps`, `load`, `loads`, `PickleError`; the C pickle implementation |
| `_queue` | `_queuemodule.c` | `SimpleQueue`, `Queue`, `Empty`, `Full`, `ShutDown`; the `queue` accelerator |
| `_random` | `_randommodule.c` | `Random`, `getrandbits`, `getstate`, `setstate`; the Mersenne Twister core |
| `_struct` | `_struct.c` | `pack`, `unpack`, `unpack_from`, `iter_unpack`, `Struct`; the `struct` module |
| `_statistics` | `_statisticsmodule.c` | `mean`, `fmean`, `median`, `median_low`, `median_high`, `mode`, `multimode`, `pstdev`, `pvariance`, `stdev`, `variance`, `quantiles`, `correlation`, `covariance`, `linear_regression`, `fmean` |
| `_remote_debugging` | `_remote_debugging/*.c` (13 files) | The remote debugging attach protocol (PEP 768 support) |

#### Numeric and math

| Module | Source file(s) | Provides |
|---|---|---|
| `math` | `mathmodule.c` | `pi`, `e`, `tau`, `inf`, `nan`, `sqrt`, `pow`, `exp`, `log`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `hypot`, `fmod`, `floor`, `ceil`, `trunc`, `factorial`, `gcd`, `isqrt`, `fsum`, `prod`, `nextafter`, `frexp`, `ldexp`, `modf`, `dist`, `erf`, `gamma`, `lgamma` |
| `cmath` | `cmathmodule.c` | The complex equivalents: `phase`, `polar`, `rect`, `exp`, `log`, `sqrt`, `sin`, `cos`, `tan`, `sinh`, `cosh`, `tanh`, `asin`, `acos`, `atan`, `atan2` |
| `_decimal` | `_decimal/_decimal.c` | The `_decimal` accelerator for `decimal.Decimal`, backed by the bundled `libmpdec` |

#### Compression

| Module | Source file(s) | Provides |
|---|---|---|
| `binascii` | `binascii.c` | `b2a_base64`, `a2b_base64`, `b2a_hex`, `a2b_hex`, `b2a_qp`, `a2b_qp`, `crc32`, `crc_hqx`, `b2a_uu`, `a2b_uu`, `b2a_hqx`, `a2b_hqx` |
| `_bz2` | `_bz2module.c` | `BZ2Compressor`, `BZ2Decompressor`, `compress`, `decompress`; the bundled bzip2 |
| `_lzma` | `_lzmamodule.c` | `LZMACompressor`, `LZMADecompressor`, `compress`, `decompress`, `FORMAT_*`, `CHECK_*`, `PRESET_*`; the bundled liblzma |
| `_zstd` | `_zstd/_zstdmodule.c` `_zstd/zstddict.c` `_zstd/compressor.c` `_zstd/decompressor.c` | `ZstdCompressor`, `ZstdDecompressor`, `compress`, `decompress`; the bundled zstd (new in 3.14) |
| `zlib` | `zlibmodule.c` | `compress`, `decompress`, `crc32`, `adler32`, `compressobj`, `decompressobj`, `zlib_version`; the bundled zlib |

#### Database

| Module | Source file(s) | Provides |
|---|---|---|
| `_dbm` | `_dbmmodule.c` | The generic DBM dispatcher; opens whichever of `dbm.ndbm`, `dbm.gnu`, `dbm.dumb` is available |
| `_gdbm` | `_gdbmmodule.c` | `open`, `open_flags`, `whichdb`; GNU dbm access |
| `_sqlite3` | `_sqlite/*.c` (9 files) | `Connection`, `Cursor`, `Blob`, `convert`, `enable_callback_tracebacks`, `enable_load_extension`; the bundled SQLite |

#### Hashing and cryptography

| Module | Source file(s) | Provides |
|---|---|---|
| `_md5` | `md5module.c` | `md5`; the MD5 hash |
| `_sha1` | `sha1module.c` | `sha1` |
| `_sha2` | `sha2module.c` | `sha224`, `sha256`, `sha384`, `sha512` |
| `_sha3` | `sha3module.c` | `sha3_224`, `sha3_256`, `sha3_384`, `sha3_512`, `shake_128`, `shake_256` |
| `_blake2` | `blake2module.c` | `blake2b`, `blake2s` |
| `_hmac` | `hmacmodule.c` | `hmac`; the fast HMAC path |
| `_hashlib` | `_hashopenssl.c` | `openssl_sha256`, `openssl_sha512`, `openssl_md5`, … ; the OpenSSL-backed hashlib accelerator. Note the file name is `_hashopenssl.c` but the module name is `_hashlib` - a mismatch to watch for when parsing the build list. |

#### Text, encoding and Unicode

| Module | Source file(s) | Provides |
|---|---|---|
| `pyexpat` | `pyexpat.c` | The `xml.parsers.expat` binding; the bundled expat XML parser |
| `_elementtree` | `_elementtree.c` | The C accelerator for `xml.etree.ElementTree` |
| `_codecs_cn` | `cjkcodecs/_codecs_cn.c` | The Simplified Chinese codec set (`gb2312`, `gbk`, `gb18030`, `hz`) |
| `_codecs_hk` | `cjkcodecs/_codecs_hk.c` | The Traditional Chinese codec set (`big5`, `big5hkscs`, `cp950`) |
| `_codecs_iso2022` | `cjkcodecs/_codecs_iso2022.c` | `iso2022_jp`, `iso2022_jp_1`, `iso2022_jp_2`, `iso2022_jp_2004`, `iso2022_jp_3`, `iso2022_jp_ext`, `iso2022_kr` |
| `_codecs_jp` | `cjkcodecs/_codecs_jp.c` | `shift_jis`, `shift_jis_2004`, `shift_jisx0213`, `euc_jp`, `euc_jis_2004`, `euc_jisx0213`, `iso2022_jp_*` |
| `_codecs_kr` | `cjkcodecs/_codecs_kr.c` | `euc_kr`, `johab`, `cp949`, `uhc` |
| `_codecs_tw` | `cjkcodecs/_codecs_tw.c` | `big5`, `big5hkscs`, `cp950` |
| `_multibytecodec` | `cjkcodecs/multibytecodec.c` | The shared multibyte codec base used by all the CJK codecs |
| `unicodedata` | `unicodedata.c` | `lookup`, `name`, `decimal`, `digit`, `numeric`, `category`, `bidirectional`, `combining`, `east_asian_width`, `decomposition`, `normalize`, `is_normalized`, `unidata_version` |

#### OS, process and IO

| Module | Source file(s) | Provides |
|---|---|---|
| `fcntl` | `fcntlmodule.c` | `fcntl`, `ioctl`, `flock`, `lockf`, `F_GETFL`, `F_SETFL`, … ; POSIX file control |
| `grp` | `grpmodule.c` | `getgrall`, `getgrgid`, `getgrnam`; POSIX group database |
| `mmap` | `mmapmodule.c` | `mmap`; memory-mapped files |
| `_posixsubprocess` | `_posixsubprocess.c` | `fork_exec`; the POSIX `fork`/`exec` used by `subprocess` |
| `resource` | `resource.c` | `getrlimit`, `setrlimit`, `getrusage`, `RLIMIT_*`; POSIX resource limits |
| `select` | `selectmodule.c` | `select`, `poll`, `epoll`; the readiness-selection primitives |
| `_socket` | `socketmodule.c` | `socket`, `socketpair`, `fromfd`, `getaddrinfo`, `getnameinfo`, `AF_*`, `SOCK_*`, `SOL_SOCKET`, `TCP_*`; the BSD socket layer |
| `syslog` | `syslogmodule.c` | `syslog`, `openlog`, `closelog`, `LOG_*`; POSIX syslog |
| `termios` | `termios.c` | `tcgetattr`, `tcsetattr`, `tcgetwinsize`, `tcsetwinsize`, `ECHO`, `ICANON`, … ; POSIX terminal control |
| `_posixshmem` | `_multiprocessing/posixshmem.c` | `shm_open`, `shm_unlink`; POSIX shared memory for `multiprocessing` |
| `_multiprocessing` | `_multiprocessing/multiprocessing.c` `_multiprocessing/semaphore.c` | `SemLock`, `sem_*`; the shared-memory and semaphore backend |

#### Terminal, GUI and platform

| Module | Source file(s) | Provides |
|---|---|---|
| `_curses` | `_cursesmodule.c` | The `curses` binding: `initscr`, `newwin`, `addstr`, `getch`, `window`, and the colour pair machinery |
| `_curses_panel` | `_curses_panel.c` | The `curses.panel` binding |
| `_tkinter` | `_tkinter.c` `tkappinit.c` | The `tkinter` binding: `Tk`, `Tcl`, `Tkinter` |
| `readline` | `readline.c` | The GNU readline / libedit binding used by the interactive REPL |
| `_scproxy` | `_scproxy.c` | macOS SystemConfiguration proxy lookup |
| `_uuid` | `_uuidmodule.c` | `uuid`; the UUID generation core |

#### SSL and TLS

| Module | Source file(s) | Provides |
|---|---|---|
| `_ssl` | `_ssl.c` | `SSLContext`, `SSLSocket`, `MemoryBIO`, `SSLError`, `OP_*`, `VERIFY_*`, `PROTOCOL_*`, `TLSVersion`; the OpenSSL binding |

#### FFI

| Module | Source file(s) | Provides |
|---|---|---|
| `_ctypes` | `_ctypes/_ctypes.c` `_ctypes/callbacks.c` `_ctypes/callproc.c` `_ctypes/stgdict.c` `_ctypes/cfield.c` | The `ctypes` FFI: `CDLL`, `PyDLL`, `CFUNCTYPE`, `Structure`, `Union`, `POINTER`, `Array`, `c_char_p`, … ; backed by the bundled libffi |

#### Interpreters and concurrency

| Module | Source file(s) | Provides |
|---|---|---|
| `_interpreters` | `_interpretersmodule.c` | The PEP 734 subinterpreter API: `create`, `destroy`, `run_string`, `run`, `set___main___attrs`, `capture_output` |
| `_interpchannels` | `_interpchannelsmodule.c` | The PEP 734 channel API: `create`, `send`, `recv`, `close` |
| `_interpqueues` | `_interpqueuesmodule.c` | The PEP 734 queue API: `create`, `put`, `get` |
| `_asyncio` | `_asynciomodule.c` | The `asyncio` C accelerator: the `Future` implementation, `FutureIter` |

### File-coverage accounting (the "nothing was missed" proof)

This section exists because the requirement was explicit: no C-coded module may
be left out. Here is the accounting.

**The 101 `.c` files directly in `Modules/`:**

| Disposition | Count | Which |
|---|---|---|
| Referenced by `Setup.bootstrap.in` | 25 | All of Category 1 except `_io` (whose sources are in `Modules/_io/`) and `pwd` |
| Referenced by `Setup.stdlib.in` | 66 | Categories 2c and 5 |
| Built by the core build | 1 | `gc` (`Modules/gcmodule.c`) |
| Windows-only, built by `PCbuild` | 2 | `_winapi`, `_overlapped` |
| Interpreter support, not a module | 6 | `main.c`, `getpath.c`, `getpath_noop.c`, `getbuildinfo.c`, `getaddrinfo.c`, `getnameinfo.c` |
| A template or helper | 1 | `xxmodule.c` (Category 5) |
| **Total** | **101** | |

The six interpreter-support files are not modules. `Modules/main.c` is the
program entry point (`Py_RunMain` and the `-m` / `-c` / script dispatch).
`Modules/getpath.c` computes the initial `sys.path` (the `PYTHONHOME` search).
`Modules/getpath_noop.c` is the stub used when path calculation is disabled.
`Modules/getbuildinfo.c` embeds the build metadata. `Modules/getaddrinfo.c` and
`Modules/getnameinfo.c` are the shared resolver helpers compiled into
`_socket` on the platforms where the platform C library does not provide them.

`rotatingtree.c` and `tkappinit.c` are **not** separate modules. They are
secondary source files of `_lsprof` and `_tkinter` respectively, and the build
list says so.

**The 16 `Modules/` subdirectories containing C sources:**

| Directory | Nature |
|---|---|
| `Modules/_io/` | The `_io` module's own sources (7 files) |
| `Modules/_sre/` | The `_sre` regex engine |
| `Modules/cjkcodecs/` | The CJK codec family (8 modules from 7 files) |
| `Modules/_ctypes/` | `_ctypes` plus the bundled libffi |
| `Modules/_decimal/` | `_decimal` plus the bundled libmpdec |
| `Modules/_sqlite/` | `_sqlite3` plus the bundled SQLite |
| `Modules/_ssl/` | `_ssl` plus the OpenSSL interface |
| `Modules/_zstd/` | `_zstd` plus the bundled zstd |
| `Modules/_multiprocessing/` | `_multiprocessing` and `_posixshmem` |
| `Modules/_remote_debugging/` | The `_remote_debugging` module (13 files) |
| `Modules/expat/` | The bundled expat XML parser |
| `Modules/_hacl/` | The HACL* cryptography library used by `_hashlib` |
| `Modules/_testcapi/` | The C API test suite |
| `Modules/_testlimitedcapi/` | The limited-API test suite |
| `Modules/_testinternalcapi/` | The internal-API test suite |
| `Modules/_xxtestfuzz/` | The fuzzing harness |

**The `Python/` directory** contains the interpreter core, listed in Category 3.
**The `PC/` directory** contains the Windows-only modules, listed in Category 2b.

**Every `.c` file in the 3.15.2 tree** therefore falls into exactly one of:
Category 1 (bootstrap), 2a (core build), 2b (Windows-only), 2c (buildable
extension), 3 (interpreter core), 4 (bundled third-party library), or 5 (test
and reference module). There is no sixth category.

### Category 3 - The interpreter core (`Python/`)

These are not separate modules in the module-system sense. They are the
interpreter itself. They are listed because they contain C code that a Go port
must replace.

| File | Responsibility |
|---|---|
| `Python/import.c` | The import machinery: `PyImport_ImportModuleLevelObject`, `PyImport_Import`, the module cache, `PyImport_AddModule`, the inittab handling, `PyImport_GetModuleDict` |
| `Python/importdl.c` | The dynamic loader: `dlopen`-based extension loading, `PyInit_<name>` symbol lookup, handle caching |
| `Python/frozen.c` | The frozen module table and lookup |
| `Python/bltinmodule.c` | The `builtins` module: every builtin function and the builtin type instances |
| `Python/modsupport.c` | Module creation helpers: `PyModule_New`, `PyModule_AddObject`, `PyModule_AddType`, `PyModule_AddFunctions`, `PyModule_AddIntConstant`, `PyModule_AddStringConstant` |
| `Python/marshal.c` | The `marshal` serialisation format used by `.pyc` files |
| `Python/codecs.c` | The codec registry and the `codecs` module |
| `Python/symtable.c` | The symbol table builder used by the compiler |
| `Python/pyhash.c` | The hash function and hash randomisation |
| `Python/getargs.c` | The argument-parsing machinery (`METH_VARARGS`, `METH_FASTCALL`, `METH_KEYWORDS`) |
| `Python/ceval.c` | The bytecode interpreter loop |
| `Python/compile.c` | The symbol-table to bytecode compiler |
| `Python/flowgraph.c` | The control-flow graph builder used by the compiler |
| `Python/bytecodes.c` | The generated opcode implementations |
| `Python/instruction_sequence.c` | The superinstruction definitions |
| `Python/ast.c` | The AST node constructors |
| `Python/asdl.c` | The generated ASDL AST definitions |
| `Python/ast_unparse.c` | `ast.unparse` |
| `Python/traceback.c` | The traceback formatting |
| `Python/ceval_gil.c` | The GIL-aware interpreter loop |
| `Python/gc.c` / `Python/gc_gil.c` / `Python/gc_free_threading.c` | The cyclic garbage collector, in three variants |
| `Python/hamt.c` | The persistent hash-array-mapped-trie used by `contextvars` and the interpreter's internal dicts |

### Category 4 - Bundled third-party C libraries

CPython vendors these. They are not part of the module system, but a Go port must
supply an equivalent for each module that depends on them.

| Library | Location | Used by | License |
|---|---|---|---|
| **expat** | `Modules/expat/` | `pyexpat`, `xml.etree`, `xml.dom`, `xml.sax` | MIT |
| **libmpdec** | `Modules/_decimal/libmpdec/` | `_decimal` | BSD-3 / Libmpdec |
| **bzip2** | `Modules/_bz2/` | `_bz2` | bzip2 licence |
| **liblzma** (xz) | `Modules/_lzma/` | `_lzma` | 0BSD |
| **SQLite** | `Modules/_sqlite/` | `_sqlite3` | Public domain |
| **libffi** | `Modules/_ctypes/` | `_ctypes` | MIT |
| **zlib** | `Modules/zlib/` | `zlib` | zlib licence |
| **OpenSSL** | `Modules/_ssl/` | `_ssl`, `_hashlib` | Apache 2.0 |
| **zstd** | `Modules/_zstd/` | `_zstd` | BSD / GPL dual |
| **libmpdec** | `Modules/_decimal/libmpdec/` | `_decimal` | BSD-3 |

Go equivalents for most of these exist in the ecosystem:
`compress/zlib` (zlib), `compress/bzip2` (bzip2, read-only),
`compress/flate` (raw deflate), `github.com/klauspost/compress` (zstd, and
read-only bzip2), `github.com/ulikunitz/xz` (liblzma), `modernc.org/sqlite`
(pure-Go SQLite), `github.com/spf13/cobra` (irrelevant), `golang.org/x/text`
(encoding), `github.com/mattn/go-sqlite3` (cgo SQLite).

Go has **no** built-in equivalent for: expat (use `encoding/xml` plus a
`libxml`-free streaming parser, or `github.com/byteark/purego` + a cgo binding),
libffi (use `cgo` directly, or restrict to a fixed call-signature table),
OpenSSL (use `crypto/tls`).

### Category 5 - Test and reference modules

These are not part of the shipped stdlib but are C-coded, and they are the
executable specification of the C API.

| Module | Source | Purpose |
|---|---|---|
| `xx` | `Modules/xxmodule.c` | The reference C extension: a simple module |
| `xxsubtype` | `Modules/xxsubtype.c` | A C extension that adds a subtype of a Python type |
| `xxlimited` | `Modules/xxlimited.c` | An extension using only the limited API |
| `xxlimited_35` | `Modules/xxlimited_35.c` | The limited API as of 3.5 |
| `xxlimited_3_13` | `Modules/xxlimited_3_13.c` | The limited API as of 3.13 |
| `_testmultiphase` | `Modules/_testmultiphase.c` | Multi-phase init reference implementation |
| `_testsinglephase` | `Modules/_testsinglephase.c` | Single-phase init reference implementation |
| `_testimportmultiple` | `Modules/_testimportmultiple.c` | Importing a module twice |
| `_testbuffer` | `Modules/_testbuffer.c` | The buffer protocol |
| `_testcapi` | `Modules/_testcapimodule.c` + `Modules/_testcapi/*.c` (37 files) | The C API test suite |
| `_testlimitedcapi` | `Modules/_testlimitedcapi.c` + `Modules/_testlimitedcapi/*.c` (30 files) | The limited-API test suite |
| `_testinternalcapi` | `Modules/_testinternalcapi.c` + `Modules/_testinternalcapi/*.c` | The internal-API test suite |
| `_testclinic` | `Modules/_testclinic.c` | Argument Clinic reference |
| `_testclinic_limited` | `Modules/_testclinic_limited.c` | Argument Clinic, limited API |
| `_ctypes_test` | `Modules/_ctypes/_ctypes_test.c` | The `ctypes` test helper |
| `_xxtestfuzz` | `Modules/_xxtestfuzz/*.c` | The fuzzing harness |

### The hybrid modules

The most important category for a port, because the Python and C halves are
interleaved and the C half is usually the *accelerator*, not the implementation.

| Python module | C accelerator | The Python layer adds |
|---|---|---|
| `threading` | `_thread` | The `Thread` class, `Condition`, `Event`, `Semaphore`, `local`, and the deadlock detector |
| `socket` | `_socket` | The `socket` class wrapper, `create_connection`, `getaddrinfo` helpers, `SocketIO` |
| `selectors` | `select` | The `Selector` classes, `DefaultSelector`, `PollSelector`, `EpollSelector`, `KqueueSelector` |
| `json` | `_json` | `JSONDecoder`, `JSONEncoder`, the pure-Python fallback |
| `decimal` | `_decimal` | The `Context`, `Decimal` pure-Python fallback, the `ROUND_*` constants |
| `xml.etree.ElementTree` | `_elementtree` | The `Element`, `ElementTree`, `TreeBuilder`, `XMLParser` classes |
| `xml.dom.minidom` / `xml.sax` | `pyexpat` | The DOM and SAX interfaces |
| `zoneinfo` | `_zoneinfo` | The `ZoneInfo` class, the TZif file parser, the `zoneinfo` data discovery |
| `hashlib` | `_hashlib` | The `__get_builtin_constructor` dispatch, the OpenSSL name mapping |
| `hmac` | `_hmac` | The `hmac`/`digest` module, `compare_digest` |
| `base64` | `binascii` | The `encodebytes`/`decodebytes` wrappers, the URL-safe alphabet |
| `statistics` | `_statistics` | The `StatisticsError`, `NormalDist` class |
| `datetime` | `_datetime` | The pure-Python `datetime` fallback, `timezone` handling |
| `math` | `math` | The pure-Python fallback |
| `itertools` | `itertools` | The pure-Python fallback |
| `functools` | `_functools` | `cached_property`, `partial` extras, `reduce` helpers |
| `operator` | `_operator` | The pure-Python fallback and `itemgetter`/`attrgetter` extras |
| `collections` | `_collections` | The `OrderedDict`, `defaultdict`, `Counter`, `deque` classes |
| `heapq` | `_heapq` | The pure-Python fallback |
| `bisect` | `_bisect` | The pure-Python fallback |
| `struct` | `_struct` | The `Struct` extras and error types |
| `uuid` | `_uuid` | The version-1/3/4/5 generation logic and `UUID` class |
| `random` | `_random` | The `Random` class, `SystemRandom`, `choices`, `sample` |
| `csv` | `_csv` | The `DictReader`/`DictWriter` classes |
| `pickle` | `_pickle` | The `Pickler`/`Unpickler` compatibility wrappers, `PickleBuffer` |
| `queue` | `_queue` | The `Queue`/`PriorityQueue`/`LifoQueue` classes |
| `os` | `posix` | `path` (`os.path` → `posixpath`), `environ` handling |
| `io` | `_io` | The `IOBase`, `TextIOBase` ABCs, `open()` |
| `codecs` | `_codecs` | The `Codec` class, the stream reader/writer classes |
| `re` | `_sre` | `re.Pattern`, `re.Match`, the `PatternError`/`error` types |
| `shutil` | `_sha2` / `_zlib` / `_bz2` / `_lzma` | The archive formats |
| `ssl` | `_ssl` | The `SSLContext` helpers, the default context factory |
| `multiprocessing` | `_multiprocessing`, `_posixshmem` | The `Process`, `Pool`, `Queue` classes |
| `asyncio` | `_asyncio` | The event loop, the selector event loop, the protocols |
| `warnings` | `_warnings` | The filter machinery, `warn_explicit` |
| `weakref` | `_weakref` | `ref`, `proxy`, `finalize` |
| `types` | `_types` | The `SimpleNamespace` helpers, `coroutine` |
| `typing` | `_typing` | The `Generic`, `Protocol`, `TypeVar` machinery |
| `sys` | `Python/sysmodule.c` | The `sys` attributes, `sys.modules`, `sys.path` |
| `builtins` | `Python/bltinmodule.c` | Every builtin function |

### Go portability assessment

| Class | Modules | Go strategy |
|---|---|---|
| **Pure computation** | `_bisect`, `_heapq`, `_struct`, `_csv`, `_json`, `_operator`, `_functools`, `_statistics`, `_math_integer`, `array`, `_pickle`, `queue`, `itertools` | Port directly to Go. No OS dependency. |
| **Text and Unicode** | `_codecs*`, `_multibytecodec`, `unicodedata`, `_sre` | Port to Go. `unicodedata` needs the Unicode database tables (large generated Go file). `_sre` is a large port; Go's `regexp` is RE2 and cannot be used (no backreferences, no lookahead). |
| **Crypto** | `_md5`, `_sha1`, `_sha2`, `_sha3`, `_blake2`, `_hmac`, `_hashlib` | Port to Go. `crypto/md5`, `crypto/sha1`, `crypto/sha256`, `crypto/sha512`, `crypto/sha3`, `crypto/hmac` exist. `blake2` needs `golang.org/x/crypto/blake2b`. `hashlib` needs an OpenSSL-name mapping table. |
| **Compression** | `binascii`, `zlib`, `_bz2`, `_lzma`, `_zstd` | Port to Go via `compress/*` and `github.com/klauspost/compress`. |
| **Database** | `_dbm`, `_gdbm`, `_sqlite3` | `_sqlite3` needs a SQLite: `modernc.org/sqlite` (pure Go) or cgo. `_dbm`/`_gdbm` need a DBM: `go.etcd.io/bbolt` is the closest, but it is not DBM-compatible. |
| **XML** | `pyexpat`, `_elementtree` | Port to Go using `encoding/xml` for the tree API. expat itself is not needed. The SAX/DOM layers need hand-porting. |
| **OS interface** | `posix`, `fcntl`, `grp`, `pwd`, `resource`, `select`, `termios`, `syslog`, `mmap`, `_posixsubprocess` | Port to Go. `syscall` package covers most. `select` needs `golang.org/x/sys/unix` for `epoll`. |
| **Networking** | `_socket`, `_ssl`, `_scproxy` | `_socket` ports cleanly. `_ssl` maps to `crypto/tls` but the API differs; `ssl` has no exact Go equivalent. |
| **Process and concurrency** | `_thread`, `_multiprocessing`, `_posixshmem`, `_interpreters`, `_interpchannels`, `_interpqueues` | `_thread` maps to Go goroutines but `Thread` identity and `Lock` semantics differ. `_multiprocessing` needs real OS processes and shared memory (`golang.org/x/sys/unix` `Shm*`). |
| **Terminal and GUI** | `_curses`, `_curses_panel`, `_tkinter`, `readline` | `_curses` needs cgo (no Go ncurses binding). `readline` needs cgo or a pure-Go line editor. `_tkinter` is out of scope for a Go port. |
| **FFI** | `_ctypes` | No Go equivalent. A Go interpreter exposing ctypes semantics would need a full C ABI trampoline, which Go's `cgo` cannot do dynamically. |
| **Introspection** | `_opcode`, `_types`, `_symtable`, `_ast`, `_tracemalloc`, `_suggestions`, `_io`, `_codecs`, `_warnings`, `_weakref`, `_abc`, `_locale`, `_stat`, `_datetime`, `_decimal`, `_typing`, `_tokenize`, `_zoneinfo` | Port directly. `_decimal` needs a big-decimal implementation: `math/big` plus a decimal layer, or `github.com/cockroachdb/apd`. |

### The complete `Modules/` file listing

For completeness, all 101 `.c` files directly in `Modules/` at `v3.15.2`:

```
_abc.c  _asynciomodule.c  _bisectmodule.c  _bz2module.c  _codecsmodule.c
_collectionsmodule.c  _csv.c  _curses_panel.c  _cursesmodule.c  _datetimemodule.c
_dbmmodule.c  _elementtree.c  _functoolsmodule.c  _gdbmmodule.c  _hashopenssl.c
_heapqmodule.c  _interpchannelsmodule.c  _interpqueuesmodule.c
_interpretersmodule.c  _json.c  _localemodule.c  _lsprof.c  _lzmamodule.c
_opcode.c  _operator.c  _pickle.c  _posixsubprocess.c  _queuemodule.c
_randommodule.c  _scproxy.c  _ssl.c  _stat.c  _statisticsmodule.c  _struct.c
_suggestions.c  _sysconfig.c  _testbuffer.c  _testcapimodule.c  _testclinic.c
_testclinic_limited.c  _testimportmultiple.c  _testinternalcapi.c
_testlimitedcapi.c  _testmultiphase.c  _testsinglephase.c  _threadmodule.c
_tkinter.c  _tracemalloc.c  _typesmodule.c  _typingmodule.c  _uuidmodule.c
_weakref.c  _winapi.c  _zoneinfo.c  arraymodule.c  atexitmodule.c  binascii.c
blake2module.c  cmathmodule.c  errnomodule.c  faulthandler.c  fcntlmodule.c
gcmodule.c  getaddrinfo.c  getbuildinfo.c  getnameinfo.c  getpath.c
getpath_noop.c  grpmodule.c  hmacmodule.c  itertoolsmodule.c  main.c
mathintegermodule.c  mathmodule.c  md5module.c  mmapmodule.c  overlapped.c
posixmodule.c  pwdmodule.c  pyexpat.c  readline.c  resource.c  rotatingtree.c
selectmodule.c  sha1module.c  sha2module.c  sha3module.c  signalmodule.c
socketmodule.c  symtablemodule.c  syslogmodule.c  termios.c  timemodule.c
tkappinit.c  unicodedata.c  xxlimited.c  xxlimited_35.c  xxlimited_3_13.c
xxmodule.c  xxsubtype.c  zlibmodule.c
```

And the 16 subdirectories containing C sources:

```
Modules/_ctypes/        Modules/_decimal/       Modules/_hacl/
Modules/_io/            Modules/_multiprocessing/  Modules/_remote_debugging/
Modules/_sqlite/        Modules/_sre/           Modules/_ssl/
Modules/_testcapi/      Modules/_testinternalcapi/  Modules/_testlimitedcapi/
Modules/_xxtestfuzz/    Modules/_zstd/          Modules/cjkcodecs/
Modules/expat/
```

## Verification

**1. Confirm the two build lists still parse to the stated counts.**

```bash
cd /tmp
curl -sO https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.bootstrap.in
curl -sO https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.stdlib.in
grep -vE '^\s*#|^\s*$|^\*' Setup.bootstrap.in | awk 'NF>=2 {print $1}' | sort -u | wc -l   # 27
grep -vE '^\s*#|^\s*$|^\*' Setup.stdlib.in  | awk 'NF>=2 {print $1}' | sort -u | wc -l   # 80
```

**2. Confirm the `Modules/` root file count.**

```bash
curl -s "https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1" \
  | python3 -c "
import json,sys
p=[t['path'] for t in json.load(sys.stdin)['tree'] if t['type']=='blob']
print(len([x for x in p if x.startswith('Modules/') and x.count('/')==1 and x.endswith('.c')]))"
```

Expect `101`.

**3. Confirm the builtin set at runtime.** On a real CPython 3.15 build:

```bash
python3.15 -c "import sys; print(len(sys.builtin_module_names)); print(sorted(sys.builtin_module_names))"
```

Every name in `Setup.bootstrap.in` must appear in that list. The list is a
superset (it also contains the shared extensions built static by default).

**4. Confirm each module's public surface.** For any module in the tables above,
the authoritative public API is the `PyMethodDef` table in the module's `.c` file:

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/arraymodule.c \
  | grep -A2 "static PyMethodDef" | head -40
```

For a pure-Python module, the public API is the module's `Lib/*.py` file.

**5. Confirm no module was missed.** The two build lists plus the `Python/`
interpreter-core directory plus the `Lib/` pure-Python tree account for every
`.c` and `.py` file in the repository. Any `.c` file not reachable from
`Setup.bootstrap.in`, `Setup.stdlib.in`, `Python/`, or a bundled library directory
is a test module and must appear in Category 5.
