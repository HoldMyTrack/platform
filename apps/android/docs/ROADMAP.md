# HoldMyTrack for Android — Roadmap

The Android app's open work: testing and releasing it on Google Play. The product's is root `docs/ROADMAP.md`.

## Ongoing

- [ ] **Testing tracks, then production**
  - The closed test ran with testers recruited through Testers Community, pointed at `https://holdmytrack.com/testing`, the step-by-step test suite with its sample files (root `docs/SPEC.md` FR-10.7). Production access was applied for on 2026-10-24; Google answers the account owner by email, usually within 7 days. Then release in stages, after root `ROADMAP.md`'s "Before launch", since a production release is a public launch.
  - Recheck the release requirements against Play Console Help before each submission.
- [ ] **The Digital Services Act trader-status declaration**, which the Play Console account needs before the app can be distributed in the EU.
- [ ] **No payment link reachable from the Play build, once donations open**
  - Play's Payments policy lets an app point to payment only through Google Play's billing, so the app has no Donate. Help, Contacts and Privacy open the web's pages in a browser tab, whose header's Donate goes to Open Collective once `OpenCollectiveSlug` (`services/server/internal/web/web.go`) is set, and About's funding section would link there too. StreetComplete's Play submission was rejected for such a link; recheck before each submission once donations open.
- [ ] **`WebPageActivity.route` under test**
  - It takes an Android `Uri`, so it has no unit test, though the first-run redirect bug lived in it. Move the decision into a function over plain values and test it (`AGENTS.md`, "Code and tests").