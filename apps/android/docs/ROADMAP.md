# HoldMyTrack for Android — Roadmap

The Android app's open work: testing and releasing it on Google Play. The product's is root `docs/ROADMAP.md`.

## Ongoing

- [ ] **Testing tracks, then production**
  - Production access was granted on 2026-10-25 and 0.18 sent to production review, in the US, Canada, Australia, New Zealand and Ukraine, unpromoted until root `ROADMAP.md`'s "Before launch" is done. The closed test stays open for testers in other countries.
  - Recheck the release requirements against Play Console Help before each submission.
- [ ] **The tour** (`docs/SPEC.md` FR-4.18) on the native map, with the web's steps and cards; move its start and card rules (`apps/web/src/ui/tour/tourRules.ts`) into `testdata/client-rules/` first (ADR-0049).
- [ ] **The Digital Services Act trader-status declaration**, which the Play Console account needs before the app can be distributed in the EU.
- [ ] **No donation link in the web pages the app opens, once donations open**
  - The app has no Donate of its own: Play's Payments policy lets an app point to payment only through Google Play's billing. Setting `OpenCollectiveSlug` (`services/server/internal/web/web.go`) would still bring links in through pages: About is shown inside the app, and root `ROADMAP.md` turns its funding line into a link; Help, Contacts and Privacy open in a browser tab with the site's header, whose Donate goes to Open Collective. Leave the funding link and the header's Donate out of pages for the `hmt_app` cookie, and decide whether the browser-tab pages need the same. StreetComplete's Play submission was rejected for such a link; recheck before each submission.