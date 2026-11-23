package terminal_records

// The runs of code of a row: what each part of a line of code is, so that
// the terminal colors it (docs/CONSOLE.md, section 7). The process sends
// kinds, not colors: the terminal maps each kind to a class of the colors
// of code of the system (src/library/modus/graphics/code_colors.odin), so one table
// changes the colors of every terminal.
//
// Two forms carry kinds:
//   - a Text record: Style.code, one kind for the whole run of text: the
//     lines that the terminal keeps have runs already;
//   - a Code_Runs record: the runs of the next Edit record, or of the next
//     List_Row record of one row: a row that the terminal keeps whole. An
//     edit line takes the runs of each Code_Runs record before it, so a
//     line longer than one record keeps its colors.
// A run gives a color, never text: a run that is refused, or a row with
// more runs than CODE_RUN_LIMIT, leaves the text whole and plain.

import "modus:contract/enum_word"
import "modus:contract/ring"
import "modus:graphics"

// What a run of code is.
Code_Kind :: enum u8 {
	None            = 0, // No kind: the color of the style of the text.
	Function        = 1, // The name of a command or of an export: in a call, or at the start of its signature.
	Module          = 2, // The name of a module or of a service: before the dot of its export, or alone.
	Type            = 3, // Integer, Text, Table, Bytes, Handle, a record, and what a type holds in its parentheses.
	Parameter       = 4, // The name of a parameter in a signature, before its ':'.
	Variable        = 5, // The name of a variable of the console, also before '=' and before '.field'.
	Number          = 6, // A number.
	Text            = 7, // A text in double quotes, with its quotes.
	Text_Unfinished = 8, // A text with no end quote yet: it is still being typed.
	Operator        = 9, // An operator or punctuation: + - * / % = ( ) , : . { }
	Arrow           = 10, // '->' before the result of a signature.
	Words           = 11, // The words of a row of a list that are not code: "export of", "command", "3 lines ago".
	Unknown         = 12, // A name that is no command, module or variable, or a byte that the language does not take.
}

// One run: start and length in bytes of the text of its row. The start is
// two bytes, as an edit line has up to EDIT_TEXT_LIMIT bytes, more than
// one record; a part of one kind that is longer than 255 bytes is two
// runs. The kind is the byte of a Code_Kind, not the enum: the runs come
// from another process, and a reader takes the byte through code_kind_of,
// which refuses a byte that names no kind.
Code_Run :: struct #packed {
	start:  u16, // The first byte of the run in the text of its row.
	length: u8, // The bytes of the run.
	kind:   u8, // What the run is: a Code_Kind.
}
#assert(size_of(Code_Run) == 4)
#assert(EDIT_TEXT_LIMIT <= int(max(u16)))

// The runs of one Code_Runs record: the bytes of one record of the text
// region.
CODE_RUN_LIMIT :: RUN_LIMIT / size_of(Code_Run)

// The runs of an edit line at most: the runs of 16 Code_Runs records. A
// line with more parts keeps its first runs, and its text after them is
// plain.
EDIT_CODE_RUN_LIMIT :: 16 * CODE_RUN_LIMIT

// The runs of one row of the list.
Code_Runs :: struct {
	runs:  [CODE_RUN_LIMIT]Code_Run, // In the order of their bytes.
	count: int, // The runs in use.
}

// The runs of an edit line: the runs of each Code_Runs record before its
// Edit record, in order.
Edit_Code_Runs :: struct {
	runs:  [EDIT_CODE_RUN_LIMIT]Code_Run, // In the order of their bytes.
	count: int, // The runs in use.
}

// The class of the colors of code of each kind. Parameter, Module and
// Variable have the color of the text around them, as the names of the
// parameters on the site; an unfinished text has the color of a text, so
// that a text does not change its color at each key; an unknown name is
// quiet, not red: the error comes when the line runs.
@(rodata)
code_kind_classes := [Code_Kind]graphics.Code_Class {
	.None            = .None,
	.Function        = .Name,
	.Module          = .None,
	.Type            = .Type,
	.Parameter       = .None,
	.Variable        = .None,
	.Number          = .Literal,
	.Text            = .Literal,
	.Text_Unfinished = .Literal,
	.Operator        = .Punctuation,
	.Arrow           = .Punctuation,
	.Words           = .Comment,
	.Unknown         = .Comment,
}

// code_kind_of is the border of the kind of a byte that a process wrote:
// the member, or false for a byte that names none.
code_kind_of :: proc "contextless" (value: u8) -> (kind: Code_Kind, ok: bool) {
	return enum_word.member_of_word(Code_Kind, u64(value))
}

