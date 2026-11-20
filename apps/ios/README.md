# HoldMyTrack for iOS

`docs/VISION.md` §4.1 (Path 2): Swift, with HealthKit and Apple Watch as the on-device ingest path, inheriting the Path 2 sync contract the Android app settled. Rendering is MapLibre Native against the same style document the web client builds (`docs/ARCHITECTURE.md` §2.1). The app is a skeleton so far; the plan from here to the App Store is `docs/ROADMAP.md`.

Not containerised, and not planned to be: Xcode, the simulator and a physical device for HealthKit testing all live on the host.

- `docs/` — this app's `ARCHITECTURE.md`, `SPEC.md`, `IMPLEMENTATION.md` and `ROADMAP.md`: its shape and decisions, what it does, how it's built, and the plan.

## Build and run

Xcode 26 or later, as CI's macOS runner has; a simulator build needs no Apple Developer account. Open `HoldMyTrack.xcodeproj`, pick the HoldMyTrack scheme and an iPhone simulator, and run. From a terminal:

```
xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack -destination 'platform=iOS Simulator,name=iPhone 17'
```

The code with no UIKit in it is the `HoldMyTrackCore` package, and its tests need no simulator: `swift test` in `HoldMyTrackCore/`.

A Debug build talks to `http://localhost:8080`, compose's API port on this Mac, which the simulator reaches directly. When `.env` sets another `API_PORT`, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set it there. Release always talks to `https://holdmytrack.com`. A Debug build's You tab shows the build and whether the API answers.

The UI tests run against the dev stack at the same origin and skip when it doesn't answer, as on CI. The map's basemap comes from the web's dev server, so `web` must be running. The recording tests need a simulated location still moving: `xcrun simctl location booted start --speed=5 41.48,-81.70 41.49,-81.68 41.48,-81.66 41.49,-81.64`. The dev stack allows 5 demo sign-ins an hour from one address, so a full run fails its later demo tests with "Too many demo sessions"; run them again after the hour.

Signing for a device or an archive needs a team: copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`.

After changing `tokens.css`, or the Android app's icons, fonts or licenses, run `scripts/make-design.py`; never edit the asset catalog's Palette or Icons folders. Add every string the app shows to `HoldMyTrack/Localizable.xcstrings` with its Russian, writing a count as "label: N" as Android does; Xcode's editor adds a new string itself, a command-line build fails until it's there. Why each of these works the way it does is `apps/ios/docs/IMPLEMENTATION.md` §6.