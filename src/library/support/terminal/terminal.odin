// The terminal: how a program gives text to a terminal, and how the
// terminal gives keys to the program: records of a fixed size in a ring, as
// between any two programs, and only to the program that the terminal was
// given to.
//
// A program does not write a stream of bytes with commands hidden in it:
// no escape character and no escape sequence exists. A program sends
// records. Each record has a kind and typed fields: a run of text with its
// style, the end of a line, a status with a value and a total.
//
// The program and the terminal share two memory objects:
//   the terminal ring   One command record is one Record of this file.
//   the text region     The bytes of the text. The program writes them one
//                       after the other, and starts again at the first byte
//                       after the last. A record gives only the count of
//                       its bytes: a program cannot name another place.
//
// The terminal reads the records as fast as the program writes them. It
// draws at the rate of the screen, and it draws only the lines that the
// window shows: the display does not slow the program. When the ring is
// full, the program waits for the terminal.
//
// The input goes the other way, in the completion queue of the terminal
// ring: one record for each key that the input presses (Input). The
// program edits its line: the terminal does not know what a line of input
// is. The program shows the line with an Edit record; the terminal draws it
// after the last line, with a cursor.
//
// The root service makes the terminal ring and the text region, and starts
// the two programs. The terminal starts no program and holds three things:
// a surface, the two memory objects, and a handle that reads the state of
// the program. The program holds what its role gives, and no surface.
//
// The ring keeps at most RING_CAPACITY records that the terminal did not
// read, of RUN_LIMIT bytes at most: the program never writes over text
// that the terminal did not read.
//
// Who uses it: the console and each program that the root service starts
// with a terminal (`open`, `write`, `edit`, `key`), and the program
// `terminal` (the reading side: `List_Keeping`, `hint_form_choose`,
// `picture_wait_choose`). The parts:
//
// - `Kind`, `Input`, `Style`, `Tone`, `Flag`: the records of the ring.
// - `Terminal`, `open`, `write`, `line`, `status`, `edit`, `hint`, `key`,
//   `clear`: the side of the program.
// - `Code_Kind`, `Code_Run`, `Code_Runs` (`code_runs.odin`): the colors of a
//   line of code.
// - `List_Row`, `List_Shown`, `List_Keeping`: the completion list, as the
//   terminal keeps it.
// - `Picture_Wait`, `picture_wait_choose` (`picture_wait.odin`): the wait of
//   each turn of the terminal, and its due picture.
//
// ```odin
// terminal := terminal_records.open(ctx) or_return
// terminal_records.line(&terminal, {text = "ready: "}, {text = "3", style = {tone = u8(terminal_records.Tone.Number)}})
// ```
//
// See [terminal](term:terminal) and [terminal ring](term:terminal-ring).
package terminal_records

import "modus:contract/enum_word"
import "modus:contract/cut_mark"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:support/system"

// The roles of the context of a program that has a terminal, and of the
// terminal itself: slots of the one table of the context slots
// (src/library/support/system/grants.odin).
GRANT_RING :: system.GRANT_TERMINAL_RING // Memory: the terminal ring. The program writes its command queue.
GRANT_TEXT :: system.GRANT_TERMINAL_TEXT // Memory: the text region. The terminal has the right Read only.
GRANT_PROGRAM :: system.GRANT_TERMINAL_PROGRAM // For the terminal only: the program that writes, with the right Read.

// The values of the context of the terminal itself.
VALUE_NAME :: system.GRANT_VALUE_TERMINAL_NAME // 4 values: the name of the program. It is the title of the window.
VALUE_COLUMNS :: system.GRANT_VALUE_TERMINAL_COLUMNS // The columns of the window, at most COLUMNS_LIMIT.
VALUE_ROWS :: system.GRANT_VALUE_TERMINAL_ROWS // The rows of the window, at most ROWS_LIMIT.
VALUE_MEASURE :: system.GRANT_VALUE_TERMINAL_MEASURE // 1: the window shows the rates of the program.
// The handles that a terminal receives from its starter, the root service.
Terminal_Handles :: struct {
	display: system.Handle, // The ring to the compositor.
	ring:    system.Handle, // The terminal ring.
	text:    system.Handle, // The text region.
	writer:  system.Handle, // The program that writes in it.
	log:     system.Grant, // The log, with the rights that the starter chose.
}

