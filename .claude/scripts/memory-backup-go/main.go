// Command memory-backup creates recoverable, non-clobbering snapshots of an
// author-managed durable-memory file or its top-level Markdown store.
package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var errUsage = errors.New("usage error")

type options struct {
	all       bool
	backupDir string
	target    string
	timestamp string
}

type manifestEntry struct {
	name   string
	size   int64
	mode   fs.FileMode
	digest [sha256.Size]byte
}

type copyFileFunc func(src, dest string) error

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	cfg, help, err := parseArgs(args)
	if help {
		_, _ = io.WriteString(stdout, usage())
		return 0
	}
	if err != nil {
		fmt.Fprintf(stderr, "memory-backup: %v\n", err)
		if errors.Is(err, errUsage) {
			_, _ = io.WriteString(stderr, usage())
		}
		return 2
	}

	if cfg.all {
		err = backupStoreWithCopy(cfg, stdout, copyFilePreserve)
	} else {
		err = backupFile(cfg, stdout)
	}
	if err != nil {
		fmt.Fprintf(stderr, "memory-backup: %v\n", err)
		return 2
	}
	return 0
}

func parseArgs(args []string) (options, bool, error) {
	cfg := options{}
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--all":
			cfg.all = true
		case "--backup-dir":
			index++
			if index >= len(args) || args[index] == "" {
				return options{}, false, fmt.Errorf("%w: --backup-dir requires a directory", errUsage)
			}
			cfg.backupDir = args[index]
		case "-h", "--help":
			return options{}, true, nil
		case "--":
			if cfg.target != "" || index+2 != len(args) {
				return options{}, false, fmt.Errorf(
					"%w: -- must be followed by exactly one file (or memory-dir with --all)",
					errUsage,
				)
			}
			cfg.target = args[index+1]
			index = len(args)
		default:
			if strings.HasPrefix(arg, "-") {
				return options{}, false, fmt.Errorf("%w: unknown argument %q", errUsage, arg)
			}
			if cfg.target != "" {
				return options{}, false, fmt.Errorf("%w: unexpected extra argument %q", errUsage, arg)
			}
			cfg.target = arg
		}
	}
	if cfg.target == "" {
		return options{}, false, fmt.Errorf(
			"%w: a file (or memory-dir with --all) is required",
			errUsage,
		)
	}

	cfg.timestamp = os.Getenv("MEMORY_BACKUP_TS")
	if cfg.timestamp == "" {
		cfg.timestamp = time.Now().UTC().Format("20060102T150405Z")
	}
	parsed, err := time.Parse("20060102T150405Z", cfg.timestamp)
	if err != nil || parsed.UTC().Format("20060102T150405Z") != cfg.timestamp {
		return options{}, false, fmt.Errorf(
			"MEMORY_BACKUP_TS must look like YYYYMMDDTHHMMSSZ (got %q)",
			cfg.timestamp,
		)
	}
	return cfg, false, nil
}

func usage() string {
	return `Usage:
  memory-backup.sh [--backup-dir <dir>] <file>
  memory-backup.sh --all [--backup-dir <dir>] <memory-dir>

Default backup root is <parent>/.memory-backups/ (sibling of the file, or
inside the memory dir for --all).

Single-file layout:  .memory-backups/<basename>.<UTC-timestamp>
Whole-store layout:  .memory-backups/store.<UTC-timestamp>/<basename>

Exit codes:
  0  backup written; path + restore command printed on stdout
  2  usage error, missing source, or copy failure
`
}

