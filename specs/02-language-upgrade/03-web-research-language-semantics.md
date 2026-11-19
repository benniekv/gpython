# 03 - Web Research: Language Semantics an Implementer Needs

## Overview

`01-language-gap.md` lists the features. `02-gpython-work-plan.md` says which
gpython files change. Neither is enough on its own, because both were written
from the CPython source tree rather than from the **normative specifications**.

The specifications are the PEPs and the Language Reference. They contain
requirements that the source does not state, because the source implements
them. This file records those requirements, with the web research that
produced them.

Reading the PEPs changed three things in this spec set:

1. **Five opcode names in `02-gpython-work-plan.md` were wrong.**
   `RETURN_CONST`, `FORMAT_VALUE`, `KW_NAMES`, `LOAD_ASSERTION_ERROR` and
   `JUMP_IF_NOT_EXC_MATCH` **do not exist in CPython 3.15**. The real names
   are `FORMAT_SIMPLE` / `FORMAT_WITH_SPEC`, `CALL_KW`, and the exception
   group uses `CHECK_EG_MATCH`. A port that added the five I named would
   have added five opcodes CPython does not have.
2. **The scope rules for PEP 695 are far more specific than the source
   suggests.** There is a distinct "annotation scope", not a function scope,
   with its own disallowance list.
3. **PEP 701 specifies a lower bound on nesting depth** (5 levels for
   f-strings, 2 for format specs). That is a conformance requirement, not an
   implementation detail.

This file also records the normative requirements for PEP 634 (pattern
matching), PEP 654 (exception groups), PEP 709 (comprehension inlining) and
PEP 649/749 (deferred annotations), because each has rules that a
straightforward implementation gets wrong.

## Sources

All fetched on 2026-11-18.

| URL | Used for |
|---|---|
| `https://peps.python.org/pep-0701/` | PEP 701: the f-string grammar, the three tokens, the nesting lower bound, the untokenize requirement, the rejected alternatives |
| `https://peps.python.org/pep-0634/` | PEP 634: the full `match` grammar, the pattern semantics, the sequence-protocol definition, `__match_args__` |
| `https://peps.python.org/pep-0695/` | PEP 695: the type parameter syntax, the annotation scope rules, the `def695` scope, the lazy evaluation model |
| `https://peps.python.org/pep-0654/` | PEP 654: `ExceptionGroup` and `except*` semantics, the recursive matching rule, the forbidden combinations |
| `https://peps.python.org/pep-0749/` | PEP 749: `annotationlib`, the `__annotate__` signature, the `STRING` format rename, the stringifier's supported expressions |
| `https://peps.python.org/pep-0709/` | PEP 709: the before/after bytecode, the visible behaviour changes, the `LOAD_FAST_AND_CLEAR` requirement |
| `https://docs.python.org/3/reference/compound_stmts.html` | The 3.15.2 Language Reference: the authoritative `try`/`match`/`funcdef`/`classdef` grammar, and the type parameter list section |
| `https://docs.python.org/3/whatsnew/3.15.html` | The 3.15 release notes, the PEP 810 restrictions, `frozendict`, `sentinel` |
| `https://github.com/python/cpython/blob/main/InternalDocs/inlined_comprehensions.md` | The CPython internal design note for PEP 709: the symbol table rules, the `InlinedComprehensionBlock`, the codegen entry/exit functions |
| `https://github.com/python/cpython/pull/101441` | The PEP 709 implementation PR: the `LOAD_FAST_AND_CLEAR` rationale, the cell-in-`co_varnames` handling |
| `https://github.com/python/cpython/issues/97933` | The original inlining proposal: the `locals()` and traceback behaviour changes |
| `https://jellezijlstra.github.io/pep695.html` | The PEP 695 implementer's notes: the `&"type"` lookahead optimisation, the rule-ordering constraint |
| `https://peps.python.org/pep-0492/` | PEP 492: `async`/`await` semantics |

## Spec

### The correction: the 3.15 opcode set

This is the most important correction in this spec set, so it comes first.

**CPython 3.15.2 has 248 opcodes** (`Include/opcode_ids.h`). gpython has 102.

| | Count |
|---|---|
| gpython's opcodes | 102 |
| CPython 3.15.2's opcodes | 248 |
| The name exists in both | 53 |
| In gpython but **not** in 3.15 | 49 |
| In 3.15 but **not** in gpython | 195 |

**The 49 gpython opcodes that CPython 3.15 no longer has.** These are the
3.4-era opcodes that later versions replaced or removed:

| Group | Opcodes |
|---|---|
| Binary operators (replaced by `BINARY_OP` in 3.11) | `BINARY_ADD`, `BINARY_AND`, `BINARY_FLOOR_DIVIDE`, `BINARY_LSHIFT`, `BINARY_MODULO`, `BINARY_MULTIPLY`, `BINARY_OR`, `BINARY_POWER`, `BINARY_RSHIFT`, `BINARY_SUBSCR`, `BINARY_SUBTRACT`, `BINARY_TRUE_DIVIDE`, `BINARY_XOR` |
| Inplace operators (also replaced) | `INPLACE_ADD`, `INPLACE_AND`, `INPLACE_FLOOR_DIVIDE`, `INPLACE_LSHIFT`, `INPLACE_MODULO`, `INPLACE_MULTIPLY`, `INPLACE_OR`, `INPLACE_POWER`, `INPLACE_RSHIFT`, `INPLACE_SUBTRACT`, `INPLACE_TRUE_DIVIDE`, `INPLACE_XOR` |
| Calls (replaced by `CALL`, `CALL_KW`, `CALL_FUNCTION_EX`) | `CALL_FUNCTION`, `CALL_FUNCTION_KW`, `CALL_FUNCTION_VAR`, `CALL_FUNCTION_VAR_KW` |
| Stack manipulation (removed in 3.11) | `DUP_TOP`, `DUP_TOP_TWO`, `ROT_TWO`, `ROT_THREE` |
| Control flow (replaced by `JUMP_BACKWARD`, `POP_JUMP_IF_*`) | `JUMP_ABSOLUTE`, `JUMP_IF_FALSE_OR_POP`, `JUMP_IF_TRUE_OR_POP`, `CONTINUE_LOOP`, `BREAK_LOOP`, `SETUP_LOOP` |
| Exception handling (replaced by `PUSH_EXC_INFO`, `POP_EXCEPT`) | `SETUP_EXCEPT`, `END_FINALLY`, `WITH_CLEANUP` |
| Others | `IMPORT_STAR`, `PRINT_EXPR`, `STORE_MAP`, `LOAD_CLASSDEREF`, `MAKE_CLOSURE`, `UNARY_POSITIVE`, `YIELD_FROM` |

**The five names I got wrong in `02-gpython-work-plan.md`:**

| I wrote | The truth in 3.15 | Evidence |
|---|---|---|
| `RETURN_CONST` | **Does not exist.** 3.15 uses `RETURN_VALUE` only. | Absent from `Include/opcode_ids.h` and from `Lib/_opcode_metadata.py`. |
| `FORMAT_VALUE` | **Does not exist.** 3.15 has `FORMAT_SIMPLE` and `FORMAT_WITH_SPEC`. | Same. |
| `KW_NAMES` | **Does not exist.** 3.15 has `CALL_KW`, which takes the names tuple as its argument. | Same. |
| `LOAD_ASSERTION_ERROR` | **Does not exist.** 3.15 uses `RAISE_VARARGS`. | Same. |
| `JUMP_IF_NOT_EXC_MATCH` | **Does not exist.** The `except*` machinery uses `CHECK_EG_MATCH`, `PUSH_EXC_INFO`, `POP_EXCEPT`, `CLEANUP_THROW`, `RERAISE`, `WITH_EXCEPT_START`. | Same. |

**The `except*` opcode set, verified present in 3.15.2:**

```
CHECK_EG_MATCH        CHECK_EXC_MATCH        CLEANUP_THROW
PUSH_EXC_INFO         POP_EXCEPT             RERAISE
WITH_EXCEPT_START
```

**The full opcode families that a 3.15 implementation needs** (from
`Include/opcode_ids.h`), grouped by what they serve:

| Purpose | Opcodes |
|---|---|
| f-strings | `BUILD_STRING`, `FORMAT_SIMPLE`, `FORMAT_WITH_SPEC` |
| Calls | `CALL`, `CALL_FUNCTION_EX`, `CALL_KW`, `CALL_INTRINSIC_1`, `CALL_INTRINSIC_2`, plus the specialised `CALL_*` families |
| Cells and closures | `MAKE_CELL`, `COPY_FREE_VARS`, `LOAD_FAST_AND_CLEAR`, `LOAD_FAST_CHECK` |
| Exception groups | `CHECK_EG_MATCH`, `CHECK_EXC_MATCH`, `CLEANUP_THROW`, `PUSH_EXC_INFO`, `POP_EXCEPT`, `RERAISE`, `WITH_EXCEPT_START` |
| Exception machinery | `RESUME`, `COPY`, `SWAP`, `RAISE_VARARGS` |
| PEP 709 comprehensions | `LOAD_FAST_AND_CLEAR`, `END_FOR` |
| Unified binary ops | `BINARY_OP` |
| 3.13 to 3.15 codegen | `SET_FUNCTION_ATTRIBUTE`, `LOAD_COMMON_CONSTANT`, `LOAD_FAST_LOAD_FAST`, `TO_BOOL`, `CONVERT_VALUE` |
| Miscellaneous | `GET_LEN`, `LOAD_SPECIAL`, `LOAD_SUPER_ATTR`, `STORE_SLICE`, `NOT_TAKEN` |

**The 195-opcode difference is mostly the specialised `CALL_*` families.**
CPython 3.15 has 248 opcodes because the specialising interpreter has a
separate opcode per call shape: `CALL_PY_EXACT_ARGS`, `CALL_PY_GENERAL`,
`CALL_BUILTIN_FAST`, `CALL_METHOD_DESCRIPTOR_FAST`, `CALL_STR_1`,
`CALL_TUPLE_1`, and so on.

**Recommendation for gpython: do not chase the specialised families.** gpython
does not need a specialising interpreter. It needs one `CALL`, one `CALL_KW`
and one `CALL_FUNCTION_EX`. The opcode *count* is not the target; the
*semantics* are.

**So the corrected opcode work for gpython is 12 opcodes, not 30:**

