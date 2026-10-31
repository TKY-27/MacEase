# 44. Version 2.0.0 VoiceOver acceptance

Date: 2026-11-01
Status: Accepted

## Context

Implementation, three independent review rounds, device checks and signed
candidate validation are complete. The macOS 26.6.2 VM smoke check passed.
VoiceOver starts, but automation cannot reliably verify its spoken output or
navigation. Earlier release exclusions explicitly do not carry forward.

## Decision

After the other work, the owner explicitly authorized publishing v2.0.0 with
actual VoiceOver operation recorded as unverified and excluded from this
release's mandatory acceptance. This decision applies only to v2.0.0.

Keep the remaining requirements: tagged-source packaging, the existing signing
identity, checksum verification, public download checks and disabled Actions.
Do not describe unperformed VoiceOver checks as passed.

## Consequences

Version 2.0.0 may be published after the remaining distribution checks.
Accessibility semantics and keyboard checks remain evidence of their own
scope, not substitutes for real VoiceOver operation. The release notes and
validation record disclose this limit. Future releases need their own decision
if VoiceOver acceptance is still unavailable.
