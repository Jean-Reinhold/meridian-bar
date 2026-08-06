# Contributing to MeridianBar

Questions and PRs are welcome. Questions go to
[Discussions](https://github.com/Jean-Reinhold/meridian-bar/discussions);
bugs and concrete feature proposals go to
[Issues](https://github.com/Jean-Reinhold/meridian-bar/issues). For
anything larger than a small fix, open an issue first so the approach is
agreed before you spend time on it.

## Project map

The project is documented in the [OKF knowledge base](okf/README.md) —
read `okf/README.md` for the index. The short version:

- `okf/01` — the Meridian API contract this app is built on
- `okf/02` — product spec (UI, states, design language)
- `okf/04` — architecture and the algorithms worth testing
- `okf/05` — feature inventory and milestones

If your change contradicts an OKF doc, update the doc in the same PR —
the OKF is living state, not history.

## Dev setup

macOS 14+ and Command Line Tools are enough — no Xcode required:

```sh
git clone https://github.com/Jean-Reinhold/meridian-bar
cd meridian-bar
make build   # swift build -c release + assemble dist/MeridianBar.app
make test    # unit tests (Swift Testing)
```

A running [Meridian](https://github.com/rynfar/meridian) instance on
`127.0.0.1:3456` is needed to see live data, but not to build or test.

## Expectations for a PR

- `make test` green; new logic in the pure-logic layer gets a test.
- Conventional commit messages (`feat:`, `fix:`, `docs:`, `ci:`).
- A `CHANGELOG.md` entry under *Unreleased* for user-visible changes.
- Screenshots for UI changes — with staged/redacted data only, never
  real account emails.
- No new dependencies without prior discussion in an issue
  (see `okf/03` — the dependency budget is deliberately near-zero).

Small, focused PRs get reviewed fast.
