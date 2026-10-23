# 31. Kernel memory measurements

Date: 2026-10-23
Status: Accepted

## Context

Instruments cannot start a ktrace session on the acceptance Mac, including
after Developer mode was enabled. The owner explicitly permits an equivalent
official measurement method. SPEC section 16 limits peak resident memory,
not physical footprint.

## Decision

Accept the Darwin kernel resident high-water mark reported by
`/usr/bin/time -l` for the actual Release host process. Measure from launch
through the operation, staged verification, final commit and process exit.
Darwin `getrusage(2)` defines `ru_maxrss` as maximum resident bytes; this
captures peaks that periodic RSS samples can miss. Keep the 1.5 GB target.

Record physical footprint separately. Its accounting includes compressed
memory and cannot be substituted for resident size. Keep standalone
converter results separate from full-app acceptance.

## Consequences

A failed Instruments recording does not itself block publication when a
complete kernel measurement exists. Correctness checks and analysis of
input-dependent allocations remain required: passing finite fixtures cannot
establish a bound for arbitrary inputs. Report measurement scope and units.

References: the installed Darwin `getrusage(2)` and `time(1)` manuals, and
[Apple rusage documentation](https://developer.apple.com/documentation/kernel/rusage_info_current).
