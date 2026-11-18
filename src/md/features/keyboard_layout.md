# The layout of the keyboard

A key gives a character by the layout of the keyboard that the principal chose. This file records where that choice lives, who reads it, what a key record carries, and how the layout of France gives its accented letters. The setting and the settings page are in [`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting".

## The chosen form

- **A setting.** `keyboard_layout` is one value of the settings page: `us`, the default, or `french`. The principal changes it as each other setting, with the process `settings`, the console or the palette.
- **The input service reads it at each key.** The root service maps the settings page, read-only, in the input service. The service turns a key into a character, so it is the one reader of the layout. A change takes effect at the next key, with no message.
- **The tables are in one private part of the input service.** `src/library/private/input/keyboard_layout` holds the two layouts, the third level and the dead keys, with no state of its own and no kernel call, so a host test presses each key. The input service keeps the one state: the accent that waits.
- **A key record carries a code point.** The value `character` of the record `Key` of the input ring is the code point of the character of the key, or 0. `display.Event.character`, the key of `interface.Input` and `terminal.Key.character` are a `rune`. A process that keeps the character writes its UTF-8 (`text_encoding.character_encode`). Each other contract was UTF-8 before the keys gave a character outside ASCII ([../data/text_encoding.md](../data/text_encoding.md)), so this change touched the key path, the line editor and the fonts only.
- **The layout of France gives its letters.** The keys of the row of the digits give é, è, ç and à; the key right of `m` gives ù; the other keys give ², °, £, µ and § as on an AZERTY keyboard. Each of them is in the Latin-1 Supplement, which each font of the system draws. A host test checks that each character of each layout has a character index. The key between the left Shift and W gives `<` and `>`, which the console needs for its comparisons.
- **Two dead keys: `^` and `¨`.** The key right of `p` is the circumflex; with Shift it is the diaeresis. A dead key gives no character. The next key that gives a character gives the accented letter: `^` then `e` gives ê, `¨` then `i` gives ï, for a, e, i, o, u and their capitals, and ÿ. The dead keys are needed: the words of French hold â, ê, î, ô, û, ë, ï and ü (être, fenêtre, naïf, Noël), and an AZERTY keyboard has no other key for them.
- **AltGr gives the third level.** The right Alt key (scan code E0 38) of the layout of France is AltGr. With it held, the keys of the row of the digits give the characters that an AZERTY keyboard prints on their right side: `#` (3), `{` (4), `[` (5), `|` (6), `\` (8), `^` (9), `@` (0), `]` (the key right of 0) and `}` (the key of `=`); the key of `$` gives `¤`, and the key of `e` gives €. The console language needs the brackets, the braces, `|`, `#`, `@` and `\`, and the layout of France has no other key for them. Shift with AltGr gives the third level too: the layout builds no fourth level, and a key then gives the character that it shows. A key with no character on the third level (a letter other than `e`, `;`) gives none. Space, Tab, Enter and Backspace act as themselves. The layout of the United States has no third level: there AltGr is the right Alt key and changes no character.
- **Two more dead keys on the third level: `~` and `` ` ``.** AltGr with the key of 2 is the tilde, AltGr with the key of 7 the grave accent, as on each AZERTY keyboard. They follow the rules below: `~` then `n` gives ñ, `` ` `` then Shift `a` gives À, `~` then space gives `~`. A plain key saves the space after `~` and `` ` ``. But French needs À, È and Ù at the start of a sentence, the keyboard has no other key for them, and the hands of a principal who types AZERTY expect the dead form. The tilde makes ã, õ, ñ and their capitals; the grave accent makes à, è, ì, ò, ù and their capitals. Each is in the Latin-1 Supplement.
- **AltGr with `e` gives the euro sign.** € is on the key `e` of each AZERTY keyboard, and a principal needs it to write a price. € is U+20AC, past the Latin-1 Supplement: it is the first added character of the fonts, with the character index 191 ([../data/text_encoding.md](../data/text_encoding.md)). Each font of the system draws it, so the key gives it with no other change of the key path. With Shift and AltGr it gives € too, as each key of the third level. A dead key before it follows rule 4: `^` then AltGr `e` gives `^€`.

The rules of a dead key, in the order of the check:

1. A dead key while an accent waits gives the waiting accent alone, and no accent waits after it: `^` `^` gives `^`.
2. A space gives the accent alone: `^` then space gives `^`.
3. A letter with an accented form in the Latin-1 Supplement gives that form. Ÿ is outside it, so `¨` then Shift `y` follows rule 4.
4. Another key with a printable character gives two key records: the first has the code of that key and the accent alone, the second has the code of that key and its character. `^` then `z` gives `^z`. The input service reads the byte of that key only when the input ring has room for two records, so no record is lost (see [key_path.md](key_path.md)).
5. A key with a control character (Enter, Tab, Backspace) or with no character (Escape, an arrow key) drops the accent, and acts as itself.
6. Shift, Control and AltGr keep the accent waiting: a capital letter after a dead key needs Shift, and `^` then AltGr `4` gives `^{` by rule 4.

A release gives the character of its key with no accent, and a dead key gives 0 in its press and in its release: a process reads the character of a press.

## The refused forms

- **The layout in the compositor.** The compositor receives key records that already hold their character. A layout there would put a second translation of keys in a process that has no other reason to know one.
- **A message to the input service at each change.** It needs a ring from `settings` to the input service and a second path for one value. The page is already shared with one writer, and its read is one load for each key.
- **A second field for a character outside ASCII.** One field `character` for the ASCII byte and one for a code point would give two terms for one concept, and each reader would check two fields. The field is a code point, and an ASCII character is its own code point.
- **The bytes of UTF-8 in the key record.** A process then decodes a key before it compares it with a letter. A code point is compared directly (`event.character == 'q'`), and the writer of a text encodes it once.
- **A dead key that gives a combining accent.** U+0302 after a letter is a second form of ê. The identifiers and the passphrases compare bytes, so ê must have one form: the precomposed code point.
- **A compose key.** A compose key is not on the keyboard of France, and AltGr with the four dead keys reaches each character that the layout needs.
- **Control and Alt together as AltGr.** Some systems read Control with the left Alt as AltGr. With that form, a shortcut of Control and left Alt with a key of the row of the digits gives a character, and a process cannot tell the two apart. AltGr is the right Alt key only.
- **A modifier bit of AltGr in the key record.** The character of the record already holds the third level, and no process reads AltGr as a modifier. A bit with no reader is a second term for the same fact.
- **AltGr with Shift as no character.** With that form, a key with Shift and AltGr gives nothing, and a principal who holds Shift a moment too long loses a character in silence. The third level ignores Shift.
- **A dead key that drops a character it cannot combine.** `^` then `z` would lose the `^` in silence. Two records keep both characters.

## Subtle points

- **The room of two records.** The input service checks the room of the input ring before it takes a byte from the controller. While an accent waits, it needs room for two records, so a byte waits in the controller until the compositor read half the ring, as for one record.
- **Shift after a dead key.** Shift is a key with no character. It must not drop the accent, else `¨` then Shift `i` cannot give Ï.
- **A change of the layout while an accent waits.** The accent waits through the change; the next key reads the new layout and combines with it as rule 3 or 4 says.
- **The key records of a dead key carry no accent.** A dead key gives 0 in its press and in its release, and a process that reads the code of a key (a game, a shortcut) still sees the key.
- **AltGr is an extended key.** The left Alt key is 0x38 and gives no third level. The input service sets its state of AltGr only for 0x38 after the prefix 0xE0, so the left Alt key never changes a character.
- **The release of a key after AltGr.** A release gives the character of its key on the level that is held at the release, as for Shift: a process reads the character of a press.
- **A machine test types by the QWERTY names.** The tool names a key by its place on a QWERTY keyboard: `alt_r-4` is AltGr with the key that gives `{`, `alt_r-minus` gives `]`, and `alt_r-e` gives €. The text `%` is Shift with the key of 5, which gives `5` on the layout of France.

## State

Built: the two layouts, the setting and its read in the input service, the key record that carries a code point, the letters, the third level with the euro sign and the four dead keys of the layout of France, the host tests of the tables, and the machine test that types `"5 €"`.
