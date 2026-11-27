# Per-application command palettes and compact context menus

Every desktop window in `modus` can provide its own right-click context menu and fuzzy-filtered command palette through `modus:interface` (`src/library/modus/interface/context_menu.odin`, `src/library/modus/interface/command_palette.odin`), while the compositor keeps the desktop background menu, taskbar plate menu, and window titlebar menu.

## Purpose

A desktop where only the background owns right-click and every application lists its shortcuts in a static footer bar feels frozen and uniform. Applications need two native overlay primitives that follow the design rules (`docs/DESIGN.md`, sections 2 and 3) without duplicating filtering, hit-testing, or drawing:

- **Compact context menus** (`interface.context_menu_open_compact`) for crisp right-click action lists over window titlebars, taskbar plates, and application panes, with optional group dividers (`separator_before`), destructive styling (`danger`), and sharp drop shadows (`colors.shadow` and `colors.edge`).
- **Per-application command palettes** (`interface.Command_Palette_State`) opened by `Ctrl+K` or `Ctrl+Shift+P` (or `Ctrl+Shift+P` alone in terminal windows so bare `Ctrl+K` remains free for shell line editing), with fuzzy subsequence + category matching, keyboard and wheel scrolling, and a slim match-count footer.

## Constraints

- **No heap allocation.** Both `Context_Menu_State` and `Command_Palette_State` live in fixed-capacity module memory (`CONTEXT_MENU_MAX_ITEMS :: 32`, `COMMAND_PALETTE_MAX_ITEMS :: 48`) so freestanding modules never allocate.
- **Right-click reaches the surface under the pointer.** `interface.Input` tracks `BUTTON_RIGHT` edges (`right_pressed`, `right_released`, `right_held`, `right_press_x`, `right_press_y`) and `window_scroll.odin` shifts right-press coordinates alongside left-press coordinates in scrolled layouts. The compositor routes surface right-clicks to the window, titlebar/frame right-clicks to the compact window action menu, taskbar plate right-clicks to the compact taskbar menu, and empty desktop right-clicks to the filterable desktop menu.
- **No cut text in Spleen 8x16.** `CONTEXT_MENU_COMPACT_WIDTH :: 256` holds the widest compositor label plus shortcut (`"Snap right"` + `"Ctrl+Shift+Right"`, 224 px) inside 232 px of label room.
- **No leaked clicks or cursor shapes.** Overlays consume pointer events inside their bounds, clear per-frame pressed flags and wheel deltas so underlying scroll bars never move, ignore `Control`/`Alt`-modified characters in filter inputs, and keep cursor shapes accurate over disabled rows, dividers, and filter fields.

## Refused forms

- **One global palette owned by the compositor for per-window commands.** A window knows its live state (enabled actions, document selection, mode); moving per-app actions over IPC into the compositor would add round-trip latency and stale menus.
- **Bare `Ctrl+K` in `terminal`.** `terminal` hosts `console` and `linux`; stealing `Ctrl+K` breaks readline/bash kill-to-end-of-line (`0x0B`). Terminal windows bind `Ctrl+Shift+P` instead.
- **Rounded translucent menus with blurred shadows.** `docs/DESIGN.md` specifies rectangular forms and sharp solid shadows (`colors.shadow`) until GPU effects are introduced.

## State

Built: `BUTTON_RIGHT` tracking in `modus:interface`, compact `Context_Menu_State` with separators and danger styling, `Command_Palette_State`, compositor titlebar and taskbar compact menus, and the resize-safe `terminal` status bar with `Follow` and `Ctrl+Shift+P` pills, right-click menu, and command palette.
