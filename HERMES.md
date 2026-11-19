# HERMES.md

Instructions for Hermes Agent working in this repository.

**This file must stay under 100 lines.** Anything that does not fit goes into `specs/`,
and this file points to it. Check with `wc -l HERMES.md` before committing.

Implement the artifact the task names. If a different approach looks better, build the
named artifact first and mention the alternative in one line. Do not stop at a plan.
## Project
gpython is a Python 3.4 interpreter written in Go. It parses Python, compiles it to a
bytecode-like instruction set, and runs it in a multi-context VM. It embeds into Go
applications. Module path: `github.com/go-python/gpython`. Go 1.27 in `go.mod` (CI runs
1.27.x and 1.26.x). Packages: `py` (the runtime object model, the base package), `ast`,
`parser`, `symtable`, `compile`, `vm`, `stdlib`, `repl`, `pytest`, `importlib`, `ci`.
**Layout, dependency graph, code generators and the full style rules:
`specs/02-language-upgrade/07-repository-guide.md`.**
## Commands
Use the Makefile. `make help` lists every target. Every binary lands in `bin/`, which is
never committed.

    make build     # bin/gpython and bin/testparser
    make test      # go test -tags=ci ./...
    make check     # fmt-check + vet + staticcheck + test
    make generate  # all four code generators
    make tools     # install stringer, goyacc, staticcheck into bin/tools
CI passes `-tags=ci` to every go command. No source file is guarded by that tag, so it
changes nothing today; it keeps your local run identical to CI. Use `make test-ci` when
a change touches more than one package.
## Testing conventions
Go unit tests: `*_test.go` next to the code, table-driven where several cases exist.
Python test files: a `.py` file under a `tests/` directory next to the package, run by
`pytest.RunTests(t, "tests")`. Adding one needs no Go change.
The harness compares program output against golden files in `testdata/`. The compile,
symtable and grammar golden data are **generated from CPython**, not from gpython.
Never regenerate them from gpython's own output with `-regen`: that would rewrite the
oracle to match the implementation. `-regen` is only for a stdlib module's
`testdata/test_golden.txt`.
Every new behavior needs a test. Do not edit a test to make it pass unless the test
was wrong. **Detail: `specs/02-language-upgrade/04-code-style-and-testing.md`.**
## Code conventions
Follow Go style, as in `CONTRIBUTE.md`. The full rules, the licence header, the
`I__dunder__` naming and the comment style are in
`specs/02-language-upgrade/07-repository-guide.md`.
- Run `gofmt` on every file you touch.
- Exported identifiers carry doc comments that start with the identifier name.
- Never ignore an error without a comment saying why it is safe.
- No underscores in Go names. Use camelCase.
- Pass error text to a formatting function as an **argument**, never as the format
  string. Go 1.27's vet enforces this.
- Do not add a dependency to `go.mod` without a clear reason.

## Commit messages
Follow `CONTRIBUTE.md`: a `py: ` prefix, the change in the body, every package named
when the change spans packages, `Fixes go-python/gpython#NN` for an issue.
Every commit message ends with the attribution line, on its own line:

    Authored-By: Bennie Kahler-Venter <bennie@obsidian.co.za>

Never write a `Co-Authored-By:` trailer, and never name a model, vendor, or agent in
a commit message. Both the author and the committer must be
`Bennie Kahler-Venter <bennie@obsidian.co.za>`. Never rewrite other people's commits.
## Working in this repo
- Commit at the end of every prompt. Stage all changes, run the project's checks,
  commit, then push to `origin HEAD`. Never force push. Do not rewrite published
  history.
- Do not commit generated files unless the repository already tracks them.
- `parser/y.go` and `parser/y.output` come from goyacc. Never hand-edit them; use
  `make generate-grammar`.
- The `*_data_test.go` golden files need the right CPython version. Treat them as
  read-only unless the task is about changing the expected output.
- Keep the package dependency order intact: `py` is the base package. An import that
  points the other way is a design error.
- Do not touch `LICENSE`, `.goreleaser.yml`, or the CI workflow unless the task is
  about packaging or CI.
## Hard requirements
These four rules are absolute. They override any other guidance in this file, in
`CONTRIBUTE.md`, in `specs/`, or in an individual task request.
**Full text: `specs/00-hard-requirements.md`.**

1. **Always add documentation to all code created or modified.** Update the doc
   comment when you change the behaviour, so it never contradicts the code.
2. **Always add tests, and never modify tests and code at the same time.** A commit
   changes either the production code or the tests, never both.
3. **A failing test is a good outcome. Diagnose it with the person; never fix it
   automatically.** Do not delete, weaken, skip or rewrite a failing test.
4. **All code must be tested unless it is documented as untestable. Only a person,
   together with the agent's guidance, can declare code untestable.**
## Reference
- `specs/README.md` - the specification index and reading order.
- `specs/00-hard-requirements.md` - the four hard rules, the commit-splitting procedure.
- `specs/02-language-upgrade/04-code-style-and-testing.md` - code style, the test styles.
- `specs/02-language-upgrade/05-code-gap-analysis.md` - what gpython's code is missing.
- `specs/02-language-upgrade/06-porting-and-build-system.md` - Go 1.27, the build system.
- `specs/02-language-upgrade/07-repository-guide.md` - layout, dependency graph, code
  generators, the style rules.
- `specs/02-language-upgrade/08-hand-written-parsers.md` - hand-written parsers.
- `README.md`, `CONTRIBUTE.md`, `notes.txt`, `RELEASE.md` - the project itself.
