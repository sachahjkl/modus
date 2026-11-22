type: Added

**Desktop-free full-featured console renderers (`ansi_terminal` and `grid_renderer`).** Added a 24-bit TrueColor ANSI VT100 renderer + input decoder (`src/library/internal/terminal/ansi_terminal`), a dirty-row Spleen 8x16 direct framebuffer grid renderer (`src/library/internal/terminal/grid_renderer`), and a zero-dependency ANSI console web page (`browser_machine_console.html`) preserving full console colors, Lex syntax highlighting, and interactive completion popups without a desktop compositor.
