// Command memory-hygiene validates the boot-loaded surface of a native agent
// memory store without modifying it.
package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	defaultThresholdKB = int64(48)
	defaultIndexKB     = int64(24)
	maxThresholdKB     = int64(1<<63-1) / 1024
	legacyIndexFile    = "MEMORY.md"
	codexSummaryFile   = "memory_summary.md"
)

type config struct {
	dir                      string
	layout                   string
	thresholdKB              int64
	indexKB                  int64
	projectionLoadedBeforeMs int64
	quiet                    bool
	showAll                  bool
}

type projectionSnapshot struct {
	file      *os.File
	info      os.FileInfo
	digest    [sha256.Size]byte
	hasDigest bool
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	cfg, help, err := parseArgs(args)
	if help {
		if _, writeErr := io.WriteString(stdout, usage()); writeErr != nil {
			return 2
		}
		return 0
	}
	if err != nil {
		return reportFailure(stderr, err, errors.Is(err, errUsage))
	}

	if err := validateDirectory(cfg.dir); err != nil {
		return reportFailure(stderr, err, false)
	}

	indexFile := legacyIndexFile
	var codexProjection *projectionSnapshot
	if cfg.layout == "codex" {
		codexProjection, err = validateCodexStore(
			cfg.dir,
			time.UnixMilli(cfg.projectionLoadedBeforeMs),
			cfg.indexKB*1024,
		)
		if err != nil {
			return reportFailure(stderr, err, false)
		}
		defer func() {
			_ = codexProjection.file.Close()
		}()
		indexFile = codexSummaryFile
	}

	entries, err := os.ReadDir(cfg.dir)
	if err != nil {
		return reportFailure(
			stderr,
			fmt.Errorf("failed to enumerate memory files in %s: %w", cfg.dir, err),
			false,
		)
	}

	output := lineWriter{writer: stdout, quiet: cfg.quiet}
	checked := 0
	overCount := 0
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || filepath.Ext(name) != ".md" || strings.Contains(name, "archive") {
			continue
		}
		if cfg.layout == "codex" && name != indexFile {
			if cfg.showAll {
				output.line("skip                  %s (Codex runtime-managed source)", name)
			}
			continue
		}

		path := filepath.Join(cfg.dir, name)
		var info os.FileInfo
		if cfg.layout == "codex" {
			info = codexProjection.info
		} else {
			var statErr error
			info, statErr = os.Stat(path)
			if statErr != nil {
				return reportFailure(
					stderr,
					fmt.Errorf("unreadable memory file %s: %w", name, statErr),
					false,
				)
			}
		}
		if !info.Mode().IsRegular() {
			continue
		}
		if cfg.layout != "codex" {
			if err := validateReadable(path); err != nil {
				return reportFailure(
					stderr,
					fmt.Errorf("unreadable memory file %s: %w", name, err),
					false,
				)
			}
		}

		limitKB := cfg.thresholdKB
		if name == indexFile {
			limitKB = cfg.indexKB
		}
		limitBytes := limitKB * 1024
		nearBytes := limitBytes - limitBytes/10
		size := info.Size()
		sizeKB := size / 1024
		if size%1024 != 0 {
			sizeKB++
		}
		checked++

		switch {
		case size > limitBytes:
			overCount++
			output.line("OVER %5dK / %3dK  %s", sizeKB, limitKB, name)
		case size >= nearBytes:
			output.line("near %5dK / %3dK  %s", sizeKB, limitKB, name)
		case cfg.showAll:
			output.line("ok   %5dK / %3dK  %s", sizeKB, limitKB, name)
		}
	}

	if cfg.layout == "codex" && overCount == 0 {
		if err := validateProjectionUnchanged(
			codexProjection,
			filepath.Join(cfg.dir, codexSummaryFile),
		); err != nil {
			return reportFailure(
				stderr,
				err,
				false,
			)
		}
	}

	if checked == 0 {
		output.line("memory-hygiene: no memory files found in %s", cfg.dir)
		return output.exitCode(0)
	}

	if overCount > 0 {
		output.line("")
		if cfg.layout == "codex" {
			output.line(
				"memory-hygiene: %d/%d boot projection file(s) OVER threshold.",
				overCount,
				checked,
			)
			output.line(
				"  Refresh the Codex boot projection through the runtime's supported memory-maintenance path.",
			)
			output.line(
				"  Restart the run afterward; this session already received the old projection.",
			)
			output.line(
				"  Do not rewrite MEMORY.md or raw_memories.md; they are runtime-managed sources.",
			)
		} else {
			output.line(
				"memory-hygiene: %d/%d file(s) OVER threshold — consolidate this tick.",
				overCount,
				checked,
			)
			output.line("  These will TRUNCATE at run start and silently hide carry-forwards.")
			output.line("  Memory is a multi-writer surface: re-read immediately before writing and")
			output.line("  prefer a non-clobbering append over a whole-file rewrite.")
			output.line("  If a rewrite is required, use memory-rewrite.sh (never sed+mv into the live file).")
		}
		return output.exitCode(1)
	}

	output.line("memory-hygiene: all %d file(s) within threshold.", checked)
	return output.exitCode(0)
}

