# HoldMyTrack for iOS: Spec

| | |
| :-- | :-- |
| **Status** | Current: the app as built, a skeleton so far |
| **Last updated** | 2026-10-24 |
| **Related documents** | `docs/SPEC.md` (the server and web behavior this app shares), `apps/ios/docs/ARCHITECTURE.md` (the app's shape and stack), `apps/ios/docs/IMPLEMENTATION.md` (how it's built), `apps/ios/docs/ROADMAP.md` (the plan) |

## 1. Introduction

### 1.1 Purpose

What the iOS app does, as a user can rely on it: where it differs from the Android app (`apps/android/docs/SPEC.md`) and the web, and what only it does. What it shares with the web is in `docs/SPEC.md`, cited by FR. Screen wording and layout live in the code. Its sections take the Android spec's numbers, so a requirement and its Android counterpart share one.

### 1.2 Scope

Every built feature of the app. None a user relies on is built yet: the app opens on a screen showing its build and whether the API answers, which the sign-in screen replaces (`ROADMAP.md`, phase 5).

## 8. Non-Functional Requirements (summary)

| Concern | Behavior |
| :-- | :-- |
| **Devices** | iPhone, on iOS 17 and later; an iPad runs it in compatibility mode. |
| **Language** | English or Russian, iOS's choice from the phone's languages and the app's own setting in Settings, else English; sent as `Accept-Language` (`docs/SPEC.md` FR-13.1). |
| **Version gate** | Every request names the build in its User-Agent, so the server can turn away an old one (`docs/SPEC.md` §1.5). |