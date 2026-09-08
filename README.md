# GooglePhotosImport

People share photos via Google Photos shared albums and links. As an iPhone
user, saving those into the native Photos app is tedious. This is a free,
self-built alternative for personal use.

It's a small native iOS app (Swift / SwiftUI) that lets you pick photos and videos
from a Google Photos shared album and save them straight into the iOS Photos
app, in one batch, into a dedicated "Imported from Google Photos" album.
Personal use only: it's sideloaded onto your own iPhone from Xcode, not an App
Store app.

**Status: scaffold.** The source is complete and organized, but it has never
been compiled or run. It was written in a Linux cloud session with no Xcode,
so the first `xcodegen generate` + build on a Mac will almost certainly surface
a few compiler nits. See "Where the real work still is" at the bottom.

## What it does (and deliberately doesn't)

Google locked down the Photos Library API in March 2025. The only sanctioned
way to read existing library or shared-album content is the interactive
**Photos Picker API**: the user opens Google's picker UI, selects items, and
confirms. There is no API for silently watching a shared album for new items.
Full background sync therefore is **not possible** and is not attempted here
(see `PROJECT_SPEC.md` and the "Hard constraints" section of `CLAUDE.md`).

What the app does instead:

1. Sign in with Google, requesting only the
   `photospicker.mediaitems.readonly` scope.
2. Tap **Import from \<album\>**. The app creates a Picker session and opens
   Google's picker. You navigate to the shared album and multi-select whatever
   is new.
3. Back in the app, it polls the session until your selection is confirmed,
   lists the selected items, and skips any it has imported before (a local
   ledger of media-item IDs).
4. It downloads each remaining item at full resolution and saves it into the
   "Imported from Google Photos" album via PhotoKit, showing "12 of 40 saved".
5. Every failed item is listed on screen and logged. Nothing is skipped
   silently.

## Requirements

- A Mac with **Xcode 15 or newer**. There is no way around this for an iOS
  app that writes to Photos. Nothing in this project can be built, run or
  simulated anywhere else.
- **XcodeGen** (`brew install xcodegen`). The Xcode project file is generated
  from `project.yml` and is gitignored; never hand-edit a `.xcodeproj`.
- An iPhone running **iOS 17 or newer**, plus an Apple ID for signing.
  A free Apple ID works but the install expires every 7 days. A paid
  developer account ($99/yr) keeps a sideload alive for a year.
- A Google account and a free Google Cloud project (next section).

## Google Cloud setup (do this once, before the first run)

1. **Create a project** at <https://console.cloud.google.com/> (any name).
2. **Enable the Photos Picker API**: APIs & Services → Library → search
   "Google Photos Picker API" → Enable.
3. **Configure the OAuth consent screen**: APIs & Services → OAuth consent
   screen (or "Google Auth Platform" → Branding/Audience in newer consoles).
   - User type: **External**.
   - App name, support email, developer email: anything.
   - **Publishing status: leave it in "Testing".** Do not submit for
     verification.
   - **Test users: add your own Google account.** Only test users can sign in
     while the app is in Testing, and that is exactly what you want.
   - Scopes: you can leave this empty. The app requests the picker scope at
     runtime. (If you add it, use
     `https://www.googleapis.com/auth/photospicker.mediaitems.readonly`.)
4. **Create an OAuth client**: APIs & Services → Credentials → Create
   credentials → OAuth client ID.
   - Application type: **iOS**.
   - Bundle ID: must match `PRODUCT_BUNDLE_IDENTIFIER` for the app. With
     `project.yml` as shipped that is `com.rohangoel.GooglePhotosImporter`.
     Change `bundleIdPrefix` in `project.yml` if you want something else, and
     use the same value here.
   - App Store ID / Team ID: leave blank.
5. Copy two values from the new client's detail page:
   - **Client ID**, like `123456789012-abc...xyz.apps.googleusercontent.com`
   - **iOS URL scheme**, like `com.googleusercontent.apps.123456789012-abc...xyz`
     (this is just the client ID with its parts reversed).

## Local configuration

Credentials never go into `project.yml` or the Swift source. They live in a
gitignored xcconfig that XcodeGen wires into Info.plist at build time.

