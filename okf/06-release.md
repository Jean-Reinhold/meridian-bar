# Release, security, distribution & community

How the public repo stays professional, how builds are produced, how a
stranger installs — and stays current with — the app, and how they ask
questions or contribute. Requirements set by the project owner: **security
CI scans, proper (CI-built, verifiable) builds, easy installs, easy updates
with update channels, and a real contribution pathway.**

## Repo hygiene

- **MIT license** — matches Meridian's, no friction for contributors.
- **No personal data in-repo.** The OKF quotes API shapes with redacted
  emails (`*@example.com`) and generic profile ids where the real ones are
  not needed. README screenshots must use staged or redacted data — never a
  capture of the real menu with real account emails visible.
- **Conventional commits** (`feat:`, `fix:`, `docs:`) and a `CHANGELOG.md`
  kept from v0.1.0 on ([Keep a Changelog](https://keepachangelog.com) form).
- `SECURITY.md` with a private-report channel (GitHub security advisories).

## Contribution pathway — launch scope

People must be able to ask questions and open PRs from day one:

- **`CONTRIBUTING.md`**: dev setup (`make build` needs only
  CommandLineTools), project map (point at the OKF), test expectations
  (`make test` green, new logic in `UsageLogic` gets a test), commit
  convention, and the review promise (small PRs reviewed fast; open an
  issue first for anything larger than a fix).
- **Issue templates** (`.github/ISSUE_TEMPLATE/`): `bug_report.yml` (asks
  for macOS + Meridian versions and `curl /health` output), and
  `feature_request.yml`. `config.yml` routes questions to Discussions
  instead of issues.
- **PR template**: what/why, screenshot for UI changes, checklist (tests
  pass, CHANGELOG entry, no personal data in fixtures/screenshots).
- **GitHub Discussions** enabled — the "ask" channel (Q&A + Ideas
  categories), keeping the issue tracker actionable.
- **Code of Conduct**: Contributor Covenant, stock.
- **Labels**: `good first issue` and `help wanted` seeded from the feature
  backlog (`okf/05`) so newcomers have an entry point.
- Branch protection on `main`: PRs only, CI green required.

## Security CI

- **CodeQL** (`github/codeql-action`, Swift language pack) on push, PR, and
  a weekly schedule — static analysis of the app code.
- **Secret scanning + push protection** enabled on the repo (GitHub-side
  setting, free for public repos).
- **Dependency review action** on PRs. The package graph is near-empty by
  design (`okf/03`); this guards the future — any PR that introduces a
  dependency gets its advisories surfaced in review.
- **Actions supply chain:** all workflow actions pinned to full commit SHAs,
  `permissions:` blocks scoped read-only by default, release workflow the
  only one with `contents: write`.
- **OpenSSF Scorecard** workflow + badge once the repo is public — cheap,
  and it audits the settings above continuously.

## Proper builds

- **Releases are built by CI only** — never from a laptop. `release.yml`
  triggers on tag `v*`: build, test, assemble, sign, notarize, staple, zip,
  attach to a GitHub Release with generated notes, update the appcast and
  the Homebrew tap.
- **Universal binary**: `swift build -c release` for `arm64` + `x86_64`,
  `lipo` into one executable, so Intel Macs are covered.
- **Version stamping**: `CFBundleShortVersionString` injected from the git
  tag at bundle assembly — the binary always knows what release it is.
- **Checksums**: `shasum -a 256` of the zip published in the release notes;
  the Homebrew cask pins the same hash.
- `ci.yml`: on push/PR — release-config build + tests on `macos-latest`.
  The runner ships full Xcode, so CI also guards against "works only with
  CommandLineTools quirks" drift (`okf/03` risk).

## Signing & notarization — required, not optional

Easy installs and in-app updates make this launch scope: an unsigned app
means Gatekeeper warnings or `--no-quarantine` workarounds, and Sparkle
updates require a stable signing identity across versions.

- Developer ID Application certificate + `codesign --options runtime`
  (hardened runtime), then `notarytool submit --wait` and `stapler` in
  `release.yml`. Cert/keys live in GitHub Actions secrets.
- **Owner prerequisite:** an Apple Developer Program membership
  (US$99/yr) to issue the Developer ID cert. Until it exists, releases
  ship unsigned with a README caveat and the cask carries
  `--no-quarantine` guidance — explicitly marked temporary.

## Easy installs

Priority order for someone who finds the repo:

1. **Homebrew cask** (primary): `brew install --cask jean-reinhold/tap/meridian-bar`
   via a `homebrew-tap` repo under the same account. Cask formula updated by
   `release.yml` (commit to the tap with the new version + sha256); marked
   `auto_updates true` once Sparkle ships so brew doesn't fight the in-app
   updater. Submission to `homebrew/cask` mainline once the app has
   users/stars — mainline has notability requirements a day-one project
   doesn't meet.
2. **Release zip**: notarized `MeridianBar.app` — download, unzip, drag to
   `/Applications`. Linked prominently in the README.
3. **From source**: `git clone && make install` for developers.

## Easy updates & channels

- **In-app updates via [Sparkle 2](https://sparkle-project.org)** — the
  macOS standard: background check, one-click install, EdDSA-signed
  payloads on top of notarization. Sparkle is the **single sanctioned
  exception** to the no-dependency rule (`okf/03`): update plumbing is
  exactly the code you don't hand-roll, for security reasons.
- **Channels:** `stable` and `beta`. GitHub Releases is the source of
  truth — a pre-release tag (`v0.3.0-beta.1`) publishes only to the beta
  appcast; a full release publishes to both. Two `appcast.xml` files
  generated by `release.yml` (Sparkle's `generate_appcast`) and hosted on
  GitHub Pages of this repo. Channel selection is a Settings toggle
  (default: stable).
- **Fallbacks:** cask users can always `brew upgrade --cask meridian-bar`;
  zip users get Sparkle like everyone else. A "Check for updates…" menu
  item triggers Sparkle manually.
- The Sparkle EdDSA private key lives in GitHub Actions secrets alongside
  the signing cert; the public key ships in `Info.plist`.

## Versioning

SemVer. v0.1.0 = M1+M2 complete (label + dropdown usable daily). v1.0.0 =
M4 shipped and the API-drift risk (`okf/01` §stability) has survived at
least one Meridian minor release without breakage.
