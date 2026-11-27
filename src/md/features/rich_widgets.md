# Rich interactive widgets in `modus:interface`

Applications in `modus` share a reusable set of interactive desktop controls in `src/library/modus/interface/rich_widgets.odin` built directly on the draw table, `graphics.colors`, and `accessibility` roles.

## Purpose

Earlier windows relied on flat track rectangles (`button`) for every control: toggles, tabs, multi-choice pickers, and lists looked identical and gave no pressed-in feedback or drag-and-drop manipulation. Rich widgets give every application cohesive desktop controls while keeping zero heap allocation and rectangular machined geometry (`docs/DESIGN.md`, sections 2–4).

## The chosen form

- **Button variants (`Button_Variant`, `button_styled`)**: `Secondary` (machined gradient track with subtle border and top highlight), `Primary` (solid `colors.chosen` gradient), `Ghost` (flat until hovered), `Danger` (`colors.stop_process`), and `Sidebar_Row` (navigation item with 3 px `colors.title` active accent rail). Every variant renders distinct Rest, Hover, Pressed (`state.pressed == element && input.button_held`), Focused (`draw_focus_ring`), Selected/Open, and Disabled states. `button()` delegates to `.Secondary` so existing windows gain hover/pressed depth automatically.
- **Toggle switch (`toggle_switch`)**: Rectangular machined track (`36 × 18` px) with a sliding thumb, label on the left, click-anywhere-on-row and Space/Enter activation, and WAI-ARIA `.Switch` role.
- **Segmented control (`segmented_control`)**: Connected horizontal multi-choice selector inside a single recessed frame (`colors.recess`), with `.Radio_Group`/`.Radio` accessibility and Left/Right keyboard stepping.
- **Tab bar (`tab_bar`)**: Measured horizontal tabs over a bottom divider hairline, with a 2 px `colors.title` bottom indicator on the active tab, hover highlight, mouse-wheel tab switching, and Left/Right/Home/End keyboard navigation (`.Tab_List`/`.Tab`).
- **Slider and editable value (`slider`, `slider_with_value`, `Slider_Edit_State`)**: Horizontal value track with filled `colors.chosen` progress, draggable rectangular thumb (`12 × 18` px), step snapping, mouse-wheel stepping (consuming wheel input so parent containers stay still), double-click reset to an optional default value, and Left/Right/Up/Down/Shift-fine/Page/Home/End keyboard control (`.Slider`). `slider_with_value` pairs the track with an interactive numeric readout supporting mouse-wheel stepping, horizontal drag scrubbing, and click-to-type exact integer entry (pre-selected on open, `Enter` or blur commits and clamps, `Escape` cancels).
- **Rich single-line text editing (`text_input`)**: Transient caret and selection state lives in `Interface_State` for the currently focused field (zero extra caller state), giving every `text_input` caret movement (`Left`/`Right`/`Home`/`End`), word jumps (`Ctrl+Left`/`Right`), selection (`Shift+arrows`, `Ctrl+A`, pointer drag, double-click word, triple-click all), `Delete`, `Ctrl+Backspace`/`Ctrl+Delete` word erase, `Ctrl+U`, and selection-aware copy/paste.
- **Badge (`badge`)**: Compact rectangular tag with a 3 px left accent bar and high-contrast caption text in both dark and light appearances.
- **Drag-and-drop reorderable list (`reorder_list`, `Reorder_Drag_State`)**: In-place permutation over caller-owned `order: []int` with grip handles, 4 px drag threshold, live 2 px horizontal insertion indicator, floating dragged-row preview with sharp shadow, and `Alt+Up`/`Alt+Down` keyboard reordering.

## Refused forms

- **Heap-allocated retained widget trees inside `modus:interface`.** Freestanding system modules forbid allocators (`modustool check static`); caller-owned fixed structs (`Reorder_Drag_State`) keep all state explicit and bounded.
- **Rounded-pill switches and blurred shadows.** Rectangular forms and sharp shadows keep visual unity with `docs/DESIGN.md`.

## State

Built: `button_styled`, `toggle_switch`, `segmented_control`, `tab_bar`, `slider`, `badge`, `reorder_list`, and host unit tests in `src/library/modus/interface/rich_widgets_test.odin`.
