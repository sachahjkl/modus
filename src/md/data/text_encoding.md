# Text encoding: UTF-8 in every contract

## Purpose

A principal writes the words of a language other than English: é, è, ç, à and ù on the layout of France. A text of the system must then hold these characters in each record that two parties share: an entry of the palette, a run of a result, a line of the terminal, a line of the log, the name of an object of a store.

Several contracts froze their text to the bytes 32 to 126, each with its own check. Each of them is a format that two programs agree on. A change of each format, one at a time and later, is a migration of every contract. This design breaks those contracts once, before the keys give the characters, so that the keyboard work changes the keyboard path, the line editor and the fonts only.

The `Text` of the module contract is UTF-8 already ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The types that a description knows"). This design gives the same rule to each other contract.

## Constraints

- **A text from another party is hostile input.** A broken sequence, an overlong form or a control character must not reach a terminal of the host, a log record, or the drawing as a byte.
- **The kernel holds the border of the log.** A program calls the operation `Log` directly, so a check in the support library is no check.
- **Each contract has a fixed size of field.** A length is a count of bytes, and a field holds fewer characters than bytes when a text has characters outside ASCII.
- **The grid of cells shows one character in one cell.** A text that a byte count places is wrong for a character of two bytes.
- **The fonts hold 32 to 126, the Latin-1 Supplement and the added characters only.** The glyph caches and Spleen have no other glyph.
- **Contract packages import no support package**, and the kernel imports contract packages only ([infrastructure/repository_layout.md](../infrastructure/repository_layout.md)).

## The chosen form

**One rule, in one contract package.** `src/library/contract/text_encoding` holds the rule and the procedures. It is a contract package because the palette table, the store, the cut mark and the kernel check text with it, and none of them can import a support package. A support package or a program imports it as well.

**A text is UTF-8, as RFC 3629 defines it.** A character is one well-formed sequence:

| First byte | Second byte | Third byte | Fourth byte |
| --- | --- | --- | --- |
| 00..7F | | | |
| C2..DF | 80..BF | | |
| E0 | A0..BF | 80..BF | |
| E1..EC | 80..BF | 80..BF | |
| ED | 80..9F | 80..BF | |
| EE..EF | 80..BF | 80..BF | |
| F0 | 90..BF | 80..BF | 80..BF |
| F1..F3 | 80..BF | 80..BF | 80..BF |
| F4 | 80..8F | 80..BF | 80..BF |

Each other byte that starts a sequence is an invalid sequence: an overlong form (C0, C1, E0 80..9F, F0 80..8F), a surrogate (ED A0..BF), a code point above U+10FFFF (F4 90.. and F5..FF), a lone continuation byte, and a sequence cut short. A control character is an invalid sequence too: U+0000 to U+001F, U+007F, and U+0080 to U+009F. So a text holds no line feed and no tab: a line is a record, and its end is a record or a field. Each other code point is a character of a text, whether a font draws it or not.

**The procedures.**

- `character_decode` reads one character, each byte once. A byte that starts no well-formed sequence is an invalid sequence of one byte; a control character keeps the length of its sequence.
- `text_valid` and `invalid_sequence_find` are the check at a border: the first gives a verdict, the second the place of the first invalid sequence.
- `invalid_sequences_replace` writes `?` in place of each byte of each invalid sequence. The length stays, so each offset into the text stays.
- `complete_characters` is the one way to cut a text: a writer with room for `n` bytes keeps `complete_characters(text[:n])` bytes. It moved here from the cut mark, which uses it.
- `character_count` counts the cells of a text: one for each character, one for each invalid sequence.
- `character_encode` writes the sequence of a code point, and refuses a code point that is no character of a text.

**What each border does.**

| Border | Its party | What it does with an invalid sequence |
| --- | --- | --- |
| The operation `Log` | The kernel | Replaces each byte of an invalid sequence with `?` in its copy, before the serial port and the record. Each record of a long text ends after a whole character. |
| The palette table | The compositor | Refuses the table (`Bad_Byte`), the result area, the candidates, a `Text` argument; and a table whose names are not ASCII. The writer (`result_run`) replaces an invalid sequence, so its own table passes, and counts the columns of the run as written. |
| `Program_Create` | The kernel | Refuses a name of a program with a byte outside 32 to 126 (`Bad_Operation`): a space is allowed, as in the names of the nodes of `rings`, and no byte acts on a terminal. |
| The name of an entry of a store | The storage service | Refuses the name (`Bad_Byte` at the place of the invalid sequence). |
| A record of the terminal ring | The terminal | Draws the replacement glyph for the invalid sequence. The library cuts each text after a whole character. |
| A text drawn by a program | `graphics`, `text_shaping` | Draws the replacement glyph. |

