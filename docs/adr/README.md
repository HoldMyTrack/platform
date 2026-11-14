# Architecture Decision Records

Each ADR here captures one consequential, hard-to-reverse decision on its own — the alternatives that were considered, why they were rejected, and what the decision costs as well as what it buys. This is a different job from the other docs in `docs/`:

- **`docs/ARCHITECTURE.md`** is the current-state reference — what the system looks like today, in one place, kept current as things change.
- **These ADRs** record *why* each decision in force went the way it did. When a decision changes, its ADR is edited to match; when one is reversed, its ADR is deleted.

Only a decision that is hard to reverse gets an ADR: one that would lose data that can't be recovered, break a promise users rely on, need stored data or account links migrated, break apps already installed, or mean a large rewrite. Any other choice, with its reasoning, is documented in the section that owns that piece (`IMPLEMENTATION.md`, `SPEC.md`, `VISION.md`, `DEPLOY.md`, `apps/android/docs/`). The numbering has gaps, and a deleted ADR's number is not reused.

Numbered in rough order of how foundational the decision is, not strictly chronological.

| ADR | Decision |
| :-- | :-- |
| [0002](0002-privacy-applied-at-ingest.md) | Privacy is applied at ingest, never at render |
| [0003](0003-precomputed-raster-fog-pyramid.md) | Precomputed raster fog pyramid, not per-request geometry union or H3 |
| [0009](0009-external-sign-in.md) | Google, Facebook and Apple sign-in run server-side with no library, and link by email only when the provider vouches for it |
| [0012](0012-server-rendered-pages-react-for-the-map.md) | Every page is server-rendered HTML sharing one header; React is kept for the map page |
| [0017](0017-no-health-data.md) | No health data: heart rate is never read, stored or shown |
| [0024](0024-activity-photos-resized-and-route-bound.md) | An activity can carry the user's photos, kept as resized copies on our own storage, each placed on the route by the time it was taken |
| [0036](0036-send-a-copy-of-a-story.md) | A Story can be sent as a copy to another account, which accepts it into a Story and activities of its own; nothing syncs afterwards |
| [0039](0039-the-app-is-the-gate.md) | The app is the gate: every source brings in only what the user ticks, and nothing is guessed on their behalf |
| [0042](0042-mobile-apps-show-the-sites-pages.md) | The mobile apps are native where the platform is the point, and show the site's own pages for the rest |
| [0043](0043-per-account-limits.md) | Every account can keep up to 50,000 activities and 5 GB of original files, the same limits for all |
| [0048](0048-two-map-documents.md) | The server shapes the map as two documents, a shared basemap style and the account's layers, which native maps apply |
| [0049](0049-shared-rules-written-natively.md) | Rules every client applies are written natively in each, and defined once by shared test cases |

## Writing a new one

Copy the shape of an existing ADR: Status, Context, Decision, Alternatives considered, Consequences (including the honest costs, not just the benefits). Number it one past the current highest. Link it from the table above in the same change.