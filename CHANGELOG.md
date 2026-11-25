# Changelog

All notable changes to MeridianBar. Format follows
[Keep a Changelog](https://keepachangelog.com); versions follow SemVer.

## [Unreleased]

### Added

- Fable route display. When the base URL points at a model router, the bar
  marks the account that serves Fable requests with an `F<percent>%` suffix
  showing its weekly Fable usage. Its card gets a FABLE badge, and the
  dropdown names the Fable account. Plain Meridian shows no change.
- Weekly subscription pacing from overall seven-day usage and time until reset.
  Menu bar arrows show room to use more, an even pace, or usage ahead of pace.
  Account cards show unused quota, reset time, and a daily or hourly budget.
  Cached readings are marked as estimates and omit menu bar pace arrows.
- Accounts window for Claude accounts: Meridian profiles and the default CLI
  login. Add, sign in again, switch, sign out, and remove, all through the
  official `meridian` and `claude` commands.
- `--render-preview` also renders `accounts.png` and a light dropdown.

### Changed

- Claude menu bar percentages default to overall `seven_day` usage instead of
  `seven_day_fable`. A missing selected window stays unknown rather than
  substituting another quota. Worst-window warning colors remain unchanged.
- The dropdown is wider (420 pt) and scrolls; an Accounts… button opens the
  new window.

### Removed

- Codex and OMP support: the Codex card, the `Codex NN%` bar segment, Codex
  accounts, and OMP OpenAI routing. MeridianBar shows Claude only and talks
  to nothing but the Meridian endpoint. These features never shipped in a
  release. The app no longer reads or writes Codex logins. Earlier dev
  builds saved copies under
  `~/Library/Application Support/MeridianBar/CodexAccounts`; delete that
  folder by hand if you no longer need it.
- The five-hour limit from the weekly budget caption, which now reads
  "Planning guide only. Model limits still apply." Max accounts no longer
  report a five-hour window. A `five_hour` window still renders as `5h` if
  Meridian returns one again.

### Fixed

- The usage popover no longer collapses its scroll area when opened.
- Claude profiles with missing credentials show `login` in the bar and a
  sign-in explanation in the card. Quota errors and empty data also have
  explicit messages.
- The Accounts window no longer opens by itself: it was declared as a
  SwiftUI `Window` scene, which macOS opens at launch as the app's main
  window and brought to front when the bar was clicked, hiding the usage
  dropdown. It is now an explicit window opened only from "Accounts…".

## [0.1.0] - 2026-08-06

### Added

- All-accounts menu bar label: one colored segment per Meridian profile,
  7d Fable utilization as the leading number, color driven by each
  account's worst quota window; active profile underlined.
- Per-account dropdown cards: every quota window as a bar with percentage
  and reset countdown, email, plan, active/exhausted/login badges,
  extra-usage credits; Liquid Glass styling on macOS 26+ with material
  fallback down to macOS 14.
- Profile switching from the dropdown.
- Meridian uptime monitoring: gray offline marker within one poll,
  automatic recovery, last-known data kept with its age.
- Settings: Meridian URL, poll interval, label style (segments / dots /
  worst), primary window, per-profile name overrides, notifications.
- Threshold notifications: one per transition (60%, 85%, exhausted,
  reset), no repeats.
- Launch at login, About panel, app icon.
- Sparkle in-app updates with stable and beta channels.
- `install.sh` one-liner installer with sha256 verification.

[Unreleased]: https://github.com/Jean-Reinhold/meridian-bar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Jean-Reinhold/meridian-bar/releases/tag/v0.1.0
