# Building and Distributing zzPDF

This guide covers local builds, Developer ID signing, Apple notarization, Gatekeeper verification, and GitHub releases.

## 1. Prepare the Mac

Install Xcode from the App Store, open it at least once, and accept its license. Verify the environment:

```bash
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-path
```

Select Xcode explicitly when necessary:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## 2. Create a Local Build

```bash
./build-app.sh
```

The script compiles a release binary, assembles `outputs/zzPDF.app`, applies an ad hoc local signature, verifies the bundle, and creates `outputs/zzPDF-macOS.zip`.

Launch the local build with:

```bash
open "outputs/zzPDF.app"
```

## 3. Obtain a Distribution Certificate

Join the Apple Developer Program and create or install a **Developer ID Application** certificate in Keychain Access. List the available signing identities:

```bash
security find-identity -v -p codesigning
```

Rebuild using the certificate's exact name:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./build-app.sh
```

When `SIGN_IDENTITY` is not `-`, the build script enables Hardened Runtime and requests a secure timestamp.

Verify the signature and Gatekeeper assessment:

```bash
codesign --verify --deep --strict --verbose=2 "outputs/zzPDF.app"
spctl --assess --type execute --verbose=2 "outputs/zzPDF.app"
```

Before notarization, `spctl` may report that the app has not been notarized. This is expected.

## 4. Store Notarization Credentials

Store the credentials in Keychain once. Apple requires an app-specific password:

```bash
xcrun notarytool store-credentials "zzPDF-notary" \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

These credentials are not stored in the repository.

## 5. Notarize the App

After producing a Developer ID-signed build:

```bash
./scripts/notarize.sh
```

The script submits the ZIP to Apple, waits for the result, staples the ticket to the app, validates it, and recreates the final ZIP. To use another Keychain profile:

```bash
NOTARY_PROFILE="profile-name" ./scripts/notarize.sh
```

Perform the final checks:

```bash
xcrun stapler validate "outputs/zzPDF.app"
spctl --assess --type execute --verbose=2 "outputs/zzPDF.app"
```

## 6. Publish a GitHub Release

Create a tag that matches `CFBundleShortVersionString` in `AppResources/Info.plist`:

```bash
git tag -a v0.5.10 -m "zzPDF 0.5.10"
git push origin main --tags
```

On the repository's **Releases** page, create a release from the tag and attach `outputs/zzPDF-macOS.zip`. Only publish the ZIP created after notarization.

## 7. Update the Version

Before each release, update these values in `AppResources/Info.plist`:

- `CFBundleShortVersionString`: the public version, for example `0.5.0`.
- `CFBundleVersion`: an always-increasing build number, for example `3`.

Rebuild, sign, notarize, and create the matching tag.

## Notes

- Never commit passwords, exported notarization profiles, API credentials, or `.p12` certificates.
- A package built on an Apple Silicon Mac is arm64. A universal release requires an additional x86_64 build combined with `lipo`, or an Xcode project configured with `ARCHS = arm64 x86_64`.
- Mac App Store distribution requires sandboxing, provisioning profiles, and a separate pipeline from the Developer ID workflow described here.
