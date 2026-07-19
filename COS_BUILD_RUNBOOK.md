# WhisperBoard → TestFlight — Build Runbook (Devin's fork)

> Goal: on-device Whisper dictation on the iPhone 16 Pro, shipped to TestFlight with the
> **least tethering** — build + sign + ship on free GitHub Actions macOS CI, install via
> TestFlight, never touch a Mac interactively. Fork: `github.com/dfmcintosh-hash/WhisperBoard`.

## Proven tonight (2026-07-19, free CI, no Mac, no dev account)
- **DONE:** compiles clean + **40/40 tests** + **vocab seeded (WD_PROMPT)** + **renamed to com.captainsos**. Below:
- Compiles CLEAN against **iOS 26.5 SDK**, **WhisperKit auto-resolved to 0.18.0**
  (`from: 0.1.0`) — `** BUILD SUCCEEDED **`, 1m48s. The 5-month-staleness risk is dead.
- **Tests: 40/40 PASS** on CI (simulator, no signing) — ModelManager, SharedDefaults, TranscriptionService, WhisperKit, WhisperModelType. Codebase is healthy, not half-broken.
- **Signing pipeline already exists** (author's): `fastlane` lanes `test/build/beta/release`
  + `match` + App Store Connect API key; `.github/workflows/ios.yml` runs `fastlane beta`
  → TestFlight. We are *plugging in identity*, not building the pipeline.

## The ONE gate that's Devin's: $99/yr Apple Developer account
Required for signing + App Groups + TestFlight, no matter the path. Nothing installs on
the phone without it. (developer.apple.com/programs)

## Tomorrow — sequence
**1. Enroll** in the Apple Developer Program ($99/yr) → note your **Team ID**.

**2. Rename bundle IDs** off the author's `com.fmachta.*` (you can't sign under his identity).
Pick a namespace, e.g. `com.dfmcintosh` (or a domain you own). ORCH runs this sed once you pick:
- `project.yml`: `com.fmachta.whisperboard` + `com.fmachta.whisperboard.keyboard`
- App Group `group.com.fmachta.whisperboard` → `SharedDefaults.swift:11` + both `*.entitlements`
- `fastlane/Appfile` (`app_identifier`, add `team_id`, `apple_id`) + `fastlane/Matchfile`

**3. Register in the Developer portal** (web, Linux-fine):
- App IDs: `com.captainsos.whisperboard` + `com.captainsos.whisperboard.keyboard`, both with **App Groups** capability
- App Group: `group.com.captainsos.whisperboard`
- Create the app record in **App Store Connect** (for TestFlight)

**4. App Store Connect API key** (CI upload auth): App Store Connect → Users and Access →
Integrations → Team Keys → generate (App Manager role). Keep **KEY_ID**, **ISSUER_ID**, and
the downloaded **.p8** contents.

**5. `match` cert storage:** create a PRIVATE repo (e.g. `dfmcintosh-hash/certificates`),
point `Matchfile` `git_url` at it, choose a **MATCH_PASSWORD**, run `fastlane match appstore`
once via CI to generate + store certs. _(Alt: skip match, use Xcode automatic signing + the
API key — simpler for a solo dev. ORCH will pick whichever is least friction on the day.)_

**6. Add GitHub Actions secrets** to the fork (Settings → Secrets and variables → Actions):
`MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`, `APP_STORE_CONNECT_API_KEY_ID`,
`APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_CONTENT`.

**7. Ship:** push (or dispatch `ios.yml`) → CI runs `fastlane beta` → signed build → TestFlight.

**8. Install** via the TestFlight app on your iPhone → hammer the dictation keyboard.

## What ORCH does tomorrow (no Mac needed)
- The bundle-ID rename (once you pick the namespace) — 2-min sed + commit.
- Wire/verify the CI signing (secrets, `ios.yml` beta trigger, match-vs-automatic choice).
- Debug CI signing failures from the logs, on Linux, for free, until TestFlight upload is green.
- v2 (later): install Swift-on-Linux, build + PROVE the `COSConnector` against the live
  connector, wire the async capture hook at `TranscriptionService.swift:314` over tailscale.

## Cost / tether
- **$99/yr dev account = the only real cost.** CI is free; no cloud-Mac rental required
  unless you later want interactive Xcode debugging.
- Outcome: **push → CI signs + ships → you install from TestFlight. Zero interactive Mac.**
