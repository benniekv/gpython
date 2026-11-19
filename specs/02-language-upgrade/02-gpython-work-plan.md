# 02 - The gpython Language Upgrade Work Plan

## Overview

`01-language-gap.md` documents what changed in Python between 3.4 and 3.15.
It is organised by PEP and by CPython subsystem.

**This file documents the other half: which gpython files change, and what has
to happen in each.** It is the implementation plan, derived by reading
gpython's own source at commit `9b1d059`.

The distinction matters. A reader who knows the PEP list still cannot start
work, because "implement PEP 634 pattern matching" does not say whether to
touch `ast/ast.go`, `parser/grammar.y`, `compile/compile.go`, `vm/opcodes.go`,
`symtable/symtable.go`, or all five. For most PEPs it is all five, in a
specific order, because the layers are strictly stacked.

The one-line summary of where gpython stands:

| Layer | gpython's state | Target |
|---|---|---|
| `ast/ast.go` | 82 node types, Python 3.4 shape | +25 node types |
| `parser/lexer.go` | 70 token constants, Python 3.4 shape | +12 token kinds |
| `parser/grammar.y` | 1,987 lines, goyacc | extend, or replace with PEG |
| `symtable/symtable.go` | 828 lines, 3.4 scope rules | +PEP 695 type params, +cell-var rework |
| `compile/compile.go` | 1,933 lines, 3.4 codegen | rewrite for 3.15 semantics |
| `vm/opcodes.go` | **102 opcodes, Python 3.4 numbering** | ~200 opcodes |
| `vm/jumptable.go` | hand-written dispatch | +~100 new cases |

The VM is the deepest problem: gpython's opcode set is byte-for-byte CPython
3.4's, including `IMPORT_STAR = 84` and `PRINT_EXPR`.

## Sources

- `/home/bennie/Desktop/ansible/gpython` at `9b1d059`, read directly.
- `ast/ast.go`, `parser/lexer.go`, `parser/grammar.y`, `symtable/symtable.go`,
  `compile/compile.go`, `vm/opcodes.go`, `vm/jumptable.go`, `vm/vm.go`.
- `01-language-gap.md` in this directory, for the PEP list and the CPython
  side of each change.
- `01-module-system/03-import-bytecodes.md`, for the `IMPORT_NAME` and
  `IMPORT_FROM` opcode changes.

All gpython measurements below were taken by reading the files, not estimated.

## Spec

### The layer stack

gpython's Python pipeline is strictly layered. A change to the language
usually has to be made in every layer, in this order:

```
  source text
      |
  parser/lexer.go      tokenise
      |
  parser/grammar.y     parse to AST (goyacc)
      |
  ast/ast.go           AST node types
      |
  symtable/symtable.go scope analysis
      |
  compile/compile.go   AST to bytecode
      |
  vm/opcodes.go        opcode definitions
      |
  vm/jumptable.go      opcode dispatch
      |
  vm/vm.go             the evaluator loop
```

**The rule that follows:** adding a syntax feature without its AST node, its
symtable handling, its opcodes and its dispatch cases produces a compiler that
compiles but crashes at run time. gpython's existing test harness (`pytest/`,
`compile/compile_test.go`, `parser/grammar_test.go`) catches this, but only
if the new feature has a test file.

### Layer 1 - `ast/ast.go`

**Current state:** 82 node types. Present: `Arg`, `Arguments`, `Starred`,
`Nonlocal`, `Global`, `Yield`, `YieldFrom`, `Lambda`, `Comprehension`, `Call`.

**Absent** (verified by name):

