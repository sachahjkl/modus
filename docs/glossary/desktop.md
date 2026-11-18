## Desktop

### Surface

A surface is a memory object that one process draws into and the compositor shows as the content of a window.

A surface keeps the pixels out of the kernel and out of the rings: the process writes pixels in its own memory, and the compositor reads the same memory. A process opens a surface with `display.open(ctx, width, height, title)`, which needs the grant of the display. It draws a picture, then sends `Present` with the rectangle that changed. The compositor sends the input of the window back on the same ring. A surface is not a framebuffer: only the compositor writes the screen.

The design: `docs/DESIGN.md`, "3. Surfaces".

Do not use: window buffer, framebuffer (reserved for the UEFI one).

### Picture

A picture is one complete image in the memory of a surface; a surface has two pictures.

The process draws one picture while the compositor reads the other, and `Present` names the picture that is complete; the next frame draws in the other one. The picture that a frame draws holds the frame of two frames before, so the interface package keeps, for each picture, the rectangles where it differs from the last frame presented. A picture is not a picture record: a picture record shows pixels that the process holds in its own memory, inside its surface.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: back buffer, front buffer, swap chain.

### Whole frame

A whole frame is a picture of a window that reaches the screen complete: the screen never shows a picture that a process is drawing.

It is a rule of the system for every window, and a process writes no code for it. The process draws only the picture that the compositor does not read, and a process that stops in a draw leaves its last complete picture on the screen. The compositor counts the breaks of the rule (`pictures_drawn_again` in `compositor.windows()`). A hostile process can break it, but it spoils only its own window. The frames of the compositor keep the rule too, by a page flip.

The design: `src/md/infrastructure/whole_frame.md`.

Do not use: tear-free, double buffering, vertical synchronization.

### Screen page

A screen page is one whole screen in the video memory of the display: the display shows one screen page at a time.

The video memory of the test machine holds two screen pages. The page 0 is the framebuffer of the firmware. The compositor writes each frame into the page that the display does not show, then a page flip shows it. A screen page holds the frame of two frames before, so the compositor keeps the rectangles where each page differs. On a display with no page flip, the compositor has one screen page. A screen page is not a picture, which is in the memory of a surface.

The design: `src/md/infrastructure/whole_frame.md`, "The screen: two screen pages and a page flip".

Do not use: back buffer, front buffer, framebuffer (for the page 1).

### Page flip

A page flip is the one write of a display register that makes the display show another screen page.

The compositor writes the first line of the page in the register `Offset_Y`, then reads it back: a value that differs is a refused flip, and the compositor goes back to one screen page. `compositor.screen()` counts the flips in `page_flips`. A page flip is not a `Present`: a `Present` names the picture of a surface that the compositor reads next, and a page flip names the screen page that the display shows.

The design: `src/md/infrastructure/whole_frame.md`, "The screen: two screen pages and a page flip".

Do not use: buffer swap, vsync.

### Compositor

The compositor is the service that owns the display: it combines the surfaces of the processes into the framebuffer and routes the input to the process that has the focus.

The compositor is the one process that writes the screen. It draws the background, the bar, each window with its title bar, the menus, the palette and the pointer, and only the damage rectangles of a frame. It sends each key to the process in front, and each pointer event to the process of the surface under the pointer. Today it is also the desktop shell. The compositor is not a display server with a protocol of drawing: a process gives it pixels, never commands to draw.

The design: `docs/ARCHITECTURE.md`, "U8. Graphics: the draw table and the compositor".

Do not use: window manager, display server.

### Damage rectangle

A damage rectangle is a rectangle of the screen or of a surface that changed and that the next frame draws again.

To draw only what changed costs much less than to draw the whole screen. The compositor keeps a few damage rectangles and joins a rectangle that touches another. A process sends the rectangle that changed in its picture with `display.present_rectangle`. The interface package finds the damage rectangles of a window itself, by damage by difference. A damage rectangle is never too small: if a rule cannot say what changed, the damage is larger, and only the time grows.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty region, invalid area.

### Boot display

The boot display is the picture of how the machine started, drawn from the boot record and the other records of the kernel.

The boot display shows each stage of the start and its time, the memory, the firmware, the processors, the processes and the modules of the boot image. Three parts of the system draw it with one package, `src/library/support/bootscreen`: the boot program, the root service while it starts the first processes, so that a failure stays on the screen with its cause, and the process `boot`. The boot display is not a splash screen and not a log of text: it is made of cards with measures.

The design: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: splash screen, boot log, POST screen.

### Console

The console is a normal process that calls commands, functions with typed parameters and a typed result, in a small programming language.

The console replaces the shell: a command is an export of a module, so its arguments and its result are typed values. The console has a terminal and no surface, and acts for the principal of its session. Examples: `grants("notes")` shows the grants of a process; `load("calendar")` loads a module into the console and calls its exports directly. The console is not a TTY and not a shell: it starts no process by a path, passes no text between processes, and has no pipe.

The design: `docs/CONSOLE.md`, "The language of the console".

Do not use: TTY, shell.

### Desktop shell

The desktop shell is the process that starts processes and shows their windows to the principal.

In the first version, the compositor is the desktop shell: its bar has the start menu and the menu of the windows, the palette starts a process and reaches a window, and the close button of a window stops its process. It starts a process by the command `Start` to the root service, which decides the grants of the process. The desktop shell is not a window manager with rules of placement: the compositor places new windows at fixed steps on the grid.

The design: `docs/ARCHITECTURE.md`, "U10. Desktop shell".

