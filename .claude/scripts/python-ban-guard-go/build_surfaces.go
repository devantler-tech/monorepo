package main

import (
	"errors"
	"fmt"
	goparser "go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// generateWord retains whether expansion depends on an unavailable runtime value.
type generateWord struct {
	text  string
	known bool
}

// goGenerate scans Go's line-based directives, not Go comments or shell syntax.
// Go deliberately recognizes these lines even inside raw strings. Aliases and
// predefined source variables are local to this file; host variables stay unknown.
func (s *scanner) goGenerate(src string) error {
	tree, err := goparser.ParseFile(token.NewFileSet(), s.path, src, goparser.PackageClauseOnly)
	if err != nil {
		return nil // go generate ignores files without a valid package clause.
	}
	aliases := make(map[string][]generateWord)
	for i, line := range strings.Split(src, "\n") {
		if !strings.HasPrefix(line, "//go:generate ") && !strings.HasPrefix(line, "//go:generate\t") {
			continue
		}
		args, err := generateWords(strings.TrimSuffix(line[len("//go:generate"):], "\r"))
		if err != nil {
			return fmt.Errorf("go:generate line %d: %w", i+1, err)
		}
		if len(args) == 0 {
			return fmt.Errorf("go:generate line %d: missing command", i+1)
		}
		if alias, ok := aliases[args[0].text]; ok {
			args = append(append([]generateWord(nil), alias...), args[1:]...)
		}
		for j := range args {
			args[j].text = os.Expand(args[j].text, func(name string) string {
				switch name {
				case "GOFILE":
					return filepath.Base(s.path)
				case "GOLINE":
					return strconv.Itoa(i + 1)
				case "GOPACKAGE":
					return tree.Name.Name
				case "DOLLAR":
					return "$"
				default:
					args[j].known = false
					return ""
				}
			})
		}
		if args[0].known && args[0].text == "-command" {
			if len(args) < 3 || !args[1].known || args[1].text == "" {
				return fmt.Errorf("go:generate line %d: malformed command alias", i+1)
			}
			if _, exists := aliases[args[1].text]; exists {
				return fmt.Errorf("go:generate line %d: duplicate command alias", i+1)
			}
			aliases[args[1].text] = append([]generateWord(nil), args[2:]...)
			continue
		}
		values, known := make([]string, len(args)), make([]bool, len(args))
		for j, arg := range args {
			values[j], known[j] = arg.text, arg.known
		}
		if _, err := s.argv(values, known, i+1, 0); err != nil {
			return err
		}
	}
	return nil
}

// generateWords applies the Go command's double-quoted argument grammar.
// Single quotes, backslashes outside quotes, and shell operators are ordinary data.
func generateWords(src string) ([]generateWord, error) {
	var words []generateWord
	for src = strings.TrimLeft(src, " \t"); src != ""; src = strings.TrimLeft(src, " \t") {
		end := strings.IndexAny(src, " \t")
		if end < 0 {
			end = len(src)
		}
		var value string
		if src[0] == '"' {
			end = 1
			for end < len(src) && src[end] != '"' {
				if src[end] == '\\' {
					end++
				}
				end++
			}
			if end >= len(src) {
				return nil, errors.New("unterminated quoted argument")
			}
			end++
			var err error
			value, err = strconv.Unquote(src[:end])
			if err != nil {
				return nil, fmt.Errorf("invalid quoted argument: %w", err)
			}
			if end < len(src) && src[end] != ' ' && src[end] != '\t' {
				return nil, errors.New("expected space after quoted argument")
			}
		} else {
			value = src[:end]
		}
		words = append(words, generateWord{text: value, known: true})
		src = src[end:]
	}
	return words, nil
}

// makeSourcePath identifies the standard make entrypoints and included fragments.
func makeSourcePath(path string) bool {
	name := filepath.Base(path)
	return name == "Makefile" || name == "makefile" || name == "GNUmakefile" || filepath.Ext(name) == ".mk"
}

var makeAssignment = regexp.MustCompile(`^(?:override[ \t]+|export[ \t]+)?([A-Za-z_.][A-Za-z0-9_.-]*)[ \t]*(:::=|::=|:=|\?=|\+=|!=|=)[ \t]*(.*)$`)

var makeScopedShellAssignment = regexp.MustCompile(`^[ \t]*(?:(?:export|unexport|override|private)[ \t]+)*SHELL[ \t]*(:::=|::=|:=|\?=|\+=|!=|=)[ \t]*(.*)$`)

// makeRecipe is one shell invocation with its original physical line number.
type makeRecipe struct {
	source     string
	line       int
	unresolved bool
}

// makeRecipes separates literal recipes from Make declarations before shell parsing.
// It does not run Make functions, include other files, or consult host variables.
func (s *scanner) makeRecipes(src string) error {
	lines := strings.Split(src, "\n")
	var recipes []makeRecipe
	var comments []string
	variables := make(map[string]string)
	defined := make(map[string]bool)
	prefix := byte('\t')
	inRule, defineDepth, conditionalDepth := false, 0, 0
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSuffix(lines[i], "\r")
		trimmed := strings.TrimSpace(line)
		if defineDepth > 0 {
			if strings.HasPrefix(trimmed, "define ") {
				defineDepth++
			} else if makeDirective(trimmed) == "endef" {
				defineDepth--
			}
			continue
		}
		if inRule && len(line) > 0 && line[0] == prefix {
			program := stripMakePrefixes(line[1:])
			first := i + 1
			for strings.HasSuffix(line, "\\") && i+1 < len(lines) {
				i++
				line = strings.TrimSuffix(lines[i], "\r")
				if len(line) > 0 && line[0] == prefix {
					line = line[1:]
				}
				program += "\n" + line
			}
			recipes = append(recipes, makeRecipe{source: program, line: first})
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			if strings.HasPrefix(trimmed, "#") {
				comments = append(comments, strings.TrimPrefix(trimmed, "#"))
			}
			continue
		}
		if strings.HasPrefix(trimmed, "define ") || strings.HasPrefix(trimmed, "override define ") {
			defineDepth = 1
			inRule = false
			continue
		}
		if strings.HasPrefix(trimmed, "ifeq") || strings.HasPrefix(trimmed, "ifneq") || strings.HasPrefix(trimmed, "ifdef ") || strings.HasPrefix(trimmed, "ifndef ") {
			conditionalDepth++
			continue
		}
		if makeDirective(trimmed) == "endif" {
			if conditionalDepth > 0 {
				conditionalDepth--
			}
			continue
		}
		if trimmed == "else" || strings.HasPrefix(trimmed, "else ") {
			continue
		}
		declaration, declarationLine := line, i+1
		for strings.HasSuffix(declaration, "\\") && i+1 < len(lines) {
			i++
			declaration = strings.TrimSuffix(declaration, "\\") + " " + strings.TrimSpace(lines[i])
		}
		if parts := makeAssignment.FindStringSubmatch(strings.TrimSpace(declaration)); parts != nil {
			inRule = false
			if parts[2] == "?=" && defined[parts[1]] {
				continue
			}
			defined[parts[1]] = true
			value := strings.TrimSpace(stripMakeComment(parts[3]))
			// Make runs $(shell ...) while reading the file, so its command is an
			// executable surface even when the surrounding value is discarded as
			// dynamic just below.
			for _, command := range makeShellCommands(value) {
				recipes = append(recipes, makeRecipe{source: command, line: i + 1})
			}
			// `!=` executes its right-hand side through the shell as Make reads the
			// file, so that command runs even though the value stays unresolved below.
			if parts[2] == "!=" && value != "" {
				recipes = append(recipes, makeRecipe{source: value, line: i + 1})
			}
			// GNU Make runs every recipe through SHELL, so a Python interpreter
			// selected there executes each recipe body.
			if parts[1] == "SHELL" && value != "" && !strings.ContainsAny(value, "$\\") {
				if err := s.source(value, i+1, 0, false); err != nil {
					return fmt.Errorf("make SHELL line %d: %w", i+1, err)
				}
			}
			// Only literal definitions are statically resolved. References and
			// escapes have different := and = expansion times; leave both unknown
			// instead of re-evaluating an immediate assignment at recipe time.
			unsupported := parts[2] == "+=" || parts[2] == "!=" || parts[2] == ":::="
			if conditionalDepth > 0 || unsupported || strings.ContainsAny(value, "$\\") {
				delete(variables, parts[1])
			} else {
				variables[parts[1]] = value
			}
			if parts[1] == ".RECIPEPREFIX" {
				if conditionalDepth > 0 || unsupported || strings.ContainsAny(value, "$\\") {
					return errors.New("dynamic Make recipe prefix is unsupported")
				} else if value == "" {
					prefix = '\t'
				} else {
					prefix = value[0]
				}
			}
			continue
		}
		colon := makeRuleColon(declaration)
		if colon < 0 {
			inRule = false
			continue
		}
		if parts := makeScopedShellAssignment.FindStringSubmatch(strings.TrimPrefix(declaration[colon+1:], ":")); parts != nil {
			// Target and pattern overrides select an interpreter without updating
			// the global variable table. Dynamic or compound assignments cannot
			// be resolved without Make's target context, so retain that uncertainty.
			value := strings.TrimSpace(stripMakeComment(parts[2]))
			unresolved := value == "" || strings.ContainsAny(value, "$\\") || parts[1] == "+=" || parts[1] == "!=" || parts[1] == ":::=" || parts[1] == "?="
			recipes = append(recipes, makeRecipe{source: value, line: declarationLine, unresolved: unresolved})
			inRule = true
			continue
		}
		inRule = true
		if semicolon := strings.IndexByte(declaration[colon+1:], ';'); semicolon >= 0 {
			recipes = append(recipes, makeRecipe{source: stripMakePrefixes(declaration[colon+1+semicolon+1:]), line: i + 1})
		}
	}
	if s.declaration(comments) {
		return nil
	}
	for _, recipe := range recipes {
		if recipe.unresolved {
			s.addUnresolved(recipe.line)
			continue
		}
		// Make expands $(shell ...) before handing the recipe to the shell, so its
		// command runs even when the surrounding expansion is discarded as unknown.
		for _, command := range makeShellCommands(recipe.source) {
			if err := s.source(command, recipe.line, 0, false); err != nil {
				return fmt.Errorf("make shell function line %d: %w", recipe.line, err)
			}
		}
		program := makeRecipeVariables(recipe.source, variables, 0)
		if err := s.source(program, recipe.line, 0, false); err != nil {
			return fmt.Errorf("make recipe line %d: %w", recipe.line, err)
		}
	}
	return nil
}

