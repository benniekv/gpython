# 06 - Porting Work: Go 1.27, the Build System and the Web Target

## Overview

This file records the porting work that has to happen for gpython to reach
Python 3.15, and that is **not** about the Python language itself. It covers
three areas:

1. **The Go 1.27 upgrade.** The module declared `go 1.18` and CI tested
   1.18 and 1.19. Go 1.27's vet enforces the `printf` non-constant format
   string rule, which found **twelve real bugs** in the production code.
2. **The build system.** There was no Makefile. There is now one, and every
   binary it produces lands in `bin/`, which is never committed.
3. **The web target.** `repl/web` depends on `gopherjs/gopherwasm`, which is
   **archived and deprecated**. The wasm build still works, but on a
   dependency that upstream has abandoned.

**Item 3 is the open porting work.** Items 1 and 2 are done.

## Sources

### The gpython checkout, at `6d9bee8` plus the Go 1.27 changes

| Path | Used for |
|---|---|
| `go.mod` | The `go` directive, the dependency set |
| `py/file.go`, `stdlib/os/os.go` | The 12 non-constant format string sites |
| `stdlib/array/array.go` | The unreachable `panic("impossible")` and the two missing `default` branches |
| `parser/lexer_test.go` | 180 unkeyed `ast.Pos` struct literals |
| `vm/eval.go` | The dead `i++` that staticcheck found |
| `repl/web/main.go` | The gopherwasm dependency |
| `.github/workflows/ci.yml` | The Go version matrix |
| `py/gen.go`, `parser/grammar.y`, `symtable/`, `vm/` | The four code generators |

### Web, fetched 2026-11-19

| URL | Used for |
|---|---|
| `https://github.com/gopherjs/gopherwasm` | The package is **archived**. "This package is deprecated. Use `syscall/js` of GopherJS instead." |
| `https://github.com/gopherjs/gopherjs/` | GopherJS itself is alive: v1.21.0, released 2026-06-26, supporting Go 1.21. It requires `GOPHERJS_GOROOT` to point at a Go 1.21 tree when the local Go is newer. |
| `https://pkg.go.dev/golang.org/x/tools` | x/tools v0.53.0 requires Go 1.26.0 |
| `https://pkg.go.dev/golang.org/x/tools/cmd/stringer` | The stringer command |
| `https://pkg.go.dev/golang.org/x/tools/cmd/goyacc` | The goyacc command |

## Spec

### Part 1 - The Go 1.27 upgrade (DONE)

`go.mod` declared `go 1.18`. The upgrade to `go 1.27` was made, and CI now
tests `1.27.x` and `1.26.x`.

#### The code already used Go 1.27 features

The module built cleanly with Go 1.27 before the `go.mod` change, because
the `go` directive is a *minimum*, not a pin. The code already used:

| Feature | Files |
|---|---|
| `any` | 24 |
| `go:build` directives | 6 |
| `range` over an integer | 6 |
| `errors.Is` | 2 |
| `slices` | 2 |
| builtin `min`/`max` | 2 |
| `os.ReadFile` | 3 |
| `io.ReadAll` | 3 |

**The `go` directive was stale, not restrictive.** Raising it to 1.27 is
therefore safe and lets the module use the newer standard library.

#### The 12 bugs Go 1.27's vet found

Go 1.24 added the `printf` vet check for non-constant format strings. With
the `go` directive raised to 1.27, the check became active and found twelve
call sites in production code.

**The bug in each case:** an error message was passed as the *format
string* rather than as an *argument*. If the message contained a `%`, it
would be interpreted as a format directive.

Two distinct patterns:

```go
// Pattern 1: the error text IS the format string.
return nil, ExceptionNewf(OSError, err.Error())

// Pattern 2: the error text is CONCATENATED into the format string.
return nil, py.ExceptionNewf(py.TypeError, "str expected, not "+args[0].Type().Name)
```

Both were fixed to pass the value as an argument:

```go
return nil, ExceptionNewf(OSError, "%s", err.Error())
return nil, py.ExceptionNewf(py.TypeError, "str expected, not %s", args[0].Type().Name)
```

**The complete list of sites:**

| File | Line | Pattern |
|---|---|---|
| `py/file.go` | 241 | `ExceptionNewf(FileExistsError, err.Error())` |
| `py/file.go` | 244 | `ExceptionNewf(FileNotFoundError, err.Error())` |
| `py/file.go` | 247 | `ExceptionNewf(OSError, err.Error())` |
| `stdlib/os/os.go` | 204 | `"str expected, not " + ...` |
| `stdlib/os/os.go` | 208 | `"Couldn't change cwd; " + err.Error()` |
| `stdlib/os/os.go` | 221 | `"str expected (pos 1), not " + ...` |
| `stdlib/os/os.go` | 400 | `"str expected (pos 1), not " + ...` |
| `stdlib/os/os.go` | 404 | `"str expected (pos 2), not " + ...` |
| `stdlib/os/os.go` | 420 | `"str expected (pos 1), not " + ...` |
| `stdlib/os/os.go` | 436 | `"expected int (pos 1), not " + ...` |
| `stdlib/os/os.go` | 557 | `"str expected (pos 1), not " + ...` |
| `stdlib/os/os.go` | 568 | `py.ExceptionNewf(py.OSError, err.Error())` |

**This is a real class of bug, not a lint nit.** A Python program that
triggers an OS error whose message contains a percent sign would get a
garbled exception. The 3.15 upgrade will port far more error paths from
CPython, and every one of them must use the argument form.

#### The other vet findings

| Finding | Sites | Fix |
|---|---|---|
| `unkeyed fields` in `py.File` | `stdlib/os/os.go:176` | `&py.File{File: f, FileMode: perm}` |
| `unreachable code` | `stdlib/array/array.go:422` | See below |
| `unkeyed fields` in `ast.Pos` | `parser/lexer_test.go`, 180 sites | `ast.Pos{Lineno: 1, ColOffset: 0}` |

**The `array.go` case was a genuine latent bug.** The `panic("impossible")`
was the outer switch's fallthrough guard, but the outer switch has a
`default` that returns, so the panic was unreachable. Removing it exposed
the real defect: **the inner `switch arr.descr` had no `default` branch**,
so an unknown array typecode fell out of the function with no return value
at all.

The fix adds a `default` to both inner switches:

```go
default:
	return nil, py.ExceptionNewf(py.TypeError, "bad array typecode %s", string(arr.descr))
```

**That is a real behaviour change.** Before the fix, `array` with an
unrecognised typecode would panic or return garbage. Now it raises a
`TypeError`, which is what CPython does.

#### The staticcheck finding

staticcheck found one issue:

```
vm/eval.go:526:2: this value of i is never used (SA4006)
```

In `unpack_iterable`, `i` was declared outside the loop and incremented
once more after the loop, but never read again. The `i++` was dead and `i`
was scoped too wide. Fixed by scoping `i` to the loop and removing the
dead increment.

#### The staticcheck version had to change

**The CI pinned staticcheck `2022.1`, and that version cannot run against Go
1.27.** It panics:

```
panic: *types.Alias: any
goroutine 387 [running]:
golang.org/x/tools/go/types/typeutil.Hasher.hashFor(...)
```

The panic is in `x/tools@v0.1.11`, which staticcheck 2022.1 depends on. It
cannot handle the `*types.Alias` node that Go 1.22 introduced.

The versions were tested in order:

| Version | Result |
|---|---|
| `2022.1.3` (the CI pin) | **Panics** on `*types.Alias` |
| `2025.1.1` | `cannot decode "internal/byteorder", export data version 5 is greater than maximum supported version 2` |
| `v0.6.1`, `v0.7.0` | Same export data error |
| `v0.8.2` | **Works.** Zero findings. |
| `latest` (v0.8.2) | Works. Zero findings. |

