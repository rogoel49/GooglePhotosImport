# CLAUDE.md — Google Photos Importer (iOS)

## Project
Native iOS Swift app that lets the user pick photos from a Google Photos shared
album (via Google's Photos Picker API) and save them into the iOS Photos app.
Personal use only — sideloaded via Xcode, not App Store bound. See
PROJECT_SPEC.md for the full background and scope.

## Hard constraints — read before writing any sync logic
- Google's Photos Library API no longer supports listing/joining shared albums or
  reading arbitrary library content. Only the **Picker API** exposes
  user-selected items, and it requires the user to open Google's picker UI and
  confirm a selection each time. Do NOT design around a background poller for new
  shared-album items — there is no API for that as of this writing. If you think
  you've found a way to do it headlessly, stop and double check against current
  Google Photos API docs before building on it.
- Use the `photospicker.mediaitems.readonly` scope only — least privilege.
- Downloaded bytes come from the Picker API session results (`mediaItems.baseUrl`
  + size params), not the old Library API `mediaItems.get`.

## Tech stack
- Swift, SwiftUI
- `PhotosUI` / `PHPhotoLibrary` for writing into the Photos app
- `GoogleSignIn-iOS` (or `AppAuth-iOS`) for OAuth
- Lightweight local persistence (`UserDefaults` or a small SQLite/JSON file) for
  the imported-media-ID dedup set — no backend needed

## Suggested structure
- `GooglePhotosAuth.swift` — OAuth sign-in
- `PickerSessionManager.swift` — create/poll picker sessions
- `PhotoImporter.swift` — download + `PHPhotoLibrary` save + dedup
- `ImportView.swift` — SwiftUI screen: sign in, "Import from [album]" button, progress

## Setup required before coding
1. Google Cloud project → OAuth client (iOS type) → enable Photos Picker API →
   keep app in "Testing" publish status with your Google account added as a test
   user.
2. Xcode project signed with a free Apple ID (re-sign every 7 days) or a paid
   $99/yr developer account (sideload lasts a year).

## Workflow split: cloud session vs. Xcode laptop
This project is developed across two environments — plan the work accordingly:

- **This session (Claude Code on the web / cloud sandbox):** Linux container, no
  Xcode, no Simulator, no ability to build or run the iOS app. Use it to write and
  iterate on Swift source files, structure the repo, draft the OAuth/Picker/
  PHPhotoLibrary logic, write docs, and commit/push to GitHub. Don't attempt to
  run `xcodebuild`, open a Simulator, or verify the app actually builds here — it
  can't.
- **Xcode laptop (separate machine, pulled from this repo):** where the project
  actually gets opened, built, signed, run on-device, and debugged. A local
  Claude Code session there can drive `xcodebuild`/signing/CLI tasks once the repo
  is pulled.
- **Project file format:** use **XcodeGen** (a `project.yml` describing targets,
  sources, and settings) instead of hand-maintaining a raw `.xcodeproj`. A
  `.xcodeproj` is a fragile, semi-binary format that's easy for a text-editing
  agent to corrupt; `project.yml` is plain text the cloud session can safely edit,
  and running `xcodegen generate` on the Xcode laptop regenerates the real Xcode
  project from it. Commit `project.yml` and all source files; the generated
  `.xcodeproj` itself can be gitignored and regenerated locally.

## Conventions
- Keep networking/auth code isolated from SwiftUI views.
- Fail loud in the UI on a failed download/save (alert or inline error) rather
  than silently skipping — log skipped items so nothing quietly disappears.
- On every import run, cross-check newly picked items against the local dedup
  store before writing to Photos, to avoid duplicate camera-roll entries.

## Explicitly not building (see PROJECT_SPEC.md)
- Background/automatic sync
- Multi-user or server backend
- Android version
