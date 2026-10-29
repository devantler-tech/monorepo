package archive

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func archiveFixture(t *testing.T) (Options, []byte) {
	t.Helper()
	dir := t.TempDir()
	source := []byte("# Store\r\n### Old\r\nsame\r\nsame\r\n#### Addendum\r\nbody\r\n### Current\r\nkeep")
	opt := Options{Source: filepath.Join(dir, "Store With Spaces.md"), Selector: "^### Old$", Destination: filepath.Join(dir, "Old With Spaces.md")}
	var err error
	opt.HelperDir, err = filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(opt.Source, source, 0600); err != nil {
		t.Fatal(err)
	}
	return opt, source
}

func TestArchiveRefusesUnverifiedBackupResults(t *testing.T) {
	for _, mode := range []string{"failed", "empty success", "wrong bytes"} {
		t.Run(mode, func(t *testing.T) {
			opt, original := archiveFixture(t)
			ops := operations{link: os.Link, command: func(helper string, args ...string) error {
				if filepath.Base(helper) != "memory-backup.sh" {
					return errors.New("unexpected rewrite after bad backup")
				}
				if mode == "failed" {
					if err := os.WriteFile(filepath.Join(args[1], "snapshot"), original, 0600); err != nil {
						return err
					}
					return errors.New("injected backup failure")
				}
				if mode == "wrong bytes" {
					return os.WriteFile(filepath.Join(args[1], "snapshot"), []byte("wrong snapshot"), 0600)
				}
				return nil
			}}
			_, err := runWith(opt, ops)
			if err == nil || !(strings.Contains(err.Error(), "backup verification failed") || strings.Contains(err.Error(), "injected backup failure")) {
				t.Fatalf("unverified backup accepted: %v", err)
			}
			assertBytes(t, opt.Source, original)
			if _, err := os.Lstat(opt.Destination); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("bad backup produced an archive")
			}
		})
	}
}

