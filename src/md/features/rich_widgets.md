# Rich interactive widgets in `modus:interface`

Applications in `modus` share a complete, stylable set of interactive desktop controls in `src/library/modus/interface` (`theme.odin`, `rich_widgets.odin`, `toolbar.odin`, `selection_widgets.odin`, `data_widgets.odin`) built directly on the draw table, `graphics.colors`, `modus:layout`, and `accessibility` roles.

## Purpose

Earlier windows relied on flat track rectangles (`button`) and hardcoded `graphics.colors` references: controls such as dropdowns, multi-select chip pickers, checkboxes, radio groups, adaptive collapsing toolbars, numeric steppers, disclosures, multi-line text areas, draggable split panes, sortable multi-select tables, tree views, tooltips, and modals had to be rebuilt in every module. A single stylable, freestanding widget suite gives every application cohesive defaults while allowing per-window or per-subtree theming with zero heap allocation and rectangular machined geometry (`docs/DESIGN.md`, sections 2–4).

## The chosen form

- **Scoped theme stack (`theme.odin`, `Widget_Theme`, `theme_push`, `theme_pop`, `theme_current`)**: `Frame` carries a fixed stack of `THEME_STACK_CAPACITY` (8) `Widget_Theme` records holding surface, border, text, accent, intent, and spacing tokens. An empty stack resolves dynamically from `graphics.colors` (dark, light, and forced high-contrast modes). Pushing a custom `Widget_Theme` restyles every widget drawn inside that subtree until popped.
- **Button variants (`Button_Variant`, `button_styled`)**: `Secondary`, `Primary`, `Ghost`, `Danger`, and `Sidebar_Row` with distinct Rest, Hover, Pressed, Focused, Selected/Open, and Disabled states driven by `theme_current(frame)`. `button()` delegates to `.Secondary`.
- **Toggle switch, checkboxes, and radio groups (`toggle_switch`, `checkbox`, `checkbox_tri`, `radio_group`)**: Rectangular machined switch, 2-state and 3-state (`Unchecked`, `Checked`, `Mixed`) checkboxes, and vertical/horizontal radio groups with full keyboard navigation and WAI-ARIA roles.
- **Segmented control and tab bar (`segmented_control`, `tab_bar`)**: Connected horizontal selectors and measured tab strips with keyboard stepping and mouse-wheel tab switching.
- **Adaptive collapsing toolbar (`toolbar.odin`, `Toolbar_Overflow`)**: Groups of toolbar items with priority, separators, `end`, and `pinned` flags. `.Fold` keeps one line, pins `pinned` groups at the right edge, and folds lowest-priority items first into a `"…"` overflow menu (`Context_Menu_State`) with section headers, shortcuts, and active checkmarks. `.Wrap` wraps groups across multiple rows (moving each group whole when it fits on one line, wrapping items when a single group exceeds line width) and computes exact multi-line height via `toolbar_measure_height` for `modus:layout`.
- **Dropdown, searchable combobox, and multi-select (`selection_widgets.odin`, `dropdown_trigger`, `dropdown_overlay`, `multi_select_trigger`, `multi_select_overlay`)**: Single-select dropdown and filterable combobox with floating overlays that flip upward near the window bottom, keyboard navigation (`Up`/`Down`/`Home`/`End`/`Enter`/`Escape`), mouse-wheel scrolling, and click-outside dismissal. Multi-select renders removable tag chips (`×` click and `Backspace` removal) inside the trigger and a floating checklist overlay with live filtering and Select-All/Clear actions.
- **Numeric controls and disclosures (`slider`, `slider_with_value`, `number_stepper`, `disclosure`, `progress_bar`)**: Draggable slider with inline editable readout, `-`/`+` numeric stepper with wheel and `Shift` coarse steps, collapsible disclosure headers, and determinate/indeterminate progress bars.
- **Multi-line text area (`text_area`)**: Caller-owned `[]u8` buffer with line wrapping/scrolling, caret movement (`Left`/`Right`/`Up`/`Down`/`Home`/`End`), newline insertion, deletion, optional line numbers, and clipboard copy/paste.
- **Structural and data controls (`data_widgets.odin`, `split_pane_divider`, `data_table`, `tree_view`, `reorder_list`)**: Interactive draggable split divider synced to `modus:layout` ratios with double-click 50/50 reset; reusable sortable, column-resizable, single/multi-select data table; hierarchical expandable tree view with indent guides and `Left`/`Right`/`Up`/`Down` navigation; and drag-and-drop reorderable list.
- **Floating overlays (`tooltip_draw`, `modal_dialog_begin`, `modal_dialog_end`, `context_menu`, `command_palette`)**: Window-clamped hover tooltips, dimmed scrim modal dialogs with `Escape`/outside-click dismissal, right-click context menus, and `Ctrl+K` command palettes.

## Refused forms

- **Heap-allocated retained widget trees inside `modus:interface`.** Freestanding system modules forbid allocators (`modustool check static`); caller-owned fixed structs (`Toolbar_State`, `Dropdown_State`, `Multi_Select_State`, `Data_Table_State`, `Tree_View_State`, `Text_Area_State`, `Reorder_Drag_State`) keep all state explicit and bounded.
- **Copying `gui_toolkit` code.** `gui_toolkit` allocates, uses floats, and imports `core:`; `modus:interface` reimplements the same ergonomic controls directly on the integer draw table and `modus:layout`.
- **Rounded-pill switches and blurred shadows.** Rectangular forms and sharp shadows keep visual unity with `docs/DESIGN.md`.

## State

Built: scoped `Widget_Theme` stack, adaptive collapsing/wrapping `toolbar`, `checkbox`/`checkbox_tri`, `radio_group`, `dropdown` (with searchable combobox), `multi_select` (with removable chips), `number_stepper`, `disclosure`, `progress_bar`, `text_area`, `split_pane_divider`, `data_table`, `tree_view`, `tooltip_draw`, `modal_dialog`, `button_styled`, `toggle_switch`, `segmented_control`, `tab_bar`, `slider`/`slider_with_value`, `badge`, `reorder_list`, host unit tests covering adversarial edge cases, and the responsive `modus:layout`-driven `interface_elements` component showcase application.
