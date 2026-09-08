package main

import (
	"strings"
	"testing"
)

// python-ban-guard: allow-file — build directives and recipes below are inert scanner inputs.

// TestBuildExecutionSurfaces pins executable selection and physical source positions.
func TestBuildExecutionSurfaces(t *testing.T) {
	tests := []struct {
		name, path, source, want string
		wantError                bool
	}{
		{"generate direct", "tools.go", "package tools\n//go:generate python3 --version\n", "tools.go:2: Python invocation", false},
		{"generate invalid package is ignored", "tools.go", "package 123\n//go:generate python3 --version\n", "", false},
		{"generate tab", "tools.go", "package tools\n//go:generate\tpip3 --version\n", "tools.go:2: Python invocation", false},
		{"generate quoted", "tools.go", "package tools\n//go:generate \"pyth\\x6fn3\" --version\n", "tools.go:2: Python invocation", false},
		{"generate alias", "tools.go", "package tools\n//go:generate -command gen python3\n//go:generate gen --version\n", "tools.go:3: Python invocation", false},
		{"generate alias expands at definition", "tools.go", "package tools\n//go:generate -command gen python$GOLINE\n\n\n//go:generate gen --version\n", "tools.go:5: Python invocation `python2 --version`", false},
		{"generate alias escaped dollar expands at use", "tools.go", "package tools\n//go:generate -command gen python${DOLLAR}GOLINE\n//go:generate gen --version\n", "tools.go:3: Python invocation `python3 --version`", false},
		{"generate unused alias", "tools.go", "package tools\n//go:generate -command gen python3\n", "", false},
		{"generate shell alias", "tools.go", "package tools\n//go:generate -command check sh -c\n//go:generate check \"python3 --version\"\n", "tools.go:3: Python invocation", false},
		{"generate literal punctuation", "tools.go", "package tools\n//go:generate echo safe ; python3 --version\n", "", false},
		{"generate quoted argument", "tools.go", "package tools\n//go:generate echo \"python3 --version\"\n", "", false},
		{"generate indented data", "tools.go", "package tools\n //go:generate python3 --version\n", "", false},
		{"generate spaced comment", "tools.go", "package tools\n// go:generate python3 --version\n", "", false},
		{"generate raw string directive", "tools.go", "package tools\nvar example = `\n//go:generate python3 --version\n`\n", "tools.go:3: Python invocation", false},
		{"generate single quotes are literal", "tools.go", "package tools\n//go:generate 'python3' --version\n", "", false},
		{"generate package variable", "tools.go", "package python3\n//go:generate $GOPACKAGE --version\n", "tools.go:2: Python invocation", false},
		{"generate line variable", "tools.go", "package tools\n\n//go:generate python$GOLINE --version\n", "tools.go:3: Python invocation", false},
		{"generate unknown environment", "tools.go", "package tools\n//go:generate $BUILD_GENERATOR python3\n", "", false},
		{"generate dollar for nested shell", "tools.go", "package tools\n//go:generate sh -c \"$DOLLAR{BUILD_GENERATOR} python3\"\n", "", false},
		{"generate malformed quote", "tools.go", "package tools\n//go:generate \"python3\n", "", true},
		{"generate quote adjacency", "tools.go", "package tools\n//go:generate \"python\"3\n", "", true},
		{"make silent", "Makefile", "check:\n\t@python3 --version\n", "Makefile:2: Python invocation", false},
		{"make ignore", "makefile", "check:\n\t-pip3 --version\n", "makefile:2: Python invocation", false},
		{"make force", "GNUmakefile", "check:\n\t+pytest\n", "GNUmakefile:2: Python invocation", false},
		{"make combined prefixes", "checks.mk", "check:\n\t -@+ python3 --version\n", "checks.mk:2: Python invocation", false},
		{"make inline recipe", "Makefile", "check: ; @python3 --version\n", "Makefile:1: Python invocation", false},
		{"make unused assignment", "Makefile", "TOOL = python3\ncheck:\n\t@echo safe\n", "", false},
		{"make literal variable command", "Makefile", "TOOL = python3\ncheck:\n\t@$(TOOL) --version\n", "Makefile:3: Python invocation", false},
		{"make empty definition blocks conditional assignment", "Makefile", "TOOL =\nTOOL ?= python3\ncheck:\n\t@$(TOOL) --version\n", "", false},
		{"make unknown definition blocks conditional assignment", "Makefile", "TOOL = $(RUNTIME)\nTOOL ?= python3\ncheck:\n\t@$(TOOL) --version\n", "unresolved build-surface command", false},
		{"make shell assignment invalidates literal", "Makefile", "TOOL = python3\nTOOL != printf echo\ncheck:\n\t@$(TOOL) --version\n", "unresolved build-surface command", false},
		{"make immediate variable reference stays unknown", "Makefile", "TOOL := $(LATER)\nLATER = python3\ncheck:\n\t@$(TOOL) --version\n", "unresolved build-surface command", false},
		{"make recursive variable reference stays unknown", "Makefile", "TOOL = $(LATER)\nLATER = python3\ncheck:\n\t@$(TOOL) --version\n", "unresolved build-surface command", false},
		{"make escaped variable value stays unknown", "Makefile", "TOOL := $$RUNTIME\ncheck:\n\t@$(TOOL) python3\n", "unresolved build-surface command", false},
		{"make unknown command", "Makefile", "check:\n\t@$(DYNAMIC_TOOL) python3\n", "unresolved build-surface command", false},
		{"make dollar shell expansion", "Makefile", "check:\n\t@echo $$(printf python3)\n", "", false},
		{"make shell substitution executes", "Makefile", "check:\n\t@echo $$(python3 --version)\n", "Makefile:2: Python invocation", false},
		{"make argument data", "Makefile", "check:\n\t@echo python3 --version\n", "", false},
		{"make define data", "Makefile", "define SCRIPT\n\t@python3 --version\nendef\ncheck:\n\t@echo safe\n", "", false},
		{"make define comment terminator", "Makefile", "define SCRIPT\n\t@echo safe\nendef # done\ncheck:\n\t@python3 --version\n", "Makefile:5: Python invocation", false},
		{"make conditional comment terminator", "Makefile", "ifeq (1,1)\nINNER = 1\nendif # done\nTOOL = python3\ncheck:\n\t@$(TOOL) --version\n", "Makefile:6: Python invocation", false},
		{"make escaped hash is not a comment terminator", "Makefile", "define SCRIPT\n\t@echo safe\nendef\\# done\ncheck:\n\t@python3 --version\n", "", false},
		{"make comment data", "Makefile", "# check: ; python3\ncheck:\n\t@# python3 --version\n", "", false},
		{"make continuations", "Makefile", "check:\n\t@echo safe; \\\n\tpython3 --version\n", "Makefile:3: Python invocation", false},
		{"make continuation argument", "Makefile", "check:\n\t@echo \\\n\tpython3 --version\n", "", false},
		{"make continuation prefix stays data", "Makefile", "check:\n\t@echo safe; \\\n\t@python3 --version\n", "", false},
		{"make custom recipe prefix", "Makefile", ".RECIPEPREFIX = >\ncheck:\n>@python3 --version\n", "Makefile:3: Python invocation", false},
		{"make malformed recipe", "Makefile", "check:\n\t@if true; then\n", "", true},
		{"make allow marker", "Makefile", "# python-ban-guard: allow-file — fixture\ncheck:\n\t@python3 --version\n", "", false},
		{"dockerfile env apostrophe value", "Dockerfile", "FROM alpine\nENV DESCRIPTION=\"Devantler's tool\"\nRUN echo safe\n", "", false},
		{"dockerfile env interpreter still resolves", "Dockerfile", "FROM alpine\nENV TOOL=python3\nRUN $TOOL --version\n", "Python invocation", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: tt.path, seen: map[string]bool{}}
			_, err := s.file(tt.source)
			if (err != nil) != tt.wantError {
				t.Fatalf("error = %v, wantError %v", err, tt.wantError)
			}
			got := strings.Join(s.hits, "\n")
			if tt.want == "" && got != "" || tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("hits = %q, want %q", got, tt.want)
			}
		})
	}
}

