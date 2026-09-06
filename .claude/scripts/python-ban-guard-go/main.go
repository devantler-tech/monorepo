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

var interpreter = regexp.MustCompile("^(python[23]?([.][0-9]+)?|pip3?|pytest)$")
var assignment = regexp.MustCompile("^[A-Za-z_][A-Za-z0-9_]*=")

const marker = "python-ban-guard: allow-file"

type scanner struct {
	path string
	hits []string
	seen map[string]bool
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "python-ban-parser: need display path and input file")
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
	if !handled {
		// Only unsupported non-shell text reaches the original compatibility scanner.
		os.Exit(3)
	}
	for _, hit := range s.hits {
		fmt.Println(hit)
	}
}

func (s *scanner) add(line int, command string) {
	q := string(rune(96))
	hit := fmt.Sprintf("%s:%d: Python invocation %s%s%s", s.path, line, q, command, q)
	if !s.seen[hit] {
		s.seen[hit] = true
		s.hits = append(s.hits, hit)
	}
}

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

func parse(src string) (*syntax.File, error) {
	return syntax.NewParser(syntax.KeepComments(true)).Parse(strings.NewReader(src), "")
}

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
			if input != nil && input.Hdoc != nil {
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
				if arg == "-o" || arg == "-O" || arg == "+o" || arg == "+O" {
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
		case "env", "sudo", "exec", "xargs", "command", "nohup", "time", "nice":
			i++
			for i < len(args) && known[i] {
				arg := args[i]
				if arg == "--" {
					i++
					break
				}
				if name == "env" && assignment.MatchString(arg) {
					i++
					continue
				}
				if !strings.HasPrefix(arg, "-") {
					break
				}
				if (name == "command" && (arg == "-v" || arg == "-V")) || (name == "sudo" && (arg == "-l" || arg == "--list")) {
					return false, nil
				}
				if name == "nice" && (arg == "--help" || arg == "--version") {
					return false, nil
				}
				needsValue := false
				switch name {
				case "env":
					needsValue = arg == "-u" || arg == "--unset" || arg == "-C" || arg == "--chdir"
					if arg == "-S" || arg == "--split-string" {
						if i+1 < len(args) && known[i+1] {
							return false, s.source(args[i+1]+" "+strings.Join(args[i+2:], " "), line, depth+1, false)
						}
						return false, nil
					}
				case "sudo":
					needsValue = arg == "-u" || arg == "-g" || arg == "-h" || arg == "-p" || arg == "-C" || arg == "-T" || arg == "--user" || arg == "--group" || arg == "--host" || arg == "--prompt"
				case "xargs":
					needsValue = arg == "-I" || arg == "-L" || arg == "-n" || arg == "-P" || arg == "-s" || arg == "-E" || arg == "-d"
				case "exec":
					needsValue = arg == "-a"
				case "time":
					needsValue = arg == "-f" || arg == "-o" || arg == "--format" || arg == "--output"
				case "nice":
					needsValue = arg == "-n" || arg == "--adjustment"
				}
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

func shebang(src string) string {
	first, _, _ := strings.Cut(src, "\n")
	if !strings.HasPrefix(first, "#!") {
		return ""
	}
	command := strings.TrimSpace(strings.TrimPrefix(first, "#!"))
	// env split-string syntax is distinct from ordinary interpreter arguments.
	fields := strings.Fields(command)
	isEnv := len(fields) > 1 && filepath.Base(fields[0]) == "env"
	if isEnv {
		rest := strings.TrimSpace(strings.TrimPrefix(command, fields[0]))
		if strings.HasPrefix(rest, "-S") {
			command = strings.TrimSpace(strings.TrimPrefix(rest, "-S"))
		} else if strings.HasPrefix(rest, "--split-string=") {
			command = strings.TrimPrefix(rest, "--split-string=")
		} else {
			command = rest
		}
	}
	args, err := literalArgs(command)
	if err == nil && isEnv {
		for len(args) > 0 {
			arg := args[0]
			if arg == "--" {
				args = args[1:]
				break
			}
			if assignment.MatchString(arg) {
				args = args[1:]
				continue
			}
			if arg == "-u" || arg == "--unset" || arg == "-C" || arg == "--chdir" {
				if len(args) < 2 {
					return ""
				}
				args = args[2:]
				continue
			}
			if strings.HasPrefix(arg, "-") {
				args = args[1:]
				continue
			}
			break
		}
	}
	if err == nil && len(args) > 0 {
		return args[0]
	}
	return ""
}

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
		return false, nil
	}
	switch ext {
	case ".js", ".jsx", ".ts", ".tsx", ".json", ".yaml", ".yml", ".toml":
		return false, nil
	}
	if _, err := parse(src); err == nil {
		return true, s.source(src, 1, 0, true)
	}
	return false, nil
}

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
	var visit func(*yaml.Node) error
	visit = func(node *yaml.Node) error {
		if active[node] {
			return errors.New("cyclic YAML alias")
		}
		active[node] = true
		defer delete(active, node)
		if node.Kind == yaml.AliasNode {
			return visit(node.Alias)
		}
		if node.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(node.Content); i += 2 {
				key, value := node.Content[i], node.Content[i+1]
				if value.Kind == yaml.AliasNode {
					value = value.Alias
				}
				if (key.Value == "run" || key.Value == "shell") && value.Kind == yaml.ScalarNode {
					line := value.Line
					if value.Style == yaml.LiteralStyle || value.Style == yaml.FoldedStyle {
						line++
					}
					// Expressions are runtime values, not shell syntax. Leave a
					// non-command placeholder while retaining all surrounding code.
					program := regexp.MustCompile("(?s)\\$\\{\\{.*?\\}\\}").ReplaceAllString(value.Value, "__workflow_expression__")
					if err := s.source(program, line, 0, false); err != nil {
						return err
					}
				}
			}
		}
		for _, child := range node.Content {
			if err := visit(child); err != nil {
				return err
			}
		}
		return nil
	}
	return visit(&doc)
}

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
		case "RUN", "CMD", "ENTRYPOINT":
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
