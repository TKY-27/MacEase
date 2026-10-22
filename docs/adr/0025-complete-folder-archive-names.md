# 25. Complete folder names for archives

Date: 2026-10-22
Status: Accepted

## Context

Section 3.5 previously removed the last extension from folder names.
Folder compression already keeps the complete name. The owner explicitly
requires `project.v1` to produce `project.v1.zip`.

## Decision

Keep the complete source folder name before the archive extension.
For multiple selected folders, keep the complete parent folder name.
Keep the existing collision numbering and archive-root layout.

## Consequences

Dotted folder names retain their version or other suffix in archive names.
This intentionally differs from Flect's extension-stripping rule.
No production naming change is required.
