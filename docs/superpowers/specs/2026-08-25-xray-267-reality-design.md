# Xray 26.7+ REALITY Compatibility Design

**Status:** Approved for implementation planning

## Goal

Make the Android Hiddify fork connect to Xray 26.7+ / 3X-UI 3.5+ REALITY servers that keep the default `minClientVer` check, then publish a signed fork APK and fork-local update metadata.

## Evidence

Discussion: https://github.com/hiddify/hiddify-app/discussions/2309

Xray compatibility issue: https://github.com/XTLS/Xray-core/issues/6477

Xray 26.7+ compares the first three REALITY client-version bytes against the default minimum `{26, 3, 27}`. The shipped Hiddify Sing-box client currently writes `{1, 8, 1}` into the encrypted ClientHello session ID, so the server rejects the connection before VLESS traffic starts.

## Decision

Patch the forked `hiddify-sing-box/common/tls/reality_client.go` to advertise compatibility version `{26, 7, 0}` through a named package-private array and copy it into `hello.SessionId[:3]`. Keep the existing REALITY key exchange, short ID, fingerprint, and payload behavior unchanged.

Do not change Flutter connection logic, add a second proxy core, or ask users to weaken the server to `minClientVer=1.0.0`.

## Repository chain

Use three repositories owned by `ferras777`:

- `ferras777/hiddify-sing-box`: patched REALITY client and self-contained integration test.
- `ferras777/hiddify-core`: existing core build with its `hiddify-sing-box` submodule pointed at the patched fork.
- `ferras777/hiddify-app`: Android-only release workflow, updater endpoints, appcast, version, and release cleanup.

`hiddify-core` must be built from the official app-compatible `v4.1.0` source commit `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0`, whose Singbox submodule base is `0a02b7729f6a211436bb8bdcd8696c283eb27767`. Its `go.mod` already uses the local replacement `github.com/sagernet/sing-box => ./hiddify-sing-box`; do not replace it with a remote module. Change only the submodule URL and gitlink commit in the core fork. The patched Sing-box fork keeps `module github.com/sagernet/sing-box`, so sibling local replacements remain valid.

## Core artifact

Reuse `hiddify-core/.github/workflows/build.yml`. Restrict its matrix to the existing Android job `hiddify-lib-android` / `target: android`; gate non-Android release jobs for the fork. The workflow already installs NDK, runs `make android`, and uploads `hiddify-lib-android.tar.gz`.

Core release tag: `v4.1.2`; earlier fork tag `v4.1.1` is retained as a failed API-compatibility attempt and must not be used by the app.

Required asset:

```text
hiddify-lib-android.tar.gz
```

## App build and release

In `ferras777/hiddify-app`:

- delete fork-hostile `.github/workflows/ci.yml` and `.github/workflows/release.yml` in the same first commit as source changes;
- add `.github/workflows/android-release.yml` with no upstream Sentry, Google Play, TestFlight, or desktop matrix dependencies;
- download and checksum the fork core asset;
- pass the fork core URL as a make command-line override, not an environment-only value;
- build production APKs for arm64-v8a, armeabi-v7a, x86_64, and universal;
- publish GitHub Release `v4.1.3` in `ferras777/hiddify-app`.

App version becomes `4.1.3+40103`.

The release uses a new fork keystore supplied through GitHub Actions secrets. It cannot update the official Hiddify installation because Android signatures differ; users must export profiles, uninstall the official APK, and install the fork APK.

## Updater

Point all three updater constants to the fork:

```dart
static const githubReleasesApiUrl =
    "https://api.github.com/repos/ferras777/hiddify-app/releases";
static const githubLatestReleaseUrl =
    "https://github.com/ferras777/hiddify-app/releases/latest";
static const appCastUrl =
    "https://raw.githubusercontent.com/ferras777/hiddify-app/main/appcast.xml";
```

Update `appcast.xml` with the fork release and universal APK URL. Keep tag format `v4.1.3`; existing `GithubReleaseParser` strips the leading `v` and parses `4.1.3` without a parser change.

## Verification

Two infrastructure-free checks are mandatory:

1. A Go integration test in the Sing-box fork starts a local XTLS/REALITY server with `MinClientVer: []byte{26, 3, 27}`, connects with the patched client, completes TLS/REALITY handshake, and exchanges a sentinel payload.
2. The app workflow prints the resolved fork `CORE_URL` and SHA-256 of the exact `hiddify-lib-android.tar.gz` used by the Android build.

If a live 3X-UI/Xray 26.7+ endpoint is available, run an additional real connection test; release correctness must not depend on that external box.
