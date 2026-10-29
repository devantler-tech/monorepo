package main

import (
	"fmt"
	"io"
	"os"
	"regexp"

	"github.com/devantler-tech/monorepo/memory-backup/internal/replace"
)

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) != 3 || args[0] == "" || args[1] == "" || !regexp.MustCompile("^[a-f0-9]{64}$").MatchString(args[2]) {
		_, _ = io.WriteString(stderr, "Usage: memory-replace <source> <candidate> <expected-sha256>\n")
		return 2
	}
	displaced, err := replace.Commit(args[0], args[1], args[2])
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "memory-replace: %v\n", err)
		return 2
	}
	if _, err := fmt.Fprintf(stdout, "memory-replace: verified displaced=%q\n", displaced); err != nil {
		_, _ = fmt.Fprintf(stderr, "memory-replace: receipt failed after exchange; displaced=%q\n", displaced)
		return 2
	}
	return 0
}
