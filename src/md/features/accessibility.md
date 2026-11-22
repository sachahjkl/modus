# Accessibility: a desktop that each principal can use

## Purpose

A principal who does not see the screen, who sees it badly, who cannot tell red from green, who cannot hold a pointer, or whom motion makes ill, must be able to use the whole desktop. Today such a principal cannot: no process says what a window shows except in pixels, and no setting changes the contrast or the motion.

This design gives the system accessibility at the scale of the world, now, because each part costs least before the windows, the contracts and the tests depend on its absence. It covers the semantic tree, the assistive role, the keyboard, the settings of the principal, speech and the tests.

The guide of the subject does not exist yet. The parts that this design changes are [../api/draw_table.md](../api/draw_table.md), [palette.md](palette.md), [appearance.md](appearance.md), [timed_stream.md](timed_stream.md) and [../infrastructure/test_pointer.md](../infrastructure/test_pointer.md). Two designs of other branches meet this one: the roles as contracts (property 23, "A role is a contract; its implementation is replaceable", and its intent file `roles_and_contracts.md`) and the interface in the language of the principal (its intent file `interface_language.md`: BCP 47 and Unicode MessageFormat 2).

## Constraints

- **One description draws and is read.** The owner decided that the semantic tree comes from the draw table: the element that writes the records of a button also says that it is a button. Two descriptions drift, and a drift is a lie to a principal who cannot check the pixels.
- **Immediate mode** ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "2. The model: an immediate pass over flat tables"). No tree of objects lives between frames. Only the element identity and the interface state do.
- **No ambient access** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). The text of every window is what a capture of the screen gives (row 6). A process that reads it, or that moves the focus of every window (row 7), holds a broad grant: rare, visible and revocable.
- **The compositor never waits for a process**, and does no work in proportion to a table that another process wrote ([palette.md](palette.md), "The constraints").
- **A role is a contract with a conformance suite** (property 23, designed in another branch). A screen reader, a magnifier and a switch input are holders of one role; none is a part of the compositor.
- **Take the standards; invent no set.** The roles, the states and the properties come from WAI-ARIA 1.2 (W3C Recommendation, 6 June 2023) and their mappings from the Core Accessibility API Mappings 1.2 (Candidate Recommendation Draft, 5 November 2026). The name comes from the Accessible Name and Description Computation 1.2 (Working Draft, 4 November 2026).
- **No float in a contract** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes"). A value of WAI-ARIA is a number with a fraction; the record holds an integer with a unit and a value text.
- **A test waits for a condition, never for a time** ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests").
- **The machine must be usable before any unlock.** A principal who does not see the screen types the passphrase of the machine too.

## The chosen form

### 1. The semantic tree

**The element push and the element pop.** Two kinds join the closed set of the draw record ([../api/draw_table.md](../api/draw_table.md)): `Element_Push` (value 16) and `Element_Pop` (value 17). New values, so that no word of a kind that left names them. Each draws nothing. The records between a push and its pop are the records of that element. The order of the pushes and the pops is the tree: a push inside an open push is its child, in the order of the table. So the order of drawing, the order of reading and the order of Tab are one order: the order of the calls of the frame.

The interface package writes the push and the pop in the same call that writes the records of the element: `button`, `text_input`, `list_with_choice`, `scroll_bar`, `action_bar`, `card`. A process that calls an element writes no semantic code. A process that draws with its own records writes a push with `element_push(frame, area, identity, role, ...)` and its pop.

The fields of a push, after the header of 24 bytes:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 4 (header) | `element` | u32 | The element word: the low 32 bits of the element identity; never 0 |
| 8 (header) | the box | 4 x i32 | The area of the element: where it takes the pointer, on whole pixels |
| 24 | `role` | u8 | `Element_Role` after the border |
| 25 | `live` | u8 | `Live_Politeness`: `Off` 0, `Polite` 1, `Assertive` 2 |
| 26 | `toggle` | u8 | `Toggle_State`: `None` 0, `False` 1, `True` 2, `Mixed` 3 |
| 27 | `expanded` | u8 | `Expanded_State`: `None` 0, `Collapsed` 1, `Expanded` 2 |
| 28 | `states` | u32 | A bit set of `Element_State` |
| 32 | `name_first`, `name_count` | u32, u16 | The accessible name: a range of the byte table, at most 256 bytes; a count of 0 takes the name from the content |
| 38 | `reserved` | u16 | 0 |
| 40 | `detail_first`, `detail_count` | u32, u16 | The details: a range of entries of 16 bytes in the byte table, at most `ELEMENT_DETAIL_LIMIT` (32) |
| 46 | `reserved` | u16 | 0 |

A pop has no field and a box of zeros, as a `Clip_Pop`.

**Why in the draw table, and not beside it.**

- The element word is in the header of each draw record already. Each record that the call of an element writes carries its word. So the border of the order can check what no second table can: a record under an open push carries the word of the innermost push, or 0. A button whose records move and whose push stays is a table that the border refuses. The drift is not a fault to find later: it is a form that the format cannot hold.
- The difference already compares two tables at one index. A push whose bytes are equal changes nothing; a push that changes damages nothing, since it draws nothing, and still marks a changed tree.
- The texts are in the byte table already. The name of a button is the text of its label: the push names no bytes, and the reader takes the text runs under it.

