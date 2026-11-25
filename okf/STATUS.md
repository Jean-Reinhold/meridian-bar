# Status as of 2026-11-14

Living log. Update on every meaningful state change; newest facts here win
over older docs until those docs are revised.

## State

- **2026-11-14 Fable route display.** MeridianBar now reads the optional
  `GET model-router/routes` endpoint (`okf/01`) with the other polls. Any
  failure, including plain Meridian's 404, hides the feature and never
  marks the app offline. `UsageLogic.segments` takes the Fable profile and
  sets `servesFable` and `fablePercent` from its `seven_day_fable` window.
  The `segments` label style appends ` F<percent>%` (or ` F–`) to that
  account; `dots` and `worst` are unchanged. Its card shows a FABLE badge,
  and a caption names the Fable account. New tests cover the marking, a
  missing Fable window, no route, and the label suffix. Plain Meridian
  1.88.0 answered 404 live on 2026-11-14 and the router on port 3457
  answered 200. Built with the macOS 26.5 SDK and passed 86 tests.
  Installed and relaunched `/Applications/MeridianBar.app` with `baseURL`
  set to `http://127.0.0.1:3457`. A native screenshot showed
  `rein 35%↑ F68% · paul 0%↑`, the FABLE badge, and the route caption in
  dark appearance. Light appearance was not checked.
- **2026-10-01 weekly usage and pacing.** Changed the primary Claude
  percentage from Fable to overall seven-day usage. Added pace arrows,
  unused quota, reset countdown, and remaining daily or hourly budgets.
  Missing weekly data stays unknown; cached estimates are identified.
  Built with the installed macOS 26.5 SDK and passed 82 tests.
  Installed and relaunched `/Applications/MeridianBar.app`.
  Native screenshots and accessibility inspection confirmed the weekly
  numbers, arrows, hourly budget, daily budgets, and cached-data warnings.
  Routing and quota limits were not changed.
- **2026-09-28 installed-app repair.** The owner requested an update and
  repair of the broken menu bar app. `/Applications/MeridianBar.app` still
  contained the older September 7 build, not the source's popover fix.
  Its live dropdown measured 420 × 107 pixels and hid the usage cards.
  Rebuilt the current source with Swift 6.4 and the installed macOS 26.5
  SDK, passed all 80 tests, replaced the installed bundle, and relaunched it.
  Code-signature verification passed. A live screenshot and accessibility
  inspection confirmed a 420 × 719 dropdown with usage bars, reset times,
  a sign-in explanation, and the Meridian 1.77.1 operational footer.
  The menu bar now shows `login` for the signed-out profile.
  Verification used the current dark appearance; light appearance was
  not checked during this installation repair. No app source change was needed.
  See `03-stack.md` for the SDK selection required on this host.
- **2026-09-07 popover fix, 80/80 tests passed:** the scroll view had only
  a maximum height, so `MenuBarExtra` could collapse it. A fixed 610 pt
  viewport keeps account cards visible and scrollable. Live Meridian
  1.60.0 returned `no_token` for one profile while the proxy was healthy.
  The bar now shows `login` for missing credentials or a signed-out profile.
  Cards explain missing credentials, API-key quota limitations, other quota
  errors, and empty data instead of leaving a blank body. Built and relaunched
  with `make run`; the owner reported testing the fix. Agent-side light/dark
  interaction checks were blocked by macOS Accessibility permission.
- **2026-09-07 follow-up (78/78 tests):** owner reported the bar click
  showing only accounts, no per-account bars or reset times. Cause: the
  Accounts `Window` scene in the app body — SwiftUI opens the first window
  scene at launch and on activation, so it sat over the dropdown. Replaced
  by `AccountsWindowController` (explicit `NSWindow`, opened only from the
  dropdown button). Second report, intermittent "quota unavailable":
  `wham/usage` is IP rate limited and OMP polls it as well; the client now
  fetches at most every 5 min (1 min retry after failure), serves the last
  good windows in between with no error banner, and only the dropdown
  Refresh button forces a fetch (`snapshot(forceQuota:)`).
