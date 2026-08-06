# Status — 2026-08-06

Living log. Update on every meaningful state change; newest facts here win
over older docs until those docs are revised.

## State

- **Phase: M0–M4 implemented; v0.1.0 tagging in progress. CI/release
  verification pending a GitHub Actions outage (see below).**
- Published at <https://github.com/Jean-Reinhold/meridian-bar>. Repo
  settings: Discussions, secret scanning + push protection, dependency
  alerts, private vulnerability reporting, branch protection on `main`
  (PRs; owner bypass until CI-green is required).
- **M1+M2 smoke tests PASSED (2026-08-06, live Meridian 1.60.0, 3
  profiles):** bar label with Fable-primary numbers and worst-window
  colors (non-template color rendering confirmed — R1 closed); dropdown
  cards, per-window bars + countdowns, blocked flags, switch buttons,
  health footer. Offline path: dead-port override degraded the bar to
  gray `meridian ⏻` within two polls and recovered without relaunch.
- **M3 implemented (17/17 tests):** settings window (base URL, poll
  interval, label style, primary window, per-profile aliases,
  notifications toggle, update channel), `segments`/`dots`/`worst` label
  styles, per-transition threshold notifications (escalations + blocked
  recovery, no startup spam), launch-at-login.
- **M4 implemented:** app icon (generated, committed `.icns`), About
  panel, CHANGELOG, `release.yml` (universal binary, ad-hoc sign, zip +
  sha256, GitHub Release, Sparkle-signed appcast item to `gh-pages`,
  guarded Homebrew cask bump), `install.sh` one-liner, Sparkle 2.9.5
  (exact-pinned SPM binary artifact, bundled framework, stable/beta
  channels via `sparkle:channel` + `SUPublicEDKey` in Info.plist).
- **Release infrastructure live:** `gh-pages` appcast skeleton + GitHub
  Pages enabled; `Jean-Reinhold/homebrew-tap` repo created; secrets set:
  `SPARKLE_PRIVATE_KEY` (EdDSA, also in owner keychain),
  `TAP_PUSH_TOKEN`.
- Meridian surface verified live 2026-08-06 against Meridian **1.60.0**
  (`okf/01`).
- **Host toolchain quirk RESOLVED** — orphaned 2024 private
  swiftinterfaces; details `okf/03`. `make test` runs Swift Testing
  locally.
- **GitHub Actions major outage (2026-08-06 ~18:00Z onward):** killed
  runs mid-flight, swallowed push events. All workflows are believed
  good (an identical earlier tree passed CI pre-outage); re-verify when
  GitHub recovers.

## Owner requirements of record

Confirmed with the project owner (2026-08-06):

1. Collapsed bar label summarizes **all** accounts; per-account detail in
   the dropdown; profiles always identified by name (`okf/02` §1–2).
2. Docs live in this OKF; all features planned up front (`okf/05`).
3. Security CI scans; CI-built verifiable releases (`okf/06`).
4. Easy installs — bash one-liner first, then cask and source (`okf/06`).
5. Easy updates with stable/beta channels (Sparkle 2) (`okf/06`).
6. Contribution pathway: Discussions, issue/PR templates, CONTRIBUTING
   (`okf/06`).
7. Visual design: Liquid Glass / native Apple (`okf/02` §5).
8. **7d Fable quota is the primary number** — leads the bar label; color
   still tracks the worst window (`okf/02` §1).
9. **No Apple affiliation, ever** — ad-hoc signing + sha256 + Sparkle
   EdDSA (`okf/06`). Final; do not re-raise.
10. The app doubles as the **Meridian uptime monitor** (`okf/02`).

## Near-term queue (in order)

1. When GitHub Actions recovers: confirm CI green on `main`, confirm the
   `v0.1.0` release run (artifact, appcast item, cask bump), then require
   CI-green in branch protection.
2. Verify the published pipeline end to end: `install.sh` against the
   real release, `brew install --cask jean-reinhold/tap/meridian-bar`,
   and a Sparkle update offer from v0.1.0 → next tag.
3. README staged screenshots (redacted data only).

## Owner actions pending

- None.

## Risks being tracked

- Meridian API drift between minors — tolerant decoding + fixtures
  (`okf/01`, tests).
- Unsigned distribution vs Gatekeeper — installer quarantine strip + cask
  caveats; integrity = sha256 + Sparkle EdDSA (`okf/06`).
- `TAP_PUSH_TOKEN` holds an OAuth token that rotates — the cask-bump step
  degrades to a skip with a notice; refresh the secret if it goes stale.
- Liquid Glass APIs are macOS 26+ — material fallback keeps min target at
  macOS 14 (`okf/02` §5).
