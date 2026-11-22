# Desktop-free console renderers

The console (`src/modules/system/console`) writes only typed records onto the `modus:terminal` ring: styled text runs, Lex `Code_Runs`, cursor position, status bar, hints, and the interactive `List_Keeping` completion popup. It draws no pixels. A modus image with no desktop keeps the console experience — 24-bit colors, syntax highlighting, completion popups, `Ctrl+R` history search, tables and `log.follow` — by swapping only the process at the other end of the ring: the holder of the role Terminal (property 23).

## Which renderer a machine runs

The root service chooses the renderer once, before the start policy, from the modules of the signed boot image and the screen of the machine (`role_policy.console_renderer_choose`, host-tested on each of the 16 cases):

| The image holds | The machine | The holder of Terminal | The holder of Display |
|---|---|---|---|
| the compositor | any | `terminal` | `compositor` |
| no compositor, `grid_terminal` | a screen | `grid_terminal` | `grid_terminal` |
| no compositor, `serial_terminal` | any other case | `serial_terminal` | none |
| none of the three | any | `terminal` | `compositor` |

- The compositor wins. A desktop image behaves as before, whatever else it holds: the choice changes no holder, no start and no window.
- The choice writes the defaults of the image only. A plan of principal 0 still overrides a holder, as for each other role.
- A console image has no window server. `start_view_give` starts a process with no terminal with no window, and a disk process gets none either. A start of `display` is refused: with `serial_terminal` the role Display has no holder, and with `grid_terminal` the procedure of the compositor refuses a holder that is not a compositor.
- `serial_terminal` needs no screen: on a machine with no framebuffer, the console starts with it. With `grid_terminal` or the desktop, a process with the grant Terminal still needs a screen.
- The root service writes one line for a console image: "root: no compositor in the boot image: the console writes to the second serial port through serial_terminal", or the line of the grid.

## Variant A: serial_terminal

ANSI 24-bit TrueColor over COM2. `src/library/internal/serial_terminal/ansi_terminal` and `src/modules/system/serial_terminal` translate the typed records into 24-bit TrueColor ANSI escape sequences, and decode VT100 and UTF-8 input bytes back into `terminal_records.Key`.

- **COM2, never COM1.** COM1 (`0x3F8`) is the log of the kernel, which the kernel writes itself and the tools read line by line. The renderer drives COM2 (`0x2F8` to `0x2FF`, `terminal_records.SERIAL_PORT_FIRST`), whose ports the root service gives it as a Ports handle: the kernel then opens these 8 ports in its I/O permission map, and no other. Text of a terminal never mixes with lines of the log.
- **The layout.** The last row is the edit line. The rows above it are the output, a VT100 scroll region (`DECSTBM`) that scrolls by itself. The output keeps its own cursor, saved with `ESC 7` and restored with `ESC 8`, so the edit line and the completion list never move where the next output goes. A completion list goes under the edit line when it fits, and above it if not.
- **The text of a process never acts on the terminal of the reader.** The renderer decodes the text as UTF-8. Each C0 control but Tab (ESC, CR, LF, BS and BEL included), Delete, each C1 control (U+0080 to U+009F, the 8-bit CSI `0xC2 0x9B` among them) and each invalid sequence (a raw byte `0x80` to `0xFF` included) becomes one `?`. Each other character passes whole, and a completion row counts characters, not bytes.
- **One renderer at a time.** The root service starts a renderer only when the holder of Terminal is the module that the image chose, and when no renderer runs (`role_policy.console_renderer_start_check`): a plan cannot give COM2 or the framebuffer to another module, and two processes never hold one device. A renderer stops with its process, and its place is forgotten when it stops.
- **The decoder refuses** a CSI sequence longer than 16 bytes, a control byte inside a sequence, and overlong or surrogate UTF-8 (the replacement character). An ESC inside a sequence starts the next one, so a key typed before the end of the last sequence is kept. An Escape with no byte after it for 20 ms by the clock of the system is the key Escape, so a sequence whose bytes come slowly stays one key. A UART that keeps its transmit register full past a bounded count of reads is taken as absent: the renderer writes no more.
- **No UART.** A line status that reads all ones is no UART: the renderer writes one line and reads the ring and drops it, so the console never waits on a full ring.

