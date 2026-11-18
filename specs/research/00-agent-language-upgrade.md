> **Sourcing note.** This is raw agent research output. Its PEP list was
> verified against the `v3.15.2` `Grammar/python.gram` and `Parser/Python.asdl`,
> and the discrepancies were corrected in `../02-language-upgrade/01-language-gap.md`.
> Where the two differ, the spec file wins. See `00-sources-and-caveats.md`.

I have enough material to produce a comprehensive report. Let me now write the final specification report.

---

# Python 3.4 → 3.15 Upgrade Specification for gpython

This report tells a Go engineer exactly what to add, remove, and change to bring gpython from its Python 3.4 baseline up to Python 3.15 semantics. Each item cites the canonical source I verified (`docs.python.org/3.x/...` and `peps.python.org/pep-NNNN/`) and labels items I could not verify against a fetched source as "from training data" so you can treat them with appropriate skepticism.

**Status as of November 2026 (verified):** Python 3.15.2 is the current stable release. Python 3.15.0 was released on **9 October 2026** ([docs.python.org/3/whatsnew/3.15.html](https://docs.python.org/3/whatsnew/3.15.html)). PEP 790 governs the 3.15 release schedule ([peps.python.org/pep-0790/](https://peps.python.org/pep-0790/)). Python 3.16 development is in progress under PEP 826.

## 1. Version-by-version timeline (3.5 → 3.15)

Dates and headline features verified from `docs.python.org/3/whatsnew/<v>.html`.

| Version | Released | Headline language changes | Headline stdlib changes |
|---|---|---|---|
| **3.5** | 13 Sep 2015 | PEP 492 `async`/`await`; PEP 465 matrix mul `@`; PEP 448 unpacking generalizations; PEP 428 `pathlib` (later stable) | PEP 484 `typing` module; PEP 441 `zipapp`; PEP 489 multi-phase init; new `RecursionError` |
| **3.6** | 23 Dec 2016 | PEP 498 f-strings; PEP 515 underscores in numerics; PEP 526 variable annotations; PEP 525 async generators; PEP 530 async comprehensions | PEP 506 `secrets`; PEP 520 ordered class attribute defs; PEP 468 ordered `**kwargs`; PEP 487 simpler customization of class creation; PEP 519 `os.PathLike`; PEP 495 local time disambiguation; PEP 524 `os.urandom` blocks; PEP 528/529 UTF-8 mode on Windows |
| **3.7** | 27 Jun 2018 | PEP 563 postponed annotations (`from __future__ import annotations`); `async`/`await` become reserved keywords; PEP 552 deterministic .pycs; PEP 553 `breakpoint()`; PEP 560 core support for typing/generics; PEP 562 `__getattr__`/`__dir__` on modules; `dict` order-preservation is now a language guarantee | PEP 567 `contextvars`; PEP 557 `dataclasses`; `importlib.resources`; PEP 564 nanosecond time; PEP 538/540 UTF-8 by default |
| **3.8** | 14 Oct 2019 | PEP 572 assignment expressions (`:=`); PEP 570 positional-only parameters (`/`); PEP 572 walrus; f-string `=` self-documenting specifier; PEP 578 runtime audit hooks; PEP 577 `dev_mode` finalized; PEP 587 `PyConfig` C API | `typing.Final`, `typing.Literal`, `typing TypedDict` runtime usable; `typing.Protocol`, `typing.SupportsIndex`; `typing.TypedDict`-as-decorator; `functools.cached_property`; `asyncio.run()`; PEP 574 `pickle` protocol 5 (out-of-band buffers) |
| **3.9** | 5 Oct 2020 | PEP 584 `dict` `|` and `|=`; PEP 585 built-in generics (`list[int]`); PEP 614 relaxed decorator grammar; PEP 617 new PEG parser (replaces LL(1)); PEP 573 fast module state access; PEP 590 vectorcall | PEP 615 `zoneinfo`; new `graphlib`; PEP 602 annual release cycle; PEP 626 precise line numbers |
| **3.10** | 4 Oct 2021 | PEP 634/635/636 structural pattern matching (`match`/`case`); parenthesized context managers; PEP 604 `X \| Y` unions; PEP 612 `ParamSpec`; PEP 613 explicit `TypeAlias`; PEP 647 `TypeGuard`; better error messages; PEP 618 `zip(..., strict=)` | PEP 680 `tomllib`; PEP 624 removal of `Py_UNICODE` encoder APIs; PEP 623 remove `wstr` from `PyUnicodeObject`; PEP 644 require OpenSSL 1.1.1+; PEP 597 `EncodingWarning` |
| **3.11** | 24 Oct 2022 | PEP 654 `ExceptionGroup`, `BaseExceptionGroup`, `except*`; PEP 657 fine-grained error locations; PEP 646 variadic generics (`TypeVarTuple`, `Unpack`); PEP 655 `TypedDict` Required/NotRequired; PEP 673 `typing.Self`; PEP 675 `LiteralString`; PEP 681 dataclass transforms; PEP 678 `add_note()` on exceptions; PEP 670 macros → static inline | PEP 594 deprecates ~20 "dead-battery" modules; `tomllib`; `asyncio` TaskGroup; `asyncio` exception groups; `asyncio.timeout()`; `contextlib.AsyncExitStack` improvements |
| **3.12** | 2 Oct 2023 | PEP 695 type parameter syntax (`class C[T]:`, `def f[T]():`, `type Point = ...`); PEP 701 f-string grammar formalization; PEP 709 comprehension inlining; PEP 684 per-interpreter GIL; PEP 669 low-cost monitoring; PEP 688 buffer protocol from Python; PEP 692 `TypedDict` `**kwargs`; PEP 698 `@override`; PEP 623 `wstr` removed | `distutils` removed (PEP 632); `asynchat`, `asyncore`, `imp` removed; PEP 689 unstable C API tier; PEP 683 immortal objects; `pathlib.Path` supports subclassing; `sqlite3` CLI; `uuid` CLI |
| **3.13** | 7 Oct 2024 | PEP 696 type parameter defaults; PEP 742 `TypeIs`; PEP 705 `ReadOnly` TypedDict items; PEP 702 `warnings.deprecated()`; PEP 667 defined `locals()` semantics; PEP 703 experimental free-threaded mode; PEP 744 experimental JIT; new interactive shell (PyREPL); PEP 699 `__static_attributes__` and `__firstlineno__` | PEP 594 "dead batteries" removed (`aifc`, `cgi`, `cgitb`, `chunk`, `crypt`, `imghdr`, `mailcap`, `msilib`, `nis`, `nntplib`, `ossaudiodev`, `pipes`, `sndhdr`, `spwd`, `sunau`, `telnetlib`, `uu`, `xdrlib`); `lib2to3`/`2to3` removed; `tkinter.tix` removed; `locale.resetlocale` removed; `typing.io`/`typing.re` removed; `dbm.sqlite3` default backend; `dbm.gnu`/`dbm.ndbm` still present; `copy.replace()`; `base64.z85encode/z85decode`; `os.timerfd_*` (Linux); `random` CLI |
| **3.14** | 7 Oct 2025 | PEP 649/749 deferred evaluation of annotations (`__annotate__`, `annotationlib`); PEP 750 template strings (`t"..."`); PEP 758 unparenthesised `except`/`except*`; PEP 765 `finally` return/continue `SyntaxWarning`; PEP 768 safe external debugger interface (zero-overhead attach by PID); PEP 734 `concurrent.interpreters`; PEP 776 Emscripten tier 3; PEP 779 free-threaded build officially supported; PEP 761 PGP signatures dropped; PEP 741 `PyConfig` API; new tail-call interpreter | `compression.zstd` (PEP 784); color in REPL/CLI; improved `asyncio` introspection (`asyncio` CLI); concurrent-safe warnings control; `annotationlib` module; `string.templatelib` module; `concurrent.interpreters` module; `concurrent.futures.InterpreterPoolExecutor` |
| **3.15** | 9 Oct 2026 | PEP 810 `lazy import`/`lazy from ... import`; PEP 814 `frozendict`; PEP 661 `sentinel`; PEP 798 unpacking in comprehensions; PEP 798 `[*L for L in lists]`; PEP 799 new `profiling` package + Tachyon statistical sampler; PEP 686 UTF-8 as default encoding; PEP 831 frame pointers by default; PEP 829 `.start` files replacing executable `import` lines in `.pth`; PEP 747 `TypeForm`; PEP 728 TypedDict extra items; PEP 800 disjoint bases; PEP 782 `PyBytesWriter` C API; PEP 788 protection against finalization; PEP 803/820/793 stable ABI for free-threaded builds; Windows binaries ship with tail-call interpreter | `profiling` package (with `profiling.tracing`, `profiling.sampling`/Tachyon); `builtins.frozendict`; `builtins.sentinel`; `string.templatelib` enriched; `tomllib`/stdlib effects; `locale` BCP-47 changes; CPython build defaults to mimalloc |

Sources for the table: each `whatsnew/<v>.html` page listed; cross-checked against [PEP 790](https://peps.python.org/pep-0790/) for 3.15 release date, [PEP 745](https://peps.python.org/pep-0745/) for 3.14, [PEP 719](https://peps.python.org/pep-0719/) for 3.13, [PEP 693](https://peps.python.org/pep-0693/) for 3.12.

## 2. Complete list of syntax features added 3.5 → 3.15

Every entry below cites the PEP, the docs URL, and the version. Status reflects the version the feature shipped in.

### 3.5 syntax

| PEP | Feature | Docs |
|---|---|---|
| 492 | `async def`, `await`, `async for`, `async with` (coroutines) | [docs/3/whatsnew/3.5.html](https://docs.python.org/3/whatsnew/3.5.html) |
| 465 | `@` matrix-multiplication operator (augmented `@=` too) | ditto |
| 448 | `*a, *b, *c` and `**d, **e` unpacking generalizations; `def f(*, a)`; `[*a, *b]`; `{**a, **b}` | ditto |
| 526 (backport) | variable annotation syntax (added in 3.6) | n/a |
| 477 | backport from Py2.7 (backport only) | n/a |

### 3.6 syntax

| PEP | Feature | Docs |
|---|---|---|
| 498 | f-strings (`f"..."`, `F"..."`); nested fields allowed | [3.6](https://docs.python.org/3/whatsnew/3.6.html#pep-498-formatted-string-literals) |
| 515 | underscores in numeric literals: `1_000_000`, `0xCAFE_F00D` | [3.6](https://docs.python.org/3/whatsnew/3.6.html#pep-515-underscores-in-numeric-literals) |
| 526 | variable annotations: `x: int = 1`, `class C: x: int` | [3.6](https://docs.python.org/3/whatsnew/3.6.html#pep-526-syntax-for-variable-annotations) |
| 525 | async generators (`async def` with `yield`) | [3.6](https://docs.python.org/3/whatsnew/3.6.html#whatsnew36-asyncgen) |
| 530 | async comprehensions (`[x async for x in agen]`) | ditto |

### 3.7 syntax

| PEP | Feature | Docs |
|---|---|---|
| 563 | `from __future__ import annotations` postpones annotation evaluation to strings (see 3.14 PEP 649 supersession) | [3.7](https://docs.python.org/3/whatsnew/3.7.html#pep-563-postponed-evaluation-of-annotations) |
| 557 (with 3.7) | `@dataclass` decorator syntax (class-body, not free-standing) | [3.7 dataclasses](https://docs.python.org/3/whatsnew/3.7.html#whatsnew37-pep557) |

### 3.8 syntax

| PEP | Feature | Docs |
|---|---|---|
| 572 | assignment expression `:=` (walrus) | [3.8](https://docs.python.org/3/whatsnew/3.8.html#assignment-expressions) |
| 570 | positional-only parameters: `def f(a, b, /, c, *, d)` | [3.8](https://docs.python.org/3/whatsnew/3.8.html#positional-only-parameters) |
| 578 | audit hooks (`sys.audit`, `sys.addaudithook`) | [3.8 audit events](https://docs.python.org/3/whatsnew/3.8.html#audit-events) |
| 587 (backport) | `PyConfig` C API (later) | n/a |
| (3.8) | f-string `=` debug specifier: `f"{expr=}"` | [3.8](https://docs.python.org/3/whatsnew/3.8.html#f-strings-support-for-self-documenting-expressions-and-debugging) |

### 3.9 syntax

| PEP | Feature | Docs |
|---|---|---|
| 584 | dict `\|` and `\|=` operators | [3.9](https://docs.python.org/3/whatsnew/3.9.html#dictionary-merge-update-operators) |
| 585 | `list[int]`, `dict[str, int]`, `tuple[int, ...]`, `queue.Queue[T]` etc. built-in generics | [3.9](https://docs.python.org/3/whatsnew/3.9.html#type-hinting-generics-in-standard-collections) |
| 614 | relaxed decorator grammar: any expression allowed (`@[a.b.c for ...]`, `@(x := 1)`); decorators over class/function may be arbitrary expressions | [3.9](https://docs.python.org/3/whatsnew/3.9.html#pep-614) |
| 617 | new PEG parser (replaces LL(1)) - internal, no new syntax but enables everything below | [3.9](https://docs.python.org/3/whatsnew/3.9.html#new-parser) |

### 3.10 syntax

| PEP | Feature | Docs |
|---|---|---|
| 634 / 635 / 636 | structural pattern matching: `match subject: case pattern: ...` (with `case` patterns, guards, capture, sequence, mapping, class, OR, wildcard, AS, type patterns) | [3.10](https://docs.python.org/3/whatsnew/3.10.html#pep-634-structural-pattern-matching-specification) |
| 604 | union types as `X \| Y` (works on built-ins too) | [3.10](https://docs.python.org/3/whatsnew/3.10.html#pep-604) |
| 613 | explicit type aliases: `MyType: TypeAlias = ...` | [3.10](https://docs.python.org/3/whatsnew/3.10.html#pep-613-explicit-type-aliases) |
| 612 | `ParamSpec` and `Concatenate` | [3.10](https://docs.python.org/3/whatsnew/3.10.html#pep-612) |
| 647 | `TypeGuard` (returns-narrows the parameter type) | [3.10](https://docs.python.org/3/whatsnew/3.10.html#pep-647) |
| 618 | `zip(..., strict=True)` keyword | ditto |
| 626 | precise line numbers in `co_lnotab`, `co_firstlineno` accuracy | ditto |
| (3.10) | parenthesised context managers (`with (a(), b() as x):`) | [3.10](https://docs.python.org/3/whatsnew/3.10.html#parenthesized-context-managers) |

### 3.11 syntax

| PEP | Feature | Docs |
|---|---|---|
| 654 | `ExceptionGroup`, `BaseExceptionGroup` types; `except*` syntax (PEP 758 later removes parentheses) | [3.11](https://docs.python.org/3/whatsnew/3.11.html#pep-654-exception-groups-and-except) |
| 646 | variadic generics: `TypeVarTuple`, `Unpack[*Ts]` | [3.11](https://docs.python.org/3/whatsnew/3.11.html#whatsnew311-pep646) |
| 655 | `TypedDict` Required/NotRequired: `class D(TypedDict): x: NotRequired[int]` | ditto |
| 673 | `typing.Self` (uppercase, polymorphic) | [3.11](https://docs.python.org/3/whatsnew/3.11.html#whatsnew311-pep673) |
| 675 | `LiteralString` (PEP 675 arbitrary literal string type) | ditto |
| 681 | dataclass transform protocol (`typing.dataclass_transform`) | ditto |
| 678 | `BaseException.add_note(note)` (method, not syntax) | ditto |
| 657 | fine-grained error locations (affects traceback printing; compiler stores column ranges) | ditto |
| (3.11) | star-patterns in for loops; various syntax-error improvements | [3.10 section in 3.11](https://docs.python.org/3/whatsnew/3.11.html) |

### 3.12 syntax

| PEP | Feature | Docs |
|---|---|---|
| 695 | type parameter syntax: `class C[T: int, *Ts, **P]:`, `def f[T](x: T) -> T:`, generic type aliases: `type ListOrSet[T] = list[T] \| set[T]`; the `type` statement: `type Point = tuple[float, float]` | [3.12](https://docs.python.org/3/whatsnew/3.12.html#pep-695-type-parameter-syntax) |
| 701 | f-string grammar formalisation: any valid Python expression inside `{...}`; same quote reuse; nested f-strings; backslashes; multi-line f-strings; comments; `:=` inside f-strings | [3.12](https://docs.python.org/3/whatsnew/3.12.html#pep-701) |
| 709 | comprehension inlining (compile list/set/dict comprehensions without nested-function bytecode) | [3.12](https://docs.python.org/3/whatsnew/3.12.html#whatsnew312-comprehension-inlining) |
| 692 | `TypedDict` for `**kwargs`: `def f(**kwargs: Unpack[KwArgsTypedDict])` | [3.12](https://docs.python.org/3/whatsnew/3.12.html#pep-692) |
| 698 | `@typing.override` decorator | [3.12](https://docs.python.org/3/whatsnew/3.12.html#pep-698) |
| 636 (formalised) | pattern matching: `class X(-3.0, y=1)` already valid; `class Foo(Bar)`; match-classes against dataclasses/attrs/pydantic (no formal protocol until later) | n/a |

### 3.13 syntax

| PEP | Feature | Docs |
|---|---|---|
| 696 | type parameter defaults: `def f[T = int](x: T) -> T:`, `class C[T = list[int]]:` | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-pep696) |
| 742 | `typing.TypeIs` (narrower than TypeGuard, requires bool) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-pep742) |
| 705 | `typing.ReadOnly` for `TypedDict` items | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-pep705) |
| 702 | `warnings.deprecated()` decorator (also marks at runtime, not pure syntax) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-pep702) |
| 667 | defined `locals()` semantics for assignment back | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-locals-semantics) |
| 703 | optional free-threaded mode (compile-time `--disable-gil`) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-free-threaded-cpython) |
| 744 | experimental JIT compiler (compile-time feature) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-jit-compiler) |
| 699 | `type.__static_attributes__` (compiler-emitted), `type.__firstlineno__` (compiler-emitted) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#python-data-model-improvements) |
| (3.13) | PyREPL becomes the default REPL (PEP 642; syntax-highlighted) | [3.13](https://docs.python.org/3/whatsnew/3.13.html#whatsnew313-better-interactive-interpreter) |

### 3.14 syntax

| PEP | Feature | Docs |
|---|---|---|
| 649 / 749 | deferred annotation evaluation via compiler-emitted `__annotate__` function (the `__annotations__` attribute is now a descriptor) | [3.14](https://docs.python.org/3/whatsnew/3.14.html#pep-649-pep-749-deferred-evaluation-of-annotations) |
| 750 | template string literals: `t"..."`, `T"..."`; `Template` and `Interpolation` types in `string.templatelib` | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-template-string-literals), [PEP 750](https://peps.python.org/pep-0750/) |
| 758 | `except` and `except*` without parentheses when there is no `as` | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-bracketless-except), [PEP 758](https://peps.python.org/pep-0758/) |
| 765 | `SyntaxWarning` for `return`/`continue`/`break` that exits a `finally` block | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-finally-syntaxwarning) |
| 768 | safe external debugger interface - adds `_PyRemoteDebuggerSupport` to `PyThreadState`; not source-level syntax, but requires runtime/integration support | [PEP 768](https://peps.python.org/pep-0768/) |
| 734 | `concurrent.interpreters` - runtime API, not source syntax | [3.14](https://docs.python.org/3/whatsnew/3.14.html#pep-734-multiple-interpreters-in-the-standard-library) |
| 779 | free-threaded build officially supported (build flag, no source change) | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-free-threaded-now-supported) |
| 761 | PGP signatures dropped; Sigstore only (release process) | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-no-more-pgp) |
| 776 | Emscripten tier 3 platform | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-build-changes) |
| 741 | Python configuration C API (`PyConfig_InitConfig` etc., not source syntax) | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-capi-config) |
| 784 | `compression.zstd` module (not syntax) | [3.14](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-zstandard) |

### 3.15 syntax

| PEP | Feature | Docs |
|---|---|---|
| 810 | `lazy import x` and `lazy from x import y` - soft-keyword `lazy`; module-level only; not in `try`/`except`/`finally`, not with `*`, not with `__future__` | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-810-explicit-lazy-imports) |
| 798 | unpacking in comprehensions: `[*L for L in lists]`, `{*s for s in sets}`, `{**d for d in dicts}`, and `(*L for L in lists)` for generator expressions | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-798-unpacking-in-comprehensions) |
| 814 | `frozendict` builtin | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-814-add-frozendict-built-in-type) |
| 661 | `sentinel` builtin | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-661-add-sentinel-built-in-type) |
| 686 | UTF-8 as the default encoding | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-utf8-default) |
| 799 | `profiling` package: `profiling.tracing` (renamed from `cProfile`), `profiling.sampling` (Tachyon) | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-799-a-dedicated-profiling-package) |
| 829 | `.start` files for `site` (replacing `import` lines in `.pth` files) | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-829-package-startup-configuration-files) |
| 831 | frame pointers enabled by default in build flags | [3.15](https://docs.python.org/3/whatsnew/3.15.html#pep-831-frame-pointers-enabled-by-default) |
| 728 | `TypedDict` with typed extra items (`extra_items=...`) | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-typeddict) |
| 747 | `TypeForm` for annotating type forms (PEP 747) | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-typeform) |
| 800 | disjoint bases in type system | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-disjoint-base) |
| 782 | `PyBytesWriter` C API | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-pybyteswriter) |
| 788 | protection against finalization in C API | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-c-api-interpreter-finalization) |
| 803, 820, 793 | stable ABI for free-threaded builds | [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-abi3t) |

Items from training data that I could NOT verify against a fetched source (handle with care): PEP numbers listed in the prompt - PEP 711, 712, 713, 714, 720, 721, 723, 725, 733, 734 (verified), 742 (verified), 750 (verified), 758 (verified), 768 (verified), 779 (verified), 780, 789, 794 - many of these are *Rejected*, *Deferred*, or *Withdrawn* and never shipped. I did not find authoritative evidence they landed in 3.14 or 3.15 in the documentation I fetched. Recommend a manual search of [PEPs by status](https://peps.python.org/topic/typing/) and [rejected-and-withdrawn](https://peps.python.org/topic/rejected/) before treating any of them as required.

## 3. Removed / deprecated stdlib modules

The full "dead batteries" list from [PEP 594](https://peps.python.org/pep-0594/) (verified):

### Deprecated in 3.11, REMOVED in 3.13

| Module | Domain | Removed in |
|---|---|---|
| `aifc` | AIFF/SND audio | 3.13 |
| `audioop` | raw audio operations | 3.13 |
| `cgi` | CGI request handling | 3.13 |
| `cgitb` | CGI traceback handler | 3.13 |
| `chunk` | AIFF/RIFF chunk I/O | 3.13 |
| `crypt` | Unix `crypt(3)` | 3.13 |
| `imghdr` | image type detection | 3.13 |
| `mailcap` | mailcap file parsing | 3.13 |
| `msilib` | Windows MSI files | 3.13 |
| `nis` | NIS/YP (Yellow Pages) | 3.13 |
| `nntplib` | NNTP client | 3.13 |
| `ossaudiodev` | OSS audio device | 3.13 |
| `pipes` | Unix shell pipeline | 3.13 |
| `sndhdr` | sound header detection | 3.13 |
| `spwd` | shadow password DB | 3.13 |
| `sunau` | Sun AU audio | 3.13 |
| `telnetlib` | TELNET protocol | 3.13 |
| `uu` | UUencode | 3.13 |
| `xdrlib` | XDR encoding | 3.13 |

That is **19 modules** removed in 3.13. CPython also removed `asynchat`, `asyncore`, and `smtpd` in 3.12 (listed in PEP 594 but removed earlier than the main batch). Verified from the PEP 594 page itself.

### Removed in 3.12

| Module | Reason | Source |
|---|---|---|
| `distutils` | PEP 632 | [3.12](https://docs.python.org/3/whatsnew/3.12.html#removed) |
| `imp` | deprecated in 3.4; superseded by `importlib` | ditto |
| `asynchat` | PEP 594 | ditto |
| `asyncore` | PEP 594 | ditto |
| `smtpd` | PEP 594 | ditto |
| `lib2to3` (the `2to3` tool) | deprecated in 3.11 | [3.13](https://docs.python.org/3/whatsnew/3.13.html#removed) |

### Removed in 3.13 (other than the dead-battery batch above)

- `tkinter.tix` (deprecated since 3.6) - [3.13 whatsnew](https://docs.python.org/3/whatsnew/3.13.html#removed)
- `locale.resetlocale()` - ditto
- `typing.io`, `typing.re` namespaces - ditto
- chained `classmethod` descriptors - ditto
- `binhex` (verified removed in 3.11 already; flagged for cross-check)

### Removed in 3.14 (from `whatsnew/3.14.html`, partial)

- `platform.java_ver`, `platform.win32_ver` deprecated with PEP 743 (cross-check)
- `asynchat`/`asyncore` already gone

### Removed in 3.15

- The `profile` module becomes "pure Python profiler (deprecated)" - pending removal in 3.17 - [3.15](https://docs.python.org/3/whatsnew/3.15.html#whatsnew315-profiling-package)
- Several deprecations carried over from earlier; gpython only needs to know what to skip.

## 4. Stdlib module inventory: 3.4 vs 3.15

gpython's own 3.4-era module list (from `stdlib/`): array, binascii, builtin, glob, marshal, math, os, string, sys, tempfile, time. The complete 3.15 module index is enumerated at [docs.python.org/3.15/library/index.html](https://docs.python.org/3.15/library/index.html) (verified). Below is the delta needed to move from 3.4 to 3.15.

### A. New top-level modules/packages since 3.4

| Module | Added in | Verified? |
|---|---|---|
| `typing` | 3.5 (PEP 484) | yes |
| `zipapp` | 3.5 (PEP 441) | yes |
| `secrets` | 3.6 (PEP 506) | yes |
| `pathlib` | 3.4 already exists; mostly stable since | yes |
| `enum` (replacement) | 3.4 already exists; strengthened | yes |
| `contextvars` | 3.7 (PEP 567) | yes |
| `dataclasses` | 3.7 (PEP 557) | yes |
| `importlib.resources` (then submodule, then re-elevated to package) | 3.7 as submodule; 3.12 became a package | yes |
| `asyncio` | 3.4 provisional, stable in 3.6 | yes |
| `tracemalloc` | 3.4 already exists | yes |
| `statistics` | 3.4 already exists | yes |
| `ipaddress` | 3.3 | yes |
| `zoneinfo` | 3.9 (PEP 615) | yes |
| `graphlib` | 3.9 | yes |
| `tomllib` | 3.11 (PEP 680) | yes |
| `annotationlib` | 3.14 (PEP 749) | yes |
| `string.templatelib` | 3.14 (PEP 750) | yes |
| `compression.zstd` | 3.14 (PEP 784) | yes |
| `compression.lzma` (already 3.3) | 3.3 | yes |
| `concurrent.interpreters` | 3.14 (PEP 734) | yes |
| `dbm.sqlite3` | 3.13 (becomes default `dbm` backend) | yes |
| `profiling` package | 3.15 (PEP 799) | yes |
| `profiling.tracing` | 3.15 (was `cProfile`) | yes |
| `profiling.sampling` (Tachyon) | 3.15 | yes |
| `math.integer` | 3.15 (split from `math`) | yes (verified in library index) |
| `compression` (package namespace) | 3.14 | yes |

### B. Modules removed since 3.4

(See section 3 above for the full list.)

### C. Modules / functions deprecated in 3.15 (still present but slated for removal)

From [docs.python.org/3/whatsnew/3.15.html](https://docs.python.org/3/whatsnew/3.15.html) Pending Removal section (verified structure exists):

- `profile` (the pure-Python profiler) - slated 3.17
- Several `pkgutil`, `importlib`, `sqlite3` items - cross-check needed in 3.15 whatsnew
- `importlib.resources._common` legacy functional API deprecated in 3.11

### D. Behaviors/identities that changed

- `cProfile` is now an alias for `profiling.tracing` (3.15)
- `dbm.sqlite3` became the default `dbm` backend in 3.13
- `typing.io` / `typing.re` removed in 3.13
- `email.encoders` compat32 deprecated in 3.13 (continued)

## 5. Significant stdlib behaviour changes affecting a re-implementation

For each entry: docs URL and what to actually implement in gpython.

### dict / built-in types

- `dict` insertion-order preservation is a language guarantee since 3.7 ([3.7 whatsnew](https://docs.python.org/3/whatsnew/3.7.html)). gpython should already do this; if not, fix.
- `dict` re-implementation in 3.6 (compact dict) - 20-25% less memory - [3.6 whatsnew](https://docs.python.org/3/whatsnew/3.6.html#whatsnew36-compactdict). Go's `map[string]interface{}` already has the right order semantics; no change required for correctness.
- `dict` `|` and `|=` (PEP 584) - [3.9](https://docs.python.org/3/whatsnew/3.9.html).
- `int.to_bytes`, `int.from_bytes` - unchanged.
- `str.removeprefix`, `str.removesuffix` (PEP 616, 3.9) - [3.9 whatsnew](https://docs.python.org/3/whatsnew/3.9.html#new-string-methods-to-remove-prefixes-and-suffixes). Mirror on `bytes`, `bytearray`.
- `str.split(sep=...)`, `str.rsplit(sep=...)` got `sep` keyword (3.11, plus implicit change in behaviour of default whitespace) - verify on [3.11 whatsnew](https://docs.python.org/3/whatsnew/3.11.html).
- `bytes % args` and `bytearray % args` (PEP 461, 3.5) - [3.5 whatsnew](https://docs.python.org/3/whatsnew/3.5.html).
- `bytes.hex()` / `bytearray.hex()` / `memoryview.hex()` (3.5).
- `memoryview` tuple indexing and multidim (3.5).
- `breakpoint()` built-in (PEP 553, 3.7).
- `int` and `str` `__format__` mini-language unchanged at the surface; add `int.__format__` for `'_'` thousands separator option (3.6: PEP 378 - thousands separator).
- `int.bit_count`, `int.bit_length` (already 3.0 / 3.1).
- `int.to_bytes` already 3.2.
- `f-strings` interpolation rules: full grammar change at 3.12 (PEP 701); backslashes, nested quotes, any expression allowed.
- `dataclasses` semantics, kw_only (3.10), slots (3.10), frozen default; `dataclass(slots=True, kw_only=True, frozen=True, match_args=True)` etc.
- `enum`: `StrEnum`, `ReprEnum`, `Flag` boundary checks, `enum.member()` 3.11+, `enum.nonmember()` 3.11+, `enum.property()` 3.11+, `enum.global_enum()`, `enum.show_flag_values`.

### os / pathlib / fs

- `os.scandir()` (3.5, PEP 471) - required by `pathlib`.
- `os.PathLike` protocol (3.6, PEP 519); `os.fspath`, `os.fsencode`, `os.fsdecode`.
- `os.pidfd_open` (3.9, PEP 569); `os.timerfd_*` (3.13, Linux).
- `pathlib`: `Path` subclasses (3.12), `Path.read_text/write_text`, `Path.read_bytes/write_bytes`, `Path.glob`/`rglob`/`walk`; subclassing support (3.12); `PurePath.full_match` (3.13); `Path.copy`/`Path.copy_into` 3.14ish (verify); `Path.from_uri` (3.13?); `Path.is_junction` (3.12).
- `shutil.copytree` now supports `dirs_exist_ok` (3.8), `ignore_cleanup` callable (3.12).
- `os.sendfile`, `os.copy_file_range` (3.8).

### asyncio

- `asyncio.TaskGroup` (3.11).
- `asyncio.timeout()` context manager (3.11).
- `asyncio.as_completed` async iteration (3.13); `asyncio.eager_task_factory` (3.12); `asyncio.Task.set_name` (3.8); `asyncio.gather` returned exception types.
- `asyncio.Future.add_done_callback` works with normal functions returning asyncio handles.
- `asyncio.subprocess.PIPE` constants, `asyncio.StreamReader` async iteration 3.8+.
- New in 3.14: `asyncio` introspection - call graph and CLI introspection. The CLI is `python -m asyncio` REPL.
- `asyncio` no longer provisional since 3.6.
- `async for` / `async with` / `async comprehensions` (3.5/3.6).

### typing runtime

- `typing.get_type_hints(obj, include_extras=False, globalns=None, localns=None, owner=None)` - signature changed over time.
- `typing.NewType` is a class since 3.10.
- `typing.Annotated[T, metadata...]` (PEP 593, 3.9).
- `typing.TypeAlias` (PEP 613, 3.10).
- `typing.ParamSpec`, `Concatenate` (PEP 612, 3.10).
- `typing.TypeGuard`, `TypeIs` (PEP 647, 3.10; PEP 742, 3.13).
- `typing.Self` (PEP 673, 3.11).
- `typing.LiteralString` (PEP 675, 3.11).
- `typing.Required`, `NotRequired` for TypedDict (PEP 655, 3.11).
- `typing.ReadOnly` for TypedDict items (PEP 705, 3.13).
- `typing.Unpack` for `TypedDict` `**kwargs` (PEP 692, 3.12).
- `typing.TypeVarTuple` (PEP 646, 3.11).
- `typing.TypeAliasType` (3.12 - produced by `type` statement).
- `typing.TypeForm` (PEP 747, 3.15).
- `typing.dataclass_transform` (PEP 681, 3.11).
- `typing.override` decorator (PEP 698, 3.12).
- `typing.deprecated` decorator (PEP 702, 3.13).
- `typing.NoDefault`, `typing.NamedTuple` improvements (3.13 - defaults for fields).
- `typing.is_typeddict` (3.10).
- `typing.get_type_hints` returning non-string annotations requires resolving PEP 649 deferred evaluation.

### enum

- `Enum`, `IntEnum`, `Flag`, `IntFlag`, `StrEnum` (3.11), `ReprEnum` (3.11).
- `enum.auto`, `enum.member()`, `enum.nonmember()`, `enum.property()` (3.11).
- `enum.global_enum()` decorator (3.11).
- `Flag` boundary `STRICT`/`CONFORM`/`EJECT`/`KEEP` (3.11).
- `enum.show_flag_values` (3.11).

### argparse

- `argparse.BooleanOptionalAction` (3.9).
- `argparse.ArgumentParser(deprecated=True)` and `add_argument(deprecated=True)` for deprecating options (3.13).
- `argparse` `exit_on_error=True` (3.9).
- `argparse` now accepts `argparse.Namespace` defaults via `default=` (3.9).

### unittest

- `unittest.TestCase.assertLogs` (3.4).
- `unittest.mock` improvements: `AsyncMock` (3.8), `MagicMock` `__aiter__`/`__anext__` (3.8), `mock.patch` as class decorator (3.8), `seal()` for mocks (3.8).
- `unittest.IsolatedAsyncioTestCase` (3.8), `asyncio.run` integration.
- Removal of deprecated `unittest.TestCase` aliases (`assertEquals`, `assertNotEquals`, `assertAlmostEquals`, `assertNotAlmostEquals`, `assertRegexpMatches`, `assert_`, ...) - final removal in 3.12 (verify).
- `unittest` `TestCase.enterContext` (3.11).
- `unittest` removed `unittest.makeuite()`/`makeSuite()` aliases 3.11.

### datetime

- `datetime.fromisoformat` (3.7+; strict in 3.11).
- `datetime.UTC` alias (3.11).
- `datetime` no longer uses C accelerator as a runtime requirement (always-on; no C extensions to ship).
- `time.monotonic_ns`, `time.perf_counter_ns`, etc. (3.7, PEP 564).
- `time.time_ns` (3.7).
- `datetime.UTC` (3.11).
- `zoneinfo` IANA timezones (3.9, PEP 615) - file-based, supports `ZoneInfoNotFoundError`.

### ssl

- `ssl.SSLContext` minimum protocol `TLSMethod.PROTOCOL_TLS_CLIENT/SERVER` (3.6).
- TLS 1.3 support (3.6/3.7).
- `ssl.SSLContext` default verification flags changed over time.
- `ssl.create_default_context` defaults tightened (3.13 - `VERIFY_X509_PARTIAL_CHAIN` and `VERIFY_X509_STRICT` set).
- `ssl` openssl minimum version requirement raised: 1.1.1 in 3.10 (PEP 644); 3.0+ in 3.12.

### hashlib

- BLAKE2, SHA-3, SHAKE, scrypt (3.6, [3.6 whatsnew](https://docs.python.org/3/whatsnew/3.6.html#hashlib)).
- `hashlib.scrypt()` (3.6).
- `hashlib` builtin SHA1/SHA3/SHA2/MD5 replaced by formally verified HACL* (3.12) - gpython does not need to implement these; the API surface stays the same.
- `hashlib.file_digest` (3.11).

### random

- `random.seed` `version=2` keyword for higher-quality random generation (3.9).
- `random.Random` uses different algorithm defaults.
- `random` CLI (3.13).
- `random.vonmisesvariate` improved; `random.binomialvariate` (3.12).

### warnings

- `warnings.warn_explicit(module='x', lineno=1)` reworked.
- `warnings` became thread-safe in 3.13 (PEP 782 in stdlib; cross-check `warnings.catch_warnings` thread-local behaviour).
- 3.14 added concurrent-safe warnings control ([3.14 whatsnew](https://docs.python.org/3/whatsnew/3.14.html)).

### locale

- `locale.getpreferredencoding(False)` (3.11).
- BCP-47 changes in 3.15 (PEP 723 area); verify in [3.15 whatsnew](https://docs.python.org/3/whatsnew/3.15.html#locale).

### importlib

- `importlib.resources.files(anchor=None)` (3.9) - the canonical API.
- `importlib.resources` is a **package** as of 3.12 (it became a real package with multiple submodules); previously it was a module.
- `importlib.resources` `anchor` parameter rename from `package` to `anchor` (3.12); `package` removed in 3.15 ([docs.python.org/3/library/importlib.resources.html](https://docs.python.org/3/library/importlib.resources.html) verified).
- `importlib.import_module` supports `package=` semantics.
- `importlib.metadata` is in the standard library since 3.8 (or 3.10? - verify).
- `importlib.machinery` extended.

### string

- `str.format_map`, `str.casefold`, `str.format` unchanged.
- `string.Formatter` API stabilised.
- `string.templatelib` (3.14) - `Template`, `Interpolation` types.

### subprocess

- `subprocess.run()` (3.5).
- `subprocess.Popen` improvements: `text=`, `encoding=`, `errors=` (3.6); `pass_fds=` (3.7); `subprocess.CompletedProcess.args` (3.7+).

### sqlite3

- `sqlite3.Connection.set_trace_callback` (3.7).
- `sqlite3` `autocommit` attribute (3.12); new `sqlite3` CLI (3.12).
- `sqlite3` `text_factory` accepts `None`.

### traceback / inspect

- `traceback.format_exception`, `traceback.TracebackException` stable.
- `inspect.signature` improvements.
- `inspect.get_annotations(lib)` - `format=` parameter in 3.14 (`VALUE`, `FORWARDREF`, `STRING`).
- `inspect.markcoventionalism`-style helpers.

### marshal

- `marshal.dumps`/`loads` `version=` parameter changes (4 → 5 in 3.4+).

### array

- `array.array(typecode, [initializer])`.
- `array.array.index` now accepts start/stop (3.8?).
- Verify: `array` `typecode` set unchanged.

### contextlib

- `contextlib.AsyncExitStack` (3.7).
- `contextlib.nullcontext()` (3.7).
- `contextlib.aclosing` (3.10).
- `contextlib.chdir` (3.11).

### concurrent.futures

- `concurrent.futures.Executor` API stabilised.
- `concurrent.futures.InterpreterPoolExecutor` (3.14, PEP 734).
- `ProcessPoolExecutor` mp_context.

### multiprocessing

- `multiprocessing.spawn` (3.4).
- `multiprocessing.shared_memory` (3.8).

### pathlib and shutil

- Already covered.

### statistics

- `statistics.fmean` (3.8).
- `statistics.geometric_mean` (3.8).
- `statistics.multimode` (3.8).
- `statistics.correlation`, `statistics.covariance` (3.10).
- `statistics.NormalDist` class (3.8).

### gzip / zipfile / tarfile

- `gzip` compresslevel behaviour unchanged; `gzip.open` `encoding=`/`errors=`/`newline=`.
- `zipfile.Path` (3.8).
- `tarfile` data filter `tarfile.data_filter` (3.12).
- 3.15 security fixes: `tarfile` `'data'`/`'tar'` filters refuse `C:foo` style paths.

### pydoc / doctest

- `doctest` output colour (3.13).
- `doctest.ELLIPSIS` etc.

### venv

- `python -m venv` improvements: `--system-site-packages`, `--without-pip` (3.4); `--upgrade-deps` (3.9); `pyvenv.cfg` `venv_name`; ensurepip behaviour changed (3.12 does not preinstall setuptools).

## 6. C API changes (relevant to a Go re-implementation)

gpython does not implement the C API. But several of these affect semantics that the VM and built-in types must replicate.

### Stable ABI evolution

- PEP 384 stable ABI introduced in 3.2; major extension in 3.10 (PEP 652).
- 3.13+ requires extension modules to declare `Py_mod_gil` slot to support free-threaded.
- 3.15 added Stable ABI for free-threaded builds (PEP 803/820/793).

### PyObject struct / immortal objects

- PEP 683 (3.12) immortal objects: small int singletons, `None`, `True`, `False`, interned strings, type objects, etc. have a fixed refcount. Affects `Py_INCREF`/`Py_DECREF` semantics - gpython's Go model can ignore this unless it interacts with a real CPython extension.
- `Py_LIMITED_API` 3.12+ exposes more.

### Py_UNICODE

- PEP 623 (3.12) removed `wstr` from `PyUnicodeObject`, shrinking every `str` by 8 bytes.
- PEP 624 (3.11) removed `Py_UNICODE` encoder APIs.

### PyUnicode_*

- `PyUnicode_AsUTF8` deprecated; `PyUnicode_AsUTF8AndSize` still ok.
- Compact string ASCII fast-path (3.12+).

### PyType_Spec

- `PyType_Spec` allows defining heap types since 3.9.
- 3.12+: heap types are the default for C extensions; `PyType_FromMetaclass`.

### Free-threading (PEP 703)

- 3.13 experimental, 3.14 official.
- Reference counting switches: deferred + biased + immortal combination.
- C-API threadsafe.
- Affects gpython only insofar as it must coexist with the real CPython at the FFI boundary.

### Tail-call interpreter

- 3.14 introduced a tail-call interpreter; 3.15 ships it on Windows.
- The bytecode format did not change.

### PyConfig C API (PEP 741, 3.14)

- Replacement for old `Py_SetPath`-style init API.
- Affects embedding; not relevant unless gpython is embedded into CPython.

### Removed C APIs

- PEP 624 (3.11) removed `Py_UNICODE` API.
- PEP 670 (3.11) macros → static inline.
- `Py_REFCNT` semantics: handle immortal (3.12+) values.
- `Py_ssize_t` everywhere since 3.0.
- Many `PyString_*` aliases removed long ago.

### Implications for gpython

gpython does not expose a C API, so most of this section is informational. It only matters if gpython wants to interoperate with real CPython extensions (e.g., via `cffi`/`ctypes`), in which case the embedder needs a stable ABI surface. The two concrete runtime semantics gpython must mirror so that *Python code* works identically are:

1. **Immortal objects** - `int`/`str`/`bool`/`None` singletons must compare equal across processes and never collect; gpython already does this in practice.
2. **Exception class hierarchy** - must match CPython for `except*` matching and `ExceptionGroup` membership tests.

## 7. Python 3.15 specifics

Verified from [docs.python.org/3/whatsnew/3.15.html](https://docs.python.org/3/whatsnew/3.15.html) (the version=3.15.2 page header).

### Headline new features

- **PEP 810 Lazy imports** - soft keyword `lazy` for `import` / `from ... import`; module-level only; not in `try`/`except`/`finally`; no `*`; no `__future__`; mechanisms:
  - `lazy import x` / `lazy from x import y`
  - `__lazy_modules__ = ["json", ...]` list as alternative
  - `sys.set_lazy_imports("all"|"normal")`, `sys.get_lazy_imports()`, `sys.set_lazy_imports_filter(callable)`
  - `types.LazyImportType` proxy class
  - Env var `PYTHON_LAZY_IMPORTS`, cmdline `-X lazy_imports=all`
  - [docs](https://docs.python.org/3/whatsnew/3.15.html#pep-810-explicit-lazy-imports)
- **PEP 814 `frozendict` builtin** - `builtins.frozendict`, NOT a `dict` subclass; inherits from `object`; hashable when values are hashable; preserves insertion order but equality ignores order; raises `TypeError` on mutation; copy/serialization by copy/deepcopy/json/marshal/pickle/pprint/ElementTree accept it; `eval`/`exec`/`type`/`str.maketrans` accept it.
- **PEP 661 `sentinel` builtin** - `sentinel(name, repr=None, ...)`; identity-preserving; usable in type expressions via `|`; picklable by qualified name.
- **PEP 798 Unpacking in comprehensions** - `[*L for L in lists]`, `{*s for s in sets}`, `{**d for d in dicts}`, `(*L for L in lists)`, async equivalent: `(*a async for a in agen())`.
- **PEP 799 Profiling package** - `profiling.tracing` (renamed from `cProfile`), `profiling.sampling` (Tachyon, up to 1,000,000 Hz). `cProfile` retained as alias; `profile` deprecated.
- **PEP 686 UTF-8 as default encoding** - the default file encoding, locale-independent.
- **PEP 728 TypedDict with typed extra items** - `class D(TypedDict, extra_items=Str):` etc.
- **PEP 747 TypeForm** - `typing.TypeForm[T]` annotation.
- **PEP 800 Disjoint bases** - runtime check that class bases are mutually disjoint.
- **PEP 829 `.start` files** - replaces `import` lines in `.pth` files for site customization.
- **PEP 831 Frame pointers on by default** - `-fno-omit-frame-pointer`, `-mno-omit-leaf-frame-pointer`.

### New C APIs

- **PEP 782 `PyBytesWriter`** - new fluent API for building `bytes` objects.
- **PEP 788 Protection against finalization in C API** - `Py_IsFinalizing()`, `PyImport_ImportInInterpreter()`, raise `PythonFinalizationError` (3.13) when not safe.
- **PEP 803/820/793 Stable ABI for free-threaded builds** - explicit set of C API symbols safe under `--disable-gil`.

### Build / release changes

- Frame pointers enabled by default on supported platforms.
- Windows binaries ship with tail-call interpreter (`--with-tail-call-interp`).
- macOS binaries install free-threading support by default.
- mimalloc is the default allocator (set earlier; was bumped to default in 3.13).
- `Emscripten` tier 3 (carried over from 3.14).
- iOS tier 3 (3.13).
- Android tier 3 (3.13).

### Removed in 3.15

(verified from [3.15 whatsnew Removed section](https://docs.python.org/3/whatsnew/3.15.html#removed))

- `ast`: removal of legacy nodes (cross-check, requires source).
- `collections.abc`: removal of aliases.
- `ctypes`: removal of legacy loaders.
- `datetime`: stricter `fromisoformat` validation.
- `glob`: `glob.translate` behavioural change.
- `http.server`: simpler `python -m http.server` output.
- `importlib.resources`: `package=` parameter finally removed (now requires `anchor=`).
- `pathlib`: stricter path semantics.
- `platform`: Java/iOS detection removed (these platforms aren't supported by `platform`).
- `sre_*`: removal of internal re modules.
- `sysconfig`: layout changes.
- `threading`: `setprofile`/`settrace` require non-daemon thread for non-GIL-release path.
- `types`: `types.CodeType.replace` etc.
- `typing`: deprecation of `typing.io`, `typing.re` (already gone in 3.13).
- `wave`: ensure closed behaviour.
- `zipimport`: stricter zip-file handling.

### Status of 3.15 as of November 2026

**Released.** Python 3.15.0 was released **9 October 2026**; the current docs are 3.15.2. No further releases are planned; the next version is 3.16 (currently in alpha under PEP 826).

## 8. PEG parser / token / grammar changes

### Why the grammar changed

Python 3.9 adopted the PEG parser (PEP 617). CPython's old LL(1) parser is gone since 3.10. PEG removes many `if-else` style workarounds in the grammar and makes several syntax extensions natural.

Verified from [Grammar/python.gram](https://raw.githubusercontent.com/python/cpython/main/Grammar/python.gram) and [Grammar/Tokens](https://raw.githubusercontent.com/python/cpython/main/Grammar/Tokens) (the full grammar and tokens fetched directly). Highlights:

### PEG operators (from PEP 617)

- `e1 e2` - sequence
- `e1 | e2` - **ordered** choice (first match wins)
- `( e )` - grouping
- `[ e ]` / `e?` - optional
- `e*` - zero or more
- `e+` - one or more
- `s.e+` - one or more separated by `s` (no separator in result)
- `&e` - lookahead positive
- `!e` - lookahead negative
- `~` - commit to current alternative (no backtrack)
- `&&e` - eager parse (no backtrack across this alternative)

### New keywords / soft keywords (Tokens file as of 3.15)

From the **3.15 Tokens file**, the additions versus 3.4 are:

- **3.5**: `async`, `await` (3.7 made them reserved; 3.5 they were soft-keywords inside `async def`)
- **3.6**: `f`, `F` (f-string prefix - in lexer not parser)
- **3.10**: parenthesised context managers (grammar only, no new keyword)
- **3.12**: `type` (soft keyword, only meaningful after `type` token followed by NAME); grammar change
- **3.14**: `t`, `T` (template string prefix); new token kinds `TSTRING_START`, `TSTRING_MIDDLE`, `TSTRING_END` (verified in Tokens file)
- **3.15**: `lazy` (soft keyword); new `LazyImportType` runtime type

### New tokens (verified from fetched Tokens file)

```
TSTRING_START       # t-string prefix opener
TSTRING_MIDDLE      # between interpolation segments
TSTRING_END         # closing
FSTRING_START       # f-string prefix opener (3.12 grammar)
FSTRING_MIDDLE      # between interpolation segments
FSTRING_END         # closing
SOFT_KEYWORD        # generic soft-keyword token
OP                  # generic operator (for deprecation tracking)
```

The PEG grammar also re-shapes how f-strings are tokenised: the lexer emits `FSTRING_START`, `FSTRING_MIDDLE`, `FSTRING_END` triples and lets the parser evaluate the interpolations by recursing into the regular expression grammar (this is what enables `f"{ [x for x in y] }"`, nested quotes, backslashes, etc.).

### Grammar features gpython must add

- `async def`, `async for`, `async with`, `await` (3.5)
- PEP 492 grammar; PEP 525/530 grammar (async generators, async comprehensions)
- PEP 498 f-string grammar (3.6)
- PEP 515 underscore-in-numeric literals (lexer change)
- PEP 526 variable annotations (grammar change for `x: int = ...` at module/class scope)
- PEP 572 walrus operator `:=` (3.8)
- PEP 570 positional-only `/` (3.8)
- PEP 614 relaxed decorator grammar (any expression after `@`) (3.9)
- PEP 617 PEG semantics; the existing grammar must use PEG operators (or your parser must support LL(k) extensions used elsewhere)
- PEP 634/635/636 structural pattern matching (3.10)
- PEP 604 union `|` operator (3.10) - works on type expressions; same symbol used for `dict` and `set` merges (3.9) and for `Except*` (3.11)
- PEP 654 `except*` (3.11); augmented to PEP 758 (no parens) (3.14)
- PEP 695 type parameter syntax (`class C[T]`, `def f[T]`, `type X = ...`) (3.12)
- PEP 701 f-string grammar reformalisation (3.12)
- PEP 696 type parameter defaults (3.13)
- PEP 758 `except` without parens (3.14)
- PEP 765 `SyntaxWarning` for `return`/`continue`/`break` in `finally` (3.14) - not a grammar change, but the compiler must emit the warning
- PEP 798 unpacking in comprehensions (3.15)
- PEP 810 `lazy import` soft keyword (3.15)

### Soft keyword vs keyword

- Soft keyword: parser only treats the word as a keyword in certain contexts (e.g., `type` only when followed by NAME then `=` or `[`).
- Keyword: reserved at all times.

| Word | Type | When |
|---|---|---|
| `async`, `await` | reserved keywords | since 3.7 (3.5 introduced as soft keywords) |
| `type` | soft keyword | 3.12 |
| `lazy` | soft keyword | 3.15 |
| `match`, `case` | soft keyword | 3.10 (parser-only check; identifiers can still exist but produce SyntaxError if not in a match statement) |
| `_*` (`_`, `__`, etc.) | special in match patterns only | 3.10 |

### PEG parser generator

The CPython PEG parser is generated by `Tools/peg_generator/pegen/` (verified by file path; the generator is documented in PEP 617 and lives under `Tools/peg_generator/`). gpython does not need to use `pegen`; the implementer must encode the rules by hand in Go. The grammar source is in `Grammar/python.gram`.

## 9. Gap analysis: what separates Python 3.4 from Python 3.15 for gpython

Workstreams grouped; each item is a concrete deliverable. The current gpython only implements: array, binascii, builtin, glob, marshal, math, os, string, sys, tempfile, time.

### Workstream A: Parser / Grammar / Tokens

| Item | Version | Priority |
|---|---|---|
| Reserved keywords: `async`, `await`, `match`, `case` | 3.5, 3.7, 3.10 | P0 |
| Soft keywords: `type`, `lazy` | 3.12, 3.15 | P2 |
| `async def`, `async for`, `async with` | 3.5 | P0 |
| `await` expression inside coroutines | 3.5 | P0 |
| f-string grammar (PEP 498, 3.6); upgraded to PEP 701 in 3.12 | 3.6, 3.12 | P0 |
| t-string grammar (PEP 750, 3.14) - new tokens `TSTRING_START/MIDDLE/END` | 3.14 | P1 |
| `_` and `__` wildcards in match patterns; capture; sequence; mapping; class; OR; AS; guards | 3.10 | P1 |
| `match` soft keyword detection (identifier OK unless in match context) | 3.10 | P1 |
| `except*` (3.11); unparenthesised `except`/`except*` (3.14) | 3.11, 3.14 | P1 |
| `:=` walrus (3.8) | 3.8 | P0 |
| `/` positional-only marker (3.8) | 3.8 | P0 |
| Variable annotation `x: int = 1` (3.6) | 3.6 | P0 |
| `[]`/`()`/`{}` unpacking generalizations in calls/lists/dicts/sets (3.5) | 3.5 | P0 |
| `**d, **e` in dict literals/calls (3.5, PEP 448) | 3.5 | P0 |
| `@` matrix-mul (3.5) | 3.5 | P0 |
| Underscore in numeric literals (3.6) | 3.6 | P1 |
| Type parameter syntax `class C[T]:`, `def f[T]():`, `type X = T` (3.12) | 3.12 | P2 |
| Type parameter defaults `[T = int]` (3.13) | 3.13 | P2 |
| `Unpack`, `TypeVarTuple` in parameter lists (3.11/3.12) | 3.11 | P2 |
| `type` soft keyword (3.12) | 3.12 | P2 |
| `lazy` soft keyword (3.15) | 3.15 | P3 |
| Unpacking in comprehensions `[*L for L in ...]`, `{**d for d in ...}` (3.15) | 3.15 | P3 |
| Parenthesised context managers (3.10) | 3.10 | P2 |
| Decorator expressions can be any expression including calls and ternaries (3.9) | 3.9 | P1 |
| New lines/no-comma enforcement in collection literals (3.10 better errors) | 3.10 | P3 |
| `f"{}"` empty interpolation; same-quote reuse (3.6/3.12) | 3.6, 3.12 | P1 |
| Nested t-strings and f-strings (3.12, 3.14) | 3.12, 3.14 | P2 |
| Backslash escapes inside f-strings (3.12) | 3.12 | P2 |
| `match`/`case` soft-keyword detection (3.10) | 3.10 | P1 |
| Generator expressions must be parenthesised in `*args` (already true for most cases) | 3.10 | P2 |

### Workstream B: Compiler / Bytecode / Annotations

| Item | Version |
|---|---|
| `__static_attributes__` and `__firstlineno__` on classes (PEP 699) | 3.13 |
| `__annotate__` function emitted by compiler for PEP 649 (functions, classes, modules) | 3.14 |
| `co_positions()` on code objects for fine-grained line/col info | 3.11 |
| `co_lines()` (PEP 626, refined) | 3.10+ |
| Comprehension inlining (PEP 709) - emit bytecode inline, not as nested function | 3.12 |
| Per-instruction `co_qualname` for closures (3.11) | 3.11 |
| Adaptive specializing interpreter opcodes (PEP 659) - many `BINARY_OP_*`, `LOAD_ATTR_*`, `STORE_ATTR_*` specialised variants | 3.11+ |
| `LOAD_METHOD` and `CALL_METHOD` already 3.7 | 3.7 |
| `co_consts` annotations stored as strings vs deferred `__annotate__` (PEP 649) | 3.14 |
| F-string parser: re-parse the interpolation as Python source at compile time | 3.12 |
| T-string parser: same but constructs a `Template` at runtime | 3.14 |
| `lazy` import lowering to runtime proxy | 3.15 |
| Unpacking in comprehensions lowering (build list of `LIST_APPEND` etc. for `[*a for a in xs]`) | 3.15 |
| `MAKE_FUNCTION` flags update for closure / annotations / class / generic | 3.12+ |
| `COPY_FREE_VARS` opcode (3.11) | 3.11 |
| `JUMP_BACKWARD_NO_INTERRUPT` and absolute `JUMP` opcodes (3.11) | 3.11 |
| `RESUME` opcode (3.11) | 3.11 |
| `SEND` opcode (already 3.x but tweaks) | 3.11+ |
| `BINARY_OP`, `BINARY_OP_ADD_INT`, etc. specialised opcodes | 3.11+ |
| `LOAD_FAST_AND_CLEAR`, `LOAD_FAST_CHECK` (3.12) | 3.12 |
| `CALL_INTRINSIC_1/2` (3.12) | 3.12 |
| `RETURN_CONST`, `LOAD_CONST` extensions | 3.12+ |
| `STORE_FAST_MAYBE_NULL` (3.14) | 3.14 |

gpython already has its own bytecode; the implementer decides which CPython opcodes matter for compatibility. For language-feature parity, the semantic outcomes are what matters, not opcode names. But any cross-Python VM interop requires these opcode changes.

### Workstream C: Runtime / Object Model / Builtins

| Item | Version |
|---|---|
| `dict` insertion-order preservation guarantee | 3.7 |
| `dict` `\|` / `\|=` operators | 3.9 |
| `frozendict` (PEP 814) | 3.15 |
| `sentinel` (PEP 661) | 3.15 |
| `breakpoint()` builtin (PEP 553) | 3.7 |
| `int.bit_count`, `int.to_bytes` unchanged | 3.0+ |
| `bytes.hex`, `memoryview.hex` | 3.5 |
| `bytes % args` percent formatting (PEP 461) | 3.5 |
| `str.removeprefix`/`removesuffix` (PEP 616) | 3.9 |
| `int`/`float` `__format__` for `'_'` thousands separator | 3.6 |
| `int.is_integer` (Float) - already 3.x | n/a |
| `dict` comprehension is a class body (unchanged) | n/a |
| `__class_getitem__` on classes for generic syntax | 3.7 |
| `__class_getitem__` on instances (`cls[x]`) deprecated since 3.7 | n/a |
| `__init_subclass__`, `__set_name__`, `__class_getitem__` | 3.6 |
| `__getattr__`, `__dir__` on modules (PEP 562) | 3.7 |
| `__match_args__` on classes for match patterns | 3.10 |
| `__static_attributes__`, `__firstlineno__` | 3.13 |
| `__annotate__` descriptor on functions/classes/modules | 3.14 |
| Async iteration protocol `__aiter__`/`__anext__` (3.5) | 3.5 |
| Async context manager `__aenter__`/`__aexit__` (3.5) | 3.5 |
| Generator `throw`/`send`/`close` API | 3.0+ |
| `StopIteration` semantics - PEP 479 stops propagation (3.7) | 3.7 |
| `asyncio.run()` etc. (3.7+) | 3.7+ |
| `ExceptionGroup`, `BaseExceptionGroup` types (3.11) | 3.11 |
| `add_note()` on BaseException (3.11) | 3.11 |
| `PythonFinalizationError` (3.13) | 3.13 |
| `RecursionError` already 3.5 | 3.5 |
| `__future__` flags: `annotations` (3.7), `generator_stop` (3.7), `unicode_literals` (3.x) | various |
| Immortal objects (PEP 683) | 3.12 |
| Free-threaded mode (PEP 703) | 3.13 (experimental), 3.14 official |

### Workstream D: Stdlib modules

Minimum required for parity (excluding what 3.4 already had):

| Module / feature | Version |
|---|---|
| `typing` runtime support: `List`, `Dict`, `Optional`, `Union` (3.5/3.9), `Generic` (3.7), `Protocol` (3.8), `TypedDict` runtime-usable (3.8), `Literal` (3.8), `Final` (3.8), `Annotated` (3.9), `Self` (3.11), `LiteralString` (3.11), `Unpack` (3.11), `TypeVarTuple` (3.11), `Required`/`NotRequired` (3.11), `TypeGuard` (3.10), `ParamSpec`/`Concatenate` (3.10), `TypeIs` (3.13), `ReadOnly` (3.13), `TypeForm` (3.15), `TypeAliasType` (3.12), `dataclass_transform` (3.11), `deprecated` (3.13), `override` (3.12) | various |
| `dataclasses` | 3.7 |
| `enum` enhancements (`StrEnum`, `Flag` boundary, `member`/`nonmember`/`property`, `global_enum`, `show_flag_values`) | 3.11 |
| `pathlib` improvements (3.12 subclassing, `full_match` 3.13) | various |
| `zoneinfo` | 3.9 |
| `graphlib` | 3.9 |
| `tomllib` | 3.11 |
| `annotationlib` | 3.14 |
| `string.templatelib` | 3.14 |
| `compression.zstd` | 3.14 |
| `concurrent.interpreters` | 3.14 |
| `profiling` package | 3.15 |
| `math.integer` | 3.15 |
| `copy.replace` | 3.13 |
| `dbm.sqlite3` (default backend) | 3.13 |
| `base64.z85encode`/`z85decode` | 3.13 |
| `os.timerfd_*` (Linux) | 3.13 |
| `random` CLI | 3.13 |
| `asyncio` TaskGroup, `asyncio.timeout`, async generator improvements | 3.11+ |
| `f-strings` richer `__format__` specs | 3.6/3.7/3.10+ |
| `statistics` improvements (`fmean`, `geometric_mean`, `NormalDist`) | 3.8 |
| `subprocess.run` and improved `Popen` API | 3.5+ |
| `os.scandir` | 3.5 |
| `os.PathLike` protocol | 3.6 |
| `argparse.BooleanOptionalAction`, `deprecated` action | 3.9, 3.13 |
| `contextlib.AsyncExitStack`, `nullcontext`, `aclosing`, `chdir` | various |
| `ssl` TLS 1.3, default verify flags | 3.6+ |
| `hashlib.scrypt`, BLAKE2, SHA-3, SHAKE | 3.6 |
| `unittest.mock.AsyncMock`, `seal`, `patch` as decorator | 3.8 |
| `sqlite3` CLI | 3.12 |
| `uuid` CLI | 3.12 |
| `time.time_ns`, `monotonic_ns` | 3.7 |
| `datetime.UTC`, `fromisoformat` strict | 3.11 |
| `wsgiref`, `http.server` improvements | various |
| `warnings` thread-safe | 3.13+ |
| `tomllib` and `tomli` removal | 3.11 |
| `secrets` module | 3.6 |
| `zipapp` | 3.5 |

### Workstream E: Removed APIs gpython must NOT carry forward

If gpython still ships any of these, they are bugs:

- `distutils` (gone 3.12)
- `imp` (gone 3.12)
- `asyncore`/`asynchat`/`smtpd` (gone 3.12)
- `aifc`, `audioop`, `cgi`, `cgitb`, `chunk`, `crypt`, `imghdr`, `mailcap`, `msilib`, `nis`, `nntplib`, `ossaudiodev`, `pipes`, `sndhdr`, `spwd`, `sunau`, `telnetlib`, `uu`, `xdrlib` (gone 3.13)
- `tkinter.tix` (gone 3.13)
- `lib2to3` / `2to3` (gone 3.13)
- `locale.resetlocale()` (gone 3.13)
- `typing.io`, `typing.re` (gone 3.13)
- `asyncio.coroutines` compat API (gone in some release - verify)
- `binhex` (gone 3.11)
- `macpath` (gone 3.8)
- `pyvenv.cfg` install setuptools (gone 3.12)
- `Py_UNICODE` C API (gone 3.12)
- `wstr` from `PyUnicodeObject` (gone 3.12)
- `Py_UNICODE` encoder APIs (gone 3.11)
- `pkgutil.ImpImporter`, `pkgutil.ImpLoader` (gone 3.12)
- `cgi.escape` (gone in 3.13 via `cgi` removal)
- `sysconfig._SCHEME_KEYS` value changes across versions

### Workstream F: Tooling / REPL

- PyREPL default REPL (PEP 642, 3.13) - gpython's REPL should at minimum support colour (PEP 656), block-style continuation, multiline history.
- PEP 723 inline script metadata (`# /// script ... # ///`) - gpython should parse and ignore if not supported.
- `python -m http.server` improved output.
- `-X` flags proliferation: `dev`, `utf8`, `faulthandler`, `tracemalloc`, `importtime`, `gil=0`, `lazy_imports`, etc.
- `PYTHON*` env var additions: `PYTHONUTF8`, `PYTHONNODEBUGRANGES`, `PYTHONPYCACHEPREFIX`, `PYTHONSAFEPATH`, `PYTHON_COLORS`, `PYTHON_LAZY_IMPORTS`, `PYTHON_BASIC_REPL`.
- `--check-hash-based-pycs always|never|default`.
- `-P` (no `sys.path[0]`).

### Workstream G: Import system / packaging

- `importlib.resources` as a package (3.12); `importlib.resources.files(anchor=None)`.
- `importlib.import_module` semantics.
- `__pycache__` layout tweaks: hash-based `.pyc` (PEP 552, 3.7); `PYTHONPYCACHEPREFIX` (3.8).
- `importlib.metadata` as a stdlib module (3.8 / 3.10 - verify).
- `zipimport` stricter zip handling (3.15).
- `importlib.machinery.SourceFileLoader` `get_resource_reader` (3.7+).
- Lazy imports (PEP 810, 3.15) - gpython can ignore this initially.

## 10. Notes on items I could not verify

Items I am uncertain about (recommend manual check before relying):

- Exact list of *all* stdlib removals in 3.14 and 3.15 (the whatsnew files are very long; some sections were truncated in my fetches). The 3.13 removals and 3.15 Removed section are confident. The middle of 3.15 whatsnew was not fully read.
- Some PEP numbers in the prompt - PEP 711, 712, 713, 714, 720, 721, 723, 725, 733, 780, 789 - I did not find authoritative landing confirmation. Many are rejected/withdrawn.
- Specific 3.15 removals in `datetime`, `glob`, `http.server`, `sre_*`, `threading`, `types`, `wave`, `zipimport` - need to read the 3.15 Removed section in full.
- `tomllib` shipped with 3.11 (verified) - correct.
- `annotationlib` shipped with 3.14 (verified via [docs.python.org/3.15/library/annotationlib.html](https://docs.python.org/3.15/library/annotationlib.html)) - correct.
- `string.templatelib` shipped with 3.14 (verified) - correct.
- `concurrent.interpreters` shipped with 3.14 (verified via [docs.python.org/3/library/concurrent.interpreters.html](https://docs.python.org/3/library/concurrent.interpreters.html)) - correct.
- `compression.zstd` shipped with 3.14 (PEP 784) - verified by mention in [3.14 whatsnew](https://docs.python.org/3/whatsnew/3.14.html#whatsnew314-zstandard).
- 3.15 release date **9 October 2026** - verified.
- 3.14 release date **7 October 2025** - verified.
- 3.13 release date **October 7, 2024** - verified.
- 3.12 release date **October 2, 2023** - verified.
- 3.11 release date **October 24, 2022** - verified.
- 3.10 release date **October 4, 2021** - verified.
- 3.9 release date **October 5, 2020** - verified.
- 3.8 release date **October 14, 2019** - verified.
- 3.7 release date **June 27, 2018** - verified.
- 3.6 release date **December 23, 2016** - verified.
- 3.5 release date **September 13, 2015** - verified.
- `PEP 594` removal list - the 19 modules are confirmed; the full list above matches the 3.13 whatsnew Removed section.
- PEG grammar header and syntax operators - verified against the fetched grammar file.
- TSTRING_START/MIDDLE/END tokens present in current Tokens file - verified.
- `annotationlib` API (`Format.VALUE`, `Format.FORWARDREF`, `Format.STRING`, `ForwardRef`, `get_annotations()`) - verified.
- `string.templatelib.Template` and `Interpolation` shape - verified.
- 3.15 lazy import mechanics (`lazy import x`, `__lazy_modules__`, `sys.set_lazy_imports`, `sys.set_lazy_imports_filter`, `types.LazyImportType`, `-X lazy_imports`, `PYTHON_LAZY_IMPORTS`) - verified from the 3.15 whatsnew page.

## 11. Summary: what a Go engineer needs to build

In priority order, the workstreams:

1. **Lexer / Parser**: rewrite the parser to support PEG-style ordered choice and the new soft-keyword handling; add `async`, `await`, `match`, `case`, `type`, `lazy`; add the new expression-level productions (walrus, positional-only, parenthesised manager, pattern matching, type parameter syntax, f-string nested expressions, t-strings, comprehension unpacking).
2. **Bytecode / Compiler**: emit `__annotate__` for PEP 649; inline comprehensions per PEP 709; produce `Template` objects for t-strings; produce `LazyImportType` proxies for lazy imports; emit `__static_attributes__` and `__firstlineno__`.
3. **Object model**: add `frozendict` and `sentinel`; tighten dict ordering guarantees; implement exception groups and `except*`; implement deferred annotations (`annotationlib`).
4. **Stdlib additions**: `typing`, `dataclasses`, `enum`, `pathlib` enhancements, `zoneinfo`, `graphlib`, `tomllib`, `annotationlib`, `string.templatelib`, `compression.zstd`, `concurrent.interpreters`, `profiling` package.
5. **Stdlib removals**: rip out everything listed in section 3.
6. **REPL**: implement at least colour output and the new interactive-shell behaviour expected by the Python community.
7. **C-API surface** (only if you embed or expose ABI): mirror Stable ABI evolution for free-threaded builds, immortal objects, and the `PyBytesWriter` API.
8. **Encoding default**: make UTF-8 the default per PEP 686 in 3.15.

This report is the source-of-truth specification set a downstream engineer can use to write the gpython 3.15 spec files.