Do not use: window manager.

### Focus

The focus is the state of the window in front: its process receives the keys, and its title bar shows it in blue.

The focus decides where each key goes. A press on a window, or a line of the menu of the windows, brings it to the front and gives it the focus. While the palette is open, no process receives a key. Inside a window, the interface package has a focus of its own: the element that takes the keys, which Tab moves. The focus of the compositor chooses a window; the focus of the interface state chooses an element in it. No process can give itself the focus.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: active window, keyboard owner.

### Title bar

The title bar is the top part of the frame of a window, 24 pixels high: the title and the close button.

The title bar says which window has the focus: its title bar is blue with a white title, and the title bar of another window is a quiet grey with a dim title. The close button at its right end is a deep red square, the color of the concept "stop a process": a press on it stops the process of the window. A drag of the title bar moves the window. The compositor draws the title bar, not the process: a process cannot hide the close button.

The design: `docs/DESIGN.md`, "Windows".

Do not use: header, caption, decoration.

### Resizable window

A resizable window is a window whose process states its size limits, so that the principal can drag its edges to give it another size.

A window is fixed unless its process calls `display.resizable_set` with the least and the largest size of its surface. The principal then drags an edge or a corner; at the release the process gets the event `Resized`, makes the surface of the new size with its own budget (`display.surface_resize`), and draws its next frame in it. The compositor shows the old surface until that frame. A resizable window is not a stretched picture: the compositor never scales the pixels of a process.

The design: `src/md/features/window_resize.md`.

Do not use: live resize, size hint, stretchable window.

### Clipboard

The clipboard is the one slot of the compositor that holds the last text that the principal copied, until a process reads it at a paste of the principal.

Control+C asks the window in front for its text; the process gives a memory object of its own with Read, so its budget pays. Control+V lends the window in front a handle with Read to it, revoked after the paste or at the next key of the clipboard. The compositor takes both keys, so no process reads the clipboard by itself, writes it by itself, or sends the keys. The content ends with the process that copied. The clipboard is not a named object that a process opens.

The design: `src/md/features/clipboard.md`.

Do not use: pasteboard, selection buffer, primary selection.

### Bar

The bar is the line at the top of the screen that the compositor draws: the mark of the system, the buttons of the two menus, the key of the palette, and the clock.

The bar is the fixed place of the desktop where the input starts a process or finds a window. A press on a button opens its menu under it. `src/library/private/compositor/bar` holds the places of the buttons and of each line of the menus, and the table of the names of the processes, `bar.names`: the compositor draws from it, and the modus tool presses the same places in the machine tests. The bar is not a task bar and not a dock: it holds two menus and no state of a process.

The design: `docs/DESIGN.md`, "Background and bar".

Do not use: task bar, panel, dock.

### Bar layout

The bar layout is the widths of the texts of the bar, measured in the font that draws them, from which come the place of each button and of each line of a menu.

The names of the bar are in the interface font, which has proportional widths. With places from a fixed width, a press can land beside the entry that the eye sees. So the compositor measures `bar.Layout` at its start and when the font changes, and writes it on the log. The modus tool measures the same layout from the same glyph cache, so it presses the right places. The bar layout is not a set of constants: it depends on the font in use.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bar geometry, bar metrics.

### Start menu

The start menu is the menu of the bar under the button `start`, with one line for each module of the table `bar.names`: a press on a line starts that module.

The menu is the way of the pointer to start a module. It is a card in two columns. A press sends `Start` with the name to the root service, which decides the grants of the process. The start menu is not the palette, which the key super opens and which narrows as the input types. It has no folders and no recent entries: one flat table.

The design: `docs/DESIGN.md`, "Menus".

Do not use: application menu, launcher.

### Menu of the windows

The menu of the windows is the menu of the bar with one line for each window: a press on a line brings the window to the front and gives it the focus.

The menu lets the input reach a window that other windows cover. It lists the windows in the order of the client table of the compositor, and marks the window that has the focus. The line of a disk process has its nickname and the hash prefix of its file. The menu does not move a window. The menu of the windows is not a task switcher with pictures of the windows, and not a task bar.

The design: `docs/DESIGN.md`, "Menus".

Do not use: task bar, window list, switcher.

### Palette

The palette is the panel that the key super opens, where the input types a part of a name and chooses one entry of one list: a process to start, a window to bring to the front, or another operation.

The palette is the way of the keyboard to each operation of the desktop. The compositor draws it and holds its state; the panel holds no right of its own. The list ranks the palette entries by the fuzzy match of the console. Example: the key super, "pla", Enter starts `plasma`. The palette is not a run dialog: it runs only its entries, never a path or a line of the console. It is not a set of colors either.

The design: `docs/DESIGN.md`, "Palette".

Do not use: launcher, command palette, everything palette, run dialog.

### Palette entry

A palette entry is one thing that the palette lists and that the input can choose: a name, a kind, and the fact that its icon says.

The entries are data: the panel only ranks, draws and dispatches them. An entry has a kind, which the row says by its kind icon and in words, a name that the typed part matches, and a fact that the color or the form of the icon says, such as "this entry destroys something". The compositor makes the entries from `bar.names`, its client table and the palette table, when one of them changes. The record is `palette.Entry`. A palette entry is not a command line: it holds no text that another process parses.

The design: `src/md/features/palette.md`.

Do not use: palette item, palette command, action.

### Kind icon

A kind icon is the small picture of one kind of thing, a grid of 12 by 12 square cells, that each display of the system and the site draw from one table.

