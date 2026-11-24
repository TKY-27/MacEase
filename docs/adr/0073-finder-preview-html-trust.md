# ADR 0073: Finder Preview HTML trust and permissions

Date: 2026-11-24
Status: Accepted

## Context

ADR 0067 rendered HTML by default with read access to the parent folder and
offered separate Run Scripts and Allow Network toggles that reset on every
selection. Files downloaded from the internet were treated like local files.
Measurements on macOS 27 showed that a "scripts without network" state could not
be upheld: page scripts reached WebKit's speculative TCP preconnect through
scripted anchor clicks, fresh `about:blank` iframe realms or overridden DOM
methods, which neither content rules nor Lockdown Mode stopped. A transparent
AppKit input shield made static pages unselectable. `loadFileURL` with the file
itself as the read-access URL still loaded sibling images, so it is not a
containment boundary. This supersedes the HTML permission parts of ADR 0067;
earlier ADRs stay unchanged as history.

## Decision

Represent HTML with exactly three policies: restricted, static Preview and
interactive. Scripts without network access cannot be expressed. Open HTML in
Source unless the file is in a Trusted Folder or has interactive consent.
Static Preview turns content JavaScript off, compiles offline content rules
before any load, routes the website data store through a fail-closed SOCKS5
proxy, installs an isolated-world guard at document start that cancels
activation, editing, submission and drags (including events retargeted from
closed shadow roots) while text stays selectable and fragment links scroll, and
neutralizes link and form targets at document end. Its context menu keeps only
Copy, Look Up, Speech and Share for non-link targets. One button, Run Scripts
with Network Access, grants interactive for the resolved path and a preview
stamp that adds the status-change time to the engine's file identity, size and
modification time, until the file changes or MacEase quits; the engine's commit
stamps keep their meaning. Trusted Folders open HTML interactive.

Treat a file as restricted when the link or its target carries
`com.apple.quarantine` or the attribute cannot be read; restriction wins over
Trusted Folders. Restricted HTML renders a page generated from its text with
only `data:` and `blob:` and no button. Grant folder read access only to the
resolved parent folder, and none for files directly in the home folder,
`/Users` or `/`, which render inline. Evaluate trust and consent on every load
from one file descriptor and check the stamp and quarantine again immediately
before loading.

## Consequences

The permission that the button grants is the permission that applies; no state
promises isolation that WebKit cannot enforce. Static pages are readable,
searchable and copyable but inert. Stated limits: an interactive or trusted page
can load files from its own folder, including quarantined ones, because the
quarantine rule covers the file the user opened; the proxy does not cover
loopback or local-interface IP literals, which `Network.framework` exempts, so
for those addresses the guard, the neutralizer and the content rules are the
only layers; input-method composition inside a closed shadow root can change
local, transient text; Look Up may contact Apple when Siri Suggestions are on.
The measurements come from app-hosted probes with loopback listeners in
`PreviewTrustTests`, `PreviewSealedPageTests` and `PreviewRenderedPageTests`.

Alternatives rejected: separate script and network permissions; a page-world
click guard, which page scripts bypassed; the AppKit input shield, replaced by
the isolated-world guard so text can be selected; relying on `loadFileURL`'s
read-access URL for containment; a per-selection permission reset, which made
users grant the same file repeatedly.