**The element role.** `Element_Role` is a closed enum whose members are the roles of WAI-ARIA 1.2, section 5.4, "Definition of Roles", with no abstract role (section 5.3.1): the names of the standard in the form of the code (`button`, `checkbox`, `combobox`, `listbox`, `option`, `scrollbar`, `textbox`, `meter`, `log`, `status`, `alert`, `timer`, `heading`, `link`, `table`, `row`, `cell`, `columnheader`, `toolbar`, `menu`, `menuitem`, `radiogroup`, `radio`, `dialog`, `alertdialog`, `img`, `group`, `region`, and each other). The value 0 is `none`: the role `none` of the standard, whose records are presentation. The values are those of the contract, in the order of the standard; a role of WAI-ARIA 1.3 comes as a new member when 1.3 is a Recommendation, under the version rule of the record.

The roles of the elements of the interface package:

| Element | Role, and what the push says |
|---|---|
| `button` | `button`; `toggle` for a button that stays pressed |
| A setting row, the buttons of a field of the palette | `radiogroup` with a `radio` for each member, `toggle` `True` on the member in use |
| `text_input`, `text_input_line` | `textbox`; the state `protected` for a passphrase |
| `list_with_choice` | `listbox` with an `option` for each row, the state `selected` on the choice |
| `list_of_rows` | `list` with a `listitem` for each row; `listbox` when the caller owns a choice |
| `scroll_bar` | `scrollbar`: the first unit as its value, `controls` names its view |
| `action_bar` | `toolbar` with a `button` for each item and its keys in `Key_Shortcuts`; the button `more` with `Has_Popup` `menu` and its `menu` |
| `card` | `group` named by its title; the caption is its description |
| `draw_heading` | `heading`, level 1; the title of a card is a `heading` of level 2 |
| `bar_with_value`, a gauge | `meter`, with its value, its range and its value text |
| `case_lines` | `table`, `row` and `cell` |
| The panel of the palette | `dialog` with the state `modal`; its input is a `combobox` whose `listbox` it controls, `Active_Descendant` on the chosen entry |
| The bar of the desktop | `toolbar`; the clock is a `timer`; the mark of a viewer is a `status` |
| The window of `log`, the lines of a terminal | `log` |

**The element states.** `Element_State` is a closed bit set of the boolean states and properties of WAI-ARIA 1.2: `busy`, `disabled`, `hidden`, `invalid`, `modal`, `multiline`, `multiselectable`, `readonly`, `required`, `selected`, `atomic`. Three come from the mappings, not from WAI-ARIA, because a platform state of the Core Accessibility API Mappings carries them: `focusable`, `focused` and `protected` (the state of a passphrase field: `IsPassword` of UI Automation, the subrole `AXSecureTextField` of macOS). The tristates `aria-checked` and `aria-pressed` are one field, `toggle`, because the role says which one it is. `aria-expanded` is the field `expanded`.

**The name, the description, the value and its range.**

- **The name** follows the Accessible Name and Description Computation 1.2: the range `name` of the push when it is not empty; else, for a role that takes its name from its content (`button`, `link`, `cell`, `row`, `heading`, `option`, `radio`, `tab`, `menuitem` and the others of WAI-ARIA 1.2, section 5.2.8.4), the text runs under the push, in order, joined by a space. A `textbox` takes its name from its label, a relation `Labelled_By`, and never from its placeholder, which is a detail.
- **The details** are entries of 16 bytes in the byte table (`Element_Detail_Record`): the word of an `Element_Detail`, 4 bytes of zeros, and a value of 64 bits. A text is a range of the byte table in the value: its first byte in the low 32 bits, its count in the high 32 bits.
- **A value**: `Value_Now`, `Value_Minimum` and `Value_Maximum` are integers in the integer unit of the element, the unit of the palette (`docs/glossary/running_code.md`); `Value_Text` is the text that the screen shows, as "4 pages" or "1.375". A number with a fraction is an integer of its smallest unit and a value text: the scale factor is a count of eighths and "1.375". A textbox has its text as its `Value_Text`, and `Caret`, `Selection_Start` and `Selection_End` as offsets in characters, the text interface of the mappings (`Text` of AT-SPI, `TextPattern` of UI Automation).
- **The other details** are the properties of WAI-ARIA 1.2 that are not boolean: `Description`, `Placeholder`, `Key_Shortcuts` (texts); `Level`, `Position_In_Set`, `Set_Size`, `Row_Index`, `Row_Count`, `Column_Index`, `Column_Count`, `Row_Span`, `Column_Span` (integers); `Orientation`, `Sort`, `Current`, `Has_Popup`, `Auto_Complete`, `Relevant` (enums and a bit set of the standard); `Language`, a range that holds a locale record of the interface in the language of the principal; and `Actions`, the declared actions.

**The relations.** A relation is a detail whose value is an element word of the same table: `Labelled_By`, `Described_By`, `Controls`, `Details`, `Error_Message`, `Flow_To`, `Active_Descendant`. A relation can repeat, for a list of words. A word that names no push of the frame is ignored and counted, as WAI-ARIA 1.2 ignores an identifier that matches no element. A relation never names an element of another window: the word is local to its table.

