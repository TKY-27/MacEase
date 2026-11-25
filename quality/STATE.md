# MacEase quality continuation

Updated: 2026-11-25, Asia/Tokyo. This branch records work in progress and
reproducible evidence. Do not merge this maintenance branch into the product.

## Operating constraints

The maintainer authorized continuing quality work and separate pull requests.
Never push to main, merge PRs, force-push, or weaken tests. Every product change
requires at least two independent agent reviewers other than its implementer.
Review findings must be resolved and the final diff reviewed again. A missing
necessary validation environment blocks the affected PR, not unrelated work.

Read current AGENTS.md and docs/SPEC.md before changing code. SPEC wins. Preserve
the original-file commit model, dependency licensing/pins, strict lint and
warnings-as-errors. Prefer demonstrated defects and measured improvements.
Avoid cosmetic refactors and new abstractions without a concrete need.

Audited baseline: `1bf5681919034a3a79b9badff01232399ce6e1f8` on main.
Baseline tree: `de9915fa58403022e710dbc2145b79388af27a0d`.
Check current main, branch heads, open PRs and review comments before resuming.

## Environment and validation gates

- Execution environment: Debian 13, x86_64. Swift 6.2 and pinned Go 1.26.5
  were installed from official distributions for focused Linux validation.
- Full baseline Swift strict lint passed, with zero warnings.
- Native Mac connector was offline on three attempts, most recently at
  2026-11-25 17:05 JST. No Xcode, Apple SDK,
  app-hosted tests, device tests, signing, packaging or macOS runtime checks ran.
- GitHub repository Settings / Actions explicitly had **Disable actions**
  selected. CONTRIBUTING.md says to keep Actions disabled. No setting changed.
  Empty commit status lists are not a passing CI result.
- A disposable `quality/validation-main-20261125` branch only adds itself to
  the CI push filter. It has no PR and produced no Actions runs. Do not repeat
  trigger experiments while the repository setting remains disabled.
- Publishing shell changes can be checked independently with actual Bash,
  SHA-256 and temporary fixture artifacts. Swift product changes need native
  builds/tests. AgeBridge's OS-dependent file-open change needs native Darwin
  `go test`; cross-compilation does not establish runtime behavior.

## Changes

