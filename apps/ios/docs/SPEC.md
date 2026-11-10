# HoldMyTrack for iOS: Spec

| | |
| :-- | :-- |
| **Status** | Current: the app as built |
| **Last updated** | 2026-11-08 |
| **Related documents** | `docs/SPEC.md` (the server and web behavior this app shares), `apps/ios/docs/ARCHITECTURE.md` (the app's shape and stack), `apps/ios/docs/IMPLEMENTATION.md` (how it's built), `apps/ios/docs/ROADMAP.md` (the plan) |

## 1. Introduction

### 1.1 Purpose

What the iOS app does, as a user can rely on it: where it differs from the Android app (`apps/android/docs/SPEC.md`) and the web, and what only it does. What it shares with the web is in `docs/SPEC.md`, cited by FR. Screen wording and layout live in the code. Its sections take the Android spec's numbers, so a requirement and its Android counterpart share one.

### 1.2 Scope

Every built feature of the app: so far signing in and out, email verification, the first run, the Update screen, the map and its Activities and Stories panel, the site's pages, the You tab, Privacy, deleting the account, and Upload.

## 3. FR-1 — Authentication & Session

As the Android app's (`apps/android/docs/SPEC.md` FR-1.1–FR-1.8), except as below.

### FR-1.1 Sign in, sign up, start a demo

- Google and Facebook both run the server's own flow in the system's browser sheet, started with the S256 hash of a verifier the app keeps; the code returned to `holdmytrack://oauth` is redeemed with it at `POST /v1/auth/handoff`. No Google or Meta SDK is in the app.
- Sign in with Apple shows when the server reports it, in Apple's own sheet (`docs/SPEC.md` FR-1.14). The name Apple shares on the first sign-in names a new account.

### FR-1.2 Session persistence and re-verification

- The token is kept in the Keychain, on this iPhone only. A reinstall starts signed out, though the Keychain outlives an uninstall.
- A failed check shows why, with Try again and Sign out; returning to the app checks again.

### FR-1.5 Settings

- Avatar: the page's file input, which iOS answers with its own photo picker, camera or Files.
- Language is the app's page in the system's Settings (`ARCHITECTURE.md` §1, D11); the page's Language sets only the account's.

### FR-1.7 Privacy

- A new Private location is centred where the map last looked, with its radius typed in, until the map has an editor (`ROADMAP.md`, 7b.2); a row renames it or changes its radius.
- Download your data hands each ready part to the share sheet, whose Save to Files keeps it, in place of Android's Downloads.

### FR-1.8 Update screen

- It stays over every screen for the rest of the run; iOS has no Back to close the app.
- Until the app has an App Store listing it has no Update button.

## 4. FR-2 — Map Visualization

As the Android app's (`apps/android/docs/SPEC.md` FR-2.1–FR-2.10), except as below.

### FR-2.2 Three map modes: Normal, Fog of War, Heatmap

- Stories is Normal mode's, as on Android; the Sync tab is a page with no map.
- There is no recording to hide the modes.

### FR-2.3 Initial camera framing

- An account with nothing on the map stays on the world view, never its Country's, and is pointed to Upload on the You tab.

### FR-2.6 Dates

- Each end of Dates is picked in a calendar in a sheet, and applies at once.

### FR-2.7 Activities panel

- No Private location editor yet (`ROADMAP.md`, 7b.2).
- While any listed activity is Pending, a notice over the map says so.

### FR-2.8 Spots

- With only approximate location allowed, Capture asks through iOS's one-time prompt for precise location; refused, nothing starts.
- Leaving the Map tab ends a capture: iOS has no Back.

### FR-2.9 The bottom bar

- Map, Stories, Sync and You, with no record button yet. Sync is Sync history (FR-4.1).
- You leads to Settings, Activity graph & trends, Upload, Privacy, Theme, Language, About, Help and Contacts, Delete account and Sign out. Language opens the app's page in the system's Settings (`ARCHITECTURE.md` §1, D11). There is no Settings › Sync until HealthKit sync (`ROADMAP.md`, 7c).
- Delete account, for a real account, is confirmed by typing the email. On success the phone forgets what it kept for that account and signs out.

### FR-2.10 Photos

- Added photos come from iOS's photo picker, which hands over a photo's location with its time, unlike Android's, so the placement check can place a photo by where it was taken (`docs/SPEC.md` FR-16.1).

## 5. FR-3 — Sync and Imports

### FR-3.6 Upload

As the Android app's (`apps/android/docs/SPEC.md` FR-3.6), except as below.

- Files come from the document picker, or are opened in HoldMyTrack from Files or another app's share sheet.
- Files go on even after the app is left, sent by iOS one at a time. Imports still running show on the Upload screen.

## 8. Non-Functional Requirements (summary)

| Concern | Behavior |
| :-- | :-- |
| **Devices** | iPhone, on iOS 17 and later; an iPad runs it in compatibility mode. |
| **Language** | English or Russian, iOS's choice from the phone's languages and the app's own setting in Settings, else English; sent as `Accept-Language` (`docs/SPEC.md` FR-13.1). |
| **Version gate** | Every request names the build in its User-Agent, so the server can turn away an old one (`docs/SPEC.md` §1.5). |