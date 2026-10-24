# HoldMyTrack for Android — Roadmap

The Android app's open work: testing and releasing it on Google Play. The product's is root `docs/ROADMAP.md`.

## Ongoing

- [ ] **Testing tracks, then production**
  - The closed test ran with testers recruited through Testers Community, pointed at `https://holdmytrack.com/testing`, the step-by-step test suite with its sample files (root `docs/SPEC.md` FR-10.7). Production access was applied for on 2026-10-24; Google answers the account owner by email, usually within 7 days. Then release in stages, after root `ROADMAP.md`'s "Before launch", since a production release is a public launch.
  - Recheck the release requirements against Play Console Help before each submission.
- [ ] **The Digital Services Act trader-status declaration**, which the Play Console account needs before the app can be distributed in the EU.
- [ ] **No donation link in the web pages the app opens, once donations open**
  - The app has no Donate of its own: Play's Payments policy lets an app point to payment only through Google Play's billing. Setting `OpenCollectiveSlug` (`services/server/internal/web/web.go`) would still bring links in through pages: About is shown inside the app, and root `ROADMAP.md` turns its funding line into a link; Help, Contacts and Privacy open in a browser tab with the site's header, whose Donate goes to Open Collective. Leave the funding link and the header's Donate out of pages for the `hmt_app` cookie, and decide whether the browser-tab pages need the same. StreetComplete's Play submission was rejected for such a link; recheck before each submission.
- [ ] **`WebPageActivity.route` under test**
  - It takes an Android `Uri`, so it has no unit test, though the first-run redirect bug lived in it. Move the decision into a function over plain values and test it (`AGENTS.md`, "Code and tests").