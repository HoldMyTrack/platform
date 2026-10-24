# HoldMyTrack for iOS: Architecture

> **Scope note.** The app's shape, the decisions that set it and its stack. Where it sits among the system's parts is root `docs/ARCHITECTURE.md` §1.2; what is left to build is `ROADMAP.md`.

The iOS app is to be Path 2 for HealthKit (ADR-0001), a map viewer on the same accounts and documents as the web, and GPS recording that submits straight to the server (ADR-0007), as the Android app is. Native where the platform is the point, and the site's own pages in a `WKWebView` for the rest (ADR-0042). So far it is one Xcode project with the app, its visual language and both languages, and the `HoldMyTrackCore` package for what needs no UIKit; a first screen that shows the build and whether the API answers.

## 1. Key decisions

Settled by the owner on 2026-10-24; the plan's steps cite them by number. A change is made here first.

| # | Decision | Reason |
| :-- | :-- | :-- |
| D1 | UIKit for the shell and the map, a `UITabBarController`; SwiftUI allowed for leaf screens in a `UIHostingController` | The map's camera and layers survive a tab switch, as Android's tabs do. MapLibre's map is a UIKit view, which SwiftUI would host through a representable with its lifecycle forwarded by hand |
| D2 | iOS 17 and later | Interactive Live Activities, `CLBackgroundActivitySession` for recording, `@Observable` and the String Catalog tooling |
| D3 | iPhone only | An iPad runs it in compatibility mode, so no iPad layouts or screenshots |
| D4 | One Xcode project with folder-synchronized groups and Swift Package Manager; no CocoaPods, XcodeGen or Tuist | A file in a target's folder joins the target with no project-file edit, which keeps merges clean without a generator to install |
| D5 | Bundle ID `dev.holdmytrack.ios` | Beside Android's `dev.holdmytrack.android`; it can't change once registered |
| D6 | The same developer-account holder as the Play account, unless a legal entity exists by then | The App Store shows the account's name as the seller |
| D7 | Email and password, Sign in with Apple, and Google and Facebook through the server's own flow in `ASWebAuthenticationSession` | As Android does Facebook: no Google or Meta SDK, and no change to Google's token audience |
| D8 | Session token in the Keychain; recordings and the last HealthKit read in SQLite through the system `sqlite3`, no ORM; small settings in `UserDefaults` | As Android's stores (`apps/android/docs/ARCHITECTURE.md` §1), with the Keychain because it is the platform's place for a credential |
| D9 | The build number is `git rev-list --count` | As Android's `versionCode`, so one tag scheme and one contract check serve both |
| D10 | No watch app | A watch's workouts reach the phone's HealthKit and are read there |
| D11 | The app's language is set in the system's Settings; the You tab's Language opens it | iOS has no in-app language switch. The account's language follows the app's on each session check unless set to automatic |
| D12 | Crash reports from Xcode Organizer only | From users who share analytics with developers; no third-party SDK |

## 2. Stack

* **Build**: Xcode 26 or later, as CI's macOS runner has, Swift 6. On the host, not in a container: Xcode, the simulator and the device HealthKit testing needs live there (`apps/ios/README.md`).
* **Map**: MapLibre Native iOS 6.31.0 through Swift Package Manager at that exact version, which reads `pmtiles://` (since 6.10.0), so the served style (root `docs/ARCHITECTURE.md` §2.1) is consumed unmodified.
* **UI**: UIKit, with the web's palette, scales and typefaces (Inter, Fraunces, Source Serif 4) and Android's Lucide icons, written into the project by `scripts/make-design.py`.
* **Network**: `URLSession`, with no client library.