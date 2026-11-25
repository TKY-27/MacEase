# Independent final reviews by audit_core

These are source reviews and focused local verification, not GitHub approval
reviews. No native macOS acceptance is claimed. Production changes implemented
by audit_core (VTT and Age) were reviewed by audit_app and audit_formats instead.

## Portable release + unpack + Go gate composition

Reviewed cumulative local commit:
`8ac3c9f18ffd798ed2f9f57150da23e373cb420f`.
Reviewed stacked Go gate local commit:
`c8593aca5a030853feda4813819a0fd3a24b4ae2`, compared with unpack parent
`dbafdd5`.

No findings. The cumulative eight-file diff contains only the reviewed release,
unpack, and Go test-gate changes. Held Swift and Go production changes are not
included. The combined English/Japanese README and CONTRIBUTING text accurately
describes dependency scripts, JavaScript isolation, Go bridge tests, then Swift
package tests. Both release and unpack changelog entries survive composition.

Independent byte comparisons passed:

- `.github/workflows/release.yml` equals the reviewed MacEase-release copy.
- `scripts/build-deps.sh` equals the reviewed MacEase-unpack copy.
- `scripts/test-build-deps.py` equals the reviewed MacEase-unpack copy.
- `Makefile` equals the final stacked MacEase-test-gate copy.

Both cumulative and stacked diff whitespace checks passed. No additional full
suite was run solely for unchanged executable content.

For the original Go gate review, actual `make test-age` with pinned Go 1.26.5
passed the complete baseline bridge suite in 10.287 seconds. A separate
actual-Makefile failure fixture checked the bridge working directory, local
toolchain/CGO settings, read-only modules, and disabled test caching. Stub Go
exit 23 produced Make exit 2 and did not invoke Swift. `make -n test-device`
confirmed the same sequencing; no device execution occurred. This validates
the Makefile-only change, not the separate Darwin file-open fix.

## Dependency preparation errors

Final review includes the integrated Makefile test calls and English/Japanese
documentation. No findings. Explicit return guards preserve the failing status
through both nested command substitutions; the existing outer assignment and
errexit stop the build. An unmatched patch glob still succeeds.

Independently ran all five tests successfully, then loaded the same tests with
baseline `1bf5681` script contents. Exactly three regression cases failed:
rejected patch, corrupt archive after partial extraction, and failed download
with a retained partial file. The two normal/cache controls passed. Shell syntax
and diff checks passed. The tests use actual extracted functions and real local
curl/tar/patch operations, not native dependency compilation.

## Dependency rebuild stamp

Reviewed final three-file diff against unpack parent `dbafdd5`. No findings.
Stamp removal is after the valid-cache early return and before preflight or
output mutation. It runs at the top level under errexit, so removal failures
cannot be ignored. Valid unchanged cache behavior is preserved.

The real `generate-notices.sh` writes directly to the notices output and can
fail after creating it. Therefore the fixture's partial-output state is
reachable. Its native build body is explicitly simulated; startup, checksum,
cache decision, and cleanup code come from the actual script.

Independent execution: all seven tests passed. Substituting `dbafdd5` script
contents caused exactly the retry regression to fail (two build attempts rather
than three); all six other cases passed. Shell syntax and diff checks passed.
This is sufficient for the shell cache-state change, with no native build claim.

## Ogg completed-page granules

Reviewed the full reader/page scanner, PCM accumulation, callers, existing
granule boundary tests, and final three-file diff. No findings. Checked the
format rule against RFC 3533 section 6, RFC 7845 section 4, and pinned libogg's
completed-packet counting semantics.

Validation occurs before malformed pages expose packets. Legal pages without
completed packets and internal packet granule -1 remain accepted. The existing
policy for skipped multiplexed streams is unchanged. Positive Int64 boundary
tests remain compatible.

Verified the portable harness's Ogg source and new test file were byte-identical
to the candidate, then independently ran Swift 6.2 release OggPageTests: three
functions, six parameterized cases passed on Linux. Native Mac gate remains.

## Empty Opus packets and cumulative format behavior

Reviewed final Opus commit `abb9cf4e8d70f9aaa8bd2261400fa78074eac436`.
No findings. RFC 7845 section 3 distinguishes malformed zero-octet packets from
valid packets carrying a TOC byte and empty coded frames. Pinned libopus treats
length zero as a packet-loss-concealment request. The added lower bound rejects
empty file packets before PCM allocation, preserves the existing upper bound,
and covers both Ogg and AudioPacketDecoder callers.

Final tests cover direct and CRC-valid Ogg empty payloads, mono/stereo encoded
silence, and valid one-byte TOC-only concealment. Reviewed the test-only explicit
finite-predicate adjustment. Verified candidate source and tests byte-for-byte,
then independently ran the Linux Swift 6.2 release tests: two functions, four
parameterized cases passed. Ogg.swift was baseline for that run, establishing
independence from the separate page-granule fix.

After the implementer composed both changes, independently compared its combined
Ogg.swift and Opus.swift with the reviewed branch copies; both matched. The page
guard handles invalid page positions before packet delivery. Empty packets on
otherwise valid pages reach the separate codec guard. Neither weakens the
other. Reviewed the implementer's combined log: 12 functions, 19 cases passed.
That combined run was not repeated by this reviewer. Both product changes still
require native Mac validation before PR submission.

Format references: [RFC 3533 section 6](https://www.rfc-editor.org/rfc/rfc3533.html#section-6),
[RFC 7845 sections 3–4](https://www.rfc-editor.org/rfc/rfc7845.html#section-3),
and [libogg ogg_page_packets](https://xiph.org/ogg/doc/libogg/ogg_page_packets.html).

## Final four-PR composition and checkpoint

Final local cumulative commit `4c8a01e9845049ca7a10cc06101f98389455b5a7`
adds the reviewed stamp fix to the earlier three-PR composition. Independently
compared exact file content: release.yml matches the release branch,
build-deps.sh and test-build-deps.py match the stamp branch, and Makefile matches
the final stacked Go gate. No held product changes are present. Final diff
checks pass. This was source-identity verification, not another full test run.

The final checkpoint's ten remote heads and trees match live GitHub resources
and reviewed local trees. Main remains the original baseline. All 45 staged
files are UTF-8 text, including previously ignored logs; five documented native
dependency checksums match the lock. Test totals and platform limitations agree
with the logs. Corrected references distinguish the stamp's #3 parent from main
and attribute each independent runtime check to the agent that actually ran it.
