# Contributing to MacEase

Thanks for your interest in MacEase. This guide explains how to propose changes
and what reviews look for.

## Ground rules

- Be respectful. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- **Never lose a user's file.** Any change that touches file handling must keep
  the commit model in [docs/SPEC.md](docs/SPEC.md) section 3.5 intact.
- **Source policy.** GPL, LGPL and AGPL sources may be read to study architecture
  and algorithms. Never copy, translate, adapt or incorporate their code into
  MacEase. Implement independently. Bundled dependencies must be permissively
  licensed, pinned and attributed. See [ADR 0013](docs/adr/0013-flect-style-menu-first-direction.md).
- AI-assisted contributions are welcome, but you must understand, test and stand
  behind every line you submit.

## Before you start

- **Bugs:** search existing issues, then open one with the bug template.
- **Features:** open a feature request first. MacEase keeps its Finder menu
  short, so new menu items need discussion before code.
- **Small fixes** (typos, translations, obvious regressions) can go straight to
  a pull request.

## Development setup

Requirements: a Mac with Apple Silicon, macOS 26 or later, Xcode 26 or later
(Xcode 27 for macOS 27 features), and Homebrew.

```sh
git clone https://github.com/TKY-27/MacEase.git
cd MacEase
make bootstrap   # tools, native dependencies, Xcode project
make build
make test
```

Debug builds are named "MacEase Dev" with their own bundle ID, so they can run
next to an installed release. Before first launch, copy the built app from
`build/DerivedData/Build/Products/Debug/MacEase Dev.app` to `~/Applications` or
`/Applications`; onboarding cannot continue while the app is outside those
folders. For example:

```sh
mkdir -p "$HOME/Applications"
ditto "build/DerivedData/Build/Products/Debug/MacEase Dev.app" "$HOME/Applications/MacEase Dev.app"
open "$HOME/Applications/MacEase Dev.app"
```

Then enable the "MacEase Dev" Finder extension in onboarding, or open System
Settings > General > Login Items & Extensions and enable it under Finder
Extensions.

The full list of commands is in [AGENTS.md](AGENTS.md#2-commands).

## Code style

- Swift API Design Guidelines and the repository's `.swift-format`.
- `make lint` must pass with zero warnings; builds treat warnings as errors.
- Comments explain why, never what, and stay short.
- No force unwraps, no dead code, no debug prints.

The complete rules are in [AGENTS.md](AGENTS.md#3-code-quality-rules) and apply
to human contributors too.

## Tests

- Add or update tests for every behavior change.
- Tests that need hardware encoders, Apple Intelligence or downloadable OS
  assets must probe the capability and skip only when it is missing.
- Never weaken or delete a test to make it pass.

## Pull requests

- One logical change per pull request.
- Conventional Commit messages in English (`feat(image): add AVIF quality setting`).
- Fill in the pull request template, including how you verified the change.
- Update `docs/SPEC.md` (with its Changelog and an ADR) if behavior or a decision
  changes, and `CHANGELOG.md` for user-visible changes.
- User-facing strings need English and Japanese entries in the String Catalogs.

## Releasing

1. Set `MARKETING_VERSION` in `project.yml` and prepare the matching changelog
   section. Keep unreleased work under `Unreleased` until ready to publish.
2. Run `make lint` and `make test-device`. Resolve failures before tagging.
3. Package with `MACEASE_SIGNING_KEYCHAIN=<unlocked-keychain> make dmg`, using
   the existing **MacEase Release** identity. Never recreate an existing identity
   for a routine release. Inspect the DMG, signatures, Finder entitlements,
   bundled resources and notices, and verify its `.sha256` file.
4. Complete the [manual release checklist](docs/spikes.md#manual-release-checklist)
   on the supported macOS versions and audit the repository before public
   disclosure. Push the reviewed commit to `main` and wait for CI to pass on
   that exact commit.
5. Create and push `v<version>`. The release workflow requires successful CI
   and the `MACEASE_CERT_P12_BASE64` and `MACEASE_CERT_PASSWORD` repository
   secrets. It publishes the signed DMG, checksum, and matching changelog notes.
6. Download the published assets, verify the checksum, and confirm the public
   `releases/latest` API returns the expected tag and release page.

Never publish an ad-hoc test DMG or retag a published version. If a required
check is unavailable, retain a local release candidate and report the blocker.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