var errUsage = errors.New("usage error")

type usageError struct {
	message string
}

func (e usageError) Error() string {
	return e.message
}

func (e usageError) Is(target error) bool {
	return target == errUsage
}

func parseArgs(args []string) (config, bool, error) {
	cfg := config{
		thresholdKB: defaultThresholdKB,
		indexKB:     defaultIndexKB,
	}

	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			return cfg, true, nil
		case "--all":
			cfg.showAll = true
		case "--quiet":
			cfg.quiet = true
		case "--dir", "--layout", "--threshold-kb", "--index-kb", "--projection-loaded-before-ms":
			if i+1 >= len(args) {
				return cfg, false, usageError{message: fmt.Sprintf("%s requires a value", arg)}
			}
			i++
			value := args[i]
			switch arg {
			case "--dir":
				cfg.dir = value
			case "--layout":
				cfg.layout = value
			case "--threshold-kb":
				threshold, err := positiveDecimal(value)
				if err != nil {
					return cfg, false, err
				}
				cfg.thresholdKB = threshold
			case "--index-kb":
				index, err := positiveDecimal(value)
				if err != nil {
					return cfg, false, err
				}
				cfg.indexKB = index
			case "--projection-loaded-before-ms":
				loadedBefore, err := positiveUnixMilliseconds(value)
				if err != nil {
					return cfg, false, err
				}
				cfg.projectionLoadedBeforeMs = loadedBefore
			}
		default:
			return cfg, false, usageError{message: fmt.Sprintf("unknown argument %q", arg)}
		}
	}

	if cfg.layout == "" {
		return cfg, false, usageError{message: "--layout <legacy|codex> is required"}
	}
	if cfg.layout != "legacy" && cfg.layout != "codex" {
		return cfg, false, fmt.Errorf("unsupported layout %q (expected legacy or codex)", cfg.layout)
	}
	if cfg.layout == "codex" && cfg.projectionLoadedBeforeMs == 0 {
		return cfg, false, usageError{
			message: "--projection-loaded-before-ms is required with --layout codex",
		}
	}
	if cfg.layout == "legacy" && cfg.projectionLoadedBeforeMs != 0 {
		return cfg, false, usageError{
			message: "--projection-loaded-before-ms is only valid with --layout codex",
		}
	}
	if cfg.dir == "" {
		return cfg, false, usageError{message: "--dir is required"}
	}
	return cfg, false, nil
}

func positiveDecimal(value string) (int64, error) {
	if value == "" {
		return 0, errors.New("thresholds must be positive integers")
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return 0, fmt.Errorf("thresholds must be positive integers (got %q)", value)
		}
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("thresholds must be positive integers (got %q)", value)
	}
	if parsed > maxThresholdKB {
		return 0, fmt.Errorf("threshold exceeds supported size (got %q)", value)
	}
	return parsed, nil
}

func positiveUnixMilliseconds(value string) (int64, error) {
	if value == "" {
		return 0, errors.New("projection load boundary must be a positive Unix millisecond timestamp")
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return 0, fmt.Errorf(
				"projection load boundary must be a positive Unix millisecond timestamp (got %q)",
				value,
			)
		}
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf(
			"projection load boundary must be a positive Unix millisecond timestamp (got %q)",
			value,
		)
	}
	return parsed, nil
}

func validateDirectory(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("memory directory not found: %s: %w", dir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("memory directory not found: %s", dir)
	}
	return nil
}