// context_of writes the handles and the values of the context of a
// terminal through the checked writes of the context, so that a test reads
// the layout that the root service starts it with: the display ring, the
// terminal ring and the program with the rights that the terminal needs, the
// text region with Read only, the name of the program and the size of the
// window. A slot or a value that the caller wrote already is refused, and
// its refusal stays in the record.
context_of :: proc "contextless" (grants: ^system.Context_Grants, values: ^system.Context_Values, handles: Terminal_Handles, name: [4]u64, columns, rows: u64, measure: bool) {
	system.grant_put(grants, system.GRANT_DISPLAY, {handles.display, {.Read, .Write}})
	system.grant_put(grants, GRANT_RING, {handles.ring, {.Read, .Write}})
	system.grant_put(grants, GRANT_TEXT, {handles.text, {.Read}})
	system.grant_put(grants, GRANT_PROGRAM, {handles.writer, {.Read}})
	system.grant_put(grants, op.CONTEXT_LOG, handles.log)
	words := name
	system.values_put(values, VALUE_NAME, words[:])
	system.value_put(values, VALUE_COLUMNS, columns)
	system.value_put(values, VALUE_ROWS, rows)
	system.value_put(values, VALUE_MEASURE, u64(measure))
}

COLUMNS_LIMIT :: 104 // The most columns of a terminal window.
ROWS_LIMIT :: 32 // The most rows of a terminal window.

RING_CAPACITY :: 4096 // The records of each queue of the terminal ring.
TEXT_PAGES :: 1024 // 4 MiB. A power of two.
TEXT_SIZE :: TEXT_PAGES * system.PAGE_SIZE // The bytes of the text region.
RUN_LIMIT :: 256 // The bytes of the text of one record.
#assert(RING_CAPACITY * RUN_LIMIT <= TEXT_SIZE / 2)

// The kind of a command record.
//   Text    tag: the count of bytes, in the text region after the bytes of
//           the record before. values[0]: a Style.
//   Status  One line that the terminal keeps in view, with a bar. A new
//           status replaces the one before. tag: the count of bytes of its
//           text. values[0]: a Style. values[1]: the value. values[2]: the
//           total; 0 removes the status.
//   Clear   The terminal forgets all the lines.
//   Edit    The line that the program changes: the line of input of the
//           input, or a line that says what the program does now. The
//           terminal shows it after the last line. A new one replaces the
//           one before. tag: the count of bytes of its text. values[0]: a
//           Style. values[1]: the place of the cursor, in bytes from the
//           start of the text, or NO_CURSOR. No text and no cursor: the
//           terminal shows no such line.
//   Hint    One line under the edit line, in the dim color: what the
//           program says about the line (the signature of the call at the
//           cursor). It has a long form, and a short form for a terminal
//           that is too narrow for the long one (hint_form_choose); the
//           text is the long form, then the short form. The terminal keeps
//           a free row under the edit line at all times and draws the hint
//           over it: a hint that comes or goes does not move the text. A
//           new one replaces the one before; no text removes it. tag: the
//           count of bytes of the two forms. values[0]: a Style. values[1],
//           values[2]: the first byte and the count of bytes of the part of
//           the long form that the terminal marks. values[3]: the bytes of
//           the long form. values[4], values[5]: the marked part of the
//           short form, from its first byte.
//   List_Row One row of the next completion list. tag: the count of bytes
//           of its text: the name, then what the name is. values[0]: the
//           number of the row, below LIST_ROWS. values[1]: the bytes of the
//           name. values[2], values[3]: the places of the name that matched
//           what the input typed (bit n: byte n of the name; values[2]
//           holds bytes 0 to 63). values[4]: a List_Icon, what the name
//           is; the terminal refuses a row whose number names no List_Icon.
//   List    The completion list that the terminal shows over its text, at
//           the edit line: the rows that List_Row gave before. values[0]:
//           the count of rows, at most LIST_ROWS; 0 removes the list.
//           values[1]: the row that is chosen, or NO_CHOICE. values[2]: the
//           place of the first row in all the names of the program, and
//           values[3] their count: with more names than rows, the list
//           shows a scroll bar. values[4]: the byte of the edit line where
//           the name starts: the list starts at its column.
//   Code_Runs The runs of code of the next record of a target
//           (code_runs.odin): what each part of its text is, so that the
//           terminal colors it. tag: the count of bytes of the runs, 4 for
//           each run, at most CODE_RUN_LIMIT runs. values[0]: the target,
//           Kind.Edit or Kind.List_Row; another target is not kept.
//           values[1]: for List_Row, the number of the row. The next record
//           of the target takes the runs; a record of the target with no
//           Code_Runs before it is plain.
// The text of each record is UTF-8 (src/library/contract/text_encoding),
// and each count is a count of bytes. The library cuts a text after a whole
// character only. The terminal shows one cell for each character, and the
// replacement glyph for each invalid sequence and for each character that the font
// lacks: the text of these records comes from other programs.
Kind :: enum u32 {
	None     = 0, // Not a record: the terminal skips it.
	Text     = 1, // A run of text.
	Status   = 2, // The status line.
	Clear    = 3, // Forget all the lines.
	Edit     = 4, // The edit line.
	Hint     = 5, // The hint line.
	List_Row  = 6, // One row of the next completion list.
	List      = 7, // Show the completion list.
	Code_Runs = 8, // The runs of code of the next record of a target.
}

