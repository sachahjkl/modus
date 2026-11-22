# Desktop-free console renderers

The console (`src/modules/system/console`) writes only typed records onto the `modus:terminal` ring: styled text runs, Lex `Code_Runs`, cursor position, status bar, hints, and the interactive `List_Keeping` completion popup. It draws no pixels. A modus image with no desktop keeps the console experience — 24-bit colors, syntax highlighting, completion popups, `Ctrl+R` history search, tables and `log.follow` — by swapping only the process at the other end of the ring: the holder of the role Terminal (property 23).

## Which renderer a machine runs

The root service chooses the renderer once, before the start policy, from the modules of the signed boot image and the screen of the machine (`role_policy.console_renderer_choose`, host-tested on each of the 32 cases):

| The image holds | The machine | The holder of Terminal | The holder of Display |
|---|---|---|---|
| the compositor | any | `terminal` | `compositor` |
| no compositor, `dom_terminal` | any | `dom_terminal` | none |
| no compositor, `grid_terminal` | a screen | `grid_terminal` | none |
| no compositor, `serial_terminal` | any other case | `serial_terminal` | none |
| none of the four | any | `terminal` | `compositor` |

- The compositor wins. A desktop image behaves as before, whatever else it holds: the choice changes no holder, no start and no window.
- `dom_terminal` comes next, with or without a screen: an image that holds it is made for a page, which draws the terminal itself.
- The choice writes the defaults of the image only. A plan of principal 0 still overrides a holder, as for each other role.
- A console image has no window server. `start_view_give` starts a process with no terminal with no window, and a disk process gets none either. A start of `display` is refused: with each of the three renderers the role Display has no holder.
- **`grid_terminal` does not hold Display.** It writes the screen, but it does not implement the display contract: a caller that resolves `display` and reached it would send records that it does not read (property 23). The framebuffer is its device grant as the holder of Terminal, and the start check keeps it the one screen writer. Refused: `grid_terminal` as the holder of both roles.
- `serial_terminal` and `dom_terminal` need no screen: on a machine with no framebuffer, the console starts with them (`role_policy.console_renderer_needs_screen`). With `grid_terminal` or the desktop, a process with the grant Terminal still needs a screen.
- The root service writes one line for a console image: "root: no compositor in the boot image: the console writes to the second serial port through serial_terminal", or the line of the grid, or of `dom_terminal`.

## Variant A: serial_terminal

ANSI 24-bit TrueColor over COM2. `src/library/internal/serial_terminal/ansi_terminal` and `src/modules/system/serial_terminal` translate the typed records into 24-bit TrueColor ANSI escape sequences, and decode VT100 and UTF-8 input bytes back into `terminal_records.Key`.

- **COM2, never COM1.** COM1 (`0x3F8`) is the log of the kernel, which the kernel writes itself and the tools read line by line. The renderer drives COM2 (`0x2F8` to `0x2FF`, `terminal_records.SERIAL_PORT_FIRST`), whose ports the root service gives it as a Ports handle: the kernel then opens these 8 ports in its I/O permission map, and no other. Text of a terminal never mixes with lines of the log.
- **The layout.** The last row is the edit line. The rows above it are the output, a VT100 scroll region (`DECSTBM`) that scrolls by itself. The output keeps its own cursor, saved with `ESC 7` and restored with `ESC 8`, so the edit line and the completion list never move where the next output goes. A completion list goes under the edit line when it fits, and above it if not.
- **The text of a process never acts on the terminal of the reader.** The renderer decodes the text as UTF-8. Each C0 control but Tab (ESC, CR, LF, BS and BEL included), Delete, each C1 control (U+0080 to U+009F, the 8-bit CSI `0xC2 0x9B` among them) and each invalid sequence (a raw byte `0x80` to `0xFF` included) becomes one `?`. Each other character passes whole, and a completion row counts characters, not bytes.
- **One renderer at a time.** The root service starts a renderer only when the holder of Terminal is the module that the image chose, and when no renderer runs (`role_policy.console_renderer_start_check`): a plan cannot give COM2 or the framebuffer to another module, and two processes never hold one device. A renderer stops with its process, and its place is forgotten when it stops.
- **The decoder** is the one of all the renderers on COM2 ("One key decoder"). It refuses a CSI sequence longer than 16 bytes, a control byte inside a sequence, and overlong or surrogate UTF-8 (the replacement character). An ESC inside a sequence starts the next one, so a key typed before the end of the last sequence is kept. An Escape with no byte after it for 20 ms by the clock of the system is the key Escape, so a sequence whose bytes come slowly stays one key. A UART that keeps its transmit register full past a bounded count of reads is taken as absent: the renderer writes no more.
- **No UART.** A line status that reads all ones is no UART: the renderer writes one line and reads the ring and drops it, so the console never waits on a full ring.

