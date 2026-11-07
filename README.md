# AES Camera for iOS

**A camera app that encrypts every photo and video the moment it's captured.** Nothing is
ever written to disk unencrypted. This is the native iOS version of
[AES Camera for Android](https://github.com/AESCamera/AESCamera-Android).

> Work in progress: not yet usable.

## Goals

- **Encrypt at the shutter.** Photos are encrypted in memory before they're saved.
- **Encrypt while recording.** Video is encrypted segment by segment as it records, so no
  unencrypted video is ever written.
- **Same files as Android.** A photo or video made on either platform opens on the other
  with the same password, and an exported vault restores on either.
- **Your key, your access.** The password is held in memory only. The app locks as soon as
  it goes to the background. Any password opens a vault; there's no wrong-password signal.
- **No tracking.** No analytics, no ads, no network code.

Unlike Android, iOS can't block screenshots. The app hides its content from the app
switcher and while the screen is being recorded or mirrored.

## Requirements

- Xcode 26 or later, iOS 17 or later.
- A real iPhone for camera work (the Simulator has no camera).

## Licence

[Mozilla Public License 2.0](LICENSE). The Android app is GPLv3.
