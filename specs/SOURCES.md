# Sources - CPython 3.15 Module System and gpython Upgrade

## Anchor sources (read in full or parsed in full)

| URL | Read on | Type | Used in |
|---|---|---|---|
| `https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1` | 2026-11-18 | JSON, 6141 entries | `00-foundations/01-scope-and-baseline.md`, `03-c-modules/01-c-module-inventory.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/patchlevel.h` | 2026-11-18 | C header | `00-foundations/01-scope-and-baseline.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.bootstrap.in` | 2026-11-18 | Build config | `03-c-modules/01-c-module-inventory.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.stdlib.in` | 2026-11-18 | Build config | `03-c-modules/01-c-module-inventory.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup` | 2026-11-18 | Build config | `03-c-modules/01-c-module-inventory.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Makefile.pre.in` | 2026-11-18 | Makefile | `03-c-modules/01-c-module-inventory.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap.py` | 2026-11-18 | Python, 1553 lines | `01-module-system/01-import-pipeline.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/importlib/_bootstrap_external.py` | 2026-11-18 | Python, 58 KB | `01-module-system/01-import-pipeline.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/import.c` | 2026-11-18 | C, 173 KB | `01-module-system/01-import-pipeline.md`, `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/importdl.c` | 2026-11-18 | C, 17 KB | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Python/modsupport.c` | 2026-11-18 | C | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/moduleobject.h` | 2026-11-18 | C header, 124 lines | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/slots.h` | 2026-11-18 | C header, 56 lines | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/slots_generated.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/cpython/import.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/modsupport.h` | 2026-11-18 | C header, 160 lines | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/methodobject.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/internal/pycore_import.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/internal/pycore_importdl.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/internal/pycore_moduleobject.h` | 2026-11-18 | C header | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Objects/moduleobject.c` | 2026-11-18 | C | `01-module-system/02-module-object-model.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Grammar/python.gram` | 2026-11-18 | PEG grammar, 76 KB | `02-language-upgrade/01-language-gap.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Grammar/Tokens` | 2026-11-18 | Token list, 1893 bytes | `02-language-upgrade/01-language-gap.md` |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Parser/Python.asdl` | 2026-11-18 | ASDL, 154 lines | `02-language-upgrade/01-language-gap.md` |

## Documentation sources

| URL | Read on | Used for |
|---|---|---|
| `https://docs.python.org/3/whatsnew/3.15.html` | 2026-11-18 | The 3.15 release notes and the 3.15 feature set |
| `https://docs.python.org/3/whatsnew/3.14.html` | 2026-11-18 | The 3.14 feature set |
| `https://docs.python.org/3/whatsnew/3.13.html` | 2026-11-18 | The 3.13 feature set and the removal list |
| `https://docs.python.org/3/whatsnew/3.12.html` | 2026-11-18 | The 3.12 feature set and removals |
| `https://docs.python.org/3/whatsnew/3.11.html` | 2026-11-18 | The 3.11 feature set |
| `https://docs.python.org/3/whatsnew/3.10.html` | 2026-11-18 | The 3.10 feature set |
| `https://docs.python.org/3/whatsnew/3.9.html` | 2026-11-18 | The 3.9 feature set and the PEG parser |
| `https://docs.python.org/3/whatsnew/3.8.html` | 2026-11-18 | The 3.8 feature set |
| `https://docs.python.org/3/whatsnew/3.7.html` | 2026-11-18 | The 3.7 feature set |
| `https://docs.python.org/3/whatsnew/3.6.html` | 2026-11-18 | The 3.6 feature set |
| `https://docs.python.org/3/whatsnew/3.5.html` | 2026-11-18 | The 3.5 feature set and the 3.5 release date |
| `https://peps.python.org/pep-0594/` | 2026-11-18 | The 19-module "dead batteries" removal list |
| `https://peps.python.org/pep-0790/` | 2026-11-18 | The 3.15 release schedule |
| `https://peps.python.org/pep-0826/` | 2026-11-18 | The 3.16 development schedule |

