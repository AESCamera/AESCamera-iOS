# AES Camera for iOS

**A camera app that encrypts every photo and video the moment it's captured.** Nothing is
ever written to disk unencrypted. This is the native iOS version of
[AES Camera for Android](https://github.com/AESCamera/AESCamera-Android).

> Work in progress: runs end to end in the Simulator; not yet tested on a real iPhone.

## What it does

- **Encrypt at the shutter.** Photos are captured as JPEG in memory and sealed with
  AES-256-GCM before they're written.
- **Encrypt while recording.** `AVAssetWriter` runs in segment mode with no output file:
  each fragmented-MP4 segment arrives in memory and goes straight through AES-256-CTR +
  HMAC-SHA256 into the `.encv` file. No unencrypted video is ever written.
- **Same files as Android.** Photos (`.enc`) and videos (`.encv`) made on either platform
  open on the other with the same password, and an exported vault restores on either.
  Android videos (MPEG-TS) play through a built-in TS player; iOS videos (fragmented MP4)
  play through AVPlayer with on-the-fly decryption.
- **A private vault.** A grid of encrypted thumbnails and a swipeable viewer that decrypts
  in memory. Share, export and delete, always as ciphertext.
- **Your key, your access.** The password is held in memory only and the app locks as soon
  as it goes to the background. Any password opens a vault; there's no wrong-password
  signal, and nothing is created until the first save.
- **Your choice of storage.** Private app storage, or the Files app (On My iPhone ›
  AES Camera). Both are excluded from iCloud backups; use Export for backups.
- **No tracking.** No analytics, no ads, no network code.

iOS can't block screenshots. The app covers its content in the app switcher and while the
screen is being recorded or mirrored, and says so when a screenshot is taken.

## Project layout

| Path | What |
|---|---|
| `AESCore/` | Swift package with no UI: file formats, crypto, vault lookup, import validation, MPEG-TS demuxing. Tested with `swift test` on macOS. |
| `AESCore/Sources/aescore-tool/` | Development tool (macOS) to inspect vault files and make test videos. |
| `AESCamera/` | The SwiftUI app. |
| `AESCameraUITests/` | UI tests that drive the app in the Simulator. |

## Building

Requires Xcode 26 or later; the app targets iOS 17 or later. Open `AESCamera.xcodeproj` and
run the `AESCamera` scheme. Set your own development team under Signing & Capabilities to
run on a device.

The Simulator has no camera. There the app uses a **simulated camera** (a moving test
pattern for photos and videos), so capture, encryption, the gallery and playback can all
be exercised without a device.

## Testing

```sh
# Format and crypto tests (no Simulator needed)
cd AESCore && swift test

# UI tests in the Simulator
xcodebuild test -project AESCamera.xcodeproj -scheme AESCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The UI tests unlock with `uitest-password`. To run them against another vault, such as files
recorded on Android and imported into the Simulator, prefix the command with
`TEST_RUNNER_UITEST_PASSWORD=<password>`.

The crypto tests include reference values computed independently with Python's `hashlib`
and the `openssl` CLI, pinning PBKDF2, AES-CTR (with counter carry), the `.encv` MAC key and
legacy CBC to the same definitions Android uses.

### Development tool

```sh
cd AESCore && swift build --product aescore-tool
T=.build/debug/aescore-tool
$T find    "<vault base dir>" <password>          # which vault folder a password opens
$T verify  <file.encv> <password>                 # header + integrity check
$T decrypt <file.enc|file.encv> <password> <out>  # for inspecting test data only
$T probe   <out.mp4>                              # duration, tracks, rotation
$T make-ts <out.encv> <password> [seconds] [rotation]  # Android-style MPEG-TS test video
```

The app's data folder in the Simulator is at
`xcrun simctl get_app_container booted dev.dineshkumar.aescamera data`; the private vault
is under `Library/Application Support/vault/`.

To test **opening shared files**, copy an `.enc`/`.encv` into the app's `Documents/Inbox/`
and run `xcrun simctl openurl booted "file://<path>"`. The UI test
`testPendingImportOpensAndAddsToVault` then completes the import (it's skipped when no
import is waiting).

## Licence

[Mozilla Public License 2.0](LICENSE). The Android app is GPLv3.
