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
| Noto Sans Bengali | `noto_sans_bengali` | Bengali | `glyf` | 372 212 |
| Noto Sans Gurmukhi | `noto_sans_gurmukhi` | Gurmukhi | `glyf` | 154 552 |
| Noto Sans Gujarati | `noto_sans_gujarati` | Gujarati | `glyf` | 574 628 |
| Noto Sans Oriya | `noto_sans_oriya` | Oriya | `glyf` | 533 592 |
| Noto Sans Tamil | `noto_sans_tamil` | Tamil | `glyf` | 224 256 |
| Noto Sans Telugu | `noto_sans_telugu` | Telugu | `glyf` | 787 664 |
| Noto Sans Kannada | `noto_sans_kannada` | Kannada | `glyf` | 557 872 |
| Noto Sans Malayalam | `noto_sans_malayalam` | Malayalam | `glyf` | 392 048 |
| Noto Sans Khmer | `noto_sans_khmer` | Khmer | `glyf` | 259 980 |
| Noto Sans Myanmar | `noto_sans_myanmar` | Myanmar | `glyf` | 656 176 |
| Noto Serif Tibetan | `noto_serif_tibetan` | Tibetan: Noto has no sans form | `glyf` | 1 968 044 |
| Noto Sans Balinese | `noto_sans_balinese` | Balinese | `glyf` | 155 276 |
| Noto Sans Javanese | `noto_sans_javanese` | Javanese | `glyf` | 206 772 |
| Noto Sans Sundanese | `noto_sans_sundanese` | Sundanese | `glyf` | 17 480 |

The set is 43 294 696 bytes of fonts, 21 fonts (`font_outlines.FONT_LIMIT` is 255).

**The plan names it; the boot image names the default.** The plan of principal 0 names the set by its hash, in one entry of the kind `Script_Fonts` (`plans_recipes.plan_entry_make_script_fonts`), or names a content-addressed `Script_Font_Pack_Manifest` (`MODSFP01`, `modus:contract/interface_language_pack`) by its hash in the plan value `root.script_fonts_manifest_hash`. The entry `Script_Fonts` travels to the core with the roles of the plan (`Plan_Roles_Set.script_fonts`), so the core takes the set and the roles whole, or refuses both; a `Script_Fonts` entry may name either a `font_outlines` blob directly or a `MODSFP01` manifest blob. With no plan entry and no manifest hash, the resource `script_fonts_name` of the boot image names the set, and a plan with no entry after a plan that named one gives the set back to the boot image: before the read, at once; after it, at the next start (`role_policy.script_fonts_plan_choice`, whose host test makes that rollback). The resource is the 32 bytes of its hash, which the build writes from the set that it made (`modustool script_fonts`), and which the signed system description lists as each resource. A plan of another principal that names a set is refused (`Machine_Only`): one set serves the machine.

**The root service reads it once, when the machine is usable, with object-cache fallback.** The object is `script_fonts` of the private store `script_fonts` of the machine. When the start policy says that the machine is usable, the root service reads it through the delegated service `disk_processes`, with a load of the kind `Script_Fonts` (`root_delegation.Load_Kind`): one object of at most `SCRIPT_FONTS_BYTES_LIMIT` (64 MiB) bytes, no import scan, and no start. When the local data disk lacks the object (`Not_On_Disk`), holds another hash (`Hash_Differs`), or is absent (`Without_Data_Disk`), and principal 0 configured a pinned QUIC object-cache server key (`root.script_fonts_cache_key`, 64 lowercase hexadecimal digits), the root service opens the scoped UDP endpoint (`10.0.2.100:5010` or the plan endpoint of `disk_processes`) and asks `disk_processes` to fetch the named BLAKE3 hash over QUIC (`ALPN = "modus-object-cache"`, `Load_Kind.Script_Fonts_Cache`). With no configured cache key, the network never starts and the machine stays on the replacement glyph.

