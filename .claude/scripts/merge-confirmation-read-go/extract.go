// Package mergeconfirmation guards the post-merge read prescribed to agents.
// The parser and fixtures preserve the Bash guard's vocabulary and normalization (#2582).
package mergeconfirmation

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
)

var (
	literalWhitespace = regexp.MustCompile(`\\[nrt]`)
	space             = regexp.MustCompile(`[[:space:]]+`)
	jsonSeparator     = regexp.MustCompile("--json[[:space:]]*[=,]*[[:space:]]*[`\"']?[[:space:]]*")
	fieldList         = regexp.MustCompile(`--json [A-Za-z,]*`)
)

func extract(input []byte, jsonSurface bool) ([]string, error) {
	text := string(input)
	if jsonSurface {
		decoder := json.NewDecoder(strings.NewReader(text))
		decoder.UseNumber()
		var values []string
		var visit func(any)
		visit = func(value any) {
			switch v := value.(type) {
			case string:
				values = append(values, v, "%") // Hard scalar boundary, as in jq '.. | strings | ., "%"'.
			case []any:
				for _, child := range v {
					visit(child)
				}
			case map[string]any:
				// Boundary sentinels make traversal order immaterial; sorting makes it deterministic.
				keys := make([]string, 0, len(v))
				for key := range v {
					keys = append(keys, key)
				}
				sort.Strings(keys)
				for _, key := range keys {
					visit(v[key])
				}
			}
		}
		// jq accepts a stream of JSON values (and an empty stream); preserve that
		// grammar instead of silently tightening the existing surface contract.
		for {
			var document any
			if err := decoder.Decode(&document); err == io.EOF {
				break
			} else if err != nil {
				return nil, fmt.Errorf("JSON surface does not parse: %w", err)
			}
			visit(document)
		}
		text = strings.Join(values, "\n")
	}
	text = literalWhitespace.ReplaceAllString(text, " ")
	text = strings.ReplaceAll(text, "\\", " ")
	var joined []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, " \t\r\v\f")
		if len(joined) > 0 && strings.HasSuffix(joined[len(joined)-1], ",") {
			joined[len(joined)-1] += strings.TrimLeft(line, " \t\r\v\f")
		} else {
			joined = append(joined, line)
		}
	}
	text = strings.Join(joined, " ")
	text = strings.ReplaceAll(strings.ReplaceAll(text, "…", ","), "...", ",")
	text = jsonSeparator.ReplaceAllString(space.ReplaceAllString(text, " "), "--json ")
	unique := map[string]bool{}
	for _, list := range fieldList.FindAllString(text, -1) {
		unique[list] = true
	}
	var lists []string
	for list := range unique {
		lists = append(lists, list)
	}
	sort.Strings(lists)
	return lists, nil
}

func badLists(lists []string) []string {
	var bad []string
	for _, list := range lists {
		for _, field := range strings.Split(strings.TrimPrefix(list, "--json "), ",") {
			if field == "merged" || field == "isInMergeQueue" {
				bad = append(bad, list)
				break
			}
		}
	}
	return bad
}