// makeRuleColon distinguishes a rule separator from escaped target-name colons
// and colons inside variable references, without evaluating those references.
// A backslash quotes the following byte, so pairs leave a colon unescaped.
func makeRuleColon(declaration string) int {
	for i := 0; i < len(declaration); i++ {
		switch declaration[i] {
		case '\\':
			i++
		case '$':
			i++
			if i >= len(declaration) || declaration[i] != '(' && declaration[i] != '{' {
				continue
			}
			opening, closing, depth := declaration[i], byte(')'), 1
			if opening == '{' {
				closing = '}'
			}
			for i++; i < len(declaration); i++ {
				if declaration[i] == opening {
					depth++
				} else if declaration[i] == closing {
					depth--
					if depth == 0 {
						break
					}
				}
			}
		case '#':
			return -1
		case ':':
			return i
		}
	}
	return -1
}

// makeDirective strips a trailing comment from a directive line. GNU Make accepts
// a comment after `endif` and `endef`, so an exact comparison against the raw line
// leaves the block open and swallows every later recipe.
func makeDirective(trimmed string) string {
	return strings.TrimSpace(stripMakeComment(trimmed))
}

// stripMakeComment drops an unescaped trailing comment and unescapes `\#`, which
// GNU Make treats as a literal hash rather than a comment introducer.
func stripMakeComment(value string) string {
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] == '\\' && i+1 < len(value) && value[i+1] == '#' {
			out.WriteByte('#')
			i++
			continue
		}
		if value[i] == '#' {
			break
		}
		out.WriteByte(value[i])
	}
	return out.String()
}