`disk_processes` verifies every 1 MiB Bao frame proof against the requested hash (`object_cache.object_frame_verify`) as it writes into the memory that the root service lent. The root service revokes the loan and checks the BLAKE3 hash of the whole object on its own mapping, trusting neither the cache server nor `disk_processes`. If the verified bytes are a `Script_Font_Pack_Manifest` (`MODSFP01`), the root service decodes and resolves the single target set hash and declared byte size (`role_policy.script_fonts_manifest_resolve`, bounded to one indirection so a manifest never points to another manifest) and loads that hash through the same path. Otherwise it validates the outline header and records (`font_outlines.validate`), keeps the pages, and publishes a read-only (`{.Give, .Read}`) handle to the storage service (`Service_Command.Publish_Public_Object`). Each process with the `"fonts"` tree grant that starts after that maps `fonts/script_fonts` read-only at a kernel-chosen address through `storage.map_object` and opens the set once at startup (`display.fallback_load`, `text_rendering.script_fonts_open` / `written_part_open`). When the verified set arrived from the object cache and a data disk is present, the root service lends the verified pages read-only (`Load_Kind.Script_Fonts_Store`) to `disk_processes` to write them atomically into the `script_fonts` store of the machine so later starts load from disk with no network traffic.

The read waits for the machine to be usable for two reasons: the plan of principal 0 is read by then, and a read or fetch of 43 MB does not delay the first frames of the desktop.

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

- **The bound of a set is a property of its format, and each width follows it.** A resource of the format of the font outlines holds 1 to `font_outlines.FONT_LIMIT` (255) fonts: a font has an index of one byte. The tool refuses to write more (`resource_write`), and each reader refuses a header that names more (`validate`, `Bad_Count`). The records that a reader validated live in a room that the reader gives, sized from the header: a process and the root service give a room for any count of the format (`Record_Room`), a call of the library module a room for the fonts of a boot image and three more, and a header past the room is refused (`No_Room`). The font field of the key of the private glyph cache and of the direct glyph of a placed glyph is `FONT_FIELD_BITS` (9) wide, which holds None, the five fonts of the boot image and 255 more; a constant check ties it to the bound of the format. So a script added to the set meets the bound of the format, 255 fonts, before any width of the system: today 15 are used. The key is 64 bits and uses 47; the direct glyph uses bits 16 to 24, far below `DIRECT_GLYPH_FIRST` (2^30).
- **The glyph index is 16 bits in the key.** Noto Sans CJK has 65 535 glyphs, the most that a font holds.
- **A collection.** The set holds the whole file of Noto Sans CJK, and the open takes its face 0, the Japanese face, which holds the ideographs of the four languages in their Japanese forms. A face for each language waits for a principal who needs it.
- **The library module `text_rendering`** opens the font outlines of its caller only: a call places a character of a script font as the replacement glyph. A font of the boot image is TrueType: a font with CFF outlines in the place of one is refused, so a call never runs the reader of CFF, whose machine of 4 KiB does not fit beside the font set in the 16 KiB of a call. The set of a call has room for the five fonts of the boot image only (`Font_Set.room`): a script font added to the set costs a call no stack.
- **One load at a time.** The delegated service reads one object at a time. A `start_from_disk` during the read of the set is refused as busy, with its line; the read takes the time of 36 MB once at each start. A data disk with no set ends the read at once, with one line at the level Info.
- **The budgets.** The memory of the set comes from the budget of the root service, once: each process maps the same pages and pays its page tables only, about 18 pages for 36 MB.

## State

Built: the format 12, the reader of CFF and CFF2, the measures from the stated heights, the 21 fonts and their chains, the set written by the tool, its check, its delivery through `storage.map_object` (`fonts/script_fonts`), its open in a process, the plan entry `Script_Fonts` and its way through the roles set, the plan values `root.script_fonts_cache_key` and `root.script_fonts_manifest_hash`, the resource `script_fonts_name`, the read of the root service through `disk_processes`, the live QUIC object-cache fetch fallback (`Load_Kind.Script_Fonts_Cache`) with Bao frame verification, `Script_Font_Pack_Manifest` resolution, root-side BLAKE3 + `font_outlines.validate` verification, read-only publication to `storage` (`Service_Command.Publish_Public_Object`), asynchronous persistence to the local `script_fonts` store (`Load_Kind.Script_Fonts_Store`), the host tests, and the part `script_fonts` of the machine test (disk read, tampered hash refusal, oversize refusal, plan override + read-only fault, bad-form refusal, live QUIC object-cache fetch from a disk without `script_fonts` with glyph rendering and local persistence, and a deterministic busy refusal of `start_from_disk` while the host QUIC object cache holds the set open followed by release, mapping, caching, and a clean disk start).

Left: none.
