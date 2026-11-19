# 08 - Hand-written Parsers and Lexers in Go

## Overview

The 3.15 upgrade needs the grammar to change substantially: pattern matching
(PEP 634), type parameters (PEP 695), t-strings (PEP 750), f-string
rewriting (PEP 701), `except*` (PEP 654), async (PEP 492), the walrus
operator (PEP 572) and variable annotations (PEP 526) all have to land.

**Question: should gpython keep using goyacc, or replace it with a
hand-written recursive-descent parser?**

**Answer: the lexer is already hand-written. Only the parser uses goyacc.
The parser is 129 rules in a 1,987-line grammar, generating 3,155 lines of
Go.**

The measured breakdown:

| Component | Lines | Hand-written? |
|---|---|---|
| `parser/lexer.go` | 992 | **Yes**, already |
| `parser/stringescape.go` | 147 | Yes |
| `parser/grammar.y` | 1,987 | The grammar |
| `parser/y.go` | 3,155 | **Generated** by goyacc |
| `parser/y.output` | - | Generated debug output |

**The recommendation is a hybrid**, and it is not the obvious one. See
"Recommendation" below.

## Sources

### Web, fetched 2026-11-19

| URL | Used for |
|---|---|
| `https://blog.gopheracademy.com/advent-2014/parsers-lexers/` | The core method: hand-written scanner and recursive-descent parser in Go, by Ben Johnson. The three-part structure: token type, character classes, `read`/`unread` scanner, `scan`/`unscan` parser with a one-token buffer. |
| `https://eli.thegreenplace.net/2012/08/02/parsing-expressions-by-precedence-climbing` | Precedence climbing for expressions. The `compute_expr(min_prec)` algorithm, associativity handling, and the note that Clang uses it in `Parser::ParseExpression`. |
| `https://github.com/python/cpython/blob/main/InternalDocs/parser.md` | CPython's own parser documentation: why PEG, packrat memoization, the `(memo)` marker, left recursion. |
| `https://github.com/python/cpython/blob/main/InternalDocs/compiler.md` | How the rule functions `xx_rule` are generated, and the two-pass error recovery. |
| `https://github.com/python/cpython/blob/master/Tools/peg_generator/pegen/parser.py` | The actual memoization and left-recursion implementations in Pegen. |
| `https://raw.githubusercontent.com/python/cpython/v3.15.2/Grammar/python.gram` | The 1,653-line PEG grammar: 147 `invalid_` occurrences and 20 `(memo)` markers. The `match_stmt` and `case_block` rules. |
| `https://lobste.rs/s/10pkib/parser_generators_vs_handwritten` | The survey recommending hand-written recursive descent first, then parsing combinators, then parser generators. |
| `https://en.wikipedia.org/wiki/Operator-precedence_parser` | The three algorithm families: shunting yard, TDOP, precedence climbing. |

### The gpython checkout

| Path | Measured |
|---|---|
| `parser/lexer.go` | 992 lines, hand-written |
| `parser/grammar.y` | 1,987 lines, 129 rules |
| `parser/y.go` | 3,155 lines, generated |
| `parser/stringescape.go` | 147 lines |

## Spec

### Part 1 - What gpython has today

#### The lexer is already hand-written

`parser/lexer.go` is 992 lines of ordinary Go with no code generation. It
implements:

```go
func (l *yyLex) Lex(yylval *yySymType) (ret int)   // the token scanner
func (l *yyLex) readIdentifierOrKeyword() (int, string)
func (l *yyLex) readOperator() int
func (l *yyLex) readNumber() (token int, value py.Object)
func (l *yyLex) readString() (token int, value py.Object)
func (l *yyLex) queueDedents()
func (l *yyLex) refill()
```

The structure is the same one Ben Johnson's article describes:

- A `bufio.Reader` with `read`/`unread` helpers.
- An explicit token queue for `INDENT`/`DEDENT` lookahead.
- A bracket-depth counter (`bracket`, `parenthesis`, `brace`) so the lexer
  knows when newlines are significant.
- A `state` field for the lexer state machine.

**The lexer uses `regexp` for numbers.** Six compiled patterns:

```go
decimalInteger        = regexp.MustCompile(`^[0-9]+[jJ]?`)
illegalDecimalInteger = regexp.MustCompile(`^0[0-9]*[1-9][0-9]*$`)
octalInteger          = regexp.MustCompile(`^0[oO][0-7]+`)
hexInteger            = regexp.MustCompile(`^0[xX][0-9a-fA-F]+`)
binaryInteger         = regexp.MustCompile(`^0[bB][01]+`)
floatNumber           = regexp.MustCompile(`^(([0-9]+|` + pointFloat + `)[eE][+-]?[0-9]+|` + pointFloat + `)[jJ]?`)
```

**This is a performance problem.** The CPython 3.15 grammar adds the `j`
suffix to imaginary numbers, and `0o`/`0x`/`0b` prefixes. Six regexes per
number literal is slow, and a hand-written scanner would remove them
entirely.

#### The parser is generated

`parser/grammar.y` is 1,987 lines with 129 rules, and goyacc turns it into
3,155 lines of Go.

**goyacc is an LALR(1) generator.** That matters for the 3.15 features:

| Feature | LALR(1) problem |
|---|---|
| **PEP 634 match/case** | `case` patterns need arbitrary lookahead to distinguish `case [x]` from `case (x)` from `case {x}`. LALR(1) has one token of lookahead. |
| **Soft keywords** (`match`, `case`, `type`, `lazy`) | The generator needs a *context* predicate, not a token type. goyacc has no mechanism for this. |
| **PEP 750 t-strings** | Straightforward, but adds three token types. |
| **PEP 701 f-strings** | Needs lexer work, not grammar work. |

**The soft-keyword problem is the sharp one.** CPython's PEG grammar
solves it with a *validator* that inspects the token stream at the point of
use:

```
match_stmt[stmt_ty]:
    | invalid_* ...
    | "match" subject_expr ':' NEWLINE INDENT case_block+ DEDENT
```

The `invalid_*` alternatives are guarded by a runtime check. In an LALR
parser there is no such place to put a context-sensitive predicate, which is
why `specs/02-language-upgrade/02-gpython-work-plan.md` recommends lexer
context tracking instead.

**CPython's own solution, from `InternalDocs/parser.md`:**

> PEG parsers are usually constructed as a recursive descent parser in which
> every rule in the grammar corresponds to a function in the program
> implementing the parser.

And from `InternalDocs/compiler.md`:

> Each rule function in turn creates an AST node as it goes along... If an
> error occurs, the rule functions backtrack and try another rule function.

**CPython's parser IS a recursive-descent parser.** It is generated, but
the generated code is recursive descent with backtracking, not a table-driven
LALR automaton.

#### What goyacc costs

| Cost | Detail |
|---|---|
| An external tool | `goyacc` must be installed and pinned. The CI does not install it, so `go generate ./parser/` fails on a clean checkout. |
| A generated file in the tree | `parser/y.go`, 3,155 lines, plus `parser/y.output`. |
| Debugging difficulty | Ben Johnson's article: "they're difficult to debug. For example, try reading the Ruby language's yacc file. Eek!" |
| Grammar conflicts | An LALR grammar for Python has conflicts. CPython's old LL(1) grammar needed `%prec` and a shift/reduce resolution table. |
| No context predicates | The soft keywords have no place to live. |

**The tool dependency is real and already bit us.** The `go:generate`
directive cannot run on a fresh checkout without installing goyacc first,
and the tool version changes the output (`int` to `int16` in the parse
tables).

### Part 2 - The hand-written method

From Ben Johnson's article, the structure is:

**1. Define the token types as an `int` enum with `iota`.**

```go
type Token int

const (
	ILLEGAL Token = iota
	EOF
	WS
	IDENT
	ASTERISK
	COMMA
	SELECT
	FROM
)
```

**2. Define character-class predicates.**

```go
func isWhitespace(ch rune) bool { return ch == ' ' || ch == '\t' || ch == '\n' }
func isLetter(ch rune) bool     { return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') }
```

**3. Wrap the reader with read/unread.**

