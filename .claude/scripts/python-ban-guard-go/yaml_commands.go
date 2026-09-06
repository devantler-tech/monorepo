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
