package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
)

// /v1 is the API under its names before Tracks and Trips, frozen at api/openapi.yaml for the
// installed apps (IMPLEMENTATION.md §4.31). Nothing registers under it: serveV1 rewrites each
// request onto its /v2 route, renaming the path, query names, JSON keys and multipart fields,
// serves it, and renames the JSON keys and error code of the answer back. Each endpoint's
// table names only what that endpoint carries, so a key in another document, such as `tracks`
// in the layers document, is never touched.

// v1Endpoint is one /v1 path pattern and what it becomes under /v2; a pattern segment in braces
// matches any one segment and keeps it.
type v1Endpoint struct {
	old, new string
	query    map[string]string // old name → new
	keys     map[string]string // old JSON key → new, at any depth of the request and the answer
	form     map[string]string // old multipart field → new
}

var (
	v1TrackRowKeys = map[string]string{"activities": "tracks", "activity_type": "track_type", "stories": "trips", "track_edit": "route_edit"}
	v1TripKeys     = map[string]string{"stories": "trips", "activity_ids": "track_ids", "activity_type": "track_type"}
	v1PhotoKeys    = map[string]string{"activity_id": "track_id"}
	v1TripFilter   = map[string]string{"story": "trip"}
)

var v1Endpoints = []v1Endpoint{
	{old: "/activities", new: "/tracks", query: v1TripFilter, keys: v1TrackRowKeys},
	{old: "/activities/upload", new: "/tracks/upload"},
	{old: "/activities/area", new: "/tracks/area", query: v1TripFilter, keys: v1TrackRowKeys},
	{old: "/activities/overlaps", new: "/tracks/overlaps", keys: map[string]string{"activity_id": "track_id", "activity_type": "track_type"}},
	{old: "/activities/stats-card", new: "/tracks/stats-card", keys: map[string]string{"activity_ids": "track_ids"}},
	{old: "/activities/pending", new: "/tracks/pending"},
	{old: "/activities/summary", new: "/tracks/summary", query: v1TripFilter},
	{old: "/activities/histogram", new: "/tracks/histogram", query: v1TripFilter},
	{old: "/activities/graph-stats", new: "/tracks/graph-stats"},
	{old: "/activities/trends", new: "/tracks/trends"},
	{old: "/activities/{id}", new: "/tracks/{id}", keys: v1TrackRowKeys},
	{old: "/activities/{id}/track-metrics", new: "/tracks/{id}/route-metrics", keys: map[string]string{"activity_id": "track_id"}},
	{old: "/activities/{id}/track-points", new: "/tracks/{id}/route-points"},
	{old: "/activities/{id}/track-edit", new: "/tracks/{id}/route-edit"},
	{old: "/activity-types", new: "/track-types"},
	{old: "/photos", new: "/photos", query: map[string]string{"activity": "track", "story": "trip"}, keys: v1PhotoKeys, form: v1PhotoKeys},
	{old: "/photos/place", new: "/photos/place", keys: v1PhotoKeys},
	{old: "/photos/{id}", new: "/photos/{id}", keys: v1PhotoKeys},
	{old: "/stories", new: "/trips", keys: v1TripKeys},
	{old: "/stories/{id}", new: "/trips/{id}", keys: v1TripKeys},
	{old: "/stories/{id}/activities", new: "/trips/{id}/tracks", keys: v1TripKeys},
	{old: "/stories/{id}/send", new: "/trips/{id}/send"},
	{old: "/story-sends", new: "/trip-sends", keys: map[string]string{"story_name": "trip_name", "activity_count": "track_count"}},
	{old: "/story-sends/{id}/accept", new: "/trip-sends/{id}/accept"},
	{old: "/story-sends/{id}", new: "/trip-sends/{id}"},
	{old: "/sync/activities", new: "/sync/tracks", keys: map[string]string{"activities": "tracks", "activity_type": "track_type"}},
	{old: "/uploads", new: "/uploads", keys: v1PhotoKeys},
	{old: "/uploads/active", new: "/uploads/active", keys: v1PhotoKeys},
	{old: "/uploads/{id}", new: "/uploads/{id}", keys: v1PhotoKeys},
}

