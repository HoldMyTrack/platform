package httpapi

import (
	"encoding/json"
	"io"
	"slices"
	"strconv"
	"strings"
)

// A request body may hold only the fields its operation declares (docs/IMPLEMENTATION.md §4.31):
// a field the server doesn't know is refused, so a client's misspelling fails in testing instead
// of being dropped.

// decodeJSON decodes a request body into v, refusing a field v doesn't declare.
func decodeJSON(body io.Reader, v any) error {
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// bodyError is the 400 message for a body decodeJSON refused: the unknown field when that was
// the reason, invalid otherwise.
func bodyError(err error, invalid string) string {
	if field, ok := strings.CutPrefix(err.Error(), "json: unknown field "); ok {
		return "unknown field " + field
	}
	return invalid
}

// unknownField is the first key of a body decoded into a map that isn't one of known, and false
// when there is none.
func unknownField(body map[string]json.RawMessage, known ...string) (string, bool) {
	keys := make([]string, 0, len(body))
	for k := range body {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		if !slices.Contains(known, k) {
			return "unknown field " + strconv.Quote(k), true
		}
	}
	return "", false
}
