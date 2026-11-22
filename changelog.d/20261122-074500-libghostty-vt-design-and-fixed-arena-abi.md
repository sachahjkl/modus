type: Added

**Freestanding `libghostty-vt` design and fixed-arena C-ABI allocator bridge.** Recorded the `libghostty-vt` (MIT) integration design in `src/md/features/ghostty_vt.md` (keeping the small Odin `terminal` in the Zig-free bootstrap seed) and added `modus:contract/ghostty_vt` implementing the bounded fixed-arena `Ghostty_Allocator` vtable and validated terminal options.
