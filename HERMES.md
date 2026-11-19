# HERMES.md

Instructions for Hermes Agent working in this repository.

## Project

gpython is a Python 3.4 interpreter written in Go. It parses Python, compiles it to a
bytecode-like instruction set, and runs it in a multi-context VM. It embeds into Go
applications.

Module path: `github.com/go-python/gpython`. Go 1.18 in `go.mod` (CI runs 1.18.x and 1.19.x).

## Layout

| Path | Contents |
|---|---|
| `py/` | Runtime object model: types, values, exceptions, frames, generators. The core of the interpreter. |
| `parser/` | Hand-written lexer plus a goyacc grammar (`grammar.y`, `y.go`). |
| `ast/` | AST node types (`ast.go`), walker, dumper. `Python.asdl` is the source of truth for the AST shape. |
| `symtable/` | Symbol table construction and scope analysis. |
| `compile/` | AST to bytecode compiler, instruction set (`instructions.go`). |
| `vm/` | The virtual machine, opcodes, evaluator. `vm/benchmarks/` holds benchmarks. |
| `stdlib/` | Python standard modules: `builtin`, `math`, `sys`, `time`, `os`, `string`, `array`, `binascii`, `glob`, `marshal`, `tempfile`. |
| `repl/` | Interactive mode: `repl/cli` for the terminal REPL, `repl/web` for the web REPL. |
| `pytest/` | Test harness that runs Python test files and compares against golden output. |
| `importlib/` | Import machinery. |
| `ci/` | `run-tests.go`, the CI test driver. |
| `examples/` | `embedding/` and `multi-context/` show how to host gpython in a Go program. |

## Commands

The CI workflow passes `-tags=ci` to every go command, so use the same tag locally.
No source file is guarded by that tag today, so it changes nothing today. It keeps
your local run identical to CI.

Build:

    go build ./...
    go install -v -tags=ci ./...

Test (quick, single package):

    go test -tags=ci ./py/...
    go test -tags=ci ./stdlib/...

Test (full, matching CI on Linux):

    go run ./ci/run-tests.go -tags=ci -race -coverpkg=github.com/go-python/gpython/...

The CI driver runs each package as a separate `go test` invocation and merges coverage
into `coverage.txt`. Use it when a change touches more than one package.

Other useful targets:

    go vet -tags=ci ./...
    gofmt -l .
    go test -tags=ci -regen ./...     # regenerate golden testdata files

Static analysis in CI uses `dominikh/staticcheck` at version `2022.1`.

### Known baseline failures

These exist on `main` and are not caused by your change. Do not chase them unless the
task is about them. If you do fix one, fix it in a separate commit.

- `gofmt -l .` reports `py/import.go`. The file has a mis-indented `return` in the
  `__import__` error branch.
- `go vet -tags=ci ./...` reports two issues: unreachable code in `stdlib/array/array.go`
  and an unkeyed struct literal in `stdlib/os/os.go`.
- `goimports` and `staticcheck` are not guaranteed to be installed. `staticcheck` is
  present on this machine; `goimports` is not. Use `gofmt` when `goimports` is missing.

## Testing conventions

Two kinds of tests live in this repo.

Go unit tests. Standard `testing` package, `*_test.go` next to the code. Table-driven
where several cases exist. See `py/py_test.go`, `py/string_test.go`, `py/type_test.go`.