// stripMakePrefixes removes only the control characters on a recipe's first line.
func stripMakePrefixes(src string) string {
	for {
		src = strings.TrimLeft(src, " \t")
		if src == "" || !strings.ContainsRune("@-+", rune(src[0])) {
			return src
		}
		src = src[1:]
	}
}

// makeRecipeVariables leaves unresolved Make expressions as unknown shell words.
// A doubled dollar belongs to the shell; only literal definitions are substituted.
func makeRecipeVariables(src string, variables map[string]string, depth int) string {
	const unknown = "${__python_ban_make_unknown}"
	if depth > 32 {
		return unknown
	}
	var out strings.Builder
	for i := 0; i < len(src); i++ {
		if src[i] != '$' || i+1 == len(src) {
			out.WriteByte(src[i])
			continue
		}
		i++
		if src[i] == '$' {
			out.WriteByte('$')
			continue
		}
		name := string(src[i])
		if src[i] == '(' || src[i] == '{' {
			open, closing := src[i], byte(')')
			if open == '{' {
				closing = '}'
			}
			start, nesting := i+1, 1
			for i++; i < len(src); i++ {
				if src[i] == open {
					nesting++
				} else if src[i] == closing {
					nesting--
					if nesting == 0 {
						break
					}
				}
			}
			if i >= len(src) {
				out.WriteString(unknown)
				break
			}
			name = src[start:i]
		}
		if value, ok := variables[name]; ok {
			out.WriteString(makeRecipeVariables(value, variables, depth+1))
		} else {
			out.WriteString(unknown)
		}
	}
	return out.String()
}

// makeShellCommands returns the command text of every $(shell ...) expression in
// a Make value. Make executes these while reading the file, so treating a value
// as unknown because it contains a reference still leaves its shell command run.
func makeShellCommands(value string) []string {
	var commands []string
	for i := 0; i+1 < len(value); i++ {
		if value[i] != '$' {
			continue
		}
		if value[i+1] == '$' {
			i++
			continue
		}
		opening := value[i+1]
		var closing byte
		switch opening {
		case '(':
			closing = ')'
		case '{':
			closing = '}'
		default:
			continue
		}
		rest := value[i+2:]
		if !strings.HasPrefix(rest, "shell") || len(rest) == len("shell") {
			continue
		}
		if next := rest[len("shell")]; next != ' ' && next != '\t' {
			continue
		}
		depth, at := 1, len("shell")
		for ; at < len(rest); at++ {
			if rest[at] == opening {
				depth++
			} else if rest[at] == closing {
				if depth--; depth == 0 {
					break
				}
			}
		}
		if depth != 0 {
			continue
		}
		commands = append(commands, strings.TrimSpace(rest[len("shell"):at]))
		i += 1 + at
	}
	return commands
}
