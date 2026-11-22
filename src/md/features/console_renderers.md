# Desktop-free console renderers

The console (`src/modules/system/console`) writes only typed records onto the `modus:terminal` ring: styled text runs, Lex `Code_Runs`, cursor position, status bar, hints, and the interactive `List_Keeping` completion popup. It draws no pixels. A desktop-free modus profile keeps the entire console experience — full 24-bit colors, real-time syntax highlighting, interactive completion popups, `Ctrl+R` history search, tables, and `log.follow` — by swapping only the terminal renderer on the other end of the ring.

## Variant A: `serial_terminal` (ANSI 24-bit TrueColor over COM1)

`src/library/internal/serial_terminal/ansi_terminal` and `src/modules/system/serial_terminal` translates typed `modus:terminal` records into 24-bit TrueColor ANSI escape sequences (`\x1b[38;2;R;G;Bm`, `\x1b[48;2;R;G;Bm`, cursor movement, Unicode box-drawing completion popup) and decodes VT100/UTF-8 input bytes (arrows, Home/End, Delete, Shift+Tab, Tab, Escape, `Ctrl+A..Z`) back into `terminal_records.Key`. Untrusted ESC bytes inside output text are sanitized to `?` so no process can inject escape sequences. Overlong CSI sequences reset cleanly to Ground.

This variant needs no compositor, no drawing module, no TrueType fonts, and no framebuffer. It targets QEMU `-nographic`, headless servers/distributed builders, hardware UART, and the zero-dependency `browser_machine_console.html` web page.

## Variant B: `grid_terminal` (direct framebuffer monospace grid)

`src/library/internal/grid_terminal/grid_renderer` and `src/modules/system/grid_terminal` renders the same typed terminal grid and completion popup directly onto a linear framebuffer using `graphics.character` (Spleen 8x16 bitmap font) with per-row dirty tracking — no compositor, no window chrome, and no TrueType outline rasterization.

## State

Built and host-tested: `ansi_terminal` (ANSI 24-bit renderer + VT100/UTF-8 decoder), `grid_renderer` (dirty-row Spleen 8x16 direct framebuffer renderer + completion popup overlay/restore), and `tools/modustool/build/browser_machine/browser_machine_console.html`.

Left: wiring a dedicated `console` start policy in `start_lists.odin` and module entry loops connecting COM1 / direct framebuffer to `console`'s terminal ring for live QEMU `-nographic` and console-only web boots.
