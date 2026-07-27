// Command memory-hygiene validates the boot-loaded surface of a native agent
// memory store without modifying it.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	defaultThresholdKB = int64(48)
	defaultIndexKB     = int64(24)
	maxThresholdKB     = int64(1<<63-1) / 1024
	legacyIndexFile    = "MEMORY.md"
	codexSummaryFile   = "memory_summary.md"
)

type config struct {
	dir         string
	layout      string
	thresholdKB int64
	indexKB     int64
	quiet       bool
	showAll     bool
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
	if cfg.layout == "codex" {
		if err := validateCodexStore(cfg.dir); err != nil {
			return reportFailure(stderr, err, false)
		}
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
		info, statErr := os.Stat(path)
		if statErr != nil {
			return reportFailure(
				stderr,
				fmt.Errorf("unreadable memory file %s: %w", name, statErr),
				false,
			)
		}
		if !info.Mode().IsRegular() {
			continue
		}
		if err := validateReadable(path); err != nil {
			return reportFailure(
				stderr,
				fmt.Errorf("unreadable memory file %s: %w", name, err),
				false,
			)
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
		case "--dir", "--layout", "--threshold-kb", "--index-kb":
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

func validateCodexStore(dir string) error {
	for _, name := range []string{codexSummaryFile, legacyIndexFile} {
		path := filepath.Join(dir, name)
		info, err := os.Stat(path)
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("incomplete Codex memory layout: missing %s", name)
		}
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("unreadable Codex memory file: %s", name)
		}
		if err := validateReadable(path); err != nil {
			return fmt.Errorf("unreadable Codex memory file: %s: %w", name, err)
		}
	}

	summary, err := os.Open(filepath.Join(dir, codexSummaryFile))
	if err != nil {
		return fmt.Errorf("unreadable Codex memory file: %s: %w", codexSummaryFile, err)
	}
	firstLine, readErr := readFirstLine(summary)
	closeErr := summary.Close()
	if readErr != nil {
		return fmt.Errorf("malformed Codex boot projection: %s: %w", codexSummaryFile, readErr)
	}
	if closeErr != nil {
		return fmt.Errorf("unreadable Codex memory file: %s: %w", codexSummaryFile, closeErr)
	}
	if firstLine != "v1" {
		return fmt.Errorf(
			"malformed Codex boot projection: %s (expected v1 header)",
			codexSummaryFile,
		)
	}
	return nil
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
  memory-hygiene.sh --layout <legacy|codex> --dir <memory-dir>
                    [--threshold-kb N] [--index-kb N] [--all] [--quiet]

Exit codes:
  0  every boot-loaded file is within its threshold
  1  at least one boot-loaded file is over threshold
  2  usage, layout, missing-store, or unreadable-store error
`
}
