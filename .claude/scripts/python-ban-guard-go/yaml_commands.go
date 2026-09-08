package main

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"gopkg.in/yaml.v3"
)

// yamlCommands follows the existing command/run/shell heuristic, preserving literal YAML argv.
func (s *scanner) yamlCommands(src string) error {
	decoder := yaml.NewDecoder(strings.NewReader(src))
	var documents []*yaml.Node
	var comments []string
	var collect func(*yaml.Node)
	collect = func(node *yaml.Node) {
		comments = append(comments, node.HeadComment, node.LineComment, node.FootComment)
		for _, child := range node.Content {
			collect(child)
		}
	}
	for {
		var document yaml.Node
		if err := decoder.Decode(&document); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return fmt.Errorf("cannot parse YAML commands: %w", err)
		}
		documents = append(documents, &document)
		collect(&document)
	}
	if s.declaration(comments) {
		return nil
	}
	// Operands are decoded only after traversal has checked their alias graph.
	unalias := func(node *yaml.Node) *yaml.Node {
		for node.Kind == yaml.AliasNode {
			node = node.Alias
		}
		return node
	}
	operand := func(node *yaml.Node) error {
		node = unalias(node)
		switch node.Kind {
		case yaml.ScalarNode:
			line := node.Line
			if node.Style == yaml.LiteralStyle || node.Style == yaml.FoldedStyle {
				line++
			}
			return s.source(node.Value, line, 0, false)
		case yaml.SequenceNode:
			args := make([]string, len(node.Content))
			known := make([]bool, len(args))
			line := node.Line
			for i, item := range node.Content {
				item = unalias(item)
				if item.Kind != yaml.ScalarNode {
					return fmt.Errorf("YAML command argv at line %d must contain scalar values", item.Line)
				}
				if i == 0 {
					line = item.Line
				}
				args[i], known[i] = item.Value, true
			}
			_, err := s.argv(args, known, line, 0)
			return err
		}
		return nil
	}
	// Kubernetes derives one process from command and args jointly, so a shell
	// named in command whose script sits in the sibling args field executes
	// while each field, scanned alone, carries no command operand at all.
	// plainCommandWord reports whether a scalar command is a bare executable name.
	// Only such a scalar is safe to normalize into a one-element argv; a scalar
	// carrying shell syntax stays with the shell scanner, which parses it whole.
	plainCommandWord := func(value string) bool {
		if value == "" || strings.ContainsAny(value, " \t\n;|&<>()$`\"'\\*?[]{}~#!") {
			return false
		}
		return true
	}
	combined := func(command, args *yaml.Node) (bool, error) {
		command, args = unalias(command), unalias(args)
		if args.Kind != yaml.SequenceNode {
			return false, nil
		}
		var head []*yaml.Node
		switch {
		case command.Kind == yaml.SequenceNode:
			head = command.Content
		case command.Kind == yaml.ScalarNode && plainCommandWord(command.Value):
			// Kubernetes derives one argv from command and args jointly, so a
			// scalar command names the executable of that joint argv.
			head = []*yaml.Node{command}
		default:
			return false, nil
		}
		items := append(append([]*yaml.Node{}, head...), args.Content...)
		argv := make([]string, len(items))
		known := make([]bool, len(items))
		line := command.Line
		for at, item := range items {
			item = unalias(item)
			if item.Kind != yaml.ScalarNode {
				return false, nil
			}
			if at == 0 {
				line = item.Line
			}
			argv[at], known[at] = item.Value, true
		}
		_, err := s.argv(argv, known, line, 0)
		return true, err
	}
	// Resolve only the five executable fields, retaining their original nodes for
	// diagnostics. Memoizing each mapping keeps repeated merge aliases bounded;
	// copying whole effective mappings would expand unrelated data needlessly.
	fieldsByMapping := make(map[*yaml.Node]map[string]*yaml.Node)
	var effectiveFields func(*yaml.Node) (map[string]*yaml.Node, error)
	effectiveFields = func(node *yaml.Node) (map[string]*yaml.Node, error) {
		node = unalias(node)
		if node.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("YAML merge at line %d must contain mappings", node.Line)
		}
		if fields, ok := fieldsByMapping[node]; ok {
			return fields, nil
		}
		fields := make(map[string]*yaml.Node)
		var merges []*yaml.Node
		for i := 0; i+1 < len(node.Content); i += 2 {
			key, value := unalias(node.Content[i]), node.Content[i+1]
			if key.Kind != yaml.ScalarNode {
				continue
			}
			if key.Tag == "!!merge" {
				if len(merges) != 0 {
					return nil, fmt.Errorf("duplicate YAML merge at line %d", key.Line)
				}
				merges = append(merges, value)
				continue
			}
			switch key.Value {
			case "command", "args", "run", "shell", "entrypoint":
				if _, exists := fields[key.Value]; exists {
					return nil, fmt.Errorf("duplicate YAML command field %q at line %d", key.Value, key.Line)
				}
				fields[key.Value] = value
			}
		}
		// Explicit fields win regardless of where << occurs. Earlier mappings in
		// a merge sequence win over later mappings, so fill only missing fields.
		for _, merge := range merges {
			merge = unalias(merge)
			sources := []*yaml.Node{merge}
			if merge.Kind == yaml.SequenceNode {
				sources = merge.Content
			}
			for _, source := range sources {
				inherited, err := effectiveFields(source)
				if err != nil {
					return nil, err
				}
				for name, value := range inherited {
					if _, exists := fields[name]; !exists {
						fields[name] = value
					}
				}
			}
		}
		fieldsByMapping[node] = fields
		return fields, nil
	}
	active := make(map[*yaml.Node]bool)
	// A node reached through repeated aliases is otherwise re-traversed once per
	// path to it, so nested aliases make the scan exponential in their depth.
	// Memoize successful visits; `active` still detects genuine cycles. The key
	// carries `commands` because the same node can be reached as a mapping key
	// (data) and as a value (a command operand), which are different traversals.
	type visitKey struct {
		node     *yaml.Node
		commands bool
	}
	done := make(map[visitKey]bool)
	var visit func(*yaml.Node, bool) error
	visit = func(node *yaml.Node, commands bool) (err error) {
		if active[node] {
			return errors.New("cyclic YAML alias")
		}
		key := visitKey{node: node, commands: commands}
		if done[key] {
			return nil
		}
		active[node] = true
		defer func() {
			delete(active, node)
			if err == nil {
				done[key] = true
			}
		}()
		if node.Kind == yaml.AliasNode {
			return visit(node.Alias, commands)
		}
		if node.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(node.Content); i += 2 {
				key, value := node.Content[i], node.Content[i+1]
				if err := visit(key, false); err != nil {
					return err
				}
				if err := visit(value, commands); err != nil {
					return err
				}
			}
			// Complete cycle-checked traversal before following merge aliases or
			// decoding operands, including mappings reused as keys and values.
			if !commands {
				return nil
			}
			fields, err := effectiveFields(node)
			if err != nil {
				return err
			}
			for _, name := range []string{"command", "run", "shell", "entrypoint"} {
				value := fields[name]
				if value == nil {
					continue
				}
				if name == "command" && fields["args"] != nil {
					handled, err := combined(value, fields["args"])
					if err != nil {
						return err
					}
					if handled {
						continue
					}
				}
				if err := operand(value); err != nil {
					return err
				}
			}
			return nil
		}
		for _, child := range node.Content {
			if err := visit(child, commands); err != nil {
				return err
			}
		}
		return nil
	}
	for _, document := range documents {
		if err := visit(document, true); err != nil {
			return err
		}
	}
	return nil
}
