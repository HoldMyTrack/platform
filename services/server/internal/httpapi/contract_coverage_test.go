package httpapi

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
)

// Every response api/openapi.yaml describes must come out of some test, or its shape is never
// checked against the handler's JSON. checkContract records each (method, path, status) it
// validates; after a full run with a database, TestMain fails on a described response no test
// produced, and on an allowlist entry a test now produces.

// unexercisedPath lists the responses no test can produce, one "METHOD /path STATUS" per line,
// each with a # reason.
const unexercisedPath = "testdata/contract-unexercised.txt"

var (
	contractHitsMu sync.Mutex
	contractHits   = map[string]bool{}
)

func recordContractHit(method, path string, status int) {
	contractHitsMu.Lock()
	defer contractHitsMu.Unlock()
	contractHits[fmt.Sprintf("%s %s %d", method, path, status)] = true
}

func TestMain(m *testing.M) {
	flag.Parse()
	code := m.Run()
	if code == 0 && os.Getenv("TEST_DATABASE_URL") != "" && fullRun() {
		if problems := contractCoverage(); len(problems) > 0 {
			fmt.Fprintf(os.Stderr, "contract coverage (%s):\n  %s\n", unexercisedPath, strings.Join(problems, "\n  "))
			code = 1
		}
	}
	os.Exit(code)
}

// fullRun is false when -run or -skip narrows the run, which leaves responses unexercised by
// design.
func fullRun() bool {
	for _, name := range []string{"test.run", "test.skip"} {
		if f := flag.Lookup(name); f != nil && f.Value.String() != "" {
			return false
		}
	}
	return true
}

// contractCoverage compares the responses the contract describes with those the run produced.
func contractCoverage() []string {
	doc, err := newContractLoader().LoadFromFile(contractPath)
	if err != nil {
		return []string{err.Error()}
	}
	allowed, err := readUnexercised()
	if err != nil {
		return []string{err.Error()}
	}
	var problems []string
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			for status := range op.Responses.Map() {
				key := method + " " + path + " " + status
				switch {
				case contractHits[key] && allowed[key]:
					problems = append(problems, key+": produced by a test; drop it from the allowlist")
				case !contractHits[key] && !allowed[key]:
					problems = append(problems, key+": no test produces it")
				}
				delete(allowed, key)
			}
		}
	}
	for key := range allowed {
		problems = append(problems, key+": allowlisted but not in the contract")
	}
	sort.Strings(problems)
	return problems
}

func readUnexercised() (map[string]bool, error) {
	f, err := os.Open(unexercisedPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]bool{}
	scanner := bufio.NewScanner(f)
	for n := 1; scanner.Scan(); n++ {
		line, reason, _ := strings.Cut(scanner.Text(), "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("%s:%d: %q has no # reason", unexercisedPath, n, line)
		}
		fields := strings.Fields(line)
		if len(fields) != 3 {
			return nil, fmt.Errorf("%s:%d: want METHOD /path STATUS, got %q", unexercisedPath, n, line)
		}
		out[fields[0]+" "+fields[1]+" "+fields[2]] = true
	}
	return out, scanner.Err()
}
