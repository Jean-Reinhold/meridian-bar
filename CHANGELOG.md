# Changelog

All notable changes to MeridianBar. Format follows
[Keep a Changelog](https://keepachangelog.com); versions follow SemVer.

## [Unreleased]

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
