# Stack decision record

## Decision

Native **Swift 6 + SwiftUI `MenuBarExtra`**, built with **SwiftPM + a
Makefile** that assembles the `.app` bundle. Third-party dependencies:
**exactly one sanctioned exception — Sparkle 2** for in-app updates (M4,
rationale in `okf/06`); everything else is OS frameworks. Minimum target
**macOS 14** (Sonoma), with Liquid Glass APIs adopted behind availability
checks (`02-product-spec.md` §5).

## Why

The app is a label and a popover fed by a localhost JSON poll. Its entire
value is being *invisible* when not looked at — footprint is the product.

| Option | Idle RAM | Deps to maintain | Verdict |
|---|---|---|---|
| Swift + `MenuBarExtra` | ~15–30 MB | none (URLSession, Codable, SMAppService are OS) | **chosen** |
| Tauri | ~80 MB+ | Rust toolchain + webview + npm | webview for a native menu is backwards |
| Electron | ~200 MB+ | node + chromium | disqualified on footprint alone |
| Python + rumps | ~60 MB | Python runtime on user machines | not distributable as a clean `.app` |
| Swift + AppKit `NSStatusItem` (no SwiftUI) | same as chosen | none | more code for the same result; `MenuBarExtra` window-style gives us real progress bars in the dropdown for free |

- `MenuBarExtra` (macOS 13+) with `.menuBarExtraStyle(.window)` renders
  arbitrary SwiftUI in the dropdown — required for per-window progress
  bars and account cards. Plain `NSMenu` items cannot do this cleanly.
- `SMAppService.mainApp` (macOS 13+) gives launch-at-login with no helper
  bundle.
- API layer is `URLSession` + `Codable` against the contract in
  `01-meridian-surface.md`. No HTTP library earns its keep for four GET/POST
  endpoints on loopback.
- **Liquid Glass**: `.glassEffect()` / `GlassEffectContainer` are
  macOS 26+ APIs — every use sits behind `#available(macOS 26.0)` with an
  `.ultraThinMaterial` fallback so the macOS 14 target holds. The dev
  machine runs 26.5, so the primary look is testable locally.
- **Sparkle 2** arrives only in M4 via SPM, pinned to an exact version;
  until then `Package.swift` has an empty dependency array and CI's
  dependency-review job proves it stays that way.

## Build-system constraints (verified on the dev machine)

- Toolchain: Apple Swift **6.3.2** via Command Line Tools only
  (`xcode-select -p` → `/Library/Developer/CommandLineTools`); no full
  Xcode assumed. *(verified 2026-08-06)*
- Therefore: **no `.xcodeproj` in the repo.** SwiftPM executable target +
  `make app` assembles `MeridianBar.app/Contents/{MacOS,Info.plist,Resources}`
  by hand. This is a well-trodden pattern for menu bar apps and keeps the
  repo reviewable.
- `Info.plist` essentials: `LSUIElement = true` (no Dock icon, no app
  switcher), `NSHumanReadableCopyright`, bundle id
  `com.jeanreinhold.MeridianBar`. App Transport Security: loopback HTTP is
  exempt by default (`NSAllowsLocalNetworking` only if a non-loopback base
  URL is ever configured — it is not in v1).
- Tests use **Swift Testing** via `make test`. Under bare CLT the Testing
  framework lives outside the default search paths
  (`CLT/Library/Developer/Frameworks` + `…/usr/lib` for
  `lib_TestingInterop.dylib`), so the Makefile injects `-F`/`-rpath`
  flags — gated on `xcode-select -p`, so Xcode/CI builds are untouched.
  *(verified 2026-08-06: 11/11 tests pass locally)*
- **Host defect encountered & fixed (2026-08-06):** orphaned Feb-2024
  `PackageDescription.swiftmodule/*.private.swiftinterface` files (owned
  by no installed pkg) shadowed the current interface and broke *every*
  SwiftPM manifest compile. Fix: CLT 26.6 reinstall + moving the orphans
  to `*.orphaned2024.bak`. Symptom to recognize: undefined
  `swiftLanguageVersions` `Package.init` symbol at manifest link.
- CI (GitHub Actions `macos-15`) has full Xcode; it runs the same
  `make app` + `swift test` path as local, so local CLT is the constraining
  environment by design.

## Concurrency model

Swift 6 strict concurrency on. One `@MainActor @Observable` store; the
poll loop is a structured `Task` owned by the store; `MeridianClient` is a
stateless `Sendable` struct. No locks, no combine, no notification
spaghetti — state flows one way: client → store → views.

## Risks

- **R1 — colored label rendering.** Menu bar items template-render images
  by default, stripping color. Mitigation chosen: draw the label as a
  non-template `NSImage` via the block-based drawing handler so dynamic
  `NSColor`s resolve at display time (adapts to light/dark). Must be
  validated on-device in M1; fallback is a monochrome label with
  `●▲■` health glyphs. Gate: G1.
- **R2 — SwiftUI under bare CLT.** `swift build` linking SwiftUI works
  with the CLT SDK, but is less traveled than Xcode builds. **Resolved:**
  release build + test suite verified locally 2026-08-06 (see build
  constraints above for the two host quirks encountered).
- **R3 — `MenuBarExtra` label refresh cadence.** Label views re-render on
  `@Observable` change; if the image swap flickers, throttle label updates
  to actual content changes (equatable segment model).