**The pin is now `honnef.co/go/tools/cmd/staticcheck@v0.8.2`.**

#### The toolchain pins that work with Go 1.27

| Tool | Pin | Why |
|---|---|---|
| `stringer` | `golang.org/x/tools/cmd/stringer@v0.53.0` | v0.24.0 fails to compile: `invalid array length -delta * delta` in `x/tools/internal/tokeninternal` |
| `goyacc` | `golang.org/x/tools/cmd/goyacc@v0.53.0` | Same module, same constraint |
| `staticcheck` | `honnef.co/go/tools/cmd/staticcheck@v0.8.2` | Older versions panic or cannot read Go 1.27 export data |

x/tools v0.53.0 requires Go 1.26.0, which is satisfied by the 1.27 floor.

### Part 2 - The build system (DONE)

There was no Makefile. There is now one, with these properties:

- **Every binary lands in `bin/`.** `bin/gpython`, `bin/testparser`,
  `bin/gpython-<os>-<arch>`, `bin/cover.out`.
- **`bin/` is gitignored**, except `bin/install-python.sh`, which is a source
  script rather than a build product.
- **The generator tools install into `bin/tools/`**, so a build never depends
  on what happens to be on `$PATH`.
- `make help` lists every target with a one-line description.

#### The targets

| Target | What it does |
|---|---|
| `build` | `bin/gpython` and `bin/testparser` |
| `test`, `test-race`, `test-386`, `test-ci` | The test suite in the four modes CI uses |
| `cover` | Tests plus a coverage report |
| `check` | `fmt-check` + `vet` + `staticcheck` + `test` |
| `fmt`, `fmt-check` | gofmt |
| `vet` | `go vet` |
| `staticcheck` | staticcheck, installing it first if needed |
| `cross` | linux, darwin and windows binaries for amd64, 386 and arm64 |
| `tools` | Installs stringer, goyacc and staticcheck into `bin/tools` |
| `tools-list` | Shows which tools are installed |
| `generate` | All four generators |
| `generate-arithmetic` | `py/arithmetic.go` |
| `generate-grammar` | `parser/y.go` |
| `generate-stringer` | `symtable/stringer.go` and `vm/stringer.go` |
| `generate-asdl` | `ast/Python-ast.go` from `ast/Python.asdl` |
| `generate-testdata` | The golden test data, **from CPython** |
| `generate-check` | Regenerates and shows the diff |
| `clean`, `distclean` | Remove the binaries, and the tools |
| `difftest` | The differential test harness |

#### The four code generators

| Generator | Directive | Input | Output | Tool |
|---|---|---|---|---|
| Arithmetic | `py/py.go:9` `go run gen.go` | a table in `py/gen.go` | `py/arithmetic.go` | none, just `go run` |
| Grammar | `parser/parser.go:10` | `parser/grammar.y` | `parser/y.go`, `parser/y.output` | `goyacc` |
| Stringer | `symtable/symtable.go:27` | `symtable/symtable.go` | `symtable/stringer.go` | `stringer` |
| Stringer | `vm/vm.go:12` | `vm/vm.go`, `vm/opcodes.go` | `vm/stringer.go` | `stringer` |
| ASDL | none | `ast/Python.asdl` | `ast/Python-ast.go` | `ast/asdl_go.py` |

**The licence header problem.** The generators do not emit the licence
header, but every tracked generated file in the repository carries it. The
Makefile has an `_add-license` target that prepends it. The target takes a
`FILES` variable, a space separated list of paths relative to the repository
root, because a target that changes directory cannot resolve a relative
path.

**The `stringer` invocation needs the package directory.** The `go:generate`
directive says `stringer -type=Scope,BlockType -output stringer.go`, which
fails with `no packages matching .` when run from the repository root. It
must be run **from inside the package directory**, or given the package
name.

#### What regenerating with the modern tools produces

**`py/arithmetic.go` is byte-identical.** The only difference is the
licence header, which the Makefile restores. That generator is stable.