Python test files. A `.py` file under a `tests/` directory next to the package. The Go
test file in the package calls `pytest.RunTests(t, "tests")` to run them. Adding a
Python test means dropping the `.py` file into the right `tests/` directory; no Go
change is needed.

    py/tests/string.py            -> run by py/py_test.go
    stdlib/builtin/tests/builtin.py -> run by stdlib/builtin/builtin_test.go
    vm/tests/*.py                 -> run by vm/vm_test.go

The harness compares program output against golden files in `testdata/`.

The compile, symtable and grammar golden data under `compile/`,
`symtable/` and `parser/` are different. They are **generated from CPython**,
not from gpython, by `make_compile_test.py`, `make_symtable_test.py` and
`make_grammar_test.py`. Regenerate them with the CPython version that is the
target, and review the diff. Never regenerate them from gpython's own output
with `-regen`: that would rewrite the oracle to match the implementation and
hide the difference.

`-regen` is only for the `testdata/test_golden.txt` files of a stdlib module,
and only when the module's correct output changed.

Every new behavior needs a test. Do not edit a test to make it pass unless the test
was wrong. If the behavior is a deliberate change to Python semantics, say so in the
commit message.

See the Hard requirements section below. The short version: code and tests go in
separate commits, and a failing test gets reported and diagnosed, never
auto-fixed.

## Code conventions

Follow Go style, as in `CONTRIBUTE.md`.

- New `.go` files start with the copyright header. Use the year the file is added.
  Do not bump the year on files you only edit.

      // Copyright 20xx The go-python Authors.  All rights reserved.
      // Use of this source code is governed by a BSD-style
      // license that can be found in the LICENSE file.

- Run `gofmt` on every file you touch. `goimports` is the preferred formatter.
- Exported identifiers carry doc comments that start with the identifier name.
- Never ignore an error without a comment saying why it is safe.
- No underscores in Go names. Use camelCase.
- Do not add new dependencies to `go.mod` without a clear reason. The current set is
  `go-cmp`, `gopherjs/gopherwasm`, and `liner`, plus the `gopherjs` indirect for the
  wasm target.

## Commit messages

Follow the format in `CONTRIBUTE.md`:

    py: harden __import__ argument handling

    Explain the change in the body. Name every package touched when the change spans
    packages:

    py,repl/cli,stdlib/builtin: implement input

Reference an issue as `Fixes go-python/gpython#NN` when one exists.

## Working in this repo

- Commit at the end of every prompt. Stage all changes, run the project's checks, commit,
  then push to `origin HEAD`. Never force push. Do not rewrite published history.
- Do not commit generated files unless the repository already tracks them. The
  generated parser, symtable, and compile golden files are tracked, so a regeneration
  is a legitimate commit when it is the point of the change.
- `parser/y.go` and `parser/y.output` come from goyacc. Regenerate them with
  `go generate ./parser/`, which runs `goyacc -v y.output grammar.y`. Never hand-edit
  them.
- The `*_data_test.go` golden files (`parser/grammar_data_test.go`,
  `symtable/symtable_data_test.go`, `compile/compile_data_test.go`) are written by
  Python scripts: `make_grammar_test.py`, `make_symtable_test.py`, and
  `make_compile_test.py`. They need a Python 3.4 interpreter, so they are hard to
  regenerate locally. Treat the golden files as read-only unless the task is about
  changing the expected output.
- Keep the package dependency order intact. The real graph, measured from the
  non-test imports, is:

      py            (base: no internal package imports)
      ast   -> py
      parser-> py
      symtable -> ast, parser, py
      vm     -> py
      compile-> ast, parser, symtable, py, vm
      stdlib -> compile, py
      repl   -> py, stdlib, vm

  A new import that points the other way, for example `py` importing `compile`, is a
  design error. `compile` and `stdlib` are the two places where a cycle is most
  tempting.
- Do not touch `LICENSE`, `.goreleaser.yml`, or the CI workflow unless the task is
  about packaging or CI.

## Hard requirements

These four rules are absolute. They override any other guidance in this file,
in `CONTRIBUTE.md`, in `specs/`, or in an individual task request.

The full text, with examples and the commit-splitting procedure, is in
`specs/00-hard-requirements.md`.

1. **Always add documentation to all code created or modified.** Every function,
   type, method and non-obvious block. Exported identifiers get a doc comment
   starting with the identifier name. Update the doc comment when you change
   the behaviour, so it never contradicts the code.

2. **Always add tests, and never modify tests and code at the same time.** A
   commit changes either the production code or the tests, never both. A commit
   that touches only tests needs a message explaining what was wrong with the
   old expectation. The compile, symtable and grammar golden data are test
   data: regenerating them is its own commit, and it must name the CPython
   version that produced them.

3. **A failing test is a good outcome. Diagnose it with the person; never fix
   it automatically.** Do not delete, weaken, skip or rewrite a failing test,
   and never regenerate a golden file to match wrong output. Report the
   failure, present the evidence, and agree the fix with the person first.

4. **All code must be tested unless it is documented as untestable. Only a
   person, together with the agent's guidance, can declare code untestable.**
   The agent may identify a candidate and explain it. A bare `// TODO: add
   tests` is not documentation of untestability.

A work item is not done because the tests are green. It is done when the tests
are green because the code is right, and the person has reviewed it.

## Scope

Implement the artifact the task names. If a different approach looks better, build the
named artifact first and mention the alternative in one line. Do not substitute your
preferred solution for the requested one.

Do not stop at a plan. The deliverable is working, tested code on disk.

When you find a bug, look for the same flaw in sibling call paths and fix the class of
problem, not only the reported site.

## Reference

- `specs/00-hard-requirements.md` for the four hard engineering rules, with
  examples and the commit-splitting procedure.
- `specs/02-language-upgrade/04-code-style-and-testing.md` for the code style,
  the five test styles and where the test data comes from.
- `README.md` for what gpython is and its status.
- `CONTRIBUTE.md` for the upstream contribution rules and commit format.
- `notes.txt` for the author's list of ideas and known gaps.
- `RELEASE.md` for the goreleaser release procedure.
