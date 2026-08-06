# Status — 2026-08-06

Living log. Update on every meaningful state change; newest facts here win
over older docs until those docs are revised.

## State

- **Phase: M1+M2 complete — all smoke tests passed; CI verification in
  progress.**
- Published at <https://github.com/Jean-Reinhold/meridian-bar>
  (2026-08-06). Repo settings: Discussions, secret scanning + push
  protection, dependency alerts, private vulnerability reporting, branch
  protection on `main` (PRs; owner bypass until CI-green is required).
- Community files in place: CONTRIBUTING, SECURITY, Code of Conduct,
  issue templates + Discussions routing, PR template, AGENTS.md (F16).
- **M1+M2 smoke test PASSED (2026-08-06, live Meridian 1.60.0, 3
  profiles):** bar label rendered `rein 59 · paul 100 · pnr 100` with
  correct Fable-primary numbers, worst-window colors (red + underline on
  the active, blocked `paul`), non-template color rendering confirmed
  (risk R1 closed). Dropdown verified by owner screenshot: per-account
  cards, per-window bars + countdowns, `blocked` flags, switch buttons,
  health footer `Operational · Meridian 1.60.0`.
- **Offline-path smoke test PASSED (2026-08-06):** app pointed at a dead
  port (via `baseURL` default — live Meridian untouched); bar degraded to
  the gray `meridian ⏻` marker within two 5 s polls, and recovered to
  live colored segments (`rein 62 · paul 100 · pnr 100`) without a
  relaunch after the override was removed. Base URL is re-read every
  poll, so recovery needs no restart. Completes the M1 gate.
- Meridian surface verified live on 2026-08-06 against Meridian **1.60.0**
  (`okf/01`): `/v1/usage/quota/all`, `/profiles/list`, `/health`,
  `POST /profiles/active` all confirmed with real three-profile data.
- **Host toolchain quirk RESOLVED (2026-08-06):** the SwiftPM manifest
  failure was caused by orphaned Feb-2024 `.private.swiftinterface` files
  shadowing the fresh PackageDescription interface. Fixed by installing
  CLT 26.6 (`softwareupdate`) and moving the orphans to
  `*.orphaned2024.bak` (admin prompt, reversible). `swift build` and
  `make test` (11/11 green) now run locally; the `build-direct`
  workaround has been removed from the Makefile. Details: `okf/03`.

## Owner requirements of record

Confirmed with the project owner (2026-08-06):

1. Collapsed bar label summarizes **all** accounts; per-account detail in
   the dropdown; profiles always identified by name (`okf/02` §1–2).
2. Docs live in this OKF; all features planned up front (`okf/05`).
3. Security CI scans; CI-built verifiable releases (`okf/06`).
4. Easy installs for strangers — bash one-liner installer first, then
   cask and source (`okf/06`).
5. Easy updates with stable/beta channels (Sparkle 2) (`okf/06`).
6. Contribution pathway: Discussions, issue/PR templates, CONTRIBUTING
   (`okf/06`).
7. Visual design: Liquid Glass / native Apple (`okf/02` §5).
8. **7d Fable quota is the primary number** — leads the bar label and any
   single-number view; color still tracks the worst window (`okf/02` §1).
9. **No Apple affiliation, ever** — no Developer Program, no signing
   certs, no notarization; ad-hoc signing + sha256 + Sparkle EdDSA
   (`okf/06`). Decision is final; do not re-raise.
10. The app doubles as the **Meridian uptime monitor** (`okf/02` intro,
    §2.4) and is deployed now — implementation takes priority over
    further planning.

## Near-term queue (in order)

1. Confirm CI green (`ci.yml`, CodeQL, Scorecard, dependency review);
   then require CI-green in branch protection.
2. **M3 — comfort**: settings window, label styles, launch-at-login,
   notifications (`okf/05` F8–F11).
3. **M4 — ship**: icon/polish, release workflow, Homebrew tap, Sparkle +
   channels (`okf/05` F12–F15, `okf/06`); `install.sh` already in-repo.

## Owner actions pending

- None.

## Risks being tracked

- Meridian API drift between minors — mitigated by tolerant decoding +
  fixtures (`okf/01` §stability, tests in place).
- ~~Colored non-template label rendering (R1)~~ — **closed**, verified
  on-device 2026-08-06.
- SwiftUI-under-CLT (R2) — direct `swiftc` compile verified working; the
  SwiftPM manifest failure is a host-toolchain defect, tracked above.
- Liquid Glass APIs are macOS 26+ — material fallback keeps min target at
  macOS 14 (`okf/02` §5).
- Unsigned distribution vs Gatekeeper — routed around via installer
  quarantine strip + cask caveats; integrity = sha256 + Sparkle EdDSA
  (`okf/06`).
