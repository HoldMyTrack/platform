# HoldMyTrack for iOS: Spec

| | |
| :-- | :-- |
| **Status** | Current: the app as built |
| **Last updated** | 2026-11-25 |
| **Related documents** | `docs/SPEC.md` (the server and web behavior this app shares), `apps/ios/docs/ARCHITECTURE.md` (the app's shape and stack), `apps/ios/docs/IMPLEMENTATION.md` (how it's built), `apps/ios/docs/ROADMAP.md` (the plan) |

## 1. Introduction

### 1.1 Purpose

What the iOS app does, as a user can rely on it: where it differs from the Android app (`apps/android/docs/SPEC.md`) and the web, and what only it does. What it shares with the web is in `docs/SPEC.md`, cited by FR. Screen wording and layout live in the code. Its sections take the Android spec's numbers, so a requirement and its Android counterpart share one.

### 1.2 Scope

Every built feature of the app: so far signing in and out, email verification, the first run, the Update screen, the map and its Tracks and Trips panel, Library, the site's pages, the You tab, Privacy, deleting the account, and Upload.

## 3. FR-1 — Authentication & Session

As the Android app's (`apps/android/docs/SPEC.md` FR-1.1–FR-1.8), except as below.

### FR-1.1 Sign in, sign up, start a demo

- Google and Facebook both run the server's own flow in the system's browser sheet, started with the S256 hash of a verifier the app keeps; the code returned to `holdmytrack://oauth` is redeemed with it at `POST /v2/auth/handoff`. Sign-up opens the web's page in the same sheet and ends the same way. No Google or Meta SDK is in the app.
- Sign in with Apple shows when the server reports it, in Apple's own sheet (`docs/SPEC.md` FR-1.11). The name Apple shares on the first sign-in names a new account.

### FR-1.2 Session persistence and re-verification

- The token is kept in the Keychain, on this iPhone only. A reinstall starts signed out, though the Keychain outlives an uninstall.
- The map's unreachable notice offers Sign out beside Try again, since the tab bar waits for the check.

### FR-1.5 Settings

- Avatar: the page's file input, which iOS answers with its own photo picker, camera or Files.
- Language is the app's page in the system's Settings (`ARCHITECTURE.md` §1, D11); the page's Language sets only the account's.

### FR-1.7 Privacy

- Download your data hands each ready part to the share sheet, whose Save to Files keeps it, in place of Android's Downloads.

### FR-1.8 Update screen

- It stays over every screen for the rest of the run; iOS has no Back to close the app.
- Until the app has an App Store listing it has no Update button.

## 4. FR-2 — Map Visualization

As the Android app's (`apps/android/docs/SPEC.md` FR-2.1–FR-2.12), except as below.

### FR-2.6 Dates

- Each end of Dates is picked in a calendar in a sheet, and applies at once.

### FR-2.7 Tracks panel

- Leaving the Tracks tab drops the Private location editor's draft: iOS has no Back.
- Download hands the file to the share sheet, whose Save to Files keeps it.

### FR-2.8 Spots

- With only approximate location allowed, Capture asks through iOS's one-time prompt for precise location; refused, nothing starts.

### FR-2.9 The bottom bar

- Tracks, Trips, the record button, Library (FR-4.1) and You. Sync's sheet, opened from Library's head, lists the recordings on the phone (FR-5.2), with Upload (FR-3.6) at its head; ‹ or a tap on Library goes back to Library.
- You's Language opens the app's page in the system's Settings (`ARCHITECTURE.md` §1, D11).

### FR-2.10 Photos

- Added photos come from iOS's photo picker, which hands over a photo's location with its time, unlike Android's, so the placement check can place a photo by where it was taken (`docs/SPEC.md` FR-15.1).

### FR-2.11 Map image export

- The image is saved to Photos, which the app may only add to, and offered to the share sheet; with Photos refused, only to the share sheet.
- A basemap or Satellite with a tile that can't be reached is left out of the image whole, and out of its credit, where Android leaves out only the tiles it couldn't load.

## 5. FR-3 — Sync and Imports

### FR-3.4 Imports that failed

- The alert for imports that failed on the server's side is the Android app's (`apps/android/docs/SPEC.md` FR-3.4), checked whenever the app comes to the front on any tab and when a sent recording fails.

### FR-3.6 Upload

As the Android app's (`apps/android/docs/SPEC.md` FR-3.6), except as below.

- Files come from the document picker, or are opened in HoldMyTrack from Files or another app's share sheet.
- Files go on even after the app is left, sent by iOS one at a time. Imports still running show on the Upload sheet.

## 6. FR-4 — Library

### FR-4.1 Library

As the Android app's (`apps/android/docs/SPEC.md` FR-4.1), except as below.

- Download hands the file to the share sheet, whose Save to Files keeps it.
- Library's sheet stays while recording, so Sync can be reached mid-walk.

## 7. FR-5 — In-App GPS Recording

### FR-5.1 Record — one button on the map

As the Android app's (`apps/android/docs/SPEC.md` FR-5.1), except as below.

- Location is used while the app is in use, with iOS's location indicator showing while it records in the background. VoiceOver stops it with the record button's Stop action.
- A Live Activity on the Lock Screen and in the Dynamic Island takes the place of Android's notification: the clock and distance, Pause or Resume, and Stop, which opens the app to ask first.
- iOS has no GPS-only positions: a fix vaguer than 50 m is left out.
- Swiping HoldMyTrack away in the app switcher stops the recording, which the first recording on the phone says once. Crash recovery keeps it to the last fix as on Android, and a notification posted as the app closes resumes it with a tap, with no prompt.
- A pause turns location off until Resume. Location or precise location taken away while recording pauses it.

### FR-5.2 Recorded tracks — review, edit, send

As the Android app's (`apps/android/docs/SPEC.md` FR-5.2), except as below.

- Download GPX goes to the share sheet, which saves to Files among its choices.

## 8. Non-Functional Requirements (summary)

| Concern | Behavior |
| :-- | :-- |
| **Devices** | iPhone, on iOS 17 and later; an iPad runs it in compatibility mode. |
| **Language** | English or Russian, iOS's choice from the phone's languages and the app's own setting in Settings, else English; sent as `Accept-Language` (`docs/SPEC.md` FR-12.1). |
| **Version gate** | Every request names the build in its User-Agent, so the server can turn away an old one (`docs/SPEC.md` §1.4). |