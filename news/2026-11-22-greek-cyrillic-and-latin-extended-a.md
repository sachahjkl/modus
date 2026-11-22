title: Greek, Cyrillic and Latin Extended-A in every window
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: docs/FONTS.md

Each window and each cell of a terminal now draws every Greek letter, the 96 basic Cyrillic letters (U+0400 to U+045F) and the 128 letters of Latin Extended-A (U+0100 to U+017F). So a principal writes Greek, Russian, Polish or Czech in a label, a title or the console.

The letters come from Noto Sans, the last font of each fallback chain. A letter that B612 or Paper Mono has keeps its glyph; Noto Sans gives only the others, such as Π, ρ, Ж and Ł. The process draws each one itself, at its first use, as it draws each other glyph past the 192 characters.

The subset of Noto Sans holds 465 characters in 87 172 bytes of the boot image.
