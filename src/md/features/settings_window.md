# The window of settings

The window of the process `settings` is where a principal reads and changes the choices of the settings page ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting"). This file records the form of the window: what it shows, how it reflows, and what it does not offer. The page, the store and the exports are in the guide; the time zone is in [time_zone.md](time_zone.md); the languages in [interface_language.md](interface_language.md); the appearance in [appearance.md](appearance.md).

## Purpose

A principal who opens the window must see each choice, what it does, the value in force, and change it with one press or one key. The window is also the first window that a principal resizes to fit a small screen at a large scale, so it must reflow cleanly down to 400 × 320 logical pixels.

## Constraints

- **One piece of information once.** A title, a line and a control do not repeat one fact. The value in force is the selected segment or stop, not a text beside it.
- **The window is the preview.** Each window draws again in the new font, appearance and scale at the next frame.
- **The scale is the whole range.** Each member of `scale_factor.Scale`, from 1 to 2, is a value that a principal sets ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"). The window of settings fits the least work area at 2, so the principal can always set the scale back.
- **The time zone is a fixed offset.** The contract holds minutes from UTC, with no summer time ([time_zone.md](time_zone.md)).
- **The frame of the window is drawn at the scale of its surface.** The records are logical; a pointer event is logical.

## The chosen form

- **Sidebar navigation and live search.** From 580 logical pixels wide, a left sidebar (`SIDEBAR_WIDTH :: 176`) shows a live search filter (`interface.text_input`) and category rows (`All`, `Display`, `Pointer`, `Keyboard`, `Region & language`, plus `Modules` when dynamic module settings are discovered). Below 580 logical pixels, the sidebar collapses into a compact horizontal `tab_bar` above the content pane so narrow windows down to 400 px keep full width for controls. `All` is selected on open so every core section and all 7 act names (`settings.set:*`) are active immediately.
- **Rich native controls.** Enum settings (`Appearance`, `Font`, `Color stripes`, `Pointer theme`, `Grid fit`, `Layout`) use `interface.segmented_control`, keeping distinct clickable labels for each option while registering each setting's act name for palette navigation. `Scale` uses the 9-stop interactive track (`100 %` to `200 %`) with machined gradient fills and hover states.
- **Dynamic module settings cards.** Alongside the four core sections, the window reads the boot image and discovers every other module that declares a `set` export with optional parameters, rendering one card per discovered module via `modus:layout` with off-thread service calls.
- **Right-click context menu and `Ctrl+K` command palette.** Right-clicking opens a compact section menu; `Ctrl+K` or `Ctrl+Shift+P` (or clicking the `Ctrl+K` footer pill) opens `interface.Command_Palette_State` for instant fuzzy jump to any section or direct toggle of appearance, font, and scale.
- **Slim status footer.** A 24 px footer bar replaces the static keyboard action bar: a status badge on the left (`Kept in store` or `Session only`), and an interactive `Ctrl+K` pill on the right cleared by 22 px from the bottom-right resize grip.
- **The window is resizable** from 400 × 320 to 1024 × 800 logical pixels, opening at 784 × 624 logical pixels so the sidebar and content split shows immediately on the desktop.

## Refused forms

- **A sample card of the text of the system.** The live desktop and the window itself are the preview.
- **A static bottom action bar listing `Tab`, `Shift+Tab`, `Enter`.** Standard desktop focus keys need no permanent footer bar; the slim status footer gives real store status and command-palette access.
- **Named zones with rules of summer time.** The contract holds a fixed UTC offset.

## Subtle points

- **One writer, the store first when present.** When `settings` has a private store, a change is written to the store first, then to the page (`change_decision`).
- **One process settings at a time.** The root service raises the running window on a second start.
- **The act names.** Each of the seven core settings registers `settings.set:<setting>` on its active control when visible, so the Super palette jumps directly to it.
- **The element names are the labels.** Each option segment, scale stop, and language button keeps its distinct label as its element name.

## State

Built: sidebar navigation with collapsible narrow tab bar, live search filter, segmented controls, machined scale track, dynamic module cards, right-click menu, `Ctrl+K` command palette, slim status footer, resize from 400 × 320 to 1024 × 800, and host layout tests. Left: named zones with summer time.
