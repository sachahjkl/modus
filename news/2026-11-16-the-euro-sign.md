title: The keyboard of France types the euro sign
date: 2026-11-16
release: next
picture: docs/screenshots/keys_french.png
kind: Shown
guide: docs/FONTS.md

With the setting `keyboard_layout` on `french`, AltGr with `e` types €, as on each AZERTY keyboard. The console prints `5 €`. Each font of the system draws the sign: Paper Mono, its SemiBold, B612 and Spleen. € is U+20AC, past the Latin-1 Supplement. It is the first character of a short list of added characters: each one is chosen, and each font must draw it.
