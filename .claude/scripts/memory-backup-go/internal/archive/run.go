package archive

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

type Options struct{ Source, Selector, Destination, HelperDir string }
type Result struct{ Backup string }
type operations struct {
	command func(string, ...string) error
	link    func(string, string) error
}

func runHelper(helper string, args ...string) error {
	cmd := exec.Command("bash", append([]string{helper}, args...)...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s failed: %w: %s", filepath.Base(helper), err, output)
	}
	if filepath.Base(helper) == "memory-rewrite.sh" {
		// Preserve the displaced-inode recovery receipt even if the archive's
		// later readback fails. This does not announce archive completion.
		if _, err := os.Stderr.Write(output); err != nil {
			return err
		}
	}
	return nil
}

func Run(options Options) (Result, error) {
	return runWith(options, operations{command: runHelper, link: os.Link})
}

func canonicalParent(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(absolute))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(absolute)), nil
}

func regularBytes(path string) ([]byte, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0444 == 0 {
		return nil, nil, errors.New("input is not a readable regular file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	return data, info, nil
}

func snapshotUnchanged(path string, info os.FileInfo, want []byte) error {
	got, current, err := regularBytes(path)
	if err != nil || !os.SameFile(info, current) || !bytes.Equal(got, want) {
		return errors.New("source snapshot changed; no source rewrite permitted")
	}
	return nil
}

func stagedFile(dir, pattern string, data []byte) (string, error) {
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	name := file.Name()
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(name)
		return "", err
	}
	return name, nil
}

func runWith(options Options, ops operations) (result Result, err error) {
	source, err := canonicalParent(options.Source)
	if err != nil {
		return result, err
	}
	destination, err := canonicalParent(options.Destination)
	if err != nil {
		return result, err
	}
	original, info, err := regularBytes(source)
	if err != nil {
		return result, err
	}
	if source == destination {
		return result, errors.New("source and archive must differ")
	}
	if _, err := os.Lstat(destination); err == nil {
		return result, errors.New("archive already exists; overwrite is forbidden")
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	keep, moved, err := Split(original, options.Selector)
	if err != nil {
		return result, err
	}
	for _, helper := range []string{"memory-backup.sh", "memory-rewrite.sh"} {
		entry, err := os.Lstat(filepath.Join(options.HelperDir, helper))
		if err != nil || !entry.Mode().IsRegular() {
			return result, errors.New("existing guarded helper is unavailable")
		}
	}
	if err := snapshotUnchanged(source, info, original); err != nil {
		return result, err
	}

	// Data writes start with the existing backup helper, after every selector and
	// destination preflight. Never delete the recovery directory on a later failure.
	backupDir, err := os.MkdirTemp(filepath.Dir(source), ".memory-archive-backup-")
	if err != nil {
		return result, err
	}
	defer func() {
		if err != nil {
			err = fmt.Errorf("%w; recovery directory retained at %s", err, backupDir)
		}
	}()
	if err = ops.command(filepath.Join(options.HelperDir, "memory-backup.sh"), "--backup-dir", backupDir, "--", source); err != nil {
		return result, err
	}
	entries, err := os.ReadDir(backupDir)
	if err != nil || len(entries) != 1 {
		return result, errors.New("backup verification failed: expected one complete snapshot")
	}
	result.Backup = filepath.Join(backupDir, entries[0].Name())
	backup, _, err := regularBytes(result.Backup)
	if err != nil || !bytes.Equal(backup, original) {
		return result, errors.New("backup verification failed: bytes differ from the selected snapshot")
	}

	work, err := os.MkdirTemp(filepath.Dir(source), ".memory-archive-prepare-")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(work)
	candidate, err := stagedFile(work, "retained-", keep)
	if err != nil {
		return result, err
	}
	staged, err := stagedFile(filepath.Dir(destination), ".memory-archive-stage-", moved)
	if err != nil {
		return result, err
	}
	defer os.Remove(staged)
	retained, _, err := regularBytes(candidate)
	if err != nil {
		return result, err
	}
	archived, _, err := regularBytes(staged)
	if err != nil {
		return result, err
	}
	if err = Verify(original, retained, archived); err != nil {
		return result, err
	}
	if err = snapshotUnchanged(source, info, original); err != nil {
		return result, err
	}

	// Link publishes a complete file atomically and refuses a racing destination.
	// Staging beside the destination also works across source/archive filesystems.
	if err = ops.link(staged, destination); err != nil {
		return result, fmt.Errorf("archive publication refused without overwrite: %w", err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(original))
	if err = ops.command(filepath.Join(options.HelperDir, "memory-rewrite.sh"), "--file", source, "--from", candidate, "--expected-sha256", digest, "--allow-shrink", "--backup-dir", backupDir); err != nil {
		return result, fmt.Errorf("source rewrite incomplete; published archive and backup retained: %w", err)
	}
	installed, _, err := regularBytes(source)
	if err != nil {
		return result, err
	}
	published, _, err := regularBytes(destination)
	if err != nil {
		return result, err
	}
	saved, _, err := regularBytes(result.Backup)
	if err != nil {
		return result, err
	}
	if !bytes.Equal(installed, keep) || !bytes.Equal(published, moved) || !bytes.Equal(saved, original) {
		return result, errors.New("final archive readback differs; operation is incomplete")
	}
	if err = Verify(original, installed, published); err != nil {
		return result, err
	}
	return result, nil
}
