# 16. Owned TOML conversion

Date: 2026-10-21
Status: Accepted

## Context

TOMLKit 0.6.0 allocates native tables without a matching destruction API.
Its table insertion copies children, C strings truncate at NUL, and its
date-time conversion substitutes UTC for a missing offset. MacEase already
guards the latter behaviors, but a per-input limit cannot stop cumulative
leaks in a long-running app.

The replacement must preserve the typed JSON mapping, deterministic TOML,
bounded inputs, and refusal of value loss. New dependencies cannot be fetched
in this workspace; only verified local sources may be vendored.

## Decision

- Vendor the unmodified toml++ 3.4.0 header from the locally resolved TOMLKit
  revision `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`. Keep its MIT license and
  pin the actual source URL and SHA-256 in `Vendor/deps.lock`.
- Compile it once in the `TOMLBridge` C++17 target. Expose a C ABI so Engine
  keeps ordinary Swift 6 compilation without C++ interoperability settings.
  Native owners release descendants through RAII; Swift releases each owner
  on every exit. Borrowed children never outlive their owner. Strings cross
  the boundary with explicit lengths, and exceptions do not cross the ABI.
- Reuse the existing JSON model, validation, and toml++ formatter. Keep the
  1 MiB input cap, depth and value budgets, finite-number and precision checks,
  conservative NUL refusal, local date/time semantics, and output reparse.
- Remove TOMLKit from SwiftPM and generated notices. Validate the vendored
  header's digest before generating its notice. Do not modify upstream code.
- Add resident-memory regression tests using `mach task_info`, warmup, and
  autorelease pools. Swift Testing exit tests isolate each measurement from
  other suites while forwarding assertion failures to the parent runner.
  Forty repeated conversions of a 512 KiB payload must
  grow by at most 16 MiB in either direction. The old implementation fails
  both checks. The allowance covers allocator reuse; it is not a peak-memory
  or universal leak-freedom proof.

Alternatives were evaluated against their primary upstream documentation:

| Option | Correctness and ownership | Maintenance, size, and build trade-off |
| --- | --- | --- |
| [toml++](https://github.com/marzer/tomlplusplus) with owned C ABI | TOML 1.0 parser and formatter; RAII owns trees, local offsets remain optional, strings have lengths | MIT; tagged 3.4.0 release dates to 2023, with later upstream development. Available locally. One C++17 translation unit replaces the existing C++ dependency and Swift wrapper. |
| Direct Swift/C++ interop | Same parser and native ownership | Requires exposing C++ types and interop configuration to Swift consumers. A C ABI keeps that requirement out of Engine. |
| [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) plus a writer | Pure Swift decoder advertises TOML 1.1; no encoder | MIT and active releases. Requires a new writer and independent validation; no local source checkout. No compiled-size measurement is available. |
| [mattt/swift-toml](https://github.com/mattt/swift-toml) | Read/write support, four TOML date/time types, configurable resource limits | MIT, Swift 6, toml++ through a C bridge. A maintained full wrapper is viable after an authorized fetch and ownership verification, but no local sources are available. |

## Consequences

There is no custom TOML parser, new package fetch, or additional native runtime.
MacEase owns the small bridge and must update the pinned header deliberately.
The old parser's stable release is not evidence of recent release cadence;
this decision favors locally verifiable ownership and compatibility.
Full upstream TOML compliance suites and release binary-size comparisons are
not claimed by the focused conversion tests. NUL remains an explicit refusal,
including escape spellings in comments, as accepted in section 8.7.
