package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/getkin/kin-openapi/openapi3"
)

// Every operation the frozen /v1 contract describes reaches an operation the /v2 contract
// describes, with the same method: v1_edge.go leaves no installed app's call unserved.
func TestV1RouteCoversTheV1Contract(t *testing.T) {
	v1, err := newContractLoader().LoadFromFile(v1ContractPath)
	if err != nil {
		t.Fatal(err)
	}
	v2, err := newContractLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range contractOperations(v1) {
		newPath, _, ok := v1Route(op.path)
		if !ok {
			t.Errorf("%s %s: refused by v1Route", op.method, op.path)
			continue
		}
		item := v2.Paths.Find(newPath)
		if item == nil || item.GetOperation(op.method) == nil {
			t.Errorf("%s %s: becomes %s, which /v2 doesn't describe", op.method, op.path, newPath)
		}
	}
}

func TestV1Route(t *testing.T) {
	for _, tc := range []struct {
		path, want string
		ok         bool
	}{
		{"/activities", "/tracks", true},
		{"/activities/area", "/tracks/area", true},
		{"/activities/a1", "/tracks/a1", true},
		{"/activities/a1/track-edit", "/tracks/a1/route-edit", true},
		{"/stories/s1/activities", "/trips/s1/tracks", true},
		{"/story-sends/x/accept", "/trip-sends/x/accept", true},
		{"/photos/place", "/photos/place", true},
		{"/photos/p1/thumb", "/photos/p1/thumb", true},
		{"/auth/me", "/auth/me", true},
		// Only /v2 has these names.
		{"/tracks", "", false},
		{"/tracks/a1/route-points", "", false},
		{"/trips", "", false},
	} {
		got, _, ok := v1Route(tc.path)
		if got != tc.want || ok != tc.ok {
			t.Errorf("v1Route(%q) = %q, %v; want %q, %v", tc.path, got, ok, tc.want, tc.ok)
		}
	}
}

func TestRenameV1JSON(t *testing.T) {
	names := map[string]string{"tracks": "activities", "track_type": "activity_type"}
	in := `{"tracks":[{"id":"a","track_type":"walking","n":12345678901234567890}],"types":{"tracks":{"label":"Tracks"}}}`
	var got, want any
	if err := json.Unmarshal(renameV1JSON([]byte(in), v1Rename{keys: names}), &got); err != nil {
		t.Fatal(err)
	}
	// A type named like a key stays: the types map is keyed by data.
	_ = json.Unmarshal([]byte(`{"activities":[{"id":"a","activity_type":"walking","n":12345678901234567890}],"types":{"tracks":{"label":"Tracks"}}}`), &want)
	if g, w := mustJSON(t, got), mustJSON(t, want); g != w {
		t.Errorf("got %s\nwant %s", g, w)
	}
	if got := string(renameV1JSON([]byte(`{"error":"track_limit","message":"m"}`), v1Rename{errorCode: true})); !strings.Contains(got, `"activity_limit"`) {
		t.Errorf("error code not renamed: %s", got)
	}
	if got := string(renameV1JSON([]byte(`{"error":"not_found","message":"m"}`), v1Rename{errorCode: true})); !strings.Contains(got, `"not_found"`) {
		t.Errorf("unchanged code changed: %s", got)
	}
	// What /v2 would refuse comes through as it is, for the handler to refuse.
	for _, body := range []string{`not json`, `{"tracks":[]} trailing`, `{"tracks":[],"activities":[]}`} {
		old := map[string]string{"activities": "tracks"}
		if got := string(renameV1JSON([]byte(body), v1Rename{keys: old})); got != body {
			t.Errorf("%s came out as %s", body, got)
		}
	}
	ids := string(renameV1JSON([]byte(`{"id":"route-bands","sources":{"route-bands":{}},"layers":[{"id":"route-bands-line","source":"route-bands","note":"route-bands x"}]}`),
		v1Rename{keys: map[string]string{"route-bands": "track-bands"}, values: map[string]string{"route-bands": "track-bands", "route-bands-line": "track-bands-line"}}))
	if strings.Contains(ids, `"route-bands"`) || strings.Contains(ids, `"route-bands-line"`) || !strings.Contains(ids, `"route-bands x"`) {
		t.Errorf("layer ids: %s", ids)
	}
	urlOut := string(renameV1JSON([]byte(`{"url":"/v2/photos/p","thumb_url":"/v2/photos/p/thumb","caption":"/v2/x"}`), v1Rename{urls: true}))
	if !strings.Contains(urlOut, `"url":"/v1/photos/p"`) || !strings.Contains(urlOut, `"thumb_url":"/v1/photos/p/thumb"`) || !strings.Contains(urlOut, `"caption":"/v2/x"`) {
		t.Errorf("photo URLs: %s", urlOut)
	}
}