**The focus.** The interface state holds the element with the focus, by its identity; its push carries the state `focused`. The window with the focus is a fact of the compositor, never of the tree: a process cannot say that it has the focus of the desktop, as a process of AT-SPI can. The focus of the principal is therefore the window that the compositor names, then the push with `focused` in its last tree.

**The live regions.** `live` is `aria-live`; the roles `alert`, `log`, `status` and `timer` have the politeness that WAI-ARIA 1.2 gives them when `live` is `Off`. The details `Relevant` and the state `atomic` are `aria-relevant` and `aria-atomic`. An announcement is a change of the text under a live region from one tree to the next: the reader finds it by identity and says it, at the politeness of the region. A process that wants to say a fact puts its text in a live region; no call announces a text alone (`ariaNotify` is a draft of WAI-ARIA 1.3).

**From frame to frame: stable identities, and changes as events.**

- **The identity of a node is its element word.** The element identity already lives from frame to frame: the focus follows it. A push with the word 0 is refused. Two pushes of one word in one frame: the second is a group with no identity, which takes no focus and no action, and is counted; `Frame.identity_collisions` already counts the elements that repeat an identity.
- **A tree is a snapshot of a frame.** The window publishes the whole tree of a frame, never a list of changes: immediate mode knows what the frame is, not what changed in it. The reader compares two trees by identity and makes the events: a node added, gone or moved; a name, a value, a state or a toggle changed; the focus moved; the text of a live region changed. A row that a list scrolls into view is a new node; its `Position_In_Set` says where it is.
- **A tree is published with its frame.** The reader never reads a tree that the screen does not show, and never a frame whose tree it lacks: the tree of a frame is published with the `Present` of that frame, as GNOME's Newton puts the tree update in the committed state of a surface.

**How the tree leaves the window.** The window lends its tables, read-only; nothing is copied.

- The window layer puts the two draw tables and the two byte tables of a window in one memory object, the frame tables, which its budget pays as it pays them today in its working memory. At `display.open`, it gives the compositor a handle with Read, as it gives the surface.
- Each table starts with a word, the table serial: odd while the window writes it, even after. `Present` names the serial of the table of its frame when its pushes or its texts changed, and 0 when they did not. The difference of the drawing module already says it.
- The compositor never reads the frame tables. It lends a handle with Read to each holder of the assistive role, and sends it the serial with each `Present` that names one. When no holder runs, the compositor sends the window `Semantics_Wanted` with 0: the window writes its pushes, which cost two records for each element, and never publishes a serial.
- The holder copies the table of the last serial, then checks the serial again: a window that wrote the table during the copy gives another serial, and the holder takes the next one. Then it reads the copy through the borders of the record, of the order and of the details. A count, an offset and a length of the window are copied, then checked.

### 2. The assistive role

**The role.** `assistive` is a role of property 23: a typed contract that the root service gives to a holder after its check against the descriptions, with a conformance suite. A screen reader, a magnifier and a switch input each fill it. The holder reads the trees through the assistive face of the display role (the compositor), never through a connection to a window.

**Several holders at once.** A principal with low vision uses a magnifier and a screen reader together. So `assistive` is the one role that takes several holders in one scope, each with its own ring of the assistive face and its own wiring of the record outputs ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable"). The compositor serves each holder apart: no holder sees the ring, the actions or the keys of another. The assistive key and the switch keys go to the holder that the setting `assistive_key_holder` names; with one holder, to that holder. The bar shows one mark for each holder.

**Who chooses a holder.** `assistive` is in the trusted path: it reads each window and acts on it. So only principal 0 chooses a holder from the disk, in its plan, and the root service measures the hash of each such holder into PCR 12 before it runs, as for the display, the input and the console ([roles_and_contracts.md](roles_and_contracts.md), "The plan says who holds each role"). A named principal chooses among the holders that the image or principal 0 gives; it does not bring its own from the disk. The rescue start policy takes the holders of the signed image only.

**The assistive face of the display role.** The compositor gives a holder:

- the list of the windows (the title, the nickname of the process, the place, the order, the focus) as records, with an event for each change: a window added, gone, brought to the front, given the focus;
- the handle of the frame tables of each window, with Read, and the serial of each `Present` that names one, as the record output of its contract (property 23: an event of a role is a record output, with a ring for each subscriber, with no loss);
- the frame tables of the compositor itself: the bar, the menus, the title bars and the palette;
- `focus_element(window, element)`: the compositor raises the window and sends it the event that the go to of the palette sends, with an element word in place of an act name ([palette.md](palette.md), "The form of an entry, from its descriptions", rule 3);
- `act(window, element, action, value)`: the compositor sends the event `Element_Action` to the window;
- `magnify(rectangle, factor)` and `magnify_end()`: the compositor draws a part of its screen larger, over the whole screen, as the last step of its frame;
- the assistive keys and the switch keys that the principal pressed (below).

**What a holder gets, and what it never gets.**

