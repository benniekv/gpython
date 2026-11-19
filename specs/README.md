# CPython 3.15 Module System and gpython Upgrade - Spec Set

This directory holds the research specifications for two related projects:

1. **Re-implement CPython's module system in Go**, so that gpython can load
   Python modules the way CPython does.
2. **Upgrade gpython from Python 3.4 semantics to Python 3.15**, including the
   parser, the compiler, the runtime and the standard library.

The reference implementation is **CPython 3.15.2**, pinned by tag. Every source
citation in this tree uses the `v3.15.2` tag, never `main` (which is already at
3.16.0a2+dev).

## Reading order

Read in this order. Each file assumes the ones before it.

| # | File | What it covers |
|---|---|---|
| 0 | `00-hard-requirements.md` | **The four hard engineering rules. Read this first.** |
| 1 | `00-foundations/01-scope-and-baseline.md` | What gpython is today, what 3.15.2 is, how big the gap is, the three workstreams |
| 2 | `01-module-system/01-import-pipeline.md` | The full import pipeline, stage by stage, with the behaviours that break naive re-implementations |
| 3 | `01-module-system/02-module-object-model.md` | The module object model, the `PyModuleDef` structure, the 3.15 unified slot mechanism, the extension init protocol |
| 4 | `01-module-system/03-import-bytecodes.md` | The emitted bytecode for `import` and `from`, the `IMPORT_FROM` fallback and its exact error messages, the lazy import protocol |
| 5 | `02-language-upgrade/01-language-gap.md` | Every syntax, compiler and runtime change from 3.4 to 3.15, with PEPs, and the workstream breakdown |
| 6 | `02-language-upgrade/02-gpython-work-plan.md` | Which gpython files change for each feature, layer by layer, with a 16-step implementation order |
| 7 | `02-language-upgrade/03-web-research-language-semantics.md` | The normative language semantics from the PEPs and the Language Reference, with the web research that produced them |
| 8 | `02-language-upgrade/04-code-style-and-testing.md` | The code style, the five test styles, and where the test data comes from |
| 9 | `02-language-upgrade/05-code-gap-analysis.md` | **What gpython's code is missing**, measured by running it: the broken `import importlib`, the unordered dict, 127 missing methods, 22% coverage |
| 8 | `03-c-modules/01-c-module-inventory.md` | The complete inventory of CPython's C-coded modules, with the Go-portability assessment |

## The three workstreams

| Workstream | Directory | Size | Depends on |
|---|---|---|---|
| **A. Module system** | `01-module-system/` | Large | Nothing |
| **B. Language and stdlib** | `02-language-upgrade/` | Very large | A |
| **C. C-module inventory** | `03-c-modules/` | Medium (reference) | Nothing, but it sizes B's stdlib work |

**Workstream A is a prerequisite for B.** A 3.15 stdlib cannot be loaded by a
3.4-era import system. The modern stdlib uses `importlib.resources` as a
package, `annotationlib`, lazy imports (PEP 810), and module-level `__getattr__`
hooks.

**Workstream C sizes B's stdlib work.** The C inventory shows which stdlib
modules are pure Python (port directly), which need a bundled C library ported
(`decimal` needs libmpdec, `sqlite3` needs SQLite, `xml` needs expat, `ctypes`
needs libffi, `ssl` needs OpenSSL), and which have no Go equivalent at all.

## The critical findings

Two defects in gpython's code that the CPython-side research could not find,
because they only show up when you run the interpreter. Both are in
`02-language-upgrade/05-code-gap-analysis.md`.

1. **`import importlib` fails.** The `gpython/importlib` package exists and
   holds a frozen blob of CPython 3.4's `_bootstrap.py`, but **nothing
   imports the package**, so its `init()` never runs and the module is never
   registered. Every import falls through to the filesystem. The fix is one
   blank import in `stdlib/stdlib.go`, plus replacing the 3.4 blob.

2. **`dict` iteration order is random.** `py/dict.go` declares
   `type StringDict map[string]Object`, and Go maps randomise iteration
   order. Measured across five runs, gpython produced five different
   orderings of the same eight keys, and `keys()` and `items()` disagreed
   within a single run. CPython guarantees insertion order since 3.7.

## The headline numbers

All measured, not estimated.

| Measure | Value | How measured |
|---|---|---|
| Reference release | CPython 3.15.2, `PY_RELEASE_LEVEL_FINAL` | `Include/patchlevel.h` |
| CPython source files | 6141 | GitHub trees API, `truncated: false` |
| C modules in `Modules/*.c` | 101 | GitHub trees API |
| Always-static builtins | 27 | `Modules/Setup.bootstrap.in` |
| Buildable C extensions | 80 | `Modules/Setup.stdlib.in` |
| `Lib/` top-level `.py` modules | 150 | GitHub trees API |
| `Lib/` packages (excluding `Lib/test/`, `Lib/lib2to3/`) | 56 | GitHub trees API |
| CPython top-level importable names | 206 | 150 `.py` + 56 packages |
| gpython stdlib modules | 11 | `ls stdlib/` in the gpython checkout |
| stdlib modules missing from gpython | 202 | 206 minus the 4 matched by name |
| gpython internal packages | 13 | Source tree |
| Language versions spanned | 11 (3.4 → 3.15) | - |
| PEPs in the feature list | ~55 | Per-file tables |
| CPython 3.15.2 opcodes | 248 | `Include/opcode_ids.h` |
| gpython opcodes | 102 | `vm/opcodes.go` |
| Opcode names common to both | 53 | Set intersection |
| Modules removed between 3.4 and 3.15 | 30 | Verified absent from the 3.15.2 `Lib/` tree |
| gpython statement coverage | 22% | `go test -coverpkg` over 154,049 statements |
| Missing public methods on core types | 127 | `str` 35, `bytes` 41, `set` 16, `int` 11, `list` 8, `dict` 7, `float` 7, `tuple` 2 |
| Missing builtins | 17 | `stdlib/builtin/builtin.go` vs `dir(__builtins__)` |
| Missing AST node types | 22 | `ast/ast.go` vs the 3.5-3.15 node set |

## Source pin

```
https://raw.githubusercontent.com/python/cpython/v3.15.2/<path>
```

Fetched on 2026-11-18. The tree listing came from:

```
https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1
```

which returned 6141 entries with `truncated: false`, so the inventory in
`03-c-modules/` is complete rather than sampled.

## Conventions

Every spec file has four H2 sections, in this order:

1. **Overview** - what the topic covers and why.
2. **Sources** - the URLs and local artifacts that informed it.
3. **Spec** - the content.
4. **Verification** - how a future reader proves the section was met.

Files that state a measured number state how it was measured. Claims that could
not be verified against a fetched source are marked explicitly.

## The research log

`research/` holds the raw material:

| File | Contents |
|---|---|
| `00-agent-import-mechanism.md` | The full import-mechanism research report (98 KB) |
| `00-agent-c-module-inventory.md` | The full C-module research report (79 KB) |
| `00-agent-language-upgrade.md` | The full language-upgrade research report (63 KB) |
| `00-sources-and-caveats.md` | Every source consulted, every gap, and the follow-up work |

The agent reports are raw material, not spec. Where they disagree with the
spec files, the spec files win - they were written afterwards against the
source directly, and the discrepancies were corrected.