NO_CURSOR :: max(u64) // An Edit record with no cursor.
NO_CHOICE :: max(u64) // A List record with no chosen row.
LIST_ROWS :: 8 // The rows of a completion list.

// What a row of a completion list is: the terminal draws the kind icon of
// it before the name, as a row of the palette has one
// (docs/glossary/desktop.md, "Kind icon"). The program says what the name is; the terminal
// chooses the form and the color. None: the row has no icon, and a list
// with no icon in any row keeps no room for one.
List_Icon :: enum u8 {
	None         = 0, // No icon.
	Command      = 1, // A command of the program itself.
	Export       = 2, // An export of a module or of a service.
	Record       = 3, // A command that makes a record from its fields.
	Service      = 4, // A service that the program is connected to.
	Module       = 5, // A module of the boot image.
	Program      = 6, // A program that runs.
	Variable     = 7, // A variable of the program.
	History_Line = 8, // A line of the history.
}

// The kind of a completion record: what the terminal gives to the program.
//   Key     A key was pressed. tag: the code of the key
//           (display.KEY_*). values[0]: its character, or 0. values[1]:
//           the modifiers that were held (display.MODIFIER_*).
//           Control-R gives the character 'r' with MODIFIER_CONTROL.
//   List_First  The pointer moved the scroll bar of the completion list.
//           values[0]: the first row of the whole list that the scroll
//           bar asks for. The program owns the list: it moves its view
//           there and its choice into the view, and sends the rows
//           again (List_Row, List). A program that has no list, or that
//           reads only its keys (`key`), skips the record.
// The terminal keeps the keys Page Up and Page Down: they move its view.
// If the program does not read and the queue is full, the newest keys are
// lost: the terminal never waits for a program.
Input :: enum u32 {
	None       = 0, // Not a record: the program skips it.
	Key        = 1, // A key was pressed.
	List_First = 2, // The scroll bar of the completion list asks for a first row.
}

// One input record, as `input` gives it to the program.
Input_Record :: struct {
	kind:       Input, // Key or List_First.
	key:        Key, // Key: the key.
	list_first: int, // List_First: the first row of the whole list that the scroll bar asks for.
}

