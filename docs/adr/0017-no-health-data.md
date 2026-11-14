# ADR-0017: No health data: heart rate is never read, stored or shown

## Status

Accepted.

## Context

HoldMyTrack is about where someone has been, not how their body performed (`VISION.md` §1.1). It had nonetheless grown one fitness-style surface: a floating card beside the focused activity, on web and Android, with a Pace/Heart rate toggle, a strip of pace or heart-rate bands laid out by distance, an elevation curve, and a hover (or touch-and-drag) readout. To feed it, every parser read heart rate out of GPX, TCX and FIT files, `activity_streams.heartrate` stored it per point, the sync wire format accepted it, dedupe counted it as a richer channel, and the demo export wrote it back out.

The question came up while looking at whether to also read heart rate from Health Connect. A probe on a Pixel 10a (2026-09-27) found it would work well: all 37 sessions with a route also had heart rate (Fitbit, a sample every 2–3 s), and 36 of 37 were fully covered at a 60 s matching tolerance. That made the real question sharper — not "can we get it" but "should HoldMyTrack hold it at all".

## Decision

**HoldMyTrack keeps no health data: "we don't keep your health profile, only the geographical data you trust us with."**

- Heart rate is never read — not from a file, not from Health Connect — never stored and never shown. The parsers skip it, `JSONPoint` has no field for it (an old client that still sends `heart_rate` is ignored, not rejected), and the database has no column for it.
- The profile card goes on both clients, with its toggle and readout.
- Pace stays, as route context: the focused activity's track is colored by pace (`SPEC.md` FR-4.8), and average speed and moving time are computed. `GET /v1/activities/{id}/track-metrics` returns position and speed per vertex and nothing else.
- Elevation stays as route data: per-point `elevation_m`, elevation gain, the Trends totals and GPX export.
- The original upload is kept as-is. It can contain heart rate, but it is only ever read for its route (to rebuild the activity after a track edit or a Private location change), and it is deleted with the activity. The About and Help pages say so.

## Alternatives considered

- **Keep the card and add Health Connect heart rate.** Rejected. The probe showed it would work, which is exactly why it had to be decided on scope rather than feasibility: it adds a health permission to the Android app, a Play health-data declaration, and more sensitive data held per user, for a view that serves training analysis rather than exploration.
- **Remove only the UI, keep parsing and storing heart rate.** Rejected. Data kept "in case" is still data held, and the promise on the About page would not be true.
- **Strip heart rate from stored originals too** — store a canonical, route-only copy of each upload instead of the original bytes, and backfill existing blobs. Rejected for now: the raw key is content-addressed, feeds re-derivation and the demo export, and a rewrite of every stored blob is a larger, riskier change than the benefit. The docs are worded honestly instead: the file is kept, only the route is read from it.
- **Keep the card without heart rate** (pace strip plus elevation curve). Rejected: it is still a fitness instrument, and the pace-colored track on the map already answers "where was I faster or slower".

## Consequences

- Heart rate stored before this decision was deleted from the database; it still exists inside any original upload that carried it.
- There is no exact pace readout anywhere; the bands are a relative picture only.
- `VISION.md` §1.1 and §4.2 and `SPEC.md` FR-4.8 carry the policy; the About and Help pages state it to users.