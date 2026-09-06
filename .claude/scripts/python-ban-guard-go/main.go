// Command python-ban-guard parses executable shell surfaces without evaluating them.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	goparser "go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/syntax"
)

var interpreter = regexp.MustCompile("^(python[23]?([.][0-9]+)?|pip[23]?([.][0-9]+)?|pytest)$")
var assignment = regexp.MustCompile("^[A-Za-z_][A-Za-z0-9_]*=")

const marker = "python-ban-guard: allow-file"

type scanner struct {
	path string
	hits []string
	seen map[string]bool
}

// main scans one supplied file and reports whether the compatibility route is needed.
func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "python-ban-parser: need display path and input file")
		os.Exit(2)
	}
	info, err := os.Lstat(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		fmt.Fprintf(os.Stderr, "python-ban-parser: %s: symlink inputs are not supported\n", os.Args[1])
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	s := scanner{path: os.Args[1], seen: make(map[string]bool)}
	handled, err := s.file(strings.ToValidUTF8(string(data), "\uFFFD"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "python-ban-guard: %s: %v\n", s.path, err)
		os.Exit(2)
	}
	for _, hit := range s.hits {
		fmt.Println(hit)
	}
	if !handled {
		// Preserve parsed directive findings when other source text needs the compatibility route.
		os.Exit(3)
	}
}

// add records a command finding once at its source location.
func (s *scanner) add(line int, command string) {
	q := string(rune(96))
	hit := fmt.Sprintf("%s:%d: Python invocation %s%s%s", s.path, line, q, command, q)
	if !s.seen[hit] {
		s.seen[hit] = true
		s.hits = append(s.hits, hit)
	}
}

// declaration validates exemptions found in comments parsed by the source language.
func (s *scanner) declaration(comments []string) bool {
	for _, comment := range comments {
		start := strings.Index(comment, marker)
		if start < 0 {
			continue
		}
		reason := strings.TrimSpace(strings.TrimPrefix(comment[start+len(marker):], " — "))
		if strings.HasPrefix(comment[start+len(marker):], " — ") && reason != "" {
			return true
		}
		s.hits = append(s.hits, s.path+": bare "+string(rune(96))+marker+string(rune(96))+" marker carries no reason; a marker states WHY the file is about the form, or it is a finding")
		return true
	}
	return false
}

// shellName recognizes interpreters whose command operands use shell syntax.
func shellName(name string) bool {
	switch filepath.Base(name) {
	case "bash", "sh", "zsh", "dash", "ksh":
		return true
	}
	return false
}

// staticWord never expands host variables, runs substitutions or consults the filesystem.
func staticWord(word *syntax.Word) (string, bool) {
	var safe func([]syntax.WordPart) bool
	safe = func(parts []syntax.WordPart) bool {
		for _, part := range parts {
			switch p := part.(type) {
			case *syntax.Lit:
				// Expansion-sensitive literals are unknown. Quoted literal values are data.
			case *syntax.SglQuoted:
			case *syntax.DblQuoted:
				if !safe(p.Parts) {
					return false
				}
			default:
				return false
			}
		}
		return true
	}
	if !safe(word.Parts) {
		return "", false
	}
	for i, part := range word.Parts {
		if p, ok := part.(*syntax.Lit); ok {
			if (i == 0 && strings.HasPrefix(p.Value, "~")) || strings.ContainsAny(p.Value, "*?[{") {
				return "", false
			}
		}
	}
	values, err := expand.Fields(&expand.Config{Env: expand.ListEnviron()}, word)
	if err != nil || len(values) != 1 {
		return "", false
	}
	return values[0], true
}

// parse builds a shell syntax tree without executing or expanding the source.
func parse(src string) (*syntax.File, error) {
	return syntax.NewParser(syntax.KeepComments(true)).Parse(strings.NewReader(src), "")
}