// One key, as `key` gives it to the program.
Key :: struct {
	code:      u32, // The code of the key (display.KEY_*).
	character: rune, // Its character as a code point, or 0. A program that keeps it writes its UTF-8.
	modifiers: u32, // The modifiers held (display.MODIFIER_*).
}

// What a run of text is. The terminal chooses the color of each tone.
Tone :: enum u8 {
	Default = 0, // Plain text.
	Dim     = 1, // Text of less weight: a unit, a note.
	Strong  = 2, // Text of more weight: a title.
	Good    = 3, // A success: a check that passed.
	Warning = 4, // Something to look at.
	Bad     = 5, // A failure.
	Accent  = 6, // A name that the reader looks for.
	Number  = 7, // A number.
}

// tone_of_byte is the border of the tone byte of a Style that another
// program wrote: the member, or false for a byte that names no tone. The
// terminal then draws the run in the color of plain text.
tone_of_byte :: proc "contextless" (value: u8) -> (tone: Tone, ok: bool) {
	return enum_word.member_of_word(Tone, u64(value))
}

// A flag of the style of a run.
Flag :: enum u8 {
	End_Line = 0, // The line ends after this run.
	Color    = 1, // The run has its own color: Style.color, not the color of its tone.
	Reverse  = 2, // The color fills the cells, and the text has the color of the background.
}

// The style of a run: values[0] of a record. The zero value is the default.
// The color of a run: Style.color with the flag Color; if not, the color of
// its value kind when it has one; if not, the color of its code kind when
// the kind has one; if not, the color of its tone. The terminal chooses
// each color but Style.color in the appearance in force when it draws, so
// a line written before a change of the appearance takes the new colors.
//
// The tone and the code kind are bytes, not members: the terminal reads a
// record that another program wrote, and takes each byte through its
// border (tone_of_byte, code_kind_of), so it never holds a member that the
// writer did not name.
//
// Example: `{tone = u8(Tone.Number)}` writes a number.
Style :: struct {
	tone:       u8, // What the run is: the byte of a Tone.
	flags:      bit_set[Flag;u8], // End_Line, Color, Reverse.
	code:       u8, // A Text record: what the run is in a line of code, the byte of a Code_Kind (code_runs.odin).
	value_kind: u8, // The value kind of the run (modus:contract/value_kinds), or 0: none.
	color:      u32, // Red, green, blue: 0xRRGGBB.
}
#assert(size_of(Style) == 8)

// A terminal, as the program that writes sees it.
Terminal :: struct {
	ring:    ring.Ring, // The terminal ring: this program writes its commands.
	text:    []u8, // The text region.
	written: u64, // The bytes that the program wrote since the start.
}

// open gives the terminal of this program. false: the program that started
// this one gave no terminal (the record No_Grant, unit Terminal), or a
// kernel operation failed (its record).
// error: the record of a failure, if the caller gives one:
// system.wrapper_error_text(writer, &error, "terminal.open", {"ctx"}).
open :: proc "contextless" (ctx: ^system.Context, error: ^errors.Error_Record = nil) -> (terminal: Terminal, ok: bool) {
	if ctx.handles[GRANT_RING] == 0 || ctx.handles[GRANT_TEXT] == 0 {
		errors.fail(error, 0, .No_Grant, .Terminal)
		return {}, false
	}
	size, size_status := system.memory_size(ctx.handles[GRANT_TEXT], error)
	if size_status != .Ok {
		return {}, false // memory_size wrote the record of the kernel.
	}
	if size != TEXT_PAGES {
		errors.fail(error, 0, .Bad_Value, .Pages, 1, i64(size), TEXT_PAGES) // The text region of the grant has another size.
		return {}, false
	}
	status: system.Status
	if terminal.ring, status = system.ring_open(ctx.handles[GRANT_RING], error); status != .Ok {
		return {}, false
	}
	address: rawptr
	if address, status = system.memory_map(ctx.handles[GRANT_TEXT], error = error); status != .Ok {
		return {}, false
	}
	terminal.text = ([^]u8)(address)[:TEXT_SIZE]
	return terminal, true
}

