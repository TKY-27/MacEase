# ADR 0060: Sequential package acceptance

Date: 2026-11-14
Status: Accepted

## Context

The full package run starts hundreds of tests together, including native media
and model inference. The existing ZIP-preview cancellation test must observe
partially written output before closing the session. It twice missed that
transient state during a full run, while its unchanged focused run passed.
The same symptom was recorded during v2.2.0 validation. No failed cancellation
or staging cleanup was observed, and no single competing test is established
as the cause.

## Decision

Use SwiftPM's supported `--no-parallel` for `make test` and `make test-device`.
Execute every package test with unchanged assertions. Tests that explicitly
create parallel operations continue to do so. Do not slow production code or
add test-only coordination seams to satisfy an observation deadline.

## Consequences

Acceptance takes longer and uses fewer simultaneous native resources. This
controls suite scheduling, not application concurrency. Full-run evidence is
still required; focused passes alone do not satisfy release acceptance.
