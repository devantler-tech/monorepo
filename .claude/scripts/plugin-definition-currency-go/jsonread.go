package main

// The Bash implementation read every JSON document with one jq filter. These functions are those
// filters, evaluated the way jq evaluates them: a payload is a STREAM of documents, each is judged
// on its own, the outputs are joined line by line, and any document jq could not evaluate fails the
// whole read. Indexing a value that is neither an object nor null is an error, as it is in jq.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

var errJQ = errors.New("jq could not evaluate the document")

// documents decodes the stream. A malformed document is an error, as it is for jq.
func documents(raw []byte) ([]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var docs []any
	for {
		var v any
		err := dec.Decode(&v)
		if errors.Is(err, io.EOF) {
			return docs, nil
		}
		if err != nil {
			return docs, err
		}
		docs = append(docs, v)
	}
}

// field is jq's `.name`: an object's member (null when absent), null on null, an error otherwise.
func field(v any, name string) (any, error) {
	switch t := v.(type) {
	case nil:
		return nil, nil
	case map[string]any:
		return t[name], nil
	default:
		return nil, errJQ
	}
}

// path is a chain of fields.
func path(v any, names ...string) (any, error) {
	var err error
	for _, name := range names {
		if v, err = field(v, name); err != nil {
			return nil, err
		}
	}
	return v, nil
}

