package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"unicode/utf8"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/parse"
)

// syncSources is the `source` allowlist this endpoint accepts: Path 2's on-device health stores
// (IMPLEMENTATION.md §4.0), Health Connect and HealthKit, and "recorded", the app's own GPS
// recording (§4.0.4), all in one batched wire shape. A file upload has its own endpoint and
// source.
var syncSources = map[string]bool{"healthconnect": true, "healthkit": true, "recorded": true}

// syncExternalIDPattern is what a synced track's external_id may be: a Health Connect or
// HealthKit record UUID, or the UUID GPS-Logger mints, fits easily. The id goes into the raw
// payload's object key and into two VARCHAR(255) columns (source_detail as id + ".json"), so
// a "/" or ".." would nest or escape the key, and an over-long id was accepted as "enqueued"
// only for the worker's insert to fail on it.
var syncExternalIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$`)

// maxSyncBatchTracks bounds one request to a page of a sync run: a first backfill makes
// several requests, each retried on its own when interrupted (IMPLEMENTATION.md §4.0).
const maxSyncBatchTracks = 100

// maxSyncPointsPerTrack bounds one synced track: nearly 14 hours at a point a second,
// with room above a 100-mile ride's 36,000. A file upload's bound is parse.MaxPoints.
const maxSyncPointsPerTrack = 50000

// maxSyncBodyBytes bounds the whole batched request body: generously above
// maxSyncBatchTracks tracks at maxSyncPointsPerTrack points each, the same
// "cap before reading the body fully" posture handleUpload's maxUploadBytes documents.
const maxSyncBodyBytes = 64 << 20 // 64 MiB

// syncTrackRequest is one track in the batch. Its raw payload is parse.JSONActivity
// (payload), which names the type activity_type, as every payload already stored does and the
// data download hands back; the request names it track_type like the rest of /v2.
type syncTrackRequest struct {
	// ExternalID is the source's own stable id for this record (a Health Connect session UUID,
	// say). (user_id, source, external_id) is what a retried sync is matched on, not a hash of
	// the bytes below, so the same record is the same track even if its JSON re-serializes
	// differently.
	ExternalID  string            `json:"external_id"`
	TrackType   string            `json:"track_type"`
	Points      []parse.JSONPoint `json:"points"`
	Name        string            `json:"name,omitempty"`
	Description string            `json:"description,omitempty"`
}

// payload is the raw payload stored for the track.
func (t syncTrackRequest) payload() parse.JSONActivity {
	return parse.JSONActivity{TrackType: t.TrackType, Points: t.Points, Name: t.Name, Description: t.Description}
}

type syncTracksRequest struct {
	Source string             `json:"source"`
	Tracks []syncTrackRequest `json:"tracks"`
}

// syncTrackResult reports what happened to one track in the batch — a batch is never
// all-or-nothing: one bad entry doesn't abort the rest.
type syncTrackResult struct {
	ExternalID string `json:"external_id"`
	Status     string `json:"status"` // "enqueued" | "already_processed" | "rejected"
	Error      string `json:"error,omitempty"`
}

type syncTracksResponse struct {
	Results []syncTrackResult `json:"results"`
}

// handleSyncTracks serves IMPLEMENTATION.md §4.0's `POST /v2/sync/tracks` — Path 2's
// batched normalized points. Like handleUpload (§4.1 step 1), this only validates and
// enqueues an `ingest` job per track with its raw payload inline (ingest.EnqueueRaw), two
// queries however large the batch; no parsing or privacy clipping happens inline.
// ingest.Process needs no Path-2-specific branch at all: each track's raw payload is
// stored as JSON and read back through parse.ByExtensionUpTo's ".json" case
// (parse.ParseJSON), the same "differ only in how bytes arrive, converge on §4.1 step 2"
// contract §4.0 states for all three paths.
//
// Idempotent on (user_id, source, external_id) per §4.0's hard invariant, enforced the same
// two-layer way as every other path: EnqueueRaw's existence check here is the fast
// path, and ingest.Process's `ON CONFLICT DO NOTHING` at persist time is the actual guarantee
// under concurrent duplicates.
func (s *Server) handleSyncTracks(w http.ResponseWriter, r *http.Request) {
	// Before the body is read, as for uploads.
	if limited(w, r, s.syncLimiter, "error.sync_rate_limit") {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxSyncBodyBytes)

	var req syncTracksRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		msg := bodyError(err, "invalid request body")
		if errors.Is(err, parse.ErrPointIncomplete) {
			msg = err.Error()
		}
		writeAPIError(w, msg, http.StatusBadRequest)
		return
	}
	if !syncSources[req.Source] {
		writeAPIError(w, `invalid "source", want "healthconnect", "healthkit" or "recorded"`, http.StatusBadRequest)
		return
	}
	if len(req.Tracks) == 0 {
		writeAPIError(w, "activities must not be empty", http.StatusBadRequest)
		return
	}
	if len(req.Tracks) > maxSyncBatchTracks {
		writeAPIError(w, fmt.Sprintf("too many activities in one batch (%d), want %d or fewer", len(req.Tracks), maxSyncBatchTracks), http.StatusBadRequest)
		return
	}
	// Every track sent counts, taken or not; a batch that doesn't fit in what's left of
	// the hour is refused whole and counts nothing.
	if !s.syncTrackLimiter.allowN(rateKey(authInfoFromContext(r.Context()), rateLimitAddress(r)), len(req.Tracks)) {
		httpErrorT(w, r, http.StatusTooManyRequests, "error.sync_track_rate_limit", "max", s.syncTrackLimiter.limit)
		return
	}

	batch := newBatchID()

	ctx := r.Context()
	userID := userIDFromContext(ctx)
	l := i18n.Get(requestLang(r))
	results := make([]syncTrackResult, len(req.Tracks))
	var items []ingest.RawItem
	var slots []int // results index of each item
	for i, act := range req.Tracks {
		item, rejection := s.syncItem(l, req.Source, batch, act)
		if rejection != "" {
			results[i] = syncTrackResult{ExternalID: act.ExternalID, Status: "rejected", Error: rejection}
			continue
		}
		items = append(items, item)
		slots = append(slots, i)
	}
	// What the account's limits (account_limits.go) have no room for is rejected one by one,
	// so the phone keeps it and offers it again.
	usage, err := readUsage(ctx, s.pool, userID)
	if err != nil {
		s.log.Error("sync: read usage failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	sizes := make([]int64, len(items))
	for k, it := range items {
		sizes[k] = int64(len(it.Data))
	}
	if fit, refused := fitWithinLimits(usage, sizes); refused != "" {
		msg := limitMessage(l, refused)
		for k := fit; k < len(items); k++ {
			results[slots[k]] = syncTrackResult{ExternalID: items[k].ExternalID, Status: "rejected", Error: msg}
		}
		items, slots = items[:fit], slots[:fit]
	}
	enqueued, err := ingest.EnqueueRaw(ctx, s.pool, userID, items)
	if err != nil {
		s.log.Error("sync enqueue failed", "err", err, "activities", len(items))
	}
	for k, i := range slots {
		switch {
		case err != nil:
			results[i] = syncTrackResult{ExternalID: items[k].ExternalID, Status: "rejected", Error: l.T("error.internal")}
		case enqueued[k].AlreadyProcessed:
			results[i] = syncTrackResult{ExternalID: enqueued[k].ExternalID, Status: "already_processed"}
		default:
			results[i] = syncTrackResult{ExternalID: enqueued[k].ExternalID, Status: "enqueued"}
		}
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, syncTracksResponse{Results: results})
}

// maxKnownIDs bounds one `POST /v2/sync/known` request: three months of a phone's sessions,
// which is what the Sync screen asks about, is a few hundred at most.
const maxKnownIDs = 5000

type syncKnownRequest struct {
	Source      string   `json:"source"`
	ExternalIDs []string `json:"external_ids"`
}

type syncKnownResponse struct {
	Known []string `json:"known"`
	// The known ones whose ingest hasn't finished: sent, not on the map yet.
	Processing []string `json:"processing"`
}

// handleSyncKnown serves IMPLEMENTATION.md §4.0.3's `POST /v2/sync/known`: which of a phone's
// candidates the account already has (ingest.KnownExternalIDs). The phone keeps no cursor —
// its Sync screen lists what's on the device minus what this answers — so a reinstall or a
// second phone agrees with the server, and a track deleted here is offered again.
func (s *Server) handleSyncKnown(w http.ResponseWriter, r *http.Request) {
	var req syncKnownRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	if !syncSources[req.Source] {
		writeAPIError(w, `invalid "source", want "healthconnect", "healthkit" or "recorded"`, http.StatusBadRequest)
		return
	}
	if len(req.ExternalIDs) > maxKnownIDs {
		writeAPIError(w, fmt.Sprintf("too many external_ids (%d), want %d or fewer", len(req.ExternalIDs), maxKnownIDs), http.StatusBadRequest)
		return
	}
	for _, id := range req.ExternalIDs {
		if !syncExternalIDPattern.MatchString(id) {
			httpErrorT(w, r, http.StatusBadRequest, "error.sync_external_id_invalid")
			return
		}
	}
	ctx := r.Context()
	known, processing, err := ingest.KnownExternalIDs(ctx, s.pool, userIDFromContext(ctx), req.Source, req.ExternalIDs)
	if err != nil {
		s.log.Error("sync known failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if known == nil {
		known = []string{}
	}
	if processing == nil {
		processing = []string{}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, syncKnownResponse{Known: known, Processing: processing})
}

// syncItem validates one batch entry and turns it into the item EnqueueRaw takes, or returns
// why it was rejected — one bad entry is that entry's result, never the whole batch's.
func (s *Server) syncItem(l *i18n.Localizer, source, batch string, act syncTrackRequest) (ingest.RawItem, string) {
	if act.ExternalID == "" {
		return ingest.RawItem{}, l.T("error.sync_external_id_required")
	}
	if !syncExternalIDPattern.MatchString(act.ExternalID) {
		return ingest.RawItem{}, l.T("error.sync_external_id_invalid")
	}
	// Same >= 2 raw points floor ingest.Process itself enforces on the raw points
	// (internal/ingest.Process) — a coarse pre-check here, not a claim that every track
	// clearing it will also survive the trim; that deeper rejection still happens
	// asynchronously in the worker, exactly as it already does for Path 3 uploads.
	if len(act.Points) < 2 {
		return ingest.RawItem{}, l.T("error.sync_too_few_points")
	}
	if len(act.Points) > maxSyncPointsPerTrack {
		return ingest.RawItem{}, l.T("error.sync_too_many_points", "n", len(act.Points), "max", maxSyncPointsPerTrack)
	}
	// The bounds handleUpdateTrack enforces, checked here: a client can send any custom
	// activity_type (GPS Logger's free-text field), and an over-long value would otherwise fail
	// on the column's width in the worker instead of being refused here.
	if utf8.RuneCountInString(act.TrackType) > maxTrackTypeLen {
		return ingest.RawItem{}, l.T("error.track_type_too_long", "max", maxTrackTypeLen)
	}
	if utf8.RuneCountInString(act.Name) > maxTrackNameLen {
		return ingest.RawItem{}, l.T("error.track_name_too_long", "max", maxTrackNameLen)
	}
	if utf8.RuneCountInString(act.Description) > maxTrackDescriptionLen {
		return ingest.RawItem{}, l.T("error.track_description_too_long", "max", maxTrackDescriptionLen)
	}

	// The payload, not the whole syncTrackRequest: the raw payload stored for the job is
	// exactly what parse.ParseJSON expects to decode back (activity_type + points), with no
	// external_id or other request-envelope fields mixed in.
	data, err := json.Marshal(act.payload())
	if err != nil {
		s.log.Error("sync activity marshal failed", "external_id", act.ExternalID, "err", err)
		return ingest.RawItem{}, l.T("error.internal")
	}
	return ingest.RawItem{
		Source:     source,
		Filename:   act.ExternalID + ".json",
		Ext:        ".json",
		Data:       data,
		ExternalID: act.ExternalID,
		Batch:      batch,
	}, ""
}
