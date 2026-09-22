# Pocket Clipboard

Pocket Clipboard lets an Android phone send a photo to a macOS computer. The macOS receiver writes the image to the system clipboard, shows a notification, and can optionally archive the image to 7bu through a token supplied by the Android app.

## Features

- Six-digit pairing code with refresh support.
- Android camera and gallery selection.
- Pairing code and 7bu token cached locally; the token is encrypted with Android Keystore.
- macOS automatic clipboard copy, notification, launch at login, and image-host link copy.
- Server-side fan-out: computer delivery is independent from 7bu archive success.

## Repository Layout

- `android-app/`: native Android client.
- `mac-app/`: native macOS receiver.
- `server.mjs`: lightweight relay API.
- `docs/api.md`: relay API and 7bu integration details.
- `pocket-clipboard.service`: systemd unit example.

## Build

Build Android with Android Studio or `android-app/gradlew assembleDebug` after setting the local Android SDK path. Build macOS with `cd mac-app && ./build.sh`.

Application packages are published in the [Releases](../../releases) section rather than committed to the source tree.

## Security

Do not commit real 7bu tokens, server environment files, Android `local.properties`, or signing keys. The relay accepts a per-upload `X-Sevenbu-Token` header from the Android client over HTTPS and never sends that token to the macOS receiver.