// source visits executable shell nodes and follows statically known nested programs.
func (s *scanner) source(src string, firstLine, depth int, declarations bool) error {
	if depth > 32 {
		return errors.New("nested shell command limit exceeded")
	}
	tree, err := parse(src)
	if err != nil {
		return fmt.Errorf("cannot parse shell commands: %w", err)
	}
	if declarations {
		var comments []string
		syntax.Walk(tree, func(node syntax.Node) bool {
			if c, ok := node.(*syntax.Comment); ok {
				comments = append(comments, c.Text)
			}
			return true
		})
		if s.declaration(comments) {
			return nil
		}
	}
	syntax.Walk(tree, func(node syntax.Node) bool {
		if err != nil {
			return false
		}
		stmt, ok := node.(*syntax.Stmt)
		if !ok {
			return true
		}
		call, ok := stmt.Cmd.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		values := make([]string, len(call.Args))
		known := make([]bool, len(call.Args))
		for i, word := range call.Args {
			values[i], known[i] = staticWord(word)
		}
		line := firstLine + int(stmt.Pos().Line()) - 1
		var stdin bool
		stdin, err = s.argv(values, known, line, depth)
		if err == nil && stdin {
			var input *syntax.Redirect
			for _, r := range stmt.Redirs {
				fd := ""
				if r.N != nil {
					fd = r.N.Value
				}
				if fd == "0" || (fd == "" && (r.Op == syntax.Hdoc || r.Op == syntax.DashHdoc || r.Op == syntax.WordHdoc || r.Op == syntax.RdrIn || r.Op == syntax.DplIn || r.Op == syntax.RdrInOut)) {
					input = r
				}
			}
			if input != nil && input.Op == syntax.WordHdoc {
				if program, known := staticWord(input.Word); known {
					err = s.source(program, firstLine+int(input.Word.Pos().Line())-1, depth+1, false)
				}
			} else if input != nil && input.Hdoc != nil {
				// Reparse the source spelling, never an evaluated document. This
				// preserves independent literal commands beside unknown expansions;
				// the outer walk also visits substitutions executed by this shell.
				start, end := int(input.Hdoc.Pos().Offset()), int(input.Hdoc.End().Offset())
				err = s.source(src[start:end], firstLine+int(input.Hdoc.Pos().Line())-1, depth+1, false)
			}
		}
		return true
	})
	return err
}

// argv returns whether the selected shell reads commands from stdin.
func (s *scanner) argv(args []string, known []bool, line, depth int) (bool, error) {
	if depth > 32 {
		return false, errors.New("nested command limit exceeded")
	}
	for i := 0; i < len(args); {
		if !known[i] {
			return false, nil
		}
		name := filepath.Base(args[i])
		if interpreter.MatchString(name) {
			hit := args[i]
			if i+1 < len(args) && known[i+1] && args[i+1] != "" {
				hit += " " + args[i+1]
			}
			s.add(line, hit)
			return false, nil
		}
		if name == "eval" {
			if i+1 < len(args) && args[i+1] == "--" {
				i++
			}
			for j := i + 1; j < len(args); j++ {
				if !known[j] {
					return false, nil
				}
			}
			return false, s.source(strings.Join(args[i+1:], " "), line, depth+1, false)
		}
		if shellName(name) {
			stdin := false
			for j := i + 1; j < len(args); j++ {
				if !known[j] {
					return false, nil
				}
				arg := args[j]
				if arg == "--" {
					return stdin || j+1 == len(args), nil
				}
				if arg == "-o" || arg == "-O" || arg == "+o" || arg == "+O" ||
					(name == "bash" && (arg == "--rcfile" || arg == "--init-file")) {
					j++
					continue
				}
				if strings.HasPrefix(arg, "-") && !strings.HasPrefix(arg, "--") && strings.Contains(arg[1:], "c") {
					if j+1 < len(args) && known[j+1] {
						return false, s.source(args[j+1], line, depth+1, false)
					}
					return false, nil
				}
				if strings.HasPrefix(arg, "-") && !strings.HasPrefix(arg, "--") && strings.Contains(arg[1:], "s") {
					stdin = true
				}
				if !strings.HasPrefix(arg, "-") && !strings.HasPrefix(arg, "+") {
					return stdin, nil // A script path unless -s selects stdin.
				}
			}
			return true, nil
		}
		switch name {
		case "timeout", "stdbuf", "setsid", "ionice", "doas", "sudo", "exec", "xargs", "command", "nohup", "time":
			i++
			i += wrapperCommand(name, args[i:], known[i:])
		case "env":
			return s.envArgs(args[i+1:], known[i+1:], line, depth+1, nil)
		case "find":
			return false, s.findCommands(args[i+1:], known[i+1:], line, depth+1)
		case "nice":
			i++
			for i < len(args) && known[i] {
				arg := args[i]
				if arg == "--" {
					i++
					break
				}
				if !strings.HasPrefix(arg, "-") {
					break
				}
				if arg == "--help" || arg == "--version" {
					return false, nil
				}
				needsValue := arg == "-n" || arg == "--adjustment"
				i++
				if needsValue {
					i++
				}
			}
		default:
			return false, nil
		}
	}
	return false, nil
}