| Work | Branch | State | Implementer / final independent reviewers |
| --- | --- | --- | --- |
| Release source assets and checksum association | `quality/release-media-sources` | [PR #2](https://github.com/TKY-27/MacEase/pull/2) open | root / audit_core, audit_app |
| Reject changed archive inputs and abort failed writes | `quality/archive-source-validation` | Preserved remotely; PR held for Mac validation | audit_formats / audit_core, audit_app |
| Linear duplicate-group partition | `quality/duplicate-group-partition` | Preserved remotely; PR held for Mac validation | root / audit_core, audit_app, audit_formats |
| Linear WebVTT header scan | `quality/linear-vtt-header` | Preserved remotely; PR held for Mac validation | audit_core / audit_formats, audit_app |
| Reject FIFO input before blocking in age helper | `quality/age-regular-input` | Preserved remotely; PR held for Darwin tests | audit_core / audit_formats, audit_app |
| Propagate dependency unpack/patch errors | `quality/dependency-unpack-errors` | [PR #3](https://github.com/TKY-27/MacEase/pull/3) open | audit_app / audit_core, audit_formats |
| Run Go bridge tests in standard targets | `quality/age-test-gate` | [PR #4](https://github.com/TKY-27/MacEase/pull/4) open, based on #3 | root / audit_core, audit_formats |
| Invalidate stale success before rebuilds | `quality/dependency-rebuild-stamp` | [PR #5](https://github.com/TKY-27/MacEase/pull/5) open, based on #3 | audit_app / audit_core, audit_formats |
| Reject invalid Ogg completed-page granules | `quality/ogg-page-granules` | Preserved remotely; PR held for Mac validation | audit_formats / audit_core, audit_app |
| Reject empty Opus packets | `quality/opus-empty-packets` | Preserved remotely; PR held for Mac validation | audit_formats / audit_core, audit_app |

All completed reviews were adversarial source reviews, not GitHub approval
reviews or substitutes for runtime validation. Reviewer names identify separate
agents in this session. The maintainer's GitHub account was not used to approve
its own PR.

### Release source artifacts

`make-dmg.sh` already produces matching media-tool source archives and their
checksums. The release workflow omitted both from the release upload, contrary
to docs/media-tools.md. PR #2 uploads all four assets and fails before invoking
`gh release create` for missing, empty or mismatched artifacts. Manual release
instructions now agree.

The actual YAML publication step passed 18 fixture cases with real Bash and
shasum and a local gh stub. Cases cover success, CLI failure propagation, every
missing/empty artifact, corrupt payloads and swapped/garbage/malformed manifests.
Review found that `shasum -c` could verify the wrong named file or tolerate extra
garbage; canonical digest-and-filename comparison fixed this before submission.
No live release was created. No macOS packaging claim is made.

Reproduce: install PyYAML in a disposable environment, then run
`python3 quality/evidence/release/verify.py PATH_TO_RELEASE_WORKFLOW` against the
PR branch's `.github/workflows/release.yml`.

### Archive consistency and cleanup

The writer collected a size, then read until EOF without revalidating the open
file. Shrinking a collected source produced silently padded content. Replacing
an unread regular file with a symlink could read outside the collected input;
a replacement FIFO could block. The fix opens without following links or
blocking, checks regular type, device, inode, size, mtime and ctime before and
after reading, and verifies the exact declared byte count.

Independent review discovered `archive_write_free` finalizes/pads a failed
archive. `archive_write_fail` prevents this. Further inspection of pinned
libarchive 3.8.10 found that abort skips the filename writer's close callback,
so the final implementation explicitly owns the output descriptor and uses
`archive_write_open_fd`. Both reviewers re-reviewed these changes.

Focused Swift 6.2 Linux tests used SHA-verified libarchive 3.8.10 and xz 5.8.4.
Seven test functions / 13 parameterized cases pass, including four output
formats, shrinking, growth, restored-mtime edits, inode replacement, symlinks
and FIFO replacement. Seven selected cases fail against baseline as expected.
After 64 aborted writes, open descriptors remained 7 before / 7 after.
Linux adapters replace Darwin names and the extraction oracle; this does not
establish macOS integration correctness. No full filesystem snapshot is claimed.

### Duplicate grouping

The byte-verification stage removed every matched URL using repeated linear
membership scans. Partitioning into equal/different arrays preserves the
comparison and ordering behavior without the quadratic removal phase.

Actual old/current function bodies, Swift 6.2 `-O -warnings-as-errors`, real
empty files, one warm-up and five alternating samples, median seconds:

| Files in one group | Baseline | Candidate |
| ---: | ---: | ---: |
| 1,000 | 0.019231098 | 0.006822159 |
| 4,000 | 0.215915585 | 0.026157121 |
| 16,000 | 3.295375630 | 0.117329261 |

This measures only the byte-group partition stage on Linux, not complete scans
or macOS performance. Identical, mixed, reversed, empty and singleton cases
produce equal results. Product regressions also cover duplicate roots and
same-size edits after hashing.

Reproduce: compile `quality/evidence/duplicates/{Comparison,Main}.swift` with
`swiftc -O -warnings-as-errors`, then run the resulting temporary executable.

### WebVTT validation

The header scan repeatedly removed the first array element. A cursor preserves
validation behavior while avoiding repeated shifts. Twelve behavior fixtures
pass on both implementations. Same Swift build and alternating median method:

| Header lines | Input bytes | Baseline seconds | Candidate seconds |
| ---: | ---: | ---: | ---: |
| 2,000 | 4,046 | 0.001297089 | 0.000806503 |
| 8,000 | 16,046 | 0.009260062 | 0.002936435 |
| 32,000 | 64,046 | 0.111378109 | 0.011312800 |
| 100,000 | 200,046 | 1.119995539 | 0.037595612 |

Only the validator was measured on Linux, with the EngineError type adapted.
This is not end-to-end download or macOS performance evidence.

### AgeBridge

Opening a FIFO with O_RDONLY blocks before fstat can reject it. The helper's
regular-file requirement therefore did not prevent a no-writer FIFO hang,
including a file replaced after app preflight. Use os.OpenFile with O_NOFOLLOW
and O_NONBLOCK, followed by the existing descriptor type check. This also uses
Go's normal Darwin file handling instead of introducing kqueue behavior through
os.NewFile.

Pinned Go 1.26.5 Linux full suite passes. The added bounded subprocess regression
fails on baseline at its five-second guard, then passes on the fix. The actual
fixed CLI rejects the FIFO in approximately 2.7 ms with the existing IO error
category and no output file; baseline had to be killed after two seconds.
Darwin arm64 production and test binaries cross-compile. Native Darwin tests
remain the necessary PR gate; neither compilation nor reviewer consensus
replaces them.

### Portable build and QA follow-ups

PR #3 propagates command-substitution failures explicitly. Baseline falsely
succeeds after a rejected patch, partial corrupt TAR extraction or failed
download with a retained partial file. Actual shell-function fixtures reproduce
all three and preserve two successful build/cache controls. All five pass after
the fix, and run from test/test-device targets.

PR #5 fixes the separate stale-success stamp: a forced rebuild fails after
recreating partial outputs, then ordinary retry incorrectly accepts them.
Invalidation follows the valid-cache early exit and precedes rebuild work.
The exact startup/cache/cleanup fixture now performs the required third build;
only its native compilation body is simulated. All seven tests pass, while
the #3 parent (`dbafdd5` locally) has one failing retry case. Reproduce with
`python3 scripts/test-build-deps.py`; shell syntax and diff checks also pass.

PR #4 adds `make test-age` between JS and Swift checks. The existing Go suite
passes with the actual target and pinned Go 1.26.5, independently rerun by a
reviewer. The actual Makefile plus real Go tests also passes dispatch fixtures:
a failing Go test stops Make without invoking Swift. JS/Swift are stubs only in
that dispatch fixture; test-device is checked by dry run. No Go product code
changed. Both reviewers re-reviewed combined English/Japanese instructions.

Reproduce dispatch checks with
`python3 quality/evidence/test-age/verify.py CHECKOUT GO_BINARY`.

PRs #4 and #5 are based on #3's branch. Preserve that dependency until #3 is
merged, then retarget and inspect the diff against current main. Do not merge
any PR automatically. Changelog insertions shared by release/build changes
must retain all entries when reconciling conflicts.

### Ogg and Opus malformed input

The page guard rejects negative granules on completed pages before packet
delivery, preserving legal continuation pages and internal packet granule -1.
Baseline's 41,178-byte malformed input returned a 38,398,752-byte Float32 array
from its first read; correct granules returned 977,952 bytes. These are array
sizes, not process RSS. The focused pinned-native Linux suite passes 15 cases;
baseline fails all three new negative-granule cases.

Separately, libopus interprets an empty payload as packet-loss concealment and
creates 5,760 frames. RFC 7845 section 3 requires zero-octet received packets to
be malformed. The fix extends the existing size check with a positive-length
condition, reusing its error and upper bound. Encoded silence and nonempty
TOC-only concealment remain valid. Mono/stereo direct and Ogg regressions fail
on baseline, then pass. Combined Ogg+Opus tests pass 12 functions / 19 cases.
This does not establish macOS correctness or a bound on all Ogg memory usage.
Adapter details, exact sources and logs: `evidence/formats/README.md`.

### Cumulative checks

The isolated cumulative worktree combines all four portable PRs. Only shared
changelog entries and development instructions needed conflict resolution.
Release fixtures (18), build fixtures (7), and actual-Go dispatch success/failure
fixtures pass together. The reviewed shell contents are preserved. Both
reviewers checked composition and the Go integration's resolved instructions.
The Formats implementer ran Ogg+Opus together; independent reviewers ran new
cases separately and checked composition. `evidence/core/reviews.md` records
audit_core's executions. audit_app independently reran the four Opus cases;
its Ogg review was source/specification/log review. Do not overstate shared
evidence or attribute one reviewer's test run to another.

Both independent reviewers also audited this checkpoint: recorded remote
commits/trees, preserved blobs, log totals, restoration instructions and missing
native gates match the underlying evidence. audit_app independently replayed
the cumulative release/build/Go dispatch fixtures. These checks do not change
the pending macOS acceptance status.

## Next work and audit candidates

Continue native validation when available, otherwise inspect remaining portable
build, integrity and resource-handling paths for demonstrated defects. These
changes do not complete the overall mission.

Once a Mac is available, first run the Go helper suite, strict lint and focused
Swift suites, followed by the affected package integration gates. Submit each
fully verified change separately. Check available PR CI/comments after each
submission. Do not enable Actions contrary to CONTRIBUTING.md without an
explicit maintainer override.

Candidates below are not completed fixes:

- PreviewTextSource eagerly detects/decodes text and discards the text, then
  automatic rendering detects/decodes again. Exact detector harness suggests
  about 2x stage improvement at 4 MiB. Prefer one result in the existing caller,
  not a new cache. Needs app-focused tests and native execution.
- PreviewImageSource reopens mutable images without reapplying its original
  decoded-memory budget. Needs a native replacement-file regression first.
- Delayed PreviewPlayback conversion may retain an earlier quarantine decision.
  Reproduce xattr changes between load and conversion before changing behavior.
- MediaToolProcess may wait indefinitely for inherited pipes when the leader
  exits before a descendant. Reachability and a production-path reproducer are
  still unproven.

The apparent Data index issue was disproved; do not repeat it without new
evidence. ZIP EOCD-looking comment rejection is deliberate existing behavior.

## Restart procedure

1. Read this file from the current `quality/continuation` head and inspect main,
   existing feature branches, open PRs and review comments.
2. Check whether another run owns active work before editing shared branches.
   Prefer separate worktrees. Do not overwrite someone else's changes.
3. Confirm required tools and native environment. Reuse completed evidence;
   re-run tests for changed code, new risks or an available native gate.
4. Select a demonstrated, valuable improvement, implement it and obtain two
   independent reviews. Address and re-review findings before submission.
5. Record exact commits, commands, results, limits and next steps here. Update
   this branch by ordinary fast-forward commits, never by rewriting history.

Feature branches were published through GitHub Git Data because local git push
has no credentials. Remote commits and local commits can have different IDs;
their tree IDs were explicitly checked for equality. Keep remote head IDs when
updating refs with expected_sha. Main has not been changed by this work.

| Branch | Remote commit | Tree |
| --- | --- | --- |
| `quality/release-media-sources` | `8df4b2195eccd0e4f1e866660ca2363301088353` | `ada7bee7c1db87f72c8b4bbad99a7ee862a8ebf3` |
| `quality/archive-source-validation` | `446426548ca15a8e07b3f672eeb6cbfc7ec0e934` | `af97e3a56667e0e3e2c12c49d5cb65526357ab49` |
| `quality/duplicate-group-partition` | `9a8c9dba2997ceee23952fba8cba2d028d859c18` | `8dfa4280d8690b77c65b78b0f4fe0cf315f8950b` |
| `quality/linear-vtt-header` | `16133c0cdce7e9d3bc07b3b251366e23489c6402` | `3c5a0f53627d19c7b3b169a8132fc1094cd85023` |
| `quality/age-regular-input` | `e1b55ddadf883a917375224a778e8678dd59daac` | `f84e6753684e24fd1d16940a547e6201efe62076` |
| `quality/ogg-page-granules` | `00faf613791076528d432e0f6b45508a8e795ca5` | `0337b4bc22557a8550104f2711e8efc1cea3076f` |
| `quality/opus-empty-packets` | `8d2e50dc4183bdda3a25a93394423d6b3b294de3` | `c8d9960f61435bea9bcfd8c06e3c798722c63a62` |
| `quality/dependency-unpack-errors` | `3d7222a54c053e4304acebb9afe5911e85285663` | `102e13a96d47dfba064ff6b1c74c434254821b35` |
| `quality/age-test-gate` | `24432f0da2f4c1b388b2ee02c2a2ff205a167137` | `15f2541f447ffe75ffbf74bfca162dadbdbd6fb3` |
| `quality/dependency-rebuild-stamp` | `10929833372a1bece986ae9a094bf6d80ffe66d2` | `17fc3faa39138900e289897c1e18d34ed0e5f6ed` |
