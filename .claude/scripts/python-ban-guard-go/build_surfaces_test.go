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
		{"generate alias", "tools.go", "package tools\n//go:generate -command py python3\n//go:generate py --version\n", "tools.go:3: Python invocation", false},
		{"generate alias expands at definition", "tools.go", "package tools\n//go:generate -command py python$GOLINE\n\n\n//go:generate py --version\n", "tools.go:5: Python invocation `python2 --version`", false},
		{"generate alias escaped dollar expands at use", "tools.go", "package tools\n//go:generate -command py python${DOLLAR}GOLINE\n//go:generate py --version\n", "tools.go:3: Python invocation `python3 --version`", false},
		{"generate unused alias", "tools.go", "package tools\n//go:generate -command py python3\n", "", false},
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
		{"make unknown definition blocks conditional assignment", "Makefile", "TOOL = $(RUNTIME)\nTOOL ?= python3\ncheck:\n\t@$(TOOL) --version\n", "", false},
		{"make shell assignment invalidates literal", "Makefile", "TOOL = python3\nTOOL != printf echo\ncheck:\n\t@$(TOOL) --version\n", "", false},
		{"make immediate variable reference stays unknown", "Makefile", "TOOL := $(LATER)\nLATER = python3\ncheck:\n\t@$(TOOL) --version\n", "", false},
		{"make recursive variable reference stays unknown", "Makefile", "TOOL = $(LATER)\nLATER = python3\ncheck:\n\t@$(TOOL) --version\n", "", false},
		{"make escaped variable value stays unknown", "Makefile", "TOOL := $$RUNTIME\ncheck:\n\t@$(TOOL) python3\n", "", false},
		{"make unknown command", "Makefile", "check:\n\t@$(DYNAMIC_TOOL) python3\n", "", false},
		{"make dollar shell expansion", "Makefile", "check:\n\t@echo $$(printf python3)\n", "", false},
		{"make shell substitution executes", "Makefile", "check:\n\t@echo $$(python3 --version)\n", "Makefile:2: Python invocation", false},
		{"make argument data", "Makefile", "check:\n\t@echo python3 --version\n", "", false},
		{"make define data", "Makefile", "define SCRIPT\n\t@python3 --version\nendef\ncheck:\n\t@echo safe\n", "", false},
		{"make comment data", "Makefile", "# check: ; python3\ncheck:\n\t@# python3 --version\n", "", false},
		{"make continuations", "Makefile", "check:\n\t@echo safe; \\\n\tpython3 --version\n", "Makefile:3: Python invocation", false},
		{"make continuation argument", "Makefile", "check:\n\t@echo \\\n\tpython3 --version\n", "", false},
		{"make continuation prefix stays data", "Makefile", "check:\n\t@echo safe; \\\n\t@python3 --version\n", "", false},
		{"make custom recipe prefix", "Makefile", ".RECIPEPREFIX = >\ncheck:\n>@python3 --version\n", "Makefile:3: Python invocation", false},
		{"make malformed recipe", "Makefile", "check:\n\t@if true; then\n", "", true},
		{"make allow marker", "Makefile", "# python-ban-guard: allow-file — fixture\ncheck:\n\t@python3 --version\n", "", false},
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
	if _, err := s.file("package tools\n//go:generate -command py python3\n"); err != nil {
		t.Fatal(err)
	}
	s.path = "second.go"
	if _, err := s.file("package tools\n//go:generate py --version\n"); err != nil {
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
