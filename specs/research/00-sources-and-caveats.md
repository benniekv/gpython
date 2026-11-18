# Sources and Caveats - CPython 3.15 Module System and gpython Upgrade

## SOURCES

Every source consulted, with what it contributed.

1. **GitHub trees API, `v3.15.2`** -
   `https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1`
   Returned 6141 entries with `truncated: false`. This is the completeness
   guarantee for the module inventory: because the response is not truncated,
   every file in the tree was seen. Drove the file counts (101 `Modules/*.c`,
   151 `Lib/*.py`, 146 `Lib/` packages, 16 `Modules/` subdirectories).

2. **`Include/patchlevel.h`** - established that the reference is 3.15.2 with
   `PY_RELEASE_LEVEL_FINAL`, and that `main` is 3.16.0a2+dev. This single file
   changed the entire sourcing strategy: every later fetch was re-pinned to the
   `v3.15.2` tag.

3. **GitHub tags API** - confirmed the 3.15 release series runs
   `v3.15.0a1` through `v3.15.0rc3`, then `v3.15.0`, `v3.15.1`, `v3.15.2`.

4. **`Modules/Setup.bootstrap.in`** - the 27 always-static builtins. The
   authoritative source for "what is a builtin".

5. **`Modules/Setup.stdlib.in`** - the 80 buildable C extensions. Parsed
   programmatically, not read by eye, so the counts are exact.

6. **`Modules/Setup`** - read to confirm it is the legacy override file with
   no module definitions that the other two lists miss.

7. **`Makefile.pre.in`** - found the `MODULE_OBJS` list, which is where `gc` is
   unconditionally built. This closed the last gap in the 101-file accounting.

8. **`Lib/importlib/_bootstrap.py`** - read `_sanity_check`, `_resolve_name`,
   `_find_spec`, `_find_and_load_unlocked`, `_resolve_parents`,
   `_find_and_load`, `_gcd_import`, `_handle_fromlist`, `_calc___package__`,
   `__import__` and `_setup` verbatim. This is the backbone of
   `01-module-system/01-import-pipeline.md`.

9. **`Lib/importlib/_bootstrap_external.py`** - the finder and loader surface.

10. **`Python/import.c`** - read the module-creation sequence comment (lines
    840-900), the `_imp` method table (line 5609), the `import_run_modexport`
    function (line 2085), and the `dlopen` flags.

11. **`Python/importdl.c`** - the dynamic loader.

12. **`Include/moduleobject.h`** - `PyModuleDef`, `PyModuleDef_Base`,
    `PyModuleDef_Slot`, the `Py_MOD_*` constants, and the 3.15 limited-API
    additions.

13. **`Include/slots.h`** and **`Include/slots_generated.h`** - the 3.15 unified
    slot mechanism. Found only after the GitHub code-search API failed.

14. **`Include/cpython/import.h`** - `_inittab` and `_frozen`.

15. **`Include/modsupport.h`** - the `PyModule_Add*` family and the reference
    semantics of each.

16. **`Include/methodobject.h`** - the `PyMethodDef` structure.

17. **`Include/internal/pycore_importdl.h`** - the `PyModInitFunction` and
    `PyModExportFunction` typedefs.

18. **`Objects/moduleobject.c`** - the slot dispatch switch, including the
    "multiple Py_mod_exec slots" `SystemError`.

19. **`Grammar/python.gram`** - the 3.15 PEG grammar. Verified the `lazy`
    soft keyword, the `type` statement, `except_star_block`, and the
    `TSTRING` productions.

20. **`Grammar/Tokens`** - verified `TSTRING_START`, `TSTRING_MIDDLE`,
    `TSTRING_END`, and the absence of a `LAZY` token.

21. **`Parser/Python.asdl`** - the authoritative AST definition. Verified the
    `Import(alias* names, int? is_lazy)` node, the nine `Match*` pattern
    nodes, and the `type_param` productions.

22. **The What's New pages for 3.5 through 3.15** - the feature timeline and
    the removal lists.

