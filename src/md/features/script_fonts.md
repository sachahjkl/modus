# Script fonts: the fonts that the boot image does not hold

## Purpose

The font outlines of the boot image hold B612, Paper Mono and a subset of Noto Sans: Latin, Greek, Cyrillic and the symbols of those fonts ([glyphs_on_demand.md](glyphs_on_demand.md), "Every character that a font of the system has"). A principal who reads Hebrew, Arabic, Chinese, Japanese, Korean or an emoji, or a text with a black square (U+25A0), sees the replacement glyph. Each of those fonts is large: the Noto Sans CJK collection is about 32 MB. A boot image that holds them all is 30 times larger, for scripts that most machines never show.

This design gives the system fonts past the boot image, a fallback chain for each of their scripts, and the reader of the outlines that they need. The guide of the subject is [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs past the glyph cache". The shaping of their text is [written_shaping.md](written_shaping.md).

## Constraints

- **The boot image stays small.** No script font is a resource of the boot image.
- **No shared state tells a process what another process draws** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17). A request for a font that a text makes is such a state: the service that answers, and the network behind it, learn which scripts a process shows, and when.
- **A process never waits for another process in its frame** ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **A data object is named by its hash** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system").
- **A font file is hostile input**, and a font from a cache comes from a third party.

## The chosen form

**A script font set is one data object, named by its hash in the plan.** The modus tool writes it from the source fonts (`modustool script_fonts`, `build/fonts/script_fonts.bin`) in the format of the font outlines (`modus:contract/font_outlines`): a header, one record for each font with its name and the BLAKE3 hash of its file, then the files. The fonts are whole source files, not subsets: an Arabic font keeps its table `GSUB` for the forms of its letters. The set today:

| Font | Name | Scripts | Outlines | Bytes |
|---|---|---|---|---|
| Noto Sans Hebrew | `noto_sans_hebrew` | Hebrew | `glyf` | 35 508 |
| Noto Sans Arabic | `noto_sans_arabic` | Arabic | `glyf` | 682 836 |
| Noto Sans Symbols 2 | `noto_sans_symbols_2` | geometric shapes, symbols, dingbats, arrows | `CFF` | 404 576 |
| Noto Emoji | `noto_emoji` | emoji, in the color of the text | `glyf` | 1 966 648 |
| Noto Sans CJK | `noto_sans_cjk` | Han, kana, Hangul, the fullwidth forms | `CFF2`, a collection, face 0 | 32 682 580 |
| Noto Sans Thai | `noto_sans_thai` | Thai | `glyf` | 94 872 |
| Noto Sans Devanagari | `noto_sans_devanagari` | Devanagari | `glyf` | 565 836 |

The set is 36 433 492 bytes.

**The plan names it; the boot image names the default.** The plan of principal 0 names the set by its hash, in one entry of the kind `Script_Fonts` (`plans_recipes.plan_entry_make_script_fonts`), as the settings study plans a typed row of a policy of the machine (`src/md/features/module_settings.md` of the branch of that study, "Machine policy: the plan holds it"): a row that names a data object by its hash, which the evaluation of a declaration fills when that study is built. The entry travels to the core with the roles of the plan (`Plan_Roles_Set.script_fonts`), so the core takes the set and the roles whole, or refuses both. With no entry, the resource `script_fonts_name` of the boot image names the set: the 32 bytes of its hash, which the build writes from the set that it made (`modustool script_fonts`), and which the signed system description lists as each resource. A plan of another principal that names a set is refused (`Machine_Only`): one set serves the machine.

**The root service reads it once, when the machine is usable.** The object is `script_fonts` of the private store `script_fonts` of the machine. When the start policy says that the machine is usable, the root service reads it through the delegated service `disk_processes`, with a load of the kind `Script_Fonts` (`root_delegation.Load_Kind`): one object of at most `SCRIPT_FONTS_BYTES_LIMIT` (64 MiB) bytes, no import scan, and no start. The root service takes the memory back from the service, checks the BLAKE3 hash of the bytes against the named hash on its own mapping, then validates their form (`font_outlines.validate`), and keeps them. It maps them read-only at the fixed range `Script_Fonts`, beside the font outlines, in each process that gets the font outlines and starts after that. A process opens the set once (`display.fallback_load`, `text_rendering.script_fonts_open`).

The read waits for the machine to be usable for two reasons: the plan of principal 0 is read by then, and a read of 36 MB does not delay the first frames of the desktop. The object reaches the store as each object of a plan does: from an object cache by its hash, or from the disk that the tool writes.

**The box until it arrives.** A process with no script font set, or with a set whose check failed, draws each character of those scripts as the replacement glyph, with the advance of `0`, as before. A process started after the set is mapped draws the glyphs. No process asks for a font, and no frame waits: a process has the fonts of its start.

**A fallback chain for each script.** Each script has a row in `text_rendering.scripts`; the script font is the last font of the row, after the fonts of the boot image that have some of its characters:

| Script | Its characters | Chain of the interface | Chain of the cells |
|---|---|---|---|
| Hebrew | U+0590 to U+05FF, U+FB1D to U+FB4F | Noto Sans Hebrew | Noto Sans Hebrew |
| Arabic | U+0600 to U+06FF, U+0750 to U+077F, U+08A0 to U+08FF, U+FB50 to U+FDFF, U+FE70 to U+FEFF | Noto Sans Arabic | Noto Sans Arabic |
| Symbols | U+25A0 to U+27BF, U+2B00 to U+2BFF | B612, Paper Mono, Noto Sans Symbols 2, Noto Emoji | Paper Mono, B612, Noto Sans Symbols 2, Noto Emoji |
| Han and Hangul | the CJK blocks, kana, Bopomofo, Hangul, the fullwidth forms, the two ideographic planes | Noto Sans CJK | Noto Sans CJK |
| Emoji | U+1F000 to U+1FAFF | Noto Emoji, Noto Sans Symbols 2 | Noto Emoji, Noto Sans Symbols 2 |
| Thai | U+0E00 to U+0E7F | B612, Noto Sans, Paper Mono, Noto Sans Thai | Paper Mono, B612, Noto Sans, Noto Sans Thai |