// A /v1 body is read and renamed only when the handler reads it, and no further than its limit.
func TestV1RenamedBody(t *testing.T) {
	src := &countingReader{r: strings.NewReader(`{"activity_ids":["a"]}`)}
	b := &v1RenamedBody{src: io.NopCloser(src), limit: 100, names: map[string]string{"activity_ids": "track_ids"}}
	if src.n != 0 {
		t.Fatal("read before the handler asked")
	}
	got, err := io.ReadAll(b)
	if err != nil || strings.TrimSpace(string(got)) != `{"track_ids":["a"]}` {
		t.Errorf("got %s, %v", got, err)
	}
	long := &v1RenamedBody{src: io.NopCloser(strings.NewReader(strings.Repeat(" ", 101) + "{}")), limit: 100}
	var tooLarge *http.MaxBytesError
	if _, err := io.ReadAll(long); !errors.As(err, &tooLarge) {
		t.Errorf("over the limit: %v, want a MaxBytesError", err)
	}
}

type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestRenameV1MultipartFields(t *testing.T) {
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	mw.WriteField("activity_id", "a1")
	part, _ := mw.CreateFormFile("file", "photo.jpg")
	part.Write([]byte("\xff\xd8 image bytes"))
	mw.Close()
	req := httptest.NewRequest("POST", "/v2/photos", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	renameV1MultipartFields(req, map[string]string{"activity_id": "track_id"})
	defer req.Body.Close()
	if err := req.ParseMultipartForm(1 << 20); err != nil {
		t.Fatal(err)
	}
	if got := req.FormValue("track_id"); got != "a1" {
		t.Errorf("track_id = %q, want a1", got)
	}
	if _, ok := req.MultipartForm.Value["activity_id"]; ok {
		t.Error("activity_id still sent")
	}
	f, h, err := req.FormFile("file")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(f)
	if h.Filename != "photo.jpg" || string(data) != "\xff\xd8 image bytes" {
		t.Errorf("file part changed: %q %q", h.Filename, data)
	}
}

// An installed app's calls under /v1's names, each checked against the frozen /v1 contract by
// dbTest.do: the edge renames the request on the way in and the answer on the way out.
func TestV1EdgeServesTheOldNames(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	me := d.newAccount(false)
	walk := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 3000, durationSecs: 60,
		startedAt: photoTrackStart, at: &[2]float64{10, 50}})

	var story struct {
		ID          string   `json:"id"`
		ActivityIDs []string `json:"activity_ids"`
	}
	d.decode(d.do(me, "POST", "/v1/stories", map[string]any{"name": "Walks", "activity_ids": []string{walk}}), http.StatusCreated, &story)
	if len(story.ActivityIDs) != 1 || story.ActivityIDs[0] != walk {
		t.Fatalf("POST /v1/stories: activity_ids %v", story.ActivityIDs)
	}

	var list struct {
		Activities []struct {
			ID           string `json:"id"`
			ActivityType string `json:"activity_type"`
			Stories      []struct {
				ID string `json:"id"`
			} `json:"stories"`
		} `json:"activities"`
		Types map[string]any `json:"types"`
	}
	d.decode(d.do(me, "GET", "/v1/activities?story="+story.ID, nil), http.StatusOK, &list)
	if len(list.Activities) != 1 || list.Activities[0].ActivityType != "walking" || len(list.Activities[0].Stories) != 1 {
		t.Fatalf("GET /v1/activities?story=: %+v", list)
	}
	if _, ok := list.Types["walking"]; !ok {
		t.Errorf("types lost walking: %v", list.Types)
	}

	d.decode(d.do(me, "PATCH", "/v1/activities/"+walk, map[string]any{"activity_type": "hiking"}), http.StatusOK, nil)
	if rec := d.do(me, "PATCH", "/v1/activities/"+walk, map[string]any{"activity_type": " "}); !strings.Contains(rec.Body.String(), `"activity_type_required"`) {
		t.Errorf("PATCH /v1/activities blank type: %d %s", rec.Code, rec.Body)
	}

	var metrics struct {
		ActivityID string `json:"activity_id"`
	}
	d.decode(d.do(me, "GET", "/v1/activities/"+walk+"/track-metrics", nil), http.StatusOK, &metrics)
	if metrics.ActivityID != walk {
		t.Errorf("track-metrics activity_id %q", metrics.ActivityID)
	}

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	mw.WriteField("activity_id", walk)
	mw.WriteField("route_at", photoTrackStart.Add(30*time.Second).Format(time.RFC3339))
	for name, data := range map[string][]byte{"file": testJPEG(t, 400, 300), "thumb": testJPEG(t, 32, 24)} {
		part, _ := mw.CreateFormFile(name, name+".jpg")
		part.Write(data)
	}
	mw.Close()
	var photo struct {
		ActivityID string `json:"activity_id"`
		URL        string `json:"url"`
	}
	d.decode(d.send(me, "POST", "/v1/photos", mw.FormDataContentType(), body.Bytes()), http.StatusCreated, &photo)
	if photo.ActivityID != walk {
		t.Errorf("POST /v1/photos: activity_id %q", photo.ActivityID)
	}
	var photos struct {
		Photos []struct {
			ActivityID string `json:"activity_id"`
		} `json:"photos"`
	}
	d.decode(d.do(me, "GET", "/v1/photos?story="+story.ID, nil), http.StatusOK, &photos)
	if len(photos.Photos) != 1 || photos.Photos[0].ActivityID != walk {
		t.Errorf("GET /v1/photos?story=: %+v", photos)
	}
	if !strings.HasPrefix(photo.URL, "/v1/photos/") {
		t.Errorf("POST /v1/photos: url %q, want it under /v1", photo.URL)
	}
	if rec := d.do(me, "GET", photo.URL, nil); rec.Code != http.StatusOK {
		t.Errorf("GET %s: %d", photo.URL, rec.Code)
	}

	var sync struct {
		Results []struct {
			Status string `json:"status"`
		} `json:"results"`
	}
	d.decode(d.do(me, "POST", "/v1/sync/activities", map[string]any{"source": "recorded", "activities": []map[string]any{{
		"external_id": "rec-1", "activity_type": "walking",
		"points": []map[string]any{
			{"lat": 50, "lon": 10, "time": "2026-05-02T10:00:00Z"},
			{"lat": 50.001, "lon": 10.001, "time": "2026-05-02T10:01:00Z"},
		},
	}}}), http.StatusOK, &sync)
	if len(sync.Results) != 1 || sync.Results[0].Status == "rejected" {
		t.Errorf("POST /v1/sync/activities: %+v", sync)
	}

	// Android builds on /v1 fill the pace bands' source by its old id.
	if body := d.do(me, "GET", "/v1/map/layers?flavor=light", nil).Body.String(); !strings.Contains(body, `"track-bands-line"`) || strings.Contains(body, "route-bands") {
		t.Errorf("GET /v1/map/layers still names route-bands, or lost track-bands")
	}
	if body := d.do(me, "GET", "/v2/map/layers?flavor=light", nil).Body.String(); !strings.Contains(body, `"route-bands-line"`) {
		t.Errorf("GET /v2/map/layers has no route-bands")
	}
	if rec := d.do(me, "GET", "/v1/tracks", nil); rec.Code != http.StatusNotFound {
		t.Errorf("GET /v1/tracks: %d, want 404", rec.Code)
	}
	d.decode(d.do(me, "DELETE", "/v1/stories/"+story.ID, nil), http.StatusNoContent, nil)
}

