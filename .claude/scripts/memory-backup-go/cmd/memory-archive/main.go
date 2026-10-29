package main

import (
	"fmt"
	"io"
	"os"

	"github.com/devantler-tech/monorepo/memory-backup/internal/archive"
)

func main() { os.Exit(run(os.Args[1:], os.Getenv("MEMORY_ARCHIVE_HELPER_DIR"), os.Stdout, os.Stderr)) }

func run(args []string, helpers string, stdout, stderr io.Writer) int {
	const usage = `Usage: memory-archive.sh <file> <heading-regex> <archive-path>

Archive one ATX Markdown heading, its prose and deeper subsections into a new file.
The next equal-or-shallower heading ends the section; fences and frontmatter are data.
Setext headings and HTML markup outside fenced text are refused before data writes.
The archive directory must already exist. Existing archive paths are never overwritten.
A verified backup and the actual displaced source inode are retained.
The source uses guarded native exchange on Linux/macOS; unsupported filesystems refuse.
Exit 0: complete and independently read back. Exit 2: refused, incomplete or invalid.
`
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		_, _ = io.WriteString(stdout, usage)
		return 0
	}
	if len(args) != 3 || helpers == "" {
		_, _ = io.WriteString(stderr, usage)
		return 2
	}
	for _, arg := range args {
		if arg == "" {
			_, _ = io.WriteString(stderr, usage)
			return 2
		}
	}
	result, err := archive.Run(archive.Options{Source: args[0], Selector: args[1], Destination: args[2], HelperDir: helpers})
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "memory-archive: %v\n", err)
		return 2
	}
	if _, err := fmt.Fprintf(stdout, "memory-archive: complete backup=%q archive=%q\n", result.Backup, args[2]); err != nil {
		_, _ = io.WriteString(stderr, "memory-archive: files completed, but the completion receipt could not be written\n")
		return 2
	}
	return 0
}