// v1ErrorCodes are the error codes /v1 sends under another name, /v2 code → /v1 code.
var v1ErrorCodes = map[string]string{
	"photo_no_route":             "photo_no_track",
	"route_edit_too_large":       "track_edit_too_large",
	"route_points_rate_limit":    "track_points_rate_limit",
	"track_type_required":        "activity_type_required",
	"track_type_too_long":        "activity_type_too_long",
	"track_name_too_long":        "activity_name_too_long",
	"track_description_too_long": "activity_description_too_long",
	"track_limit":                "activity_limit",
	"sync_track_rate_limit":      "sync_activity_rate_limit",
	"trip_send_limit":            "story_send_limit",
	"trip_name_required":         "story_name_required",
	"trip_name_too_long":         "story_name_too_long",
	"trip_description_too_long":  "story_description_too_long",
}

// v1OpaqueKeys hold an object keyed by data, a track type's name, whose keys are never renamed.
var v1OpaqueKeys = map[string]bool{"types": true}

// v1Route is what a /v1 path (without the prefix) becomes: the /v2 path and the endpoint's
// table, nil for a path whose name didn't change. ok is false for a path only /v2 has, which
// /v1 doesn't serve.
func v1Route(path string) (newPath string, e *v1Endpoint, ok bool) {
	for i := range v1Endpoints {
		if p, ok := matchV1Pattern(v1Endpoints[i].old, v1Endpoints[i].new, path); ok {
			return p, &v1Endpoints[i], true
		}
	}
	for i := range v1Endpoints {
		if v1Endpoints[i].old != v1Endpoints[i].new {
			if _, ok := matchV1Pattern(v1Endpoints[i].new, v1Endpoints[i].new, path); ok {
				return "", nil, false
			}
		}
	}
	return path, nil, true
}

// matchV1Pattern reports whether path matches from, and if so the path to with from's braced
// segments filled in from path, in order.
func matchV1Pattern(from, to, path string) (string, bool) {
	fs, ps := strings.Split(from, "/"), strings.Split(path, "/")
	if len(fs) != len(ps) {
		return "", false
	}
	var vars []string
	for i, f := range fs {
		switch {
		case strings.HasPrefix(f, "{"):
			if ps[i] == "" {
				return "", false
			}
			vars = append(vars, ps[i])
		case f != ps[i]:
			return "", false
		}
	}
	ts := strings.Split(to, "/")
	for i, t := range ts {
		if strings.HasPrefix(t, "{") && len(vars) > 0 {
			ts[i], vars = vars[0], vars[1:]
		}
	}
	return strings.Join(ts, "/"), true
}

// serveV1 serves a /v1 request as its /v2 route (the comment at the top of this file).
func (s *Server) serveV1(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, v1Prefix)
	newPath, e, ok := v1Route(rest)
	if !ok {
		s.setSecurityHeaders(w.Header())
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	r2 := r.Clone(r.Context())
	r2.URL.Path, r2.URL.RawPath = apiPrefix+newPath, ""
	r2.RequestURI = r2.URL.RequestURI()
	// r is what ServeHTTP's metrics read the route from.
	defer func() { r.Pattern = r2.Pattern }()
	if e == nil {
		e = &v1Endpoint{}
	}
	if len(e.query) > 0 {
		r2.URL.RawQuery = renameV1Query(r2.URL.Query(), e.query)
		r2.RequestURI = r2.URL.RequestURI()
	}
	if len(e.keys) > 0 && r.Body != nil && isJSONRequest(r) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxSyncBodyBytes))
		if err != nil {
			s.setSecurityHeaders(w.Header())
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				writeAPIError(w, "request body too large", http.StatusRequestEntityTooLarge)
			} else {
				writeAPIError(w, "unreadable request body", http.StatusBadRequest)
			}
			return
		}
		body = renameV1JSON(body, e.keys, false)
		r2.Body, r2.ContentLength = io.NopCloser(bytes.NewReader(body)), int64(len(body))
		r2.Header.Del("Content-Length")
	}
	if len(e.form) > 0 && r.Body != nil {
		renameV1MultipartFields(r2, e.form)
		defer r2.Body.Close()
	}
	vw := &v1Writer{ResponseWriter: w, keys: invert(e.keys)}
	s.serve(vw, r2)
	vw.finish()
}

