package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func execute(args ...string) (int, string, string) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func writeKB(t *testing.T, path string, kb int) {
	t.Helper()
	data := bytes.Repeat([]byte("x"), kb*1024)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write fixture %s: %v", path, err)
	}
}

func writeSummaryKB(t *testing.T, path string, kb int) {
	t.Helper()
	data := append([]byte("v1\n"), bytes.Repeat([]byte("x"), kb*1024)...)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write summary fixture %s: %v", path, err)
	}
}

func legacyStore(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeKB(t, filepath.Join(dir, "MEMORY.md"), 5)
	return dir
}

func codexStore(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeSummaryKB(t, filepath.Join(dir, "memory_summary.md"), 5)
	writeKB(t, filepath.Join(dir, "MEMORY.md"), 80)
	return dir
}

func TestArgumentValidation(t *testing.T) {
	validStore := legacyStore(t)
	tests := []struct {
		name       string
		args       []string
		wantCode   int
		wantStderr string
	}{
		{
			name:       "missing layout",
			args:       []string{"--dir", validStore},
			wantCode:   2,
			wantStderr: "--layout <legacy|codex> is required",
		},
		{
			name:       "unknown layout",
			args:       []string{"--layout", "other", "--dir", validStore},
			wantCode:   2,
			wantStderr: "unsupported layout",
		},
		{
			name:       "missing directory argument",
			args:       []string{"--layout", "legacy"},
			wantCode:   2,
			wantStderr: "--dir is required",
		},
		{
			name:       "directory does not exist",
			args:       []string{"--layout", "legacy", "--dir", filepath.Join(validStore, "missing")},
			wantCode:   2,
			wantStderr: "memory directory not found",
		},
		{
			name:       "non-numeric threshold",
			args:       []string{"--layout", "legacy", "--dir", validStore, "--threshold-kb", "abc"},
			wantCode:   2,
			wantStderr: "thresholds must be positive integers",
		},
		{
			name:       "zero threshold",
			args:       []string{"--layout", "legacy", "--dir", validStore, "--threshold-kb", "0"},
			wantCode:   2,
			wantStderr: "thresholds must be positive integers",
		},
		{
			name:       "unknown flag",
			args:       []string{"--layout", "legacy", "--dir", validStore, "--bogus"},
			wantCode:   2,
			wantStderr: "unknown argument",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			code, _, stderr := execute(test.args...)
			if code != test.wantCode {
				t.Fatalf("exit code = %d, want %d; stderr=%q", code, test.wantCode, stderr)
			}
			if !strings.Contains(stderr, test.wantStderr) {
				t.Fatalf("stderr %q does not contain %q", stderr, test.wantStderr)
			}
		})
	}
}

func TestLegacyLayout(t *testing.T) {
	t.Run("healthy store", func(t *testing.T) {
		dir := legacyStore(t)
		writeKB(t, filepath.Join(dir, "portfolio-status.md"), 10)
		code, stdout, stderr := execute("--layout", "legacy", "--dir", dir)
		if code != 0 {
			t.Fatalf("exit code = %d, want 0; stdout=%q stderr=%q", code, stdout, stderr)
		}
	})

	t.Run("oversized topic", func(t *testing.T) {
		dir := legacyStore(t)
		writeKB(t, filepath.Join(dir, "portfolio-status.md"), 80)
		code, stdout, _ := execute("--layout", "legacy", "--dir", dir)
		if code != 1 {
			t.Fatalf("exit code = %d, want 1", code)
		}
		for _, expected := range []string{"OVER", "portfolio-status.md", "append"} {
			if !strings.Contains(stdout, expected) {
				t.Fatalf("stdout %q does not contain %q", stdout, expected)
			}
		}
	})

	t.Run("index uses tighter configurable bound", func(t *testing.T) {
		dir := t.TempDir()
		writeKB(t, filepath.Join(dir, "MEMORY.md"), 30)
		code, _, _ := execute("--layout", "legacy", "--dir", dir)
		if code != 1 {
			t.Fatalf("default index exit code = %d, want 1", code)
		}
		code, _, _ = execute("--layout", "legacy", "--dir", dir, "--index-kb", "48")
		if code != 0 {
			t.Fatalf("configured index exit code = %d, want 0", code)
		}
	})

	t.Run("archives nested and non-markdown files are exempt", func(t *testing.T) {
		dir := t.TempDir()
		writeKB(t, filepath.Join(dir, "portfolio-status-archive.md"), 200)
		writeKB(t, filepath.Join(dir, "manifest.tsv"), 200)
		nested := filepath.Join(dir, "nested")
		if err := os.Mkdir(nested, 0o700); err != nil {
			t.Fatalf("create nested fixture: %v", err)
		}
		writeKB(t, filepath.Join(nested, "deep.md"), 200)
		code, _, _ := execute("--layout", "legacy", "--dir", dir)
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
	})

	t.Run("leading zeros stay base ten", func(t *testing.T) {
		dir := legacyStore(t)
		writeKB(t, filepath.Join(dir, "portfolio-status.md"), 80)
		code, stdout, stderr := execute(
			"--layout", "legacy",
			"--dir", dir,
			"--threshold-kb", "048",
			"--index-kb", "024",
		)
		if code != 1 {
			t.Fatalf("exit code = %d, want 1; stdout=%q stderr=%q", code, stdout, stderr)
		}
	})
}

