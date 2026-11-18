# 01 - Scope and Baseline (gpython → Python 3.15)

## Overview

This spec set defines the work to upgrade **gpython**, a Python 3.4-era interpreter
written in Go, to Python 3.15 semantics, and to re-implement CPython's module system
in Go.

Two independent bodies of work live in this tree:

1. **The language and library upgrade** (`02-language-upgrade/`). Every syntax
   feature, every stdlib module and every behaviour change between Python 3.4 and
   Python 3.15, with the PEP that introduced it.
2. **The module system re-implementation** (`01-module-system/`). The import
   machinery, the module object model, and the full inventory of CPython's
   C-implemented modules, specified at the level of detail needed to write a Go
   equivalent.

This file establishes the baseline: what gpython is today, what Python 3.15
requires, and how the two are measured against each other.

## Sources

- `https://github.com/python/cpython/tree/v3.15.2` - the CPython 3.15.2 source tree.
  This is the authoritative reference for the entire spec set. Fetched via the
  GitHub tree API on 2026-11-18: 6141 entries, `truncated: false`.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/patchlevel.h` -
  the version constants.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.bootstrap.in` -
  the always-static builtin module list.
- `https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.stdlib.in` -
  the full C extension build list.
- `https://api.github.com/repos/python/cpython/tags` - the tag list, used to pin
  the reference release.
- The gpython checkout at `/home/bennie/Desktop/ansible/gpython`, at commit
  `8c979bc` (branch `main`).
- Live `sys.builtin_module_names` from CPython 3.14.9, used only as a cross-check
  of the 3.15 source lists. Where 3.14 and 3.15 differ, the 3.15.2 source wins.

## Spec

### The reference release

Python 3.15 is **final**. The reference for this spec set is **CPython 3.15.2**.

Verified from `Include/patchlevel.h` at tag `v3.15.2`:

```c
#define PY_MAJOR_VERSION        3
#define PY_MINOR_VERSION        15
#define PY_MICRO_VERSION        2
#define PY_RELEASE_LEVEL        PY_RELEASE_LEVEL_FINAL
#define PY_RELEASE_SERIAL       0
#define PY_VERSION              "3.15.2"
```

`PY_RELEASE_LEVEL_FINAL` is `0xF`. The release is not an alpha, beta or RC.

**The `main` branch is ahead of the release.** `main` reports
`PY_VERSION "3.16.0a2+dev"` with `PY_RELEASE_LEVEL_ALPHA`. Every source citation
in this spec set therefore pins the `v3.15.2` tag. Do not cite `main` for
3.15 behaviour.

Tag list evidence for the 3.15 series (from the GitHub tags API):
`v3.15.0a1` … `v3.15.0a8`, `v3.15.0b1` … `v3.15.0b4`, `v3.15.0rc1` … `v3.15.0rc3`,
`v3.15.0`, `v3.15.1`, `v3.15.2`.

### The gpython baseline

gpython at `8c979bc` implements **Python 3.4** semantics. Its own `README.md`
states it "parses all the code in the Python 3.4 distribution".

Measured package layout:

| Package | Role | Internal imports (non-test) |
|---|---|---|
| `py/` | Runtime object model: types, values, exceptions, frames, generators | none (base) |
| `ast/` | AST node types, walker, dumper | `py` |
| `parser/` | Hand-written lexer plus goyacc grammar (`grammar.y`) | `py` |
| `symtable/` | Symbol table construction and scope analysis | `ast`, `parser`, `py` |
| `vm/` | The virtual machine, opcodes, evaluator | `py` |
| `compile/` | AST to bytecode compiler, instruction set | `ast`, `parser`, `symtable`, `py`, `vm` |
| `stdlib/` | Python standard modules | `compile`, `py` |
| `repl/` | Terminal REPL (`repl/cli`) and web REPL (`repl/web`) | `py`, `stdlib`, `vm` |
| `pytest/` | Test harness running Python files against golden output | `compile`, `py`, `stdlib` |
| `importlib/` | Import machinery | `py` |

`py` is the **base** package. It imports no other internal package. `ast` and
`parser` both import `py` (for `py.String` and friends), not the reverse.

### The gpython stdlib today

gpython ships **11** stdlib modules. Measured from `stdlib/` at `8c979bc`:

| Module | C counterpart | gpython status |
|---|---|---|
| `array` | `Modules/arraymodule.c` | present |
| `binascii` | `Modules/binascii.c` | present |
| `builtin` | `Python/bltinmodule.c` | present |
| `glob` | pure Python (`Lib/glob.py`) | present |
| `marshal` | `Python/marshal.c` | present |
| `math` | `Modules/mathmodule.c` | present |
| `os` | `Modules/posixmodule.c` | present |
| `string` | `Modules/stringmodule.c` (removed in 3.12) | present |
| `sys` | `Python/sysmodule.c` | present |
| `tempfile` | pure Python (`Lib/tempfile.py`) | present |
| `time` | `Modules/timemodule.c` | present |