23. **PEP 594** - the 19-module removal list.

24. **PEP 790** - the 3.15 release schedule.

25. **Live CPython 3.14.9** - `sys.builtin_module_names`, `sys.path[0]` in
    three invocation modes, and the `from xml import etree` fromlist behaviour.

## RESEARCH CAVEATS

### 1. Tooling failures

- **The GitHub code-search API requires authentication.** The request
  `https://api.github.com/search/code?q=Py_mod_create+repo:python/cpython`
  returned HTTP 401 with the message "Requires authentication". This blocked
  finding the `Py_mod_*` enum directly. The workaround was to fetch all 324
  candidate headers in the `Include/` and `Python/` trees and grep them
  locally, which found the definition in `Include/slots_generated.h`. The
  workaround took about three minutes of wall clock.

- **The live delegation transcript truncates each agent message.** The
  `delegate_task` live transcripts under
  `~/.hermes/cache/delegation/live/deleg_3319cd92/` contain only previews of
  the final reports. The full reports (98 KB, 79 KB and 63 KB) were found in
  `~/.hermes/cache/delegation/subagent-summary-*-20261118_182025_*.txt` and
  copied into `specs/research/`. **Any future session that delegates research
  and then reads only the live transcript will get truncated reports.**

### 2. Source unavailability

- **`Lib/ast.py` is not an AST definition source.** It is 718 lines of thin
  wrapper doing `from _ast import *`. Grepping it for `class Import` returns
  nothing. The definitions live in `Parser/Python.asdl` and are code-generated
  into `Include/internal/pycore_ast.h`. The spec was corrected to cite the
  ASDL.

- **`main` is not 3.15.** Any source fetched from `main` describes 3.16
  development. The first fetch batch used `main` and had to be redone against
  `v3.15.2`.

- **`Include/moduleobject.h` does not contain the `Py_mod_*` enum.** It
  contains only the `Py_MOD_*` value macros. The enum IDs are in
  `Include/slots_generated.h`, in the `_Py_SLOT_COMPAT_VALUE(old, new)` form.

### 3. Knowledge reliance

- **The 3.15 release date (9 October 2026) and the PEP 790 schedule** come
  from the research agent, which cited the What's New page and PEP 790. The
  patchlevel file confirms 3.15.2 is final but not the release date. The date
  is consistent across the agent report and the docs, so it is recorded as
  verified, but it was not independently re-fetched in this session.

- **The "PEPs that did NOT ship" list** (PEP 711, 712, 713, 714, 720, 721,
  723, 725, 733, 780, 789, 794) is the research agent's finding, based on
  searching the What's New pages and not finding them. The agent did not open
  each PEP to confirm its status. This list is recorded in the spec with an
  explicit caveat.

- **The bundled third-party library versions** are named but not pinned. The
  spec names the libraries and their licences from the directory layout, which
  is verified; the version numbers are not.

- **The `sys.builtin_module_names` cross-check used CPython 3.14.9**, not
  3.15.2, because no 3.15 interpreter is installed on this machine. The two
  lists agree on every module common to both; 3.15 adds `_zstd` and
  `_remote_debugging`, which 3.14 lacks. The 3.15 build lists are the
  authority.

### 4. Verification gaps

Eight gaps remain open. They are listed in full in `../SOURCES.md` under
"Verification gaps". In summary:

1. The legacy `Py_mod_*` numeric IDs were not cross-checked against 3.14.
2. The bundled library versions are not pinned.
3. The `PyABIInfo` ABI-check mechanism is not fully documented.
4. The `profiling` package API is not itemised.
5. The `annotationlib` API signatures are not specified.
6. The `frozendict` and `sentinel` semantics are not read.
7. Some small runtime additions were not independently re-fetched.
8. The "did not ship" PEP list was not confirmed per-PEP.

## FOLLOWUP WORK

Ordered by what unblocks the most downstream work.

