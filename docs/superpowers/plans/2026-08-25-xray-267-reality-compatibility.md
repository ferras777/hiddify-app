# Xray 26.7+ REALITY Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch Hiddify's REALITY client compatibility with Xray 26.7+, build a fork core, publish signed Android APKs, and keep in-app updates inside `ferras777/hiddify-app`.

**Architecture:** Patch the REALITY ClientHello version bytes in a fork of `hiddify-sing-box`; consume that fork through `hiddify-core`'s existing local submodule replacement; publish only the Android core artifact. Replace fork-hostile app CI/release triggers with one Android-only release workflow that verifies the exact fork core archive before building.

**Tech Stack:** Go, XTLS/REALITY, Sing-box `with_utls`, Hiddify core gomobile/Android AAR, Flutter 3.38.5, Gradle/Kotlin, GitHub Actions, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-08-25-xray-267-reality-design.md`

## Global Constraints

- Target repositories: `ferras777/hiddify-sing-box`, `ferras777/hiddify-core`, and `ferras777/hiddify-app`.
- REALITY compatibility bytes: `{26, 7, 0}`; Xray default minimum under test: `{26, 3, 27}`.
- Required core release asset: `hiddify-lib-android.tar.gz`.
- App version: `4.1.3+40103`; app release tag: `v4.1.3`.
- Do not change `hiddify-core/go.mod` remote replacements; keep `replace github.com/sagernet/sing-box => ./hiddify-sing-box`.
- Delete app fork `.github/workflows/ci.yml` and `.github/workflows/release.yml` in the same first commit as app source changes, before pushing any other app change.
- Use a fork-owned Android keystore; never create an empty `key.properties` or empty keystore.
- Official Hiddify signing key is unavailable; fork APK cannot update an official installation.
- Release correctness must not depend on access to a live 3X-UI/Xray server.

---

### Task 1: Patch Sing-box REALITY version advertisement

**Repository:** `ferras777/hiddify-sing-box`

**Files:**
- Modify: `common/tls/reality_client.go`
- Create: `common/tls/reality_client_test.go`
- Modify: `go.mod` and `go.sum` only if the self-contained test needs a direct XTLS/REALITY module dependency

**Interfaces:**
- Consumes: existing `NewRealityClient`, `RealityClientConfig.ClientHandshake`, and `option.OutboundTLSOptions`.
- Produces: package-private `realityClientVersion` with value `[3]byte{26, 7, 0}` and a passing integration test named `TestRealityClientVersionAgainstXrayMin`.

- [ ] **Step 1: Create the fork and check out the current extended branch**

```bash
gh repo fork hiddify/hiddify-sing-box --clone=false
git clone https://github.com/ferras777/hiddify-sing-box.git ../hiddify-sing-box-fork
git -C ../hiddify-sing-box-fork checkout extended
git -C ../hiddify-sing-box-fork switch -c fix/xray-267-reality
```

- [ ] **Step 2: Add the failing local REALITY integration test**

Create `common/tls/reality_client_test.go` with `//go:build with_utls`. The test must generate an X25519 key pair and an 8-byte short ID, then start a local TLS 1.3 fallback before starting the REALITY listener. Use `httptest.NewUnstartedServer` with an `http.HandlerFunc`, assign `fallback.TLS = &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13}`, call `fallback.StartTLS()`, and derive `fallbackAddr` by removing `https://` from `fallback.URL`.

`reality.Server` dials `Config.Dest` before inspecting the client hello, so do not use `net.Pipe` for the fallback leg. Configure the REALITY listener with the actual fallback address:

```go
serverConfig := &reality.Config{
    DialContext: (&net.Dialer{}).DialContext,
    Type:         "tcp",
    Dest:         fallbackAddr,
    ServerNames:  map[string]bool{"example.com": true},
    PrivateKey:   serverPrivateKey.Bytes(),
    MinClientVer: []byte{26, 3, 27},
    ShortIds:     map[[8]byte]bool{shortID: true},
}
```