A glyph of a script font is drawn in the frame of the first font of its face, as each fallback glyph ([glyphs_on_demand.md](glyphs_on_demand.md), "A fallback font in the frame of the first font"). A script font has no Latin letters to measure, so its frame comes from the heights that its table `OS/2` states, or from its ascender when it states none (`vector_font.font_measures_stated`).

**A wide character takes two cells.** In a face of cells, a glyph of Noto Sans CJK or Noto Emoji is drawn in two cells: its em is two cells wide, and the cell width of the character (`text_rendering.cell_width_of`) gives the text two cells for it. The terminal already lays out the lead and the trail of a wide character.

**The character map of format 12.** Emoji and the ideographs of the second plane are past U+FFFF, which the format 4 cannot name. The reader takes the subtable of format 12 (platform 3, encoding 10, or platform 0, encoding 4 or 6) before the format 4: a search by halves over its groups, which the open checks to grow strictly.

**A reader of CFF and CFF2.** Noto Sans Symbols 2 has CFF outlines, and Noto Sans CJK has CFF2 outlines, the variable form of CFF. The reader runs the Type 2 charstrings (the moves, the lines, the eight curve operators, the four flex operators, the hints, which it skips, the local and global subroutines with their bias, at most 10 levels deep) and, for CFF2, `blend` and `vsindex` with the default instance: it keeps the default values and drops the deltas. A CID font finds the local subroutines of each glyph through its `FDSelect` (formats 0, 3 and 4) and its `FDArray`. A cubic curve becomes two quadratic curves, split at its middle, each with the control point `(3 (c1 + c2) - p0 - p3) / 4`: within 1/8 pixel at the sizes of the system, as the cut of a curve of the rasterizer is. The outline is the outline of a TrueType glyph, so the rasterizer, the private glyph cache and the golden hashes do not change.

## The refused forms

- **A font fetched when a text needs it.** The fetch tells the service and the network what a process draws, the channel of property 20, row 17; and a frame would wait for the answer.
- **Each script font in the boot image.** About 36 MB for scripts that most machines never show.
- **A subset of each script font.** An Arabic font loses its forms with its `GSUB`, and a subset of the ideographs leaves out the characters of a name that a principal types.
- **The color emoji of Noto Color Emoji.** Its glyphs are pictures (`CBDT`) or layers of colors (`COLR`), which the rasterizer of coverage does not draw. Noto Emoji draws each emoji in the color of its text.
- **A hash check of 36 MB in each process.** The root service checks the object once, as it checks the font outlines; a process maps pages that no process writes.
- **The hash of each font against its record in the root service.** The hash of the whole object already says that these are the bytes of the set that the plan names; a second pass over 36 MB in the loop of the root service proves nothing more. The tool checks each record where it writes the set (`font_outlines.script_fonts_check`).
- **A map into each process that runs, when the set arrives.** The root service would write into the address space of a process at a moment that the process does not choose, as a language pack would ([interface_language.md](interface_language.md), "A new pack reaches a process at its next start"). A process that started before keeps the box until its next start.
- **The set in the store `module_files`.** That store holds module files by name, with a limit of 16 MiB that a grant table and a module disk share; the set is a data object of the machine, larger than that limit.
- **A read before the start policy.** It delays the first frames by the read of 36 MB, and the plan of principal 0 is not read yet.
- **A cubic rasterizer.** Two quadratic curves keep one rasterizer and its proof.

## Subtle points

- **The key of the private glyph cache holds the font in 4 bits.** The five fonts of the boot image and the seven script fonts are twelve members of `Outline_Font`, of the sixteen that the key holds.
- **The glyph index is 16 bits in the key.** Noto Sans CJK has 65 535 glyphs, the most that a font holds.
- **A collection.** The set holds the whole file of Noto Sans CJK, and the open takes its face 0, the Japanese face, which holds the ideographs of the four languages in their Japanese forms. A face for each language waits for a principal who needs it.
- **The library module `text_rendering`** opens the font outlines of its caller only: a call places a character of a script font as the replacement glyph. A font of the boot image is TrueType: a font with CFF outlines in the place of one is refused, so a call never runs the reader of CFF, whose machine of 4 KiB does not fit beside the font set in the 16 KiB of a call. The set of a call has room for the five fonts of the boot image only (`Font_Set.room`): a script font added to the set costs a call no stack.
- **One load at a time.** The delegated service reads one object at a time. A `start_from_disk` during the read of the set is refused as busy, with its line; the read takes the time of 36 MB once at each start. A data disk with no set ends the read at once, with one line at the level Info.
- **The budgets.** The memory of the set comes from the budget of the root service, once: each process maps the same pages and pays its page tables only, about 18 pages for 36 MB.

## State

Built: the format 12, the reader of CFF and CFF2, the measures from the stated heights, the five fonts and their chains, the set written by the tool, its check, its fixed range, its open in a process, the plan entry `Script_Fonts` and its way through the roles set, the resource `script_fonts_name`, the read of the root service through `disk_processes`, the map into each process, the host tests, and the part `script_fonts` of the machine test.

Left: the fetch of the set from an object cache by its hash, with the large objects of [recipes.md](recipes.md); today the tool writes the set on the data disk.