It lets a reader tell a window from a process, or a handle from a number, before the reader reads a word. `src/library/support/kind_icons` holds the cells only, with no color: the display gives the color. The system draws a cell as a square of 1, 2 or 3 pixels, and the site draws the same cells in SVG, so an icon is never scaled by a filter. A kind icon is not the mark of the system, and it never stands alone: the row says the kind in words too.

The design: `docs/DESIGN.md`, "The icons of the kinds".

Do not use: glyph (for this), symbol (for this), pictogram, badge.

### Palette provider

A palette provider is a process that gives palette entries of its own to the panel and runs the one that the input chooses, with its own rights.

The provider keeps the rule that the panel holds no right: an entry runs in the process that gave it, with its grants. The console is the palette provider: it has the grant `Palette`, writes its commands and its settings in the palette table, and runs a chosen entry as a line. `revoke("console", "palette")` ends it, and the palette keeps the processes and the windows. A palette provider is not a plugin of the compositor: it runs in its own process, and draws nothing in the panel.

The design: `docs/CONSOLE.md`, "8. The palette provider".

Do not use: palette source, palette backend, palette plugin.

### Palette form

The palette form is the input band of the palette while it holds the call of a command with parameters: one typed field for each parameter.

The form lets the input give the arguments of a command without a line. Each field has the name and the kind of its parameter, and the palette provider gives its candidates. Tab takes a candidate or goes to the next field; Enter in the last field runs. The values go to the provider as typed values, and the provider builds the line. Example: `revoke(name: plasma, grant: log)`. The palette form is not an edit line: it holds no expression and no variable.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: dialog, prompt, argument box.

### Field control

A field control is the form in which the palette shows one field of a palette form, chosen from what the field is: a typed text, a typed Integer, a typed number with its unit, a list of candidates, or a row of buttons.

The field chooses its control, so no command needs a form of its own and a provider gives data only. One table of the code gives it (`palette.field_control`). Example: the field of `strategy(name: )` is a row of three buttons, `round_robin`, `fair`, `eevdf`, because its candidates are the only values of the parameter. A field control is not an element of the interface package: the palette draws it in its own panel, and a process cannot give the palette one.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: widget, input type.

### Setting row

A setting row is one row of the palette that holds every value of one setting: the name of the setting, then one button for each value, with a line under the value in use.

The row lets a principal see the values of a setting together and set one with one key. The palette provider writes one palette entry for each value, and the palette joins the entries of one setting into one row. Left and Right choose a value, Enter sets it. Example: `font  [vector] spleen`, with the line under the font in use. A setting row is not a palette form: it has no field and no typed value.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: radio group, toggle, option row.

### Palette table

The palette table is the memory object where the palette provider writes its entries, and which the compositor maps read-only.

The table carries data and no text of a line: for each entry its kind, its name, the kinds of its parameters and of its result, a help sentence and an act name. The compositor copies the table and checks each field of the copy before it uses it: a table that fails is no table. One ring goes with the table: the compositor names the chosen entry, and the provider answers in the result area. The palette table is not a call region: the compositor waits for no answer in its loop.

The design: `docs/CONSOLE.md`, "8. The palette provider".

Do not use: command table of the palette, entry file, palette registry.

### Interface package

The interface package is `src/library/support/interface`: the code that builds the window of a process as a draw table at each frame, lays it out on the grid, takes the pointer and the keys, finds the damage, and draws.

The package gives each process one way to draw its window by the design rules. It works in immediate mode: at each frame, the process calls an element procedure for each part of its window, such as `button`. Each call appends draw records and gives back what the input did to that element. The package allocates nothing, and an error is a value. Example: `disk`, `monitor` and the palette are drawn with it. The interface package is not a toolkit with objects, callbacks and a tree.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables".

Do not use: toolkit, widget library, UI framework.

### Library module

A library module is a module that holds code that many modules import, in place of a package that each module compiles into its own file.

A package that many modules compile in is many copies of the same code, with no record of what each module holds. A library module is one file with one hash: the import table of each importer names it, and a change of its code builds one module. Its exports are coarse: a call passes whole tables of the caller, by address, with no copy. Example: the drawing module. A library module is not a second kind of import: the loader binds it as each import.

The design: `docs/MODULE_CONTRACT.md`, "A library as a module".

Do not use: shared library, dynamic library, runtime library.

### Drawing module

The drawing module is the module `drawing`: the code that finds the damage between two draw tables and draws the records of a draw table into pixels, for each process that imports it.

It is the first library module. A window calls `damage_of_draw_table_16` once for a frame to get the damage rectangles, then `execute_draw_table_in_rectangles_16` once to draw the records in them, into the pixels of its surface. Each argument is memory of the process, passed by address. The 16 in the names is the version of the draw record. The terminal and the compositor draw through it too. The drawing module is not a render service: it runs in the process that calls it.

The design: `docs/INTERFACE.md`, "7. Where it lives: the elements in each process, the drawing in a module".

Do not use: renderer module, graphics library, render service.

### Draw record

A draw record is one thing to draw, in 48 bytes: a rectangle or a pattern of rectangles, a gradient, a run of text, a clip, a picture, a text grid or a path, with its box and the fields of its kind.

Records of one fixed size make a frame plain data: a table that can be compared, drawn again in a part, or tested. A record is a header (its kind, its element identity, its box in 1/64 pixel) and 24 bytes of the fields of its kind only. The contract package `draw_record` holds the form, its version and its one border, `draw_record.read`, which refuses a byte past its bound. A draw record is not a command to a graphics processor: it is drawn on the processor, in the memory of the process.

