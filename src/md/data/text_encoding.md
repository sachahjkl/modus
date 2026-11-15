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
- **The fonts hold 32 to 126 only.** The glyph caches and Spleen have no glyph outside ASCII.
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

**The cell of a text grid holds a code point.** `interface.Text_Grid_Cell.character` is a `rune`. One cell is one character, so the reader that fills a grid decodes the text once, and the grid compares and draws cells with no decode. The cell grows from 12 to 16 bytes, with two reserved bytes of 0 in place of a hidden pad, because `draw_text_grid` copies the cells into the text table of the frame and the drawing module reads them there ([../api/text_grid.md](../api/text_grid.md)): the bytes of a cell are part of the border of the module. So the draw record is version 10, and the exports are `damage_of_draw_table_10` and `execute_draw_table_10`. A cell with the bytes of UTF-8 needs 4 bytes and a length, the same size, and a decode at each draw. A cell of a hostile caller with a code point that is no character of a text (a surrogate, a number past U+10FFFF) draws the replacement glyph.

**The drawing of a character that the font lacks: one replacement glyph.** The drawing decodes UTF-8 and gives each character one cell (`graphics.text_scaled`, `text_bold`, `text_width`), or one placed glyph (`text_shaping.shape`). A character outside 32 to 126, a control character and each invalid sequence draw the replacement glyph: the outline of a box from the top of a capital letter to the baseline (`graphics.character_replacement`). Code draws it, in each font and at each scale, so no font needs a glyph for it. A byte is never drawn as a glyph, so a reader always sees that a character is there. The shaper gives the placed glyph `REPLACEMENT_GLYPH`, with the advance of `0` and no pair, and the first byte of each character as its cluster.

**The glyphs of Latin-1 are not built.** The cache builder draws 32 to 126 (`glyph_cache.CHARACTER_LIMIT`), and the Spleen data holds the same range. The glyphs of the Latin-1 Supplement are part of the work of the keys, in `ROADMAP.md`: the format of the glyph cache keys a character in one byte, so that work changes the cache format, the builder, the font command and the bounds of the boot image together.

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

**What stays ASCII until the keys give other characters.** The line of the console, its history file and a passphrase are typed only. The line editor moves its caret by bytes. The palette refuses a `Text` argument outside ASCII in words ("a line of the console holds no character outside ASCII yet"), so a value is never changed in silence. The command `character` writes a character from its code point, so a principal can write é before the keys give it. A passphrase that the keys cannot type would lock its principal out.

## The forms that were refused

- **UTF-16.** Every contract and every source of text is bytes already; UTF-16 doubles ASCII and still has sequences of two units.
- **Arrays of code points (UTF-32).** Four times the size of each field of fixed size, and a second form of each text of a call. Only the cell of a grid holds a code point, because it is one character by definition.
- **Latin-1.** One byte for each character fits the fields, but it holds no character outside Western Europe, and it is a second encoding beside the `Text` of the module contract.
- **A check in each contract with its own rule.** That is the state that this design removes: each contract had its own range of bytes.
- **The replacement character drawn as `?`.** A `?` is a character of a text: a reader cannot tell an invalid sequence from a question mark.
- **A border that replaces where it can refuse.** A table that a provider wrote with an invalid sequence is a mistake of the provider; a refusal names it in the log, and a replacement hides it.

## Subtle points

- **A measure in bytes is wider than the drawing, never narrower.** A text of UTF-8 has at least as many bytes as characters. A program that still places a text by its count of bytes leaves a gap after a character outside ASCII; it never draws a text over another. `interface.text_width`, `graphics.text_width` and `text_fit` count characters.
- **A writer cuts, a reader checks.** A record of the terminal of 256 bytes ends after a whole character, so a reader never sees half a character at the end of a run. A program that writes the ring by hand can still split one: the terminal draws two replacement glyphs, and nothing more happens.
- **The check of the kernel is a filter of bytes, not a text parser.** It keeps no state between two calls and builds no structure, as the check of the channel does. It must be in the kernel: a program calls `Log` itself, so a check in the support library is no check.
- **The kernel replaces with `?`, not with U+FFFD.** U+FFFD is three bytes, and the value runs of a log line name offsets into the text.
- **Bidirectional controls are characters of a text.** The drawing has no bidirectional algorithm: such a character the font lacks draws the replacement glyph and changes no order. A terminal of the host that reads the serial port can reorder a line with them; the log is for the developer, and the rule refuses the controls that act on a terminal.
- **One code point, one cell.** A combining accent and a wide character take one cell each. No font of the system draws them, so each draws the replacement glyph in its own cell.

## State

Built: the contract package and its host tests; the checks of the palette table, the store names and the kernel log; the cut of the terminal library, the cut mark, the console output and the log of the support library; the drawing of the cells, of text and of the shaper with the replacement glyph; the cell of a grid as a code point; the command `character` with a machine test.

Left (the roadmap entry "Keys that type characters outside ASCII"): the keys that give a character outside ASCII, a line editor that moves by character, its history file, a passphrase outside ASCII, and the glyphs of the Latin-1 Supplement in the glyph caches and in Spleen.
