# Status — 2026-08-06

Living log. Update on every meaningful state change; newest facts here win
over older docs until those docs are revised.

## State

- **Phase: M0 complete — public repo live, pre-implementation.**
  OKF 01–06 written and internally consistent; no application code yet.
- Published at <https://github.com/Jean-Reinhold/meridian-bar>
  (2026-08-06). Repo settings applied: Discussions, secret scanning +
  push protection, dependency alerts, private vulnerability reporting,
  branch protection on `main` (PRs, no force push; owner bypass until CI
  exists — add the CI-green requirement when `ci.yml` lands).
- Community files in place: CONTRIBUTING, SECURITY, Code of Conduct,
  issue templates + Discussions routing, PR template (F16).
- Meridian surface verified live on 2026-08-06 against Meridian **1.60.0**
  (`okf/01`): `/v1/usage/quota/all`, `/profiles/list`, `/health`,
  `POST /profiles/active` all confirmed with real three-profile data.
- Toolchain verified: Swift 6.3.2 via CommandLineTools (no full Xcode
  selected), macOS 26.5.2, `gh` authenticated.

## Owner requirements of record

Confirmed with the project owner in planning (2026-08-06):

1. Collapsed bar label summarizes **all** accounts; per-account detail in
   the dropdown; profiles always identified by name (`okf/02` §1–2).
2. Docs live in this OKF; all features planned up front (`okf/05`).
3. Security CI scans; CI-built verifiable releases (`okf/06`).
4. Easy installs for strangers (cask + notarized zip) (`okf/06`).
5. Easy updates with stable/beta channels (Sparkle 2) (`okf/06`).
6. Contribution pathway: Discussions, issue/PR templates, CONTRIBUTING
   (`okf/06`).
7. Visual design: Liquid Glass / native Apple (`okf/02` §5).

## Near-term queue (in order)

1. **M1 — core**: Package.swift, client, store, logic, bar label with live
   data (`okf/05`).
2. **M2 — dropdown** per `okf/02` §2 + §5.
3. CI (`ci.yml` + security workflows), then require CI-green in branch
   protection.
4. M3/M4 per `okf/05`.

## Owner actions pending

- Decide on Apple Developer Program membership (US$99/yr) — gates
  signing/notarization, which gates frictionless installs and Sparkle
  (`okf/06`). Until then: unsigned releases with README caveat.

## Risks being tracked

- Meridian API drift between minors — mitigated by tolerant decoding +
  fixtures (`okf/01` §stability, `okf/04` tests).
- Colored non-template label rendering in the menu bar — validate first
  thing in M1; fallback design documented (`okf/04` §4).
- Liquid Glass APIs are macOS 26+ — material fallback keeps min target at
  macOS 14 (`okf/02` §5).