Construct the Hiddify client with `option.OutboundTLSOptions` using the matching public key, short ID, `ServerName: "example.com"`, `Reality.Enabled: true`, and `UTLS.Enabled: true`. Accept one TCP connection, wrap it with `reality.Server`, call both sides' handshake methods, write `reality-client-ok` from the client, and assert the server reads the same bytes. Close the fallback server with `defer fallback.Close()` and add deadlines so a rejected `{1, 8, 1}` client fails instead of hanging. Pin `github.com/xtls/reality` to commit `9234c772ba8f181f31c3e81dc2b4177322e5a9a9` if it is not already reachable through the module graph. This remains fully offline; the fallback listener binds only to the local test host.

- [ ] **Step 3: Run the focused test before the source change**

Run:

```bash
go test -tags with_utls ./common/tls -run TestRealityClientVersionAgainstXrayMin -count=1
```

Expected: FAIL during REALITY authentication because the current client advertises `{1, 8, 1}`, which is below `{26, 3, 27}`.

- [ ] **Step 4: Implement the smallest source change**

Add the named compatibility value near the REALITY client implementation:

```go
var realityClientVersion = [3]byte{26, 7, 0}
```

Replace the three hardcoded assignments:

```go
hello.SessionId[0] = 1
hello.SessionId[1] = 8
hello.SessionId[2] = 1
```

with:

```go
copy(hello.SessionId[:3], realityClientVersion[:])
```

Do not change key derivation, server name, fingerprint, short ID, fallback, or payload code.

- [ ] **Step 5: Run the focused test after the source change**

Run:

```bash
go test -tags with_utls ./common/tls -run TestRealityClientVersionAgainstXrayMin -count=1
```

Expected: PASS, including the sentinel payload exchange. Run the package's existing focused tests as well:

```bash
go test -tags with_utls ./common/tls -count=1
```

- [ ] **Step 6: Commit the patched core**

```bash
git -C ../hiddify-sing-box-fork add common/tls/reality_client.go common/tls/reality_client_test.go go.mod go.sum
git -C ../hiddify-sing-box-fork commit -m "fix: support Xray 26.7 reality clients"
git -C ../hiddify-sing-box-fork push -u origin fix/xray-267-reality
git -C ../hiddify-sing-box-fork switch extended
git -C ../hiddify-sing-box-fork merge --ff-only fix/xray-267-reality
git -C ../hiddify-sing-box-fork push origin extended
```

**Acceptance:** The focused test proves a client with the patched bytes passes a server enforcing `{26, 3, 27}` without external infrastructure, and the patched commit is available from the fork's `extended` branch.

---

### Task 2: Wire patched Sing-box into the core fork

**Repository:** `ferras777/hiddify-core`

**Files:**
- Modify: `.gitmodules`
- Modify: gitlink `hiddify-sing-box`
- Modify: `.github/workflows/build.yml`
- Do not modify: `go.mod` replacement directives

**Interfaces:**
- Consumes: `ferras777/hiddify-sing-box:extended` and its patched commit.
- Produces: Android-only core workflow that publishes `hiddify-lib-android.tar.gz`.

- [ ] **Step 1: Create the core fork and check out its release branch**

```bash
gh repo fork hiddify/hiddify-core --clone=false
git clone --recurse-submodules https://github.com/ferras777/hiddify-core.git ../hiddify-core-fork
git -C ../hiddify-core-fork switch -c release/xray-267-reality
```

- [ ] **Step 2: Repoint only the Sing-box submodule**

Run from the core fork:

```bash
git -C ../hiddify-core-fork submodule set-url hiddify-sing-box https://github.com/ferras777/hiddify-sing-box
git -C ../hiddify-core-fork submodule update --init hiddify-sing-box
git -C ../hiddify-core-fork/hiddify-sing-box fetch origin extended
git -C ../hiddify-core-fork/hiddify-sing-box checkout extended
git -C ../hiddify-core-fork add .gitmodules hiddify-sing-box
```

Verify the core module still contains the local replacement and does not point at a remote Sing-box module:

```bash
git -C ../hiddify-core-fork diff -- go.mod
git -C ../hiddify-core-fork submodule status
```

Expected: `go.mod` has no diff, and the `hiddify-sing-box` gitlink resolves to the patched fork branch commit.

