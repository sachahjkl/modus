# Written shaping: marks, Arabic joining and direction

## Purpose

The written shaper of the text rendering places one glyph for each character ([text_rendering.md](text_rendering.md), "The interface"). A text that holds a letter and a combining mark (e and U+0301, the stacked marks of Vietnamese), a text of Arabic, whose letters change form with their neighbours, and a line that mixes a right-to-left script with Latin drew wrong or drew the replacement glyph.

[interface_language.md](interface_language.md), "6. Shaping and fonts", sent each such run to a library module built from HarfBuzz. That module needs a C++ path that does not exist yet. This design gives the written shaper the part of that work that the scripts of the bundled fonts need, so that a principal reads them now. HarfBuzz stays the shaper of the scripts of India and of Southeast Asia, whose reordering is far larger ([`ROADMAP.md`](../../../ROADMAP.md), "The shaping of the scripts of India and of Southeast Asia").

## Constraints

- **The measure and the draw agree** ([text_rendering.md](text_rendering.md), "Constraints"): each step below is a pure function of the text, the face and the size, run by the measure, the fit, the line break and the draw.
- **The stored text is not changed.** A composition is a choice of a glyph, not a change of bytes. The cluster of each placed glyph is the first byte of its characters.
- **No allocation, a bound of work.** Each step runs over a bounded window of the text.
- **The data comes from Unicode, not from a guess.** The tables are generated from the pinned Unicode Character Database by the modus tool (`modustool unicode_tables`, `src/library/modus/text_rendering/unicode_tables.odin`).

## The chosen form

**The cluster.** A character and the marks after it (general category Mn or Me) are one cluster. A cluster holds at most `CLUSTER_MARK_LIMIT` (16) marks; a mark past it starts a cluster of its own.

**The composition (UAX #15).** The marks of a cluster are put in canonical order by their combining class, a stable sort. Then each mark, in order, composes with the base when the table of the primary compositions (`compositions`, the canonical decompositions of two characters that are not excluded) names the pair and no mark of the same class before it stayed apart. The result is the composed character when a font of the chain has it; else the base and its marks stay apart. So e and U+0301 draw é, and e with U+0323 and U+0302, in either order, draws ệ (U+1EC7).

**A mark that stays apart.** It is a placed glyph with the advance 0, at the place of its base. The draw centres its ink on the advance of its base (`graphics`); its height is the height that its font gives it. A mark with no base (the first character of a text, or after a space) takes the dotted circle U+25CC as its base, as a reader of the Unicode Standard expects ("Display of combining marks with no base"). The anchors of `GPOS` are not read: the centre is right for the marks of the Latin, Greek, Cyrillic and Hebrew scripts above or below one letter, and wrong for a mark that a font puts at the side.

**The joining of Arabic.** The joining type of each character (`ArabicShaping.txt`: right, dual, left, join causing) and each mark (transparent) gives the form of each letter: isolated, initial, medial or final. The shaper looks back to the last character that is not transparent, and forward to the next. The form is the presentation form that Unicode names for the letter (the compatibility decompositions <isolated>, <final>, <initial> and <medial> of UnicodeData.txt, U+FB50 to U+FEFF), when its font maps it; else the single substitution of the feature isol, init, medi or fina of the script arab in the GSUB of its font. Lam with an alef after it is one glyph: the isolated or the final form of their ligature (U+FEF5 to U+FEFC). A form that the font lacks keeps the glyph of the character. A glyph that a substitution gives has no character: its placed glyph names its font and its glyph index (DIRECT_GLYPH_FIRST).

The presentation forms come first because Noto Sans Arabic makes its forms in GSUB by a multiple substitution, a letter with no dots and then its dots as marks, which GPOS places: a single substitution finds nothing there, and the dots need the anchors that the written shaper does not read. The presentation forms of the same font are whole glyphs. HarfBuzz takes the same fallback for a font with no usable GSUB. The letters past the presentation forms (the extended Arabic of U+0750 and U+08A0) draw isolated.

**The direction of a line (UAX #9).** After the shaper places the glyphs of a text in logical order, it reorders their places for the screen: the paragraph level from the first strong character (rules P2 and P3), the weak types (W1 to W7), the neutral types (N1 and N2), the implicit levels (I1 and I2), and the reversal of each run of a level (L2). The places change, not the order of the placed glyphs, so a fit and a break still count bytes in logical order. A glyph of a right-to-left level with a mirrored form (`BidiMirroring.txt`) draws that form. The embeddings, the overrides and the isolates are characters of no strength: a text of the system holds none ([../data/text_encoding.md](../data/text_encoding.md)). A text of more than `BIDI_GLYPH_LIMIT` (1 024) placed glyphs keeps its logical order: a draw record holds 256 bytes, and a longer line is a document that a later layer breaks into paragraphs.

## The refused forms

- **HarfBuzz for these runs now.** It is the decided shaper of the complex scripts, and its C++ path is several steps away. These scripts are read today; HarfBuzz takes the scripts whose reordering is the large part of its work.
- **Applying NFC to the stored text.** `NFC is checked, not applied` at the borders of names ([interface_language.md](interface_language.md), "Subtle points"); the drawing picks a glyph and leaves the bytes.
- **The joining from the glyphs of a font.** The joining type is a fact of Unicode; a font may lack a form.
- **The forms of GSUB first.** In Noto Sans Arabic they are a letter with no dots and its dots as marks, which only the anchors of GPOS place.
- **A table of the levels for the whole text.** The places of a line are enough to draw it; the levels live on the stack for the length of one line.

## State

Built: the tables generated from Unicode 17.0, the cluster, the composition, the mark with its dotted circle, the joining of Arabic with lam-alef, and the reordering of a line, with host tests.

Left: the anchors of `GPOS` for the marks, the isolates of UAX #9, the breaks of UAX #14, and the scripts that HarfBuzz shapes.