// A run of text and its style.
Run :: struct {
	text:  string, // The bytes; a run longer than RUN_LIMIT is several records.
	style: Style, // Its style.
}

// write gives runs of text to the terminal. The terminal has all of them
// when write returns: the library keeps nothing. A text of more than
// RUN_LIMIT bytes is several records. If the ring is full, the thread
// waits. One call with several runs costs less than one call for each run:
// the reader is told one time.
write :: proc "contextless" (terminal: ^Terminal, runs: ..Run) {
	for run in runs {
		text := run.text
		for {
			part := text[:record_part(text, RUN_LIMIT)]
			text = text[len(part):]
			style := run.style
			if len(text) != 0 {
				style.flags -= {.End_Line}
			}
			append(terminal, part)
			push(terminal, ring.Record{kind = u32(Kind.Text), tag = u32(len(part)), values = {0 = transmute(u64)style}})
			if len(text) == 0 {
				break
			}
		}
	}
	system.wake_reader(&terminal.ring.commands)
}

// line gives runs of text, and ends the line after the last run.
line :: proc "contextless" (terminal: ^Terminal, runs: ..Run) {
	if len(runs) == 0 {
		write(terminal, Run{style = {flags = {.End_Line}}})
		return
	}
	last := runs[len(runs) - 1]
	last.style.flags += {.End_Line}
	// The runs before the last, then the last with the end of the line.
	for run in runs[:len(runs) - 1] {
		text := run.text
		for len(text) != 0 {
			part := text[:record_part(text, RUN_LIMIT)]
			text = text[len(part):]
			style := run.style
			style.flags -= {.End_Line}
			append(terminal, part)
			push(terminal, ring.Record{kind = u32(Kind.Text), tag = u32(len(part)), values = {0 = transmute(u64)style}})
		}
	}
	write(terminal, last)
}

// status sets the status of the terminal: a text, and a value of a total.
// A total of 0 removes the status.
status :: proc "contextless" (terminal: ^Terminal, text: string, value, total: u64, style: Style = {}) {
	marked: [RUN_LIMIT]u8
	part := record_text(text, &marked)
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Status), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = value, 2 = total}})
	system.wake_reader(&terminal.ring.commands)
}

// edit sets the line that the program changes, with the place of its
// cursor. edit(terminal, "") removes the line.
edit :: proc "contextless" (terminal: ^Terminal, text: string, cursor: u64 = NO_CURSOR, style: Style = {}) {
	marked: [RUN_LIMIT]u8
	part := record_text(text, &marked)
	append(terminal, part)
	push(terminal, ring.Record{kind = u32(Kind.Edit), tag = u32(len(part)), values = {0 = transmute(u64)style, 1 = cursor}})
	system.wake_reader(&terminal.ring.commands)
}

// A form of a hint line, and the part of it that the terminal marks: the
// first byte and the count of bytes.
Hint_Form :: enum u8 {
	Long  = 0, // The long form: the whole signature.
	Short = 1, // The short form, for a narrow terminal.
}

// One form of a hint: its text and its marked part.
Hint_Text :: struct {
	text:         string, // The text of the form.
	marked_start: int, // The first byte that the terminal marks.
	marked_count: int, // The bytes that it marks.
}

// hint sets the line under the edit line: a long form, a short form ("" if
// the long form is the only one), and a style. A long form of 0 bytes
// removes it. The two forms together are cut to RUN_LIMIT bytes, the long
// form first.
hint :: proc "contextless" (terminal: ^Terminal, long: Hint_Text, short: Hint_Text, style: Style) {
	long_part := long.text[:record_part(long.text, RUN_LIMIT)]
	short_part := short.text[:record_part(short.text, RUN_LIMIT - len(long_part))]
	append(terminal, long_part)
	append(terminal, short_part)
	push(terminal, ring.Record{kind = u32(Kind.Hint), tag = u32(len(long_part) + len(short_part)), values = {0 = transmute(u64)style, 1 = u64(max(long.marked_start, 0)), 2 = u64(max(long.marked_count, 0)), 3 = u64(len(long_part)), 4 = u64(max(short.marked_start, 0)), 5 = u64(max(short.marked_count, 0))}})
	system.wake_reader(&terminal.ring.commands)
}