The design: `docs/INTERFACE.md`, "2.1 Draw record".

Do not use: draw command, display list item.

### Draw primitive

A draw primitive is what one draw record draws, as a reader sees it past the border: one record type for each kind, with the fields of that kind only.

`draw_record.read` gives it as `Draw_Primitive`, a union of Odin, from the bytes of a record, and `draw_record.record_of` writes the bytes of a record from it. The bytes are the contract; the union is the view of one reader, so no contract depends on a feature of the language. Example: a `Draw_Rectangle` holds a color, and its box stays in the record. A draw primitive is not a command to a graphics processor.

The design: `src/md/api/draw_table.md`, "The record: a header and the fields of one kind".

Do not use: draw command, shape.

### Draw color

A draw color is the color of a draw record: `0xAARRGGBB`, with straight alpha in the high byte, so alpha 255 is opaque and the color 0 is transparent.

It blends over the pixels by one rule in linear light, the rule of the glyphs with the alpha as the coverage of the three channels. A color with alpha 0 has one form, 0, so two rectangles that draw nothing in one box have the same bytes, but for their patterns. A writer makes one from a color token with `draw_record.opaque` or `draw_record.with_alpha`. A draw color is not a pixel of a surface: a pixel is `0x00RRGGBB`, and stays opaque.

The design: `docs/INTERFACE.md`, "2.1 Draw record".

Do not use: RGBA color, premultiplied color, opacity.

### Gradient record

A gradient record is a draw record that fills its box with a color that goes from one color at one point to another at a second point, along the line of the two points.

The level of a pixel is the projection of its center on that line, cut to the two ends, in steps of 1/255; the two colors mix at that level, alpha too. A gradient down or across is one with its points on one x or one y: `draw_vertical_gradient` and `draw_horizontal_gradient` write them. A gradient record is not a gradient of several stops: a writer puts one record for each pair of stops.

The design: `docs/INTERFACE.md`, "2.1 Draw record".

Do not use: linear gradient, ramp, blend record.

### Covered alpha

The covered alpha of a pixel is the alpha of a color times the part of that pixel that the box of a rectangle or a gradient covers.

The part is the product of the parts on each axis, in 1/64 of a pixel, so an edge of a box can lie between two pixels: `(alpha × x × y + 2048) >> 12`. A pixel covered whole keeps the alpha of its color, so a box on whole pixels draws the pixels of a fill. The covered alpha is not the coverage of a glyph, which has one value for each channel.

The design: `docs/INTERFACE.md`, "2.1 Draw record".

Do not use: antialiasing value, edge alpha, opacity.

### Draw table

A draw table is the draw records of one frame of a window, the bytes of their texts, the cells of their text grids and the points of their paths, and the picture memories that they name, in the memory of the process.

It is the one 2D interface of the system: each window and the compositor draw through it, and a GPU later draws the same table through WebGPU. The process owns it (`Draw_Table` of `src/library/support/interface`) and keeps the table of the frame before, to find the damage by difference. A full table sets `full`; a record that names memory outside the table sets `refused`. A draw table is not a tree: two tables compare record by record at the same index.

The design: `docs/INTERFACE.md`, "2.1 Draw record"; its rationalised form: `src/md/api/draw_table.md`.

Do not use: display list, command buffer, render tree.

### Byte table

The byte table is the bytes of a draw table that its records name by an offset: the UTF-8 of the texts, the cells of the text grids and the points of the paths.

A record holds no address, so its variable part goes here, and the record keeps a fixed size. The difference ignores the offset of a record and compares the bytes that it names. It is the field `text` of `Draw_Table`, the text table. A byte table is not a heap: it is filled in the order of the records and emptied at each frame.

The design: `src/md/api/draw_table.md`, "The byte table".

Do not use: text buffer, payload buffer, arena.

### Window memory

A window memory is the record of a process that holds the drawing of one window and the memory of its two draw tables.

The process declares one for each window (`Window_Memory(RECORDS, TEXT)` of `src/library/support/interface`), with the capacity of each draw table in records and in bytes of text, and starts each frame with `window_frame_start`. The record is memory of the process, so the package allocates nothing. Example: `budget` keeps `window_memory: interface.Window_Memory(512, 8192)`.

A window memory is not the surface of the window: the pixels are in the memory object of the surface, which the compositor reads.

The design: `docs/INTERFACE.md`, "2.3 Memory of the caller, errors as values".

Do not use: window buffer, frame memory.

### Text grid

A text grid is a grid of text cells of a process (a character, reverse, a color, or a fill), drawn by one draw record.

A terminal changes many cells many times in one second, and one record for each cell makes a large table. So one text grid record names the whole grid. A cell holds one code point. `draw_text_grid` copies the cells into the text table of the frame, so the record holds values only, and the difference compares the cells: in each row, the span of the changed cells is damaged. The console draws no pixels: the text grid of the terminal draws it. A text grid is not a screen buffer of a text mode.

The design: `docs/INTERFACE.md`, "2.4 Text grid".

Do not use: character matrix, screen buffer.

### Picture record

A picture record is a draw record that shows the pixels of a picture of the process, with a generation that changes when the pixels change.

A process that computes or holds its own pixels, such as `life`, `paint` or `plasma`, puts its image in a draw table as one record. The record names its pixels by values: its picture memory, its first pixel, its stride, its size, and its format: copied, or blended with alpha. The process raises the generation when its pixels change; with the same generation the record damages nothing. A picture record is not a picture of a surface: it shows a canvas that the process holds, inside its surface, and it holds no address.