- [ ] **Step 3: Reduce core build matrix to Android**

In `.github/workflows/build.yml`, replace the existing `jobs.build.strategy.matrix.job` list with exactly:

```yaml
job:
  - { name: 'hiddify-lib-android', os: 'ubuntu-latest', target: 'android' }
```

Keep existing checkout with `submodules: 'recursive'`, Go setup, Java 17, NDK `r28`, `make android`, archive, artifact upload, and release upload steps. Do not add a new hand-written AAR build.

- [ ] **Step 4: Commit core wiring**

```bash
git -C ../hiddify-core-fork add .gitmodules hiddify-sing-box .github/workflows/build.yml
git -C ../hiddify-core-fork commit -m "build: use patched sing-box for android core"
git -C ../hiddify-core-fork push -u origin release/xray-267-reality
git -C ../hiddify-core-fork switch main
git -C ../hiddify-core-fork merge --ff-only release/xray-267-reality
git -C ../hiddify-core-fork push origin main
```

**Acceptance:** Core checkout resolves the patched Sing-box submodule, `go.mod` remains local-replacement based, and only Android build resources are scheduled.

---

### Task 3: Publish and verify the Android core artifact

**Repository:** `ferras777/hiddify-core`

**Files:**
- No additional source files

**Interfaces:**
- Consumes: core fork `main` and patched Sing-box submodule.
- Produces: GitHub Release `v4.1.1` with `hiddify-lib-android.tar.gz`.

- [ ] **Step 1: Confirm Actions is enabled on the core fork**

```bash
gh api repos/ferras777/hiddify-core/actions/permissions --jq '{enabled,allowed_actions}'
```

If `enabled` is false, enable Actions in the fork settings before tagging. Do not add core secrets; the existing release upload uses `secrets.GITHUB_TOKEN`.

- [ ] **Step 2: Tag the core release**

```bash
git -C ../hiddify-core-fork tag -a v4.1.1 -m "release: android core with Xray 26.7 REALITY compatibility"
git -C ../hiddify-core-fork push origin v4.1.1
```

- [ ] **Step 3: Watch the Android-only core workflow**

```bash
gh run list --repo ferras777/hiddify-core --workflow release.yml --limit 5
gh run watch --repo ferras777/hiddify-core $(gh run list --repo ferras777/hiddify-core --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

The run must finish successfully with no Linux, Windows, macOS, or iOS matrix jobs.

- [ ] **Step 4: Verify the published asset name and contents**

```bash
gh release view v4.1.1 --repo ferras777/hiddify-core --json tagName,isDraft,isPrerelease,assets --jq '{tagName,isDraft,isPrerelease,assets:[.assets[].name]}'
curl --fail --location https://github.com/ferras777/hiddify-core/releases/download/v4.1.1/hiddify-lib-android.tar.gz --output ../hiddify-lib-android.tar.gz
tar -tzf ../hiddify-lib-android.tar.gz
sha256sum ../hiddify-lib-android.tar.gz
```

Expected: published, non-draft asset named exactly `hiddify-lib-android.tar.gz`, containing the Android core AAR and its expected supporting files.

**Acceptance:** The exact URL used by the app workflow returns a valid core archive whose checksum is recorded for the app release.

---

### Task 4: Prepare fork app metadata and disable upstream triggers

**Repository:** `ferras777/hiddify-app`

**Files:**
- Modify: `pubspec.yaml:4`
- Modify: `lib/core/model/constants.dart:9-11`
- Modify: `appcast.xml`
- Create: `test/features/app_update/github_release_parser_test.dart`
- Delete: `.github/workflows/ci.yml`
- Delete: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: fork release repository and tag `v4.1.3`.
- Produces: app version `4.1.3+40103`, fork-local update endpoints, and no full-matrix push trigger.

- [ ] **Step 1: Add the parser regression test before changing metadata**

Create `test/features/app_update/github_release_parser_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';