```bash
cd GooglePhotosImport
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

Then edit `Config/Secrets.xcconfig`:

```
GOOGLE_CLIENT_ID = 123456789012-abc...xyz.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.123456789012-abc...xyz
DEVELOPMENT_TEAM = ABCDE12345      # optional; or pick the team in Xcode
```

If the file is missing the project still generates, and the app shows a
"Setup required" screen instead of a sign-in button.

## Generate, build, run (on the Mac)

```bash
brew install xcodegen            # once
cd GooglePhotosImport
xcodegen generate
open GooglePhotosImporter.xcodeproj
```

In Xcode:

1. Wait for Swift Package Manager to resolve `GoogleSignIn-iOS`.
2. Select the `GooglePhotosImporter` target → Signing & Capabilities → tick
   "Automatically manage signing" and pick your team (unless you set
   `DEVELOPMENT_TEAM` in the xcconfig).
3. Plug in your iPhone, choose it as the run destination, press Run.
4. First launch on a free Apple ID: on the phone go to Settings → General →
   VPN & Device Management and trust your developer certificate.

Unit tests (dedup ledger, URL and duration parsing) need no credentials and
run in the Simulator: Product → Test, or

```bash
xcodebuild test -scheme GooglePhotosImporter \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Any time you change `project.yml`, run `xcodegen generate` again. Editing
files inside Xcode is fine; adding or moving files also just needs a re-run of
`xcodegen generate` since sources are picked up by folder.

## Project layout

```
GooglePhotosImport/            (repo root)
├── project.yml                     XcodeGen definition (targets, SPM deps, Info.plist)
├── Config/
│   └── Secrets.xcconfig.example    copy to Secrets.xcconfig (gitignored)
├── GooglePhotosImporter/           app target sources
│   ├── App/GooglePhotosImporterApp.swift    @main, OAuth redirect hookup
│   ├── Auth/GooglePhotosAuth.swift          GoogleSignIn-iOS wrapper + AccessTokenProvider
│   ├── Picker/PickerModels.swift            Picker API JSON models
│   ├── Picker/PickerSessionManager.swift    create / poll / list / delete sessions
│   ├── Import/ImportedItemStore.swift       dedup ledger (JSON in Application Support)
│   ├── Import/PhotoImporter.swift           download + PHPhotoLibrary save into album
│   ├── Views/ImportViewModel.swift          glue: the import pipeline, one `phase` for the UI
│   ├── Views/ImportView.swift               the single SwiftUI screen
│   ├── Config/AppConfig.swift               scope, API base URL, album title, config checks
│   ├── Config/SharedAlbum.swift             album model (a list, MVP shows one)
│   ├── Support/                             logging, top-view-controller helper
│   └── Resources/Assets.xcassets
├── GooglePhotosImporterTests/      XCTest target (no credentials needed)
├── CLAUDE.md                       constraints and conventions for Claude Code sessions
└── PROJECT_SPEC.md                 problem, feasibility, scope
```

Networking and auth are kept out of the views: `ImportView` only talks to
`ImportViewModel`, which composes the three service types. `PickerSessionManager`
and `PhotoImporter` depend on a tiny `AccessTokenProvider` protocol, so they can
be exercised with `StubAccessTokenProvider` and a stubbed `URLSession` without
Google.

## Where the real work still is

Everything that needs real credentials is implemented against the documented
API shapes but is **unverified**. Grep for `TODO` to find them. In particular:

- **Compile.** Expect small fixes on the first build (SDK method signatures,
  strict-concurrency warnings, XcodeGen key spelling). The GoogleSignIn calls
  used are `signIn(withPresenting:hint:additionalScopes:)`,
  `restorePreviousSignIn()`, `refreshTokensIfNeeded()`, `handle(_:)`.
- **Picker API shapes.** `PickerModels.swift` declares only the fields the
  app reads. Confirm against a real response on the first run, especially
  `pollingConfig` duration strings and `mediaFile.baseUrl`.
- **Download suffixes.** `=d` (photo) and `=dv` (video) appended to `baseUrl`
  with the bearer token. Base URLs expire after about an hour.
- **Polling while backgrounded.** The app polls the session while you're in
  Google's picker. iOS may suspend it; the loop resumes on return. If that
  feels flaky, the fix is to re-poll on `scenePhase == .active`.
- **Live Photos / motion photos.** Not paired; saved as whatever `type` the
  item reports.
- Not built, by design: background sync, multiple albums in the UI (the model
  supports it), Shortcuts/widgets, reminders.