A border that refuses keeps the rule of its contract: a table that fails is no table. A border that must keep a text whole and its offsets (the log, with its value runs) replaces. A reader that draws shows the invalid sequence. The three are the same rule at three kinds of party.

**The cell of a text grid holds a code point.** `interface.Text_Grid_Cell.character` is a `rune`. One cell is one character, so the reader that fills a grid decodes the text once, and the grid compares and draws cells with no decode. The cell grows from 12 to 16 bytes, with two reserved bytes of 0 in place of a hidden pad, because `draw_text_grid` copies the cells into the text table of the frame and the drawing module reads them there ([../api/text_grid.md](../api/text_grid.md)): the bytes of a cell are part of the border of the module. So the draw record is version 10, and the exports are `damage_of_draw_table_10` and `execute_draw_table_in_rectangles_10`. A cell with the bytes of UTF-8 needs 4 bytes and a length, the same size, and a decode at each draw. A cell of a hostile caller with a code point that is no character of a text (a surrogate, a number past U+10FFFF) draws the replacement glyph.

**The drawing of a character that the font lacks: one replacement glyph.** The drawing decodes UTF-8 and gives each character one cell (`graphics.text_scaled`, `text_bold`, `text_width`), or one placed glyph (`text_shaping.shape`). A character that the fonts do not hold (outside 32 to 126, U+00A0 to U+00FF and the added characters), a control character and each invalid sequence draw the replacement glyph: the outline of a box from the top of a capital letter to the baseline (`graphics.character_replacement`). Code draws it, in each font and at each scale, so no font needs a glyph for it. A byte is never drawn as a glyph, so a reader always sees that a character is there. The shaper gives the placed glyph `REPLACEMENT_GLYPH`, with the advance of `0` and no pair, and the first byte of each character as its cluster.

**The fonts hold two ranges and a list: 32 to 126, the Latin-1 Supplement and the added characters.** The characters of a font are the 95 printable characters of ASCII, the 96 characters U+00A0 to U+00FF, and the added characters (`glyph_cache.added_characters`): today the euro sign U+20AC alone. That is 192 characters (`glyph_cache.CHARACTER_COUNT`). The two ranges are the characters of the languages of Western Europe. The euro sign is the one character that a key of the layout of France gives outside them: AltGr with `e` ([../features/keyboard_layout.md](../features/keyboard_layout.md)). U+0080 to U+009F are control characters, which a text never holds, so the two ranges have no gap that a character of a text could fall in.

The **character index** (`glyph_cache.character_index`) numbers them: 0 to 94 for 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then 191 and up for the added characters, in the order of their list. Each table that keys a character keys it by this index: the glyphs and the advances of a glyph cache, its pairs, the placed glyph of the shaper, and the Spleen data. A reader finds a glyph by its code point with one call, and each table has no hole. The glyph cache is version 4: its header has no first character, and a cache holds the 192 characters, no fewer. The vector fonts in `resources/fonts` are subsets with the same 192 characters (`modustool vector_fonts`), and the Spleen data holds them (`modustool font`): Spleen 2.1.0 draws each character of the Latin-1 Supplement and the euro sign.

**A character past Latin-1 is added to a list, not by a range.** The next characters that a principal can need are far apart in Unicode: Œ (U+0152), Ÿ (U+0178), the dashes and the quotation marks (U+2013 to U+201E), the ellipsis (U+2026), the euro sign (U+20AC). A range that holds them holds about 8 000 characters. Each font must draw each character of a cache, so with a range the build would refuse each font of the system, or the tables would get back the holes that the character index removed. A list holds only the characters that were chosen, and each font draws each of them. The rules of the list:

- An added character is past U+00FF and in the basic plane: the character map of a subset (format 4) holds the basic plane only. A host test checks it.
- The list is in the order of the code points, with no repeat. The character map of a subset needs its segments in that order, and a reader can search the list by halves when it grows. The search of today goes through the list, which is short, and only for a character past U+00FF.
- A character added before another moves the index of that other. Each table is made from the list at the build, so no index is kept anywhere. But a cache of the old list keys its glyphs by the old indexes: each change of the list is a new version of the glyph cache.
- A character joins the list only if each font of the system draws it: the vector fonts, their bold weights, the interface font and Spleen. A pair names a character index in one byte, so the list holds 65 characters at most.

**Two characters have an equivalent glyph.** A font that lacks U+00A0 (the space with no break) or U+00AD (the soft hyphen) draws it with the glyph of the space or of the hyphen, and the build log names each such character. Both are the same form by definition: U+00A0 is a space that a line does not break at, and U+00AD shows as a hyphen where it shows. Paper Mono has no soft hyphen. Each other character that a font lacks stops the build, the euro sign too: a glyph of another letter would show a wrong letter, and the replacement glyph in one font and a letter in the other would make the fonts differ. A host test reads the source of each font and names each character that it lacks (`tools/modustool/vector_fonts_test.odin`). Each source font of the system has a glyph of its own for U+20AC.

A pair of the glyph cache names its two characters by their character index, in one byte each: 191 fits.

**What stays ASCII, and why.** A name that is an identifier of the system stays in the visible characters of ASCII:

- the name of a module, of an export, of a field and of a record of the module contract;
- the names of a debug object: types, fields, procedures, variables and paths of sources ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Debug information");
- the channel of a line of the log (the kernel takes the bytes 33 to 126);
- the name of a program: the kernel refuses a name with another byte at `Program_Create`, because the name starts each line of the program on the serial port; so the name of a disk program too;
- the name of a setting and of its values;
- the name of a font and of a pointer theme in their files;
- a command of the console, and in a palette entry its name, its act name, the name of its setting row and the name of its value.

Each of them is matched byte for byte against what a principal or a program types, in each layout, and is written in a log line and a file name of the host. A second form of the same identifier (é as one code point, or as e and a combining accent) would name a second thing. ASCII gives one form only.

Two shared procedures of `text_encoding` hold the rule: `identifier_valid` (one or more bytes 33 to 126) for an identifier, and `identifier_words_valid` (bytes 32 to 126) for identifiers joined by spaces, as the title of a setting ("subpixel order") and the name of a setting entry of the palette ("set font to spleen"). In a palette entry, the signature, the help sentence, the parameter names, the candidates, a `Text` argument and the runs of a result are text for a reader: UTF-8.

**The typed text is UTF-8.** The keys give characters of the Latin-1 Supplement and the euro sign ([../features/keyboard_layout.md](../features/keyboard_layout.md)), so each text that is only typed holds them:

- **The line editor** (`line_editor`) keeps the bytes of UTF-8. Its caret is a place in bytes, always before a whole character. Left and Right move over a whole character, Backspace and Delete remove a whole character, and a key inserts the UTF-8 of its code point. A line holds a character of a text (`printable`), and a whole character only: a line of `LINE_CAPACITY` bytes refuses a character whose bytes do not fit. The console and the terminal place the cursor in cells, by the count of characters before the caret.
- **The history file** keeps its form and its version: a line is UTF-8, checked with `text_valid`. A file of ASCII lines is a file of this form.
- **The match of the completion and of the palette** compares whole characters, and folds the case of ASCII only. The names that a principal searches are identifiers, which are ASCII; the search of a history line compares é with é. A fold of é to e is a rule of one language (German writes ü as ue, not u), it needs a table of each letter, and it would make two lines that differ by an accent the same line. A character is never matched by half of its bytes.
- **A `Text` argument of the palette** is UTF-8: the field takes each character that the keys give.
- **A passphrase** is the bytes of UTF-8 of its characters, with no normalization. The keys give one form of each character: é is the precomposed U+00E9 from its key and from a dead key. So the same keys give the same bytes. A passphrase typed under another layout gives other bytes, as an ASCII passphrase already does. A normalization (NFC) would need the tables of Unicode in `unlock` for no case that the keys can make.

