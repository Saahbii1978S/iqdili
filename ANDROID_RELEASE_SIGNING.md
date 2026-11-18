# Android release signing for Ahla Tounsa

The public Android download must be built with one permanent private release keystore. Never commit the keystore or its passwords to this repository, send them in chat, or upload them as ordinary files.

## 1. Create and back up the release key

On a trusted computer with Java's `keytool` installed, create the keystore once:

```bash
keytool -genkeypair -v -keystore ahla-tounsa-release.jks -alias ahla-tounsa -keyalg RSA -keysize 2048 -validity 10000
```

Choose strong, unique passwords and keep a secure offline backup of the keystore and credentials. Losing this key can prevent future updates from installing over this app. Do not regenerate it for later releases.

## 2. Add GitHub Actions secrets

In the repository, open **Settings → Secrets and variables → Actions → New repository secret**.

Add these four secrets:

- `ANDROID_KEYSTORE_BASE64`: the keystore file encoded as one Base64 string (on macOS/Linux: `base64 < ahla-tounsa-release.jks | tr -d '\n'`; on PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes('ahla-tounsa-release.jks'))`).
- `RELEASE_STORE_PASSWORD`: the keystore password.
- `RELEASE_KEY_ALIAS`: `ahla-tounsa` (or the exact alias selected when creating the key).
- `RELEASE_KEY_PASSWORD`: the key password.

Never paste the Base64 value or passwords into an issue, pull request, commit, or chat.

## 3. Build only after secrets are configured

Open **Actions → Build and publish signed Ahla Tounsa Android APK → Run workflow**. The workflow checks the key, builds the Release APK, verifies its package ID, ZIP integrity, signature, and alignment, then updates the existing `android-latest` release asset.

If any secret is missing or invalid, the workflow stops before publishing and leaves the existing download untouched.

## Important installation compatibility note

The previously published APK was a Debug build. A Release APK signed with this permanent key has a different signing identity, so Android may require uninstalling the old Debug app before installing the signed Release build. Uninstalling can remove local app data. Confirm this before doing it on a device with data that matters.

A permanent signature is necessary for reliable future updates, but it cannot guarantee that Android or Google Play Protect will never display a warning for an app installed outside Google Play.
