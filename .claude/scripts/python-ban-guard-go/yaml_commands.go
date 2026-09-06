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
	combined := func(command, args *yaml.Node) (bool, error) {
		command, args = unalias(command), unalias(args)
		if command.Kind != yaml.SequenceNode || args.Kind != yaml.SequenceNode {
			return false, nil
		}
		items := append(append([]*yaml.Node{}, command.Content...), args.Content...)
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
	active := make(map[*yaml.Node]bool)
	var visit func(*yaml.Node, bool) error
	visit = func(node *yaml.Node, commands bool) error {
		if active[node] {
			return errors.New("cyclic YAML alias")
		}
		active[node] = true
		defer delete(active, node)
		if node.Kind == yaml.AliasNode {
			return visit(node.Alias, commands)
		}
		if node.Kind == yaml.MappingNode {
			var argsValue *yaml.Node
			for i := 0; i+1 < len(node.Content); i += 2 {
				if k := unalias(node.Content[i]); k.Kind == yaml.ScalarNode && k.Value == "args" {
					argsValue = node.Content[i+1]
				}
			}
			for i := 0; i+1 < len(node.Content); i += 2 {
				key, value := node.Content[i], node.Content[i+1]
				if err := visit(key, false); err != nil {
					return err
				}
				if err := visit(value, commands); err != nil {
					return err
				}
				key = unalias(key)
				if commands && key.Kind == yaml.ScalarNode && (key.Value == "command" || key.Value == "run" || key.Value == "shell") {
					if key.Value == "command" && argsValue != nil {
						handled, err := combined(value, argsValue)
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
