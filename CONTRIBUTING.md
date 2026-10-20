# Contributing to MacEase

Thanks for your interest in MacEase. This guide explains how to propose changes
and what reviews look for.

## Ground rules

- Be respectful. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- **Never lose a user's file.** Any change that touches file handling must keep
  the commit model in [docs/SPEC.md](docs/SPEC.md) section 3.5 intact.
- **Clean-room.** Do not copy, translate or consult source code from GPL, LGPL
  or AGPL projects (for example FFmpeg, LAME, gifski, pngquant). MacEase is MIT
  licensed and implements formats from public specifications.
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
next to an installed release. Enable the "MacEase Dev" Finder extension from the
onboarding screen that opens on first launch.

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

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