func isJSONRequest(r *http.Request) bool {
	mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return mt == "application/json"
}

func invert(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[v] = k
	}
	return out
}

func renameV1Query(q map[string][]string, names map[string]string) string {
	for old, new := range names {
		if v, ok := q[old]; ok {
			delete(q, old)
			q[new] = v
		}
	}
	return url.Values(q).Encode()
}

// renameV1JSON renames body's object keys by names at any depth, and with errorCode the
// top-level error code by v1ErrorCodes. A body that isn't JSON comes back as it is, for the
// handler to refuse.
func renameV1JSON(body []byte, names map[string]string, errorCode bool) []byte {
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return body
	}
	v = renameKeys(v, names)
	if obj, ok := v.(map[string]any); ok && errorCode {
		if code, ok := obj["error"].(string); ok {
			if old, ok := v1ErrorCodes[code]; ok {
				obj["error"] = old
			}
		}
	}
	var out bytes.Buffer
	if err := json.NewEncoder(&out).Encode(v); err != nil {
		return body
	}
	return out.Bytes()
}

func renameKeys(v any, names map[string]string) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, val := range t {
			if !v1OpaqueKeys[k] {
				val = renameKeys(val, names)
			}
			if n, ok := names[k]; ok {
				k = n
			}
			out[k] = val
		}
		return out
	case []any:
		for i := range t {
			t[i] = renameKeys(t[i], names)
		}
	}
	return v
}

// renameV1MultipartFields streams r's multipart body through with the fields in names renamed,
// leaving every part's content as it is.
func renameV1MultipartFields(r *http.Request, names map[string]string) {
	mt, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mt != "multipart/form-data" || params["boundary"] == "" {
		return
	}
	in := multipart.NewReader(r.Body, params["boundary"])
	pr, pw := io.Pipe()
	out := multipart.NewWriter(pw)
	r.Header.Set("Content-Type", out.FormDataContentType())
	r.Header.Del("Content-Length")
	r.Body, r.ContentLength = pr, -1
	go func() {
		pw.CloseWithError(copyV1Parts(in, out, names))
	}()
}

func copyV1Parts(in *multipart.Reader, out *multipart.Writer, names map[string]string) error {
	for {
		p, err := in.NextPart()
		if err == io.EOF {
			return out.Close()
		}
		if err != nil {
			return err
		}
		h := make(map[string][]string, len(p.Header))
		for k, v := range p.Header {
			h[k] = v
		}
		if n, ok := names[p.FormName()]; ok {
			disp := map[string]string{"name": n}
			if f := p.FileName(); f != "" {
				disp["filename"] = f
			}
			h["Content-Disposition"] = []string{mime.FormatMediaType("form-data", disp)}
		}
		w, err := out.CreatePart(h)
		if err != nil {
			return err
		}
		if _, err := io.Copy(w, p); err != nil {
			return err
		}
	}
}

// v1Writer holds back a JSON answer that has keys to rename, or is an error whose code might
// be, and writes it renamed on finish; any other answer goes straight through.
type v1Writer struct {
	http.ResponseWriter
	keys    map[string]string // new key → old
	status  int
	decided bool
	buf     *bytes.Buffer
}

func (w *v1Writer) WriteHeader(status int) {
	if w.decided {
		return
	}
	w.decided, w.status = true, status
	mt, _, _ := mime.ParseMediaType(w.Header().Get("Content-Type"))
	if mt == "application/json" && (len(w.keys) > 0 || status >= 400) {
		w.buf = &bytes.Buffer{}
		return
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *v1Writer) Write(b []byte) (int, error) {
	if !w.decided {
		w.WriteHeader(http.StatusOK)
	}
	if w.buf != nil {
		return w.buf.Write(b)
	}
	return w.ResponseWriter.Write(b)
}

func (w *v1Writer) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// finish writes a held-back answer; serveV1 calls it once serve has returned.
func (w *v1Writer) finish() {
	if w.buf == nil {
		return
	}
	body := renameV1JSON(w.buf.Bytes(), w.keys, w.status >= 400)
	w.Header().Del("Content-Length")
	w.ResponseWriter.WriteHeader(w.status)
	_, _ = w.ResponseWriter.Write(body)
}
