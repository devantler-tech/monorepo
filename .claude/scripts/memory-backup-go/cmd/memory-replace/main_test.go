package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunCommitsWithDisplacedReceipt(t *testing.T) {
	dir := t.TempDir()
	source, next := filepath.Join(dir, "source.md"), filepath.Join(dir, "next.md")
	original := []byte("# Notes\noriginal\n")
	if err := os.WriteFile(source, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(next, []byte("# Notes\nnext\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var out, diagnostics bytes.Buffer
	if code := run([]string{source, next, fmt.Sprintf("%x", sha256.Sum256(original))}, &out, &diagnostics); code != 0 || !strings.Contains(out.String(), "displaced=") {
		t.Fatalf("commit or recovery receipt failed: code=%d stdout=%q stderr=%q", code, out.String(), diagnostics.String())
	}
}

func TestRunRefusesInvalidOrStaleInput(t *testing.T) {
	for _, args := range [][]string{nil, {"missing", "candidate", strings.Repeat("0", 64)}, {"a", "b", "bad"}} {
		var out, diagnostics bytes.Buffer
		if code := run(args, &out, &diagnostics); code != 2 || out.Len() != 0 || diagnostics.Len() == 0 {
			t.Fatalf("unproven commit result: code=%d stdout=%q stderr=%q", code, out.String(), diagnostics.String())
		}
	}
}
