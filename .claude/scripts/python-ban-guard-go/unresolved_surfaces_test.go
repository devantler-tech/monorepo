package main

import (
	"strings"
	"testing"
)

// python-ban-guard: allow-file — the fixtures below are inert scanner inputs.

// TestUnresolvedBuildSurfacesAreReported covers the build-surface evasion class:
// a construct the parser cannot statically resolve must never leave the file
// looking clean. Each case runs Python at build time.
func TestUnresolvedBuildSurfacesAreReported(t *testing.T) {
	tests := []struct{ name, path, source string }{
		{"make shell assignment operator", "Makefile", "VERSION != python3 --version\ncheck:\n\t@echo safe\n"},
		{"make shell function in recipe", "Makefile", "check:\n\t@echo $(shell python3 --version)\n"},
		{"make selected recipe shell", "Makefile", "SHELL := python3\ncheck:\n\tprint\n"},
		{"make escaped hash before command", "Makefile", "TOOL = printf '\\#'; python3 --version\ncheck:\n\t@$(TOOL)\n"},
		{"make dynamic command word", "Makefile", "check:\n\t@$(DYNAMIC_TOOL) python3\n"},
		{"dockerfile healthcheck", "Dockerfile", "FROM alpine\nHEALTHCHECK CMD [\"python3\", \"--version\"]\n"},
		{"dockerfile onbuild", "Dockerfile", "FROM alpine\nONBUILD RUN python3 --version\n"},
		{"dockerfile env propagation", "Dockerfile", "FROM alpine\nENV TOOL=python3\nRUN \"$TOOL\" --version\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: tt.path, seen: map[string]bool{}}
			if _, err := s.file(tt.source); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			if len(s.hits) == 0 {
				t.Fatalf("build surface reported clean but runs Python:\n%s", tt.source)
			}
		})
	}
}

// TestWindowsInterpreterSpellings covers the Windows launcher and .exe names.
func TestWindowsInterpreterSpellings(t *testing.T) {
	tests := []struct{ name, path, source string }{
		{"py launcher", "run.sh", "#!/usr/bin/env bash\npy -3 script.py\n"},
		{"python exe", "run.sh", "#!/usr/bin/env bash\npython.exe --version\n"},
		{"python3 exe", "run.sh", "#!/usr/bin/env bash\npython3.exe --version\n"},
		{"pip exe", "run.sh", "#!/usr/bin/env bash\npip3.exe install requests\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: tt.path, seen: map[string]bool{}}
			if _, err := s.file(tt.source); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			if len(s.hits) == 0 {
				t.Fatalf("Windows Python spelling reported clean:\n%s", tt.source)
			}
		})
	}
}

// TestShellBindingsRespectLexicalOrder pins that a literal assignment is not
// applied to an expansion that precedes it, which would be a false positive.
func TestShellBindingsRespectLexicalOrder(t *testing.T) {
	src := "#!/usr/bin/env bash\nunset PYTHON\n\"$PYTHON\" --version || :\nPYTHON=python3\n"
	s := scanner{path: "run.sh", seen: map[string]bool{}}
	if _, err := s.file(src); err != nil {
		t.Fatalf("scan error: %v", err)
	}
	if len(s.hits) != 0 {
		t.Fatalf("binding applied before its assignment: %v", s.hits)
	}
}

// TestResolvedBuildSurfacesStayClean is the negative control: a build surface
// the parser fully resolves and that runs no Python must remain clean, so the
// class fix above cannot pass by reporting everything.
func TestResolvedBuildSurfacesStayClean(t *testing.T) {
	tests := []struct{ name, path, source string }{
		{"make literal recipe", "Makefile", "check:\n\t@echo safe\n"},
		{"make literal variable", "Makefile", "TOOL = echo\ncheck:\n\t@$(TOOL) safe\n"},
		{"dockerfile literal run", "Dockerfile", "FROM alpine\nRUN apk add --no-cache curl\n"},
		{"dockerfile literal entrypoint", "Dockerfile", "FROM alpine\nENTRYPOINT [\"/bin/sh\", \"-c\", \"echo safe\"]\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: tt.path, seen: map[string]bool{}}
			if _, err := s.file(tt.source); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			if len(s.hits) != 0 {
				t.Fatalf("resolved clean build surface reported: %v", strings.Join(s.hits, "\n"))
			}
		})
	}
}