| Opcode | Needed for |
|---|---|
| `BUILD_STRING`, `FORMAT_SIMPLE`, `FORMAT_WITH_SPEC` | f-strings |
| `CALL_FUNCTION_EX`, `CALL_KW` | PEP 448 unpacking |
| `LIST_EXTEND`, `DICT_MERGE` | PEP 448 unpacking in displays |
| `MAKE_CELL`, `COPY_FREE_VARS` | closures, PEP 709 |
| `LOAD_FAST_AND_CLEAR`, `END_FOR` | PEP 709 comprehension inlining |
| `RESUME`, `COPY`, `SWAP` | the 3.11 exception-handling rework |
| `CHECK_EG_MATCH`, `PUSH_EXC_INFO`, `POP_EXCEPT`, `CLEANUP_THROW`, `RERAISE`, `WITH_EXCEPT_START` | PEP 654 exception groups |
| `BINARY_OP` | optional; gpython can keep its expanded `BINARY_*` set |

### PEP 701: the f-string grammar and its requirements

**The grammar, verbatim from PEP 701:**

```
fstring
    | FSTRING_START fstring_middle* FSTRING_END
fstring_middle
    | fstring_replacement_field
    | FSTRING_MIDDLE
fstring_replacement_field
    | '{' (yield_expr | star_expressions) "="? [ "!" NAME ] [ ':' fstring_format_spec* ] '}'
fstring_format_spec:
    | FSTRING_MIDDLE
    | fstring_replacement_field
```

**Five normative requirements:**

1. **Nesting lower bound: 5 levels.** "This PEP leaves up to the
   implementation the level of f-string nesting allowed ... but **specifies a
   lower bound of 5 levels of nesting**." A conforming implementation must
   accept `f"{f"{f"{f"{f"{1+1}"}"}"}"}"}"`.

2. **Format spec nesting lower bound: 2 levels.** `f"{'':*^{1:{1}}}"` must be
   valid. `f"{'':*^{1:{1:{1}}}}"` may be rejected.

3. **The lexer must "untokenize" for debug expressions.** The `=` debug
   specifier (3.8) preserves the whitespace around it:
   `f"{1+1=}"` produces `'1+1=2'`. A pure token-level untokenisation loses
   the spaces after `{` and around `=`. **The raw string contents of the
   expression part must be kept intact.**

4. **The `:` restriction still holds at the top level.** "You can place any
   valid Python expression inside an f-string expression, and everything after
   a `:` character at the top level will be identified as a format
   specification." So `f"{lambda x: x*2}"` is still a `SyntaxError`; it must
   be `f"{(lambda x: x*2)}"`. This was an explicit rejection in the PEP.

5. **The AST is unchanged.** "The new grammar will preserve the Abstract
   Syntax Tree (AST) of the current implementation." So `JoinedStr` and
   `FormattedValue` remain the node types, with the same shape as 3.6.

**Two more restrictions PEP 701 kept:**

- **Escaped braces (`\{`, `\}`) are not allowed**, only `{{` and `}}`. This was
  an explicit rejection.
- **The `tokenize` module must be updated** for the three new tokens. That
  matters for gpython because it has a `tokenize` module to write.

**What this means for gpython.** The `FSTRING_START`/`FSTRING_MIDDLE`/
`FSTRING_END` token scheme is not optional. A lexer that treats an f-string as
one `STRING` token and post-processes it - which is what CPython did before
3.12 - cannot satisfy requirement 3 without reimplementing the lexer anyway.
And requirement 4 means the lexer must recognise `:` at the top nesting level
as the format-spec separator, which requires tracking brace depth.

### PEP 634: pattern matching

**The full grammar, verbatim from PEP 634 Appendix A:**

```
match_stmt: "match" subject_expr ':' NEWLINE INDENT case_block+ DEDENT
subject_expr:
    | star_named_expression ',' [star_named_expressions]
    | named_expression
case_block: "case" patterns [guard] ':' block
guard: 'if' named_expression

patterns: open_sequence_pattern | pattern
pattern: as_pattern | or_pattern
as_pattern: or_pattern 'as' capture_pattern
or_pattern: '|'.closed_pattern+
closed_pattern:
    | literal_pattern
    | capture_pattern
    | wildcard_pattern
    | value_pattern
    | group_pattern
    | sequence_pattern
    | mapping_pattern
    | class_pattern

literal_pattern:
    | signed_number !('+' | '-')
    | signed_number '+' NUMBER
    | signed_number '-' NUMBER
    | strings
    | 'None'
    | 'True'
    | 'False'
signed_number: NUMBER | '-' NUMBER

capture_pattern: !"_" NAME !('.' | '(' | '=')

wildcard_pattern: "_"

value_pattern: attr !('.' | '(' | '=')
attr: name_or_attr '.' NAME
name_or_attr: attr | NAME

group_pattern: '(' pattern ')'

sequence_pattern:
  | '[' [maybe_sequence_pattern] ']'
  | '(' [open_sequence_pattern] ')'
open_sequence_pattern: maybe_star_pattern ',' [maybe_sequence_pattern]
maybe_sequence_pattern: ','.maybe_star_pattern+ ','?
maybe_star_pattern: star_pattern | pattern
star_pattern: '*' (capture_pattern | wildcard_pattern)

mapping_pattern: '{' [items_pattern] '}'
items_pattern: ','.key_value_pattern+ ','?
key_value_pattern:
    | (literal_pattern | value_pattern) ':' pattern
    | double_star_pattern
double_star_pattern: '**' capture_pattern

class_pattern:
    | name_or_attr '(' [pattern_arguments ','?] ')'
pattern_arguments:
    | positional_patterns [',' keyword_patterns]
    | keyword_patterns
positional_patterns: ','.pattern+
keyword_patterns: ','.keyword_pattern+
keyword_pattern: NAME '=' pattern
```

**Six requirements that a straightforward implementation gets wrong:**