Python 3.15 has **151** top-level `.py` modules in `Lib/` and **146** packages
(measured from the 3.15.2 tree, excluding `Lib/test/`). The gap is therefore
roughly 140 stdlib modules.

### The size of the gap

Three independent measures of "how far behind is gpython":

| Measure | gpython | Python 3.15 | Ratio |
|---|---|---|---|
| Stdlib modules | 11 | ~297 (151 `.py` + 146 packages) | ~27× |
| C extension modules | 0 (all are Go re-implementations) | 107 (27 always-static + 80 buildable) | n/a |
| Language target | 3.4 | 3.15 | 11 minor versions |

The "11 minor versions" figure is the misleading one. Python's minor releases are
not uniformly sized. The gap that matters is concentrated in 3.12, 3.13, 3.14 and
3.15, which between them changed the parser (PEG), the typing system (PEP 695),
the annotation evaluation model (PEP 649/749), the f-string grammar (PEP 701), the
REPL (PEP 701/642), the free-threading model (PEP 703) and the JIT (PEP 744).

### The three workstreams

The upgrade splits into three workstreams that can proceed in parallel. This is
the organising structure of the whole spec set.

| Workstream | Spec directory | Deliverable | Size |
|---|---|---|---|
| **A. Language and stdlib** | `02-language-upgrade/` | Parser for the 3.15 grammar, compiler for the 3.15 semantics, the missing stdlib modules | Large |
| **B. Module system** | `01-module-system/` | Go re-implementation of CPython's import machinery, module object model and finder/loader protocols | Large |
| **C. C-module inventory** | `03-c-modules/` | The complete inventory of CPython's C modules, with the Go-portability assessment for each | Medium (mostly reference) |

**Workstream B is a prerequisite for Workstream A.** A Python 3.15 stdlib cannot be
loaded by a 3.4-era import system. The modern stdlib uses `importlib.resources` as
a package, `annotationlib`, lazy imports, and `__getattr__` module hooks. A
3.4-era importer breaks on all four.

**Workstream C constrains Workstream A's stdlib work.** The C inventory tells you
which stdlib modules are "easy" (pure Python, port directly) and which need a C
library port or a Go-native substitute. `decimal` needs libmpdec. `sqlite3` needs
SQLite. `xml` needs expat. `ctypes` needs libffi. `ssl` needs OpenSSL.

### The reference pin

Every source citation in this spec set uses one of:

```
https://raw.githubusercontent.com/python/cpython/v3.15.2/<path>
https://github.com/python/cpython/blob/v3.15.2/<path>
```

When a path is cited, it is a path that was fetched and read. When a claim is
marked **unverified**, it was not confirmed against the 3.15.2 source.

### The 3.15 vs main distinction

CPython `main` at the time of writing is 3.16.0a2+dev. The 3.15 series has
maintenance releases after 3.15.2 may exist. This spec set targets 3.15.2 because
it is a tagged, final, immutable release. A later patch release would change only
bug fixes, not the module inventory or the language semantics documented here.

## Verification

A future implementer proves this baseline is still accurate with these checks.

**1. Confirm the reference release.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Include/patchlevel.h \
  | grep -E "PY_(MAJOR|MINOR|MICRO)_VERSION|PY_VERSION "
```

Expect `PY_VERSION "3.15.2"` and `PY_RELEASE_LEVEL PY_RELEASE_LEVEL_FINAL`.

**2. Confirm the gpython stdlib inventory is still 11 modules.**

```bash
cd /home/bennie/Desktop/ansible/gpython
ls stdlib/ | grep -v '^stdlib.go$' | grep -v '\.go$' | sort
```

Expect exactly: `array`, `binascii`, `builtin`, `glob`, `marshal`, `math`, `os`,
`string`, `sys`, `tempfile`, `time`.

**3. Confirm the gpython dependency graph has not changed.**

```bash
cd /home/bennie/Desktop/ansible/gpython
for f in $(find . -name "*.go" -not -name "*_test.go" -not -path "./pytest/*"); do
  grep -o "go-python/gpython/[a-z]*" "$f" 2>/dev/null
done | sort | uniq -c | sort -rn
```

Expect `py` to be the most-imported package (30 references) and `py` itself to
import no internal package.

**4. Confirm the C module counts.**

```bash
curl -s "https://api.github.com/repos/python/cpython/git/trees/v3.15.2?recursive=1" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
p=[t['path'] for t in d['tree'] if t['type']=='blob']
print('Modules/ root .c:', len([x for x in p if x.startswith('Modules/') and x.count('/')==1 and x.endswith('.c')]))
print('Lib/ top .py    :', len([x for x in p if x.startswith('Lib/') and x.count('/')==1 and x.endswith('.py')]))
"
```

Expect `Modules/ root .c: 101` and `Lib/ top .py: 151`.

**5. Confirm the always-static builtin list.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Modules/Setup.bootstrap.in \
  | grep -vE '^\s*#|^\s*$|^\*' | awk '{print $1}' | sort
```

Expect 27 module names, each of which must be present in
`sys.builtin_module_names` on a real build.