- It reads each tree and moves the focus. It acts on an element only by an action that the element declared in its last frame. It never sends a key, a move of the pointer or a press (row 7: synthetic input is a grant that this role does not hold). It never receives a pixel: the magnifier tells the compositor what to enlarge.
- **The declared actions** are a closed set, `Element_Action`, the actions that the platform interfaces share: the patterns of UI Automation (`Invoke`, `Value`, `RangeValue`, `Toggle`, `ExpandCollapse`, `SelectionItem`, `ScrollItem`) and the actions of `NSAccessibility` (press, increment, decrement, show menu, cancel): `Press`, `Focus`, `Increment`, `Decrement`, `Set_Value`, `Insert_Text`, `Expand`, `Collapse`, `Select`, `Scroll_Into_View`, `Show_Menu`, `Dismiss`. The detail `Actions` of a push holds its set; the interface package writes it from the element.
- **An action runs the code of a key.** The window layer refuses an action that the element did not declare in its last frame, with a count. Else it gives the element the focus and puts the key of the action in the input of the next frame: `Press` is Enter, `Increment` is Up, `Select` is Space, `Dismiss` is Escape. The action bar already runs a press through the key of its item ([action_bar.md](action_bar.md)). So an action and a key cannot do two things.
- **Text.** `Insert_Text` puts a text at the caret through the path of a paste: a memory object of the holder with Read, lent to the window and revoked after it took the text ([clipboard.md](clipboard.md)). An on-screen keyboard and a dictation are holders that use it. A field with the state `protected` declares no `Insert_Text`: the passphrase of `unlock` is typed on the keyboard only.
- **A protected value is absent.** A field with `protected` publishes no value, no caret and no length; the reader says "protected field". A line of the log already holds no fact of a passphrase, its length either ([../infrastructure/test_pointer.md](../infrastructure/test_pointer.md), "Subtle points").

**The assistive key and the switch keys.** A screen reader has commands of its own, which must not reach the window. The setting `assistive_key` names one key, Insert or Caps Lock. The compositor keeps it as it keeps the key super: each key that the principal presses while it holds the assistive key goes to the holder, never to a window. The setting `switch_keys` names the keys of a switch device, which go to the holder only. The holder receives no other key: it learns a typed character from the change of the value of the field in the tree, so a protected field echoes nothing.

**The visible mark.** While a holder reads the trees, the bar shows a mark at the left of the key of the palette, the mark of a viewer of [remote_display.md](remote_display.md): its form, its color `warning`, the word `assistive` and the nickname of the holder. Reading every window is a capture of the screen in text (row 6). The mark is a `status` of the tree of the compositor: a reader says it when it appears.

**Before any unlock.** The start list of principal 0 starts the holder when the setting `screen_reader` is on, before `unlock`, with the speech service. One key combination always goes to the system (row 8): Super+Alt+S starts or stops the screen reader of the image, as in GNOME. The compositor keeps it as it keeps the key super, so no window receives it. So a principal who does not see the screen turns on speech on a machine where it is off.

**The conformance suite.** A holder is a client of the assistive face, so the suite drives it with a fake face: scripted windows, trees and events.

- Each holder: it takes each hostile table of the fuzz corpus of the borders and refuses it with no fault; it reads its ring, so the face never holds a full ring past the hang bound; it sends no action that the element did not declare; it reads no value of a protected field.
- A reader also fills a record output of utterances, which the suite reads in place of sound: after a focus event, an utterance with the name, the role and the states of the new focus; after a change of a polite live region, its new text, after the utterance in progress; after an assertive one, at once; nothing for a protected field.
- A magnifier: after a move of the focus or of the caret, its rectangle holds the box of the focus.

### 3. Keyboard access to everything

**The rule.** Each act that a principal does with the pointer, a key does too. The palette is already the way of the keyboard to each operation of the console, each process and each window ([palette.md](palette.md)), and the interface package already gives Tab, Shift+Tab, Enter, Space, Up and Down to each element that takes input ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "4. Input and focus").

**The gaps of today**, each a later step:

- **A window moves and resizes by the pointer only** ([window_resize.md](window_resize.md)). The palette gets two entries for the window in front, "move window" and "resize window": the arrow keys then move the edge by a spacing token, Shift by one logical pixel, Enter ends and asks the one `Resized`, Escape gives the size back.
- **The menus of the bar** take the pointer only. The palette reaches each of their lines; the bar also takes the focus with a key of the compositor, then Left and Right.
- **The window `pointers`** and the windows that draw with `graphics` have no element and no tree. They wait for the work "Every window uses the interface package" of `ROADMAP.md`.
- **The order of Tab holds 64 elements.** An element after them takes a press and no Tab (`Frame.focus_overflow`). A window that passes 64 is a fault that a test finds (section 6), not a bound to raise in silence.

**The focus order** is the order of the frame. A process that wants another order changes the order of its calls, so the order of reading follows too. `tabindex` with a number is refused (below).

**The focus ring.** The element with the focus has an outline of 2 logical pixels in `colors.text_strong`, outside its area, with a contrast of at least 3 to 1 against the colors on both sides in each appearance and each contrast (WCAG 2.2, success criterion 2.4.13, "Focus Appearance"). Host tests compute each pair, as they do for the texts. Nothing covers the outline: the box of the element grows by its width, so the damage holds it.