1. **The soft-keyword rule is precise.** "`match` and `case` keywords are
   soft keywords, i.e. they are not reserved words in other grammatical
   contexts (including at the start of a line if there is no colon where
   expected)."

2. **A single parenthesised pattern is a group pattern, not a sequence
   pattern.** "(Note that a single parenthesized pattern without a trailing
   comma is a group pattern, not a sequence pattern. However a single
   pattern enclosed in `[...]` is still a sequence pattern.)" So `case (x):`
   binds `x`, while `case (x,):` is a one-element sequence pattern.

3. **The sequence protocol is defined precisely.** A sequence pattern
   succeeds only if the subject's class inherits from
   `collections.abc.Sequence`, is registered as one, or has the
   `Py_TPFLAGS_SEQUENCE` bit set. **The classes with that bit set are
   `array.array`, `collections.deque`, `list`, `memoryview`, `range`,
   `tuple`.** Critically: "`str`, `bytes`, and `bytearray` are usually
   considered sequences, they are not included in the above list and do not
   match sequence patterns." So `case [1, 2]:` does **not** match `"ab"`.

4. **The `__match_args__` conversion rules.** For a class pattern with
   positional subpatterns, the class must have `__match_args__` (a tuple of
   attribute names). If the returned value is not a tuple, `TypeError`. If
   there are more positional patterns than `len(__match_args__)`, `TypeError`.
   Duplicate keywords, `TypeError`. For `bool`, `bytearray`, `bytes`, `dict`,
   `float`, `frozenset`, `int`, `list`, `set`, `str` and `tuple`, the handling
   is different - they match a single positional pattern against themselves.

5. **The irrefutable-case rule.** "A match statement may have at most one
   irrefutable case block, and it must be last." Capture patterns, wildcard
   patterns, AS patterns with an irrefutable left side, OR patterns
   containing an irrefutable pattern, and parenthesised irrefutable patterns
   are irrefutable. **This is a compile-time error**, not a runtime one.

6. **Partial-match bindings are explicitly unspecified.** "User code
   including a match statement should not rely on the bindings being made
   for a failed match, but also shouldn't assume that variables are unchanged
   by a failed match. This part of the behavior is left intentionally
   unspecified so different implementations can add optimizations."

**The AST, verified from the 3.15.2 ASDL** (not from PEP 634, which
predates the `rest` field):

```
    pattern = MatchValue(expr value)
            | MatchSingleton(constant value)
            | MatchSequence(pattern* patterns)
            | MatchMapping(expr* keys, pattern* patterns, identifier? rest)
            | MatchClass(expr cls, pattern* patterns, identifier* kwd_attrs, pattern* kwd_patterns)
            | MatchStar(identifier? name)
            | MatchAs(pattern? pattern, identifier? name)
            | MatchOr(pattern* patterns)
```

Note `MatchMapping` has an `identifier? rest` field for `**rest`, and
`MatchClass` has the `kwd_attrs`/`kwd_patterns` pair.

**The `match` statement AST node** is `Match(subject, cases)` where each case
is a `match_case(pattern, guard, body)`.

### PEP 695: the annotation scope

This is the requirement I most under-specified in the earlier work plan.

**PEP 695 introduces a new kind of scope**, distinct from a function scope.
The PEP calls it a `def695` scope (a clarification device, not a keyword).

**It behaves like a function scope, except:**

1. **If a `def695` scope is immediately within a class scope** (or within
   another `def695` scope immediately within a class scope), **then names
   defined in that class scope CAN be accessed within the `def695` scope.**
   "Regular functions, by contrast, cannot access names defined within an
   enclosing class scope." **This is a genuine semantic difference from
   function scope and gpython's symtable must model it.**

   **Verified live on CPython 3.14.9.** The rule applies to **annotation
   scopes**, not to function bodies:

   | Case | Result |
   |---|---|
   | `type A = x` inside a class body, where `x` is a class attribute | **Works.** The alias resolves to the class attribute. |
   | A function's annotation `def m(self, a: x)` inside a class body, where `x` is a class attribute | **Works.** The annotation resolves to the class attribute. |
   | A function body `def m(self): return x` inside a class body | **`NameError`.** Regular function scope does not see class scope. |

   So the annotation scope is a **third** kind of scope, distinct from both
   the module scope and the function scope, and distinct from the class
   scope. gpython's symtable needs all three behaviours:
   module scope sees globals, function scope sees neither the enclosing class
   nor the enclosing function's names unless they are cells, and annotation
   scope sees the enclosing class.

2. **These constructs are disallowed directly within a `def695` scope:**
   `yield`, `yield from`, `await`, and `:=` (the walrus operator). They are
   still allowed in scopes nested *inside* a `def695` scope.

3. **The `__qualname__` of objects defined in a `def695` scope** is as if
   they were defined in the closest enclosing scope. So a class defined inside
   a generic function does not get the type parameter scope in its qualname.

4. **Names bound in a `def695` scope cannot be rebound with `nonlocal`** in
   nested scopes.

**Where type parameters are and are not in scope:**

| Context | Type parameter in scope? |
|---|---|
| The class body | Yes |
| Base class list and class keyword arguments | Yes |
| Inner scopes of the class body | Yes |
| Class decorators | **No** |
| Outside the class | **No** |
| The function body | Yes |
| Parameter and return annotations | Yes |
| Default argument values | **No** (evaluated outside the scope) |
| Function decorators | **No** |

