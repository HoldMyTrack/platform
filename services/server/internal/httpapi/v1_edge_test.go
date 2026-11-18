package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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
	if err := json.Unmarshal(renameV1JSON([]byte(in), names, false), &got); err != nil {
		t.Fatal(err)
	}
	// A type named like a key stays: the types map is keyed by data.
	_ = json.Unmarshal([]byte(`{"activities":[{"id":"a","activity_type":"walking","n":12345678901234567890}],"types":{"tracks":{"label":"Tracks"}}}`), &want)
	if g, w := mustJSON(t, got), mustJSON(t, want); g != w {
		t.Errorf("got %s\nwant %s", g, w)
	}
	if got := string(renameV1JSON([]byte(`{"error":"track_limit","message":"m"}`), nil, true)); !strings.Contains(got, `"activity_limit"`) {
		t.Errorf("error code not renamed: %s", got)
	}
	if got := string(renameV1JSON([]byte(`{"error":"not_found","message":"m"}`), nil, true)); !strings.Contains(got, `"not_found"`) {
		t.Errorf("unchanged code changed: %s", got)
	}
	if got := string(renameV1JSON([]byte(`not json`), names, false)); got != "not json" {
		t.Errorf("non-JSON body changed: %s", got)
	}
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

	if rec := d.do(me, "GET", "/v1/tracks", nil); rec.Code != http.StatusNotFound {
		t.Errorf("GET /v1/tracks: %d, want 404", rec.Code)
	}
	d.decode(d.do(me, "DELETE", "/v1/stories/"+story.ID, nil), http.StatusNoContent, nil)
}