```go
type Scanner struct{ r *bufio.Reader }

func (s *Scanner) read() rune {
	ch, _, err := s.r.ReadRune()
	if err != nil {
		return eof
	}
	return ch
}

func (s *Scanner) unread() { _ = s.r.UnreadRune() }
```

**4. One `Scan()` entry point that dispatches on the first character.**

```go
func (s *Scanner) Scan() (tok Token, lit string) {
	ch := s.read()
	if isWhitespace(ch) {
		s.unread()
		return s.scanWhitespace()
	} else if isLetter(ch) {
		s.unread()
		return s.scanIdent()
	}
	switch ch {
	case eof:
		return EOF, ""
	case '*':
		return ASTERISK, string(ch)
	case ',':
		return COMMA, string(ch)
	}
	return ILLEGAL, string(ch)
}
```

**5. One `scanXxx` method per token class**, each consuming contiguous
characters until the class ends.

**6. A parser with a one-token buffer over the scanner.**

```go
type Parser struct {
	s   *Scanner
	buf struct {
		tok Token
		lit string
		n   int
	}
}

func (p *Parser) scan() (tok Token, lit string) {
	if p.buf.n != 0 {
		p.buf.n = 0
		return p.buf.tok, p.buf.lit
	}
	tok, lit = p.s.Scan()
	p.buf.tok, p.buf.lit = tok, lit
	return
}

func (p *Parser) unscan() { p.buf.n = 1 }
```

**7. The parser itself is a set of mutually recursive functions**, one per
grammar rule, each returning an AST node.

**gpython already has steps 1 to 6.** The lexer is a hand-written scanner
with a token queue and bracket tracking. **Only step 7 is generated.**

### Part 3 - The expression parser: precedence climbing

**Expressions are the hard part of a recursive-descent parser**, because
Python has 17 operator precedence levels and 6 levels of parenthesisation.

The three algorithm families, from the Wikipedia article:

| Algorithm | Shape |
|---|---|
| Shunting yard | An explicit operator stack |
| Top-down operator precedence (TDOP) | A precedence stack inside recursive descent |
| **Precedence climbing** | One recursive function with a minimum precedence parameter |

**Precedence climbing is the one that is used in practice.** Eli
Bendersky's article gives the algorithm:

```
compute_expr(min_prec):
  result = compute_atom()

  while cur token is a binary operator with precedence >= min_prec:
    prec, assoc = precedence and associativity of current token
    if assoc is left:
      next_min_prec = prec + 1
    else:
      next_min_prec = prec
    rhs = compute_expr(next_min_prec)
    result = compute operator(result, rhs)

  return result
```

**Associativity falls out of one comparison.**

For a left-associative operator at precedence `p`, the recursive call gets
`min_prec = p + 1`, so the inner call sees the same operator at
precedence `p` and refuses it. The outer call handles it. Result:
`(8 * 9) * 10`.

For a right-associative operator, the recursive call gets `min_prec = p`,
so the inner call consumes the operator. Result: `8 ^ (9 ^ 10)`.

**Clang uses this.** `Parser::ParseExpression` in `lib/Parse/ParseExpr.cpp`
is `compute_expr`, and `Parser::ParseCastExpression` is `compute_atom`.

**Python's operator precedence table, from the Language Reference, lowest
to highest:**

| Level | Operators | Associativity |
|---|---|---|
| 1 | `lambda` | n/a |
| 2 | `if`/`else` (conditional) | right |
| 3 | `or` | left |
| 4 | `and` | left |
| 5 | `not x` | right |
| 6 | comparisons, `in`, `not in`, `is`, `is not`, `<`, `<=`, `>`, `>=`, `!=`, `==` | left |
| 7 | `\|` | left |
| 8 | `^` | left |
| 9 | `&` | left |
| 10 | `<<`, `>>` | left |
| 11 | `+`, `-` | left |
| 12 | `*`, `@`, `/`, `//`, `%` | left |
| 13 | unary `+x`, `-x`, `~x` | right |
| 14 | `**` | right |
| 15 | `await x` | right |
| 16 | subscription, slicing, call, attribute | left |
| 17 | atom | n/a |