| Node | PEP | Version | Notes |
|---|---|---|---|
| `JoinedStr` | 498 | 3.6 | f-string |
| `FormattedValue` | 498 | 3.6 | f-string |
| `NamedExpr` | 572 | 3.8 | the walrus operator |
| `Match` | 634 | 3.10 | the statement |
| `MatchValue` | 634 | 3.10 | pattern |
| `MatchSingleton` | 634 | 3.10 | pattern |
| `MatchSequence` | 634 | 3.10 | pattern |
| `MatchMapping` | 634 | 3.10 | pattern |
| `MatchClass` | 634 | 3.10 | pattern |
| `MatchStar` | 634 | 3.10 | pattern |
| `MatchAs` | 634 | 3.10 | pattern |
| `MatchOr` | 634 | 3.10 | pattern |
| `TypeAlias` | 695 | 3.12 | the `type` statement |
| `TypeVar` | 695 | 3.12 | type parameter |
| `TypeVarTuple` | 695 | 3.12 | type parameter |
| `ParamSpec` | 695 | 3.12 | type parameter |
| `AnnAssign` | 526 | 3.6 | variable annotation |
| `AsyncFunctionDef` | 492 | 3.5 | coroutine function |
| `AsyncFor` | 492 | 3.5 | async comprehension / loop |
| `AsyncWith` | 492 | 3.5 | async with |
| `Await` | 492 | 3.5 | await expression |

**Field changes to existing nodes:**

| Node | Change | PEP |
|---|---|---|
| `Import` | add `is_lazy` | 810 |
| `ImportFrom` | add `is_lazy` | 810 |
| `Arguments` | add `posonlyargs`, `kwonlyargs` | 570 |
| `Arg` | add `posonly`, `kwonly` flags | 570 |
| `FunctionDef` | add `type_params`, `returns` handling | 695, 526 |
| `ClassDef` | add `type_params` | 695 |
| `comprehension` | add unpack flag | 798 |

**The 3.15 `Import` node, verified from `Parser/Python.asdl`:**

```
          | Import(alias* names, int? is_lazy)
```

Note it is `is_lazy`, not `lazy`, and it is `int?` (nullable) rather than a
plain bool.

**Work estimate:** 25 new node types, 8 field changes. Each new node needs a
`String()` method, a `NewNode()` constructor, and registration in whatever
visitor interface `ast/` defines. This is mechanical but large.

### Layer 2 - `parser/lexer.go`

**Current state:** 70 token constants. Present: `AND`, `ASSERT`, `BREAK`,
`CLASS`, `CONTINUE`, `DEF`, `DEL`, `DEDENT`, `ELIF`, `ELSE`, `EXCEPT`,
`FINALLY`, `FOR`, `FROM`, `GLOBAL`, `IF`, `IMPORT`, `INDENT`, `LAMBDA`,
`NAME`, `NONE`, `NONLOCAL`, `NOT`, `OR`, `PASS`, `RAISE`, `RETURN`, `TRUE`,
`TRY`, `WHILE`, `WITH`, `YIELD`, and the operator constants.

**Absent:** there is no `ASYNC`, `AWAIT`, `MATCH`, `CASE`, `TYPE`, `LAZY`,
`FSTRING` or `TSTRING` token.

**What has to be added:**

| Token | PEP | Version | Kind |
|---|---|---|---|
| `ASYNC` | 492 | 3.5 | keyword |
| `AWAIT` | 492 | 3.5 | keyword |
| `MATCH` | 634 | 3.10 | soft keyword |
| `CASE` | 634 | 3.10 | soft keyword |
| `TYPE` | 695 | 3.12 | soft keyword |
| `LAZY` | 810 | 3.15 | soft keyword |
| `FSTRING_START` / `FSTRING_MIDDLE` / `FSTRING_END` | 498, 701 | 3.6, 3.12 | f-string tokens |
| `TSTRING_START` / `TSTRING_MIDDLE` / `TSTRING_END` | 750 | 3.14 | t-string tokens |

**The soft-keyword problem.** `match`, `case`, `type` and `lazy` are all
*soft* keywords: they are ordinary names unless they appear in a position
where the grammar expects them. CPython's PEG parser handles this with a
lookahead: `&"lazy"` matches only when the next token can legally follow.

gpython's lexer is a hand-written scanner, so it needs a different mechanism:
**the lexer must not decide.** The cleanest approach in a goyacc grammar is
to keep them as `NAME` tokens and let the grammar match the literal text. A
goyacc grammar can match a keyword-shaped literal in a `NAME` token position
only with lexer feedback, so the practical options are:

1. **Lexer-level context tracking.** The lexer tracks whether the previous
   significant token allows `match`/`case`/`type`/`lazy` to be a keyword, and
   emits the keyword token accordingly. This is what CPython's old LL(1)
   parser effectively did.
2. **Grammar-level text matching.** Restructure the grammar so the soft
   keyword is a `NAME` whose value is checked in a semantic action. This is
   awkward in goyacc but possible.

Option 1 is the smaller change and matches what gpython's lexer already does
for real keywords.

**The f-string problem is much harder.** PEP 701 (3.12) allows any expression
inside `{}`, including nested f-strings with the same quote character,
backslashes, and comments. That means the lexer must track brace nesting
depth per f-string and switch modes. The three-token scheme
(`FSTRING_START` / `FSTRING_MIDDLE` / `FSTRING_END`) is what CPython uses
precisely so the lexer can do this.

**Work estimate:** 6 keyword tokens, 6 f/t-string tokens, a soft-keyword
context tracker, and a brace-nesting f-string scanner.

### Layer 3 - `parser/grammar.y`

**Current state:** 1,987 lines of goyacc grammar. Verified absent from it:
`async`, `await`, `match` (as a keyword), `lazy`, `fstring`, `walrus`.
`case` and `type` appear, but only as ordinary identifier names, not as
keywords.

**This is the decision point.** The grammar must grow to accept every feature
in `01-language-gap.md`. The features that need the largest grammar changes:

| Feature | PEP | Grammar change |
|---|---|---|
| Pattern matching | 634 | Nine new nonterminals, plus a new statement form with a case list |
| Type parameter syntax | 695 | Type parameters on `def`, `class` and the `type` statement |
| f-string formalisation | 701 | Any expression inside `{}`, nested quotes, backslashes |
| `async`/`await` | 492 | New keywords, new statement forms, new expression |
| General unpacking | 448 | Star and double-star in call, assignment, subscript and display contexts |
| Positional-only parameters | 570 | A `/` marker in the parameter list |
| t-strings | 750 | Parallel to f-strings but producing a different AST |
| Deferred annotations | 649 | Not a grammar change, but changes when annotations are evaluated |

**The parser-strategy decision.** The spec in `01-language-gap.md` presents
two options:

- **Extend the goyacc grammar.** Lower cost, keeps the existing toolchain
  (`go generate ./parser/`), keeps `parser/grammar_test.go` working. The cost
  is that PEP 701's f-string grammar and the soft keywords are harder.
- **Port CPython's PEG generator.** `Tools/peg_generator/` is a few thousand
  lines of Python. Porting it to Go is a project in itself, and the
  generator's output would replace `parser/y.go` entirely.

**Recommendation: extend the goyacc grammar.** The reason is the soft
keywords. A goyacc grammar has one-token lookahead, so a soft keyword must be
resolved by the lexer, which is option 1 above and works fine. PEG's
advantage here is marginal for gpython's needs, and the port cost is high.

The exception is **PEP 701**. If f-string formalisation proves intractable in
goyacc, a targeted lexer change (a dedicated f-string scanner that produces
a token stream of expressions) is the fallback, not a full PEG port.

**Work estimate:** the grammar roughly doubles in size. Every new grammar
rule needs a matching test in `parser/grammar_test.go`, which uses golden
files in `parser/testparser/`.

### Layer 4 - `symtable/symtable.go`

**Current state:** 828 lines. Has cell and free variable handling
(`Cell`, `Free`, `ScopeCell`, `ScopeFree`, `ChildFree`, `DefFree`,
`DropClassFree`, `allfree`). **No annotation handling** (0 mentions of
"annotation").

**What has to change:**

