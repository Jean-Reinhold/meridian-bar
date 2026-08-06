# Status — 2026-08-06

Living log. Update on every meaningful state change; newest facts here win
over older docs until those docs are revised.

## State

- **Phase: M1+M2 implemented and smoke-tested live; CI landing.**
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
  health footer `Operational · Meridian 1.60.0`. Offline-path smoke test
  (Meridian stopped) still pending.
- Meridian surface verified live on 2026-08-06 against Meridian **1.60.0**
  (`okf/01`): `/v1/usage/quota/all`, `/profiles/list`, `/health`,
  `POST /profiles/active` all confirmed with real three-profile data.
- **Host toolchain quirk:** CLT 6.3.2 SwiftPM cannot compile *any*
  package manifest (PackageDescription dylib/interface mismatch —
  `swiftLanguageVersions` symbol missing at link). Even a trivial
  manifest fails; cache purge doesn't help; no Xcode.app installed.
  Workaround in-repo: `make build-direct` / `make app-direct` compile the
  dependency-free sources with plain `swiftc`. `swift test` therefore
  cannot run on this host — unit tests run in CI (macos-latest, full
  Xcode). Fix path if wanted: reinstall CLT.

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

1. Push code + CI (`ci.yml`, CodeQL, Scorecard, dependency review);
   confirm green; then require CI-green in branch protection.
2. Offline-path smoke test (stop Meridian, watch the label degrade,
   restart, watch it recover) — completes the M1 gate.
3. **M3 — comfort**: settings window, label styles, launch-at-login,
   notifications (`okf/05` F8–F11).
4. **M4 — ship**: icon/polish, release workflow, `install.sh`, Homebrew
   tap, Sparkle + channels (`okf/05` F12–F15, `okf/06`).

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