**The `**` special case.** Python's `**` binds tighter than unary minus on
the left but looser on the right: `-2**2` is `-(2**2)` = -4, but `2**-1` is
`2**(-1)` = 0.5. A precedence-climbing parser handles this with a special
case in the power rule, not with a precedence number.

**The `await` and `lambda` cases** are similarly not expressible as a
precedence number, because `await` binds tighter than `**` but `lambda` is
an atom.

**This is the strongest argument for the hybrid approach.** The
expression grammar has enough special cases that a general table-driven
mechanism is *easier* to get right than hand-rolled precedence numbers.

### Part 4 - Recommendation: a hybrid

**The three options, honestly assessed.**

| Option | Effort | Verdict |
|---|---|---|
| **A. Keep goyacc** | Low | Soft keywords stay hard. The tool dependency stays. |
| **B. Hand-write the whole parser** | Very high | The expression grammar gets error-prone. 129 rules is a lot of code. |
| **C. Hybrid: hand-write the lexer and the expression parser, generate the statement grammar** | Medium | **Recommended.** |

**What C means concretely.**

| Part | Approach | Why |
|---|---|---|
| The lexer | **Already hand-written.** Extend it. | Remove the six number regexes. Add the `j` suffix, f-string tokens, t-string tokens. |
| The expression parser | **Hand-written with precedence climbing.** | Soft keywords cannot live in an LALR grammar. Precedence climbing handles the 17 levels. |
| The statement grammar | **Keep goyacc, or hand-write.** | Statements are mostly keyword-led and do not need context predicates, except `match`/`case`/`type`. |

**The decisive argument is the soft keywords.** `match`, `case`, `type`
and `lazy` are only keywords in context. That is a **context-sensitive
token classification**, which belongs in the lexer, not in the grammar.

**CPython solves it in two places.**

First, the **lexer** classifies *reserved* keywords, in
`_PyPegen_fill_token`:

> NAME tokens get their keyword classification applied here via
> `_get_keyword_or_name_type`, so `for` is `FOR` by the time the parser
> sees it.

Second, the **grammar** handles the soft keywords with `invalid_*`
alternatives. CPython 3.15.2's `Grammar/python.gram` has **147
`invalid_` occurrences**. The two rules that matter:

```
match_stmt[stmt_ty]:
    | "match" subject=subject_expr ':' NEWLINE INDENT cases[asdl_match_case_seq*]=case_block+ DEDENT {
        CHECK_VERSION(stmt_ty, 10, "Pattern matching is", _PyAST_Match(subject, cases, EXTRA)) }
    | invalid_match_stmt

case_block[match_case_ty]:
    | invalid_case_block
    | "case" pattern=patterns guard=guard? ':' body=block {
        _PyAST_match_case(pattern, guard, body, p->arena) }
```

**`invalid_match_stmt` is the mechanism.** It is an alternative that the
parser tries *after* the real one fails, and it produces a good error
message instead of a generic "invalid syntax". The second pass over the
token stream, with `call_invalid_rules = 1`, is what enables it.

**An LALR parser has no such alternative.** The decision to take
`invalid_match_stmt` is made by a table, and the table cannot depend on
whether the construct parsed successfully at an earlier point. That is
the structural reason goyacc cannot express PEP 634.

**CPython's grammar also has 20 `(memo)` markers.** Memoization is
disabled by default because the C parser is already highly optimized, and
memoization costs both memory and time.

**So the hybrid is:**

1. The lexer classifies `match`, `case`, `type` and `lazy` as **soft
   keywords** and emits a distinct token, but the parser accepts that token
   as a plain NAME in the contexts where it is an identifier.
2. The **expression parser is hand-written**, with precedence climbing.
   This is where soft keywords actually cause trouble, because an
   expression can start with `match(x)` (a call) or `match = 1` (an
   assignment) or `case` as a variable name.
3. The **statement grammar stays generated**, because it does not need
   context predicates beyond what the lexer provides.

**This removes the `goyacc` dependency for the parts that need it, but
does not remove it entirely.** If the goal is to remove the external tool
altogether, then the statement grammar has to be hand-written too, and that
is option B.