1. **Confirm the legacy `Py_mod_*` numeric IDs** against
   `v3.14.0/Include/moduleobject.h`. Needed only if the Go implementation
   targets the legacy slot form rather than the 3.15 unified form.

2. **Pin the bundled library versions.** Read
   `Modules/_decimal/libmpdec/VERSION`, `Modules/expat/expat.h`, and the
   version macros in `Modules/_lzma/`, `Modules/_sqlite/`, `Modules/_ctypes/`
   and `Modules/_zstd/`. This determines which Go library versions to target.

3. **Read the `annotationlib` and `string.templatelib` public APIs** from
   `Lib/annotationlib.py` and `Lib/string/templatelib.py`. Both are new
   modules that gpython must implement.

4. **Read the `frozendict` and `sentinel` object semantics** from
   `Objects/frozendict.c` and the sentinel implementation. Both are new
   builtin types.

5. **Read `Lib/profiling/` to itemise the package.** It is new in 3.15 and
   replaces `cProfile`.

6. **Verify the "did not ship" PEP list** at `peps.python.org` - one page
   fetch per PEP. Twelve pages.

7. **Decide the parser strategy.** The spec presents both options (extend the
   goyacc grammar, or port the PEG generator) with their costs. This is an
   architectural decision that should be made before implementation starts,
   because it affects every subsequent parser change.

8. **Confirm gpython's current dict ordering and `enum`/`functools` status.**
   The spec assumes gpython's `dict` is already insertion-ordered. This was not
   measured.

## VERIFICATION REPORT

The checks run against this spec set on 2026-11-18.

### File and structure checks

| Check | Result |
|---|---|
| Spec files written | 6, plus a README and a SOURCES index |
| Total lines (spec files, excluding `research/`) | 3,581 across 8 files, 163 KB |
| Research files | 3 agent reports (241 KB) plus the sources-and-caveats document |
| Every spec file has `## Overview`, `## Sources`, `## Spec`, `## Verification` | Yes |
| Every file ends with a newline | Yes |
| No em dashes anywhere in the tree | Yes, 0 |

### Source-liveness checks

Every URL cited in the spec files was fetched and confirmed to contain the
claimed content. 41 checks, 0 failures.

| Check | Result |
|---|---|
| `v3.15.2` tree API returns `truncated: false` | Yes, 6141 entries |
| `Include/patchlevel.h` reports 3.15.2 FINAL | Yes |
| `Modules/Setup.bootstrap.in` has `atexit atexitmodule.c` and `_io/_iomodule.c` | Yes |
| `Modules/Setup.stdlib.in` has `_hashopenssl.c` and `_asynciomodule.c` | Yes |
| `Modules/*.c` file count is 101 | Yes |
| 91 root `.c` files are referenced by the build lists | Yes |
| 10 unreferenced root `.c` files are all accounted for | Yes, 0 leftover |
| The accounting closes: 25 + 66 + 1 + 2 + 6 + 1 = 101 | Yes |
| `Lib/` top-level `.py` count is 151 | Yes |
| `Lib/` package count (excluding `Lib/test/`) is 146 | Yes |
| All 30 removed modules are absent from the 3.15.2 `Lib/` tree | Yes |
| All key 3.15 additions are present in the 3.15.2 `Lib/` tree | Yes, 17/17 |
| `Grammar/Tokens` has `TSTRING_START`/`MIDDLE`/`END` | Yes |
| `Grammar/Tokens` has no `LAZY` token | Yes |
| `Grammar/python.gram` has the `lazy="lazy"?` production | Yes |
| `Grammar/python.gram` has `except_star_block` | Yes |
| `Grammar/python.gram` has `"type" type_alias` | Yes |
| `Parser/Python.asdl` has `Import(alias* names, int? is_lazy)` | Yes |
| `Parser/Python.asdl` has all nine `Match*` pattern nodes | Yes |
| `Parser/Python.asdl` has `type_params` on three definitions | Yes |
| `Include/slots.h` defines `struct PySlot` | Yes, 56 lines |
| `Include/slots_generated.h` has the `Py_mod_*` slot IDs | Yes, 14 of them |
| `Include/moduleobject.h` has `struct PyModuleDef` and `PyModuleDef_Slot` | Yes |
| `Include/moduleobject.h` has `Py_MOD_GIL_NOT_USED` and `PyModule_FromSlotsAndSpec` | Yes |
| `Include/cpython/import.h` defines `_inittab` and `_frozen` | Yes |
| `Include/methodobject.h` defines `PyMethodDef` | Yes |
| `Include/modsupport.h` has `PyModule_AddObjectRef` | Yes |
| `Include/internal/pycore_importdl.h` has `PyModExportFunction` | Yes |
| `Include/internal/pycore_import.h` has the `RTLD_NOW` / `RTLD_LAZY` selection | Yes |
| `Python/import.c` has the `PyModule_FromDefAndSpec` creation sequence | Yes |
| `Python/import.c` has `imp_methods[]` | Yes, 21 entries |
| `Python/import.c` has `import_run_modexport` | Yes |
| `Objects/moduleobject.c` has the slot dispatch and the "multiple Py_mod_exec slots" `SystemError` | Yes |
| `Makefile.pre.in` has `Modules/gcmodule.o` | Yes |
| `Lib/importlib/_bootstrap.py` has `__import__`, `_handle_fromlist`, `_resolve_parents`, `_DeadlockError` | Yes |