## Web research sources (the normative specifications)

These are the sources for `02-language-upgrade/03-web-research-language-semantics.md`.
Fetched on 2026-11-18.

| URL | Used for |
|---|---|
| `https://peps.python.org/pep-0701/` | The f-string grammar, the three tokens, the 5-level nesting lower bound, the untokenize requirement |
| `https://peps.python.org/pep-0634/` | The full `match` grammar, the pattern semantics, the sequence protocol, `__match_args__` |
| `https://peps.python.org/pep-0695/` | The type parameter syntax, the annotation scope rules, the lazy evaluation model |
| `https://peps.python.org/pep-0654/` | `ExceptionGroup` and `except*` semantics, the recursive matching rule, the forbidden combinations |
| `https://peps.python.org/pep-0749/` | `annotationlib`, the `__annotate__` signature, the `STRING` format rename, the stringifier's supported expressions |
| `https://peps.python.org/pep-0709/` | The before/after comprehension bytecode, the visible behaviour changes |
| `https://docs.python.org/3/reference/compound_stmts.html` | The 3.15.2 Language Reference grammar for `try`, `match`, `funcdef`, `classdef` |
| `https://docs.python.org/3/whatsnew/3.15.html` | The 3.15 removals list, the PEP 810 restrictions, `frozendict`, `sentinel` |
| `https://github.com/python/cpython/blob/main/InternalDocs/inlined_comprehensions.md` | The PEP 709 symbol table rules, `InlinedComprehensionBlock`, the codegen entry/exit functions |
| `https://github.com/python/cpython/pull/101441` | The `LOAD_FAST_AND_CLEAR` rationale, the cell-in-`co_varnames` handling |
| `https://github.com/python/cpython/issues/97933` | The original inlining proposal, the `locals()` and traceback changes |
| `https://jellezijlstra.github.io/pep695.html` | The PEP 695 implementer's notes, the `&"type"` lookahead, the rule-ordering constraint |

## Local sources

| Path | Used for |
|---|---|
| `/home/bennie/Desktop/ansible/gpython` at `8c979bc` | The gpython baseline: package layout, stdlib inventory, dependency graph |
| `/home/bennie/Desktop/ansible/gpython/HERMES.md` | The repo's own agent instructions, written earlier in the same session |
| `/home/bennie/Desktop/ansible/gpython/notes.txt` | gpython's own list of known gaps |
| `/home/bennie/Desktop/ansible/go_ansible/specs/research/01-gpython-capability-assessment.md` | The prior gpython capability measurement, used for context on the parse-rate baseline |

## Local prior research artifacts

| Path | Used in | Notes |
|---|---|---|
| `specs/research/00-agent-import-mechanism.md` | Raw material for `01-module-system/` | 98 KB agent report; cites `main`, not `v3.15.2`. Superseded where it differs. |
| `specs/research/00-agent-c-module-inventory.md` | Raw material for `03-c-modules/` | 79 KB agent report. Its inventory was cross-checked against the build lists and corrected. |
| `specs/research/00-agent-language-upgrade.md` | Raw material for `02-language-upgrade/` | 63 KB agent report. Its PEP list was verified against the 3.15.2 grammar and ASDL. |

## Live runtime checks

| Command | Purpose | Result |
|---|---|---|
| `python3.14 -c "import sys; print(sorted(sys.builtin_module_names))"` | Cross-check the built-in module list | 111 names; agrees with the build lists |
| `python3.14 -c "import sys; print(repr(sys.path[0]))"` | Verify the `sys.path[0]` rule | `''` for `-c` |
| `python3.14 /tmp/pp.py` | Verify `sys.path[0]` for a script | the script's directory |
| `python3.14 -m pp` | Verify `sys.path[0]` for `-m` | the current working directory |
| `python3.14 -c "import xml; from xml import etree"` | Verify the fromlist submodule-import rule | `xml.etree` absent before, present after |

## Failed and superseded sources