// hint_form_choose chooses the form of a hint line for a width of columns
// cells, from the cells of each form (one for each character): the long
// form when it fits; if not, the short form when the program gave one; if
// not, the long form. shown is the cells of the form that the row shows:
// the form, cut to the columns.
hint_form_choose :: proc "contextless" (long_count, short_count, columns: int) -> (form: Hint_Form, shown: int) {
	room := max(columns, 0)
	if long_count <= room || short_count <= 0 {
		return .Long, clamp(long_count, 0, room)
	}
	return .Short, min(short_count, room)
}

// list_row gives one row of the next completion list: a name, what it is,
// the icon of its kind,
// and the places of the name that matched. A name and its text are cut to
// RUN_LIMIT bytes together, the name first.
list_row :: proc "contextless" (terminal: ^Terminal, row: int, name: string, about: string, matched: [2]u64, icon := List_Icon.None) {
	name_part := name[:record_part(name, RUN_LIMIT)]
	about_part := about[:record_part(about, RUN_LIMIT - len(name_part))]
	append(terminal, name_part)
	append(terminal, about_part)
	push(terminal, ring.Record{kind = u32(Kind.List_Row), tag = u32(len(name_part) + len(about_part)), values = {0 = u64(row), 1 = u64(len(name_part)), 2 = matched[0], 3 = matched[1], 4 = u64(icon)}})
}

// list_show shows the rows that list_row gave: row_count rows, the chosen
// one (NO_CHOICE: none), the place of the first row in all the names and
// their count, and the byte of the edit line where the name starts.
// list_show(terminal, 0, ...) removes the list.
list_show :: proc "contextless" (terminal: ^Terminal, row_count: int, chosen: u64, first: int, total: int, anchor: int) {
	push(terminal, ring.Record{kind = u32(Kind.List), values = {0 = u64(clamp(row_count, 0, LIST_ROWS)), 1 = chosen, 2 = u64(max(first, 0)), 3 = u64(max(total, 0)), 4 = u64(max(anchor, 0))}})
	system.wake_reader(&terminal.ring.commands)
}

// What a terminal keeps of the completion list of its program: the rows
// that List_Row records gave, and the list that the last List record shows.
// The values come from the program: each one is brought inside its array
// before it is kept. The rows given before a List go to that List only: a
// List with no new rows shows empty rows, never the rows of a list before,
// which can come from another program of the same terminal.
List_Row :: struct {
	text:        [RUN_LIMIT]u8, // The name, then what the name is.
	length:      int, // The bytes of `text` in use.
	name_length: int, // The bytes of the name, at the start of `text`.
	matched:     [2]u64, // Bit n: byte n of the name matched what the input typed.
	icon:        List_Icon, // What the name is: the kind icon before it. None: no icon.
	code:        Code_Runs, // The runs of code of the row, checked against its text. None: the row is plain.
}

// The completion list that the terminal shows now.
List_Shown :: struct {
	rows:      [LIST_ROWS]List_Row, // The rows.
	row_count: int, // The rows in use. 0: no list.
	chosen:    int, // -1: no row is chosen.
	first:     int, // The place of the first row in all the names.
	total:     int, // All the names: more than row_count shows a scroll bar.
	anchor:    int, // The byte of the edit line where the name starts.
}

// What the terminal keeps of the completion lists: the rows of the next
// list, and the list that it shows.
List_Keeping :: struct {
	next:         [LIST_ROWS]List_Row, // The rows given since the last List.
	pending:      [LIST_ROWS]Code_Runs, // The runs that the next List_Row of each row takes.
	shown:        List_Shown, // The list on the screen.
	runs_refused: u64, // The lists of runs that were refused: each one left its row plain.
	rows_refused: u64, // The List_Row records whose icon named no List_Icon: none of them was kept.
}

