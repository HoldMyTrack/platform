# HoldMyTrack for Android: Architecture

> **Scope note.** The app's shape, the decisions that set it, its stack and what is deferred. Where it sits among the system's parts is root `docs/ARCHITECTURE.md` §1.2.

The Android app is Path 2 (ADR-0001), reading Health Connect in the foreground; a map viewer on the same accounts and style document as the web; and GPS recording that submits straight to the server (ADR-0007). It is one Gradle module on the platform SDK: Views styled with Material 3 and hand-built `OkHttp` calls, with no Compose, Retrofit, ORM or dependency-injection library. A handful of screens and endpoints don't amortize a framework. How it is built is `IMPLEMENTATION.md`, what it does `SPEC.md`.

**Sync and display are separate one-way pipes.** The sync engine reads Health Connect and posts to `POST /v1/sync/activities`; the map draws the account from the server's tiles. The only lines drawn from the phone's own data are the Sync tab's candidates and a recording in progress, and once synced an activity carries no trace of its source. The phone holds two things the server lacks: unsynced recordings, deleted once their activity lands, and what the last Health Connect read found.

## 1. Key decisions

| Decision | Reason |
| :--- | :--- |
| Material 3 on Views, not Compose, without dynamic color | Compose would rewrite every screen and host the `MapView` through `AndroidView` with its lifecycle forwarded by hand. Material supplies the color and type roles the web's tokens map onto, 48 dp targets and TalkBack support. Dynamic color would replace the brand palette with the wallpaper's |
| Main screens are tabs of one Activity | Tabs are shown and hidden, so the map's camera and layers survive a trip to another tab; an Activity per tab makes every switch a window change and splits the bar's state across windows |
| Bearer token, not a cookie jar | MapLibre Native's tile fetcher never sees a cookie jar; one interceptor on the `OkHttpClient` the app shares with MapLibre reaches both |
| The web's Settings, Activity graph, Sync history and About in a WebView | ADR-0042; signed in by cookie, since WebView requests skip the app's client |
| Foreground-only Health Connect sync, no background job | A background read gets no routes whatever was granted (root `docs/IMPLEMENTATION.md` §4.0), so it would send activities with nothing to draw |
| Session token in plain `SharedPreferences` | The file is private to the app, and an attacker who can read it has everything else the app holds. Revocation bounds a leaked token: sign-out deletes the server's row |
| API calls use OkHttp's callbacks; only sync and upload calls suspend | Health Connect's API is `suspend` and each sync or upload request waits for the last; elsewhere a coroutine layer over OkHttp's async API buys nothing |
| `minSdk` 34 | Health Connect is part of the platform from Android 14; below it, it is a Play-installed app to detect and install, a second state machine never measured on a device |

## 2. Stack

* **Build**: Kotlin through AGP 9.4.1's built-in support (compiler 2.2), Gradle 9.8.2 through the wrapper, JDK 17 or 21, `compileSdk` and `targetSdk` 37. On the host, not in a container: the SDK, `adb` and the physical device Health Connect testing needs live there (`apps/android/README.md`).
* **Map**: MapLibre Native 13.7.1, which reads `pmtiles://` natively (since 11.8.0), so the served style (root `docs/ARCHITECTURE.md` §2.1) is consumed unmodified, archive URL included, with no client-side PMTiles reader. Fog arrives as veil polygons the server traced (root `docs/IMPLEMENTATION.md` §4.2), so this client has no shader either.
* **Network**: OkHttp 4.12.0, declared directly because the app hands its own client to MapLibre, and pinned to what MapLibre resolves. Bodies are `kotlinx.serialization` classes held to the API contract by a unit test.
* **Health data**: `androidx.health.connect:connect-client` 1.1.0, the version the device measurements ran against.
* **UI**: Material Components 1.13.0.
* **Local storage**: `SharedPreferences`, two SQLite databases (unsynced recordings with the live journal, and the last Health Connect read) and MapLibre's tile cache.

## 3. Deferred

| Component | Add it when |
| :--- | :--- |
| Compose | The app outgrows a handful of screens; Views/Compose interop allows moving one screen at a time |
| An encrypted token store | A threat beyond access to the device's private storage is identified |
| Instrumentation tests | Manual device checks stop being enough; JUnit covers the pure logic (`docs/DEVELOPMENT.md`) |