func TestCodexLayout(t *testing.T) {
	t.Run("gates only boot projection", func(t *testing.T) {
		dir := codexStore(t)
		writeKB(t, filepath.Join(dir, "raw_memories.md"), 200)
		writeKB(t, filepath.Join(dir, "future_registry.md"), 120)
		code, stdout, stderr := execute("--layout", "codex", "--dir", dir, "--all")
		if code != 0 {
			t.Fatalf("exit code = %d, want 0; stdout=%q stderr=%q", code, stdout, stderr)
		}
		for _, skipped := range []string{"MEMORY.md", "raw_memories.md", "future_registry.md"} {
			if !strings.Contains(stdout, "skip") || !strings.Contains(stdout, skipped) {
				t.Fatalf("stdout %q does not identify skipped %s", stdout, skipped)
			}
		}
	})

	t.Run("minimal store needs no temporary inputs", func(t *testing.T) {
		dir := codexStore(t)
		code, _, _ := execute("--layout", "codex", "--dir", dir)
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
	})

	t.Run("oversized summary requires refresh and restart", func(t *testing.T) {
		dir := codexStore(t)
		writeSummaryKB(t, filepath.Join(dir, "memory_summary.md"), 30)
		code, stdout, _ := execute("--layout", "codex", "--dir", dir)
		if code != 1 {
			t.Fatalf("exit code = %d, want 1", code)
		}
		for _, expected := range []string{
			"OVER",
			"memory_summary.md",
			"Refresh the Codex boot projection",
			"Restart the run",
			"Do not rewrite MEMORY.md or raw_memories.md",
		} {
			if !strings.Contains(stdout, expected) {
				t.Fatalf("stdout %q does not contain %q", stdout, expected)
			}
		}
		if strings.Contains(stdout, "OVER    80K") || strings.Contains(stdout, "OVER    81K") {
			t.Fatalf("generated MEMORY.md was incorrectly gated: %q", stdout)
		}
	})

	t.Run("requires exact v1 schema", func(t *testing.T) {
		for _, header := range []string{"not-a-version\n", "v2\n"} {
			dir := codexStore(t)
			if err := os.WriteFile(filepath.Join(dir, "memory_summary.md"), []byte(header), 0o600); err != nil {
				t.Fatalf("replace summary header: %v", err)
			}
			code, _, stderr := execute("--layout", "codex", "--dir", dir)
			if code != 2 {
				t.Fatalf("header %q exit code = %d, want 2", header, code)
			}
			if !strings.Contains(stderr, "expected v1 header") {
				t.Fatalf("stderr %q does not name v1 schema", stderr)
			}
		}
	})

	t.Run("requires both persistent files", func(t *testing.T) {
		tests := []struct {
			name    string
			prepare func(t *testing.T, dir string)
			missing string
		}{
			{
				name: "missing summary",
				prepare: func(t *testing.T, dir string) {
					writeKB(t, filepath.Join(dir, "MEMORY.md"), 5)
				},
				missing: "memory_summary.md",
			},
			{
				name: "missing registry",
				prepare: func(t *testing.T, dir string) {
					writeSummaryKB(t, filepath.Join(dir, "memory_summary.md"), 5)
				},
				missing: "MEMORY.md",
			},
		}
		for _, test := range tests {
			t.Run(test.name, func(t *testing.T) {
				dir := t.TempDir()
				test.prepare(t, dir)
				code, _, stderr := execute("--layout", "codex", "--dir", dir)
				if code != 2 {
					t.Fatalf("exit code = %d, want 2", code)
				}
				if !strings.Contains(stderr, test.missing) {
					t.Fatalf("stderr %q does not name %s", stderr, test.missing)
				}
			})
		}
	})

	t.Run("rejects unreadable registry", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("POSIX permission test")
		}
		dir := codexStore(t)
		registry := filepath.Join(dir, "MEMORY.md")
		if err := os.Chmod(registry, 0); err != nil {
			t.Fatalf("make registry unreadable: %v", err)
		}
		t.Cleanup(func() {
			if err := os.Chmod(registry, 0o600); err != nil {
				t.Errorf("restore registry permissions: %v", err)
			}
		})
		code, _, stderr := execute("--layout", "codex", "--dir", dir)
		if code != 2 {
			t.Fatalf("exit code = %d, want 2; stderr=%q", code, stderr)
		}
		if !strings.Contains(stderr, "unreadable Codex memory file: MEMORY.md") {
			t.Fatalf("stderr %q does not identify unreadable registry", stderr)
		}
	})
}