**`parser/y.go` changes substantially.** The tracked file was generated by a
2018-era goyacc:

| | Tracked | Modern goyacc |
|---|---|---|
| Table type | `[...]int` | `[...]int16` |
| Blank line after `//line` | no | yes |
| Import grouping | blank line between `fmt` and the local import | no blank line |

The `int16` change is deliberate upstream: it halves the size of the parse
tables. **The diff is 400 insertions and 398 deletions**, and it is all
mechanical. The build and all 19 test packages pass with it.

**The stringer files change because the tool changed.** The 2018-era
stringer used `fmt.Sprintf`; the modern one uses `strconv.Quote` and adds a
compile-time guard:

```go
func _() {
	// An "invalid array index" compiler error signifies that the constant values have changed.
	// Re-run the stringer command to generate them again.
	var x [1]struct{}
	_ = x[ScopeInvalid-0]
	...
}
```

**That guard is an improvement.** It makes the compiler fail if an enum
value changes without the file being regenerated. The diff is 30 insertions
and 8 deletions for `symtable`, 127 and 6 for `vm`.

**The golden test data must NOT be regenerated by gpython.** The
`generate-testdata` target runs the three Python scripts, and the scripts
require the right CPython version:

| Script | Requires |
|---|---|
| `compile/make_compile_test.py` | CPython 3.4 to reproduce the tracked data; CPython 3.15 to produce the target data |
| `symtable/make_symtable_test.py` | CPython 3.4, plus a rebuilt `readsymtab` C extension for 3.15 |
| `parser/make_grammar_test.py` | CPython 3.4, or CPython 3.15 for the target |

The `symtable` generator has a `ctypes` fallback that reads CPython's
`PySTEntryObject` **by offset**. That layout changed between 3.4 and 3.15,
so the `readsymtab` extension must be rebuilt before the script will work
on 3.15.

### Part 3 - The web target (OPEN, this is the porting work)

`repl/web/main.go` is the online REPL. It builds for `GOOS=js GOARCH=wasm`
and it imports:

```go
"github.com/gopherjs/gopherwasm/js" // gopherjs to wasm converter shim
```

**That package is archived.** The upstream README says, in full:

> This package is deprecated. Use `syscall/js` of GopherJS instead.

The archive means no security fixes, no Go version support, and a package
that will not track the Go standard library.

**The wasm build still works today:**

```
$ GOOS=js GOARCH=wasm go build -o /tmp/gpython.wasm .
exit 0
```

**But the shim is not a drop-in replacement for `syscall/js`.** Porting
`repl/web/main.go` to `syscall/js` was attempted and failed with two
errors:

```
repl/web2/main.go:41:9: invalid operation: node == js.Undefined() (struct containing [0]func() cannot be compared)
repl/web2/main.go:79:11: undefined: js.NewCallback
```

The two API differences:

| gopherwasm | `syscall/js` | The porting work |
|---|---|---|
| `js.Undefined()` is a **function** returning a value | `js.Undefined` is a **value** of type `js.Value` | Change `node == js.Undefined()` to `node.IsUndefined()` |
| `js.NewCallback(fn)` returns a `js.Value` | No equivalent | Use `js.FuncOf(fn)` instead, which returns a `js.Func`. Call `.Release()` when done. |

`js.FuncOf` has a **lifecycle contract** that `js.NewCallback` does not:
the returned `js.Func` holds a Go function alive, and it must be released
with `Release()` or the JavaScript side leaks a reference. The callbacks in
`repl/web/main.go` are long-lived (the REPL input handler), so they should
be created once and released on shutdown.

**The API surface used is small.** Eleven uses:

```
js.Value (x6)   js.Undefined   js.Global (x3)
js.NewCallback  js.ValueOf
```

That is a contained port.

#### The gopherjs path is a separate decision

`gopherjs/gopherwasm` exists because gpython could target **both** GopherJS
(Go to JavaScript) and native WebAssembly through one API. The upstream
guidance is now:

- **GopherJS** is alive. v1.21.0 was released 2026-06-26 and supports Go
  1.21. It requires `GOPHERJS_GOROOT` to point at a Go 1.21 distribution
  when the local Go is newer, because GopherJS cannot consume the export
  data of a newer standard library.
- **GopherJS only supports Go 1.21.** gpython now requires Go 1.27. So the
  GopherJS path needs a **separate Go 1.21 toolchain**, which is a
  significant build-matrix cost for a feature that has one user.

#### The options

| Option | Work | Result |
|---|---|---|
| **A. Port `repl/web` to `syscall/js`** | Small: two API changes plus the `js.Func` lifecycle | The wasm build uses only the standard library. The GopherJS path is dropped. **Recommended.** |
| **B. Keep the shim** | None | The build keeps working on an archived dependency that no longer tracks Go. |
| **C. Port to `syscall/js` and keep a GopherJS build** | Large: a second toolchain, a second CI job, and the `syscall/js` differences between the two runtimes | Two web targets, twice the maintenance. |

**Option A is recommended.** The `repl/web` binary is the only consumer of
the dependency, the API surface is eleven uses, and dropping GopherJS costs
one rarely used build target.

### Part 4 - The HERMES.md size limit

`HERMES.md` must stay **below 100 lines** at all times. Anything that does
not fit goes into `specs/`, and `HERMES.md` carries a one-line instruction
to load it.

This is a hard requirement, not a style preference. The file was 238 lines
before this change, so the overflow was moved out.

## Verification

**1. Confirm the module requires Go 1.27.**

```bash
grep '^go ' go.mod
```

Expect `go 1.27`.

**2. Confirm the CI matrix.**

```bash
grep 'go-version:' .github/workflows/ci.yml
```

Expect `[1.27.x, 1.26.x]`.

**3. Confirm `go vet` is clean.**

```bash
go vet ./...
```

Expect no output and exit 0. **It was not clean before the upgrade**: 12
non-constant format string errors, one unkeyed literal, one unreachable
`panic`, and 180 unkeyed `ast.Pos` literals in the tests.

**4. Confirm the format-string fix took.**

```bash
grep -n 'ExceptionNewf' py/file.go stdlib/os/os.go | grep -v '"%s"' | grep -v '"%'
```

Expect no output.

**5. Confirm the array typecode bug is fixed.**

```bash
grep -n 'bad array typecode' stdlib/array/array.go
```

Expect two occurrences, one in `M__getitem__` and one in `M__setitem__`.

**6. Confirm staticcheck is clean.**

```bash
make tools && bin/tools/staticcheck ./...
```

Expect exit 0 and no findings. **staticcheck 2022.1 panics on Go 1.27**, so
the pin matters.

**7. Confirm the tools install into `bin/`.**

```bash
make tools-list
ls bin/tools/
```

Expect `stringer`, `goyacc` and `staticcheck` under `bin/tools/`.

**8. Confirm the generators work.**

```bash
make generate
git status --short
```

Expect the four generated files to be modified and nothing else.

**9. Confirm every binary lands in `bin/`.**

```bash
make build cross
ls bin/
find . -maxdepth 1 -type f -perm -u+x -not -path './.git/*'
```

Expect the binaries in `bin/`, and no executable outside it.

**10. Confirm `bin/` is not committed.**

```bash
git check-ignore -v bin/gpython bin/tools/stringer
git ls-files bin/
```

Expect the first to report the ignore rule, and the second to list only
`bin/install-python.sh`.

**11. Confirm the wasm build still works.**

```bash
GOOS=js GOARCH=wasm go build -o /tmp/gpython.wasm .
```

Expect exit 0. **This documents the current state, not the target.** The
target is a wasm build with no gopherwasm dependency.

**12. Confirm the gopherwasm port failure is real.**

```bash
grep -n 'gopherwasm\|syscall/js' repl/web/main.go
```

Expect `gopherwasm`, and the two `syscall/js` incompatibilities are
`js.Undefined()` and `js.NewCallback`.