### 4. The settings of the principal

Each is a value of the settings page, written by the process `settings` and read by each window at each frame, as each setting of today ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting"). A change draws each window once. A browser and a rich module read the same values: the light browser gives them to a page as `prefers-contrast`, `prefers-reduced-motion` and `prefers-color-scheme`.

**Contrast.** The setting `contrast`: `.normal`, `.high`. It is a second axis beside `appearance`: the table of color tokens gets four values for each token, dark and light, normal and high ([appearance.md](appearance.md)). The high contrast keeps each rule of the normal one and raises its bounds: a text 7 to 1 (WCAG 2.2, success criterion 1.4.6), a graphic and a large text 4.5 to 1, the edge of a card 2 pixels. The decoration goes ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "8. Decoration"): the grid of points, the gradients of the surfaces and of the scroll bar become flat colors. The host tests that compute each pair compute them in the four sets.

**Text size.** Two levers.

- **The scale factor** enlarges everything, so no layout breaks: 1.25 and 1.375 today, up to 2 when each window fits ("The scales from 1.5 to 2" of `ROADMAP.md`).
- **The text sizes alone**, a step that raises each text size token (the body from 16 to 20, 24, 32), waits for the layout from the size of the content ("Layout from the size of the content" of `ROADMAP.md`): a window of fixed sizes cuts a larger text, and the text box rule then wraps it past its window ([text_box.md](text_box.md)).
- Text twice as large as the default (WCAG 2.2, success criterion 1.4.4) needs the scale 2.5 on the reference screen, whose logical screen of 768 × 432 is smaller than the window bound. Until the layout from the content exists, the magnifier is the answer past the scale 2: a gap that this design states.

**Reduced motion.** The setting `motion`: `.full`, `.reduced`. The desktop has few animations, by its rules ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"): with `.reduced`, the process `heron` shows the still heron and plays an animation only when a key asks for it, as the home of the site does for a visitor who asks for reduced motion; an animated pointer shape shows its first frame. Each later animation of the system reads the setting, and a host test of each one checks the still form.

**Color-vision differences.** The rule of the design is that a color never stands alone for a fact ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color").

| Where | Holds or fails |
|---|---|
| The colors of the value kinds | Holds: the unit and the text of the value say the same fact |
| The series colors | Holds: a number or a word names each member |
| The intensity of a gauge | Holds: the number is beside the gauge |
| The kind icons and the marks of the palette | Holds: a word says the kind; the form of the icon differs too |
| The states of the boot display (starts, runs, failed) | Holds: the list of the steps says "done", "now" or "failed" |
| `process` (green) against `failed` (coral) | Holds where a word says the state; a host test must find each place where the two meet with no word |
| The title bar of the window in front | To check: it differs from the others by its blue only; the difference of lightness must be computed, since a hue alone fails for a principal who does not see blue |
| A link in a text that a click does not open | Fails: only its color marks it; it gets the line under it that a link that opens has |
| The colors of code | Holds: a color of a class adds no fact that the text does not have |

A host test simulates the three dichromacies (the method of Viénot, Brettel and Mollon, 1999) on each pair of tokens that a rule says must be told apart, and requires a difference of lightness where no word says the fact.

**Forced colors.** A principal can choose the colors of the desktop, as the forced colors of Windows. This is one more axis of the color tokens, beside `appearance` and `contrast`: the setting `forced_colors` holds a value for each token, which the principal chooses, and each drawer reads the token through the axes in force as it does today ([appearance.md](appearance.md)). The tokens stay the one source of each color, so no window remaps pixels. The contrast rules of the host tests do not apply to a set that the principal chose; the settings window shows the contrast of each pair beside the choice. A picture keeps its colors, as in each appearance.

### 5. Speech

A screen reader needs a speech synthesiser. Speech is a role of its own, `speech`, apart from `assistive`: a principal chooses a voice more often than a screen reader, and a reader, a notification and a later reader of documents all speak.

- **The contract.** The record input of `speech` takes utterances: a text, a locale record of the interface in the language of the principal, a priority (`Queue` or `Interrupt`) and a serial. Its record output says when an utterance starts and ends, so a reader moves the caret during "read all". The holder writes the frames into a timed stream of the sound service ([timed_stream.md](timed_stream.md)): it resamples to the one format of the stream. An `Interrupt` stops the next records; the records that the device already holds play, so a cut is heard within the latency of the stream, 30 to 40 ms.
- **The queue.** The utterances that wait have a stated capacity. A polite utterance that finds the queue full replaces the oldest polite one, and the count of the replaced ones is said after ("3 more changes"). No queue drops a record in silence.
- **The sound of the other processes.** The sound service plays one process at a time today. The voice must never be refused, and the sound of another process must not be refused for it. So speech, and the screen reader with it, waits for the mixing of several processes ("Sound of several processes at once" of `ROADMAP.md`).

**The options for the first holder:**