**The lazy evaluation rule.** Three contexts are evaluated lazily: `TypeVar`
bounds, `TypeVar` constraints, and the value of a type alias. "Each expression
will be saved in a code object, and the code object is evaluated only when the
corresponding attribute is accessed (`TypeVar.__bound__`,
`TypeVar.__constraints__`, or `TypeAlias.__value__`). After the value is
successfully evaluated, the value is saved and later calls will return the
same value without re-evaluating the code object."

**The runtime type alias object.** A `type` statement generates a
`typing.TypeAliasType` instance with `__name__`, `__type_params__` and
`__value__`, all read-only.

**The `Generic` base class becomes an error.** "There is no need to include
`Generic` as a base class. Its inclusion as a base class is implied by the
presence of type parameters ... The explicit use of a `Generic` base class
will result in a runtime error."

**Type parameter names are mangled if they begin with a double underscore**,
but the `__name__` attribute holds the non-mangled name.

**Duplicate type parameter names are a compile-time syntax error.**

**The AST, verified from the 3.15.2 ASDL:**

```
    type_param = TypeVar(identifier name, expr? bound, expr? default_value)
               | ParamSpec(identifier name, expr? default_value)
               | TypeVarTuple(identifier name, expr? default_value)
```

Note the production is named `type_param` (lowercase) and all three variants
carry `default_value` in 3.15 (added by PEP 696 in 3.13). The `TypeAlias`
node is `TypeAlias(expr name, type_param* type_params, expr value)`.

**The implementer's note on the grammar.** From Jelle Zijlstra's PEP 695
implementation notes: "the `&"type"` here is a performance optimisation: it
tells the parser to only bother looking at this option if the next token is
`"type"`." And: "The order of the rules also matters. We might want to put
type aliases further down the list because they are expected to be relatively
rare compared to say `return` statements, but the grammar does not work out
if we put the type alias rule below the `star_expressions` rule, because that
rule will throw an error on type alias syntax before the parser gets a chance
to try out the `type_alias` rule."

**For gpython this is the concrete rule:** the `type` statement production must
come **before** the general expression statement production in the grammar,
or `type X = int` will fail with a parse error on `type` as a name.

### PEP 654: exception groups

**The two new types:**

| Type | Base | Purpose |
|---|---|---|
| `ExceptionGroup` | `Exception` | Groups only `Exception` instances |
| `BaseExceptionGroup` | `BaseException` | Groups any `BaseException` |

`ExceptionGroup.__new__` returns a `BaseExceptionGroup` instance if the
contained exceptions include a `BaseException` that is not an `Exception`.

**The `except*` matching algorithm** is recursive:

1. If the raised exception is an exception group, `except*` splits it.
2. Each sub-exception is tested against the `except*` clause's type.
3. Matching sub-exceptions are wrapped in a new group and bound to the
   `as` name.
4. **Non-matching sub-exceptions are re-raised** as a new group, after the
   `except*` block completes.
5. Non-matching groups are **recursively** split, so a nested group is
   descended into.

**The `split()` and `derive()` methods.** `BaseExceptionGroup.split(type)`
returns `(matched, rest)`. `derive(excs)` returns a new group of the same type.

**The forbidden combinations.** Only one pairing is a syntax error:

| Combination | Result |
|---|---|
| `except*` and a plain `except` in the same `try` | `SyntaxError: cannot have both 'except' and 'except*' on the same 'try'` |
| `except*` and a bare `except:` in the same `try` | The same `SyntaxError` |

**Correction.** An earlier draft of this section listed `except*` with `else`,
and `except*` with `finally`, as forbidden. **Both are allowed.** The 3.15.2
grammar has two distinct try productions:

```
try1_stmt: 'try' ':' block (except_block+ else_block? finally_block?)?
try2_stmt: 'try' ':' block except_star_block+ else_block? finally_block?
```

`try2_stmt` is the `except*` form and it carries **both** an optional `else`
block and an optional `finally` block. The `except*` AST node is `TryStar`,
distinct from `Try`.

Verified live on CPython 3.14.9: `try: ... except* ValueError: ... else: ...`
compiles and runs without error, and so does the same with a `finally`.

**A second syntax error, from the 3.15.2 grammar.** Multiple exception types
with `as` must be parenthesised:

```
| invalid_except_stmt:
    | 'except' a=expression ',' expressions 'as' NAME ':' {
        RAISE_SYNTAX_ERROR_STARTING_FROM(a, "multiple exception types must be parenthesized when using 'as'") }
```

So `except ValueError, TypeError as e:` is a `SyntaxError`. This is the
PEP 758 change (3.14), which made the grouping parentheses optional when
there is no `as`.

**Why this is the hardest runtime change.** `except*` is not a new type plus a
new opcode. It is a **new control-flow shape**: the handler must be able to
split a group, run the body with only the matching part, and then re-raise
the remainder *after* the body completes. That requires the VM to support
saving and restoring an exception state across a handler body. The opcodes
`PUSH_EXC_INFO`, `POP_EXCEPT`, `CHECK_EG_MATCH`, `CLEANUP_THROW` and
`RERAISE` implement it.

**The "naked exception" rule.** A `BaseException` that is not an `Exception`
cannot be wrapped in an `ExceptionGroup`. It must go in a
`BaseExceptionGroup`.

### PEP 709: comprehension inlining

**The before bytecode**, for `def f(lst): return [x for x in lst]`:

```
  0 RESUME                   0
  2 LOAD_CONST               1 (<code object <listcomp> at 0x...>)
  4 MAKE_FUNCTION            0
  6 LOAD_FAST                0 (lst)
  8 GET_ITER
 10 CALL                     0
 20 RETURN_VALUE
```

**The after bytecode:**

```
  0 RESUME                   0
  2 LOAD_FAST                0 (lst)
  4 GET_ITER
  6 LOAD_FAST_AND_CLEAR      1 (x)
  8 SWAP                     2
 10 BUILD_LIST               0
 12 SWAP                     2
>> 14 FOR_ITER               4 (to 26)
 18 STORE_FAST               1 (x)
 20 LOAD_FAST                1 (x)
 22 LIST_APPEND              2
 24 JUMP_BACKWARD            6 (to 14)
>> 26 END_FOR
 28 SWAP                     2
 30 STORE_FAST               1 (x)
 32 RETURN_VALUE
```

**The mechanism.** `LOAD_FAST_AND_CLEAR` at offset 6 saves any outer value of
`x` on the stack and clears the slot. `STORE_FAST` at offset 30 restores it.
If the comprehension accesses variables from the outer scope, inlining avoids
placing them in a cell.

**Four visible behaviour changes:**

1. **`locals()` inside a comprehension now includes the outer variables.**
   Before: `[locals() for x in lst]` gives
   `[{'.0': <list_iterator object>, 'x': 1}]`. After:
   `[{'lst': [1], 'x': 1}]`. The synthetic `.0` argument is gone and the
   outer `lst` appears.

2. **A traceback no longer shows a `<listcomp>` frame.**

3. **The comprehension no longer forces outer variables into cells.**

4. **Generator expressions are NOT inlined.** They remain their own code
   object.

**The scope rules, from CPython's internal design note.** This is the part
that a naive implementation gets wrong:

- `symtable_handle_comprehension()` inlines a comprehension **when it is not
  a generator expression AND the current block cannot see class scope**
  (`!ste_can_see_class_scope`). **Annotation scopes that can see a class
  keep the historical nested-function compilation**, so class-local names are
  not treated as comprehension locals.

- An inlined comprehension gets an **`InlinedComprehensionBlock`** entry. It is
  a child of the enclosing block with `ste_parent` pointing at it. **It is a
  lexical subscope, not a compilation unit**: no separate code object, no
  `co_consts` entry, no compiler scope.

- `finalize_inlined_comprehension()` copies `USE` from the inlined child onto
  the parent, and **drops inlined-only frees** so `analyze_cells()` does not
  promote those names to cells.

- `_PyCompile_EnterInlinedComprehensionScope()` /
  `_PyCompile_ExitInlinedComprehensionScope()` in `Python/compile.c` swap
  `c->u->u_ste` so name lookup uses the comprehension's symbol table. The
  saved `u_ste` is restored on **both success and error**.

- `codegen_push_inlined_comprehension_locals()` in `Python/codegen.c` does the
  isolation: `LOAD_FAST_AND_CLEAR` saves the enclosing value, `MAKE_CELL`
  runs if the name is a cell for this comprehension, and in module and class
  units the name is added to `u_fasthidden` so `assemble` can set
  `CO_FAST_HIDDEN`.

- A `SETUP_FINALLY` / `COMPILE_FBLOCK_INLINED_COMPREHENSION` handler restores
  those slots **if the comprehension raises**, so an enclosing `except` or
  `finally` sees the original values.

**Why `LOAD_FAST_AND_CLEAR` had to be a new opcode.** From the implementation
PR: "We need a new opcode `LOAD_FAST_AND_CLEAR` because we need to push/pop
the value of possibly-undefined variables on the stack while clearing them.
To do this with existing opcodes would require eliminating the
invariant/assert that `LOAD_FAST` never loads `NULL`."

**The cell-in-`co_varnames` detail.** From the same PR: "If a comprehension
iteration variable is a cell inside the comprehension ... we end up including
that variable in both `co_varnames` and `co_cellvars` for the inlined-into
outer function and using the non-offset (varnames) storage location for it.
This is how function arguments that are also cells are currently handled, so we
just piggyback on that handling."

**What this means for gpython.** gpython's `symtable/` currently creates a
real scope for every comprehension, and `compile/compile.go` emits a nested
function. Both have to change. The design is: keep a lexical subscope in the
symtable, but emit the code inline. gpython does not need the `CO_FAST_HIDDEN`
flag machinery if it does not optimise, but it does need the save/restore
semantics, because they are observable through `locals()`.

### PEP 649 and 749: deferred annotations

**The mechanism.** The compiler emits an `__annotate__` function alongside
each annotated definition. `__annotations__` becomes a descriptor that calls
it.

**The `__annotate__` signature.** From PEP 749: `__annotate__(format)`, where
`format` is one of the `annotationlib.Format` values.

**The formats.** PEP 749 renamed `SOURCE` to `STRING`:

| Format | Meaning |
|---|---|
| `annotationlib.Format.VALUE` | The evaluated annotation object |
| `annotationlib.Format.STRING` | The source text as a string |
| `annotationlib.Format.FORWARDREF` | A `ForwardRef` that resolves on use |
| `annotationlib.Format.VALUE_WITH_FAKE_GLOBALS` | The value, evaluated in a restricted globals environment. Added by PEP 749; there is **no code flag** for it. |

**The `annotationlib` module** provides `get_annotations()`, the `Format`
enum, the `ForwardRef` class, and a helper for calling `__annotate__`
functions.