// envArgs preserves argv boundaries: env -S splits one operand, never shell code.
func (s *scanner) envArgs(args []string, known []bool, line, depth int, optional []bool) (bool, error) {
	if depth > 32 {
		return false, errors.New("nested command limit exceeded")
	}
	i := 0
	for i < len(args) {
		if i < len(optional) && optional[i] {
			i++ // An unquoted expansion-only word can disappear before command selection.
			continue
		}
		if !known[i] {
			break
		}
		arg := args[i]
		if arg == "--" || arg == "-" {
			i++
			break
		}
		if !strings.HasPrefix(arg, "-") {
			break // Assignments and the command end option processing.
		}
		if arg == "--help" || arg == "--version" {
			return false, nil
		}
		payload, split, operand := "", false, false
		switch {
		case arg == "--split-string":
			split, operand = true, true
		case strings.HasPrefix(arg, "--split-string="):
			payload, split = strings.TrimPrefix(arg, "--split-string="), true
		case arg == "--unset" || arg == "--chdir" || arg == "--argv0":
			operand = true
		case !strings.HasPrefix(arg, "--"):
			for j := 1; j < len(arg); j++ {
				if strings.ContainsRune("uCaPS", rune(arg[j])) {
					split = arg[j] == 'S'
					payload, operand = arg[j+1:], j+1 == len(arg)
					break // The rest belongs to this option, including any S.
				}
			}
		}
		i++
		if operand {
			if i >= len(args) || !known[i] {
				return false, nil
			}
			payload = args[i]
			i++
		}
		if split {
			words, literal, canDisappear, err := splitEnvString(payload)
			if err != nil {
				return false, err
			}
			values := append(words, args[i:]...)
			flags := append(literal, known[i:]...)
			canDisappear = append(canDisappear, make([]bool, len(args)-i)...)
			return s.envArgs(values, flags, line, depth+1, canDisappear)
		}
	}
	for i < len(args) {
		if (i < len(optional) && optional[i]) || (known[i] && strings.Contains(args[i], "=")) {
			i++
			continue
		}
		break
	}
	return s.argv(args[i:], known[i:], line, depth)
}

// splitEnvString implements the literal GNU/FreeBSD env -S grammar. Shell
// punctuation is data. Environment expansions remain unknown; none are evaluated.
func splitEnvString(src string) ([]string, []bool, []bool, error) {
	var words []string
	var known, optional []bool
	var word strings.Builder
	var quote byte
	started, literal, keepEmpty := false, true, false
	finish := func() {
		if started {
			words = append(words, word.String())
			known = append(known, literal)
			optional = append(optional, !literal && !keepEmpty && word.Len() == 0)
		}
		word.Reset()
		started, literal, keepEmpty = false, true, false
	}
	for i := 0; i < len(src); i++ {
		c := src[i]
		if quote == 0 && strings.ContainsRune(" \t\n\r\v\f", rune(c)) {
			finish()
			continue
		}
		if quote == 0 && c == '#' && !started {
			break
		}
		if (c == '\'' || c == '"') && (quote == 0 || quote == c) {
			keepEmpty = true
			if quote == c {
				quote = 0
			} else {
				quote = c
			}
			started = true
			continue
		}
		if c == '\\' && (quote != '\'' || (i+1 < len(src) && strings.ContainsRune("\\'", rune(src[i+1])))) {
			i++
			if i == len(src) {
				return nil, nil, nil, errors.New("env split-string ends with a backslash")
			}
			c = src[i]
			switch c {
			case '_':
				if quote == 0 {
					finish()
					continue
				}
				c = ' '
			case 'c':
				if quote != 0 {
					return nil, nil, nil, errors.New("env split-string stop escape inside quotes")
				}
				finish()
				return words, known, optional, nil
			case 'f':
				c = '\f'
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 't':
				c = '\t'
			case 'v':
				c = '\v'
			case '"', '#', '$', '\'', '\\':
			default:
				return nil, nil, nil, fmt.Errorf("unsupported env split-string escape: %q", c)
			}
		} else if c == '$' && quote != '\'' {
			end := strings.IndexByte(src[i:], '}')
			if !strings.HasPrefix(src[i:], "${") || end < 3 || !assignment.MatchString(src[i+2:i+end]+"=") {
				return nil, nil, nil, errors.New("invalid env split-string variable")
			}
			i += end
			started, literal = true, false
			continue
		}
		started = true
		word.WriteByte(c)
	}
	if quote != 0 {
		return nil, nil, nil, errors.New("unclosed env split-string quote")
	}
	finish()
	return words, known, optional, nil
}

