# The layout of the keyboard

A key gives a character by the layout of the keyboard that the principal chose. This file records where that choice lives, who reads it, what a key record carries, and how the layout of France gives its accented letters. The setting and the settings page are in [`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting".

## The chosen form

- **A setting.** `keyboard_layout` is one value of the settings page: `us`, the default, or `french`. The principal changes it as each other setting, with the program `settings`, the console or the palette.
- **The input service reads it at each key.** The root service maps the settings page, read-only, in the input service. The service turns a key into a character, so it is the one reader of the layout. A change takes effect at the next key, with no message.
- **The tables are in one support package.** `src/library/support/keyboard_layout` holds the two layouts and the dead keys, with no state of its own and no kernel call, so a host test presses each key. The input service keeps the one state: the accent that waits.
- **A key record carries a code point.** The value `character` of the record `Key` of the input ring is the code point of the character of the key, or 0. `display.Event.character`, the key of `interface.Input` and `terminal.Key.character` are a `rune`. A program that keeps the character writes its UTF-8 (`text_encoding.character_encode`). Each other contract was UTF-8 before the keys gave a character outside ASCII ([../data/text_encoding.md](../data/text_encoding.md)), so this change touched the key path, the line editor and the fonts only.
- **The layout of France gives its letters.** The keys of the row of the digits give é, è, ç and à; the key right of `m` gives ù; the other keys give ², °, £, µ and § as on an AZERTY keyboard. Each of them is in the Latin-1 Supplement, which each font of the system draws. The key between the left Shift and W gives `<` and `>`, which the console needs for its comparisons.
- **Two dead keys: `^` and `¨`.** The key right of `p` is the circumflex; with Shift it is the diaeresis. A dead key gives no character. The next key that gives a character gives the accented letter: `^` then `e` gives ê, `¨` then `i` gives ï, for a, e, i, o, u and their capitals, and ÿ. The dead keys are needed: the words of French hold â, ê, î, ô, û, ë, ï and ü (être, fenêtre, naïf, Noël), and an AZERTY keyboard has no other key for them.

The rules of a dead key, in the order of the check:

1. A dead key while an accent waits gives the waiting accent alone, and no accent waits after it: `^` `^` gives `^`.
2. A space gives the accent alone: `^` then space gives `^`.
3. A letter with an accented form in the Latin-1 Supplement gives that form. Ÿ is outside it, so `¨` then Shift `y` follows rule 4.
4. Another key with a printable character gives two key records: the first has the code of that key and the accent alone, the second has the code of that key and its character. `^` then `z` gives `^z`. The input service reads the byte of that key only when the input ring has room for two records, so no record is lost (see [key_path.md](key_path.md)).
5. A key with a control character (Enter, Tab, Backspace) or with no character (Escape, an arrow key) drops the accent, and acts as itself.
6. Shift and Control keep the accent waiting: a capital letter after a dead key needs Shift.

A release gives the character of its key with no accent, and a dead key gives 0 in its press and in its release: a program reads the character of a press.

## The refused forms

- **The layout in the compositor.** The compositor receives key records that already hold their character. A layout there would put a second translation of keys in a program that has no other reason to know one.
- **A message to the input service at each change.** It needs a ring from `settings` to the input service and a second path for one value. The page is already shared with one writer, and its read is one load for each key.
- **A second field for a character outside ASCII.** One field `character` for the ASCII byte and one for a code point would give two terms for one concept, and each reader would check two fields. The field is a code point, and an ASCII character is its own code point.
- **The bytes of UTF-8 in the key record.** A program then decodes a key before it compares it with a letter. A code point is compared directly (`event.character == 'q'`), and the writer of a text encodes it once.
- **A dead key that gives a combining accent.** U+0302 after a letter is a second form of ê. The identifiers and the passphrases compare bytes, so ê must have one form: the precomposed code point.
- **A compose key and AltGr.** A compose key is not on the keyboard of France. AltGr gives `#`, `{`, `[`, `|`, `@`, `]`, `}`, `` ` `` and `~` there; it is a separate change of the tables (`ROADMAP.md`), and the layout of the United States types each of those characters.
- **A dead key that drops a character it cannot combine.** `^` then `z` would lose the `^` in silence. Two records keep both characters.

## Subtle points

- **The room of two records.** The input service checks the room of the input ring before it takes a byte from the controller. While an accent waits, it needs room for two records, so a byte waits in the controller until the compositor read half the ring, as for one record.
- **Shift after a dead key.** Shift is a key with no character. It must not drop the accent, else `¨` then Shift `i` cannot give Ï.
- **A change of the layout while an accent waits.** The accent waits through the change; the next key reads the new layout and combines with it as rule 3 or 4 says.
- **The key records of a dead key carry no accent.** A dead key gives 0 in its press and in its release, and a program that reads the code of a key (a game, a shortcut) still sees the key.

## State

Built: the two layouts, the setting and its read in the input service, the key record that carries a code point, the letters and the two dead keys of the layout of France, and the host tests of the tables. Left: AltGr.