| Source | Date | Reason | Fallback |
|---|---|---|---|
| `https://api.github.com/search/code?q=Py_mod_create+repo:python/cpython` | 2026-11-18 | Returns HTTP 401: "Requires authentication". The code-search API needs a token. | Located the definition by fetching every candidate public header and grepping locally. Found it in `Include/slots_generated.h`. |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Lib/ast.py` | 2026-11-18 | Does not contain the AST node definitions - it is a thin re-export of the C `_ast` module (`from _ast import *`). Grepping it for `class Import` returns nothing. | Used `Parser/Python.asdl`, the authoritative ASDL definition the C AST is generated from. |
| `https://raw.githubusercontent.com/python/cpython/main/...` (the `main` branch) | 2026-11-18 | `main` is 3.16.0a2+dev, not 3.15. Any behaviour cited from `main` does not describe the 3.15 release. | Re-fetched every file from the `v3.15.2` tag. |
| `Include/moduleobject.h` for the `Py_mod_*` enum | 2026-11-18 | The enum is not in that header; only the `Py_MOD_*` value macros are. | Found the slot IDs in `Include/slots_generated.h`. |
| `Include/import.h` for the `Py_mod_*` enum | 2026-11-18 | Contains only `_inittab` and `_frozen`. | `Include/slots_generated.h`. |
| `Lib/test/test_ast` for the AST node list | 2026-11-18 | Not a definition source. | `Parser/Python.asdl`. |

## Verification gaps

These remain open. They are stated so a later session does not treat the spec
set as complete where it is not.

1. **The `Py_mod_*` legacy slot numeric values were not cross-checked against
   the 3.14 source.** The 3.15 values are
   `_Py_SLOT_COMPAT_VALUE(1, 84)` style, carrying both an old and a new ID. The
   old IDs are almost certainly 1, 2, 3, 4 in order, but this was not verified
   against the 3.14 tag. A Go implementation that needs the legacy numeric IDs
   must check `v3.14.0/Include/moduleobject.h` directly.

2. **The bundled third-party library versions were not pinned.** The
   `03-c-modules` spec names expat, libmpdec, bzip2, liblzma, SQLite, libffi,
   zlib, OpenSSL and zstd, but their exact vendored versions were not
   confirmed. `Modules/_decimal/libmpdec/` and `Modules/expat/` carry their own
   version files; read them directly.

3. **The `Py_mod_abi` / `PyABIInfo` mechanism was not fully documented.** The
   slot exists and is dispatched in `Objects/moduleobject.c`, but the
   `PyABIInfo` struct and the version-comparison rule were not read in full.
   This matters only for a Go implementation that wants to mirror the ABI
   check.

4. **The 3.15 `profiling` package contents were not itemised.** The spec
   records that `profiling.tracing` and `profiling.sampling` exist. Their full
   public API was not read.

5. **The `annotationlib` public API was not fully specified.** The three
   `Format` values and `get_annotations()` were identified by the research
   agent; the exact signatures were not read from `Lib/annotationlib.py`.

6. **The `frozendict` and `sentinel` type semantics were not read.** The spec
   records their existence and PEP numbers. Their methods, construction rules
   and hashability were not read from `Objects/`.

7. **The `zip(..., strict=True)`, `int.bit_count` and other small runtime
   additions were taken from the research agent's verified list**, which cited
   the What's New pages. They were not independently re-fetched.

8. **The "PEPs that did NOT ship" list was not independently verified.** The
   research agent flagged PEP 711, 712, 713, 714, 720, 721, 723, 725, 733, 780,
   789 and 794 as rejected or withdrawn based on searching the docs. Each should
   be checked at `peps.python.org` before being relied on.
9. **The 3.15 Removed section is now known at the module level, but not at the
   function level.** The modules with removals in 3.15 are `ast`,
   `collections.abc`, `ctypes`, `datetime`, `glob`, `http.server`,
   `importlib`, `importlib.resources`, `pathlib`, `platform`, `sre_*`,
   `sysconfig`, `threading`, `types`, `typing`, `wave` and `zipimport`. The
   individual removed functions within those modules are not yet itemised.
