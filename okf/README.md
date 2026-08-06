# OKF — Open Knowledge Framework

Versioned knowledge base for MeridianBar. Everything the project *knows* — the
verified Meridian API surface, the product decisions, the stack rationale, the
feature inventory, and the release plan — lives here as reviewable markdown, so
every line of code and every UI choice can be traced to a measurement or a
recorded decision.

## Reading order

1. `01-meridian-surface.md` — the verified Meridian HTTP API this app is built
   on: endpoints, live response shapes, semantics, thresholds, and the
   compatibility rules we must respect.
2. `02-product-spec.md` — what the app looks like and how it behaves: the
   all-accounts menu bar label, profile identification, the per-account
   dropdown, every UI state, and the Liquid Glass design language.
3. `03-stack.md` — stack decision record: native Swift/SwiftUI `MenuBarExtra`
   vs the alternatives, and the toolchain constraints that shape the build.
4. `04-architecture.md` — module map, data flow, polling model, the colored
   label rendering approach, and the profile-abbreviation algorithm.
5. `05-features.md` — the complete feature inventory (F1–F16), each with
   scope, acceptance criteria, and a milestone (M0–M4) assignment.
6. `06-release.md` — public-repo hygiene, the contribution pathway,
   security CI, CI-built signed releases, easy installs (Homebrew tap),
   and Sparkle update channels.

## Living status

- `STATUS.md` — where the project stands: what is decided, built, verified,
  and what's next. Updated as work lands.

## Conventions

- Every factual claim about Meridian carries either a capture from the live
  API (marked *verified YYYY-MM-DD, version*) or a `[unverified]` tag.
  Unverified claims may not drive code.
- When implementation lands, measured behavior replaces provisional design
  here — the OKF is living state, not a proposal frozen in time.
- The OKF records *why the world looks the way it does and what we decided*;
  the code and its doc comments record *how it's done*.
- No personal data in this repo: emails, tokens, and account-identifying
  values in captures are redacted to `*@example.com` / placeholders.