// Every key /v1 sends or takes is the /v2 key its endpoint's table renames, at every depth of
// every request and answer, and every query name likewise: a field added to /v2 without its
// table entry, or a key a table misses, fails here with no database.
func TestV1TablesMatchTheContracts(t *testing.T) {
	v1, err := newContractLoader().LoadFromFile(v1ContractPath)
	if err != nil {
		t.Fatal(err)
	}
	v2, err := newContractLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range contractOperations(v1) {
		newPath, e, ok := v1Route(op.path)
		if !ok {
			continue // TestV1RouteCoversTheV1Contract reports it
		}
		if e == nil {
			e = &v1Endpoint{}
		}
		op2 := v2.Paths.Find(newPath).GetOperation(op.method)
		if op2 == nil {
			continue
		}
		at := op.method + " " + op.path
		for _, p := range op.op.Parameters {
			if p.Value.In != "query" {
				continue
			}
			name := p.Value.Name
			if n, ok := e.query[name]; ok {
				name = n
			}
			if op2.Parameters.GetByInAndName("query", name) == nil {
				t.Errorf("%s: query %q becomes %q, which /v2 doesn't take", at, p.Value.Name, name)
			}
		}
		if op.op.RequestBody != nil {
			for mt, media := range op.op.RequestBody.Value.Content {
				media2 := op2.RequestBody.Value.Content.Get(mt)
				if media2 == nil {
					t.Errorf("%s: /v2 takes no %s body", at, mt)
					continue
				}
				names := e.keys
				if mt == "multipart/form-data" {
					names = e.form
				}
				compareV1Schemas(t, at+" request", media.Schema, media2.Schema, names, 0)
			}
		}
		for status, resp := range op.op.Responses.Map() {
			resp2 := op2.Responses.Value(status)
			if resp2 == nil {
				t.Errorf("%s: /v2 has no %s answer", at, status)
				continue
			}
			for mt, media := range resp.Value.Content {
				if media2 := resp2.Value.Content.Get(mt); media2 != nil {
					compareV1Schemas(t, at+" "+status, media.Schema, media2.Schema, e.keys, 0)
				}
			}
		}
	}
}