**`from __future__ import annotations` is deprecated.** PEP 749's plan:
"Compiling any code that uses the future import will emit a
`DeprecationWarning`." It still works in 3.14 and 3.15, and the
`__annotate__` function returns strings when the future import is active.

**The stringifier's supported expressions.** PEP 749's appendix gives an exact
list. This matters because gpython must implement the same behaviour, and
because it is a **security consideration**:

**Supported:** `BinOp`, `UnaryOp` (`~`, `+`, `-` only, **not** `not`),
`Dict` (except `**` unpacking), `Set`, `Compare` (`==`, `!=`, `<`, `<=`,
`>`, `>=`; **not** `is`, `is not`, `in`, `not in`), `Call` (except `**`
unpacking), `Constant`, `Attribute`, `Subscript`, `Starred`, `Name`, `List`,
`Tuple`, `Slice`.

**Unsupported, throw an informative error:** `FormattedValue`, `JoinedStr`.

**Unsupported, result in incorrect output:** `BoolOp`, `IfExp`, `Lambda`,
`ListComp`, `SetComp`, `DictComp`, `GeneratorExp`.

**Disallowed in annotation scopes:** `NamedExpr`, `Await`, `Yield`,
`YieldFrom`.

**The security note, verbatim from PEP 749:** "it is also not safe to request
the `SOURCE` format on untrusted code: Python is powerful enough that it is
possible to achieve arbitrary code execution even with no access to any
globals or builtins." The example given is:

```python
def f(x: (1).__class__.__base__.__subclasses__()[-1].__init__.__builtins__["print"]("Hello world")): pass
```

which prints `Hello world` when `annotationlib.get_annotations(f, format=...)`
is called. **A gpython implementation must not be less safe than this.**

**Other PEP 749 requirements:**

- Deleting `__annotations__` also clears `__annotate__`.
- Accessing annotations on a **partially executed module** returns the
  annotations executed so far, but does not cache them.
- Conditionally defined class and module annotations are handled correctly.
- The REPL evaluates annotations lazily, like module-level annotations.

### PEP 810: the lazy import restrictions

Confirmed from the 3.15 What's New, which states the restrictions precisely:

| Restriction | Error |
|---|---|
| `lazy` inside a function | `SyntaxError` |
| `lazy` inside a class body | `SyntaxError` |
| `lazy` inside a `try`/`except`/`finally` block | `SyntaxError` |
| `lazy from module import *` | `SyntaxError` |
| `lazy from __future__ import ...` | `SyntaxError` |

**The `__lazy_modules__` alternative.** "For code that cannot use the `lazy`
keyword directly (for example, when supporting Python versions older than
3.15 while still using lazy imports on 3.15+), a module can define
`__lazy_modules__` as a container of fully qualified module name strings.
Regular `import` statements for those modules are then treated as lazy, with
the same semantics as the `lazy` keyword."

**The runtime controls:** `-X lazy_imports` and `PYTHON_LAZY_IMPORTS` both
accept `all` or `normal` (the default). `sys.set_lazy_imports()`,
`sys.get_lazy_imports()` and `sys.set_lazy_imports_filter()` change the mode
at runtime. The filter callable receives `(importing, imported, fromlist)` and
returns `True` to allow lazy loading.

**The proxy type** is `types.LazyImportType`.

**The failure behaviour:** "In the case where loading a lazily imported module
fails ... Python raises the exception at the point of first use rather than at
import time. The associated traceback includes both the location where the
name was accessed and the original import statement."

### The 3.15 `frozendict` and `sentinel`

**`frozendict`** (PEP 814):

- Not a subclass of `dict`; inherits directly from `object`.
- Hashable if all its keys and values are hashable.
- Preserves insertion order, but **comparison does not take order into
  account**: `frozendict(y=2, x=1) == frozendict(x=1, y=2)` is `True`.
- `hash(a) == hash(b)` for orderings that compare equal.
- `TypeError: 'frozendict' object does not support item assignment` on
  mutation.

**The modules updated to accept `frozendict`:** `copy`, `decimal`, `json`,
`marshal`, `plistlib` (serialisation only), `pickle`, `pprint`,
`xml.etree.ElementTree`. And `eval()`/`exec()` accept it for `globals`, and
`type()`/`str.maketrans()` accept it for `dict`.

**`sentinel`** (PEP 661): a new builtin type used as a unique marker.

### The 3.15 removals

From the 3.15 What's New "Removed" section, the modules with removals are:
`ast`, `collections.abc`, `ctypes`, `datetime`, `glob`, `http.server`,
`importlib`, `importlib.resources`, `pathlib`, `platform`, `sre_*`,
`sysconfig`, `threading`, `types`, `typing`, `wave`, `zipimport`.

**This closes the verification gap** recorded in `../SOURCES.md`, which said
"the complete Python 3.15 Removed section still needs to be reviewed". The
module list is now known. The individual removed *functions* within those
modules are not yet itemised.

## Verification

### Live behaviour checks

These were run against the installed CPython 3.14.9 on 2026-11-18. They
confirm the semantic claims above; the source checks that follow confirm the
3.15.2-specific ones.