**A pragmatic middle path exists.** Write the lexer to emit a distinct
token for each soft keyword, and write a **hand-written shim** in front of
the generated parser that rewrites the token stream when the soft keyword
is being used as an identifier. That is the "lexer context tracking" the
work plan already recommends, and it is much cheaper than option B.

### Part 5 - The code generator idea

The user's suggestion was that a hand-written parser might allow an
**optimised code generator for the grammar**.

**This is a separate idea from hand-writing the parser, and it is the more
interesting one.** Two readings:

**Reading 1: generate the recursive-descent functions from the grammar.**
That is what CPython's Pegen does, but for PEG. A generator for
recursive-descent Go functions from a Python grammar would produce
something very close to `parser/y.go` but without the LALR tables and
without the tool dependency.

**Reading 2: generate a parser specialised for gpython's compiler.**

This is where the real win is. Look at what gpython's compiler actually
needs from the AST:

- The compile, symtable and grammar golden files are the oracle.
- The compiler walks the AST and emits bytecode.
- The symtable pass walks the AST and computes scopes.

**A parser that emitted the AST in the shape the compiler wants would
remove an entire translation layer.** The AST is currently built by the
grammar actions in `parser/grammar.y`, then walked twice (once by
symtable, once by compile).

**The concrete opportunity.** CPython's `Grammar/python.gram` has two
separate grammars:

- `Grammar/python.gram` - the full grammar.
- `Grammar/Grammar` - the legacy LL(1) grammar, kept for the old parser.

And CPython keeps **two AST schemas**:

- `Parser/Python.asdl` - the current one, with `type_ignores`, `type_params`.
- `Include/cpython/ast.h` - the C-level struct definitions.

**A generator for gpython could read `Grammar/python.gram` and emit Go
functions that build gpython's `ast` package types directly**, with the
positions already attached. That is what gpython's `grammar.y` actions
already do, but the actions are hand-written in yacc syntax rather than
generated.

**The obstacle is that `Grammar/python.gram` has Python actions, and
`parser/grammar.y` has Go actions.** They are two different grammars for
the same language, and they have drifted. A generator that reads the
Python grammar and emits Go would need to either:

1. Ignore the Python actions and regenerate the Go actions from the AST
   schema, or
2. Translate the Python actions to Go, which needs a Python-to-Go
   translator, which is exactly the py2go project.

**Option 1 is tractable.** The `Parser/Python.asdl` schema and the rule
structure are enough to derive most AST construction. The exceptions are
the rules where the shape is not derivable from the schema alone, such as
`star_expressions` where the distinction between a tuple and a parenthesised
expression is semantic.

**The recommendation on the generator.** Write a small generator that
reads `Parser/Python.asdl` and `Grammar/python.gram` and emits Go AST
constructors, then hand-write the parser functions. That gives:

- No goyacc dependency.
- The AST stays in sync with CPython's schema automatically.
- The generator is far simpler than a full parser generator, because it
  does not have to handle backtracking or precedence.

### Part 6 - What CPython's own parser does that gpython must match

From `InternalDocs/parser.md` and `InternalDocs/compiler.md`:

| Behaviour | Detail |
|---|---|
| **Packrat memoization** | CPython's PEG parser memoizes selected rules. The `(memo)` marker in the grammar selects them. **Memoization is disabled by default** because the C parser is "highly optimized" and memoization "can be expensive in both memory and time". |
| **Left recursion** | CPython's Pegen implements it using the memoization cache rather than static variables. |
| **Two-pass error recovery** | The second pass sets `call_invalid_rules = 1`, which enables the `invalid_*` alternatives for better diagnostics. |
| **`PyPARSE_ALLOW_INCOMPLETE_INPUT`** | The REPL flag that turns an EOF failure into `IncompleteInputError`. |
| **AST validation** | In debug builds, `_PyAST_Validate` checks invariants the grammar cannot encode, such as "starred targets only inside tuples". |
| **Error messages** | `Parser/pegen_errors.c` walks to the deepest reached position to produce "expected `:`" pointing at the right column. `Python/suggestions.c` adds the "did you mean" suggestions. |