| Change | PEP | Why |
|---|---|---|
| Keyword-only and positional-only parameters | 570 | New scope flags on `Arg` |
| Type parameters create their own scope | 695 | `class C[T]` binds `T` in the class body only |
| Comprehension inlining removes the comprehension scope | 709 | A comprehension no longer has its own function scope |
| `__annotate__` function synthesis | 649 | The compiler must emit an annotation function, which needs a scope |
| Cell variables for `nonlocal` in comprehensions | 709, 634 | Pattern captures inside a comprehension bind in the enclosing scope |

**The comprehension-scope change (PEP 709) is the subtle one.** Before 3.12 a
comprehension compiles to a nested function, so it has its own scope and
`locals()` inside it returns the comprehension's locals. After 3.12 it
compiles inline and does not. gpython's `symtable/` currently creates a scope
for comprehensions; that code has to go away, and the closure handling that
depends on it has to be replaced.

**Work estimate:** moderate. The scope machinery is sound; it needs new scope
kinds and one removal.

### Layer 5 - `compile/compile.go`

**Current state:** 1,933 lines. Handles annotations (8 mentions of
`Annotation`) and comprehensions (27 mentions, 12 of them the exact word
`Comprehension`), but has **zero** mentions of `KwOnly`, `PositionalOnly`,
`Async`, `Match`, `NamedExpr` or `fstring`.

**What has to change:**

| Change | PEP | Compiler impact |
|---|---|---|
| f-string codegen | 498, 701 | New `FORMAT_VALUE` and `BUILD_STRING` emission |
| Async function and generator codegen | 492, 525 | New frame setup, `YIELD_FROM` semantics change |
| Pattern matching codegen | 634 | Nine node types to compile, plus guard evaluation |
| Type parameter codegen | 695 | Create the `TypeVar` objects, bind them in the scope |
| `__annotate__` emission | 649 | A new nested function per annotated definition |
| Comprehension inlining | 709 | Remove the nested-function emission, emit inline code |
| Walrus codegen | 572 | `NamedExpr` needs a store to a cell or local |
| Keyword-only and positional-only parameters | 570 | Different argument-passing order in the call protocol |
| `lazy import` codegen | 810 | The `IMPORT_NAME` opcode argument gains a mode (see `01-module-system/03-import-bytecodes.md`) |

**The f-string codegen is the trickiest.** `FORMAT_VALUE` takes a conversion
flag (none, `!r`, `!s`, `!a`) and a format spec, and `BUILD_STRING` joins the
pieces. The compiler must also decide, at compile time, which parts of the
f-string are literal (goes in `co_consts`) and which need formatting.

**The comprehension inlining change (PEP 709) is the widest.** It changes the
bytecode shape of every comprehension in the language. It also removes the
`<listcomp>` frame from tracebacks, which changes observable behaviour that
tests will notice.

**Work estimate:** this is the largest single-file change in the upgrade.
Roughly a doubling of `compile/compile.go`.

### Layer 6 - `vm/opcodes.go` and `vm/jumptable.go`

**This is the deepest problem, and it is not optional.**

**Current state:** gpython's `vm/opcodes.go` defines **102 opcodes** with
CPython 3.4's exact numeric values. Verified markers: `IMPORT_STAR OpCode = 84`,
`PRINT_EXPR OpCode = 70`, `HAVE_ARGUMENT OpCode = 90`. The highest opcode
number is 148.

**This matters for a specific reason: `.pyc` compatibility.** gpython's
bytecode is not CPython's, but the numeric values being 3.4's means the
opcode *names* match 3.4. Any test data, any golden file, and any
`dis` output is 3.4-shaped.

**Absent opcodes that 3.5 to 3.15 require.** Verified absent:

| Opcode | PEP | Version | Needed for |
|---|---|---|---|
| `FORMAT_VALUE` | 498 | 3.6 | f-strings |
| `BUILD_STRING` | 498 | 3.6 | f-strings |
| `CALL_FUNCTION_EX` | 448 | 3.5 | `*args`, `**kwargs` calls |
| `CALL_KW` / `KW_NAMES` | 448 | 3.5 | keyword arguments at call sites |
| `LIST_EXTEND` | 448 | 3.5 | `[*a, *b]` |
| `DICT_MERGE` / `DICT_UPDATE` | 448 | 3.5 | `{**a, **b}` |
| `MAKE_FUNCTION` flags | 570 | 3.8 | posonly/kwonly |
| `LOAD_ASSERTION_ERROR` | - | 3.9 | `assert` |
| `LIST_TO_TUPLE` | - | 3.9 | `*a` unpacking |
| `IS_OP` | - | 3.9 | `is not` |
| `CONTAINS_OP` | - | 3.9 | `not in` |
| `JUMP_IF_NOT_EXC_MATCH` | 654 | 3.11 | `except*` |
| `CHECK_EXC_MATCH` | 654 | 3.11 | `except*` |
| `PUSH_EXC_INFO` | 654 | 3.11 | `except*` |
| `COPY` / `SWAP` / `CLEANUP_THROW` | 654 | 3.11 | `except*` |
| `MAKE_CELL` / `COPY_FREE_VARS` | - | 3.11 | cell variables, PEP 709 |
| `RESUME` | - | 3.11 | exception handling |
| `RETURN_CONST` | - | 3.12 | constant returns |
| `NOT_TAKEN` | - | 3.12 | branch prediction |
| `LOAD_BUILD_CLASS` (3.12 semantics) | 695 | 3.12 | PEP 695 class creation |
| `CALL_INTRINSIC_1` | - | 3.13 | optimised intrinsics |
| `FORMAT_SIMPLE` / `FORMAT_WITH_SPEC` | - | 3.13 | f-string optimisation |
| `SET_FUNCTION_ATTRIBUTE` | 649 | 3.14 | `__annotate__` |
| `END_FOR` | - | 3.14 | loop exit |
| `LOAD_FAST_LOAD_FAST` | - | 3.14 | superinstruction |
| `LOAD_COMMON_CONSTANT` | - | 3.15 | shared constants |
| `BINARY_OP` | - | 3.11 | the unified binary operator |

**The `BINARY_OP` change is the one that ripples furthest.** In 3.11 CPython
collapsed `BINARY_ADD`, `BINARY_SUBTRACT`, `BINARY_MULTIPLY`, `BINARY_TRUE_DIVIDE`,
`BINARY_FLOOR_DIVIDE`, `BINARY_MODULO`, `BINARY_POWER`, `BINARY_LSHIFT`,
`BINARY_RSHIFT`, `BINARY_AND`, `BINARY_XOR`, `BINARY_OR` and their inplace
variants into a single `BINARY_OP` with an argument selecting the operation.
gpython currently has 13 separate `BINARY_*` opcodes plus 6 `INPLACE_*` ones.

**The choice:** keep gpython's expanded opcode set, or collapse it to match
3.15. Keeping the expanded set is fine for a Go implementation with its own
bytecode, and it avoids rewriting `vm/jumptable.go` for the collapse. But it
means gpython's opcode set diverges further from CPython's, which matters for
any `.pyc` compatibility goal.

**Recommendation:** gpython already has its own bytecode format. Keep the
expanded `BINARY_*` set. Add the opcodes that new features require
(`FORMAT_VALUE`, `BUILD_STRING`, the `except*` set, `MAKE_CELL`,
`COPY_FREE_VARS`, `RESUME`, `CALL_KW`, `KW_NAMES`, `CALL_FUNCTION_EX`,
`LIST_EXTEND`, `DICT_MERGE`) and leave the rest. Document the divergence so
nobody assumes gpython bytecode is CPython bytecode.

**Work estimate:** 30 new opcodes, `vm/jumptable.go` grows by roughly the same
number of cases, and `vm/vm.go` (currently 46 lines, dispatching into
`jumptable.go`) needs the new stack-manipulation ops.

### Layer 7 - `py/`

`py/` holds the runtime object model: `py/object.go`, `py/int.go`,
`py/str.go`, `py/list.go`, `py/dict.go`, `py/exception.go`, `py/generator.go`,
`py/import.go`, `py/module.go`.

**What has to change:**