## Variant B: grid_terminal

A monospace grid on the framebuffer. `src/library/internal/grid_terminal/grid_renderer` and `src/modules/system/grid_terminal` render the same records onto the framebuffer with `graphics.character` (Spleen 8x16) and dirty rows.

- **The one screen writer.** The root service gives `grid_terminal` the framebuffer of the firmware and the input ring of the input service, which the compositor reads in a desktop image. The boot display of the root service draws nothing after `grid_terminal` starts; a failure of the start stops it and takes the screen back for the boot display.
- **The keys.** `grid_renderer.key_of_input_record` is the border of the input ring: a press gives its key; a release, a pointer record, a word that names no input, a code past `KEY_EXTENDED | 0xFF`, a character that is no code point and a modifier bit that names no modifier give none.
- **The output** wraps at the last column and scrolls the rows above the edit line, one cell for each UTF-8 character, with the replacement character for an invalid sequence.
- **A completion list that moves** marks the rows under its last box dirty, so no part of an old box stays on the screen. The box is drawn again only when the list changed, when it moved, or when a row under it was drawn again.
- **The edit line** takes one cell for each UTF-8 character, and its cursor is placed by characters, not bytes.
- **No periodic wake.** The grid has no blinking cursor: it waits on the terminal ring and the input ring with no deadline.

## Variant C: dom_terminal

One JSON line for each change of the terminal, over COM2, for a page that draws the terminal with the elements of its document. `src/library/internal/dom_terminal/dom_protocol` and `src/modules/system/dom_terminal` write the lines; `browser_machine_console.html` draws them.

- **Why not the bytes of a VT100 screen.** A page that plays a VT100 screen keeps a fixed grid of cells: text that the reader selects crosses the edit line and the list, a resize cuts lines, and a change of theme needs the colors of each cell again. The lines of `dom_terminal` say what each part is; the page keeps the output as lines of text that the browser selects, copies and wraps.
- **The lines.** Each step of the intake gives one object, ended by `\n`:
  - `{"t":"out","s":"...","tone":"good","code":"function","fg":"#rrggbb","rev":true,"nl":true}`: a run of the output. A key comes only when it says more than plain text. `nl` ends the line of the page.
  - `{"t":"clr"}`: forget the output.
  - `{"t":"edit","text":"...","cur":12,"runs":[[0,4,"function"],...]}`: the edit line, its cursor and its runs of code. No `cur`: no cursor.
  - `{"t":"hint","text":"...","ms":10,"ml":6}`: the long form of the hint and its marked part. An empty text hides it. The page wraps a long form, so the short form is not sent.
  - `{"t":"status","text":"...","v":3,"tot":10}`: the status line. `tot` 0 hides it.
  - `{"t":"list","chosen":0,"first":0,"total":14,"start":5,"items":[{"name":"help","detail":"...","icon":"command","match":[0,1],"runs":[...]}]}`: the completion list. `chosen` -1 is no row. No items hides it.
- **Places are characters.** Each cursor, run, mark, match and `start` counts characters of the text that the page reads (the code points of `Array.from`), never bytes: the page decodes no UTF-8 offset. `dom_protocol.characters_before` counts each invalid sequence as one character, as the escape writes one `?` for it. The runs of a list item count the characters of its name and its detail together.
- **Classes, not colors.** A tone and a kind of code are names; the page colors them by CSS classes. A change from dark to light colors the whole scrollback again with no new line. `fg` is the one color that a process chose itself.
- **The text of a process never acts on the page.** Each character is decoded as UTF-8; a quote and a backslash are escaped, Tab is `\t`, and each C0 control, Delete, each C1 control and each invalid sequence becomes one `?`. The page reads each line with `JSON.parse` and writes each text with `textContent`, never as HTML.
- **A line that does not fit is not written.** The buffer of `dom_protocol.LINE_LIMIT` bytes holds the largest list (a host test writes it); a line past it is dropped whole and the renderer says so once, so the page never reads half an object.
- **The worker.** The page runs no kernel: `browser_machine_worker.js` runs the machine, sends the lines of COM2 in one message for each slice, and types the text that the page sends on COM2 ([browser_machine.md](browser_machine.md), "The page and its host"). The page keeps each check of a line, because the lines come from the system, and the worker passes them as they are.
- **The page.** The output is a list of lines, bounded at 4000, that follows the end only when the reader is at the end. The edit line has its runs and a caret, the hint line its marked parameter, the status a bar, and the list a popup at the column of the name; a click on a row sends the arrows and Tab that choose it. The keys go to COM2 as a VT100 terminal sends them; a paste sends its UTF-8. Control+C with a selection, and each key with Cmd or Alt, stay with the browser.