- **2026-09-07 M5 implemented (F17–F19, 77/77 tests):** Codex card
  (ChatGPT quota from `wham/usage` + local token consumption from
  `$CODEX_HOME/sessions`), `Codex NN%` bar segment, Accounts window
  (Claude profiles + default CLI, Codex current + saved copies; add,
  sign in, switch, sign out, remove through `meridian`/`claude`/`codex`),
  and OMP routing (`omp auth-broker import|logout openai-codex`, pool read
  from `agent.db` read-only). New modules: `CodexUsageClient`,
  `CodexUsageCard`, `AccountManager`, `CLIProcess`, `AccountsView`,
  `OMPAccountSync`. Owner decisions recorded below (11–13). Smoke test
  2026-09-07 against live Meridian 1.60.0, Codex CLI, OMP 18.1.13: app
  launched, Codex quota fetched (HTTP 200), OMP pool read without any
  write, current Codex login recognized as already routed, previews
  rendered for dropdown (dark + light), accounts window, and label.
  Not yet exercised live: adding a second Codex account (needs a second
  ChatGPT login in the browser) and the OMP disconnect path; both are
  covered by scripted-runner tests only.
- **2026-08-07 Meridian rotation incident (operational, not app code):**
  user reported accounts not rotating. Root cause chain in Meridian 1.60.0:
  (1) `classifyError` didn't recognize the phrasing "You've reached your
  Fable 5 limit." → misclassified as `api_error` instead of
  `rate_limit_error`; (2) priority failover (`sniffQuotaFailure`) only
  triggers on `rate_limit_error` → rotation never fired; (3) sticky
  in-memory session pins kept conversations on the limited profile;
  (4) under `routing: "priority"` the `activeProfile` switch does not
  steer chat dispatch at all (source-verified, recorded in `okf/01`).
  Fixes applied: pool reordered via `PUT /settings/api/routing` to
  `[jeanpaul, jean_reinhold, jeanpnr]` (jeanpaul = only profile with
  headroom), `classifyError` patched in the installed dist to map
  "reached your … limit" → 429 `rate_limit_error` (backup at
  /tmp/cli-k1djafvr.js.bak; patch is local — upstream 1.60.0 is latest on
  npm, worth reporting), proxy kickstarted to load patch + clear pins.
  Verified: chat probe 200 in 2.6 s landing on `jeanpaul(priority)`.
- **Phase: M0–M4 implemented; v0.1.0 tagging in progress. CI/release
  verification pending a GitHub Actions outage (see below).**
- Published at <https://github.com/Jean-Reinhold/meridian-bar>. Repo
  settings: Discussions, secret scanning + push protection, dependency
  alerts, private vulnerability reporting, branch protection on `main`
  (PRs; owner bypass until CI-green is required).
- **2026-08-07 fix (API drift risk materialized):** Meridian 1.60.0 sends
  `profiles/list` `exhausted` entries as objects (`{id, until, reason}`)
  whenever a profile is actually rate-limited out; the app modeled
  `[String]`, the decode threw on every poll, and two misses flipped the
  bar to a false `meridian off` while the proxy was healthy. Fixed with
  `ExhaustedEntry` accepting both the object and legacy bare-string
  shapes (`okf/01` updated + dated). 18/18 tests; smoke-tested live
  against 1.60.0 with `jean_reinhold` genuinely exhausted.
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
8. Overall **7d usage is the primary number**, updated 2026-10-01.
   Weekly pacing also accounts for time until reset. Color still warns
   about the worst quota window.
9. **No Apple affiliation, ever** — ad-hoc signing + sha256 + Sparkle
   EdDSA (`okf/06`). Final; do not re-raise.
10. The app doubles as the **Meridian uptime monitor** (`okf/02`).
11. **Codex consumption in the bar** (2026-09-07): account-wide ChatGPT
    quota and local token counts, labeled as separate scopes; local
    counts are never shown as money.
12. **Account management from the bar** (2026-09-07): Claude and Codex
    accounts, including multiple OpenAI accounts, with sign-in from the
    bar. Official CLIs only; the app never talks to an OAuth token
    endpoint itself. This supersedes the v1 "read-mostly" non-goal in
    `okf/02` §4.
13. **OMP GPT traffic goes through the saved Codex accounts**
    (2026-09-07): OMP's `openai-codex` pool mirrors the accounts saved
    here (default on, toggle in Accounts). Meridian stays Claude-only; OMP's
    own pool is the OpenAI multiplexer.

## Near-term queue (in order)

1. When GitHub Actions recovers: confirm CI green on `main`, confirm the
   `v0.1.0` release run (artifact, appcast item, cask bump), then require
   CI-green in branch protection. If the outage swallowed the tag-push
   event (it swallowed two branch pushes), re-fire with
   `git push origin :v0.1.0 && git push origin v0.1.0`.
2. Verify the published pipeline end to end: `install.sh` against the
   real release, `brew install --cask jean-reinhold/tap/meridian-bar`,
   and a Sparkle update offer from v0.1.0 → next tag.
3. README screenshots — DONE 2026-08-06 via `--render-preview` (staged
   data, offscreen hosting-view snapshot; see `PreviewRenderer.swift`).

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
