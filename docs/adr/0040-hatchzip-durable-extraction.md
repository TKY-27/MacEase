# 40. Durable in-place HatchZip extraction

Date: 2026-10-30
Status: Accepted

## Context

The owner wants space-saving extraction instead of duplicating macOS Archive
Utility. The owner explicitly authorizes consuming archives immediately,
without retaining originals or showing a confirmation. Ordinary staging cleanup
and derived-output Undo cannot represent this operation safely.

## Decision

Add `archive.hatchExtract` with a pinned Rust helper using hatchzip-core
0.1.8 at ba72db848178a97183c2225a3fb617f5ba7f9a2f, without UnRAR.
Use structured local communication, complete preflight verification, exclusive
same-volume output folders and durable private sessions. Preserve path and
expansion limits. Set quarantine before releasing corresponding source bytes.
Keep upstream integration patches minimal and pinned with the source.

Pause and resume preserve extracted output and checkpoint state. They never
use ordinary temporary cleanup. Recovery is independent of ordinary history
retention, and completed destructive extractions are not undoable. Source
retention, confirmation and automatic fallback to normal extraction are absent.
Reject unsupported locations or untrusted recovery state before mutation.

Retain libarchive extraction only for RAR in the Finder menu. Remove redundant
ordinary extraction for macOS-supported formats. ZIP browsing remains available.

## Consequences

This is the explicit exception to the original-preserving commit model and
URL-triggered destructive-action confirmation. Only the new authenticated
operation has this behavior; existing extraction identifiers are not repurposed.
Crash/resume, limited-space output integrity and quarantine ordering require
integration proof. Archive-consuming extraction cannot reconstruct an original
archive from history, and paused files must not be removed automatically.
