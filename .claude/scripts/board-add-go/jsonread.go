package main

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

// The readers below give GitHub's answers the same meaning the jq filters of the Bash
// implementation gave them, and are stricter only where that fails closed: an answer must be
// exactly one JSON value.

var errNotObject = errors.New("cannot index a non-object")

// decodeJSON parses exactly one JSON value. Numbers keep their text.
func decodeJSON(text string) (any, bool) {
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, false
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, false
	}
	return value, true
}

// path follows object keys like jq's `.a.b.c`: a missing key or a null yields null, and indexing
// anything else that is not an object is an error.
func path(value any, keys ...string) (any, error) {
	for _, key := range keys {
		switch typed := value.(type) {
		case nil:
			return nil, nil
		case map[string]any:
			value = typed[key]
		default:
			return nil, errNotObject
		}
	}
	return value, nil
}

// rawOrEmpty is jq's `-r '. // empty'` for a scalar: null and false print nothing, a string
// prints itself, and anything else prints as JSON.
func rawOrEmpty(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case bool:
		if !typed {
			return ""
		}
		return "true"
	case string:
		return typed
	case json.Number:
		return typed.String()
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return ""
		}
		return string(encoded)
	}
}

// iterate is jq's `.[]?`: an array's elements or an object's values; anything else yields none.
func iterate(value any) []any {
	switch typed := value.(type) {
	case []any:
		return typed
	case map[string]any:
		values := make([]any, 0, len(typed))
		for _, v := range typed {
			values = append(values, v)
		}
		return values
	default:
		return nil
	}
}

// noGraphQLErrors is `(.errors // [] | length) == 0` on an object root.
func noGraphQLErrors(root any) bool {
	object, isObject := root.(map[string]any)
	if !isObject {
		return false
	}
	switch typed := object["errors"].(type) {
	case nil:
		return true
	case bool:
		return !typed
	case []any:
		return len(typed) == 0
	case map[string]any:
		return len(typed) == 0
	case string:
		return utf8.RuneCountInString(typed) == 0
	case json.Number:
		return strings.Trim(strings.TrimPrefix(typed.String(), "-"), "0.") == ""
	default:
		return false
	}
}