// TestGenerateAliasesAreFileLocal rejects alias leakage between independent inputs.
func TestGenerateAliasesAreFileLocal(t *testing.T) {
	s := scanner{path: "first.go", seen: map[string]bool{}}
	if _, err := s.file("package tools\n//go:generate -command gen python3\n"); err != nil {
		t.Fatal(err)
	}
	s.path = "second.go"
	if _, err := s.file("package tools\n//go:generate gen --version\n"); err != nil {
		t.Fatal(err)
	}
	if len(s.hits) != 0 {
		t.Fatalf("alias definition leaked: %v", s.hits)
	}
}

// TestGenerateDoesNotReadHostEnvironment ensures unknown argv never promotes its tail.
func TestGenerateDoesNotReadHostEnvironment(t *testing.T) {
	t.Setenv("BUILD_GENERATOR", "python3")
	s := scanner{path: "tools.go", seen: map[string]bool{}}
	if _, err := s.file("package tools\n//go:generate $BUILD_GENERATOR --version\n"); err != nil {
		t.Fatal(err)
	}
	if len(s.hits) != 0 {
		t.Fatalf("host environment influenced scan: %v", s.hits)
	}
}

// TestMakeScopedShellSelection follows target and pattern interpreter overrides
// without treating assignments in recipe arguments as declarations.
func TestMakeScopedShellSelection(t *testing.T) {
	tests := []struct{ name, source, want string }{
		{"target literal", "check: SHELL := python3\ncheck:\n\tpass\n", "Makefile:1: Python invocation"},
		{"escaped colon target", "a\\:b: SHELL := python3\na\\:b:\n\t@echo $(SHELL)\n", "Makefile:1: Python invocation"},
		{"escaped colon multiple targets", "a\\:b c: private SHELL = /usr/bin/python3\nc:\n\tpass\n", "Makefile:1: Python invocation"},
		{"escaped colon pattern", "a\\:%.checked: SHELL := python3\na\\:%.checked:\n\tpass\n", "Makefile:1: Python invocation"},
		{"target function colon", "$(subst :,x,a:b): SHELL := python3\naxb:\n\t@echo $(SHELL)\n", "Makefile:1: Python invocation"},
		{"nested target function colon", "${subst :,x,${subst q,:,aqb}}: SHELL := python3\naxb:\n\t@echo $(SHELL)\n", "Makefile:1: Python invocation"},
		{"escaped backslash before rule separator", "a\\\\: SHELL := python3\na\\\\:\n\tpass\n", "Makefile:1: Python invocation"},
		{"safe escaped colon target", "a\\:b: SHELL := /bin/sh\na\\:b:\n\techo python3\n", ""},
		{"comment colon is data", "check # example: SHELL := python3\ncheck:\n\techo safe\n", ""},
		{"pattern literal", "%.checked: SHELL = /usr/bin/python3\n%.checked:\n\tpass\n", "Makefile:1: Python invocation"},
		{"multiple targets", "check verify: SHELL ::= python3\ncheck:\n\tpass\n", "Makefile:1: Python invocation"},
		{"double colon", "check:: SHELL := python3\ncheck::\n\tpass\n", "Makefile:1: Python invocation"},
		{"combined modifiers", "check: private override export SHELL := python3\ncheck:\n\tpass\n", "Makefile:1: Python invocation"},
		{"unexport modifier", "check: unexport SHELL := python3\ncheck:\n\tpass\n", "Makefile:1: Python invocation"},
		{"continued declaration", "check: SHELL := \\\n python3\ncheck:\n\tpass\n", "Makefile:1: Python invocation"},
		{"safe target shell", "check: SHELL := /bin/sh\ncheck:\n\techo python3\n", ""},
		{"safe pattern shell", "%.checked: private SHELL := /bin/bash\n%.checked:\n\techo safe\n", ""},
		{"comment data", "# check: SHELL := python3\ncheck:\n\techo safe\n", ""},
		{"inline recipe argument data", "check: ; echo SHELL := python3\n", ""},
		{"other scoped variable data", "check: TOOL := python3\ncheck:\n\techo safe\n", ""},
		{"dynamic shell", "check: SHELL := $(INTERPRETER)\ncheck:\n\tpass\n", "Makefile:1: unresolved build-surface command"},
		{"escaped shell", "check: SHELL := pyth\\on3\ncheck:\n\tpass\n", "Makefile:1: unresolved build-surface command"},
		{"append shell", "check: SHELL += python3\ncheck:\n\tpass\n", "Makefile:1: unresolved build-surface command"},
		{"shell assignment result", "check: SHELL != printf python3\ncheck:\n\tpass\n", "Makefile:1: unresolved build-surface command"},
		{"empty shell", "check: SHELL :=\ncheck:\n\tpass\n", "Makefile:1: unresolved build-surface command"},
		{"allow marker", "# python-ban-guard: allow-file — inert fixture\ncheck: SHELL := python3\ncheck:\n\tpass\n", ""},
		{"allow marker unresolved", "# python-ban-guard: allow-file — inert fixture\ncheck: SHELL := $(INTERPRETER)\ncheck:\n\tpass\n", ""},
		{"unknown shell cannot bind to a make variable", "__python_ban_make_unknown := /bin/sh\ncheck: SHELL := $(INTERPRETER)\ncheck:\n\tpass\n", "Makefile:2: unresolved build-surface command"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: "Makefile", seen: map[string]bool{}}
			if _, err := s.file(tt.source); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			got := strings.Join(s.hits, "\n")
			if tt.want == "" && got != "" || tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("hits = %q, want %q", got, tt.want)
			}
		})
	}
}
