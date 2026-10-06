# Xray 26.9.8+ REALITY (X25519MLKEM768) Compatibility Plan

**Goal:** Make fork app `4.1.3` successors connect to Xray `v26.9.8+` REALITY servers again, without breaking older servers.

**Predecessor:** `2026-08-25-xray-267-reality-compatibility.md` (version bytes `{26, 7, 0}`). That fix is still required and stays.

## Root cause

Xray `v26.9.8` bumped `github.com/xtls/reality` to `8cdf7bf9c7f0`
("REALITY protocol: Reject outdated/strange Client Hello that doesn't have X25519MLKEM768 before optional X25519",
https://github.com/XTLS/REALITY/commit/8cdf7bf9c7f0, context: https://github.com/XTLS/Xray-core/issues/6714).

The server now authenticates a REALITY client only if the ClientHello key shares contain `X25519MLKEM768`, placed before the optional plain `X25519` share. Otherwise it treats the connection as a probe and proxies it to the target.

Our client (`hiddify-sing-box/common/tls/reality_client.go`, same code in upstream sing-box and upstream hiddify-sing-box `v5`) explicitly strips `X25519MLKEM768` from `supported_groups` and `key_share`, then rebuilds the handshake state. Every handshake is therefore rejected. Client symptom: `reality verification failed` / `x509: certificate signed by unknown authority`; server log: `REALITY: processed invalid connection ...: authentication failed or validation criteria not met`.

The same Xray release also commented out the default `minClientVer = {26, 3, 27}`, so version bytes are no longer the blocker.

## Evidence (local, 2026-10-05)

Workspace: `../hiddify-sing-box-fork` at `7651ca95` (exact submodule shipped in core `v4.1.2`), Go `1.24.7`, existing test `TestRealityClientVersionAgainstXrayMin`.

| Server lib `xtls/reality` | Client as shipped | Client without MLKEM filter |
|---|---|---|
| `e4eec4520535` (Xray 25.10.15) | — | PASS |
| `9234c772ba8f` (Xray 26.3.27–26.7.28) | PASS | PASS |
| `8cdf7bf9c7f0` (Xray 26.9.8+) | **FAIL** (`authentication failed or validation criteria not met`) | PASS ×3 |

Fingerprint matrix against `8cdf7bf9c7f0` with the filter removed (`metacubex/utls v1.8.4` presets):

| Option | Preset | Key shares | Result |
|---|---|---|---|
| `chrome` / `""` / `chrome_*` | Chrome-133 | GREASE, X25519MLKEM768, X25519 | PASS |
| `firefox` | Firefox-120 | X25519, P-256 | rejected |
| `edge` | Edge-85 | GREASE, X25519 | rejected |
| `safari` | Safari-16.0 | GREASE, X25519 | rejected |
| `ios` | iOS-14 | GREASE, X25519 | rejected |
| `qq` | QQBrowser-11.1 | GREASE, X25519 | rejected |
| `android`, `360` | no TLS 1.3 shares | — | `nil ecdheKey` |
| `random` | one of chrome/firefox/edge/safari/ios per process | — | works only if chrome picked |
| `randomized` | HelloRandomized | random | non-deterministic |

Non-chrome failures are server policy, not our bug: Xray's own test now covers only `chrome`, `firefox`, `safari`, which work there because Xray uses `refraction-networking/utls` with `Firefox_148` / `Safari_26_3` presets; `metacubex/utls` lacks them.

## Decision

1. Remove the `X25519MLKEM768` filter (and the now-unused second `BuildHandshakeState` and `common` import). Auth key keeps using `KeyShareKeys.Ecdhe`, with fallback to `KeyShareKeys.MlkemEcdhe` when `Ecdhe` is nil — mirrors Xray client (`transport/internet/reality/reality.go`). Field verified in `metacubex/utls@v1.8.4` `u_public.go:885`; uTLS keeps it as a separate key from `Ecdhe` (`key_schedule.go:57`), and the server uses the hybrid's X25519 part only when no plain X25519 share exists, so the fallback stays consistent. Chrome-133 sends both shares → `Ecdhe` path.
2. Force Chrome for every REALITY outbound: in `NewRealityClient`, after the uTLS-enabled check, replace `options.UTLS` with `&option.OutboundUTLSOptions{Enabled: true, Fingerprint: "chrome"}` (new pointer — never mutate the caller's). Profile `fp` is ignored for REALITY; plain TLS/uTLS outbounds keep their fingerprint. Rescues existing subscriptions with `fp=firefox/safari/ios/random/...` without user edits.
3. Keep `realityClientVersion = {26, 7, 0}`.

Decided 2026-10-05: REALITY always uses Chrome; no uTLS preset port or library switch.

Verified locally (throwaway): filter removed + forced Chrome, client configured `fp=firefox` → PASS against `xtls/reality` `8cdf7bf9c7f0`, `9234c772ba8f`, `e4eec4520535`.

## Tasks

### 1. Sing-box fork — `ferras777/hiddify-sing-box`

- Branch `app-release-compat-xray-269` from `app-release-compat-xray-267` (`7651ca95`).
- Do **not** bump `github.com/xtls/reality` in `go.mod`: it is a production dependency (sing-box REALITY inbound) and the new version would change inbound policy. The test exercises a server version chosen at CI time via a temporary `go get` that is never committed.
- Locally: `go get github.com/xtls/reality@8cdf7bf9c7f0` (uncommitted).
- Run `go test -tags with_utls ./common/tls -run TestRealityClientVersionAgainstXrayMin -count=1` → expect RED with `authentication failed or validation criteria not met`.
- In `common/tls/reality_client.go`: force Chrome in `NewRealityClient` (Decision 2); delete the `for _, extension := range uConn.Extensions { ... X25519MLKEM768 ... }` loop and the second `uConn.BuildHandshakeState()`; drop unused `github.com/sagernet/sing/common` import; add `if ecdheKey == nil { ecdheKey = keyShareKeys.MlkemEcdhe }`.
- In `common/tls/reality_client_test.go`: set client `Fingerprint: "firefox"` — the test then proves the override, since Firefox-120 alone is rejected by the new server.
- Re-run the test → GREEN.
- `.github/workflows/reality-test.yml`: matrix over `reality: [8cdf7bf9c7f0, 9234c772ba8f]`; each job runs `go get github.com/xtls/reality@${{ matrix.reality }}` then the test. Dispatch on the branch; record run URL.
- Revert local `go.mod`/`go.sum` before commit.
- Commit `fix: force Chrome with X25519MLKEM768 for Xray 26.9 REALITY`, push.

**Acceptance:** RED before / GREEN after on new server; GREEN on old server in CI.

**Done 2026-10-05:** commit `21f54fb` on `app-release-compat-xray-269`. Local RED (`fp=firefox`, unpatched, `8cdf7bf9c7f0`) → GREEN on both servers. CI: https://github.com/ferras777/hiddify-sing-box/actions/runs/37369039718 — `reality (8cdf7bf9c7f0)` and `reality (9234c772ba8f)` success.

### 2. Core fork — `ferras777/hiddify-core`

- On `release/xray-267-app-compat` (`8e85d15`): point `hiddify-sing-box` gitlink at Task 1 commit; `go.mod` unchanged.
- Commit, tag `v4.1.3`, push → `release.yml` publishes `hiddify-lib-android.tar.gz`.
- Dispatch `Windows core release` on `main` with `ref=<new release-branch commit>`, `release-tag=v4.1.3` (tag push alone does not run it: the workflow file is not on the release branch). Update its input defaults to the new ref/tag in the same change.
  Provenance of the current `v4.1.2` Windows asset: run `33216499056` checked out `8e85d15` (gitlink `7651ca95`), so today's Windows app already has `{26, 7, 0}` and fails for the same MLKEM reason as Android.
- Record SHA-256 of both assets.

**Acceptance:** release `v4.1.3` has `hiddify-lib-android.tar.gz` and `hiddify-lib-windows-amd64.tar.gz` built from the patched submodule.

### 3. App — `ferras777/hiddify-app`

- `pubspec.yaml` → `4.1.4+40104`.
- `.github/workflows/android-release.yml`: `CORE_URL` → `.../hiddify-core/releases/download/v4.1.3`, `CORE_SHA256` → new Android digest.
- `.github/workflows/windows-release.yml`: `CORE_URL` → `v4.1.3`.
- `appcast.xml`: Android item → `v4.1.4` universal APK.
- Commit, tag `v4.1.4` (Android release), dispatch Windows release for `v4.1.4`.

**Acceptance:** release `v4.1.4` with 4 signed APKs + `SHA256SUMS` and Windows `Setup-x64.exe` + `Portable-x64.zip`; workflow logs show core `v4.1.3` URL and digest.

### 4. Runtime check

- Android and Windows: REALITY profiles with `fp=chrome` and `fp=firefox` against Xray `v26.9.30` → traffic flows for both.
- Same build against a pre-26.9 Xray server → still works.
- If no live server: record Task 1 CI runs as evidence; do not claim live validation.