The command `character` still writes a character from its code point: it writes a character that no key gives.

## The forms that were refused

- **UTF-16.** Every contract and every source of text is bytes already; UTF-16 doubles ASCII and still has sequences of two units.
- **Arrays of code points (UTF-32).** Four times the size of each field of fixed size, and a second form of each text of a call. Only the cell of a grid holds a code point, because it is one character by definition.
- **Latin-1.** One byte for each character fits the fields, but it holds no character outside Western Europe, and it is a second encoding beside the `Text` of the module contract.
- **A check in each contract with its own rule.** That is the state that this design removes: each contract had its own range of bytes.
- **The replacement character drawn as `?`.** A `?` is a character of a text: a reader cannot tell an invalid sequence from a question mark.
- **The code point as the index of a glyph cache.** A cache of the characters 32 to 255 has 33 entries for control characters that no text holds, and a reader still needs the check of those 33. The character index has no hole.
- **A list of ranges in the header of a cache.** Each reader would search the list for each character. The two ranges and the added characters are fixed by the contract, so they are constants, not fields.
- **A cache that holds the Latin-1 Supplement or not.** Each reader would then check the count of each cache, and a font that lacks é would draw a box in one font and é in the other. Each font holds the 192 characters, and the build refuses a font that lacks one.
- **A range for the characters past Latin-1.** A range from U+0152 to U+20AC holds about 8 000 characters, and no font of the system draws them all. See "A character past Latin-1 is added to a list" above.
- **The added characters in the order of their addition.** The index of a character would then never move. But no index is kept outside a build, and the character map of a subset needs its segments in the order of the code points: a list in that order is the one order for both.
- **The euro sign drawn with the glyph of another character.** E or C is a wrong character, and a price must not show a wrong currency. A font that lacks € stops the build, as for each other character.
- **A border that replaces where it can refuse.** A table that a provider wrote with an invalid sequence is a mistake of the provider; a refusal names it in the log, and a replacement hides it.

## Subtle points

- **A measure in bytes is wider than the drawing, never narrower.** A text of UTF-8 has at least as many bytes as characters. A program that still places a text by its count of bytes leaves a gap after a character outside ASCII; it never draws a text over another. `interface.text_width`, `graphics.text_width` and `text_fit` count characters.
- **A writer cuts, a reader checks.** A record of the terminal of 256 bytes ends after a whole character, so a reader never sees half a character at the end of a run. A program that writes the ring by hand can still split one: the terminal draws two replacement glyphs, and nothing more happens.
- **The check of the kernel is a filter of bytes, not a text parser.** It keeps no state between two calls and builds no structure, as the check of the channel does. It must be in the kernel: a program calls `Log` itself, so a check in the support library is no check.
- **The kernel replaces with `?`, not with U+FFFD.** U+FFFD is three bytes, and the value runs of a log line name offsets into the text.
- **Bidirectional controls are characters of a text.** The drawing has no bidirectional algorithm: such a character the font lacks draws the replacement glyph and changes no order. A terminal of the host that reads the serial port can reorder a line with them; the log is for the developer, and the rule refuses the controls that act on a terminal.
- **One code point, one cell.** A combining accent and a wide character take one cell each. No font of the system draws them, so each draws the replacement glyph in its own cell.
- **The place of the caret is in bytes, the cursor in cells.** A line of `été` has 5 bytes and 3 cells. The line editor keeps bytes, because the text is bytes; a reader that draws counts the characters before the caret.
- **A cut of a typed line.** A line of the history and a line that `line_set` receives end after a whole character (`complete_characters`), so a cut never leaves half of é.

## State

Built: the contract package and its host tests; the checks of the palette table, the store names and the kernel log; the cut of the terminal library, the cut mark, the console output and the log of the support library; the drawing of the cells, of text and of the shaper with the replacement glyph; the cell of a grid as a code point; the command `character` with a machine test; the keys that give a character of the Latin-1 Supplement; the line editor by character, its history file and the passphrase in UTF-8; the glyphs of the Latin-1 Supplement in the glyph caches and in Spleen, with the machine test that types é; the list of the added characters with the euro sign, and the machine test that types €.

Left: each other character past the Latin-1 Supplement. Each one joins the list when each font draws it and a key or a principal needs it.