func TestArchiveCannotClobberARacingDestination(t *testing.T) {
	opt, original := archiveFixture(t)
	// The external backup boundary creates a competing destination after
	// preflight. Run must still use its own real no-clobber publication primitive.
	opt.HelperDir = t.TempDir()
	t.Setenv("ARCHIVE_RACE_DESTINATION", opt.Destination)
	backup := "#!/usr/bin/env bash\nset -euo pipefail\n[[ $# == 4 && $1 == --backup-dir && $3 == -- ]]\n/bin/cp \"$4\" \"$2/snapshot\"\nprintf 'concurrent winner' >\"$ARCHIVE_RACE_DESTINATION\"\n"
	if err := os.WriteFile(filepath.Join(opt.HelperDir, "memory-backup.sh"), []byte(backup), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(opt.HelperDir, "memory-rewrite.sh"), []byte("#!/usr/bin/env bash\nexit 88\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := Run(opt)
	if !errors.Is(err, os.ErrExist) {
		t.Fatalf("racing archive was not refused: %v", err)
	}
	assertBytes(t, opt.Source, original)
	assertBytes(t, opt.Destination, []byte("concurrent winner"))
	assertBytes(t, result.Backup, original)
}

func TestArchiveStopsBeforePublicationWhenSourceChangesAfterBackup(t *testing.T) {
	opt, original := archiveFixture(t)
	newer := append(bytes.Clone(original), []byte("\nnewer content\n")...)
	ops := operations{link: os.Link, command: func(helper string, args ...string) error {
		if err := runHelper(helper, args...); err != nil {
			return err
		}
		if filepath.Base(helper) == "memory-backup.sh" {
			return os.WriteFile(opt.Source, newer, 0600)
		}
		return nil
	}}
	result, err := runWith(opt, ops)
	if err == nil || !strings.Contains(err.Error(), "source snapshot changed") {
		t.Fatalf("changed source admitted to publication: %v", err)
	}
	assertBytes(t, opt.Source, newer)
	assertBytes(t, result.Backup, original)
	if _, err := os.Lstat(opt.Destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("changed source produced an archive")
	}
}

func TestArchiveDoesNotClaimSuccessAfterLostRewriteResponse(t *testing.T) {
	opt, original := archiveFixture(t)
	ops := operations{link: os.Link, command: func(helper string, args ...string) error {
		if err := runHelper(helper, args...); err != nil {
			return err
		}
		if filepath.Base(helper) == "memory-rewrite.sh" {
			return errors.New("lost completion response")
		}
		return nil
	}}
	result, err := runWith(opt, ops)
	if err == nil || !strings.Contains(err.Error(), "source rewrite incomplete") {
		t.Fatalf("lost write response reported success: %v", err)
	}
	assertBytes(t, opt.Source, []byte("# Store\r\n### Current\r\nkeep"))
	assertBytes(t, result.Backup, original)
	assertBytes(t, opt.Destination, []byte("### Old\r\nsame\r\nsame\r\n#### Addendum\r\nbody\r\n"))
}

func TestArchiveReadbackRefusesReorderedRetainedData(t *testing.T) {
	opt, original := archiveFixture(t)
	reordered := []byte("### Current\r\n# Store\r\nkeep")
	ops := operations{link: os.Link, command: func(helper string, args ...string) error {
		if err := runHelper(helper, args...); err != nil {
			return err
		}
		if filepath.Base(helper) == "memory-rewrite.sh" {
			return os.WriteFile(opt.Source, reordered, 0600)
		}
		return nil
	}}
	result, err := runWith(opt, ops)
	if err == nil || !strings.Contains(err.Error(), "final archive readback differs") {
		t.Fatalf("reordered source reported complete: %v", err)
	}
	assertBytes(t, opt.Source, reordered)
	assertBytes(t, result.Backup, original)
	assertBytes(t, opt.Destination, []byte("### Old\r\nsame\r\nsame\r\n#### Addendum\r\nbody\r\n"))
}

func TestArchivePreservesSourceOnPublicationFailure(t *testing.T) {
	opt, original := archiveFixture(t)
	result, err := runWith(opt, operations{command: runHelper, link: func(string, string) error { return os.ErrPermission }})
	if !errors.Is(err, os.ErrPermission) {
		t.Fatalf("publication failure was hidden: %v", err)
	}
	assertBytes(t, opt.Source, original)
	assertBytes(t, result.Backup, original)
	if _, err := os.Lstat(opt.Destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed publication exposed an archive")
	}
}

func TestArchiveDoesNotOverwriteAChangeBeforeSourceRewrite(t *testing.T) {
	opt, original := archiveFixture(t)
	newer := append(bytes.Clone(original), []byte("\nnew sibling content\n")...)
	ops := operations{link: os.Link, command: func(helper string, args ...string) error {
		if filepath.Base(helper) == "memory-rewrite.sh" {
			if err := os.WriteFile(opt.Source, newer, 0600); err != nil {
				return err
			}
		}
		return runHelper(helper, args...)
	}}
	result, err := runWith(opt, ops)
	if err == nil || !strings.Contains(err.Error(), "source rewrite incomplete") {
		t.Fatalf("stale rewrite accepted: %v", err)
	}
	assertBytes(t, opt.Source, newer)
	assertBytes(t, result.Backup, original)
	assertBytes(t, opt.Destination, []byte("### Old\r\nsame\r\nsame\r\n#### Addendum\r\nbody\r\n"))
}

func TestArchiveKeepsRecoveryCopiesWhenExistingWriterRefusesStructure(t *testing.T) {
	opt, _ := archiveFixture(t)
	original := []byte("unheaded introduction\n### Old\nonly heading\n")
	if err := os.WriteFile(opt.Source, original, 0600); err != nil {
		t.Fatal(err)
	}
	result, err := Run(opt)
	if err == nil || !strings.Contains(err.Error(), "source rewrite incomplete") {
		t.Fatalf("writer structure guard bypassed: %v", err)
	}
	assertBytes(t, opt.Source, original)
	assertBytes(t, result.Backup, original)
	assertBytes(t, opt.Destination, []byte("### Old\nonly heading\n"))
}

func assertBytes(t *testing.T, path string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("unexpected file bytes at %s: got %q error %v", path, got, err)
	}
}

func TestArchivePublishesVerbatimSectionThroughExistingHelpers(t *testing.T) {
	opt, original := archiveFixture(t)
	result, err := Run(opt)
	if err != nil {
		t.Fatal(err)
	}
	assertBytes(t, opt.Source, []byte("# Store\r\n### Current\r\nkeep"))
	assertBytes(t, opt.Destination, []byte("### Old\r\nsame\r\nsame\r\n#### Addendum\r\nbody\r\n"))
	assertBytes(t, result.Backup, original)
}

func TestArchivePreflightRefusalsLeaveNoDataArtifacts(t *testing.T) {
	for _, name := range []string{"zero selector", "duplicate selector", "existing archive", "same source", "source symlink", "archive symlink", "HTML comment"} {
		t.Run(name, func(t *testing.T) {
			opt, original := archiveFixture(t)
			switch name {
			case "zero selector":
				opt.Selector = "absent"
			case "duplicate selector":
				opt.Selector = "^### "
			case "HTML comment":
				original = []byte("# Store\n<!--\n### Old\n-->\n### Current\nkeep\n")
				if err := os.WriteFile(opt.Source, original, 0600); err != nil {
					t.Fatal(err)
				}
			case "existing archive":
				if err := os.WriteFile(opt.Destination, []byte("winner"), 0600); err != nil {
					t.Fatal(err)
				}
			case "same source":
				opt.Destination = opt.Source
			case "source symlink":
				link := opt.Source + ".link"
				if err := os.Symlink(opt.Source, link); err != nil {
					t.Fatal(err)
				}
				opt.Source = link
			case "archive symlink":
				if err := os.Symlink(opt.Source, opt.Destination); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := Run(opt); err == nil {
				t.Fatal("unsafe archive admitted")
			}
			assertBytes(t, opt.Source, original)
			entries, err := os.ReadDir(filepath.Dir(opt.Source))
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), ".memory-archive-") {
					t.Fatal("preflight refusal created data artifacts")
				}
			}
			if name == "existing archive" {
				assertBytes(t, opt.Destination, []byte("winner"))
			}
		})
	}
}