// literalArgs decodes one simple command whose words are entirely static.
func literalArgs(src string) ([]string, error) {
	tree, err := parse(src)
	if err != nil || len(tree.Stmts) != 1 {
		return nil, errors.New("invalid command words")
	}
	call, ok := tree.Stmts[0].Cmd.(*syntax.CallExpr)
	if !ok {
		return nil, errors.New("not a simple command")
	}
	args := make([]string, len(call.Args))
	for i, word := range call.Args {
		value, known := staticWord(word)
		if !known {
			return nil, errors.New("dynamic command word")
		}
		args[i] = value
	}
	return args, nil
}

// shebang returns the static interpreter, including env option and split-string forms.
func shebang(src string) string {
	first, _, _ := strings.Cut(src, "\n")
	if !strings.HasPrefix(first, "#!") {
		return ""
	}
	command := strings.TrimSpace(strings.TrimPrefix(first, "#!"))
	// env split-string syntax is distinct from ordinary interpreter arguments.
	fields := strings.Fields(command)
	isEnv := len(fields) > 1 && filepath.Base(fields[0]) == "env"
	split := false
	if isEnv {
		rest := strings.TrimSpace(strings.TrimPrefix(command, fields[0]))
		short := regexp.MustCompile("^-[iv]*S").FindString(rest)
		if short != "" {
			command, split = strings.TrimPrefix(rest, short), true
		} else if strings.HasPrefix(rest, "--split-string=") {
			command, split = strings.TrimPrefix(rest, "--split-string="), true
		} else {
			command = rest
		}
	}
	args, err := literalArgs(command)
	known, optional := make([]bool, len(args)), make([]bool, len(args))
	for i := range known {
		known[i] = true
	}
	if split {
		args, known, optional, err = splitEnvString(command)
	}
	i := 0
	if err == nil && isEnv {
		for i < len(args) {
			if !known[i] {
				if optional[i] {
					i++
					continue
				}
				return ""
			}
			arg := args[i]
			if arg == "--" {
				i++
				break
			}
			if assignment.MatchString(arg) {
				i++
				continue
			}
			if arg == "--unset" || arg == "--chdir" {
				if i+1 >= len(args) || !known[i+1] {
					return ""
				}
				i += 2
				continue
			}
			if strings.HasPrefix(arg, "--") {
				i++
				continue
			}
			if strings.HasPrefix(arg, "-") {
				// GNU env short options cluster, and -u/-C take a value. The value
				// is the rest of the cluster when one follows and otherwise the
				// next argument, so skipping the cluster whole would select that
				// operand as the interpreter and report the file clean.
				rest := arg[1:]
				skip := 1
				for at := 0; at < len(rest); at++ {
					if rest[at] != 'u' && rest[at] != 'C' {
						continue
					}
					if at+1 == len(rest) {
						if i+1 >= len(args) || !known[i+1] {
							return ""
						}
						skip = 2
					}
					break
				}
				i += skip
				continue
			}
			break
		}
	}
	for i < len(optional) && optional[i] {
		i++
	}
	if err == nil && i < len(args) && known[i] {
		return args[i]
	}
	return ""
}

