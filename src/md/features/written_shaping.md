# Written shaping: marks, Arabic, Thai, Devanagari and direction

## Purpose

The written shaper of the text rendering places one glyph for each character ([text_rendering.md](text_rendering.md), "The interface"). A text that holds a letter and a combining mark (e and U+0301, the stacked marks of Vietnamese), a text of Arabic, whose letters change form with their neighbours and carry their dots as marks, a text of Thai, whose vowels and tone marks stack on a consonant, and a line that mixes a right-to-left script with Latin drew wrong or drew the replacement glyph.

[interface_language.md](interface_language.md), "6. Shaping and fonts", sent each such run to a library module built from HarfBuzz. That module needs a C++ path that does not exist yet. This design gives the written shaper that work for the scripts of the script fonts, so that a principal reads them now. The study of the scripts of India and of Southeast Asia decided against HarfBuzz: an engine of the lookups in Odin, with a shaper of each OpenType model on it, shapes Devanagari today and the other scripts of India next ("The scripts of India and of Southeast Asia: the study").

## Constraints

- **The measure and the draw agree** ([text_rendering.md](text_rendering.md), "Constraints"): each step below is a pure function of the text, the face and the size, run by the measure, the fit, the line break and the draw.
- **The stored text is not changed.** A composition is a choice of a glyph, not a change of bytes. The cluster of each placed glyph is the first byte of its characters.
- **No allocation, a bound of work.** Each step runs over a bounded window of the text.
- **A call of the library module stays under 16 KiB of stack** (`CALL_STACK_BOUND`, measured by a host test): the shaper and the order of a line live on the stack of a worker thread of the caller.
- **The data comes from Unicode, not from a guess.** The tables are generated from the pinned Unicode Character Database by the modus tool (`modustool unicode_tables`, `src/library/modus/text_rendering/unicode_tables.odin`).

## The chosen form

**The cluster.** A character and the marks after it (general category Mn or Me) are one cluster. A cluster holds at most `CLUSTER_MARK_LIMIT` (16) marks; a mark past it starts a cluster of its own.

**The composition (UAX #15).** The marks of a cluster are put in canonical order by their combining class, a stable sort. Then each mark, in order, composes with the base when the table of the primary compositions (`compositions`, the canonical decompositions of two characters that are not excluded) names the pair and no mark of the same class before it stayed apart. The result is the composed character when a font of the chain has it; else the base and its marks stay apart. So e and U+0301 draw é, and e with U+0323 and U+0302, in either order, draws ệ (U+1EC7).

**The anchors of the marks.** A mark that stays apart is a placed glyph with the advance 0. When its font is the font of its base and has a table `GPOS`, the anchors place it (`vector_font.mark_anchor_offset`): on the mark before it on the same base by the feature `mkmk` (lookup type 6), else on its base by the feature `mark` (lookup type 4), in the script of its base. The placed glyph then has the placement `Anchored`, its x from the origin of its base and its y above the baseline, both in 1/64 of a pixel and kept within one line. A mark that no anchor places has the placement `Centred`: the draw centres its ink on the advance of its base, at the height that its font gives it. A mark with no base (the first character of a text, or after a space) takes the dotted circle U+25CC as its base, as a reader of the Unicode Standard expects ("Display of combining marks with no base").

**The joining of Arabic.** The joining type of each character (`ArabicShaping.txt`: right, dual, left, join causing) and each mark (transparent) gives the form of each letter: isolated, initial, medial or final. The shaper looks back to the last character that is not transparent, and forward to the next. When the font of the letter has `GSUB` and `GPOS`, the letter takes the forms of its font (`font_forms`): the multiple substitution of the feature `ccmp` (lookup type 2), which makes some letters a dotless body and its dots, then the feature of its form (`init`, `medi`, `fina`, `isol`) on the body, by single and multiple substitutions in the order of the lookup list (`vector_font.script_substitution`). The dots are marks that the anchors place on the body, and a vowel sign after them sits on them by `mkmk`. A glyph that a substitution gives has no character: its placed glyph names its font and its glyph index (`DIRECT_GLYPH_FIRST`).

When the font changes nothing, the form is the presentation form that Unicode names for the letter (the compatibility decompositions `<isolated>`, `<final>`, `<initial>` and `<medial>` of `UnicodeData.txt`, U+FB50 to U+FEFF), when the font maps it. Lam with an alef after it is one glyph: the isolated or the final form of their ligature (U+FEF5 to U+FEFC).

**Thai.** A consonant and its vowels above and below and its tone marks are one cluster; the anchors of Noto Sans Thai stack them. SARA AM (U+0E33, and U+0EB3 of Lao) is two parts, as the Thai shaper of OpenType makes it: NIKHAHIT (U+0E4D), a mark on the consonant before it, moved before the tone marks and the vowels above that the consonant holds, so that they stack on it; and SARA AA (U+0E32), a base of its own, at the byte of SARA AM. One rule (`sara_am_splits`) decides it from both clusters that it touches: the fonts draw both parts, and before SARA AM there are a base that is no space and fewer than 16 marks. SARA AM with no such base stays whole. Thai has no reordering of its letters in OpenType; its breaks of a line need a dictionary, which UAX #14 leaves to a tailoring.

**The format characters that a reader never sees.** The controls of the direction of a line (LRI, RLI, FSI, PDI, LRM, RLM, ALM, and the embeddings and overrides), the joiners and the non-joiners, the spaces and joiners of no width and the soft hyphen are `INVISIBLE_GLYPH`: the advance 0, and the draw draws nothing. A joiner still joins the letters of Arabic around it: its joining type is join causing.

**The direction of a line (UAX #9).** After the shaper places the glyphs of a text in logical order, it reorders their places for the screen. The paragraph level comes from the first strong character, the text inside an isolate left out (rules P2 and P3). The explicit levels are those of the isolates (X1 to X10 for LRI, RLI, FSI and PDI): an initiator takes the level around it and opens the next odd or even level, FSI by the first strong character inside, at most 125 deep (`BIDI_DEPTH_LIMIT`), with the counts of the overflow and of the valid isolates that the rules keep; a PDI closes the last isolate that it matches. The weak types (W1 to W7) and the neutral types (N1 and N2) are resolved over each isolating run sequence (BD13): the runs of one level joined across each isolate, from its initiator to its matched PDI, with sos and eos from the levels around it. Then the implicit levels (I1 and I2), L1 for the white space and the isolate characters at the end, and the reversal of each run of a level (L2). The places change, not the order of the placed glyphs, so a fit and a break still count bytes in logical order. A mark keeps its offset from its base. A glyph of a right-to-left level with a mirrored form (`BidiMirroring.txt`) draws that form. The embeddings and the overrides are boundary neutrals: a text of the system holds none ([../data/text_encoding.md](../data/text_encoding.md)). A text of more than `BIDI_GLYPH_LIMIT` (512) placed glyphs keeps its logical order: a draw record holds 256 bytes, so 512 glyphs, each character a mark on a dotted circle; a longer line is a document that a later layer breaks into paragraphs.

## The scripts of India and of Southeast Asia: the study

Two ways shape Devanagari, the other scripts of India, Khmer, Myanmar and the scripts of the Universal Shaping Engine.

**A shaper written in Odin, from the OpenType script specifications.** Its parts, for Devanagari first:

| Part | What it is | Estimated lines |
|---|---|---|
| The categories | `IndicSyllabicCategory.txt` and `IndicPositionalCategory.txt`, generated by the tool as the other tables | 200, and the tables |
| The syllables | the state machine of a syllable: consonant, nukta, halant, matra, modifiers, the broken cluster on a dotted circle | 300 |
| The first reordering | the base consonant, the reph, the pre-base matra, and the mask of features of each glyph | 400 |
| A GSUB over a buffer of glyphs | lookup types 1 to 6 and 8, with the lookup flags and the mark filtering sets: the conjuncts are ligatures, and Noto Sans Devanagari picks the width of its i-matra and its forms of ra by contextual chains | 1 500 |
| The features in order | `nukt`, `akhn`, `rphf`, `rkrf`, `pref`, `blwf`, `abvf`, `half`, `pstf`, `vatu`, `cjct`, then `pres`, `abvs`, `blws`, `psts`, `haln` | 300 |
| The final reordering | the reph and the pre-base matra to their places | 300 |
| GPOS past the marks | the pairs of lookup type 2, the cursive of type 3, the marks on a ligature of type 5, and `abvm`, `blwm`, `dist` | 600 |

About 3 600 lines for Devanagari (built: 970 lines of the engine, 490 of the shaper of Devanagari and 120 of `GDEF`, with the readers of the lookups of the written shaper beside them), then 100 to 300 lines of rules for each other script of India, and as much again for Khmer, Myanmar and the Universal Shaping Engine. The buffer of a line of glyphs does not fit the 16 KiB of a call: it is an arena of the caller. Its proof is the shaping tests of HarfBuzz, which a host test can run as golden outputs, script by script.

**HarfBuzz, as an outside module.** HarfBuzz is C++. The C compiler of modus is `chibicc`, which compiles C only ([c_compiler.md](c_compiler.md)): HarfBuzz needs the C++ path of [interface_language.md](interface_language.md), "The C++ path": `clang++` of the host through the outside source path, with no exceptions and no RTTI, and the few procedures of a C++ runtime in the thin libc. Its costs: 600 KiB to 1 MiB of code (an estimate, to measure); its memory through `hb_malloc_impl` from an arena; a stack deeper than 16 KiB (its lookups nest to 64 levels), so it runs in a call with a stack of its own, not on a worker thread of the caller; and the pin and the reuse row of a work of others. Its gains: every script and 15 years of the faults of the fonts of the world, fuzzed by OSS-Fuzz.

**The decision.** Thai was built first, in Odin: past the anchors of `GPOS`, it is the split of SARA AM and a row of the chains. Then the engine of the contextual lookups, in Odin, is the one engine of this shaper, not a second HarfBuzz: the written shaper already reads `GSUB` and `GPOS`, and the contextual lookups are what each complex script needs, Devanagari and the contextual forms of the fonts of Arabic too. Devanagari is built on it. HarfBuzz stays out of the system: it would need a C++ path, a stack of its own and a megabyte of code for what the engine and a shaper of each model give.

## The engine of the lookups

**A buffer of glyphs.** The engine (`vector_font/layout_engine.odin`) works on a buffer of at most `ENGINE_GLYPH_LIMIT` (32) glyphs: one syllable, or one word of a script that joins. Each glyph has its glyph index, the place of its first character in the run, a mask of the features that apply to it, its class of `GDEF` (base, ligature, mark, component), and its advance and its offsets in units of the font. The buffer lives on the stack of the caller: 32 glyphs of 20 bytes.

**The lookups.** `GSUB`: single (type 1), multiple (2), alternate (3, the first alternate), ligature (4, its components matched over the glyphs that the lookup flags skip), contextual (5) and chaining contextual (6) in their three formats (glyphs, classes, coverages), extension (7), and reverse chaining single (8). `GPOS`: single (1), pair (2, both formats), mark-to-base (4), mark-to-ligature (5, on its last component), mark-to-mark (6), contextual (7) and chaining contextual (8), and extension (9). A contextual lookup of either table shares one matcher: the input, the backtrack and the lookahead, with the skips of the lookup flags.

**The lookup flags and GDEF.** A lookup skips the bases, the ligatures or the marks that its flags name, the marks of another attachment class, and the marks out of its mark filtering set (`GDEF` 1.2). The class of a glyph comes from the class definition of `GDEF`; a glyph that a substitution makes takes the class of the new glyph.

**The bounds.** A contextual lookup applies its nested lookups at most `ENGINE_NESTING_LIMIT` (4) deep: a cycle of lookups that call each other ends there. The engine applies at most `ENGINE_STEP_LIMIT` (4 096) lookups at a position for one run: a font that loops through a reverse lookup or a contextual chain stops there, with the glyphs that it made. It tries at most `ENGINE_WORK_LIMIT` (65 536) subtables, rules and ligatures in one stage. That one count bounds the work, not a count of subtables of each lookup: the conjuncts of Noto Sans Devanagari are one chaining lookup of 114 subtables, and a bound of 64 dropped half of them. A substitution that would pass 32 glyphs is not made. Each offset is checked against its table, as the rest of the reader.

**The features in stages.** The caller gives the features of a stage, each with its bit of the mask; the engine merges their lookups in the order of the lookup list, and applies each to the glyphs whose mask holds the bit of a feature that names it. A stage ends before the next starts, as the OpenType models ask.

## Devanagari

The shaper of Devanagari (`text_rendering/indic.odin`) follows the OpenType specification of the Indic scripts (the script tags `dev2`, then `deva`), with the categories of `IndicSyllabicCategory.txt` and `IndicPositionalCategory.txt`, generated by the tool for the blocks of the scripts of India.

1. **The syllable.** A consonant syllable is consonants joined by a virama (a joiner after the virama stays in it), each with its nukta, then the dependent vowels, a final virama and the modifiers; an independent vowel starts a syllable of its own; a mark with no syllable stands on the dotted circle of the font. A syllable holds at most 16 characters: the characters after them start the next syllable. The text is decoded once for a syllable.
2. **The first reordering.** The base consonant is the last consonant, less a ra after a virama with a consonant before it (the rakar, which `rkrf` and `blwf` make). Ra and a virama at the start of a syllable with a consonant after them are a reph. A pre-base matra (ि) moves to the start, after the reph. The masks: `rphf` on the reph, `half` and `blwf` before the base, `blwf`, `abvf` and `pstf` after it; each other feature on every glyph. A non-joiner after a virama keeps the half form away.
3. **The features of the start, one stage:** `locl` and `ccmp`. **The basic features, one stage each:** `nukt`, `akhn`, `rphf`, `rkrf`, `blwf`, `abvf`, `half`, `pstf`, `vatu`, `cjct`.
4. **The final reordering, as HarfBuzz does it.** The pre-base matra moves after the last virama that stayed a glyph before the base; with none, it stays first. The reph, when the virama went into it, moves after an explicit virama before the base, else before the first modifier after the base, else to the end: after the base, its below forms and its vowel signs.
5. **The presentation features, one stage:** `pres`, `abvs`, `blws`, `psts`, `haln`, with the common features of a line, `rlig`, `calt`, `clig`, `liga`, `rclt`.
6. **The positions, one stage of `GPOS`:** `dist`, `kern`, `abvm`, `blwm`, `mark`, `mkmk`.

The script tag is `dev2` when the font has it, else `deva` with the same rules. The font of a syllable is the font of its first character of the script, and each glyph of the syllable comes from it: the chain of Devanagari puts the script font first, so a danda and a digit beside a word come from the same font. Only a font of the script font set takes this path. A call of the library module opens the fonts of the boot image only, so it never runs the engine.

The glyphs of a syllable go to the line as one shaped cluster: the first glyph is its base, each glyph after it with an advance and no offset is a base at the pen, and each other glyph is anchored at its pen plus its offset. The pairs of the table `kern` do not join a syllable to the glyph beside it: `dist` and `kern` of `GPOS` placed it. The cluster of a glyph is the first byte of its first character, made never to go down along the glyphs of the syllable, as HarfBuzz merges them: the ि of कि takes the byte of क.

The expected glyphs of the tests come from HarfBuzz 12.3.0 on the host, through `uharfbuzz` 0.53.2 of nixpkgs, on the file of the set: 34 words, each glyph index, its advance and its offset in units of the font. The clusters are not compared: HarfBuzz merges more of them than the shaper does.

## The refused forms

- **Applying NFC to the stored text.** `NFC is checked, not applied` at the borders of names ([interface_language.md](interface_language.md), "Subtle points"); the drawing picks a glyph and leaves the bytes.
- **The joining from the glyphs of a font.** The joining type is a fact of Unicode; a font may lack a form.
- **The presentation forms first.** They are whole glyphs, but a letter past them (the extended Arabic of U+0750 and U+08A0) drew isolated, and a vowel sign was centred on its letter, not on its dots. The forms of the font have both, and the presentation forms stay for a font that makes no form.
- **A mark always centred.** It is right for a mark above or below one letter of Latin, and wrong for the dots of Arabic, the points of Hebrew and the stacked marks of Thai.
- **A table of the levels for the whole text.** The places of a line are enough to draw it; the levels live on the stack for the length of one line.
- **An array of the isolating run sequences of a line.** One sequence at a time, in the array that the order of the screen takes after it, keeps the call under its stack bound.
- **HarfBuzz in the system.** A C++ path, a stack of its own and a megabyte of code, for what one engine of lookups and a shaper of each model give.
- **A recursion with no bound.** A font can make two lookups call each other; the nesting and the steps are bounded, as each loop over hostile input.
- **A slot for every font in each font set.** A call of the library module holds its set on a stack of 16 KiB, and each script font added a slot of 584 bytes to it: the seventh font passed the bound. A set holds a pointer to each font that it opened, in the room that its owner gives (`Font_Set.room`): the state gives a room for every font, a call a room for the five fonts of the boot image.

## State

Built: the tables generated from Unicode 17.0, the cluster, the composition, the anchors of `GPOS` (mark-to-base and mark-to-mark), the mark with its dotted circle, the joining of Arabic with the forms of its font, its dots and lam-alef, Thai with SARA AM, the invisible format characters, the reordering of a line with its isolates, the engine of the lookups and Devanagari on it, with host tests.

Left: the breaks of UAX #14 and the dictionary of Thai; the other scripts of India (`ROADMAP.md`); Khmer, Myanmar and the scripts of the Universal Shaping Engine, which need a shaper of their own model on the engine; the cursive attachment of `GPOS` (lookup type 3).
