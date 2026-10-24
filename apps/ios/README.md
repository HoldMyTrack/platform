# HoldMyTrack for iOS

`docs/VISION.md` §4.1 (Path 2): Swift, with HealthKit and Apple Watch as the on-device ingest path, inheriting the Path 2 sync contract the Android app settled. Rendering is MapLibre Native against the same style document the web client builds (`docs/ARCHITECTURE.md` §2.1). The plan from the first commit to the App Store is `docs/ROADMAP.md`; the app is a skeleton so far.

Not containerised, and not planned to be: Xcode, the simulator and a physical device for HealthKit testing all live on the host.

## Build and run

Xcode 26 or later, as CI's macOS runner has; a simulator build needs no Apple Developer account. Open `HoldMyTrack.xcodeproj`, pick the HoldMyTrack scheme and an iPhone simulator, and run. From a terminal:

```
xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack -destination 'platform=iOS Simulator,name=iPhone 17'
```

A Debug build talks to `http://localhost:8080`, compose's API port on this Mac, which the simulator reaches directly. When `.env` sets another `API_PORT`, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set it there. Release always talks to `https://holdmytrack.com`. The first screen shows the build and whether the API answers.

Signing for a device or an archive needs a team: copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig`.

The palette and scales come from the web's `tokens.css`, and the fonts and icons from the Android app's resources: `scripts/make-design.py` writes them into the project, and CI fails when they're out of date. Edit the source, never the asset catalog's Palette or Icons folders, then run the script.

Every string the app shows comes from `HoldMyTrack/Localizable.xcstrings`, in English and Russian. A build fails on a string the code uses that the catalog lacks, one without its Russian, or a Russian whose placeholders differ (`scripts/check-strings.py`): Xcode's editor adds a new string to the catalog when it builds, a command-line build doesn't. As on Android, Russian writes a count as "label: N" rather than declining the word. The app's language is iOS's choice from the phone's languages and the app's own setting in Settings, and requests send it as `Accept-Language`.

The build number is the commit count and the short commit is baked in, as on Android (`scripts/stamp-build.sh`). MapLibre comes through Swift Package Manager at an exact version, pinned in the project.