package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestParseArgsConsumesDashPrefixedOperand(t *testing.T) {
	t.Setenv("MEMORY_BACKUP_TS", "20260724T003000Z")

	cfg, help, err := parseArgs([]string{"--", "-memory.md"})
	if err != nil {
		t.Fatalf("parseArgs returned error: %v", err)
	}
	if help {
		t.Fatal("parseArgs returned help for a backup request")
	}
	if cfg.target != "-memory.md" {
		t.Fatalf("target = %q, want -memory.md", cfg.target)
	}
}

func TestBackupFileRejectsChangedSourceBeforePublish(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "MEMORY.md")
	backupDir := filepath.Join(root, "backups")
	if err := os.WriteFile(source, []byte("before\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := backupFileWithCopy(options{
		target:    source,
		backupDir: backupDir,
		timestamp: "20260724T003000Z",
	}, io.Discard, func(src, dest string, info os.FileInfo) error {
		if err := copyIntoExisting(src, dest, info); err != nil {
			return err
		}
		return os.WriteFile(src, []byte("after\n"), 0o600)
	})
	if err == nil {
		t.Fatal("backupFileWithCopy published a backup after the source changed")
	}
	if !strings.Contains(err.Error(), "changed during backup") {
		t.Fatalf("error = %q, want changed-during-backup context", err)
	}
	final := filepath.Join(backupDir, "MEMORY.md.20260724T003000Z")
	if _, statErr := os.Lstat(final); !os.IsNotExist(statErr) {
		t.Fatalf("final backup was published after source change: stat err=%v", statErr)
	}
}

func TestBackupFileSyncsPublishDirectoryBeforeReportingSuccess(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "MEMORY.md")
	if err := os.WriteFile(source, []byte("memory\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("injected directory sync failure")
	var stdout strings.Builder
	err := backupFileWithDependencies(options{
		target:    source,
		backupDir: filepath.Join(root, "backups"),
		timestamp: "20260724T003003Z",
	}, &stdout, copyIntoExisting, func(string) error { return wantErr })
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want injected directory sync failure", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want no success output before directory sync", stdout.String())
	}
}

func TestBackupStoreSyncsPublishDirectoryBeforeReportingSuccess(t *testing.T) {
	root := t.TempDir()
	store := filepath.Join(root, "store")
	if err := os.Mkdir(store, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store, "MEMORY.md"), []byte("memory\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("injected directory sync failure")
	var stdout strings.Builder
	backupDir := filepath.Join(root, "backups")
	var synced []string
	err := backupStoreWithDependencies(options{
		all:       true,
		target:    store,
		backupDir: backupDir,
		timestamp: "20260724T003004Z",
	}, &stdout, copyFilePreserve, func(path string) error {
		synced = append(synced, path)
		if len(synced) == 2 {
			return wantErr
		}
		return nil
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want injected directory sync failure", err)
	}
	resolvedBackupDir, resolveErr := filepath.EvalSymlinks(backupDir)
	if resolveErr != nil {
		t.Fatal(resolveErr)
	}
	if len(synced) != 2 || synced[1] != resolvedBackupDir {
		t.Fatalf("synced directories = %q, want temporary snapshot then %q", synced, resolvedBackupDir)
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want no success output before directory sync", stdout.String())
	}
}

func TestBackupStoreRejectsChangedSourceManifest(t *testing.T) {
	root := t.TempDir()
	store := filepath.Join(root, "store")
	backupDir := filepath.Join(root, "backups")
	if err := os.Mkdir(store, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store, "MEMORY.md"), []byte("before\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	copyCalls := 0
	err := backupStoreWithCopy(options{
		all:       true,
		target:    store,
		backupDir: backupDir,
		timestamp: "20260724T003001Z",
	}, io.Discard, func(src, dest string) error {
		if err := copyFilePreserve(src, dest); err != nil {
			return err
		}
		copyCalls++
		if copyCalls == 1 {
			return os.WriteFile(filepath.Join(store, "late-writer.md"), []byte("late\n"), 0o600)
		}
		return nil
	})
	if err == nil {
		t.Fatal("backupStoreWithCopy published a snapshot after the source set changed")
	}
	if !strings.Contains(err.Error(), "changed during snapshot") {
		t.Fatalf("error = %q, want changed-during-snapshot context", err)
	}
	final := filepath.Join(backupDir, "store.20260724T003001Z")
	if _, statErr := os.Lstat(final); !os.IsNotExist(statErr) {
		t.Fatalf("final snapshot was published after source change: stat err=%v", statErr)
	}
}

func TestBackupStoreRejectsSymlinkedMarkdown(t *testing.T) {
	root := t.TempDir()
	store := filepath.Join(root, "store")
	backupDir := filepath.Join(root, "backups")
	if err := os.Mkdir(store, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store, "MEMORY.md"), []byte("memory\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("MEMORY.md", filepath.Join(store, "linked.md")); err != nil {
		t.Fatal(err)
	}

	err := backupStoreWithCopy(options{
		all:       true,
		target:    store,
		backupDir: backupDir,
		timestamp: "20260724T003005Z",
	}, io.Discard, copyFilePreserve)
	if err == nil {
		t.Fatal("backupStoreWithCopy published a snapshot that omitted a Markdown symlink")
	}
	if !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("error = %q, want symbolic-link context", err)
	}
	final := filepath.Join(backupDir, "store.20260724T003005Z")
	if _, statErr := os.Lstat(final); !os.IsNotExist(statErr) {
		t.Fatalf("snapshot was published after a Markdown symlink was found: stat err=%v", statErr)
	}
}

func TestBackupStorePreservesSourceModeAcrossRestrictiveUmask(t *testing.T) {
	root := t.TempDir()
	store := filepath.Join(root, "store")
	if err := os.Mkdir(store, 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(store, "MEMORY.md")
	if err := os.WriteFile(source, []byte("mode\n"), 0o666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(source, 0o666); err != nil {
		t.Fatal(err)
	}

	previousUmask := syscall.Umask(0o077)
	defer syscall.Umask(previousUmask)
	err := backupStoreWithCopy(options{
		all:       true,
		target:    store,
		backupDir: filepath.Join(root, "backups"),
		timestamp: "20260724T003002Z",
	}, io.Discard, copyFilePreserve)
	if err != nil {
		t.Fatalf("backupStoreWithCopy returned error: %v", err)
	}
	backup := filepath.Join(root, "backups", "store.20260724T003002Z", "MEMORY.md")
	info, err := os.Stat(backup)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o666 {
		t.Fatalf("backup mode = %04o, want 0666", got)
	}
}
