// Package replace preserves the actual inode displaced by a guarded rewrite.
package replace

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type exchangeFunc func(string, string) error

func Commit(source, candidate, digest string) (string, error) {
	return commitWith(source, candidate, digest, exchangeFiles)
}

// readRegular binds bytes and identity through the same opened regular file.
func readRegular(path string) ([]byte, os.FileInfo, error) {
	link, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !link.Mode().IsRegular() {
		return nil, nil, errors.New("not a regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, nil, err
	}
	if !os.SameFile(link, info) {
		return nil, nil, errors.New("file changed while opening")
	}
	data, err := io.ReadAll(f)
	return data, info, err
}

func commitWith(source, candidate, digest string, exchange exchangeFunc) (displaced string, err error) {
	original, identity, err := readRegular(source)
	if err != nil {
		return "", err
	}
	if fmt.Sprintf("%x", sha256.Sum256(original)) != digest {
		return "", errors.New("stale snapshot; source untouched")
	}
	next, _, err := readRegular(candidate)
	if err != nil {
		return "", err
	}
	if len(next) == 0 {
		return "", errors.New("empty replacement; source untouched")
	}
	dir, err := os.MkdirTemp(filepath.Dir(source), ".memory-rewrite-recovery-")
	if err != nil {
		return "", err
	}
	attempted := false
	defer func() {
		if !attempted {
			_ = os.RemoveAll(dir)
		}
		if err != nil && attempted {
			err = fmt.Errorf("replacement incomplete; source=%q displaced=%q: %w", source, displaced, err)
		}
	}()
	displaced = filepath.Join(dir, "displaced-source")
	f, err := os.OpenFile(displaced, os.O_CREATE|os.O_EXCL|os.O_WRONLY, identity.Mode().Perm())
	if err != nil {
		return "", err
	}
	_, writeErr := f.Write(next)
	if writeErr == nil {
		writeErr = f.Sync()
	}
	prepared, statErr := f.Stat()
	closeErr := f.Close()
	if err = errors.Join(writeErr, statErr, closeErr); err != nil {
		return "", err
	}

	// Exchange exactly once. The actually displaced inode survives a late
	// append or replacement; an uncertain response is never retried or reversed.
	attempted = true
	if err = exchange(displaced, source); err != nil {
		return displaced, err
	}
	saved, actualOld, err := readRegular(displaced)
	if err != nil {
		return displaced, err
	}
	if !os.SameFile(identity, actualOld) || !bytes.Equal(saved, original) {
		return displaced, errors.New("displaced source changed; concurrent bytes retained without rollback")
	}
	installed, actualNew, err := readRegular(source)
	if err != nil {
		return displaced, err
	}
	if !os.SameFile(prepared, actualNew) || !bytes.Equal(installed, next) {
		return displaced, errors.New("live source changed after exchange; no rollback permitted")
	}
	// Keep the inode even on success: an already-open old descriptor may still
	// receive writes. This receipt proves readback, not universal CAS or locking.
	return displaced, nil
}