| Option | Licence | Languages | What it costs |
|---|---|---|---|
| A port of eSpeak NG 1.52.0, the formant synthesiser, as an outside module ([../infrastructure/outside_source.md](../infrastructure/outside_source.md)) | GPL-3.0-or-later | More than 100 | Its C compiled into a module, the files of its data as one resource by hash in place of paths, its thin libc. It speaks at once on the processor, before any network |
| A port of CMU Flite 2.1 | X11-like, permissive | English, and a few voices of India | The same port; most principals of the world get no voice |
| A neural voice from the object cache (the voices of Piper) | piper1-gpl is GPL-3.0-or-later and uses eSpeak NG for its phonemes; each voice has its own licence | Each voice one language | A runtime of the model on the processor, a voice fetched by hash, which a machine before the network and before any unlock does not have |
| A synthesiser written for the system | Of the system | One at a time | Years of work for each language |

**The decision:** eSpeak NG is the first holder of `speech`, because only it gives a voice in the languages of the world, small, on the processor and before the network. A neural voice is a later holder of the same role, which a principal chooses. The boot image ships eSpeak NG with its source, as GPL-3.0-or-later requires, and the reuse list names it with its licence ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Reuse list"). CMU Flite is refused as the first voice: with it, most principals of the world get no voice in their language.

### 6. The tests

A test reads the semantic tree. Today a step waits for an element line, a log fact or a settled picture. A fact of the tree is more exact than each: "the button `font` of `settings` has `toggle` `True`" in place of the pixels of a button, or of a line that a process writes for the test.

- **The probe.** A module of the group `tests`, `semantic_probe`, is a holder of `assistive` in the start lists of the test machines. It reads each tree through the face, as a screen reader does, and writes a log fact for each node that it adds or changes: `assistive.Node_Changed` with the window, the accessible name, the role, the toggle, the expanded state, the states, the value text and the box. A protected value is absent there too. So each machine test runs the contract, and the release image, which has no test module, writes no such fact.
- **The step `Element`** waits for a node of a window by its name, with a condition in the form of `where` on one of its fields: `{kind = .Element, window = "settings", element = "spleen", condition = "toggle = True"}`. The tool reads it as a step `Fact` reads its fact (`console_condition`), and checks it against the fields before the machine starts.
- **The step `Act`** asks the probe for a declared action through `remote`, so a scenario tests the path of an assistive holder, beside the presses of the virtual mouse that test the path of the pointer.
- **The checks of each tree.** The probe writes a fact for each node that breaks a rule, and the tool fails the test part on one: a focusable node with no name; a node that takes a press and declares no key; a window whose order of Tab passes 64; a relation that names no node; a protected field with a value. Each window of each machine test is then checked, with no line of a scenario for it.
- **The element name becomes the accessible name.** Two names for one element is a second mechanism beside a general one ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task"). When the probe and the step `Element` exist, the step `Click_Element` reads the box of the node from the probe, the element lines of the window layer leave, and a row named by its place ("frame 0") is the row of that place in the list that names it. This changes [../infrastructure/test_pointer.md](../infrastructure/test_pointer.md) in that step.

### 7. The prior art

| Work | Its form | What modus takes | What modus refuses |
|---|---|---|---|
| WAI-ARIA 1.2 (Recommendation, 2023), Core Accessibility API Mappings 1.2 (Candidate Recommendation Draft, November 2026), Accessible Name and Description Computation 1.2 (Working Draft, November 2026) | Roles, states and properties on the elements of a page, mapped to each platform interface | The roles, the states, the properties, the politeness of a live region, the name from the content, the ignored reference | `aria-owns`, which moves a node to another parent: the order of the table is the tree. `aria-roledescription`: a process would name a role that no reader knows, in one language. Abstract roles. WAI-ARIA 1.3 (Working Draft, June 2026: `ariaNotify`, braille labels, new roles) until it is a Recommendation |
| macOS `NSAccessibility` | An object for each element; the client asks each attribute through a call; a handful of actions | The small set of actions: a client drives the interface and does not run the functions of the program | The question of each attribute through a call to the program: each read is a round trip to a hostile process. The one grant "Accessibility" that also sends any event to any program |
| Windows UI Automation | A provider for each element; control types and control patterns, a client asks across processes | The control patterns as the form of the declared actions; a control type as a role with the patterns that it must support | The calls across processes for each property; custom patterns and custom properties, an open set; WinEvent hooks, through which any process follows each tree |
| AT-SPI2 on Linux (`at-spi2-core` 2.58) | A bus of D-Bus that each program joins; a client asks each object | The vocabulary of its states and relations, which the mappings name | The bus: any process on it reads each program and can say that it has the focus, so a sandbox needs a hole for it |
| GNOME Newton (a prototype) and AccessKit 0.25 | A program pushes its tree to the compositor with its frame; the compositor passes it on and is the one source of the focus | The push of whole trees, a tree for each surface, the tree in the committed state of a frame, the compositor as the source of the focus, a program that knows when a client listens, the stable identity of a node in its tree, the password with no content | A serial format in JSON through a pipe: the frame tables are fixed records lent in shared memory. Lists of changed nodes: immediate mode knows the frame, not the change |
| Fuchsia `fuchsia.accessibility.semantics` | A view registers its tree by the reference of its view; updates and a commit; the manager closes the channel on a tree that is not well formed | A tree for each view, given through the reference that the compositor knows; the refusal of a tree that is not well formed; bounds on the nodes and the depth; updates only while a client listens | Its own set of 24 roles, a set that no standard gives. Updates sent in pieces that a commit joins |
| Flutter semantics (`SemanticsRole` since 3.32) | A semantics tree built from the tree that paints, its roles mapped to WAI-ARIA | The tree from the description that paints; roles taken from WAI-ARIA | A second tree compiled in its own pass, with its own owner and its own cost, which a program turns on |

