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

Every built feature of the app: so far signing in and out, email verification and the Update screen. Signed in, it shows the account, the build and whether the API answers, which the map replaces (`ROADMAP.md`, phase 7a).

## 3. FR-1 — Authentication & Session

As the Android app's (`apps/android/docs/SPEC.md` FR-1.1–FR-1.4, FR-1.8), except as below.

### FR-1.1 Sign in, sign up, start a demo

- Google and Facebook both run the server's own flow in the system's browser sheet, started with the S256 hash of a verifier the app keeps; the code returned to `holdmytrack://oauth` is redeemed with it at `POST /v1/auth/handoff`. No Google or Meta SDK is in the app.
- Sign in with Apple isn't offered yet (`ROADMAP.md`, 5.2).

### FR-1.2 Session persistence and re-verification

- The token is kept in the Keychain, on this iPhone only. A reinstall starts signed out, though the Keychain outlives an uninstall.
- A failed check shows why, with Try again and Sign out; returning to the app checks again.

### FR-1.8 Update screen

- It stays over every screen for the rest of the run; iOS has no Back to close the app.
- Until the app has an App Store listing it has no Update button.

## 8. Non-Functional Requirements (summary)

| Concern | Behavior |
| :-- | :-- |
| **Devices** | iPhone, on iOS 17 and later; an iPad runs it in compatibility mode. |
| **Language** | English or Russian, iOS's choice from the phone's languages and the app's own setting in Settings, else English; sent as `Accept-Language` (`docs/SPEC.md` FR-13.1). |
| **Version gate** | Every request names the build in its User-Agent, so the server can turn away an old one (`docs/SPEC.md` §1.5). |