The design: `src/md/api/picture.md`.

Do not use: image node, bitmap item.

### Picture memory

A picture memory is one run of pixels of a process in which picture records name their pictures by the index of a first pixel and a stride.

A description carries values only, so a picture record cannot name a canvas by its address. The draw table holds a list of picture memories, and a picture record names one by its number. `draw_picture(table, x, y, canvas, generation)` finds the memory that holds the canvas and writes the values. The compositor has one picture memory for each surface. A picture memory is not a surface and not a picture of a surface: it is memory of the process that its records show.

The design: `src/md/api/picture.md`.

Do not use: picture buffer, pixel pool.

### Path record

A path record is a draw record of lines and quadratic curves, from points in the byte table, that is filled, then stroked, with antialiased edges, cut to its box.

A window draws an icon, an arrow or a chart from outlines with it: `draw_path(table, points, fill, stroke, stroke_width)`. A line is a path record of one segment, stroked: `draw_line` writes it. The coverage of each pixel is its exact area, so the pixels are the same in each damage rectangle. A path record has at most 1 024 points. It is not a clip, and it has no cubic curve, no dash and no round join.

The design: `src/md/api/draw_table.md`, "The kinds".

Do not use: line record, shape record, vector record, polyline.

### Path point

A path point is one point of a path record in the byte table, 12 bytes: the word of its command, then its x and its y in 1/64 pixel of the surface.

The command is a `Path_Command`: `Move` starts a subpath, `Line` adds a segment, `Curve_Control` is the control point of a quadratic curve whose end is the next point, `Close` closes the subpath. The border of the points, `draw_record.path_points_read`, loads each point once and refuses a word that names no command, a point past the coordinate limit and an order that the contract forbids. A path point is not a pixel: it lies inside a pixel.

The design: `src/md/api/draw_table.md`, "The kinds".

Do not use: vertex, control vertex.

### Subpath

A subpath is the part of a path record from one `Move` to the next one, or to the end: one outline, open or closed.

The fill closes each subpath. The stroke closes only a subpath that ends with a `Close`: its last segment goes back to its `Move`, and its two ends are joins. Example: the folded gap is one path record of two subpaths, its two lines. A subpath is not a path record: one record holds many subpaths.

The design: `src/md/api/draw_table.md`, "The kinds".

Do not use: sub-path, path part.

### Fill rule

The fill rule says which pixels are inside a path record: the nonzero rule, by which a place is inside when the outline goes round it a number of times other than 0.

Two subpaths in one direction that overlap fill their overlap once; two in the two directions leave a hole there. A pixel inside is covered whole, so a translucent fill blends once; a pixel on an edge is covered by its part inside. The even-odd rule is not built: no process needs it yet.

The design: `src/md/api/draw_table.md`, "The kinds".

Do not use: winding mode, fill mode.

### Stroke

A stroke is the band of a width along each segment of a path record, with butt ends and a bevel join between two segments, drawn after the fill in its own color.

Its width is in 1/64 pixel, from 1 unit to 64 pixels; a path with no stroke has the stroke color 0 and the width 0. A pixel covered by two segments of one stroke blends once. A line of `draw_line` is a stroke whose two points go half the thickness past its two ends. A stroke is not an outline of a rectangle: `draw_outline` writes four rectangles.

The design: `src/md/api/draw_table.md`, "The kinds".

Do not use: line width, pen.

### Element

An element is a part of a window that one call of the interface package draws: a card, a line of a label and a value, a bar, a table, a button, a list with a choice, or a text input.

An element is a call, not an object: the process calls it at each frame with its area and its data, and gets back an `Element_Result` (pressed, has the focus, changed). An element that takes input also takes an element identity, so the interface state can follow it. Example: `button(frame, area, identity("start"), "start")` draws a button and says if the input pressed it. An element is not a widget: it does not live between frames, has no callback, and holds no copy of the data of the process.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables".

Do not use: widget, control, component, view.

### Element identity

An element identity is a number that names one element from one frame to the next, made from a text: the focus and the state of the pointer follow it.

In immediate mode no object lives between frames, so the interface state needs a stable name for each element that takes input. `identity("list")` gives the 64-bit FNV-1a hash of the text. Two elements with one text have one identity; `identity_with(base, row)` and `identity_in(parent, name)` make them two. Each draw record keeps the low 32 bits of the identity that wrote it, so a tool can say which element changed.

An element identity is not a handle: it names nothing in the kernel and gives no access.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: id, key, handle (reserved for the kernel).

### Act name

An act name is a text of at most 32 bytes that names what an element of a window or a palette entry acts on, such as `settings.set:font`.

An act name lets the palette go to the element of a window that does what an entry does. A process names an element with `element_act_name(frame, element, "settings.set:font")`, and the palette provider writes the act name of each entry. When an open window names the act name of the chosen entry, the palette offers "shift enter: go to", and the focus goes to that element. An act name is not an element identity: many processes can use one act name, and it names no rectangle.

The design: `docs/INTERFACE.md`, "4.2 Act names".

Do not use: action, anchor, target.

### Element name

An element name is a text of at most 32 bytes that names an element of a frame for a machine test, such as `watch` or `frame 0`, with the rectangle where it takes a press.

