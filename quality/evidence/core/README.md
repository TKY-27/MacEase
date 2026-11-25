# Core quality evidence — 2026-11-25

Baseline: `1bf5681919034a3a79b9badff01232399ce6e1f8`.
Subtitle commit: `204b9d7bbbea74aea8f8f90cfb840c2a58732f0c`.
Age local validation commit: `070a3af1a3b3504dd4d7a541f050a2ef778a42b2`.

The published tree-identical subtitle commit is
`16133c0cdce7e9d3bc07b3b251366e23489c6402` on `quality/linear-vtt-header`;
the published age commit is `e1b55ddadf883a917375224a778e8678dd59daac` on
`quality/age-regular-input`. Use these remote commits when restoring a fresh
checkout; local validation commit objects are not published.

All execution recorded here used Linux. macOS execution remains outstanding;
neither the Swift adapter nor Darwin cross-compilation substitutes for it.
Each production change received independent reviews from audit_app and
audit_formats, with no remaining findings. Both changes are held for native
validation before PR submission.

## Subtitle validation

`SubtitleValidation.swift` includes the actual baseline and candidate validator
implementations, with only the baseline type renamed and a minimal EngineError
adapter. It compares 12 accepted/rejected fixtures and measures five warmed,
alternating runs at each header size. The saved harness uses a unique temporary
fixture directory instead of the original fixed directory; algorithm and
measurement code are unchanged.

Reproduce with Swift 6.2:

```sh
swiftc -O -warnings-as-errors SubtitleValidation.swift -o /tmp/subtitle-validation
/tmp/subtitle-validation
```

`subtitle-results.txt` is the original output. At 100,000 metadata lines
(200,046 bytes), median validation time changed from 1.119996 seconds to
0.037596 seconds (29.79x). This measures validation only, including Foundation
file loading and parsing; it does not measure downloading or whole-app speed.
The new cursor removes repeated Array prefix shifts. All 12 behavior fixtures
matched expected results in both implementations.

## Age bridge

Use the pinned Go 1.26.5 toolchain. The repository's system command named `go`
was unrelated to the Go language; all original runs used the absolute pinned
toolchain path. The following commands use `go` only as shorthand for it.

Run in `Vendor/AgeBridge` at each indicated commit:

```sh
GOTOOLCHAIN=local CGO_ENABLED=0 go test -count=1 ./...
GOTOOLCHAIN=local CGO_ENABLED=0 go build -mod=readonly -trimpath -buildvcs=false -o /tmp/macease-age-REVISION .
```

Original full-suite observations: baseline passed in 10.451 seconds; candidate
passed in 9.195 seconds. These are test outcomes, not performance claims. A
repeated run is retained in `age-full-baseline.log` and `age-full-current.log`.

The regression red control exports candidate `go.mod`, `go.sum`, and
`main_test.go` into an isolated temporary directory, then exports baseline
`main.go` there. Run this in that directory:

```sh
GOTOOLCHAIN=local CGO_ENABLED=0 go test -count=1 -run '^TestOpenRegularRejectsFIFO$' -timeout 15s
```

`age-red-test.log` records the expected failure after its bounded five-second
deadline. On the candidate, run:

```sh
GOTOOLCHAIN=local CGO_ENABLED=0 go test -count=1 -run '^TestOpenRegular' -v
```

`age-green-test.log` records both FIFO and directory/symlink rejection tests
passing. The complete test source is in the candidate commit; it launches the
actual test binary as a bounded subprocess so the baseline cannot hang the
test runner.

`age-cli-fixture.py` creates a FIFO without a writer and invokes actual bridge
binaries, sending a public test password through the normal framed stdin
protocol. It kills a blocked process after two seconds and records whether any
output exists. Reproduce after building the two binaries above:

```sh
python3 age-cli-fixture.py /tmp/macease-age-baseline /tmp/macease-age-current
```

Original baseline observation: blocked until killed at 2.015808391 seconds,
with no output created. `age-current-cli.json` records candidate exit 1 with
`MACEASE_AGE_ERROR:io`, no output, and elapsed 0.002706073 seconds. The deadline
is a regression bound; this is not a throughput benchmark.

Candidate Darwin arm64 production binary and test binary were cross-compiled:

```sh
GOTOOLCHAIN=local GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -mod=readonly -trimpath -buildvcs=false -o /tmp/macease-age-darwin-arm64 .
GOTOOLCHAIN=local GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go test -mod=readonly -c -o /tmp/macease-age-darwin-arm64.test
```

Both were identified as Mach-O 64-bit arm64 executables. They were not run on
macOS. Native bridge `go test` remains the targeted gate because Darwin
filesystem flags and the Go runtime's Darwin descriptor path need execution.
No compiled binaries are included in this evidence directory.
