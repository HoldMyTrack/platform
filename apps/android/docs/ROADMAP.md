# HoldMyTrack for Android — Roadmap

The Android app's open work: testing and releasing it on Google Play. The product's is root `docs/ROADMAP.md`.

## Ongoing

- [ ] **Testing tracks, then production**
  - 0.18 is in production outside the EU, linked from About and Help. The closed test stays open for testers in other countries.
  - Recheck the release requirements against Play Console Help before each submission.
- [ ] **Sign in with Apple, for accounts made on an iPhone**
  - An account made with Sign in with Apple has no password, often a Hide My Email address, and no way into the Android app. Run the server's Apple flow in a Custom Tab with the app's challenge and redeem the handoff code, as Facebook does (root `docs/IMPLEMENTATION.md` §4.9); no Apple SDK. Declare `app_challenge` on `/v1/auth/apple/start` in `services/server/api/`, which the server already accepts.
  - Apple accepts only an `https://` return URL on the registered domain, so it is tested against production.
  - Done when: an account made on iOS with Hide My Email signs in on Android.
- [ ] **No donation link in the web pages the app opens, once donations open**
  - The app has no Donate of its own: Play's Payments policy lets an app point to payment only through Google Play's billing. Setting `OpenCollectiveSlug` (`services/server/internal/web/web.go`) would still bring links in through pages: About is shown inside the app, and root `ROADMAP.md` turns its funding line into a link; Help, Contacts and Privacy open in a browser tab with the site's header, whose Donate goes to Open Collective. Leave the funding link and the header's Donate out of pages for the `hmt_app` cookie, and decide whether the browser-tab pages need the same. StreetComplete's Play submission was rejected for such a link; recheck before each submission.