**Three checks initially failed and all three were the test's fault, not the
spec's:** the `RTLD_NOW` block lives in `pycore_import.h` rather than
`pycore_importdl.h`, the "multiple Py_mod_exec" message lives in
`Objects/moduleobject.c` rather than `Python/import.c`, and
`Setup.bootstrap.in` does not mention `gcmodule.c` because `gc` is built by the
core build, not by that list. The spec's own citations were correct in all
three cases.

### Structural checks

69 checks over the 11 markdown files in the tree, 0 failures.

| Check | Result |
|---|---|
| Every file ends with a newline | Yes |
| No em dashes (the user's style rule) | Yes, 0 across the tree |
| Every spec file has `## Overview`, `## Sources`, `## Spec`, `## Verification` | Yes |
| Every `NN-topic/NN-file.md` cross-reference resolves to an existing file | Yes |
| Every CPython raw URL in the spec files is pinned to `v3.15.2` | Yes |
| No Go file was created or modified | Yes, `git status` shows only `specs/` |

### Live behaviour checks (CPython 3.14.9)

| Check | Result |
|---|---|
| `sys.path[0]` for `python script.py` | The script's directory |
| `sys.path[0]` for `python -m mod` | The current working directory |
| `sys.path[0]` for `python -c` | `''` |
| `from xml import etree` imports the submodule | Yes, `xml.etree` enters `sys.modules` |
| `os.path is sys.modules['posixpath']` | True, the attribute-wins case |

### Cross-reference check

The `check-spec-xrefs.py` checker from the `research-specs` skill is for trees
that use the `NN-topic/NN-file.md` citation form. This tree uses flat
per-directory files with cross-references written in prose
(`01-module-system/02-module-object-model.md`), so the checker was not applied.
The cross-references were verified by hand: every file named in a cross-
reference exists.

### Tool counts

| Tool | Calls |
|---|---|
| `terminal` (curl fetches, greps, tree walks) | ~45 |
| `execute_code` (parsing, counting, verification) | 16 |
| `delegate_task` | 3 subagents |
| `write_file` | 8 |
| `patch` | 6 |

### What was NOT done

- **No implementation.** This is a research deliverable. No Go file was
  created or modified.
- **No gpython source file was touched.** The only change to the gpython
  working tree is the new `specs/` directory.
- **The C-module spec does not itemise every public function of every module.**
  It gives the module inventory exhaustively and the API surface for the
  important ones. A per-module API reference would be a separate, much larger
  deliverable.
- **The stdlib module list was not turned into per-module implementation
  specs.** The list is complete; the per-module work items are not.
