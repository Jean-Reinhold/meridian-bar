# MeridianBar

A native macOS menu bar app that watches **every Claude account** managed by
[Meridian](https://github.com/rynfar/meridian) and your **OpenAI Codex**
usage — quota pressure per account, always visible, a live answer to "is the
proxy even up?", and one place to sign in, switch, and remove accounts.

<p align="center"><img src="docs/label.png" height="34" alt="Menu bar label — one colored segment per account: 7d Fable percent, active profile underlined, Codex worst-window percent"></p>
<p align="center"><img src="docs/dropdown.png" width="360" alt="Dropdown — Codex quota and local consumption, then per-account quota windows with reset countdowns, badges, and profile switching"></p>
<p align="center"><sub>Staged data — real accounts never appear in this repo.</sub></p>

Meridian multiplexes several Claude Max accounts behind one local endpoint.
What it doesn't give you is ambient awareness: which account is about to hit
a rate-limit window, which one is exhausted, when the windows reset — and
whether Meridian itself is running. MeridianBar puts all of that in the menu
bar, per account, identified by name. Since v0.2 it does the same for the
Codex CLI and lets [OMP](https://github.com/can1357/oh-my-pi) spread its GPT
requests across several OpenAI accounts.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Jean-Reinhold/meridian-bar/main/install.sh | bash
```

That's it — the script fetches the latest release, verifies its sha256,
installs to `/Applications`, and launches the app. Other options:

```bash
# Build and install from source (needs Command Line Tools, no Xcode)
curl -fsSL https://raw.githubusercontent.com/Jean-Reinhold/meridian-bar/main/install.sh | bash -s -- --from-source

# Remove it again
curl -fsSL https://raw.githubusercontent.com/Jean-Reinhold/meridian-bar/main/install.sh | bash -s -- --uninstall

# Or, from a clone
make install
```

> MeridianBar is ad-hoc signed, not Apple-notarized — a deliberate project
> decision (see [`okf/06`](okf/06-release.md)). Integrity comes from the
> published sha256, which the installer verifies. Sparkle in-app updates
> (stable/beta channels) ship in the app, and each release also publishes a
> Homebrew cask to our tap: `brew install --cask jean-reinhold/tap/meridian-bar`
> *(available once the first CI-built release lands)*.

### The `tap/` submodule

[`tap/`](tap) is a git submodule pointing at
[Jean-Reinhold/homebrew-tap](https://github.com/Jean-Reinhold/homebrew-tap),
the Homebrew tap our release workflow bumps on every tag. Homebrew requires
taps to live in a separate repo named `homebrew-tap` — the shorthand
`jean-reinhold/tap/...` hardcodes that lookup — so the cask can't live here
directly (details in [`okf/06`](okf/06-release.md)). The submodule exists for
visibility only: it is **not needed to build or run**, and a plain
`git clone` without `--recurse-submodules` is fine. The pinned commit can lag
the newest release (the workflow pushes to the tap repo directly); refresh it
with `git submodule update --remote tap`.

## What you see

- **In the bar** — one compact segment per profile: auto-abbreviated name +
  **7d Fable** utilization (the binding constraint for Fable-tier usage),
  colored by the *worst* window so it never looks green while something is
  blocking. The active profile is underlined. A `Codex NN%` segment follows
  when the Codex CLI is signed in. Meridian down → a gray `meridian ⏻`
  marker, within one poll.
- **On click** — an OpenAI Codex card first: every ChatGPT rate-limit window
  as a bar with percentage and reset countdown, then tokens recorded on this
  Mac (today and all time, read from local Codex session files; consumption,
  not a bill). Below it, per-account Claude cards: every quota window (5h,
  7d, 7d Fable, …), email, plan, active / exhausted / login-needed badges,
  extra-usage credits, and a health footer with Meridian's version and data
  age.
- **Accounts…** — Claude (Meridian profiles and the default CLI login) and
  Codex (current login and saved copies) side by side. Add an account and
  sign in from the browser, sign in again, switch, sign out, remove. Every
  change runs the official `meridian`, `claude`, or `codex` command; Codex
  sign-ins run in an isolated home so a cancelled sign-in never touches
  `~/.codex/auth.json`.
- **OMP routing** — with the toggle on (default), the Codex accounts saved
  here are imported into OMP's `openai-codex` credential pool, so OMP
  load-balances GPT requests across all of them. Removing or signing out an
  account drops it from OMP again; accounts OMP got elsewhere are left alone.
- **Native and light** — SwiftUI `MenuBarExtra`, no Electron, no webview;
  an `LSUIElement` agent app idling in the tens of MB. Network access is
  your loopback Meridian endpoint plus one fixed HTTPS endpoint
  (`chatgpt.com/backend-api/wham/usage`) for Codex quota, using the token
  the Codex CLI already holds. Nothing else.

## Requirements

- macOS 14+ (Liquid Glass look on macOS 26+, graceful material fallback below)
- [Meridian](https://github.com/rynfar/meridian) running locally
  (default `127.0.0.1:3456`, configurable)
- Optional: the `codex` CLI for Codex usage and accounts, `claude` for Claude
  sign-ins, `omp` for OMP routing. Missing tools disable their features and
  say so; nothing crashes.

## Developing

```bash
make build     # swift build -c release
make app       # assemble dist/MeridianBar.app
make run       # build + launch
make test      # unit tests
```

Plain Swift toolchain — Command Line Tools are enough; there is no Xcode
project. The design, verified Meridian API surface, feature plan, and all
decisions of record live in [`okf/`](okf/README.md). Contributions welcome —
see [CONTRIBUTING](CONTRIBUTING.md); questions go to
[Discussions](https://github.com/Jean-Reinhold/meridian-bar/discussions).

## License

MIT — see [LICENSE](LICENSE).