// file dispatches known executable formats and preserves the compatibility scan for others.
func (s *scanner) file(src string) (bool, error) {
	entry := shebang(src)
	if strings.HasPrefix(filepath.Base(entry), "python") && regexp.MustCompile("^python[0-9.]*$").MatchString(filepath.Base(entry)) {
		s.hits = append(s.hits, s.path+": Python source file (its shebang names python)")
		return true, nil
	}
	ext := filepath.Ext(s.path)
	declaredShell := shellName(entry) || ext == ".sh" || ext == ".bash"
	if !declaredShell && (ext == ".md" || ext == ".mdx") {
		return true, nil
	}
	if declaredShell {
		return true, s.source(src, 1, 0, true)
	}
	if filepath.Base(s.path) == "package.json" {
		return true, s.packageScripts(src)
	}
	if (ext == ".yaml" || ext == ".yml") && strings.HasPrefix(filepath.ToSlash(s.path), ".github/workflows/") {
		return true, s.yaml(src)
	}
	if ext == ".yaml" || ext == ".yml" {
		return true, s.yamlCommands(src)
	}
	base := filepath.Base(s.path)
	if base == "Dockerfile" || strings.HasPrefix(base, "Dockerfile.") || strings.HasSuffix(base, ".Dockerfile") {
		if strings.Contains(src, "<<") {
			// Dockerfile heredocs require Dockerfile-level parsing. Preserve the
			// original scanner here instead of silently omitting their bodies.
			return false, nil
		}
		return true, s.docker(src)
	}
	// Known non-shell source formats retain the legacy invocation scan. A real
	// Go comment can declare an exemption; raw string contents never can.
	if ext == ".go" {
		if tree, err := goparser.ParseFile(token.NewFileSet(), s.path, src, goparser.ParseComments); err == nil {
			var comments []string
			for _, group := range tree.Comments {
				comments = append(comments, group.Text())
			}
			if s.declaration(comments) {
				return true, nil
			}
		}
		return false, s.goGenerate(src)
	}
	if makeSourcePath(s.path) {
		return true, s.makeRecipes(src)
	}
	switch ext {
	case ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".json", ".toml":
		return false, nil
	}
	if _, err := parse(src); err == nil {
		return true, s.source(src, 1, 0, true)
	}
	return false, nil
}

// packageScripts scans each JSON scripts value while retaining its original line number.
func (s *scanner) packageScripts(src string) error {
	if !json.Valid([]byte(src)) {
		return errors.New("cannot parse package scripts: invalid JSON")
	}
	decoder := json.NewDecoder(strings.NewReader(src))
	open, err := decoder.Token()
	if err != nil || open != json.Delim('{') {
		return errors.New("package.json must be an object")
	}
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return err
		}
		if key != "scripts" {
			var ignored json.RawMessage
			if err := decoder.Decode(&ignored); err != nil {
				return err
			}
			continue
		}
		open, err := decoder.Token()
		if err != nil {
			return err
		}
		if open == nil {
			continue
		}
		if open != json.Delim('{') {
			return errors.New("package scripts must be an object")
		}
		for decoder.More() {
			if _, err := decoder.Token(); err != nil {
				return err
			}
			start := int(decoder.InputOffset())
			var program string
			if err := decoder.Decode(&program); err != nil {
				return err
			}
			fragment := src[start:int(decoder.InputOffset())]
			quote := strings.IndexByte(fragment, '"')
			if quote < 0 {
				return errors.New("package script must be a string")
			}
			line := 1 + strings.Count(src[:start+quote], "\n")
			if err := s.source(program, line, 0, false); err != nil {
				return err
			}
		}
		if _, err := decoder.Token(); err != nil {
			return err
		}
	}
	return nil
}