## The refused forms

- **A tree that the process builds beside its drawing**, as the objects of `NSAccessibility`, the providers of UI Automation and the objects of AT-SPI. It is the retained tree that immediate mode refuses: a second copy of the state, which drifts.
- **A second table of elements beside the draw table.** Two tables written by one call can still disagree, and nothing checks that a record of the drawing belongs to a node. The element word in the header of each record gives that check only inside the draw table.
- **The role in the reserved bytes of each draw record.** A button is several records; each would carry its role, and the difference would compare it again in each. The name, the states and the details have no room there.
- **A tree inferred from the records**: a text run read as a label, a rectangle as a button. It is a guess, and a guess said to a principal who cannot check it is a lie.
- **The compositor reads the trees and keeps a desktop tree.** The process that reads each hostile surface would parse a hostile table in its loop, in proportion to its size.
- **The windows send their trees to the holder through a connection.** Each window would then know which reader runs, and the compositor would no longer be the one source of the focus and of the order of the windows.
- **A list of changes from the window.** The window would need the state of the frame before it, by identity: a second store of what the difference already compares.
- **The holder sends keys and presses.** Synthetic input is a grant that row 7 keeps narrow; an action that runs the code of a key does the same with no new power.
- **A magnifier that reads the pixels of the screen.** It would need the capture face for a work that the compositor does with no pixel leaving it.
- **Each key to the holder, for the echo of the typed characters.** The holder would read each passphrase. The tree gives the echo, and gives none for a protected field.
- **`tabindex` with a number, a focus order apart from the order of the frame.** Two orders drift, and the reader then reads in an order that Tab does not follow.
- **`aria-owns` and `aria-roledescription`.** Above, under WAI-ARIA.
- **An announcement call beside the live regions.** A text that no node shows is a second channel to the principal that no test reads in the tree; it waits for `ariaNotify` in a Recommendation.
- **A high contrast as a third appearance.** Contrast and appearance are two choices: a principal wants a light high contrast or a dark one.
- **Text sizes alone before the layout from the content.** Each window of fixed sizes would cut or wrap its texts past its edges.
- **One holder that is the screen reader and the voice.** A principal could not change the voice without changing the reader, and a notification could not speak with no reader.
- **One holder of `assistive` at a time.** A principal who needs a magnifier and a screen reader together then gets only one of them.
- **A holder of `assistive` from the disk chosen by a named principal.** The holder reads each window and acts on it, before and after each unlock. A choice that principal 0 does not make and the TPM does not measure opens the trusted path to any module.
- **The sound of the other processes refused while a screen reader runs.** A principal who needs speech then loses each other sound of the machine. Speech waits for the mixing.
- **CMU Flite as the first voice.** It speaks English and a few voices of India only.
- **A remap of the pixels for forced colors.** It changes the colors of pictures too, and breaks the contrast that each token keeps. Forced colors are an axis of the tokens.

## The subtle points

- **The tree holds what the frame draws.** A list draws only its rows on the screen, so the tree has only those rows, with `Position_In_Set` and `Set_Size`. A reader moves past the last row by the key Down of the list, which moves the choice and the view; "read all" of a long text scrolls through the action `Scroll_Into_View` of the next row. The cost is a step for each screen of rows, in place of a tree of each row of a large document.
- **A record under a push carries the word of the innermost push, or 0.** The border of the order refuses another word. A label that a call draws with no identity has 0 and stays inside the element. A decoration that belongs to no element is outside each push.
- **The element pushes and the clip pushes nest in one order.** A list writes its element push, then the push of its clip, its rows, the pop of its clip, then its element pop. The border of the order refuses a pop of one kind while a push of the other kind that came after it is open. The depth bound of the elements is `ELEMENT_DEPTH_LIMIT` (32): a bound of cost, as the bound of the clips.
- **A text outside each push is a text of the window.** The reader reads it in the order of the table, as the role `generic` of the standard. A picture outside each push is presentation: a picture that carries a fact has a push with the role `img` and a name.
- **A clipped node.** A node whose box a clip cuts to nothing is off the screen: the reader computes it from the clip stack, never from a state of the window.
- **The name of a window comes from the compositor.** A window can draw a false palette in its own surface; the reader says the title that the compositor gives, so the principal hears in which window it is.
- **A tree is as secret as the screen.** It holds each text that the window draws. It goes only to a holder, with the visible mark, and never to the log: the probe of the tests writes its facts in test machines only.
- **The value of a field is the text that the field holds.** The editor `edit` draws only its rows on the screen; its value is those rows, with `Row_Index` and `Row_Count` for its lines. Its whole text is not published in each frame.
- **The relations and the names are words and ranges of one frame.** They name nothing across frames; the reader resolves them in the copy of one serial.
- **The pushes cost two records for each element.** The measure is the window `interface_elements` (68 records today) and the size of each window memory, from the build; the publication costs nothing while no holder runs.
- **The integer of a value is not always the number that the principal reads.** The value text is what the reader says; the integer serves a reader that compares or a switch that moves by a step.
- **The terms.** An element role is not a role of property 23. The glossary defines "element role" for the one and keeps "role" for the other, as it keeps "start grant set" apart.