void main() {
  test('parses the fork release tag', () {
    final release = GithubReleaseParser.parse({
      'tag_name': 'v4.1.3',
      'prerelease': false,
      'published_at': '2026-08-25T00:00:00Z',
      'html_url': 'https://github.com/ferras777/hiddify-app/releases/tag/v4.1.3',
    });

    expect(release.version, '4.1.3');
    expect(release.buildNumber, '');
    expect(release.releaseTag, 'v4.1.3');
    expect(release.preRelease, isFalse);
  });
}
```

Run:

```bash
flutter test test/features/app_update/github_release_parser_test.dart
```

Expected: PASS with current parser behavior for `v4.1.3`.

- [ ] **Step 2: Bump app version**

Change `pubspec.yaml` line 4 to:

```yaml
version: 4.1.3+40103
```

Leave `dependencies.properties` at `core.version=4.1.0`; Android preparation will override `CORE_URL` to the fork core release, and changing the pin would make non-Android paths silently depend on an unavailable upstream version.

- [ ] **Step 3: Repoint update endpoints**

Change only these three constants in `lib/core/model/constants.dart`:

```dart
static const githubReleasesApiUrl =
    "https://api.github.com/repos/ferras777/hiddify-app/releases";
static const githubLatestReleaseUrl =
    "https://github.com/ferras777/hiddify-app/releases/latest";
static const appCastUrl =
    "https://raw.githubusercontent.com/ferras777/hiddify-app/main/appcast.xml";