func TestOutputModesAndReadOnlyBehavior(t *testing.T) {
	dir := legacyStore(t)
	writeKB(t, filepath.Join(dir, "portfolio-status.md"), 80)
	writeKB(t, filepath.Join(dir, "caches.md"), 46)
	writeKB(t, filepath.Join(dir, "small-topic.md"), 4)

	code, stdout, _ := execute("--layout", "legacy", "--dir", dir)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(stdout, "portfolio-status.md") || !strings.Contains(stdout, "near") {
		t.Fatalf("default output misses over/near signals: %q", stdout)
	}
	if strings.Contains(stdout, "small-topic.md") {
		t.Fatalf("default output includes healthy file: %q", stdout)
	}

	code, stdout, _ = execute("--layout", "legacy", "--dir", dir, "--all")
	if code != 1 || !strings.Contains(stdout, "small-topic.md") {
		t.Fatalf("--all code/output = %d/%q, want failing code with healthy file listed", code, stdout)
	}

	code, stdout, stderr := execute("--layout", "legacy", "--dir", dir, "--quiet")
	if code != 1 || stdout != "" || stderr != "" {
		t.Fatalf("--quiet code/stdout/stderr = %d/%q/%q", code, stdout, stderr)
	}

	before := make(map[string][32]byte)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read fixture directory: %v", err)
	}
	for _, entry := range entries {
		data, readErr := os.ReadFile(filepath.Join(dir, entry.Name()))
		if readErr != nil {
			t.Fatalf("read fixture %s: %v", entry.Name(), readErr)
		}
		before[entry.Name()] = sha256.Sum256(data)
	}
	_, _, _ = execute("--layout", "legacy", "--dir", dir)
	for name, want := range before {
		data, readErr := os.ReadFile(filepath.Join(dir, name))
		if readErr != nil {
			t.Fatalf("read fixture after run %s: %v", name, readErr)
		}
		if got := sha256.Sum256(data); got != want {
			t.Fatalf("%s changed: got %x, want %x", name, got, want)
		}
	}
}

func TestRepositoryContracts(t *testing.T) {
	read := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		return string(data)
	}

	constitution := read(filepath.Join("..", "..", "..", "AGENTS.md"))
	for _, required := range []string{
		"An exit 1 makes repairing the over-threshold boot-loaded file",
		"An exit 2 indicates a usage, malformed-layout, missing, or unreadable-store error",
	} {
		if !strings.Contains(constitution, required) {
			t.Fatalf("AGENTS.md is missing %q", required)
		}
	}

	maintenance := read(filepath.Join("..", "..", "skills", "portfolio-maintenance", "SKILL.md"))
	if !strings.Contains(maintenance, "memory skills") {
		t.Fatal("portfolio maintenance omits Codex memory skills from progressive retrieval")
	}

	workflow := read(filepath.Join("..", "..", "..", ".github", "workflows", "ci.yaml"))
	start := strings.Index(workflow, "            memory-hygiene:")
	end := strings.Index(workflow[start:], "            maintainer-preflight:")
	if start < 0 || end < 0 {
		t.Fatal("cannot locate memory-hygiene path filter")
	}
	filter := workflow[start : start+end]
	for _, required := range []string{
		"- 'AGENTS.md'",
		"- '.claude/scripts/memory-hygiene-go/**'",
	} {
		if !strings.Contains(filter, required) {
			t.Fatalf("memory-hygiene path filter is missing %q:\n%s", required, filter)
		}
	}
}

func Example_run() {
	dir, err := os.MkdirTemp("", "memory-hygiene-example-")
	if err != nil {
		fmt.Println("setup failed")
		return
	}
	defer func() {
		if cleanupErr := os.RemoveAll(dir); cleanupErr != nil {
			fmt.Println("cleanup failed")
		}
	}()
	if err := os.WriteFile(filepath.Join(dir, "MEMORY.md"), []byte("index\n"), 0o600); err != nil {
		fmt.Println("setup failed")
		return
	}
	code, _, _ := execute("--layout", "legacy", "--dir", dir)
	fmt.Println(code)
	// Output: 0
}
