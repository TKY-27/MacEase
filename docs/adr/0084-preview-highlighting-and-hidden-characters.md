# ADR 0084: Finder Preview highlighting and hidden characters

Date: 2026-11-25
Status: Accepted

## Context

Finder Preview highlighted about ten languages with a hand-written tokenizer
whose rules were spread across language branches. Files that people commonly
select in Finder, such as Makefiles, Dockerfiles, Terraform, SQL or patches,
showed plain text, and files without an extension did not reach the text
viewer at all. Source files can also carry characters that change what a
reader sees without being visible: bidirectional overrides that reorder code,
tag characters that hide a payload, zero-width characters left by copying.
A preview that renders them faithfully also hides them. Flagging every such
character would bury real text in false alarms, because joiners, direction
marks, zero-width spaces and soft hyphens are ordinary in Persian, Hindi,
Thai, Japanese or German prose. Drawing the marks through text attributes
changed glyph shaping for Indic and Persian text.

## Decision

Replace the tokenizer with declarative grammars, one per language, sharing one
scanning loop and a small set of document scanners for heredocs, raw strings,
fences, diffs and lightweight markup. Choose the grammar by exact file name
first, then by extension, and route the same names to the text viewer. Let
unambiguous multi-unit delimiters run to their closer, and cap only strings
opened by a single quote character, so a long block cannot invert highlighting
parity. Keep the 512 KiB cap and off-main, cancellable work.

Decide which characters are flagged in one scanner over Unicode scalars, with
context rules for the classes that prose needs (section 25.1). Draw a mark at
each flagged character's caret position from a TextKit 2 layout fragment and
never write marks or diff tints into the text storage. Show a notice only for
bidirectional controls and tag characters, which change what a reader sees;
mark the other classes without a notice. Always draw notice classes; cap the
rest per line fragment and say how many were left unmarked. Use the same
policy for CSV and TSV table cells, which replace flagged characters.

## Consequences

Forty-seven grammars cover the common source, configuration and document
formats, and new languages are table entries rather than branches. Prose in
right-to-left, Indic, Thai and Japanese scripts and emoji sequences show no
marks; the review's attack strings are flagged. Characters, shaping, Copy,
Find and selection are unaffected by marks. A file with a very long line of
flagged characters costs one caret pass over that line before first display.
A Western direction mark at the very end of a right-to-left string in code is
flagged, because both neighbours must be right-to-left. Marks have no
per-character accessibility; VoiceOver reads the notice.

Alternatives rejected: a third-party highlighting library or a grammar engine,
which would add a dependency or a JavaScript runtime to a read-only panel;
flagging every default-ignorable character, which marks ordinary prose; text
attributes for marks, which altered shaping; a global mark budget, which could
hide an override behind a run of zero-width spaces.