| Change | PEP | File |
|---|---|---|
| Exception groups | 654 | `py/exception.go`, new `py/exceptiongroup.go` |
| `frozendict` | 814 | new `py/frozendict.go` |
| `sentinel` | 661 | new `py/sentinel.go` |
| `types.GenericAlias`, `types.UnionType` | 585, 604 | `py/` |
| Deferred annotations and `__annotate__` | 649 | `py/object.go`, `py/module.go` |
| `locals()` defined semantics | 667 | `py/frame.go` |
| Coroutines | 492 | `py/generator.go`, new `py/coroutine.go` |
| Module `__getattr__` / `__dir__` | 562 | `py/module.go` |
| `__static_attributes__`, `__firstlineno__` | 699 | `py/object.go` |

**Work estimate:** 4 new files, 6 modified. The exception-group work is the
largest: `except*` needs a new control-flow shape in the VM, not just a new
type.

### The recommended implementation order

This order matters. Each step leaves the tree working.

| Step | Work | Why here |
|---|---|---|
| 0 | **Add the 3.15 opcodes and their dispatch** without changing any behaviour | Every later step needs the opcode infrastructure |
| 1 | **PEP 448 general unpacking** (`*a`, `**d` in calls, assignments, displays) | Needs `CALL_FUNCTION_EX`, `CALL_KW`, `KW_NAMES`, `LIST_EXTEND`, `DICT_MERGE`. Unlocks f-strings. |
| 2 | **PEP 515 numeric underscores** | Trivial lexer change; do it early to get the lexer workflow going |
| 3 | **PEP 498 f-strings** (basic form, no PEP 701 nesting) | Needs `FORMAT_VALUE` + `BUILD_STRING` + the AST nodes. Unlocks the f-string lexer work. |
| 4 | **PEP 526 variable annotations** + **PEP 570 posonly/kwonly** | Small, and they exercise the AST field-change workflow |
| 5 | **PEP 572 walrus** | Small AST + compiler change, needs cell-variable support |
| 6 | **PEP 709 comprehension inlining** | Big, but it removes work that the later features would otherwise inherit wrongly |
| 7 | **PEP 654 exception groups** (`except*`) | The biggest VM change. Do it before pattern matching, which can raise them. |
| 8 | **PEP 634 pattern matching** | The biggest grammar change. Do it after the VM is stable enough to handle its code shape. |
| 9 | **PEP 492 async/await** | The biggest runtime change (coroutines, an event loop, `await` in the VM) |
| 10 | **PEP 695 type parameters + the `type` statement** | Depends on scopes and annotations being right |
| 11 | **PEP 701 f-string formalisation** | Depends on the f-string lexer infrastructure from step 3 |
| 12 | **PEP 649 deferred annotations** | Depends on annotations and `type_params` being right |
| 13 | **PEP 750 t-strings** | Parallel to f-strings, so it is cheap once step 3 is done |
| 14 | **PEP 810 lazy imports** | Depends on the module-system work in `01-module-system/` |
| 15 | **PEP 686 UTF-8 default encoding** | A runtime-wide change; do it late so it does not obscure earlier failures |

**Steps 3, 4, 5, 6, 8, 10, 11 and 13 are the ones that move the needle.**
Steps 1, 2, 9, 14 and 15 are smaller or have fewer dependents.

**Note on step 9.** Async/await is the single largest runtime change and it
gates the least. Many modern Python programs do not use it. If the goal is
"run most real-world Python", steps 1 through 8 and 10 through 13 deliver more
than step 9 does. Async can come last.

### The test harness implications

gpython has two test styles, and a feature needs both:

1. **Python source files** under `py/tests/` and `stdlib/*/test_*.py`, run
   through the `pytest/` harness against golden output.
2. **Go unit tests**, and golden files in `parser/testparser/`,
   `compile/` and `symtable/`.

**Every new feature needs all three:**