func validateCodexStore(
	dir string,
	projectionLoadedBefore time.Time,
	indexLimitBytes int64,
) (*projectionSnapshot, error) {
	for _, name := range []string{codexSummaryFile, legacyIndexFile} {
		path := filepath.Join(dir, name)
		info, err := os.Stat(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("incomplete Codex memory layout: missing %s", name)
		}
		if err != nil || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("unreadable Codex memory file: %s", name)
		}
		if err := validateReadable(path); err != nil {
			return nil, fmt.Errorf("unreadable Codex memory file: %s: %w", name, err)
		}
	}

	summary, err := os.Open(filepath.Join(dir, codexSummaryFile))
	if err != nil {
		return nil, fmt.Errorf("unreadable Codex memory file: %s: %w", codexSummaryFile, err)
	}
	keepOpen := false
	defer func() {
		if !keepOpen {
			_ = summary.Close()
		}
	}()

	info, statErr := summary.Stat()
	if statErr != nil {
		return nil, fmt.Errorf("unreadable Codex memory file: %s: %w", codexSummaryFile, statErr)
	}
	if info.ModTime().After(projectionLoadedBefore) {
		return nil, fmt.Errorf(
			"codex boot projection changed after injection; restart required: %s",
			codexSummaryFile,
		)
	}

	firstLine, readErr := readFirstLine(summary)
	if readErr != nil {
		return nil, fmt.Errorf(
			"malformed Codex boot projection: %s: %w",
			codexSummaryFile,
			readErr,
		)
	}
	if firstLine != "v1" {
		return nil, fmt.Errorf(
			"malformed Codex boot projection: %s (expected v1 header)",
			codexSummaryFile,
		)
	}

	snapshot := &projectionSnapshot{file: summary, info: info}
	if info.Size() <= indexLimitBytes {
		digest, digestErr := digestFile(summary)
		if digestErr != nil {
			return nil, fmt.Errorf(
				"unreadable Codex memory file: %s: %w",
				codexSummaryFile,
				digestErr,
			)
		}
		snapshot.digest = digest
		snapshot.hasDigest = true
	}

	finalInfo, statErr := summary.Stat()
	if statErr != nil {
		return nil, fmt.Errorf("unreadable Codex memory file: %s: %w", codexSummaryFile, statErr)
	}
	if finalInfo.Size() != info.Size() || !finalInfo.ModTime().Equal(info.ModTime()) {
		return nil, fmt.Errorf(
			"codex boot projection changed while guard ran; restart required: %s",
			codexSummaryFile,
		)
	}
	snapshot.info = finalInfo
	keepOpen = true
	return snapshot, nil
}

func validateProjectionUnchanged(snapshot *projectionSnapshot, path string) error {
	current, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("codex boot projection changed while guard ran; restart required: %w", err)
	}
	defer func() {
		_ = current.Close()
	}()

	currentInfo, err := current.Stat()
	if err != nil {
		return fmt.Errorf("codex boot projection changed while guard ran; restart required: %w", err)
	}
	if !os.SameFile(snapshot.info, currentInfo) ||
		snapshot.info.Size() != currentInfo.Size() ||
		!snapshot.info.ModTime().Equal(currentInfo.ModTime()) {
		return errors.New("codex boot projection changed while guard ran; restart required")
	}
	if snapshot.hasDigest {
		currentDigest, digestErr := digestFile(current)
		if digestErr != nil {
			return fmt.Errorf(
				"codex boot projection changed while guard ran; restart required: %w",
				digestErr,
			)
		}
		if currentDigest != snapshot.digest {
			return errors.New("codex boot projection changed while guard ran; restart required")
		}
	}
	return nil
}

func digestFile(file *os.File) ([sha256.Size]byte, error) {
	var digest [sha256.Size]byte
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return digest, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return digest, err
	}
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

func validateReadable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.Mode().Perm()&0o444 == 0 {
		return errors.New("no read permission bits are set")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return nil
}

func readFirstLine(reader io.Reader) (string, error) {
	prefix := make([]byte, 4)
	count, err := io.ReadFull(reader, prefix)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", err
	}
	if count == 0 {
		return "", errors.New("empty summary")
	}

	header := string(prefix[:count])
	switch {
	case header == "v1", header == "v1\r":
		return "v1", nil
	case strings.HasPrefix(header, "v1\n"), strings.HasPrefix(header, "v1\r\n"):
		return "v1", nil
	default:
		return header, nil
	}
}

type lineWriter struct {
	writer io.Writer
	quiet  bool
	err    error
}

func (output *lineWriter) line(format string, args ...any) {
	if output.quiet || output.err != nil {
		return
	}
	_, output.err = fmt.Fprintf(output.writer, format+"\n", args...)
}

func (output *lineWriter) exitCode(successCode int) int {
	if output.err != nil {
		return 2
	}
	return successCode
}

func reportFailure(stderr io.Writer, err error, includeUsage bool) int {
	if _, writeErr := fmt.Fprintf(stderr, "memory-hygiene: %v\n", err); writeErr != nil {
		return 2
	}
	if includeUsage {
		if _, writeErr := io.WriteString(stderr, usage()); writeErr != nil {
			return 2
		}
	}
	return 2
}

func usage() string {
	return `Usage:
  memory-hygiene.sh --layout legacy --dir <memory-dir>
                    [--threshold-kb N] [--index-kb N] [--all] [--quiet]
  memory-hygiene.sh --layout codex --dir <memory-dir>
                    --projection-loaded-before-ms UNIX_MS
                    [--threshold-kb N] [--index-kb N] [--all] [--quiet]

Exit codes:
  0  every boot-loaded file is within its threshold
  1  at least one boot-loaded file is over threshold
  2  usage, layout, missing-store, or unreadable-store error
`
}
