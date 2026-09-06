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
		value := ""
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

// makeRecipe is one shell invocation with its original physical line number.
type makeRecipe struct {
	source string
	line   int
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
			} else if trimmed == "endef" {
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
		if trimmed == "endif" {
			if conditionalDepth > 0 {
				conditionalDepth--
			}
			continue
		}
		if trimmed == "else" || strings.HasPrefix(trimmed, "else ") {
			continue
		}
		declaration := line
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
			value := parts[3]
			if at := strings.IndexByte(value, '#'); at >= 0 {
				value = value[:at]
			}
			value = strings.TrimSpace(value)
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
		inRule = false
		if colon := strings.IndexByte(declaration, ':'); colon >= 0 {
			inRule = true
			if semicolon := strings.IndexByte(declaration[colon+1:], ';'); semicolon >= 0 {
				recipes = append(recipes, makeRecipe{source: stripMakePrefixes(declaration[colon+1+semicolon+1:]), line: i + 1})
			}
		}
	}
	if s.declaration(comments) {
		return nil
	}
	for _, recipe := range recipes {
		program := makeRecipeVariables(recipe.source, variables, 0)
		if err := s.source(program, recipe.line, 0, false); err != nil {
			return fmt.Errorf("Make recipe line %d: %w", recipe.line, err)
		}
	}
	return nil
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
			open, close := src[i], byte(')')
			if open == '{' {
				close = '}'
			}
			start, nesting := i+1, 1
			for i++; i < len(src); i++ {
				if src[i] == open {
					nesting++
				} else if src[i] == close {
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
