package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCommandStrictArgumentsAndHelp(t *testing.T) {
	for _, args := range [][]string{nil, {"file"}, {"file", "heading"}, {"file", "heading", "archive", "extra"}, {"file", "", "archive"}} {
		var out, err bytes.Buffer
		if code := run(args, "", &out, &err); code != 2 {
			t.Fatalf("bad invocation accepted: %v exit %d", args, code)
		}
	}
	var out, err bytes.Buffer
	if code := run([]string{"--help"}, "", &out, &err); code != 0 || !strings.Contains(out.String(), "heading-regex") {
		t.Fatalf("help missing: exit %d %s", code, out.String())
	}
}

func TestCommandUsesLiteralPathsAndReportsActualCompletion(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "Store $(touch sentinel).md")
	destination := filepath.Join(dir, "ARCHIVE With Spaces.md")
	if err := os.WriteFile(source, []byte("# Store\n## Old\nmove\n## Current\nkeep"), 0600); err != nil {
		t.Fatal(err)
	}
	helpers, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{source, "^## Old$", destination}, helpers, &stdout, &stderr); code != 0 {
		t.Fatalf("archive failed: exit %d %s", code, stderr.String())
	}
	for path, want := range map[string]string{source: "# Store\n## Current\nkeep", destination: "## Old\nmove\n"} {
		got, err := os.ReadFile(path)
		if err != nil || string(got) != want {
			t.Fatalf("wrong literal file result: %q %v", got, err)
		}
	}
	if !strings.Contains(stdout.String(), "memory-archive: complete backup=") {
		t.Fatalf("no completion receipt: %s", stdout.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "sentinel")); !os.IsNotExist(err) {
		t.Fatal("path was interpreted as code")
	}
}