// compareV1Schemas fails on a property of s1 (/v1) that isn't names' rename of one of s2
// (/v2), or the other way round, and goes on into each pair.
func compareV1Schemas(t *testing.T, at string, r1, r2 *openapi3.SchemaRef, names map[string]string, depth int) {
	t.Helper()
	if r1 == nil || r2 == nil || r1.Value == nil || r2.Value == nil || depth > 20 {
		return
	}
	s1, s2 := r1.Value, r2.Value
	p1, p2 := v1SchemaProperties(s1), v1SchemaProperties(s2)
	for k1, sub1 := range p1 {
		k2 := k1
		if n, ok := names[k1]; ok {
			k2 = n
		}
		sub2, ok := p2[k2]
		if !ok {
			t.Errorf("%s: /v1 key %q has no /v2 key %q", at, k1, k2)
			continue
		}
		if !v1OpaqueKeys[k1] {
			compareV1Schemas(t, at+"."+k1, sub1, sub2, names, depth+1)
		}
	}
	old := invert(names)
	for k2 := range p2 {
		k1 := k2
		if o, ok := old[k2]; ok {
			k1 = o
		}
		if _, ok := p1[k1]; !ok {
			t.Errorf("%s: /v2 key %q reaches /v1 as %q, which /v1 doesn't have", at, k2, k1)
		}
	}
	compareV1Schemas(t, at+"[]", s1.Items, s2.Items, names, depth+1)
	if s1.AdditionalProperties.Schema != nil && s2.AdditionalProperties.Schema != nil {
		compareV1Schemas(t, at+"{}", s1.AdditionalProperties.Schema, s2.AdditionalProperties.Schema, names, depth+1)
	}
	for i := range s1.OneOf {
		if i < len(s2.OneOf) {
			compareV1Schemas(t, at, s1.OneOf[i], s2.OneOf[i], names, depth+1)
		}
	}
}

// v1SchemaProperties is s's properties with those of its allOf members.
func v1SchemaProperties(s *openapi3.Schema) map[string]*openapi3.SchemaRef {
	out := map[string]*openapi3.SchemaRef{}
	for k, v := range s.Properties {
		out[k] = v
	}
	for _, sub := range s.AllOf {
		if sub.Value != nil {
			for k, v := range v1SchemaProperties(sub.Value) {
				out[k] = v
			}
		}
	}
	return out
}