A machine test presses an element by its element name, so a change of the layout moves the press with the element. A button is named by its label; a process names another element with `element_name(frame, area, "frame 0")`. The window layer writes an element line when the rectangle of a name changes. An element name is not an element identity: the interface state does not follow it. It is not an act name: the palette does not read it.

The design: `src/md/infrastructure/test_pointer.md`.

Do not use: test id, locator.

### Action bar

An action bar is the band at the bottom of a window that names its keys: each item is the keycaps of one key combination, then the name of its action.

A window that the keyboard drives draws it with the element `action_bar`. A press on an item gives the process the key of the item, so the press and the key run one piece of code. When the items do not fit, the items of lowest priority go behind a button `more`. Example: the item `Backspace` back of `manual`. An action bar is not the bar of the desktop, and not a bar element. The action of an item is not an act name and not a palette entry.

The design: `src/md/features/action_bar.md`.

Do not use: toolbar, key hint line, shortcut bar, footer.

### Keycap

A keycap is the small rectangle that shows one key of a key combination in an action bar, with the name of the key on it: `Tab`, `Enter`, `Backspace`, or a triangle for an arrow key.

The keycaps of one combination stand side by side with a `+` between them: `Shift` + `Tab`. A keycap has a border of 1 pixel and the gradient of a card. The fonts have no arrow character, so the keycap of an arrow key draws a triangle of rectangles; `Page Up` is the word `Page` and the triangle.

A keycap is not a button: the item of the action bar around it takes the press.

The design: `docs/DESIGN.md`, "The action bar".

Do not use: key badge, key chip, kbd.

### Element line

An element line is the line of the log that says where an element with an element name is, or that it is gone: `interface: debugger_window: the element watch at x,y,width,height`.

A window writes it after a drawn frame in which the rectangle of the name is new or changed, and writes `the element <name> is gone` when its frame no longer has the name. A frame with no change writes no line. The compositor writes the element lines of the palette in pixels of the screen. The modus tool reads the last element line of an element before a press. An element line is not a contract between two processes: no process reads it.

The design: `src/md/infrastructure/test_pointer.md`.

Do not use: layout dump, element report.

### Interface state

The interface state is what the interface package keeps between frames, in the memory of the process: the element with the focus, the element under the pointer, the pressed element, the order of the focus, and the held part of a scroll bar.

The interface state is the only state of the package, and the process owns it. With it, a press and a release on one element press that element, and Tab and Shift+Tab move the focus in the order of the elements of the last frame. The order holds 64 elements (`FOCUS_ORDER_CAPACITY`). The interface state is not a retained tree of the window: it holds element identities only, and no copy of the data that the window shows.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: UI context, retained state.

### Damage by difference

Damage by difference is the damage rectangles that the interface package finds by a comparison of the draw table of this frame with the draw table of the frame before.

Immediate mode has no tree whose nodes know what changed. The difference gives that back: `damage_by_difference` compares the two tables record by record at the same index. Two equal records damage nothing; two different records damage the old rectangle and the new one. A record added in the middle moves the records after it, so the damage is too large, never too small. The process never tracks damage by hand. Damage by difference is not an invalidation that a process calls.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty tracking, invalidation.

### Scroll bar

A scroll bar is the element beside a view that shows a part of a longer content: it shows where the view is in the content, and the pointer moves the view with it.

Each scroll bar of the system is the element `scroll_bar`, and the scroll bars of the site have the same form, from one table of sizes and colors. Its parts are two arrow buttons, the track, and the thumb with its grip. A process gives the units of its content, the units in view and the first unit in view, and takes the new first unit. A scroll bar is not a bar element and not the bar of the desktop. It takes no key.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: scrollbar (one word, outside a CSS name), scroll mark, scroller.

### Wheel notch

A wheel notch is one step of the wheel of a pointing device, toward the principal or away from the principal.

The pointer record carries the notches as a signed count. A notch toward the principal moves a view toward the end of its content, as the key Down does. The compositor gives them to the palette while it is open, else to the process of the window in front, when the pointer is over its surface: a window behind gets no notch. There, the scroll bar under the pointer moves its view by three lines for each notch. A wheel notch is not a button of the pointer, and not a count of pixels.

The design: `src/md/features/scroll_bar.md`.

Do not use: scroll event, wheel click, wheel delta.

### Scroll bar track

The scroll bar track is the part of a scroll bar between its two arrow buttons, on which the thumb moves.

Its length stands for the whole content. A press on it, before or after the thumb, moves the view by one page toward the pointer. It has a border of 1 pixel and a gradient across it. The word is the word of the design rules for the empty part of a bar (`colors.track`), and of the parts of a scroll bar in a style sheet.

The scroll bar track is not the whole bar: the arrow buttons are outside it.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: trough.

### Thumb

The thumb is the part of a scroll bar that lies on its track and stands for the view: its length is the share of the content that the view shows, and its place is the place of the view.

A press on the thumb holds it, and it follows the pointer until the button goes up. It is at least 8 % of the track and 8 pixels long. A thumb longer than 20 pixels has a grip. Under the pointer it takes blue tones.

The thumb is not a thumbnail, which is a small form of a picture of the site.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: handle (reserved for the kernel), scroller.

### Grip

The grip is the four short lines in the middle of the thumb of a scroll bar, across it.

It marks the thumb as the part that the pointer holds. Each line is 7 by 1 pixels, 1 pixel from the next. A thumb of 20 pixels or less has no grip.

The grip carries no fact and takes no input of its own: a press on it is a press on the thumb.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: gripper, handle (reserved for the kernel), ridges.