func backupFile(cfg options, stdout io.Writer) error {
	source, info, err := resolveRegularFile(cfg.target)
	if err != nil {
		return err
	}
	parent := filepath.Dir(source)
	backupDir := cfg.backupDir
	if backupDir == "" {
		backupDir = filepath.Join(parent, ".memory-backups")
	}
	backupDir, err = resolveBackupDir(backupDir)
	if err != nil {
		return err
	}

	dest := filepath.Join(backupDir, filepath.Base(source)+"."+cfg.timestamp)
	exists, err := pathExists(dest)
	if err != nil {
		return fmt.Errorf("failed to inspect backup destination %s: %w", dest, err)
	}
	if exists {
		return fmt.Errorf("refusing to overwrite existing backup: %s", dest)
	}
	if err := copyFileExclusive(source, dest, info); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("refusing to overwrite existing backup: %s", dest)
		}
		return fmt.Errorf("failed to back up %s -> %s: %w", source, dest, err)
	}

	fmt.Fprintf(stdout, "Backed up %s -> %s\n", source, dest)
	fmt.Fprintf(stdout, "Restore: cp %s %s\n", shellQuote(dest), shellQuote(source))
	return nil
}

func backupStoreWithCopy(cfg options, stdout io.Writer, copyFile copyFileFunc) error {
	memoryDir, err := resolveDirectory(cfg.target)
	if err != nil {
		return err
	}
	backupDir := cfg.backupDir
	if backupDir == "" {
		backupDir = filepath.Join(memoryDir, ".memory-backups")
	}
	backupDir, err = resolveBackupDir(backupDir)
	if err != nil {
		return err
	}
	storeDest := filepath.Join(backupDir, "store."+cfg.timestamp)
	exists, err := pathExists(storeDest)
	if err != nil {
		return fmt.Errorf("failed to inspect snapshot destination %s: %w", storeDest, err)
	}
	if exists {
		return fmt.Errorf("refusing to overwrite existing snapshot: %s", storeDest)
	}

	before, err := captureManifest(memoryDir)
	if err != nil {
		return err
	}
	if len(before) == 0 {
		return fmt.Errorf("no top-level *.md files in %s", memoryDir)
	}

	storeTmp, err := os.MkdirTemp(backupDir, ".store."+cfg.timestamp+".")
	if err != nil {
		return fmt.Errorf("failed to create temporary snapshot in %s: %w", backupDir, err)
	}
	cleanupTmp := true
	defer func() {
		if cleanupTmp {
			_ = os.RemoveAll(storeTmp)
		}
	}()

	for _, entry := range before {
		source := filepath.Join(memoryDir, entry.name)
		dest := filepath.Join(storeTmp, entry.name)
		if err := copyFile(source, dest); err != nil {
			return fmt.Errorf("failed to copy %s into %s: %w", source, storeDest, err)
		}
	}

	copied, err := captureManifest(storeTmp)
	if err != nil {
		return fmt.Errorf("failed to verify temporary snapshot: %w", err)
	}
	after, err := captureManifest(memoryDir)
	if err != nil {
		return err
	}
	if !manifestsEqual(before, copied) || !manifestsEqual(before, after) {
		return fmt.Errorf("memory store changed during snapshot; refusing to publish %s", storeDest)
	}

	lockPath := storeDest + ".publish-lock"
	if err := os.Mkdir(lockPath, 0o700); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf(
				"refusing to overwrite existing or in-progress snapshot: %s",
				storeDest,
			)
		}
		return fmt.Errorf("failed to reserve snapshot publication %s: %w", storeDest, err)
	}
	removeLock := true
	defer func() {
		if removeLock {
			_ = os.RemoveAll(lockPath)
		}
	}()

	exists, err = pathExists(storeDest)
	if err != nil {
		return fmt.Errorf("failed to inspect snapshot destination %s: %w", storeDest, err)
	}
	if exists {
		return fmt.Errorf("refusing to overwrite existing snapshot: %s", storeDest)
	}
	if err := os.Rename(storeTmp, storeDest); err != nil {
		return fmt.Errorf("failed to publish completed snapshot %s: %w", storeDest, err)
	}
	cleanupTmp = false
	if err := os.Remove(lockPath); err != nil {
		return fmt.Errorf("snapshot published but publication lock cleanup failed: %w", err)
	}
	removeLock = false

	fmt.Fprintf(
		stdout,
		"Backed up %d file(s) from %s -> %s\n",
		len(before),
		memoryDir,
		storeDest,
	)
	fmt.Fprintf(
		stdout,
		"Restore one file: cp %s/<basename> %s/<basename>\n",
		shellQuote(storeDest),
		shellQuote(memoryDir),
	)
	return nil
}