// code_kind_color gives the color of a kind on a dark surface, or plain
// when the kind has no class of its own.
code_kind_color :: proc "contextless" (kind: Code_Kind, plain: graphics.Color) -> graphics.Color {
	class := code_kind_classes[kind]
	return class == .None ? plain : graphics.code_class_color(class, graphics.appearance)
}

// code_runs_send gives the runs of the next record of a target: Kind.Edit,
// or Kind.List_Row with the number of its row. The process sends it just
// before that record. No runs: nothing is sent, and the record is plain.
// The runs of an edit line go in as many records as they need, up to
// EDIT_CODE_RUN_LIMIT; a row of the list takes CODE_RUN_LIMIT runs.
code_runs_send :: proc "contextless" (terminal: ^Terminal, target: Kind, row: int, runs: []Code_Run) {
	rest := runs[:min(len(runs), target == .Edit ? EDIT_CODE_RUN_LIMIT : CODE_RUN_LIMIT)]
	for len(rest) > 0 {
		count := min(len(rest), CODE_RUN_LIMIT)
		append(terminal, string(([^]u8)(raw_data(rest))[:count * size_of(Code_Run)]))
		push(terminal, ring.Record{kind = u32(Kind.Code_Runs), tag = u32(count * size_of(Code_Run)), values = {0 = u64(target), 1 = u64(max(row, 0))}})
		rest = rest[count:]
	}
}

// code_runs_read copies the runs of a Code_Runs record from its two parts
// of the text region. A count of bytes that is not a whole count of runs
// gives no runs, and false.
code_runs_read :: proc "contextless" (first, second: []u8) -> (read: Code_Runs, ok: bool) {
	size := len(first) + len(second)
	if size % size_of(Code_Run) != 0 || size > CODE_RUN_LIMIT * size_of(Code_Run) {
		return {}, false
	}
	bytes := ([^]u8)(&read.runs)[:CODE_RUN_LIMIT * size_of(Code_Run)]
	copied := copy(bytes, first)
	copied += copy(bytes[copied:], second)
	read.count = copied / size_of(Code_Run)
	return read, true
}

// edit_code_runs_add adds the runs of a Code_Runs record to the runs of the
// next edit line. Bytes that are not a whole count of runs, or runs past
// EDIT_CODE_RUN_LIMIT, give false: the runs that came before stay, and
// the check at the Edit record refuses nothing that it did not see.
edit_code_runs_add :: proc "contextless" (pending: ^Edit_Code_Runs, first, second: []u8) -> bool {
	read, ok := code_runs_read(first, second)
	if !ok {
		return false
	}
	pending.count = clamp(pending.count, 0, EDIT_CODE_RUN_LIMIT)
	kept := copy(pending.runs[pending.count:], read.runs[:read.count])
	pending.count += kept
	return kept == read.count
}

// code_runs_check keeps the runs of a row of length bytes when each run is
// inside the row, after the run before it, with at least one byte and a
// kind that exists. One run that is not: the row has no runs, and false.
// The text is not changed in either case. Runs is a Code_Runs or an
// Edit_Code_Runs.
code_runs_check :: proc "contextless" (runs: ^$Runs, length: int) -> bool {
	count := clamp(runs.count, 0, len(runs.runs))
	end := 0
	for run in runs.runs[:count] {
		start := int(run.start)
		kind, kind_ok := code_kind_of(run.kind)
		if run.length == 0 || start < end || start + int(run.length) > length || !kind_ok || kind == .None {
			runs.count = 0
			return false
		}
		end = start + int(run.length)
	}
	runs.count = count
	return true
}

// code_runs_kind_at gives the kind of the byte place of a row, from the
// place of the run that covered the byte before (a cursor that a loop over
// the bytes in order keeps): each byte costs one step at most. The check of
// the runs refused each byte of no kind already; the border reads the byte
// again, and a byte that names no kind gives no color of its own.
code_runs_kind_at :: proc "contextless" (runs: ^$Runs, place: int, cursor: ^int) -> Code_Kind {
	count := clamp(runs.count, 0, len(runs.runs))
	for cursor^ < count && int(runs.runs[cursor^].start) + int(runs.runs[cursor^].length) <= place {
		cursor^ += 1
	}
	if cursor^ < count && int(runs.runs[cursor^].start) <= place {
		if kind, ok := code_kind_of(runs.runs[cursor^].kind); ok {
			return kind
		}
	}
	return .None
}