// each is jq's `.[]`: an array's elements or an object's values; an error on anything else.
func each(v any) ([]any, error) {
	switch t := v.(type) {
	case []any:
		return t, nil
	case map[string]any:
		values := make([]any, 0, len(t))
		for _, key := range sortedKeys(t) {
			values = append(values, t[key])
		}
		return values, nil
	default:
		return nil, errJQ
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func isTrue(v any) bool { b, ok := v.(bool); return ok && b }

// truthy is jq's notion: everything except null and false.
func truthy(v any) bool { return v != nil && v != false }

// joinLines is how `jq -r` output reads after `$(...)`: one line per output, trailing newlines gone.
func joinLines(lines []string) string {
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// codexEnabled is
//
//	if (.installed | type) != "array" then "unparseable"
//	else [ .installed[] | select(.pluginId == $id) | .enabled ]
//	     | if length == 0 then "false" elif any(. == true) then "true" else "false" end
//	end
func codexEnabled(raw []byte, id string) (string, error) {
	docs, err := documents(raw)
	if err != nil {
		return "", err
	}
	var out []string
	for _, doc := range docs {
		installed, err := field(doc, "installed")
		if err != nil {
			return "", err
		}
		list, ok := installed.([]any)
		if !ok {
			out = append(out, "unparseable")
			continue
		}
		var enabled []any
		for _, el := range list {
			pluginID, err := field(el, "pluginId")
			if err != nil {
				return "", err
			}
			if s, ok := pluginID.(string); !ok || s != id {
				continue
			}
			value, err := field(el, "enabled")
			if err != nil {
				return "", err
			}
			enabled = append(enabled, value)
		}
		verdict := "false"
		for _, value := range enabled {
			if isTrue(value) {
				verdict = "true"
			}
		}
		out = append(out, verdict)
	}
	return joinLines(out), nil
}

// trailingSlashes is jq's sub("/+$"; ""): the regex's `$` also matches before a final newline.
var trailingSlashes = regexp.MustCompile(`/+(\n?)\z`)

func stripTrailingSlashes(s string) string { return trailingSlashes.ReplaceAllString(s, "$1") }

// registryPaths is the install-path selection of the Claude plugin registry:
//
//	[.plugins[$id][]?
//	  | select(type == "object" and (.installPath | type) == "string" and (.installPath | length) > 0)]
//	| (if length == 0 then error("not installed") else . end) as $all
//	| ([$all[] | select((.scope == "project" or .scope == "local")
//	      and ((.projectPath // "") | sub("/+$"; "")) == ($root | sub("/+$"; "")))
//	    | .installPath] | unique) as $project
//	| ([$all[] | select(.scope == null or .scope == "user") | .installPath] | unique) as $user
//	| (if ($project | length) > 0 then $project else $user end)
//	| if length == 1 then .[0] else "AMBIGUOUS \(length)" end
func registryPaths(raw []byte, id, root string) (string, error) {
	docs, err := documents(raw)
	if err != nil {
		return "", err
	}
	wantRoot := stripTrailingSlashes(root)
	var out []string
	for _, doc := range docs {
		plugins, err := field(doc, "plugins")
		if err != nil {
			return "", err
		}
		records, err := field(plugins, id)
		if err != nil {
			return "", err
		}
		candidates, _ := each(records) // `[]?`: a value that cannot be iterated yields nothing
		var all []map[string]any
		for _, candidate := range candidates {
			record, ok := candidate.(map[string]any)
			if !ok {
				continue
			}
			if p, ok := record["installPath"].(string); ok && utf8.RuneCountInString(p) > 0 {
				all = append(all, record)
			}
		}
		if len(all) == 0 {
			return "", errors.New("not installed")
		}
		var project, user []string
		for _, record := range all {
			scope := record["scope"]
			if scope == "project" || scope == "local" {
				projectPath := record["projectPath"]
				if !truthy(projectPath) {
					projectPath = ""
				}
				s, ok := projectPath.(string)
				if !ok {
					return "", errJQ
				}
				if stripTrailingSlashes(s) == wantRoot {
					project = append(project, record["installPath"].(string))
				}
			}
			if scope == nil || scope == "user" {
				user = append(user, record["installPath"].(string))
			}
		}
		chosen := unique(project)
		if len(chosen) == 0 {
			chosen = unique(user)
		}
		if len(chosen) == 1 {
			out = append(out, chosen[0])
		} else {
			out = append(out, "AMBIGUOUS "+itoa(len(chosen)))
		}
	}
	return joinLines(out), nil
}

func unique(values []string) []string {
	sorted := append([]string(nil), values...)
	sort.Strings(sorted)
	var out []string
	for i, v := range sorted {
		if i == 0 || v != sorted[i-1] {
			out = append(out, v)
		}
	}
	return out
}

func itoa(n int) string { return strconv.Itoa(n) }

// jq's test() is a Perl-style regex: `$` also matches before a final newline.
var (
	assetPath   = regexp.MustCompile(`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\n?\z`)
	assetSHA256 = regexp.MustCompile(`^[0-9a-f]{64}\n?\z`)
)

// runtimeAssets is `jq -er` over the provider-neutral desired state:
//
//	.spec.source.requiredRuntimeAssets
//	| select(type == "array" and length > 0)
//	| select(all(.[];
//	    type == "object"
//	    and (.path | type == "string" and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"))
//	    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
//	    and .executable == true
//	  ))
//	| select((map(.path) | unique | length) == length)
//	| .[].path
//
// With -e, a filter that produced no output at all is a failure.
func runtimeAssets(raw []byte) (string, error) {
	docs, err := documents(raw)
	if err != nil {
		return "", err
	}
	var out []string
	for _, doc := range docs {
		value, err := path(doc, "spec", "source", "requiredRuntimeAssets")
		if err != nil {
			return "", err
		}
		list, ok := value.([]any)
		if !ok || len(list) == 0 {
			continue
		}
		valid := true
		var paths []string
		for _, el := range list {
			record, ok := el.(map[string]any)
			if !ok {
				valid = false
				break
			}
			p, ok := record["path"].(string)
			if !ok || !assetPath.MatchString(p) {
				valid = false
				break
			}
			sum, ok := record["sha256"].(string)
			if !ok || !assetSHA256.MatchString(sum) {
				valid = false
				break
			}
			if !isTrue(record["executable"]) {
				valid = false
				break
			}
			paths = append(paths, p)
		}
		if !valid || len(unique(paths)) != len(paths) {
			continue
		}
		out = append(out, paths...)
	}
	if len(out) == 0 {
		return "", errJQ
	}
	return joinLines(out), nil
}

// rawText is how `jq -r` prints a value.
func rawText(v any) (string, error) {
	switch t := v.(type) {
	case string:
		return t, nil
	case nil:
		return "null", nil
	default:
		b, err := json.Marshal(t)
		return string(b), err
	}
}

// forgeTruncated is `jq -r '.truncated // false'`. Its failure was never checked, so the outputs
// produced before a failure are what is read.
func forgeTruncated(raw []byte) string {
	docs, _ := documents(raw)
	var out []string
	for _, doc := range docs {
		value, err := field(doc, "truncated")
		if err != nil {
			break
		}
		if !truthy(value) {
			value = false
		}
		text, err := rawText(value)
		if err != nil {
			break
		}
		out = append(out, text)
	}
	return joinLines(out)
}

// blobs is `.tree[] | select(.type == "blob")` for one document.
func blobs(doc any) ([]map[string]any, []any, error) {
	tree, err := field(doc, "tree")
	if err != nil {
		return nil, nil, err
	}
	entries, err := each(tree)
	if err != nil {
		return nil, nil, err
	}
	var found []map[string]any
	var order []any
	for _, entry := range entries {
		kind, err := field(entry, "type")
		if err != nil {
			return nil, nil, err
		}
		if kind == "blob" {
			// field() succeeded, so a blob entry is an object (null has no type "blob").
			found = append(found, entry.(map[string]any))
			order = append(order, entry)
		}
	}
	return found, order, nil
}

// forgePathSafety is `jq -er` over
//
//	if any(.tree[] | select(.type=="blob");
//	    .path | (contains("\\") or contains("\t") or contains("\r") or contains("\n")))
//	then "unsafe" else "safe" end
func forgePathSafety(raw []byte) (string, error) {
	docs, err := documents(raw)
	if err != nil {
		return "", err
	}
	var out []string
	for _, doc := range docs {
		entries, _, err := blobs(doc)
		if err != nil {
			return "", err
		}
		verdict := "safe"
		for _, entry := range entries {
			p, ok := entry["path"].(string)
			if !ok {
				return "", errJQ
			}
			if strings.ContainsAny(p, "\\\t\r\n") {
				verdict = "unsafe"
				break
			}
		}
		out = append(out, verdict)
	}
	if len(out) == 0 {
		return "", errJQ
	}
	return joinLines(out), nil
}

// tsvField is one value of jq's @tsv.
func tsvField(v any) (string, error) {
	switch t := v.(type) {
	case string:
		return strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\r", "\\r", "\n", "\\n").Replace(t), nil
	case nil:
		return "", nil
	case bool, json.Number:
		return rawText(t)
	default:
		return "", errJQ
	}
}

// forgeTree is `jq -r '.tree[] | select(.type=="blob") | [.sha,.mode,.path] | @tsv'`.
func forgeTree(raw []byte) (string, error) {
	docs, err := documents(raw)
	if err != nil {
		return "", err
	}
	var out []string
	for _, doc := range docs {
		entries, _, err := blobs(doc)
		if err != nil {
			return "", err
		}
		for _, entry := range entries {
			var fields []string
			for _, name := range []string{"sha", "mode", "path"} {
				text, err := tsvField(entry[name])
				if err != nil {
					return "", err
				}
				fields = append(fields, text)
			}
			out = append(out, strings.Join(fields, "\t"))
		}
	}
	return joinLines(out), nil
}