func captureManifest(dir string) ([]manifestEntry, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to enumerate memory files in %s: %w", dir, err)
	}
	manifest := make([]manifestEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || filepath.Ext(entry.Name()) != ".md" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		info, err := entry.Info()
		if err != nil {
			return nil, fmt.Errorf("failed to inspect memory file %s: %w", path, err)
		}
		if !info.Mode().IsRegular() {
			continue
		}
		digest, err := digestFile(path)
		if err != nil {
			return nil, fmt.Errorf("failed to read memory file %s: %w", path, err)
		}
		manifest = append(manifest, manifestEntry{
			name:   entry.Name(),
			size:   info.Size(),
			mode:   info.Mode().Perm(),
			digest: digest,
		})
	}
	sort.Slice(manifest, func(i, j int) bool { return manifest[i].name < manifest[j].name })
	return manifest, nil
}

func manifestsEqual(left, right []manifestEntry) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func digestFile(path string) ([sha256.Size]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	defer func() { _ = file.Close() }()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return [sha256.Size]byte{}, err
	}
	var digest [sha256.Size]byte
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

func copyFilePreserve(src, dest string) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = source.Close() }()
	info, err := source.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("source is not a regular file")
	}

	destination, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
	if err != nil {
		return err
	}
	cleanDest := true
	defer func() {
		_ = destination.Close()
		if cleanDest {
			_ = os.Remove(dest)
		}
	}()
	if err := destination.Chmod(info.Mode().Perm()); err != nil {
		return err
	}
	if _, err := io.Copy(destination, source); err != nil {
		return err
	}
	if err := destination.Sync(); err != nil {
		return err
	}
	if err := destination.Close(); err != nil {
		return err
	}
	if err := os.Chtimes(dest, info.ModTime(), info.ModTime()); err != nil {
		return err
	}
	cleanDest = false
	return nil
}

func copyFileExclusive(src, dest string, info os.FileInfo) error {
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".memory-backup.*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	defer func() { _ = os.Remove(tmpPath) }()
	if err := copyIntoExisting(src, tmpPath, info); err != nil {
		return err
	}
	if err := os.Link(tmpPath, dest); err != nil {
		return err
	}
	return nil
}

func copyIntoExisting(src, dest string, info os.FileInfo) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = source.Close() }()
	destination, err := os.OpenFile(dest, os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if err := destination.Chmod(info.Mode().Perm()); err != nil {
		_ = destination.Close()
		return err
	}
	if _, err := io.Copy(destination, source); err != nil {
		_ = destination.Close()
		return err
	}
	if err := destination.Sync(); err != nil {
		_ = destination.Close()
		return err
	}
	if err := destination.Close(); err != nil {
		return err
	}
	return os.Chtimes(dest, info.ModTime(), info.ModTime())
}

func resolveRegularFile(path string) (string, os.FileInfo, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", nil, fmt.Errorf("failed to resolve source file %s: %w", path, err)
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(abs))
	if err != nil {
		return "", nil, fmt.Errorf("not a readable file: %s", path)
	}
	resolved := filepath.Join(parent, filepath.Base(abs))
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return "", nil, fmt.Errorf("not a readable file: %s", path)
	}
	return resolved, info, nil
}

func resolveDirectory(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("failed to resolve memory directory %s: %w", path, err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("not a directory: %s", path)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("not a directory: %s", path)
	}
	return resolved, nil
}

func resolveBackupDir(path string) (string, error) {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return "", fmt.Errorf("failed to create backup directory %s: %w", path, err)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("failed to resolve backup directory %s: %w", path, err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("failed to resolve backup directory %s: %w", path, err)
	}
	return resolved, nil
}

func pathExists(path string) (bool, error) {
	_, err := os.Lstat(path)
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, fs.ErrNotExist):
		return false, nil
	default:
		return false, err
	}
}

func shellQuote(value string) string {
	if value != "" && strings.IndexFunc(value, func(r rune) bool {
		return !strings.ContainsRune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-", r)
	}) == -1 {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
