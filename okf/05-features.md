# Feature plan

The complete feature inventory. Each feature has an acceptance criterion —
a feature is *done* when the criterion is observable in the running app,
not when the code compiles. Milestones gate the order; nothing ships to
`main` half-implemented.

## Feature inventory

| # | Feature | Acceptance criterion | Milestone |
|---|---------|----------------------|-----------|
| F1 | **All-accounts menu bar label** — one colored segment per profile: `alias fable%` (e.g. `paul 100 · pnr 100 · rein 34`), primary window `seven_day_fable` with worst-window fallback, color by worst-window status | Label shows every configured profile with its primary-window %, colored by worst-window status, readable in light + dark menu bars | M1 |
| F2 | **Polling** — quota/profiles/health every 60 s + on menu open, stale-response protection | Usage change in Meridian visible in ≤ 60 s; opening the menu refreshes immediately | M1 |
| F3 | **Offline resilience** — Meridian down → gray `meridian off` label, last snapshot kept with data age | Killing Meridian degrades the label within one poll; restarting recovers without relaunching the app | M1 |
| F4 | **Per-account dropdown cards** — alias + full id, plan badge, active badge, auth state, exhausted banner; one bar per quota window with % and reset countdown; extra-usage credits row when enabled; rendered in the Liquid Glass design language (`02-product-spec.md` §5) | Every window Meridian reports for a profile renders as a bar with countdown; unknown window types render via fallback label; glass materials verified in light + dark, with the macOS 14 material fallback | M2 |
| F5 | **Profile switching** — button on inactive account cards → `POST /profiles/active` | Switching from the menu changes Meridian's active profile and the UI reflects it on the next refresh | M2 |
| F6 | **Health footer** — proxy status dot, Meridian version, data age, token-renewal warning when `renewalRequiredSoon` | Footer matches `/health` output; renewal warning appears when the flag is set | M2 |
| F7 | **Actions** — Refresh now, Open Meridian dashboard (default browser → base URL), Quit | Each action performs its effect from the dropdown | M2 |
| F8 | **Launch at login** — `SMAppService.mainApp` toggle | Toggle survives relaunch; app appears after logout/login when enabled | M3 |
| F9 | **Label styles** — `segments` (default), `dots` (colored ● per account), `worst` (single worst-case %) | Style switchable in settings; all three render correctly with 1–5 profiles | M3 |
| F10 | **Settings** — base URL (default `http://127.0.0.1:3456`), poll interval, label style, primary window (default `seven_day_fable`), per-profile alias overrides | Settings persist in `UserDefaults`; base URL change takes effect without relaunch | M3 |
| F11 | **Threshold notifications** — user notification when a window crosses warn/high, becomes exhausted, or resets after exhaustion; per-transition (never repeated) | Crossing 85% fires exactly one notification; reset of an exhausted window fires one "back" notification; toggleable in settings | M3 |
| F12 | **App icon + polish** — .icns, about panel, empty-state guidance when no profiles configured | App presents professionally in Finder/Spotlight; zero-profile state explains `meridian profile add` | M4 |
| F13 | **Release pipeline & security CI** — CodeQL + dependency review + OpenSSF Scorecard; CI-only release builds: universal binary, ad-hoc signed (no Apple identity), checksummed zip on tag | Security workflows green on `main`; `git tag vX.Y.Z` produces a runnable artifact with published sha256 (`okf/06`) | M4 |
| F14 | **Easy install** — `install.sh` bash one-liner (latest release, sha256 verify, quarantine strip, `/Applications`), plus Homebrew tap cask auto-bumped by the release workflow | `curl -fsSL …/install.sh \| bash` installs and launches the current release on a clean machine; `--uninstall` removes it | M4 |
| F15 | **In-app updates & channels** — Sparkle 2, EdDSA-signed appcasts (stable + beta) generated from GitHub Releases, channel toggle in Settings, "Check for updates…" action | A new stable tag is offered in-app; a `-beta` tag reaches only beta-channel users (`okf/06`) | M4 |
| F16 | **Contribution pathway** — CONTRIBUTING, issue/PR templates, PR checklist, GitHub Discussions, Code of Conduct, branch protection, seeded labels | A stranger can ask a question in Discussions and land a PR gated by green CI without maintainer hand-holding (`okf/06`) | M0 |

## Deliberately out of scope (v1)

- **Usage history / sparklines** — would require persisting samples or
  reading Meridian's `telemetry.db`; revisit once the live view proves out.
- **Cost estimation display** — Meridian computes API-equivalent cost
  per profile; a dropdown row is easy to add later but is telemetry, not
  quota, and belongs behind a settings flag.
- **Cross-device / remote Meridian** — v1 talks to loopback only; a
  configurable base URL exists (F10) but auth for remote instances is a
  separate design conversation.
- **Windows/Linux** — Meridian is cross-platform; this app is deliberately
  macOS-native. A tray port would be a separate project.

## Milestones

- **M0 — Public repo** (F16 + the OKF): the repo is publishable,
  secured (secret scanning, branch protection), and contributable
  *before* code lands.
- **M1 — Core** (F1–F3): usable on day one; the label alone answers "am I
  about to hit a wall, on any account".
- **M2 — Dropdown** (F4–F7): full per-account detail + control.
- **M3 — Comfort** (F8–F11): settings, styles, login item, notifications.
- **M4 — Ship** (F12–F15): v0.1.0 public release — polish, security CI,
  signed builds, easy installs, in-app updates.

Gate rule: each milestone ends with a smoke test against the live Meridian
instance (and, for F3, against a stopped one) recorded in `STATUS.md`.