| Check | Expected | Result |
|---|---|---|
| 5-level f-string nesting: `f"{f\"{f\"{f\"{f\"{1+1}\"}\"}\"}\"}"` | `2` | **Confirmed**, printed `2` |
| 2-level format-spec nesting: `f"{'':*^{1:{1}}}"` | no error | **Confirmed**, printed `*` |
| `str` is not a sequence-pattern subject | `no match` | **Confirmed** |
| `locals()` inside a comprehension has no `.0` and includes outer names | `[{'lst': [1], 'x': 1}]` | **Confirmed** |
| PEP 695: type parameter not in scope in a default value | `NameError: name 'T' is not defined` | **Confirmed** |
| PEP 695: type alias in a class body sees the class scope | resolves | **Confirmed** |
| PEP 695: function annotation in a class body sees the class scope | resolves | **Confirmed** |
| PEP 695: regular function body in a class body does not see class scope | `NameError` | **Confirmed** |
| `except*` with `else` | no error | **Confirmed** (corrects an earlier claim) |
| `except*` with `finally` | no error | **Confirmed** |
| `except*` mixed with `except` in one `try` | `SyntaxError` | **Confirmed** |
| `except*` mixed with a bare `except:` | `SyntaxError` | **Confirmed** |
| `frozendict` exists | present | **Not applicable on 3.14**; it is a 3.15 builtin |

**1. Confirm the 3.15 opcode count and the five corrections.**

```bash
B=https://raw.githubusercontent.com/python/cpython/v3.15.2
curl -s $B/Include/opcode_ids.h | grep -cE '^#define\s+[A-Z_0-9]+\s+[0-9]+'
```

Expect `248`.

```bash
for o in RETURN_CONST FORMAT_VALUE KW_NAMES LOAD_ASSERTION_ERROR JUMP_IF_NOT_EXC_MATCH; do
  curl -s $B/Include/opcode_ids.h | grep -q "^#define $o " \
    && echo "EXISTS: $o" || echo "absent: $o"
done
```

Expect `absent:` for all five. This is the check that would have caught the
error.

**2. Confirm the real names are present.**

```bash
for o in FORMAT_SIMPLE FORMAT_WITH_SPEC BUILD_STRING CALL_KW CALL_FUNCTION_EX \
          MAKE_CELL COPY_FREE_VARS LOAD_FAST_AND_CLEAR END_FOR RESUME COPY SWAP \
          CHECK_EG_MATCH PUSH_EXC_INFO POP_EXCEPT CLEANUP_THROW RERAISE WITH_EXCEPT_START; do
  curl -s $B/Include/opcode_ids.h | grep -q "^#define $o " || echo "MISSING: $o"
done
```

Expect no output.

**3. Confirm the 3.15.2 AST for pattern matching and type parameters.**

```bash
curl -s $B/Parser/Python.asdl | grep -E "Match|type_param|TypeAlias"
```

Expect the nine `Match*` alternatives, `MatchMapping` with `identifier? rest`,
`MatchClass` with `kwd_attrs`/`kwd_patterns`, the lowercase `type_param`
production with `default_value` on all three variants, and
`TypeAlias(expr name, type_param* type_params, expr value)`.

**4. Confirm the f-string grammar from PEP 701.**

```bash
curl -s https://peps.python.org/pep-0701/ | grep -A6 "fstring_replacement_field"
```

Expect the grammar with `FSTRING_START`, `FSTRING_MIDDLE`, `FSTRING_END`, and
the `"="?` and `[ "!" NAME ]` and `[ ':' fstring_format_spec* ]` parts.

**5. Confirm the 5-level nesting lower bound is a real requirement.**

```bash
python3.15 -c 'f"{f\"{f\"{f\"{f\"{1+1}\"}\"}\"}\"}"'
```

Expect `2`.

**6. Confirm the format-spec 2-level nesting lower bound.**

```bash
python3.15 -c "f\"{'':*^{1:{1}}}\""
```

Expect no error.

**7. Confirm the sequence-pattern exclusion of `str`.**

```bash
python3.15 -c "
match 'ab':
    case [a, b]: print('matched', a, b)
    case _: print('no match')
"
```

Expect `no match`. `str` is not a sequence pattern subject.

**8. Confirm the PEP 709 `locals()` change.**

```bash
python3.15 -c "
def f(lst): return [locals() for x in lst]
print(f([1]))
"
```

Expect `[{'lst': [1], 'x': 1}]` - no `.0` key.

**9. Confirm the 3.15 removed-module list.**

```bash
curl -s https://docs.python.org/3/whatsnew/3.15.html | grep -A40 'id="removed"' | grep -oE 'id="[a-z.*_]+"'
```

Expect the list `ast`, `collections.abc`, `ctypes`, `datetime`, `glob`,
`http.server`, `importlib`, `importlib.resources`, `pathlib`, `platform`,
`sre_*`, `sysconfig`, `threading`, `types`, `typing`, `wave`, `zipimport`.

**10. Confirm the lazy import restrictions.**

```bash
printf 'try:\n    lazy import os\nexcept ImportError:\n    pass\n' > /tmp/lz2.py
python3.15 -c "compile(open('/tmp/lz2.py').read(), 'lz2.py', 'exec')"
```

Expect a `SyntaxError`.

**11. Confirm the PEP 695 scope rule that type parameters are not in scope in
default values or decorators.**

```bash
python3.15 -c "
def f[T](a = list[T]): pass
"
```

Expect a `NameError` at runtime (the default is evaluated outside the scope),
not a `SyntaxError`.

**12. Confirm the `frozendict` order-insensitive comparison.**

```bash
python3.15 -c "
a = frozendict(x=1, y=2)
b = frozendict(y=2, x=1)
print(a == b, hash(a) == hash(b))
"
```

Expect `True True`.