## The frequent tasks

| Task | Expression |
|---|---|
| Turn the screen reader on before any unlock | Super + Alt + S |
| Raise the contrast | `settings.set(contrast = .high)` |
| Reduce the motion | `settings.set(motion = .reduced)` |
| See which process reads the trees | the mark in the bar, and `grants("screen_reader")` |
| Stop it | `revoke("screen_reader", "assistive")` |
| Wait for a state in a test | a step `Element` with `condition = "toggle = True"` |

## The layers

Each layer works alone, on a system that works.

1. **The semantic tree in the draw table.** The two kinds and their borders, the pushes of the elements of the interface package, the probe, the steps `Element` and `Act` and the checks of each tree in the machine tests. It gives the tests their value at once, with no reader.
2. **The assistive face and the role `assistive`.** The frame tables lent read-only, the serial with `Present`, `Semantics_Wanted`, `focus_element`, `act`, the assistive key and the switch keys, the visible mark and the conformance suite.
3. **Keyboard access to everything.** The move and the resize of a window by keys, the bar with the keys, the focus ring with its contrast.
4. **The contrast and the motion.** The two settings, the four sets of the tokens with their host tests, the still forms, and the test of the dichromacies.
5. **Speech.** The role `speech`, the port of eSpeak NG, after the mixing of the sound service.
6. **A screen reader of the system.** The first holder of `assistive` that reads, started before `unlock` with its key combination.
7. **The magnifier.** `magnify` in the compositor, and a holder that follows the focus and the caret.
8. **The tree to a remote viewer.** The remote display sends the trees to the native viewer, which gives them to the screen reader of its own machine through its platform interface.
9. **Braille.** A device class for a braille display, and the tables of a braille translator.
10. **The text sizes alone.** After the layout from the size of the content.

## State

Layer 1 (semantic tree in the draw table) is partially built:

- `draw_record` version 20 adds `Element_Push` (16) and `Element_Pop` (17), the 81 concrete WAI-ARIA 1.2 element roles, element states, live modes, toggle and expanded states, `Element_Push_Fields`, 16-byte `Element_Detail_Record`, and the unified clip-and-element border `table_order_check`. The drawing module exports `damage_of_draw_table_20` and `execute_draw_table_in_rectangles_20`, validates the unified order before drawing, skips semantic records during rasterization, and damages zero pixels when only semantic records change.
- Contract package `src/library/modus/contract/accessibility` implements strict border converters for all WAI-ARIA 1.2 roles, states, live modes, declared actions and 16-byte details, flat `Semantic_Tree` reconstruction (`semantic_tree_extract`), direct draw-table semantic auditing (`semantic_tree_audit` returning structured `Semantic_Audit_Issue` violations) and widget querying (`semantic_query_element` matching role, exact name, states, and toggle directly over a draw table in `src/library/modus/contract/accessibility/tree_check.odin`), and snapshot diffing (`semantic_tree_diff`) producing typed events (`Focus_Changed`, `Name_Changed`, `State_Changed`, `Value_Changed`, `Live_Announcement`, `Tree_Changed`), with host tests.
- `src/library/modus/graphics/forced_colors.odin` adds the closed `Color_Contrast_Mode` axis (`Standard`, `Forced_High_Contrast_Dark`, `Forced_High_Contrast_Light`), `colors_for_contrast_mode`, and pure integer WCAG relative-luminance checks (`contrast_ratio_x100`), with host tests proving WCAG AAA contrast (`>= 7.0:1`) across forced high-contrast foreground/surface pairs.
- Contract package `src/library/modus/contract/speech_output` implements the freestanding zero-allocation screen reader speech announcement queue (`Speech_Queue`, `Super+Alt+S` toggle state, `Speech_Priority` `Polite` / `Assertive` with assertive flushing of pending polite items, bounded utterance ring with replacement counting, rate `50..400` and pitch `50..200` bounds, `speech_utterance_for_element` semantic text formatting that shields `Protected` fields, and `sound_mixer` PCM submission bridge), with host tests.
- `src/library/modus/interface` provides `draw_element_push` / `draw_element_pop` with LIFO nesting guards and emits semantic records in `button`, `text_input`, `text_input_line`, `list_with_choice`, `list_of_rows`, `scroll_bar`, `action_bar`, `card`, `draw_heading`, `bar_with_value`, and `case_lines`.
- Remaining in Layer 1: the test module `semantic_probe` and the machine-test steps `Element` and `Act`. Service wiring for the assistive face, keyboard window moves, speech synthesizer holder, magnifier, remote trees, braille, and content-sized text scaling remain designed, not wired. The steps are in `ROADMAP.md`.