**gpython has neither of the last two.** A recursive-descent parser makes
the "deepest reached position" technique natural, because the parser knows
where it got to. This is a **quality improvement** that comes with the
rewrite, not just a speed improvement.

### Part 7 - The performance question

**The claim to test: a hand-written parser is faster.**

| Aspect | goyacc (LALR) | Hand-written recursive descent |
|---|---|---|
| Per-token dispatch | A table lookup: `yyAct[state][token]` | A function call, often inlined |
| Parse state | The parser stack, in a slice | The Go call stack |
| Backtracking | None | Possible; the danger is exponential blowup |
| Memory | The parse tables, `yyAct`, `yyPact`, `yyChk`, `yyDef` | Nothing static |
| Function call overhead | None | Every rule is a call |

**The honest answer is that the difference is small for a language the size
of Python.** A goyacc parser is already a fast table-driven automaton.
The win from hand-writing is:

1. **No tool dependency.** The build works from a fresh checkout.
2. **No 3,155-line generated file** to review, and no grammar conflicts to
   manage.
3. **Context-sensitive lexing**, which is the actual blocker for the 3.15
   soft keywords.
4. **Better error messages**, which come almost for free.

**The risk is exponential backtracking.** A naive recursive-descent parser
that tries alternatives by re-parsing can be exponential. CPython avoids
this with packrat memoization. A hand-written gpython parser must avoid
the same trap, which means:

- Prefer **deterministic dispatch** over trial-and-error. Look at the next
  token and decide.
- Where backtracking is unavoidable, **memoize the failure**, the way
  Pegen does.

**This is the single biggest risk in the hand-written approach and it must
be addressed in the design, not discovered later.**

### Part 8 - The measured scope of the work

| Task | Size | Notes |
|---|---|---|
| Extend the lexer for 3.15 tokens | Medium | `j` suffix, f-string, t-string, soft keywords |
| Hand-write the expression parser | Large | 17 precedence levels, 6 nesting levels, `**` and `await` special cases |
| Hand-write the statement parser | Very large | 129 rules |
| Write a recursive-descent generator | Very large | A new project |
| Write an ASDL-to-Go AST generator | Medium | Derives the AST from `Python.asdl` |
| Port CPython's error-message synthesis | Medium | `pegen_errors.c` equivalent |

**The full hand-written rewrite is roughly the same size as the 3.15
language upgrade itself.** That is the honest estimate, and it is why the
hybrid is recommended.

## Verification

**1. Confirm the lexer is hand-written.**

```bash
grep -c 'func ' parser/lexer.go
grep -c 'yyLex\|yylval' parser/lexer.go
```

Expect many functions and many `yyLex` methods, and no generated-table
mechanics.

**2. Confirm the parser is generated.**

```bash
grep -c 'yyAct\|yyPact\|yyChk' parser/y.go
head -6 parser/y.go
```

Expect the "Code generated by goyacc" comment.

**3. Measure the grammar size.**

```bash
grep -cE '^[a-z_]+ *:' parser/grammar.y
wc -l parser/grammar.y parser/y.go parser/lexer.go
```

Expect 129 rules.

**4. Confirm the number regexes that a hand-written scanner would remove.**

```bash
grep -c 'regexp.MustCompile' parser/lexer.go
```

Expect 6.

**5. Confirm the goyacc dependency is real.**

```bash
go generate ./parser/ 2>&1 | head -3
```

Expect a `goyacc: not found` error on a machine without the tool.

**6. Confirm the soft-keyword problem is specific to soft keywords.**

```bash
grep -nE '"match"|"case"|"type"|"lazy"' parser/grammar.y | head
```

**7. Confirm CPython's grammar has the invalid_* alternatives that
gpython's LALR grammar cannot express.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Grammar/python.gram \
  | grep -c 'invalid_'
```

Expect a non-zero count.

**8. Confirm the operator precedence table.**

```bash
curl -s https://raw.githubusercontent.com/python/cpython/v3.15.2/Doc/reference/expressions.rst \
  | grep -A30 'Operator precedence'
```

## Open questions

These need the user's decision. See the chat summary.