```

Do not change unrelated privacy, Telegram, or upstream license links in this task.

- [ ] **Step 4: Update Android appcast**

Replace stale Android appcast metadata with an item whose enclosure points to:

```text
https://github.com/ferras777/hiddify-app/releases/download/v4.1.3/Hiddify-Android-universal.apk
```

Set `sparkle:version="4.1.3"`, `sparkle:os="android"`, and `pubDate` to `Tue, 25 Aug 2026 00:00:00 +0000` for this release. Remove stale upstream Android entries so the fork updater cannot recommend an official build.

- [ ] **Step 5: Remove fork-hostile workflows before the first source push**

Delete `.github/workflows/ci.yml` and `.github/workflows/release.yml` in the same commit as the constants/version/appcast changes. `ci.yml` must not see an intermediate push of `lib/**`; otherwise it launches the full matrix, creates an empty signing configuration from absent fork secrets, and attempts upstream draft/release operations.

- [ ] **Step 6: Commit the guarded app metadata change**

```bash
git add pubspec.yaml lib/core/model/constants.dart appcast.xml test/features/app_update/github_release_parser_test.dart .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "fix: keep fork updates on Xray-compatible core"
git push origin main
```

**Acceptance:** First push contains both workflow deletions, updater tests parse `v4.1.3`, and no full-matrix job is triggered by the source change.

---

### Task 5: Add isolated Android release workflow

**Repository:** `ferras777/hiddify-app`

**Files:**
- Create: `.github/workflows/android-release.yml`

**Interfaces:**
- Consumes: core release URL `https://github.com/ferras777/hiddify-core/releases/download/v4.1.1` and four fork signing secrets.
- Produces: APK files named `Hiddify-Android-arm64.apk`, `Hiddify-Android-arm7.apk`, `Hiddify-Android-x86_64.apk`, and `Hiddify-Android-universal.apk`, plus `SHA256SUMS` and GitHub Release `v4.1.3`.

- [ ] **Step 1: Add the tag-triggered workflow**

Create `.github/workflows/android-release.yml` with this behavior:

```yaml
name: Android fork release

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

permissions:
  contents: write

env:
  FLUTTER_VERSION: '3.38.5'
  CHANNEL: prod
  CORE_URL: 'https://github.com/ferras777/hiddify-core/releases/download/v4.1.1'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: subosito/flutter-action@v2.21.0
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true

      - uses: actions/setup-java@v5
        with:
          distribution: zulu
          java-version: '17'

      - uses: android-actions/setup-android@v3

      - name: Install Fastforge
        run: |
          set -euo pipefail
          make android-install-deps
          echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"

      - name: Verify fork core archive
        run: |
          set -euo pipefail
          echo "CORE_URL=$CORE_URL"
          curl --fail --location "$CORE_URL/hiddify-lib-android.tar.gz" \
            --output "$RUNNER_TEMP/hiddify-lib-android.tar.gz"
          sha256sum "$RUNNER_TEMP/hiddify-lib-android.tar.gz"
          tar -tzf "$RUNNER_TEMP/hiddify-lib-android.tar.gz"

      - name: Prepare Flutter and fork core
        run: |
          set -euo pipefail
          make CORE_URL="$CORE_URL" android-prepare

      - name: Configure Android signing
        env:
          ANDROID_SIGNING_KEY: ${{ secrets.ANDROID_SIGNING_KEY }}
          ANDROID_SIGNING_STORE_PASSWORD: ${{ secrets.ANDROID_SIGNING_STORE_PASSWORD }}
          ANDROID_SIGNING_KEY_PASSWORD: ${{ secrets.ANDROID_SIGNING_KEY_PASSWORD }}
          ANDROID_SIGNING_KEY_ALIAS: ${{ secrets.ANDROID_SIGNING_KEY_ALIAS }}
        run: |
          set -euo pipefail
          test -n "$ANDROID_SIGNING_KEY"
          test -n "$ANDROID_SIGNING_STORE_PASSWORD"
          test -n "$ANDROID_SIGNING_KEY_PASSWORD"
          test -n "$ANDROID_SIGNING_KEY_ALIAS"
          printf '%s' "$ANDROID_SIGNING_KEY" | base64 --decode > android/key.jks
          test -s android/key.jks
          {
            printf 'storeFile=%s\n' "$GITHUB_WORKSPACE/android/key.jks"
            printf 'storePassword=%s\n' "$ANDROID_SIGNING_STORE_PASSWORD"
            printf 'keyPassword=%s\n' "$ANDROID_SIGNING_KEY_PASSWORD"
            printf 'keyAlias=%s\n' "$ANDROID_SIGNING_KEY_ALIAS"
          } > android/key.properties
          test -s android/key.properties

      - name: Build production APKs
        run: |
          set -euo pipefail
          make CHANNEL=prod android-apk-release

      - name: Collect APKs and checksums
        run: |
          set -euo pipefail
          mkdir -p out
          cp build/app/outputs/flutter-apk/*arm64-v8a*.apk out/Hiddify-Android-arm64.apk
          cp build/app/outputs/flutter-apk/*armeabi-v7a*.apk out/Hiddify-Android-arm7.apk
          cp build/app/outputs/flutter-apk/*x86_64*.apk out/Hiddify-Android-x86_64.apk
          cp build/app/outputs/flutter-apk/app-release.apk out/Hiddify-Android-universal.apk
          sha256sum out/*.apk > out/SHA256SUMS

      - uses: actions/upload-artifact@v6
        with:
          name: android-fork-release
          path: out
          retention-days: 7

      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tag_name: ${{ github.ref_name }}
          name: Hiddify Android ${{ github.ref_name }}
          prerelease: false
          files: out/*
```

- [ ] **Step 2: Validate workflow file without running the full matrix**

Run locally if `actionlint` is available:

```bash
actionlint .github/workflows/android-release.yml
```

Then inspect the workflow registration:

```bash
gh workflow list --repo ferras777/hiddify-app
gh api repos/ferras777/hiddify-app/actions/permissions --jq '{enabled,allowed_actions}'
```

Enable Actions in fork settings if `enabled` is false.
 
- [ ] **Step 3: Commit and push the Android-only workflow**

```bash
git add .github/workflows/android-release.yml
git commit -m "ci: add android fork release workflow"
git push origin main
```

This push is safe because both fork-hostile workflows were deleted in Task 4.

**Acceptance:** Workflow has only one Ubuntu job, passes `CORE_URL` as a make command-line variable, validates the exact core archive URL/digest, fails on missing signing secrets, and publishes only fork assets.

---

### Task 6: Configure fork signing and publish the APK release

**Repository:** `ferras777/hiddify-app`

**Files:**
- No additional source files
- GitHub Actions secrets and release tag are repository state

**Interfaces:**
- Consumes: Android-only workflow and core release `v4.1.1`.
- Produces: signed fork APK release `v4.1.3`.

- [ ] **Step 1: Generate a fork keystore outside the repository**

Use a local `keytool` installation to create a new RSA keystore with alias `hiddify-fork`, then base64-encode the binary keystore. Never commit the `.jks` file or passwords.

- [ ] **Step 2: Set the four fork secrets**

```bash
gh secret set ANDROID_SIGNING_KEY --repo ferras777/hiddify-app < hiddify-fork.jks.base64
gh secret set ANDROID_SIGNING_STORE_PASSWORD --repo ferras777/hiddify-app
gh secret set ANDROID_SIGNING_KEY_PASSWORD --repo ferras777/hiddify-app
gh secret set ANDROID_SIGNING_KEY_ALIAS --repo ferras777/hiddify-app
```

For the three password/alias commands, provide values interactively when `gh` prompts for stdin. Confirm the secret names, not values:

```bash
gh secret list --repo ferras777/hiddify-app
```

- [ ] **Step 3: Push the release tag**

Confirm the app branch contains the workflow deletions and Android workflow, then run:

```bash
git status --short
git tag -a v4.1.3 -m "release: Xray 26.7 REALITY compatibility"
git push origin v4.1.3
```

- [ ] **Step 4: Watch the Android-only run**

```bash
gh run list --repo ferras777/hiddify-app --workflow android-release.yml --limit 5
gh run watch --repo ferras777/hiddify-app $(gh run list --repo ferras777/hiddify-app --workflow android-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: no `ci.yml` or old `release.yml` run, core URL and SHA-256 appear in logs, all four APK copies exist, signing configuration succeeds, and release upload succeeds.

- [ ] **Step 5: Verify release assets and fork update metadata**

```bash
gh release view v4.1.3 --repo ferras777/hiddify-app --json tagName,isDraft,isPrerelease,assets --jq '{tagName,isDraft,isPrerelease,assets:[.assets[].name]}'
curl --fail --location https://raw.githubusercontent.com/ferras777/hiddify-app/main/appcast.xml
```

Expected assets:

```text
Hiddify-Android-arm64.apk
Hiddify-Android-arm7.apk
Hiddify-Android-x86_64.apk
Hiddify-Android-universal.apk
SHA256SUMS
```

- [ ] **Step 6: Verify APK signatures and install behavior**

Download the universal APK and run:

```bash
apksigner verify --verbose Hiddify-Android-universal.apk
sha256sum -c SHA256SUMS
```

Before installation, export Hiddify profiles. Because the fork key differs from the official key, uninstall the official `app.hiddify.com` package before installing the fork APK; do not claim in-place update support.

- [ ] **Step 7: Run runtime checks**

On an Android device, install the universal or matching-ABI APK, import a REALITY profile backed by Xray 26.7+, connect, and confirm traffic succeeds. Open the update checker and confirm it queries `ferras777/hiddify-app`, not `hiddify/hiddify-next` or `hiddify/hiddify-app`.

If no live Xray endpoint is available, record the Sing-box integration test and APK workflow logs as the release evidence; do not claim live-server validation.

**Acceptance:** Fork release `v4.1.3` contains four signed APKs and checksums, updater metadata points to fork, and Android runtime verification either passes against Xray 26.7+ or is explicitly recorded as unavailable while infrastructure-free checks pass.

---

## Final review checklist

- [ ] `realityClientVersion` is `{26, 7, 0}` and no `{1, 8, 1}` assignment remains in the patched client.
- [ ] Sing-box integration test enforces `{26, 3, 27}` and exchanges payload.
- [ ] Core uses local `./hiddify-sing-box`; no remote replacement was introduced.
- [ ] Core matrix contains Android only and publishes `hiddify-lib-android.tar.gz`.
- [ ] App first source commit deletes both `ci.yml` and `release.yml`.
- [ ] App workflow logs fork `CORE_URL` and archive SHA-256 before build.
- [ ] App updater constants and appcast point to `ferras777/hiddify-app`.
- [ ] App tag is `v4.1.3`; parser regression test passes.
- [ ] No empty signing properties are created.
- [ ] Release assets are signed fork APKs, not official Hiddify artifacts.
