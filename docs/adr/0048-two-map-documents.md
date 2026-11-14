# ADR-0048: The server shapes the map as two documents, a shared basemap style and the account's layers, which native maps apply

## Status

Accepted. Built for every layer HoldMyTrack draws: Fog, the bike paths, the track lines, the pace bands and Spots (`ARCHITECTURE.md` §2.1). Closes ADR-0042's open question of a WebView map.

## Context

The web, Android and soon iOS draw the same map. The basemap style had one definition, served as a document (`ARCHITECTURE.md` §2.1), but each client built every layer HoldMyTrack draws over it by hand: the veil colours and edge widths, the zoom tiers, which layers each mode shows, the track lines, the pace bands, the bike paths and Spots. The web and Android held about 65 such values each, kept equal by comments, with the pace-band binning rule implemented twice. An iOS app would have made a third copy, and every change to the look shipped as an app release. Those layers' sources carry the account's tile version, which a style shared by every account can't hold, and MapLibre Native can't change a source's URL, so a native client already replaced sources from their specifications whenever the version moved.

## Decision

- **The server decides what the map shows, how it looks, and every rule about the data; a client decides only what needs the device**: input and gestures, sensors and recording, offline use, the source gate (ADR-0039), and anything that can't wait for a round trip.
- **A rule a client applies instantly travels as data ahead of time.** The documents carry every mode's view, and a mode switch applies one locally.
- **The map loads from two documents, fetched in parallel.** The basemap style, `GET /v1/map/style/{flavor}`, stays unauthenticated and the same for every account. The layers document, `GET /v1/map/layers?flavor=`, holds every layer HoldMyTrack draws over it, at the account's tile version, behind the session.
- **Both carry the build they came from**, and a client holding two from different builds fetches the style again.
- **Runtime state travels as hooks, never values**: a layer names the Layers menu switch that shows it, and the properties that read a run-time value through `["var", name]`, which the client binds with `let`. The document gives every value's default, so a client that doesn't know one still draws.
- **No backward compatibility for this change.** The Android release and the deploy go live together, and the deploy raises `MIN_ANDROID_BUILD` to it (`IMPLEMENTATION.md` §4.33), so an older build shows the Update screen.
- **The map stays native on the phones**, decided 2026-10-17: the documents leave a native client only the device's part, so a WebView map would save little code for the risk ADR-0042 names.

## Alternatives considered

- **Each client keeps its copy, checked by a script** comparing the values across files. Built first and dropped: it catches a drifted value, but the copies remain, and so does the layer construction around them in each language.
- **An endpoint of values only.** Each client would still turn the numbers into expressions and layers, the part where the clients differed.
- **Everything in the style's metadata**, which carried Fog first. The tile version would make the style per account: no shared cache, and a 100 KB re-fetch per upload.
- **The layers in the style, with the tile version as a query the client appends.** Every native client still needs the builder that replaces sources, and the style still couldn't be shared.
- **Selection by feature-state**, as the web drew it. MapLibre Native Android has no feature-state API; filters on id sets work on every renderer.
- **Keeping old builds working.** Two contract shapes in the server and the app for one release cycle, for a build the Update screen already replaces.

## Consequences

- **A change to how any layer HoldMyTrack draws looks is a server deploy**; installed apps take it on their next load of the layers document.
- **The overlays wait for an authenticated request** beside the style on a phone's first launch; later launches draw the kept document at once and revalidate it.
- **A layers change that breaks the contract is an Android release with a raised minimum build**, released and deployed back to back.
- **MapLibre Native can't add a layer from JSON**, so Android builds each from its type and sets properties by name. Every array in a layer is an expression, by contract, since that is how Native reads it.
- **Device-only drawing stays in the clients**: the live recording line, the editors' handles, badge bitmaps in the server's colors, tap tolerances and gestures.