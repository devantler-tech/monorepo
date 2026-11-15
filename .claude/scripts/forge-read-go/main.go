// forge-read prints conditional, budget-sparing reads of organisation and
// repository list endpoints for the helpers in this directory (#4055). It was
// the read subcommand of the retired blocker guard (monorepo#5051), moved here
// unchanged with its tests.
package main

import (
	"fmt"
	"io"
	"os"
)

func run(args []string, _ io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "read" {
		// A failed diagnostic write cannot change the usage exit status.
		_, _ = fmt.Fprintln(stderr, "usage: forge-read.sh read <endpoint>...")
		return 2
	}
	return readRun(args[1:], stdout, stderr)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