## Variant B: grid_terminal

A monospace grid on the framebuffer. `src/library/internal/grid_terminal/grid_renderer` and `src/modules/system/grid_terminal` render the same records onto the framebuffer with `graphics.character` (Spleen 8x16) and dirty rows.

- **The one screen writer.** The root service gives `grid_terminal` the framebuffer of the firmware and the input ring of the input service, which the compositor reads in a desktop image. The boot display of the root service draws nothing after `grid_terminal` starts; a failure of the start stops it and takes the screen back for the boot display.
- **The keys.** `grid_renderer.key_of_input_record` is the border of the input ring: a press gives its key; a release, a pointer record, a word that names no input, a code past `KEY_EXTENDED | 0xFF`, a character that is no code point and a modifier bit that names no modifier give none.
- **The output** wraps at the last column and scrolls the rows above the edit line, one cell for each UTF-8 character, with the replacement character for an invalid sequence.
- **A completion list that moves** marks the rows under its last box dirty, so no part of an old box stays on the screen. The box is drawn again only when the list changed, when it moved, or when a row under it was drawn again.
- **The edit line** takes one cell for each UTF-8 character, and its cursor is placed by characters, not bytes.
- **No periodic wake.** The grid has no blinking cursor: it waits on the terminal ring and the input ring with no deadline.

## One intake

Both renderers read the ring through `terminal_records.renderer_intake_take` (`src/library/modus/terminal/renderer_intake.odin`): the checks of the terminal of the desktop, in one place. A word that names no record is refused and counted; the text comes from the text region in two parts; runs of code are checked against their line; the rows of a list go through `List_Keeping`, which refuses an icon that names no `List_Icon` and a chosen row past the shown rows. A renderer draws from the step that the intake gives. Refused: one decoder of records in each renderer. The two renderers had two copies, and one of them read a name length that a process chose as a negative index.

## The context of a renderer

`terminal_records.renderer_context_of` writes it, host-tested slot by slot: handle 0 is the device (the COM2 ports with no right, or the framebuffer with Read and Write), handle 2 the input ring of `grid_terminal`, and the terminal ring, the text region with Read only, the process that writes and the log at the places of a terminal. The values 7, 8 and 13 are the width, the height and the pixels of a line of the framebuffer; they never meet the seed (values 9 to 12). The text region is mapped read-only: the root service gives it with Read only.

## The console image

`modustool browser-machine console` writes `browser_machine_console.html` and `console.image` beside the files of the browser machine. The image holds `BROWSER_MACHINE_CONSOLE_MODULES` and their imports: the root service and its delegated services (`start_policy`, `log`, `wiring`, `devices`, `principals`, `disk_processes`), `console` with `c_compiler` and `assemble`, `serial_terminal`, and `storage` with `block` for the private store of the console. It holds no compositor, no drawing module, no input service, no font and no pointer theme; the tool refuses an image that would hold one. Its start list and its rescue list are one row, the console, which needs no machine part. The page plays COM2 in its host and draws a VT100 screen from its bytes; COM1 goes to the console of the developer of the browser.

Refused: the demonstration `disk` in the image. It is a window that imports the drawing module; `block` is the device service that the private store needs.

## The subtle points

- **Property 18.** `grid_terminal` draws characters with `graphics.character` and fills, not through the draw table. It is the holder of Display in a console image, so no process draws beside it. A grid that draws through the draw table waits for a measure of its cost against the direct path.
- **The pixel format.** `grid_terminal` writes the colors of `graphics` as the compositor writes them on the framebuffer of the firmware of the test machine (blue first). A framebuffer with red first shows red and blue swapped.
- **The list over the output.** On the serial port, a completion list above the edit line covers rows of the output; when it closes, these rows are cleared, and their text is not drawn again.

## State

Built and host-tested: the choice of the renderer and its holders (`role_policy`), the start of each renderer by the root service with its context, `serial_terminal` on COM2, `grid_terminal` with the framebuffer and the keys of the input ring, the intake, the console image and its lists, and COM2 in the host of the browser machine.

Left: a boot of the console image in Node that types a line on COM2 and reads its answer there; a boot volume of a console image and `modustool run --console` for QEMU (`ROADMAP.md`).
