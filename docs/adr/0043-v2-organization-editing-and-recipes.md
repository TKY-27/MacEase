# 43. Version 2 organization, editing and recipes

Date: 2026-11-01
Status: Accepted

## Context

The owner requested a major release that connects file organization, batch
editing and finished output packages. Version 1 already provides individual
operations, but rename does not cover cross-directory recovery, editors use
single sources, and AI operation chains publish intermediate results.

## Decision

Implement SPEC section 20. Reuse the job engine, commit serialization,
validation, staging and history rather than introduce a generic workflow
framework. Add root-scoped organization with approved policies and opt-in
watching, durable move intent recovery, bounded local classification and
explicit corrections. Extend existing media and PDF editors. Execute saved
recipes from original sources into verified, atomic Derived packages.

Preserve old settings, history and single-source edit decoding. Version 2.0.0
uses build 6 and the existing local signing/publication process. The owner
authorized implementation, optimization, debugging, push and GitHub publication.
Three fresh GPT-6.1 Sol/high reviews are required after integration. Earlier
release-specific acceptance exclusions remain limited to their named versions.

## Consequences

Organization becomes the only new automatic filesystem workflow, scoped by
explicit per-root approval. It never implies automatic media conversion,
recursive restructuring, cloud analysis or permission to delete user content.
Finishing packages retain sources and publish only complete verified results.
Performance claims require matched measurements and unavailable checks remain
unverified. Documentation of shipped capabilities follows verification.
