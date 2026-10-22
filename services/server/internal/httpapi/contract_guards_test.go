package httpapi

import (
	"context"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

// TestEveryGuardedOperationRefuses sends each operation the request its shared refusals describe:
// signed out where it answers Unauthenticated, from an unverified account where it answers
// NotVerified or Forbidden, and from the demo where Forbidden includes demo_read_only. A route
// registered without the guard its contract promises fails here.
func TestEveryGuardedOperationRefuses(t *testing.T) {
	d := newDBTest(t)
	unverified := d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, unverified.id); err != nil {
		t.Fatal(err)
	}
	demo := d.newAccount(true)

	doc, err := newContractLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range contractOperations(doc) {
		path := apiPrefix + samplePath(op.path)
		if refersTo(op.op, "401", "Unauthenticated") {
			if rec := d.do(account{}, op.method, path, nil); rec.Code != http.StatusUnauthorized {
				t.Errorf("%s %s signed out: status %d, want 401", op.method, op.path, rec.Code)
			}
		}
		if refersTo(op.op, "403", "NotVerified") || refersTo(op.op, "403", "Forbidden") {
			if rec := d.do(unverified, op.method, path, nil); rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "email_not_verified") {
				t.Errorf("%s %s unverified: status %d, want 403 email_not_verified: %s", op.method, op.path, rec.Code, rec.Body)
			}
		}
		if refersTo(op.op, "403", "Forbidden") {
			if rec := d.do(demo, op.method, path, nil); rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "demo_read_only") {
				t.Errorf("%s %s demo: status %d, want 403 demo_read_only: %s", op.method, op.path, rec.Code, rec.Body)
			}
		}
	}
}

type contractOperation struct {
	method, path string
	op           *openapi3.Operation
}

// contractOperations lists the contract's operations in a fixed order.
func contractOperations(doc *openapi3.T) []contractOperation {
	var out []contractOperation
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			out = append(out, contractOperation{method, path, op})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].path+out[i].method < out[j].path+out[j].method
	})
	return out
}

// refersTo reports whether op's response for status is the shared response named name.
func refersTo(op *openapi3.Operation, status, name string) bool {
	r := op.Responses.Value(status)
	return r != nil && strings.HasSuffix(r.Ref, "#/"+name)
}

var pathParam = regexp.MustCompile(`\{[^}]+\}`)

// samplePath fills a path's parameters with values its route accepts, so the request reaches the
// guard; no row has them.
func samplePath(path string) string {
	return pathParam.ReplaceAllStringFunc(path, func(p string) string {
		switch p {
		case "{n}":
			return "1"
		case "{flavor}":
			return "light"
		case "{external_id}":
			return "sample"
		}
		return "00000000-0000-4000-8000-000000000000"
	})
}
