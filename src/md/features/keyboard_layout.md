# The layout of the keyboard

A key gives a character by the layout of the keyboard that the principal chose. This file records where that choice lives and who reads it. The setting and the settings page are in [`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting".

## The chosen form

- **A setting.** `keyboard_layout` is one value of the settings page: `us`, the default, or `french`. The principal changes it as each other setting, with the program `settings`, the console or the palette.
- **The input service reads it at each key.** The root service maps the settings page, read-only, in the input service. The service turns a key into a character, so it is the one reader of the layout. A change takes effect at the next key, with no message.
- **A character is one byte of ASCII.** A key whose character in the layout is outside ASCII gives no character. The text of the system is UTF-8 in every contract ([data/text_encoding.md](../data/text_encoding.md)), so a key that gives é changes the key path, the line editor and the fonts only.

## The refused forms

- **The layout in the compositor.** The compositor receives key records that already hold their character. A layout there would put a second translation of keys in a program that has no other reason to know one.
- **A message to the input service at each change.** It needs a ring from `settings` to the input service and a second path for one value. The page is already shared with one writer, and its read is one load for each key.

## State

Built: the two layouts, the setting and its read in the input service. Left: the characters of Unicode, so that the layout of France gives é, è, ç, à and ù (`ROADMAP.md`).