| Feature | AST test | Grammar test | Compile test | VM test | Python test |
|---|---|---|---|---|---|
| f-strings | yes | yes | yes | yes | yes |
| pattern matching | yes | yes | yes | yes | yes |
| async | yes | yes | yes | yes | yes |
| PEP 695 types | yes | yes | yes | yes | yes |

The golden-file tests are the ones that catch a wrong implementation early.
`compile/make_compile_test.py` and `symtable/make_symtable_test.py` generate
the expected output from CPython, so **the reference output must come from
CPython 3.15**, not from gpython's current output. Regenerating golden files
from gpython's own output would bake in the 3.4 behaviour.

**This is the single most important process rule in this document.** The
golden files are the test oracle, and the oracle must be CPython 3.15.

### What is explicitly out of scope

| Item | Why |
|---|---|
| The PEG parser port | Recommended against, see Layer 3 |
| The tier-2 tail-call interpreter | Go's goroutine stacks already handle deep recursion |
| The free-threaded build | gpython is already goroutine-based; there is no GIL to remove |
| mimalloc | Go has its own allocator |
| The experimental JIT (PEP 744) | Optional in CPython too |
| `PyConfig` C API (PEP 741) | A C API; gpython has no C API |
| The Stable ABI for free-threaded builds | A C API concern |

## Verification

**1. Confirm the AST gap.**

```bash
cd /home/bennie/Desktop/ansible/gpython
for n in Match NamedExpr JoinedStr FormattedValue TypeAlias TypeVar \
         AnnAssign AsyncFunctionDef Await; do
  printf '%-20s %s\n' "$n" "$(grep -cE "^type $n " ast/ast.go)"
done
```

Expect `0` for every one of them, at the 3.4 baseline.

**2. Confirm the lexer gap.**

```bash
grep -cE '\b(ASYNC|AWAIT|MATCH|CASE|TYPE|LAZY|FSTRING|TSTRING)\b' parser/lexer.go
```

Expect `0`.

**3. Confirm the opcode set is 3.4's.**

```bash
grep -cE '^\t[A-Z][A-Z_0-9]*\s+OpCode\s*=\s*[0-9]+' vm/opcodes.go
grep -E 'IMPORT_STAR|PRINT_EXPR' vm/opcodes.go
```

Expect 102 opcodes, and expect `IMPORT_STAR OpCode = 84` and
`PRINT_EXPR OpCode = 70`. These are CPython 3.4's numbers.

**4. Confirm the 3.x opcodes are absent.**

```bash
for o in FORMAT_VALUE BUILD_STRING CALL_FUNCTION_EX CALL_KW KW_NAMES \
         LIST_EXTEND DICT_MERGE MAKE_CELL COPY_FREE_VARS RESUME \
         CHECK_EXC_MATCH JUMP_IF_NOT_EXC_MATCH SET_FUNCTION_ATTRIBUTE; do
  grep -q "$o" vm/opcodes.go || echo "absent: $o"
done
```

Expect all twelve reported as absent.

**5. Confirm the compiler gap.**

```bash
grep -cE 'KwOnly|PositionalOnly|Async|Match|NamedExpr|fstring|FString' compile/compile.go
```

Expect `0`.

**6. Confirm the symtable gap.**

```bash
grep -ci 'annotation' symtable/symtable.go
grep -cE 'TypeParam|type_param' symtable/symtable.go
```

Expect `0` for both.

**7. Confirm the grammar gap.**

```bash
grep -cE '\basync\b|\bawait\b|\bmatch\b|\blazy\b|fstring' parser/grammar.y
```

Expect `0`.

**8. After implementing a feature, confirm the golden files came from
CPython 3.15.** This is the process check that matters most:

```bash
# the golden files must not be regenerable from gpython's own output
# spot-check one: compile a 3.15-only construct and compare
cd /home/bennie/Desktop/ansible/gpython
cat > /tmp/t315.py <<'EOF'
type Point = tuple[float, float]
def f[T: int](x: T) -> T: return x
EOF
```

If the golden file for this input was produced by CPython 3.15, it will
contain the PEP 695 opcodes. If it was produced by gpython 3.4, the input
would not have compiled at all.
