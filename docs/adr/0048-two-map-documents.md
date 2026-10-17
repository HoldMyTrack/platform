# ADR-0048: The map is two documents, a shared basemap style and the account's layers, applied by native maps

## Status

Accepted. Supersedes ADR-0047's "a separate overlays route" alternative and its consequence that the overlays only grow, and closes ADR-0042's open question of a WebView map. Built for Fog and Heatmap (`ARCHITECTURE.md` §2.1).

## Context

ADR-0047 moved Fog and Heatmap into the served style's metadata. The track lines, pace bands, bike paths and Spots still defined their look in each client: about 40 values copied between the web and Android, with the pace-band binning rule implemented twice. An iOS app would make a third copy. Those layers' sources carry the account's tile version, which a style shared by every account can't hold, and MapLibre Native can't change a source's URL, so a native client already replaces sources from their specifications whenever the version moves.

## Decision

- **The map loads from two documents, fetched in parallel.** The basemap style, `GET /v1/map/style/{flavor}`, stays unauthenticated and the same for every account. The layers document, `GET /v1/map/layers?flavor=`, holds every layer HoldMyTrack draws over it, at the account's tile version, behind the session.
- **Both carry the build they came from**, and a client holding two from different builds fetches the style again.
- **Runtime state travels as hooks, never values**: a layer names the Layers menu switch that shows it, and the properties that read a run-time value through `["var", name]`, which the client binds with `let`. The document gives every value's default, so a client that doesn't know one still draws.
- **No backward compatibility for this change.** The Android release and the deploy go live together, and the deploy raises `MIN_ANDROID_BUILD` to it (`IMPLEMENTATION.md` §4.33), so an older build shows the Update screen.
- **The map stays native on the phones**, decided 2026-10-17: the documents leave a native client only the device's part, so a WebView map would save little code for the risk ADR-0042 names.

## Alternatives considered

- **Everything in the style's metadata**, as ADR-0047 began. The tile version would make the style per account: no shared cache, and a 100 KB re-fetch per upload.
- **The layers in the style, with the tile version as a query the client appends.** Every native client still needs the builder that replaces sources, and the style still couldn't be shared.
- **Selection by feature-state**, as the web drew it. MapLibre Native Android has no feature-state API; filters on id sets work on every renderer.
- **Keeping old builds working.** Two contract shapes in the server and the app for one release cycle, for a build the Update screen already replaces.

## Consequences

- **A change to how any layer HoldMyTrack draws looks is a server deploy.**
- **The overlays wait for an authenticated request** beside the style on a phone's first launch; later launches draw the kept document at once and revalidate it.
- **A layers change that breaks the contract is an Android release with a raised minimum build**, released and deployed back to back.
- **Device-only drawing stays in the clients**: the live recording line, the editors' handles, badge bitmaps in the server's colors, tap tolerances and gestures.