// list_keep_row keeps the row of a List_Row record: values[0] its number,
// values[1] the bytes of its name, values[2] and values[3] the matched
// places, values[4] its icon. The text is in two parts (the text region
// starts again at its first byte). A number past the rows is not kept. An
// icon that names no List_Icon is refused: the row is not kept, its runs
// are dropped with it, so they never reach a row of a later list, and the
// refusal is counted. The row takes the runs of code that came for its
// number since its last List_Row, when they fit its text; if not, it is
// plain and the refusal is counted.
list_keep_row :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64, first, second: []u8) {
	if values[0] >= LIST_ROWS {
		return
	}
	icon, icon_ok := enum_word.member_of_word(List_Icon, values[4])
	if !icon_ok {
		keeping.pending[values[0]] = {}
		keeping.rows_refused += 1
		return
	}
	row := &keeping.next[values[0]]
	row.length = copy(row.text[:], first)
	row.length += copy(row.text[row.length:], second)
	row.name_length = int(min(values[1], u64(row.length)))
	row.matched = {values[2], values[3]}
	row.icon = icon
	row.code = keeping.pending[values[0]]
	keeping.pending[values[0]] = {}
	if row.code.count != 0 && !code_runs_check(&row.code, row.length) {
		keeping.runs_refused += 1
	}
}

// list_keep_code_runs keeps the runs of a Code_Runs record for a list row:
// values[1] the number of the row. A number past the rows, or bytes that
// are not a whole count of runs, are not kept.
list_keep_code_runs :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64, first, second: []u8) {
	if values[1] >= LIST_ROWS {
		keeping.runs_refused += 1
		return
	}
	runs, ok := code_runs_read(first, second)
	if !ok {
		keeping.runs_refused += 1
	}
	keeping.pending[values[1]] = runs
}

// list_keep_show shows the rows given since the last List, with the values
// of a List record, then forgets them.
list_keep_show :: proc "contextless" (keeping: ^List_Keeping, values: [7]u64) {
	shown := &keeping.shown
	shown.rows = keeping.next
	keeping.next = {}
	shown.row_count = int(min(values[0], LIST_ROWS))
	shown.chosen = values[1] < u64(shown.row_count) ? int(values[1]) : -1
	shown.total = int(min(max(values[3], u64(shown.row_count)), 1 << 20))
	shown.first = int(min(values[2], u64(shown.total - shown.row_count)))
	shown.anchor = int(min(values[4], RUN_LIMIT))
}

// list_keep_forget forgets the list and the rows given: the program of the
// terminal stopped.
list_keep_forget :: proc "contextless" (keeping: ^List_Keeping) {
	refused := keeping.runs_refused
	keeping^ = {}
	keeping.shown.chosen = -1
	keeping.runs_refused = refused
}

// record_text gives the text of a record that holds one line as it is:
// the text when it has at most RUN_LIMIT bytes, else its start with the cut
// mark and the count of the missing bytes, written in buffer. The terminal
// draws the line whole, so a cut there is not seen without the mark.
record_text :: proc "contextless" (text: string, buffer: ^[RUN_LIMIT]u8) -> string {
	if len(text) <= RUN_LIMIT {
		return text
	}
	count := copy(buffer[:], text)
	marked, _, _ := cut_mark.apply(buffer[:], count, len(text) - count)
	return string(buffer[:marked])
}

// record_part gives the bytes of the start of a text that fit in room
// bytes: the whole text when it fits, else its start cut after a whole
// character. With a room of RUN_LIMIT bytes it is never 0 for a text that
// is not empty, so a loop over the records of a long text moves on.
@(private)
record_part :: proc "contextless" (text: string, room: int) -> int {
	if len(text) <= room {
		return len(text)
	}
	if room <= 0 {
		return 0
	}
	// A character has at most 4 bytes, so a record of RUN_LIMIT bytes always
	// takes one; a smaller room that ends inside the first character takes
	// none, and that character goes in the next record.
	return text_encoding.complete_characters(transmute([]u8)text[:room])
}

