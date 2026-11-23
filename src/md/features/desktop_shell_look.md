# The look of the desktop shell

## Purpose

The bar and its menus are the first thing that a principal sees after the boot. This file records their look: the heron button that opens the start menu, the button of the windows, the window plates, the tray, the clock, the start menu in two panes, the menu of the windows, and the module icons that the title bars, the plates and the menus share. The places are in `src/library/internal/compositor/bar` (`bar.odin`, `icons.odin`); the compositor draws them (`src/modules/system/compositor/start_menu.odin`, `desktop_features.odin`).

## Constraints

- **A press lands on what the eye sees.** The compositor draws each part of the bar and tests a press against it, and the modus tool clicks the same places in the machine test. Each place is a procedure of the bar package: no reader adds an offset of its own ([bar_edge.md](bar_edge.md)).
- **One line of text says each fact once.** A button that its mark names needs no label, and the bar holds no permanent hint: the palette has its key in the manual and in the palette itself.
- **No pixel data that the system does not draw.** The look comes from the color tokens and from rectangles of the draw table; the heron is the one picture, made by `modus:mark` at the start.
- **No work in proportion to the modules in a frame that the bar does not show.** The icon of a window is found once, when the window takes its title.

## The chosen form

**The bar, from the left.** The heron button at `START_BUTTON_X`; the button of the windows after a gap of 4 pixels; a groove of two lines of 1 pixel (`DIVIDER_X`); the window plates from `PLATES_X`; then, from the right, the clock, a hairline, the button of the notifications and the button of the control center ([tray_widgets.md](tray_widgets.md)), the mark of a viewer and the pills of the tray. The buttons and the plates have one top and one height (`PLATE_Y`, `PLATE_HEIGHT`), so they read as one band; a pill of the tray is lower (`TRAY_Y`, `TRAY_HEIGHT`), so it reads as a state, not as a button.

**The heron button.** A plate of 44 by 28 pixels in night blue, between `title` and `title_end`, with a dark outline and a line of light under its top edge. The body of the heron is the blue of the kernel: on a plate of the title blue it would vanish, so the plate is darker than the heron in both appearances, and the heron is always drawn in its variant for a dark background. It has three looks (`Start_Button_Look`): at rest, under the pointer, and pressed in with an accent of 2 pixels at its foot while the start menu is open. A picture has no transparency, so each look has its own picture of the heron on its plate, made once at the start and at each change of the appearance; each look has its own generation, so the difference of two frames finds a change of the look and nothing else.

**The button of the windows.** The module icon of a list, flat on the bar at rest, on a quiet plate under the pointer, on the chosen blue while its menu is open. It keeps the menu of the windows, the one way to reach each window by its own line, with the hash prefix of a disk process; the window plates group the windows by name.

**The window plates.** One plate of 160 pixels for each name, in the order of the client table, with the module icon, the name cut in its font, and the count of the windows when there are several. The plate of the group of the window in front is raised, with a line of light and an accent of 2 pixels in the title blue at its foot; an open group has a quiet plate; a group of minimized windows has no plate, only a line at its foot. `bar.plate` and `bar.plate_at` give the slots; the compositor keeps the right end of the plates of the last frame (`taskbar_plates_right`), so a press and a move read the plates that the eye sees. The preview of a group is drawn after the menus, over each card that the plates do not own.

**The tray.** The tray is laid out from the clock to the left before the plates, so a plate gives way to it: the two buttons of the tray widgets at fixed places, then the mark of a viewer, which is never left out, then each pill. A pill keeps the room of one plate at least. The buttons and the clock open their cards ([tray_widgets.md](tray_widgets.md)).

**The start menu.** A user menu lists what a principal starts to work, not what a test starts. Its lines come in the sections of `bar.Menu_Section`, by the module category of each module (`docs/glossary/communication.md`, "Module category"): the applications on top, then the tools (the system tools and the developer tools), then the demonstrations. A service, a library and a test module have no line: a test module is wrong on purpose or shows nothing of its own, and a principal who starts one from a menu learns nothing. A module of a listed category has no line either when its row of the table of the modules says so, in the closed set `Menu_Presence`. `Partner_Only` is a module that another process starts as a part of its own work: a node of `rings`, a twin of `frames`, a locker of `locks`, the wired pair, and `fetch`, whose server is the listener of the tool in the test of TCP. Alone, such a module does nothing or fails. `Log_Only` is a module that opens no window and gives its result as lines of the log, such as `counters` or `debugged`: the console starts it and shows those lines, and a start from the menu would show nothing. A module that a principal hears, as `tone`, keeps its line. The presence is a field of the row, with its reason in a comment of the row, and the build writes the lists of the menu from the table: a hand list of the names to leave out would drift from the table, as the list that the menu had before. Inside a section the names are in the order of the alphabet, and each line shows the name of its module with a space for each `_` ("hall of fame"): the reader reads words, and the palette and the console still take the name.

