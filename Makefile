# Makefile for gpython.
#
# Every binary this Makefile produces lands in bin/. Nothing is written
# outside bin/ except the generated Go sources, which are tracked in git.
#
# The external generator tools (stringer, goyacc) are installed into
# bin/tools/ so that a build never depends on what happens to be on $PATH.
#
# Run `make help` for the list of targets.

SHELL := /bin/sh

# The repository root. Every path in this Makefile is derived from it, so a
# target that changes directory does not break the paths that follow.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# ---------------------------------------------------------------- variables

MODULE      := github.com/go-python/gpython
BIN         := $(ROOT)/bin
TOOLS       := $(BIN)/tools
GO          ?= go
GOFLAGS     ?=
TAGS        ?= -tags=ci
COVERPKG    ?= -coverpkg=$(MODULE)/...
PYTHON      ?= python3

# The tools the code generators need. Pinned so a regeneration is
# reproducible rather than depending on whatever is newest.
STRINGER_PKG := golang.org/x/tools/cmd/stringer@v0.53.0
GOYACC_PKG   := golang.org/x/tools/cmd/goyacc@v0.53.0

STRINGER := $(TOOLS)/stringer
GOYACC   := $(TOOLS)/goyacc

# The licence header every generated file in this repository carries.
LICENSE_HEADER := $(BIN)/.license-header.txt

# The packages that build a binary.
MAIN_PKG    := .
TESTPARSER  := ./parser/testparser

# The Go packages that make up the module.
GOPKGS := ./...

# ------------------------------------------------------------------ helpers

.PHONY: help
help: ## Show this help
	@echo "gpython - make targets"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "All binaries are written to $(BIN)/."

# ------------------------------------------------------------------- build

.PHONY: all
all: build ## Build everything (default)

.PHONY: build
build: $(BIN)/gpython $(BIN)/testparser ## Build the binaries into bin/

$(BIN)/gpython: $(shell find . -name '*.go' -not -path './$(BIN)/*' 2>/dev/null) go.mod go.sum
	@mkdir -p $(BIN)
	$(GO) build $(GOFLAGS) -o $@ $(MAIN_PKG)

$(BIN)/testparser: $(shell find . -name '*.go' -not -path './$(BIN)/*' 2>/dev/null) go.mod go.sum
	@mkdir -p $(BIN)
	$(GO) build $(GOFLAGS) -o $@ $(TESTPARSER)

.PHONY: install
install: ## Install the gpython binary into GOBIN
	$(GO) install $(GOFLAGS) $(TAGS) $(GOPKGS)

.PHONY: cross
cross: ## Cross compile gpython for linux, darwin and windows into bin/
	@mkdir -p $(BIN)
	@for os in linux darwin windows; do \
		for arch in amd64 386 arm64; do \
			ext=""; [ "$$os" = "windows" ] && ext=".exe"; \
			echo "  $(GO) build $$os/$$arch -> $(BIN)/gpython-$$os-$$arch$$ext"; \
			$(GO) build $(GOFLAGS) -o $(BIN)/gpython-$$os-$$arch$$ext $(MAIN_PKG) || exit 1; \
		done; \
	done

.PHONY: clean
clean: ## Remove the built binaries (keeps bin/tools)
	rm -f $(BIN)/gpython $(BIN)/testparser $(BIN)/gpython-*
	rm -rf $(BIN)/dist

.PHONY: distclean
distclean: clean ## Remove the built binaries AND the installed tools
	rm -rf $(TOOLS) $(BIN)/.license-header.txt

# -------------------------------------------------------------------- test

.PHONY: test
test: ## Run the test suite
	$(GO) test $(TAGS) $(GOFLAGS) $(GOPKGS)

.PHONY: test-race
test-race: ## Run the test suite with the race detector
	$(GO) test $(TAGS) $(GOFLAGS) -race $(GOPKGS)

.PHONY: test-386
test-386: ## Run the test suite for 32-bit x86
	GOARCH=386 $(GO) test $(TAGS) $(GOFLAGS) $(GOPKGS)

.PHONY: test-ci
test-ci: ## Run the test suite the way CI does, with coverage
	$(GO) run ./ci/run-tests.go $(TAGS) -race $(COVERPKG)

.PHONY: cover
cover: ## Run the tests and report coverage
	$(GO) test $(TAGS) $(COVERPKG) -coverprofile=$(BIN)/cover.out $(GOPKGS)
	$(GO) tool cover -func=$(BIN)/cover.out

.PHONY: bench
bench: ## Run the benchmarks
	$(GO) test $(TAGS) -bench=. -benchmem $(GOPKGS)

.PHONY: difftest
difftest: ## Run the differential test suite (needs python3.4 or python3.15)
	$(PYTHON) py3test.py

# ------------------------------------------------------------------- check

.PHONY: check
check: fmt-check vet staticcheck test ## Run every check CI runs

.PHONY: fmt
fmt: ## Format the Go sources
	gofmt -w -s .

.PHONY: fmt-check
fmt-check: ## Fail if any Go source is not gofmt clean
	@out="$$(gofmt -l -s . 2>&1)"; \
	if [ -n "$$out" ]; then \
		echo "These files are not gofmt clean:"; echo "$$out"; exit 1; \
	fi

.PHONY: vet
vet: ## Run go vet
	$(GO) vet $(GOPKGS)

.PHONY: staticcheck
staticcheck: $(TOOLS)/staticcheck ## Run staticcheck (installed into bin/tools)
	$(abspath $(TOOLS)/staticcheck) ./...

