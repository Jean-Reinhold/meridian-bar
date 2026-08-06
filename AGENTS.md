# AGENTS.md — working on MeridianBar

MeridianBar is a native macOS menu bar app showing Claude usage for every
account managed by a local [Meridian](https://github.com/rynfar/meridian)
proxy, and doubling as its uptime monitor.

## Source of truth

`okf/README.md` indexes the knowledge base — read it first; it defines the
reading order and the evidence conventions. `okf/STATUS.md` is the living
log: current state, the near-term queue, and the **owner requirements of
record** (settled decisions — do not re-litigate them). Update STATUS when
a milestone lands, a decision is made, or verified facts change.

Never code against a Meridian endpoint or field not recorded (and dated)
in the OKF; if you verify a new one against a live instance, record it
there first.

## Build & test

Command Line Tools only — no Xcode, no `.xcodeproj`:

```
make build      # swift build -c release
make test       # swift test (Swift Testing, not XCTest)
make app        # assemble dist/MeridianBar.app (ad-hoc signed)
make run        # build + open the bundle
```

## Conventions

- Swift 6 strict concurrency. State flows one way: `MeridianClient`
  (stateless, `Sendable`) → `UsageStore` (`@MainActor @Observable`) →
  views. No other state carriers.
- All computation (aliases, thresholds, countdowns, segments) lives in
  `UsageLogic` as pure functions — **every change there needs a test** in
  `Tests/MeridianBarTests`.
- Decoding is tolerant: every non-id field optional; unknown quota window
  types must render via the label fallback, never crash or be filtered.
- Dependency policy, thresholds, and design language are set in the OKF —
  check it before adding anything.
- Conventional commits (`feat:`, `fix:`, `docs:`, `ci:`).
- **No personal data** — no real emails, tokens, or account values in
  code, fixtures, screenshots, or docs. Redact to `*@example.com`.

## Verification

- Unit tests must pass: `make test`.
- Behavior changes are smoke-tested against the live proxy at
  `http://127.0.0.1:3456` (`curl -s /health` to check it's up) and, for
  offline paths, with Meridian stopped. Record milestone smoke tests in
  `okf/STATUS.md`.
- UI changes: run `make run` and look at the menu bar in light and dark
  appearance before claiming done.
