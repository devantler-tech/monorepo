package main

import "testing"

func TestStatusAcceptsExactApplicationPath(t *testing.T) {
	if got := run([]string{"status", "--bundle-id", "tech.devantler.desktop-app-updates.canary", "--app-path", "/tmp/nonexistent-canary.app"}); got != 0 {
		t.Fatalf("read-only status for absent app: exit %d, want 0", got)
	}
}

func TestRejectsOtherApplicationsAndInvalidDeadlines(t *testing.T) {
	for _, args := range [][]string{
		{"quit", "--bundle-id", "com.apple.finder"},
		{"quit", "--bundle-id", "com.openai.codex", "--timeout", "0"},
		{"quit", "--bundle-id", "com.openai.codex", "--timeout", "61"},
		{"status", "--bundle-id", "tech.devantler.desktop-app-updates.canary"},
		{"status", "--bundle-id", "com.openai.codex", "--app-path", "relative.app"},
	} {
		if got := run(args); got != 2 {
			t.Errorf("run(%q): exit %d, want 2", args, got)
		}
	}
}