// yaml follows workflow command fields and aliases without scanning descriptive values.
func (s *scanner) yaml(src string) error {
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
		return fmt.Errorf("cannot parse YAML commands: %w", err)
	}
	var comments []string
	var collect func(*yaml.Node)
	collect = func(node *yaml.Node) {
		comments = append(comments, node.HeadComment, node.LineComment, node.FootComment)
		for _, child := range node.Content {
			collect(child)
		}
	}
	collect(&doc)
	if s.declaration(comments) {
		return nil
	}
	active := make(map[*yaml.Node]bool)
	var visit func(*yaml.Node, []string) error
	visit = func(node *yaml.Node, path []string) error {
		if active[node] {
			return errors.New("cyclic YAML alias")
		}
		active[node] = true
		defer delete(active, node)
		if node.Kind == yaml.AliasNode {
			return visit(node.Alias, path)
		}
		if node.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(node.Content); i += 2 {
				key, value := node.Content[i], node.Content[i+1]
				// Keys remain data, but their aliases must still be cycle-checked.
				if err := visit(key, []string{"<key>"}); err != nil {
					return err
				}
				for key.Kind == yaml.AliasNode {
					key = key.Alias
				}
				if err := visit(value, append(path, key.Value)); err != nil {
					return err
				}
			}
			return nil
		}
		stepCommand := len(path) == 5 && path[0] == "jobs" && path[2] == "steps" && path[3] == "*" && (path[4] == "run" || path[4] == "shell")
		defaultShell := len(path) == 3 && path[0] == "defaults" && path[1] == "run" && path[2] == "shell"
		jobDefaultShell := len(path) == 5 && path[0] == "jobs" && path[2] == "defaults" && path[3] == "run" && path[4] == "shell"
		if node.Kind == yaml.ScalarNode && (stepCommand || defaultShell || jobDefaultShell) {
			line := node.Line
			if node.Style == yaml.LiteralStyle || node.Style == yaml.FoldedStyle {
				line++
			}
			// Expressions are runtime values, not shell syntax. Leave a
			// non-command placeholder while retaining all surrounding code.
			program := regexp.MustCompile(`(?s)\$\{\{.*?\}\}`).ReplaceAllString(node.Value, "__workflow_expression__")
			return s.source(program, line, 0, false)
		}
		if node.Kind == yaml.SequenceNode {
			path = append(path, "*")
		}
		for _, child := range node.Content {
			if err := visit(child, path); err != nil {
				return err
			}
		}
		return nil
	}
	return visit(&doc, nil)
}

// docker scans shell and JSON operands of Dockerfile execution instructions.
func (s *scanner) docker(src string) error {
	lines := strings.Split(src, "\n")
	var comments []string
	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			comments = append(comments, strings.TrimSpace(line))
		}
	}
	if s.declaration(comments) {
		return nil
	}
	for i := 0; i < len(lines); i++ {
		line, first := strings.TrimSpace(lines[i]), i+1
		if strings.HasPrefix(line, "#") {
			continue
		}
		for strings.HasSuffix(line, "\\") && i+1 < len(lines) {
			i++
			if strings.HasPrefix(strings.TrimSpace(lines[i]), "#") {
				continue
			}
			line = strings.TrimSuffix(line, "\\") + lines[i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch strings.ToUpper(fields[0]) {
		// SHELL overrides the interpreter used by every later shell-form RUN,
		// CMD and ENTRYPOINT, so an explicitly selected Python there would
		// otherwise run while each shell-form operand parsed as an ordinary
		// command and reported clean.
		case "RUN", "CMD", "ENTRYPOINT", "SHELL":
		default:
			continue
		}
		operand := strings.TrimSpace(strings.TrimPrefix(line, fields[0]))
		for strings.HasPrefix(operand, "--") {
			flag := strings.Fields(operand)[0]
			operand = strings.TrimSpace(strings.TrimPrefix(operand, flag))
		}
		if strings.HasPrefix(operand, "[") {
			var args []string
			if err := json.Unmarshal([]byte(operand), &args); err != nil {
				return fmt.Errorf("cannot parse Dockerfile argv: %w", err)
			}
			known := make([]bool, len(args))
			for j := range known {
				known[j] = true
			}
			if _, err := s.argv(args, known, first, 0); err != nil {
				return err
			}
		} else if err := s.source(operand, first, 0, false); err != nil {
			return err
		}
	}
	return nil
}
