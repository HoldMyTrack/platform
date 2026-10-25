package web

import (
	"io/fs"
	"regexp"
	"strings"
	"testing"
)

// The Content-Security-Policy runs scripts only from this origin's files (httpapi's
// contentSecurityPolicy), so a template's inline script or event handler would silently not
// run. Data blocks (application/json, application/ld+json) aren't scripts and stay inline.
func TestTemplatesHaveNoInlineScript(t *testing.T) {
	scriptTag := regexp.MustCompile(`<script\b[^>]*>`)
	handler := regexp.MustCompile(`<[a-z][^>]*\son[a-z]+\s*=`)
	err := fs.WalkDir(Embedded(), "templates", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".html") {
			return err
		}
		b, err := fs.ReadFile(Embedded(), path)
		if err != nil {
			return err
		}
		for _, tag := range scriptTag.FindAllString(string(b), -1) {
			if !strings.Contains(tag, " src=") && !strings.Contains(tag, `type="application/`) {
				t.Errorf("%s: inline script %s", path, tag)
			}
		}
		if found := handler.FindString(string(b)); found != "" {
			t.Errorf("%s: inline event handler in %s", path, found)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