### Arrow button

An arrow button is the square at each end of a scroll bar, with a triangle that points to that end: a press on it moves the view by one line.

While it is held and the pointer stays on it, the view moves again after 400 ms, then each 60 ms, by the clock of the system. At rest it shows its triangle only; with the pointer over the bar it has a border and a fill. A bar shorter than 42 pixels has no arrow button.

An arrow button is not the element `button`: it has no label, takes no focus and no key.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: stepper, scroll arrow, spin button.

### Pointer

The pointer is the mark on the screen that the pointing device moves: a press acts at its place.

The compositor draws the pointer last, with the pointer picture of the pointer shape that it chose, and puts the hot spot of the picture at the place of the pointer. It sends each pointer event to the process of the surface under the pointer. In a machine test, `compositor.pointer()` gives the place and the shape of the pointer. The pointer is not the caret, which marks a place in a text. The system does not use the word "cursor" for either one.

The design: `docs/POINTERS.md`, "How the compositor draws the pointer".

Do not use: cursor, mouse cursor, mouse pointer.

### Pointer shape

A pointer shape is what the pointer shows, as one name of the system: `arrow`, `text`, `pointing_hand`, `move`, `wait`, and ten more.

One list of names lets any theme serve each process: a process asks for a name, and the theme gives the pictures. The compositor chooses the shape from what is under the pointer, such as `move` over a title bar. A process asks for a shape over its own surface with `display.pointer_shape_set`, and the compositor shows it only while the pointer is over that surface, so a process cannot change the pointer over another process. A pointer shape is not a file name of a theme.

The design: `docs/POINTERS.md`, "The pointer shapes".

Do not use: cursor type, cursor name, cursor kind.

### Pointer picture

A pointer picture is one image of one pointer shape at one nominal size, for one frame of an animation: its width, height, hot spot, delay and pixels with premultiplied alpha.

A pointer theme file holds the pictures of each shape, size by size. An animated shape has several frames, each with its delay: `wait` in the theme of the system has 16 frames of 60 ms. The compositor blends the picture over the screen with premultiplied alpha. A pointer picture is the one picture of the desktop that is not made of rectangles: the pictures of both themes have smooth edges and transparency.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor image, sprite, icon.

### Hot spot

The hot spot is the pixel of a pointer picture that the compositor puts at the place of the pointer.

A press acts at the place of the pointer, so the hot spot is the pixel that "points": the point of the arrow, the centre of a crosshair. Each pointer picture has its own hot spot, inside its width and its height. A manifest gives it with `hot` in pixels of the smallest size; the tool multiplies it for the other sizes.

The hot spot is not the top left corner of the picture, except for the arrow.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: click point, hotspot, anchor.

### Nominal size

A nominal size is the size in pixels that a theme gives to a pointer picture, to choose among its sizes.

A theme has 1 to 8 sizes for each shape, in increasing order: the theme of the system has 24 and 48, the Posy theme 32 and 64. The frames of one size share one nominal size. The width and the height of a picture can differ from its nominal size.

A nominal size is not the width of a picture, and not a scale of the screen.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor size.

### Pointer theme

A pointer theme is the pointer pictures of each pointer shape, with a name, a license and an attribution.

The system has two themes. The theme of the system is outlines that the tool draws at the build; it is always in the boot image. The Posy theme, "Posy's Cursor", comes from a build input of the development shell, and no release image holds it, because its license allows no public download. The Posy theme is the default when the build has its input. The setting `pointer_theme` chooses one of them. A pointer theme is not an icon theme: it holds the pictures of the pointer only.

The design: `docs/POINTERS.md`, "5. The two themes".

Do not use: cursor theme, icon theme.

### Pointer theme file

A pointer theme file is one pointer theme in the format of the system: a header, a table of shapes, a table of pictures, then the pixels.

One file for a whole theme lets a process map it read-only and read it in place, with no parse at run time. The format is `src/library/contract/pointer_pictures`. One function, `pointer_pictures.validate`, checks every field once; the tool and the compositor run it, and the compositor does not trust the file even from the root service. A pointer theme file is not an Xcursor file or a `.cur` file: the tool reads those formats only to make this one.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor file, .cur, Xcursor file (for this).

### Pointer form

A pointer form is one set of the pictures of a pointer theme for one appearance of the desktop: the dark form for a dark desktop, the light form for a light one.

A pointer theme file holds one or two forms. The dark form of the theme of the system is a white fill in a dark edge, the light form a dark fill in a white edge, so the fill has a strong contrast on the surfaces of its appearance. A theme with one form, such as the Posy theme, gives it for both. A pointer form is not a pointer theme: the setting `pointer_theme` chooses the theme, the appearance chooses the form.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor variant, dark cursor, mode (for this).

### Pointer manifest

A pointer manifest is a text file of the repository that says how the tool makes a pointer theme file: for each pointer shape, the files of an Xcursor theme or an outline, and the adjustments.

The manifest keeps the choices about a theme in text that a reader can review, with no JSON and no general parser. A shape has sources or an outline, not both, and a manifest names a color by its token, never by a value. `modustool pointers` reads it and writes the pointer theme file. An error gives the file, the line, the column and what was expected. A pointer manifest is not the `index.theme` of an icon theme: the system reads no file of a theme at run time.

The design: `docs/POINTERS.md`, "4. The manifest".

Do not use: config, recipe, index.theme.

### Premultiplied alpha

Premultiplied alpha is a form of a pixel whose red, green and blue are already multiplied by its alpha.

