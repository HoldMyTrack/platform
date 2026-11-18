# Roadmap

Last updated: 2026-11-18.

## How to read this document

The remaining work toward the product `VISION.md` describes, by its §5 milestones; each step points at the §/FR holding its design. A subsection whose every box is checked is deleted.

## Milestone 2 — Release and community

The current milestone, from the public launch on, with no exit gate (`VISION.md` §5).

### Cost control

Can land alongside any other work (`IMPLEMENTATION.md` §5.7).

- [ ] Serve the basemap as `/{z}/{x}/{y}` tiles Cloudflare can cache, with `pmtiles serve` on the droplet first: every range read reaches R2, since the free plan caches files only up to 512 MB (`IMPLEMENTATION.md` §5.4). Worth it once traffic grows: about 97,000 basemap requests in the 30 days to 2026-10-14 were under 1% of R2's free reads. The web style (`apps/web/src/map/style.ts`) and the server-built Android style (`mapstyle.go`) move from `pmtiles://` to the tile URL.

### Heatmap's leftovers

- [ ] When `MIN_ANDROID_BUILD` next rises, drop the Heatmap stubs kept for older builds (`IMPLEMENTATION.md` §4.33).

### Retiring `/v1`

- [ ] When `MIN_ANDROID_BUILD` reaches the build of release 0.34.3 (its `android/<versionCode>` tag) and `MIN_IOS_BUILD` that of release 0.2.4 (its `ios/<build>` tag), no supported build calls `/v1` (`IMPLEMENTATION.md` §4.31): delete `v1_edge.go`, the frozen contract, the tracks tile's `story` alias and the View on map link's `activity`, make `api/v2/` the contract, and move the OAuth callbacks to `/v2` after registering them with each provider.

### Renamed payloads

- [ ] Once production's `rewrite_sync_payload` jobs are all done and no stored `.json` payload names `activity_type`, delete the job kind and `parse.JSONActivity`'s `OldTrackType` (`IMPLEMENTATION.md` §4.0.3).

### Verification by code

- [ ] When `MIN_ANDROID_BUILD` reaches a build whose "check your email" screen takes the code, make the email code-only: drop its link, the `/verify` page and its Confirm button, the Facebook round trip from that page, and `POST /v1/auth/verify-email` (`IMPLEMENTATION.md` §4.9).

### After launch

- [ ] DPIA: drafted in `docs/DPIA.md`; left are its section 7 actions and the controller's sign-off.
- [ ] Review how long original uploads are kept (today, until the track is deleted) once real accounts show what they cost. They're the most sensitive thing held (`DPIA.md` R2) and likely the largest storage line; an expired one can't be re-clipped, rebuilt or exported (`IMPLEMENTATION.md` §5.7).
- [ ] The iOS app (`VISION.md` §4.1 Path 2, `ARCHITECTURE.md` §2), no date set; its plan is `apps/ios/docs/ROADMAP.md`.

---

## Milestone 3 — Social graph (not committed)

Public pages, followers and the rest (`VISION.md` §5.1, §5.2). No steps: the first is the Milestone 3 decision, made from Milestone 2's numbers, and not building it is one outcome.

---

## Ongoing

- [x] Describe every `/v1` endpoint in the API contract, `services/server/api/` (`IMPLEMENTATION.md` §4.31).
- [x] One error shape for the JSON API (`SPEC.md` §1.4), described in the contract.
- [x] Generate the web client's types from the contract (`apps/web/src/apiSchema.ts`).
- [x] Typed Android wire classes (`net/Wire.kt`) checked against the contract (`WireContractTest`).
- [x] Fail a pull request whose contract change breaks an installed client (`scripts/check-contract-break.sh`).
- [ ] Make `apps/web/scripts/build-basemap.sh` resolve the newest Protomaps build from `https://build-metadata.protomaps.dev/builds.json` when `BUILD` is unset, so CI's basemap cache miss stops failing once the pinned build ages out (`DEVELOPMENT.md`, "CI").
- [ ] Turn on Sign in with Facebook (`SPEC.md` FR-1.10): Meta publishes the app only after Business Verification, which needs a business document such as an EIN letter or a DBA filing (`docs/DEPLOY.md` §4). Not a launch gate.