# ------------------------------------------------------------------- tools

$(TOOLS):
	@mkdir -p $(TOOLS)

.PHONY: tools
tools: $(STRINGER) $(GOYACC) ## Install the external generator tools into bin/tools

$(STRINGER): | $(TOOLS)
	GOBIN=$(abspath $(TOOLS)) $(GO) install $(STRINGER_PKG)

$(GOYACC): | $(TOOLS)
	GOBIN=$(abspath $(TOOLS)) $(GO) install $(GOYACC_PKG)

$(TOOLS)/staticcheck: | $(TOOLS)
	GOBIN=$(abspath $(TOOLS)) $(GO) install honnef.co/go/tools/cmd/staticcheck@v0.8.2

.PHONY: tools-list
tools-list: ## Show the generator tools and whether they are installed
	@for t in $(STRINGER) $(GOYACC) $(TOOLS)/staticcheck; do \
		if [ -x "$$t" ]; then echo "  installed    $$t"; \
		else echo "  NOT INSTALLED  $$t"; fi; \
	done

# -------------------------------------------------------------- generators

$(LICENSE_HEADER):
	@mkdir -p $(BIN)
	@printf '%s\n' \
		'// Copyright 2018 The go-python Authors.  All rights reserved.' \
		'// Use of this source code is governed by a BSD-style' \
		'// license that can be found in the LICENSE file.' \
		'' > $@

# Prepend the licence header to a generated file. The generators do not
# emit it, but every tracked generated file in this repository has it.
# FILES is a space separated list of paths relative to $(ROOT).
.PHONY: _add-license
_add-license: $(LICENSE_HEADER)
	@for f in $(FILES); do \
		p="$(ROOT)/$$f"; \
		if [ ! -f "$$p" ]; then echo "no such file: $$f" >&2; exit 1; fi; \
		if head -1 "$$p" | grep -q '^// Copyright'; then \
			echo "  $$f: licence header already present"; \
		else \
			tmp="$$p.tmp"; \
			cat $(LICENSE_HEADER) "$$p" > "$$tmp"; \
			mv "$$tmp" "$$p"; \
			echo "  $$f: licence header added"; \
		fi; \
	done

.PHONY: generate
generate: generate-arithmetic generate-grammar generate-stringer ## Run every code generator

.PHONY: generate-arithmetic
generate-arithmetic: ## Regenerate py/arithmetic.go
	@echo "  py/arithmetic.go"
	@cd $(ROOT)/py && $(GO) run gen.go
	@gofmt -w -s $(ROOT)/py/arithmetic.go
	@$(MAKE) --no-print-directory _add-license FILES=py/arithmetic.go

.PHONY: generate-grammar
generate-grammar: $(GOYACC) ## Regenerate parser/y.go from parser/grammar.y
	@echo "  parser/y.go"
	@cd $(ROOT)/parser && $(abspath $(GOYACC)) -v y.output grammar.y
	@gofmt -w -s $(ROOT)/parser/y.go
	@$(MAKE) --no-print-directory _add-license FILES=parser/y.go

.PHONY: generate-stringer
generate-stringer: $(STRINGER) ## Regenerate the stringer files
	@echo "  symtable/stringer.go"
	@cd $(ROOT)/symtable && $(abspath $(STRINGER)) -type=Scope,BlockType -output stringer.go
	@gofmt -w -s $(ROOT)/symtable/stringer.go
	@$(MAKE) --no-print-directory _add-license FILES=symtable/stringer.go
	@echo "  vm/stringer.go"
	@cd $(ROOT)/vm && $(abspath $(STRINGER)) -type=vmStatus,OpCode -output stringer.go
	@gofmt -w -s $(ROOT)/vm/stringer.go
	@$(MAKE) --no-print-directory _add-license FILES=vm/stringer.go

# The ASDL generator turns ast/Python.asdl into ast/Python-ast.go.
# The name follows the ASDL module name, so it is not a fixed path.
.PHONY: generate-asdl
generate-asdl: ## Regenerate the AST from ast/Python.asdl
	@echo "  ast/Python-ast.go"
	@cd $(ROOT)/ast && $(PYTHON) asdl_go.py Python.asdl
	@$(MAKE) --no-print-directory _add-license FILES=ast/Python-ast.go

# The golden test data is generated by CPython, not by gpython. These
# targets therefore need a CPython interpreter of the right version and
# they must never be run against gpython's own output.
.PHONY: generate-testdata
generate-testdata: ## Regenerate the golden test data (needs CPython 3.15)
	@echo "  compile/compile_data_test.go"
	@cd compile && $(PYTHON) make_compile_test.py
	@echo "  symtable/symtable_data_test.go"
	@cd symtable && $(PYTHON) make_symtable_test.py
	@echo "  parser/grammar_data_test.go"
	@cd parser && $(PYTHON) make_grammar_test.py

.PHONY: generate-check
generate-check: ## Regenerate everything and show what changed
	@$(MAKE) --no-print-directory generate
	@git status --short
	@echo ""
	@echo "Review the diff. If the golden data changed, it must be regenerated"
	@echo "from CPython, never from gpython's own output."

# ------------------------------------------------------------------ misc

.PHONY: run
run: $(BIN)/gpython ## Build and run gpython
	@$(BIN)/gpython

.PHONY: version
version: ## Print the version
	@$(GO) run $(MAIN_PKG) --version 2>/dev/null || cat version.go

.PHONY: tree
tree: ## Show the package layout
	@$(GO) list ./... | sed 's|$(MODULE)|.|'