With premultiplied alpha, a blend is one multiplication for each channel: `result = source + destination * (255 - alpha) / 255`. Straight alpha needs three more multiplications for each pixel. The pixels of a pointer theme file have premultiplied alpha, the form of an Xcursor file, so the tool converts nothing. Premultiplied alpha is not straight alpha: a straight pixel with alpha 0 can hold any color, and a premultiplied one is all zero.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: straight alpha (for this).

### Resource

A resource is a file of the boot image that is not a module: data that a process reads in place, named by the hash of its bytes.

The resources are the pointer theme files, the glyph caches, the link pages of the manual, and the system description with its signature. Their table is apart from the table of the modules, so a reader of modules never takes a resource for a module. No process reads the resource table by itself: the root service finds a resource by its name, checks its hash, and gives one process a read-only mapping of it. A resource is not an asset that a process loads by a path: it has no path.

The design: `docs/ARCHITECTURE.md`, "U2b. Resources of the boot image".

Do not use: asset, data file, blob.

### Caret

The caret is the mark in a text input of the place where the next typed character goes.

The caret shows where the keys act. In the input band of the palette it is a bar of 4 by 32 pixels in the blue of the title bar, at the place of the typed part where the next character goes; in the edit line of the console the line editor keeps its place. A text input shows the caret only when it has the focus.

The caret is not the pointer: the pointer follows the pointing device, the caret follows the keys. The system does not use the word "cursor" for either one.

The design: `docs/DESIGN.md`, "Palette".

Do not use: cursor, text cursor, insertion point.

### Picker

The picker is the surface of the document service where the principal chooses a document; its result is a grant to the process that asked.

The picker makes the choice of the principal the grant: a process cannot list documents, and gets a handle to the one document that the principal chose. The document service records each grant, so that the principal can list and revoke it. The document service and its picker are not built.

The picker is not a file dialog that a process draws: it is the surface of another process, so the process that asks sees only the result.

The design: `docs/ARCHITECTURE.md`, "U6. Document service".

Do not use: file dialog, powerbox.

### Quality profile

A quality profile is one of the two sets of thresholds of the standard of quality of the desktop: the GPU profile and the processor profile.

The GPU profile is 120 Hz at 1920 × 1080: a frame in less than 8.3 ms, a key to the screen in less than 20 ms, a window shown less than 100 ms after its start. The processor profile, for a machine with no GPU, can lower the resolution, the rate or the effects, with thresholds from a measure: today 1920 × 1080 at 120 Hz with no blur. The system chooses its profile at its start and writes it on the log. A threshold is a measure that the tool follows, never a test.

The design: `src/md/features/desktop_to_browser.md`.

Do not use: performance mode, power profile, quality setting.

### Reference screen

The reference screen is the screen for which the desktop is laid out and on which the test machines take their pictures: 1920 × 1080.

The contract package `reference_screen` holds its size: the boot program asks the firmware for that mode, and the tool checks the screenshots and the video memory of its machines against it. The desktop draws on it at scale 1: a logical pixel is a pixel of the screen. A firmware with no mode of this size gets the largest mode inside it, and the boot program names the mode on one line.

The design: `src/md/features/desktop_to_browser.md`, "The reference screen".

Do not use: default resolution, target screen.

### Logical pixel

A logical pixel is the unit in which a process places and sizes what it draws; the scale factor turns it into pixels of the screen.

The grid of 8 is 8 logical pixels, and a window states its size in logical pixels. At scale 1 a logical pixel is one pixel of the screen. At a scale of 1.25 the grid is 10 pixels of the screen. A logical pixel is not a point of a font, and not a pixel of a picture, which keeps its own pixels.

The design: `src/md/features/desktop_to_browser.md`, "The reference screen".

Do not use: device-independent pixel, virtual pixel.

### Scale factor

The scale factor is the count of pixels of the screen for one logical pixel, in eighths: from 1.25 to 2 on the reference screen.

It is one setting of the system, not a choice of each process, so every window on a screen has the same scale. A count of eighths keeps the grid of 8 on whole pixels of the screen; a scale such as 1.3 has no value. The drawing module turns places into pixels of the screen and rounds each edge. The desktop draws at scale 1 still; the boot display takes its scale from the size of the screen, snapped to the sizes of its font.

The design: `src/md/features/desktop_to_browser.md`, "The reference screen", and `src/md/features/boot_display_scale.md`.

Do not use: interface zoom, DPI setting, scaling percentage.

### Window bound

The window bound is the largest size of a window with its frame: 1024 × 768 under the bar, so at most 1000 × 708 for the surface.

It keeps each window inside a screen of 1024 × 768, and inside the logical screen of the reference screen at each scale up to 1.375. A window larger than the bound is a fault of its layout. The range of the scale factor sets the bound: a scale above 1.375 needs a smaller bound or resizable windows.

The design: `src/md/features/desktop_to_browser.md`, "The reference screen".

Do not use: maximum window size.

### WebGPU subset

The WebGPU subset is the part of WebGPU that the system writes itself: only what the draw table, the compositor and 3D need.

Its shaders are compiled from WGSL to SPIR-V by the build, so the system holds no compiler of shaders. It has two back ends with the same objects (buffers, pipelines, command lists, draw calls): the GPU back end, over Vulkan through Venus, and the processor back end, with a small fixed set of shaders in Odin. It is not wgpu or Dawn.

The design: `src/md/features/gpu_access.md`.

Do not use: WebGPU implementation, software WebGPU.