The card has a sharp shadow of 3 pixels on its sides away from the bar, a dark border and a line of light under its top edge. The left pane has a heading for each section that has a line ("applications", "tools"), each line of 28 pixels, then, under a hairline at its foot, the quick actions (`Start_Action`): the demonstrations, the bar to the other edge, and the magnifier. The demonstrations are closed at each open of the menu: the quick action "demonstrations" opens the right pane, darker, with the heading "demonstrations" and each demonstration in three columns of lines of 24 pixels, and closes it again; the menu stays open. Each line has its module icon, then its label. A module is in one section only, so `bar.center` finds one line for each name. The width of a column comes from the widest label, measured in the font that draws it (the bar layout), and is never under `COLUMN_LEAST`, so the labels of the quick actions fit in both fonts.

The build of the tool writes the names of each section (`start_menu_names.odin` of `bar`) from the table of the modules before it compiles the compositor: each module of the boot image with an entry whose category is an application, a system tool, a developer tool or a demonstration. A new module of such a category gets its line with no list to change by hand, and a host test refuses a file that is not the text of the table. The menu reads no module file: the list is known when the compositor is built.

**The menu of the windows.** The card of the start menu, a heading with the count of the windows, then one line for each window: its module icon and its title. The window in front has a bar of 2 pixels in the title blue at the left of its line, in place of a square, so the icon keeps its place on each line.

**The module icons.** `bar.Icon` is a closed set of kinds: a framed window, a console, a chart, a dial, sliders, a page, a book, nodes, a bug, a picture, a disk, a key, a speaker, a screen that records, a lens, a screen with its bar, a list, two switches, a bell, a globe, a square half filled. Each icon is at most nine rectangles in a square of 16 pixels, in two colors: its lines, and an accent that tells it apart. Each edge falls on a pixel at the scale 1. `bar.icon_of` gives the icon of a module or a title, and the build writes `bar.name_icons` from it, the icon of each name of the start menu at the same index; and a name of no known kind, as the nickname of a disk process, gets the framed window. The compositor draws the icon at the left of each title bar, of each window plate and of each line of the two menus.

## Refused forms

- **A label "start" and a label "windows" on the bar.** The heron says what the first button is, and a list icon says the second; two words of the bar repeated the names of their menus.
- **The hint "palette: super" on the bar.** A permanent line of onboarding on the screen of each session. The palette is found in the manual and by its key.
- **A filter field in the start menu.** The palette is the way of the keyboard: it narrows a list of the modules, the windows and the commands at each key. A second filter in the start menu would be a second, weaker palette.
- **The pinned modules again in the list of all modules.** `bar.center` would find two lines for one name, and the screen would say one fact twice.
- **A list of all the modules with an entry.** It showed about fifty modules, a test module and the checks of the kernel among them, as the programs of the principal; a principal could not find the few that do a work.
- **The demonstrations open by default.** They are most of the lines; a closed section keeps the menu to what a principal uses, and one action opens them.
- **The categories read from the module files in the compositor.** The compositor would need the boot image and a read at each start for a list that the build already knows.
- **A list of the names written by hand.** It drifted from the table: `edit`, a system tool, had no line.
- **The module names as labels.** `hall_of_fame` is an identifier; a menu is read.
- **Icons as pictures of pixels.** A picture has one size; a rectangle of the draw table follows the scale, and the icons need no file of the boot image.
- **The heron on a plate of the title blue.** Its body vanished on it.
- **A transparent picture of the heron over a plate of records.** The picture record copies its pixels as they are; one picture for each look keeps the copy of 24 rows.
- **Lock and shut down in the quick actions.** The compositor has no such operation: the console and the palette hold them, with their second Enter.

## Subtle points

- The places of the heron button and of the button of the windows are constants: the machine test reads them with no measure of a font. The bar layout holds only the width of the widest name, and the log line of the interface font says only that width.
- `menu_line` names a line of a module, and `menu_action` a quick action: a press does the one under the pointer, after the menu is closed, so a move of the bar damages the old and the new places with the menu already gone. The quick action of the demonstrations is the one that keeps the menu open: it changes the layout of the menu, which damages the old and the new card.
- Whether the demonstrations are open is a field of the bar layout, as the edge: each place of the menu comes from the layout, so the tool computes the places of a demonstration with the field set, after its step `Launch` pressed the quick action and read the log line "compositor: the demonstrations of the start menu are shown".
- The table of the draw records of the screen holds 2048 records: the start menu draws up to nine records of an icon on each of its lines.

## State

Built: the heron button in its three looks, the button of the windows, the divider, the window plates with their icons and their preview, the tray with its icons and the buttons of the tray widgets, the start menu in sections by the module category, with the demonstrations closed by default, and its quick actions, the menu of the windows with icons, and an icon in each title bar. Left: a vertical bar; the pills of the network, the sound and the wide grant, which no service sets yet.
