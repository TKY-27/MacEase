# 30. v1.0.0 acceptance hardware

Date: 2026-10-23
Status: Accepted

## Context

The available physical machine is an Apple M5 Mac running macOS 27.0.1.
An official macOS 26 image runs in a local VM. The owner confirmed that no
M1 or macOS 26 physical Mac is available and explicitly approved publication
if acceptance succeeds on the available physical Mac.

## Decision

Use the M5/macOS 27 Mac for v1.0.0 physical acceptance. Supplement it with
macOS 26 VM checks where the guest supports them. Keep all numerical
performance targets and correctness, file-safety, signing and distribution
checks unchanged.

## Consequences

M1 performance and macOS 26 physical-device behavior remain unverified and
must not be reported as passing. Their unavailable hardware alone does not
block this release. A failed memory, correctness or distribution check still
blocks publication. Record actual results and limitations in `spikes.md`.
