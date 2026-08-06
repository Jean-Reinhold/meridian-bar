# MeridianBar

A native macOS menu bar app that shows Claude usage for **every account** managed by
[Meridian](https://github.com/rynfar/meridian) — at a glance, without clicking.

```
┌──────────────────────────────────────────────┐
│  … 🌐 ⌁ paul 91 · pnr 52 · rein 32   ⏰ 14:32 │   ← menu bar: one segment per account,
└──────────────────────────────────────────────┘      colored by quota pressure
```

Meridian multiplexes several Claude Max accounts behind one local endpoint. What it
doesn't give you is ambient awareness: which account is close to a rate-limit window,
which one is exhausted, and when the windows reset. MeridianBar puts that in the menu
bar — per-account, identified, always visible.

## Features

- **All accounts in the bar** — one compact segment per profile (auto-abbreviated
  name + worst-window utilization), colored green/yellow/red with Meridian's own
  thresholds. No click needed to know where you stand.
- **Per-account detail on click** — every quota window (5h, 7d, 7d Fable, …) as a
  bar with percentage and reset countdown; email, plan, active/exhausted badges.
- **Switch profiles** from the dropdown (`POST /profiles/active`).
- **Zero dependencies, native SwiftUI** — a single `LSUIElement` agent app; idle
  footprint in the tens of MB, no Electron, no webview, no runtime.
- **Offline-graceful** — Meridian down? Last data stays visible, grayed, with an
  offline marker. The app never nags and never crashes on a dead socket.

## Status

Planning/early development. The design and full feature plan live in
[`okf/`](okf/README.md) — the project's knowledge base (verified Meridian API
surface, product spec, stack decision, architecture, feature inventory, release
plan).

## Requirements

- macOS 14+
- [Meridian](https://github.com/rynfar/meridian) running locally (default
  `127.0.0.1:3456`; configurable)

## Building

```bash
make build     # swift build -c release + assemble MeridianBar.app
make install   # copy to /Applications
make test      # unit tests
```

Builds with the plain Swift toolchain (Command Line Tools are enough; no Xcode
project file).

## License

MIT — see [LICENSE](LICENSE).