// key gives the next key that was pressed. false: no key waits.
// A program waits for a key with system.wait_records on
// terminal.ring.completions.
key :: proc "contextless" (terminal: ^Terminal) -> (pressed: Key, ok: bool) {
	for {
		record := system.receive(&terminal.ring.completions) or_return
		given, given_ok := input_of_record(record)
		if !given_ok {
			input_refusal_log(record)
			continue
		}
		if given.kind == .Key {
			return given.key, true
		}
	}
}

// key_character_of gives the character of a key record: its code point,
// or 0 for a value past the last code point. A key with a control
// character (Enter, Tab, Backspace) keeps it.
key_character_of :: proc "contextless" (value: u64) -> rune {
	return value <= text_encoding.CODE_POINT_LAST ? rune(value) : 0
}

// input gives the next input record: a key, or what the pointer asked of
// the scroll bar of the completion list. false: no record waits. A program
// with a completion list reads its input here; a program that reads only
// keys uses `key`. A record that input_of_record refuses costs one line of
// the log, and the next record is read.
input :: proc "contextless" (terminal: ^Terminal) -> (given: Input_Record, ok: bool) {
	for {
		record := system.receive(&terminal.ring.completions) or_return
		read, read_ok := input_of_record(record)
		if read_ok {
			return read, true
		}
		input_refusal_log(record)
	}
}

// kind_of_ring_word is the border of the kind of a record of the terminal
// ring, which the program of the terminal writes: the kind, or false for a
// word that names no record, None included. The terminal counts a refusal.
// It reads and changes no state.
kind_of_ring_word :: proc "contextless" (word: u32) -> (kind: Kind, ok: bool) {
	member := enum_word.member_of_word(Kind, u64(word)) or_return
	return member, member != .None
}

// input_of_record is the border of an input record of the terminal: the
// record, or false for a kind that names no input, None included. It reads
// and changes no state, so a host test gives it each refused kind.
input_of_record :: proc "contextless" (record: ring.Record) -> (given: Input_Record, ok: bool) {
	kind := enum_word.member_of_word(Input, u64(record.kind)) or_return
	switch kind {
	case .None:
		return {}, false
	case .Key:
		return {kind = .Key, key = {code = record.tag, character = key_character_of(record.values[0]), modifiers = u32(record.values[1])}}, true
	case .List_First:
		// The number is the number of another program: the reader
		// cuts it to its own list.
		return {kind = .List_First, list_first = int(min(record.values[0], u64(max(i32))))}, true
	}
	return {}, false
}

// input_refusal_log writes the line of an input record that names no
// input. The log counts the lines of each second of the budget, so a
// terminal that writes such records with no end costs its reader no wait.
@(private)
input_refusal_log :: proc "contextless" (record: ring.Record) {
	system.log_in("programs", .Warning, "terminal: the terminal sent an input record of the kind ", u64(record.kind), ", which names no input: it is refused")
}

// clear tells the terminal to forget all the lines.
clear :: proc "contextless" (terminal: ^Terminal) {
	push(terminal, ring.Record{kind = u32(Kind.Clear)})
	system.wake_reader(&terminal.ring.commands)
}

// append writes bytes in the text region after the bytes written before,
// and starts again at its first byte after its last.
@(private)
append :: proc "contextless" (terminal: ^Terminal, text: string) {
	place := int(terminal.written % TEXT_SIZE)
	first := min(len(text), TEXT_SIZE - place)
	copy(terminal.text[place:], text[:first])
	copy(terminal.text, text[first:])
	terminal.written += u64(len(text))
}

// push writes a record with no wake. If the ring is full, the thread
// waits: wait_end wakes the reader first.
@(private)
push :: proc "contextless" (terminal: ^Terminal, record: ring.Record) {
	queue := &terminal.ring.commands
	for !ring.push(queue, record) {
		wait: system.Wait
		system.wait_room(&wait, queue)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}
