// cleanup-trap-census checks abort-test coverage for tracked deployment scripts (monorepo#4114).
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// literal excludes expansions; quoted literal command names still name commands.
func literal(word *syntax.Word) (string, bool) {
	var out strings.Builder
	for _, part := range word.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			out.WriteString(p.Value)
		case *syntax.SglQuoted:
			out.WriteString(p.Value)
		case *syntax.DblQuoted:
			value, ok := literal(&syntax.Word{Parts: p.Parts})
			if !ok {
				return "", false
			}
			out.WriteString(value)
		default:
			return "", false
		}
	}
	return out.String(), true
}

// exposed conservatively joins live set/trap commands anywhere in a parsed script.
// Literal fixture bodies, comments and quoted examples are not shell commands.
func exposed(source []byte) (bool, error) {
	file, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(bytes.NewReader(source), "")
	if err != nil {
		return false, err
	}
	errexit, exitTrap := false, false
	syntax.Walk(file, func(node syntax.Node) bool {
		call, ok := node.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		args := call.Args
		name, _ := literal(args[0])
		if (name == "builtin" || name == "command") && len(args) > 1 {
			args = args[1:]
			name, _ = literal(args[0])
		}
		switch name {
		case "set":
			for i := 1; i < len(args); i++ {
				arg, known := literal(args[i])
				if !known {
					errexit = true // An expanded option may enable errexit.
					continue
				}
				if arg == "--" || (!strings.HasPrefix(arg, "-") && !strings.HasPrefix(arg, "+")) {
					break
				}
				if arg == "-o" || arg == "+o" {
					if i+1 < len(args) {
						i++
						option, known := literal(args[i])
						errexit = errexit || arg == "-o" && (!known || option == "errexit")
					}
				} else if strings.HasPrefix(arg, "-") && strings.Contains(arg[1:], "e") {
					errexit = true
				}
			}
		case "trap":
			if len(args) > 1 {
				first, _ := literal(args[1])
				if first == "-p" || first == "-l" {
					return true
				}
				if first == "--" {
					args = append([]*syntax.Word{args[0]}, args[2:]...)
				}
			}
			if len(args) < 3 {
				break
			}
			handler, known := literal(args[1])
			if known && (handler == "" || handler == "-") {
				break
			}
			for _, arg := range args[2:] {
				signal, known := literal(arg)
				exitTrap = exitTrap || !known || signal == "EXIT" || signal == "0"
			}
		}
		return true
	})
	return errexit && exitTrap, nil
}

// auditPaths uses one complete tracked-file observation for both coverage and findings.
func auditPaths(files fs.FS, paths []string, injected, exceptions map[string]string) ([]string, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("no tracked shell scripts; nothing checked")
	}
	seen := map[string]bool{}
	var findings []string
	for _, path := range paths {
		seen[path] = true
		if _, both := injected[path]; both {
			if _, excepted := exceptions[path]; excepted {
				return nil, fmt.Errorf("%s is both injected and excepted", path)
			}
		}
		source, err := fs.ReadFile(files, path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		candidate, err := exposed(source)
		if err != nil {
			return nil, fmt.Errorf("%s: cannot parse shell: %w", path, err)
		}
		_, covered := injected[path]
		reason, excepted := exceptions[path]
		if excepted && strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("%s: exception needs a reason", path)
		}
		if candidate && !covered && !excepted {
			findings = append(findings, path+": errexit and EXIT trap have no injected-abort case or explained exception")
		}
	}
	for _, entries := range []map[string]string{injected, exceptions} {
		for path := range entries {
			if !seen[path] {
				return nil, fmt.Errorf("%s: coverage names an absent tracked script", path)
			}
		}
	}
	return findings, nil
}

// manifest accepts the injection table's name|arguments and the exception table's name|reason.
func manifest(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	entries := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, detail, ok := strings.Cut(line, "|")
		if !ok || name == "" || !fs.ValidPath(name) {
			return nil, fmt.Errorf("invalid coverage row")
		}
		name = ".claude/scripts/" + name
		if _, exists := entries[name]; exists {
			return nil, fmt.Errorf("%s: duplicate coverage row", name)
		}
		entries[name] = detail
	}
	return entries, scanner.Err()
}

// run reports unreadable/partial evidence as UNKNOWN, distinct from uncovered scripts.
func run(args []string, out, diagnostics io.Writer) int {
	flags := flag.NewFlagSet("cleanup-trap-census", flag.ContinueOnError)
	flags.SetOutput(diagnostics)
	root := flags.String("root", "", "repository root")
	covered := flags.String("covered", "", "injected-abort table")
	excepted := flags.String("exceptions", "", "explained exceptions table")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *root == "" || *covered == "" || *excepted == "" {
		return 2
	}
	unknown := func(err error) int { fmt.Fprintln(diagnostics, "cleanup-trap-census: UNKNOWN:", err); return 2 }
	injected, err := manifest(*covered)
	if err != nil {
		return unknown(err)
	}
	exceptions, err := manifest(*excepted)
	if err != nil {
		return unknown(err)
	}
	command := exec.Command("git", "-C", *root, "ls-files", "-s", "-z", "--", ".claude/scripts")
	// -C does not override inherited index/worktree selectors.
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		switch name {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES":
			continue
		}
		command.Env = append(command.Env, entry)
	}
	index, err := command.Output()
	if err != nil {
		return unknown(fmt.Errorf("tracked-file enumeration failed: %w", err))
	}
	var paths []string
	for _, record := range bytes.Split(index, []byte{0}) {
		if len(record) == 0 {
			continue
		}
		fields := strings.SplitN(string(record), "\t", 2)
		if len(fields) != 2 {
			return unknown(fmt.Errorf("malformed index record"))
		}
		path := fields[1]
		if filepath.Ext(path) != ".sh" && filepath.Ext(path) != ".bash" {
			continue
		}
		metadata := strings.Fields(fields[0])
		if len(metadata) != 3 || metadata[2] != "0" || (metadata[0] != "100644" && metadata[0] != "100755") {
			return unknown(fmt.Errorf("%s: unsupported tracked shell entry", path))
		}
		paths = append(paths, path)
	}
	findings, err := auditPaths(os.DirFS(*root), paths, injected, exceptions)
	if err != nil {
		return unknown(err)
	}
	for _, finding := range findings {
		fmt.Fprintln(diagnostics, "cleanup-trap-census:", finding)
	}
	if len(findings) > 0 {
		return 1
	}
	fmt.Fprintf(out, "cleanup-trap-census: OK — %d tracked shell scripts checked\n", len(paths))
	return 0
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }
