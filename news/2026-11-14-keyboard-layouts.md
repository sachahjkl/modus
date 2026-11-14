title: Keyboard layouts
date: 2026-11-14
release: next
picture: docs/screenshots/settings.png
kind: Shown
guide: docs/FONTS.md

The keyboard has a layout. The window of `settings` has a row for it, with two values: `us`, the QWERTY layout, and `french`, the AZERTY layout. The input service reads the setting at each key, so a change holds from the next key, with no restart.

The test of the machine types the same key under each layout: it gives `a` with the layout of France, then `q` with the layout of the United States.

A character of the system is one byte of ASCII today. A key whose character is outside ASCII, such as é or ç, gives no character yet; a program still gets its key code.