Refused: a VT100 grid emulator in the page, or a terminal library: the page would undo, cell by cell, what the records said, and selection and theme would be the problems of the grid. Refused too: the page that reads the ring itself; the root service gives a renderer COM2, the one device that the host of the browser machine plays.

## One key decoder

`serial_terminal` and `dom_terminal` read the keys of the same kind of terminal on the same port, through one driver and one decoder of `modus:terminal`: `serial_port.odin` opens the UART of COM2, bounds the wait for room in its transmit register, and gives an Escape alone after 20 ms by the clock of the system; `key_decoder.odin` turns the VT100 sequences and UTF-8 into `Key`. Refused: a copy of each in each renderer; two copies differ one day on a key.

## One intake

The three renderers read the ring through `terminal_records.renderer_intake_take` (`src/library/modus/terminal/renderer_intake.odin`): the checks of the terminal of the desktop, in one place. Status and Hint are steps too: the intake keeps their text and brings each marked part of a hint inside its form. `serial_terminal` and `grid_terminal` draw neither. A word that names no record is refused and counted; the text comes from the text region in two parts; runs of code are checked against their line; the rows of a list go through `List_Keeping`, which refuses an icon that names no `List_Icon` and a chosen row past the shown rows. A renderer draws from the step that the intake gives. Refused: one decoder of records in each renderer. The first two renderers had two copies, and one of them read a name length that a process chose as a negative index.

## The context of a renderer

`terminal_records.renderer_context_of` writes it, host-tested slot by slot: handle 0 is the device (the COM2 ports with no right, or the framebuffer with Read and Write), handle 2 the input ring of `grid_terminal`, and the terminal ring, the text region with Read only, the process that writes and the log at the places of a terminal. The values 7, 8 and 13 are the width, the height and the pixels of a line of the framebuffer; they never meet the seed (values 9 to 12). The text region is mapped read-only: the root service gives it with Read only.

## The console image

`modustool browser-machine console` writes `browser_machine_console.html` and `console.image` beside the files of the browser machine. The image holds `BROWSER_MACHINE_CONSOLE_MODULES` and their imports: the root service and its delegated services (`start_policy`, `log`, `wiring`, `devices`, `principals`, `disk_processes`), `console` with `c_compiler` and `assemble`, `dom_terminal`, and `storage` with `block` for the private store of the console. It holds no compositor, no drawing module, no input service, no font, no pointer theme and no other renderer of the terminal; the tool refuses an image that would hold one. Its start list and its rescue list are one row, the console, which needs no machine part. The tool writes `console.image.trust` beside the image: the hash of its system description, which the worker gives to the boot record. The page plays COM2 in its host and draws the lines of `dom_terminal` with its document ("Variant C: dom_terminal"); COM1 goes to the console of the developer of the browser.

Refused: the demonstration `disk` in the image. It is a window that imports the drawing module; `block` is the device service that the private store needs.

## The subtle points

- **Property 18.** `grid_terminal` draws characters with `graphics.character` and fills, not through the draw table. The root service gives the framebuffer to it alone, so no process draws beside it. A grid that draws through the draw table waits for a measure of its cost against the direct path (`ROADMAP.md`).
- **The pixel format.** `grid_terminal` writes the colors of `graphics` as the compositor writes them on the framebuffer of the firmware of the test machine (blue first). A framebuffer with red first shows red and blue swapped.
- **The list over the output.** On the serial port, a completion list above the edit line covers rows of the output; when it closes, these rows are cleared, and their text is not drawn again.

## State

Built and host-tested: the choice of the renderer and its holders (`role_policy`), the start of each renderer by the root service with its context, `serial_terminal` on COM2, `grid_terminal` with the framebuffer and the keys of the input ring, `dom_terminal` and its lines, the one driver and key decoder of COM2, the intake, the console image and its lists, COM2 in the host of the browser machine, and the console page that draws the lines of `dom_terminal`, with its machine in the worker of the browser machine and the trust of its description beside its image.

Left: a boot of the console image in Node that types a line on COM2 and reads its answer there; a boot volume of a console image and `modustool run --console` for QEMU (`ROADMAP.md`).
