# Google Photos → iOS Photos Importer — Project Spec

## Problem
People share photos via Google Photos shared albums/links. As an iPhone user, saving
those into the native Photos app is tedious one photo at a time, and Google Photos'
API no longer allows simple headless syncing of shared content. Paid third-party
tools (e.g. PhotoSync) already do this — the goal here is a free, self-built
alternative for personal use.

## Feasibility (read this first)
Buildable — with one caveat that shapes the whole product.

In March 2025, Google locked down the Photos Library API:
- Programmatic listing/joining of shared albums (`sharedAlbums.list/get/join`) → disabled.
- Library API read access is now restricted to content *your own app* created.
- The only sanctioned way to read existing library/shared-album content is the new
  **Photos Picker API** — an interactive, Google-hosted picker the user must open
  and confirm a selection in, every time. There is no API for silently polling a
  shared album for new items in the background.

**Conclusion:** a fully automatic background sync (like iCloud Shared Albums) is not
achievable through Google's supported API. What *is* achievable, and still a big
upgrade over today: a **one-tap batch importer** — open the app, launch the picker
pointed at the shared album, multi-select everything new, and the app pulls all of
it down and writes it straight into iOS Photos in one shot.

## Out of scope
- True background/automatic sync (blocked by Google's current API policy).
- Reverse-engineered/unofficial Google Photos API access (violates ToS, fragile).
- Android or other platforms.
- App Store distribution (personal sideload only).

## Recommended architecture
- **Native iOS app, Swift/SwiftUI.** Writing to Photos (`PHPhotoLibrary`) and
  handling the OAuth/picker redirect flow are both first-class here, and no App
  Store listing is required — sideload to your own phone via Xcode with a free
  Apple ID.
- **Google Cloud project** (free tier): OAuth client (iOS type) + Photos Picker API
  enabled. Keep the app in "Testing" publish status with your own Google account
  added as a test user — no Google verification review needed for personal use.

### Flow
1. Sign in with Google (`photospicker.mediaitems.readonly` scope only).
2. Create a Picker session; present Google's picker UI, deep-linked/scoped to the
   target shared album.
3. Poll the session until the user finishes selecting.
4. Fetch the selected media items' download URLs (`baseUrl` + size params);
   download full-resolution bytes.
5. Save each item via `PHPhotoLibrary.shared().performChanges`, into a dedicated
   album (e.g. "Imported from Google Photos").
6. Persist imported media-item IDs locally so re-picking the same album later
   skips duplicates.

## MVP scope
- One shared album, manual "Import now" button.
- Dedup via a stored set of media item IDs.
- Basic progress UI (e.g. "12 of 40 saved").
- Saves into a dedicated Photos album, not the main camera roll.

## Stretch goals
- Shortcuts/widget integration for a faster "Import" tap.
- Support several shared albums with saved shortcuts to each.
- Local reminder notification ("haven't imported in 2 weeks").

## Open decisions before coding starts
- Do you have a Mac with Xcode? (Required — there's no way around it for a real
  Photos-app write on iOS.)
- Free Apple ID signing (re-sign every 7 days) vs. paid $99/yr developer account
  (sideload lasts a year)?
- One shared album to start, or design for several from day one?
- Worth a sentence to whoever's sharing with you about just switching to iCloud
  Shared Albums instead, which does real background auto-sync for free?
