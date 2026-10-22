# 27. Context Page icon family

Date: 2026-10-22
Status: Accepted

## Context

The app icon combined a context-menu panel with sparkles. The menu bar item
and the Finder root item used the SF Symbol `wand.and.sparkles`, whose
sparkles now suggest AI features rather than deterministic file processing.
The menu bar had no way to report a failed batch or a disabled Finder
extension without being opened.

Three icon families were proposed. The owner approved Option C, Context Page,
for the app icon, the menu bar glyph with its states, and the Finder root glyph.

The SF Symbols license permits system symbols at runtime through
`NSImage(systemSymbolName:)`. It does not permit redrawing, exporting, or
embedding symbol artwork in custom assets or app icons. Apple's guidance also
bars symbols, and glyphs confusingly similar to them, from app icons and logos.

## Decision

- The app icon is a white folded page with a right-click pointer and a context
  menu whose highlighted row carries a chevron, on a blue squircle using
  Apple's 1024-pixel macOS grid. Below 64 pixels the pointer and text lines are
  dropped and the remaining shapes are thickened.
- The menu bar and Finder glyph is a folded page whose highlighted row slides
  out past its edge. States are idle, three busy frames in which the highlight
  steps down the page every 0.4 s, a static busy frame with three dots for
  Reduce Motion, and attention with an exclamation badge.
- Attention shows when the latest batch has failures other than cancellation,
  or when Finder Sync is disabled after onboarding. Opening the menu bar menu or
  a later successful batch clears it.
- VoiceOver labels per state are "MacEase", "MacEase, processing", and
  "MacEase, needs attention".
- All artwork is original CoreGraphics drawing in `scripts/make-app-icon.swift`,
  the single generator. It writes the AppIcon PNGs and vector template PDFs
  with preserved vector data. Generated files are never edited by hand.
- The Finder extension cannot read the host's catalog, so its root glyph
  lives in `FinderSync/Assets.xcassets`.
- No SF Symbol, Flect asset, or third-party artwork is traced, rasterized, or
  embedded in any icon or glyph.

## Consequences

- The blue body is the most common Dock color, so the icon is less distinctive
  than the alternatives. The drawn pointer may look dated.
- Template PDFs embed a creation date, so rerunning the generator rewrites them
  even when the drawing is unchanged.
- Dark, clear, and tinted Icon Composer appearances are not provided; macOS
  derives them from the single light icon.
- Turning Finder Sync off while MacEase runs is noticed at the next launch or
  onboarding change. The menu item itself is always rebuilt on open.
