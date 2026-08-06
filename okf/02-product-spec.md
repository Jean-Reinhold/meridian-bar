# Product spec

What MeridianBar shows and how it behaves. The design premise, confirmed
with the primary user: **the collapsed menu bar item summarizes all
accounts at once; the dropdown gives full per-account detail; profiles are
always identified by name, never anonymous.** Two later owner decisions
(2026-08-06): the **7d Fable window is the number that matters most** —
it leads everywhere a single number is shown — and the app doubles as the
**Meridian uptime monitor**: the bar must answer "is the proxy up?" at a
glance, at all times.

## 1. Menu bar label (collapsed state)

One compact segment **per profile**, in Meridian's `profileOrder`:

```
paul 91 · pnr 52 · rein 32
```

- **Identifier** — a short alias derived from the profile id (see
  `04-architecture.md` §3). Falls back to the raw id truncated to 4 chars.
  User-overridable per profile in Settings.
- **Number** — the profile's **primary window** utilization as an integer
  percent. Primary window defaults to `seven_day_fable` (owner decision:
  the Fable quota is the binding constraint that matters); configurable in
  Settings (F10). Profiles without the primary window fall back to their
  **worst** window. The dropdown always shows every window regardless.
- **Color** — always driven by the profile's **worst** window, never just
  the primary: the label may *show* Fable, but it must never look green
  while another window is blocking requests.
- **Thresholds** — Meridian's own, so both UIs
  agree: normal < 60% (primary label color), warn ≥ 60% (yellow),
  critical ≥ 85% (red). A profile listed in `exhausted[]` or with any
  `rejected` window renders red regardless of the number.
- **Active profile** — its segment is underlined (or bold), so routing
  state is visible without opening the menu.
- **Offline** — Meridian unreachable: label collapses to a single gray
  `meridian ⏻` segment. No stale numbers in the bar; stale detail is
  still available in the dropdown (§2.4).
- Rendered as a non-template `NSImage` so per-segment color survives the
  menu bar (see `04-architecture.md` §4). Label must stay legible in
  light and dark menu bars.

Label style is configurable (Settings, F10): `segments` (default, above),
`dots` (`● ● ●` color-only, minimal width), `worst` (single worst-case
percent across all accounts, for tight menu bars).

## 2. Dropdown (open state)

SwiftUI window-style `MenuBarExtra` content, ~320 pt wide, sections top to
bottom:

### 2.1 Account cards — one per profile, in `profileOrder`

Header row:
- Alias + full profile id (e.g. **paul** `jeanpaul`), email underneath in
  secondary text.
- Badges: `ACTIVE` (blue) on the routed profile; plan type (`max`);
  `EXHAUSTED` (red) when in `exhausted[]`; `⚠ login required` (yellow)
  when `loggedIn == false`.

Body — one row per quota window, every window the API returns (dynamic,
never a hardcoded set):
- Window label from the shared label map (`5h`, `7d`, `7d Fable`, …) with
  title-case fallback for unknown types.
- Progress bar tinted by the same threshold colors as the bar label.
- Percent + reset countdown: `91% · resets in 8h 05m`. A `rejected`
  window shows `blocked` in red next to the percent.
- Extra-usage row when `extraUsage.isEnabled`: `$used / $limit` with its
  own bar.

Footer of each card:
- `Switch to <alias>` button on inactive profiles → `POST /profiles/active`,
  then immediate re-poll. Active card shows no button.
- Data age: `updated 12s ago` from `fetchedAt`.

### 2.2 Health footer

- Meridian status dot (healthy / degraded / offline) + version.
- OAuth renewal warning when `renewalRequiredSoon` is true:
  `token renewal needed in Nd`.
- Last successful poll time.

### 2.3 Actions row

- **Refresh now** — immediate poll.
- **Open dashboard** — `open http://127.0.0.1:3456/`.
- **Settings…** — see F10.
- **Launch at login** toggle (`SMAppService`).
- **Quit**.

### 2.4 Degraded states

| State | Bar | Dropdown |
|---|---|---|
| Meridian down | gray `meridian ⏻` | last-known cards grayed + banner "Meridian is not responding — showing data from HH:MM", Retry button |
| Meridian up, quota fetch failing | segments from last data, dimmed | cards + per-profile error note (`error` field) |
| Profile `no_token` | segment gray `login` | card shows "Run `claude login`" hint |
| First launch, no data yet | `meridian …` | spinner |

Never a crash, never a modal, never a notification unless F9 opted in.

## 3. Refresh model

- Poll `/v1/usage/quota/all` + `/profiles/list` every 60 s (configurable),
  `/health` piggybacked every poll.
- Immediate poll on: menu open, profile switch, wake from sleep
  (`NSWorkspace.didWakeNotification`), Refresh button.
- Timeout 5 s; failures flip to degraded state after 2 consecutive misses
  (one blip must not flap the bar).

## 4. Explicit non-goals (v1)

- No historical charts (candidate F12, needs `telemetry.db` — see
  `05-features.md`).
- No management of Meridian itself (start/stop/login flows) beyond
  deep-linking to the dashboard; MeridianBar is read-mostly, the only
  mutation is profile switching.
- No network access other than the loopback Meridian endpoint. This is a
  privacy guarantee worth stating in the README, not just an
  implementation detail.


## 5. Design language — Liquid Glass, system-first

Owner direction: the app should feel like Apple built it — Liquid Glass,
not a webview pastiche of it. The discipline: **stock system materials and
type everywhere; exactly one custom element.**

- **Panel.** The dropdown is a floating glass panel: window-style
  `MenuBarExtra`, background `.glassEffect()` inside a
  `GlassEffectContainer` on macOS 26+, graceful fallback to
  `.ultraThinMaterial` behind `if #available` on macOS 14/15. No custom
  chrome, no borders — grouping comes from nested glass depth and spacing.
- **Signature element.** The per-window usage bar is a **liquid fill in a
  glass capsule**: a tinted translucent fluid that fills to the
  utilization level, with the threshold color glowing through the glass.
  This is the one bespoke visual; account cards, badges, buttons, and
  toggles are stock styles so the capsule reads as the identity.
- **Type.** System fonts only: SF Pro for labels, monospaced-digit
  variants for every number (percentages, countdowns) so the bar label and
  cards never jitter as values tick. Hierarchy via `foregroundStyle`
  vibrancy levels (primary/secondary/tertiary), not custom grays.
- **Color.** Semantic system colors exclusively — label colors for text,
  system yellow/red for thresholds, accent blue for `ACTIVE`. Health state
  is the *only* thing that gets color; everything else stays neutral so a
  red segment is unmissable.
- **Motion.** Two animations, both quiet: `.contentTransition(.numericText())`
  on changing percentages, and the liquid fill easing to its new level on
  refresh. Nothing on open/close beyond the system's own panel behavior.
- **Accessibility floor.** Honors Reduce Transparency (opaque surface
  fallback), Reduce Motion (fills snap instead of ease), Increase
  Contrast; every card exposes a single VoiceOver summary ("jeanpaul,
  active, seven day 91 percent, resets in 8 hours").