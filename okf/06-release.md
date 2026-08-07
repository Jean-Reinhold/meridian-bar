# Release, security, distribution & community

How the public repo stays professional, how builds are produced, how a
stranger installs — and stays current with — the app, and how they ask
questions or contribute. Owner requirements of record: **security CI
scans, proper (CI-built, verifiable) builds, easy installs (bash
one-liner first), easy updates with update channels, a real contribution
pathway, and — decided 2026-08-06 — no Apple affiliation of any kind:
no Developer Program, no signing certificates, no notarization.**

## Repo hygiene

- **MIT license** — matches Meridian's, no friction for contributors.
- **No personal data in-repo.** The OKF quotes API shapes with redacted
  emails (`*@example.com`) and generic profile ids where the real ones are
  not needed. README screenshots must use staged or redacted data — never a
  capture of the real menu with real account emails visible.
- **Conventional commits** (`feat:`, `fix:`, `docs:`) and a `CHANGELOG.md`
  kept from v0.1.0 on ([Keep a Changelog](https://keepachangelog.com) form).
- `SECURITY.md` with a private-report channel (GitHub security advisories).

## Contribution pathway — shipped in M0

- `CONTRIBUTING.md`, issue forms (`bug_report.yml`, `feature_request.yml`),
  Discussions routing (`config.yml`), PR template with checklist,
  Contributor Covenant, `SECURITY.md`.
- GitHub Discussions enabled; secret scanning + push protection,
  dependency alerts, private vulnerability reporting enabled.
- Branch protection on `main`: PRs required (owner bypass allowed until CI
  exists; CI-green becomes required once `ci.yml` lands).
- Labels `good first issue` / `help wanted` seeded from the backlog as
  issues get filed.

## Security CI

- **CodeQL** (`github/codeql-action`, Swift language pack) on push, PR, and
  a weekly schedule — static analysis of the app code.
- **Dependency review action** on PRs. The package graph is near-empty by
  design (`okf/03`); this guards the future — any PR that introduces a
  dependency gets its advisories surfaced in review.
- **Actions supply chain:** all workflow actions pinned to full commit SHAs,
  `permissions:` blocks scoped read-only by default, release workflow the
  only one with `contents: write`.
- **OpenSSF Scorecard** workflow + badge — cheap, audits the repo settings
  continuously.

## Proper builds

- **Releases are built by CI only** — never from a laptop. `release.yml`
  triggers on tag `v*`: build, test, assemble the bundle, **ad-hoc sign**
  (`codesign -s -` — a stable identity for Sparkle delta/validation
  purposes, not an Apple identity), zip, attach to a GitHub Release with
  generated notes, update the appcasts and the Homebrew tap.
- **Universal binary**: `swift build -c release` for `arm64` + `x86_64`,
  `lipo` into one executable, so Intel Macs are covered.
- **Version stamping**: `CFBundleShortVersionString` injected from the git
  tag at bundle assembly — the binary always knows what release it is.
- **Checksums**: `shasum -a 256` of the zip published in the release notes;
  the installer script and the Homebrew cask pin/verify the same hash.
- `ci.yml`: on push/PR — release-config build + tests on `macos-latest`.

## No Apple affiliation — consequences, owned deliberately

Unsigned (ad-hoc) apps are quarantined by Gatekeeper when downloaded via a
browser. We route around it honestly instead of paying Apple:

- The **bash installer** downloads with `curl` and strips the quarantine
  attribute (`xattr -dr com.apple.quarantine`) after verifying the sha256
  against the release notes — the user runs one command and the app opens.
- The **Homebrew cask** ships `--no-quarantine` guidance in its caveats.
- The README states plainly: *this app is not signed with an Apple
  certificate; install via the script, brew, or build from source — the
  integrity check is the published sha256 + Sparkle's EdDSA, not
  Gatekeeper.*
- Sparkle 2 handles unsigned bundles: update integrity comes from the
  **EdDSA-signed appcast** (key in GitHub Actions secrets, public key in
  `Info.plist`); Sparkle requires only that the signing state (ad-hoc)
  stays consistent across versions — CI guarantees that.

## Easy installs

Priority order for someone who finds the repo:

1. **Bash one-liner** (primary, owner requirement):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Jean-Reinhold/meridian-bar/main/install.sh | bash
   ```

   `install.sh` (versioned in-repo, reviewable): resolves the latest
   GitHub Release via the API, downloads the zip, **verifies sha256**,
   installs to `/Applications` (or `~/Applications` without sudo), strips
   quarantine, launches the app. Flags: `--version vX.Y.Z`,
   `--from-source` (clone + `make install`, needs CLT), `--uninstall`.
   No sudo unless `/Applications` needs it; never touches anything outside
   the app bundle and its own defaults domain.
2. **Homebrew cask**: `brew install --cask jean-reinhold/tap/meridian-bar`
   via a `homebrew-tap` repo; formula auto-bumped by `release.yml`,
   `auto_updates true` once Sparkle ships. The tap repo is linked as the
   `tap/` submodule in the main repo for visibility (added 2026-08-07);
   its pinned commit may lag releases since the workflow pushes to the tap
   directly — refresh with `git submodule update --remote tap`.
3. **From source**: `git clone && make install` for developers.

## Easy updates & channels

- **In-app updates via [Sparkle 2](https://sparkle-project.org)** — the
  single sanctioned dependency (`okf/03`): background check, one-click
  install, EdDSA-signed payloads. No Apple involvement required.
- **Channels:** `stable` and `beta`. GitHub Releases is the source of
  truth — a pre-release tag (`v0.3.0-beta.1`) publishes only to the beta
  appcast; a full release publishes to both. Two `appcast.xml` files
  generated by `release.yml` (Sparkle's `generate_appcast`), hosted on
  GitHub Pages. Channel selection is a Settings toggle (default: stable).
- **Fallbacks:** `brew upgrade --cask`, re-running the install one-liner
  (idempotent), or the "Check for updates…" menu item.

## Versioning

SemVer. v0.1.0 = M1+M2 complete (label + dropdown usable daily). v1.0.0 =
M4 shipped and the API-drift risk (`okf/01` §stability) has survived at
least one Meridian minor release without breakage.
