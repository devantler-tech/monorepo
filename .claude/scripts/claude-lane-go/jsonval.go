package main

// The scripts read every JSON value through jq. These helpers reproduce the few jq semantics the
// filters depend on, so a value jq would have rejected, skipped or printed in a particular way is
// treated the same here: truthiness (only null and false are false), `.[]?` iteration (array
// elements or object values, and nothing for anything else), the type order `sort` uses, and how
// `jq -r` prints a value once a command substitution has stripped its trailing newlines.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
)

// decodeAll parses every JSON text in data, as jq reads a file or a stream.
func decodeAll(data []byte) ([]any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	var out []any
	for {
		var v any
		err := dec.Decode(&v)
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
}

// truthy is jq's truth: everything except null and false.
func truthy(v any) bool {
	if v == nil {
		return false
	}
	if b, ok := v.(bool); ok {
		return b
	}
	return true
}

func isTrue(v any) bool {
	b, ok := v.(bool)
	return ok && b
}

// iterate is `.[]?`: an array's elements, an object's values, and nothing for any other value.
func iterate(v any) []any {
	switch t := v.(type) {
	case []any:
		return t
	case map[string]any:
		out := make([]any, 0, len(t))
		for _, x := range t {
			out = append(out, x)
		}
		return out
	}
	return nil
}

// field is `.name` on a value: an object's member, null on null, and an error on anything else.
func field(v any, name string) (any, bool) {
	switch t := v.(type) {
	case nil:
		return nil, true
	case map[string]any:
		return t[name], true
	}
	return nil, false
}

// typeRank is the order jq's `sort` places values of different types in.
func typeRank(v any) int {
	switch t := v.(type) {
	case nil:
		return 0
	case bool:
		if !t {
			return 1
		}
		return 2
	case float64:
		return 3
	case string:
		return 4
	case []any:
		return 5
	}
	return 6
}

// extremeString returns the smallest (or largest) of values in jq's sort order when that value is
// a string. A non-string extreme cannot be a timestamp, so it reports false, as every caller then
// fails to parse it.
func extremeString(values []any, largest bool) (string, bool) {
	if len(values) == 0 {
		return "", false
	}
	best := values[0]
	for _, v := range values[1:] {
		rv, rb := typeRank(v), typeRank(best)
		switch {
		case largest && rv > rb, !largest && rv < rb:
			best = v
		case rv == rb && rv == 4:
			if s := v.(string); (largest && s > best.(string)) || (!largest && s < best.(string)) {
				best = v
			}
		}
	}
	s, ok := best.(string)
	return s, ok
}

// jqNumber prints a number the way jq 1.7 does: integers plainly, anything else in shortest form.
func jqNumber(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e17 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// jqRaw is `jq -r` output after a command substitution stripped the trailing newlines.
func jqRaw(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return jqNumber(t)
	case string:
		return strings.TrimRight(t, "\n")
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
	return strings.TrimRight(b.String(), "\n")
}

// jqRawOrEmpty is `jq -r '... // empty'`: nothing for null and false.
func jqRawOrEmpty(v any) string {
	if !truthy(v) {
		return ""
	}
	return jqRaw(v)
}

// nonNegativeInteger accepts a non-negative whole number jq would print without an exponent.
func nonNegativeInteger(v any) (int64, bool) {
	f, ok := v.(float64)
	if !ok || f < 0 || f != math.Trunc(f) || f >= 1e17 {
		return 0, false
	}
	return int64(f), true
}
