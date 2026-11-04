package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
)

// instance is one registered agent instance: its writer namespace and the exact author spelling
// each GitHub surface uses for it. API spellings are not interchangeable: accepting a GraphQL App
// login on the REST surface could admit an ordinary account with the same bare name.
type instance struct {
	namespace string
	authors   map[string]string
}

type registry struct {
	// instances keeps the registry's own order, which is the default lane order.
	instances []instance
}

var namespaceShape = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// loadRegistry accepts exactly one JSON document: version 1, a non-empty instances object whose
// policy publisher is one of them, and every instance carrying a well-formed unique namespace,
// all four author spellings, a definition adapter and at least one role. The checked-in consumer
// registry is the authority for membership; a head prefix alone can never register a provider.
func loadRegistry(data []byte) (registry, bool) {
	var reg registry
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var top map[string]json.RawMessage
	if err := decoder.Decode(&top); err != nil || top == nil {
		return reg, false
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return reg, false
	}
	var version json.Number
	if json.Unmarshal(top["version"], &version) != nil {
		return reg, false
	}
	if v, err := strconv.ParseFloat(version.String(), 64); err != nil || v != 1 {
		return reg, false
	}
	keys, values, ok := orderedObject(top["instances"])
	if !ok || len(keys) == 0 {
		return reg, false
	}
	var publisher string
	if json.Unmarshal(top["policyPublisher"], &publisher) != nil || publisher == "" {
		return reg, false
	}
	found := false
	seen := map[string]bool{}
	for i, key := range keys {
		if key == publisher {
			found = true
		}
		var raw struct {
			Namespace         *string           `json:"namespace"`
			Authors           map[string]any    `json:"authors"`
			DefinitionAdapter any               `json:"definitionAdapter"`
			Roles             []json.RawMessage `json:"roles"`
		}
		if json.Unmarshal(values[i], &raw) != nil || raw.Namespace == nil || raw.Authors == nil {
			return reg, false
		}
		if !namespaceShape.MatchString(*raw.Namespace) || seen[*raw.Namespace] {
			return reg, false
		}
		seen[*raw.Namespace] = true
		authors := map[string]string{}
		for _, surface := range []string{"cli", "rest", "graphql", "search"} {
			spelling, isString := raw.Authors[surface].(string)
			if !isString || spelling == "" {
				return reg, false
			}
			authors[surface] = spelling
		}
		if adapter, isString := raw.DefinitionAdapter.(string); !isString || adapter == "" {
			return reg, false
		}
		if len(raw.Roles) == 0 {
			return reg, false
		}
		for _, role := range raw.Roles {
			var name string
			if json.Unmarshal(role, &name) != nil || name == "" {
				return reg, false
			}
		}
		reg.instances = append(reg.instances, instance{namespace: *raw.Namespace, authors: authors})
	}
	if !found {
		return reg, false
	}
	return reg, true
}

// orderedObject returns an object's keys and raw values in document order.
func orderedObject(raw json.RawMessage) ([]string, []json.RawMessage, bool) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, nil, false
	}
	var keys []string
	var values []json.RawMessage
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, nil, false
		}
		key, isString := keyToken.(string)
		if !isString {
			return nil, nil, false
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, nil, false
		}
		keys = append(keys, key)
		values = append(values, value)
	}
	return keys, values, true
}

func (r registry) has(namespace string) bool {
	for _, inst := range r.instances {
		if inst.namespace == namespace {
			return true
		}
	}
	return false
}

// writerOK is true when lane's registered instance spells its writer as author on surface.
func (r registry) writerOK(lane, author, surface string) bool {
	for _, inst := range r.instances {
		if inst.namespace == lane && inst.authors[surface] == author {
			return true
		}
	}
	return false
}
