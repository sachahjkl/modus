// The start list, the machine parts page, and the names of the two lists of
// the boot image: what the root service writes for a start policy, and
// what the default start policy reads (src/md/features/start_policy.md).
//
// **The start list** is a resource of the boot image: a header, then rows
// of a fixed size, read in their order. The tool writes it from its table
// of start lists and refuses a list that `list_read` refuses, so a released
// image holds two lists that this border takes. `list_read` is the one
// place where a word of a row becomes its member: it refuses the whole list
// at the first word that names no member.
//
// **The wiring rows** follow the start rows: each one joins a record output
// of a start row to a record input of an earlier start row, and the start
// policy applies it at the start of its writer row
// (src/md/features/module_outputs.md, "The wiring rows of a start list").
// A row is an output.Wiring that names its reader by its start row in place
// of a lent handle: the same record that the start policy gives the root
// service, and the same border, output.wiring_row_check.
//
// **The machine parts page** is one page that the root service writes once,
// before the start policy starts, and maps read-only in it: which parts of
// the machine are present. A part that the root service did not check is
// absent, never present by default.
//
// Both are at their fixed addresses (`MACHINE_PARTS_PAGE_ADDRESS`,
// `START_LIST_ADDRESS`), and the context of a start policy gives the size
// of the list at `VALUE_LIST_SIZE`.
//
// See [start list](term:start-list), [start row](term:start-row) and
// [machine parts page](term:machine-parts-page).
package start_list

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/wide_grants"

// The names of the two lists in the resource table of the boot image.
START_LIST_RESOURCE :: "start_list"
RESCUE_LIST_RESOURCE :: "rescue_list"

// Where the root service maps the machine parts page and the list, in a
// start policy: the first page of the range, and the pages after it.
MACHINE_PARTS_PAGE_ADDRESS :: fixed_addresses.START_POLICY_PAGES_ADDRESS
START_LIST_ADDRESS :: fixed_addresses.START_POLICY_PAGES_ADDRESS + PAGE_SIZE
PAGE_SIZE :: 4096

// The value of the context of a start policy that holds the bytes of its
// list.
VALUE_LIST_SIZE :: 0

// The bytes "STARTLST" and the version of the format of a list.
LIST_MAGIC :: u64(0x54534C5452415453)
LIST_VERSION :: 4
// The rows of one list at most: a list is read into a table of this size,
// on the stack of the start policy.
ROW_CAPACITY :: 32
// The wiring rows of one list at most: the start policy is the asker of
// each, and holds each wiring until both of its sides end.
WIRING_ROW_CAPACITY :: output.WIRINGS_OF_AN_ASKER_MOST
// The pages of its budget that the start policy states for its wirings:
// the tool refuses a list whose wiring rows need more
// (wiring_pages_of_list). One reserve for every list keeps one module for
// every image and for the rescue.
WIRING_PAGES_RESERVE :: 64

// The module of the machine of the operation sequences, which the root
// service starts by its own procedure.
OPERATION_FUZZING_NAME :: "operation_fuzzing"

// A procedure by which the root service starts a name of its own, with no
// wiring list: the root service switches on it, refuses a Start with a
// list of such a name, and the tool refuses a wiring row whose writer row
// names one. One table names them for the three.
Root_Procedure :: enum u8 {
	None              = 0, // The name starts with the grants of its start grant set, and takes a list.
	Input             = 1,
	// The holder of the role Display, whatever its module: the row names
	// the role, and the root service starts the module that holds it.
	Display           = 2,
	Settings          = 3,
	Unlock            = 4,
	Shortage          = 5,
	Operation_Fuzzing = 6,
}

@(rodata)
ROOT_PROCEDURE_NAMES := [Root_Procedure]string {
	.None              = "",
	.Input             = "input",
	.Display           = "display",
	.Settings          = "settings",
	.Unlock            = "unlock",
	.Shortage          = "shortage",
	.Operation_Fuzzing = OPERATION_FUZZING_NAME,
}

// root_procedure_of gives the procedure of the root service that starts a
// name, or None.
root_procedure_of :: proc "contextless" (name: string) -> Root_Procedure {
	if name == "" {
		return .None
	}
	for procedure in Root_Procedure {
		if ROOT_PROCEDURE_NAMES[procedure] == name {
			return procedure
		}
	}
	return .None
}
// The bytes of the name of a module in a row, with zero bytes after it: the
// size of the name of an entry of the boot image.
MODULE_NAME_SIZE :: 32
// The restarts of one row at most, in its restart window.
RESTART_LIMIT :: 16

// stop_restarts says if a stop of the process of a row starts the row again,
// while it has restarts left (src/md/features/start_policy.md, "The
// subtle points"). A process that stopped itself with `Done`
// finished its work, and one that stopped with `Refused` would get the same
// input again: neither restarts. Each other stop restarts. The outcome
// passed the border of `op.stop_of_words`, so it is not `None` only for a
// stop of the process itself.
//
// Example: `stop_restarts(.Done)` is false; `stop_restarts(.None)`, for a
// fault or a stop by a holder, is true.
stop_restarts :: proc "contextless" (outcome: op.Stop_Outcome) -> bool {
	switch outcome {
	case .Done, .Refused:
		return false
	case .None, .Failed, .Stopped_On_Request:
	}
	return true
}

// The restarts that one row took, for its restart bound
// (src/md/features/supervision.md, "The restart bound"). The zero value is
// a row that has not restarted yet.
Restart_Window :: struct {
	// The times of the restarts inside the window, in milliseconds of the
	// clock of the system, oldest first from first_index. A row with no
	// window keeps no time: only taken counts.
	times_milliseconds: [RESTART_LIMIT]u64,
	first_index:        u32,
	taken:              u32, // The restarts that still count against the bound.
}

// restart_window_take decides one restart of a row with restart_count
// restarts in a window of restart_window_seconds, at the time
// now_milliseconds. With a window of 0 the count holds for the whole run
// and now_milliseconds is not read, so the caller passes 0 and reads no
// clock. With a window, a restart counts while its age is below the
// window; a time before a kept time (a clock that went back) counts as age
// 0, so no subtraction wraps. allowed: the row starts again, and the
// restart is counted. restarts_left: what the window still allows after
// this decision. A count past RESTART_LIMIT is refused, as the border of
// the list refuses it.
//
// Example: restart_count 5, window 60: a 6th restart within 60000 ms of
// the first is refused; at 60000 ms after the first it is allowed.
restart_window_take :: proc "contextless" (window: ^Restart_Window, restart_count: u32, restart_window_seconds: u32, now_milliseconds: u64) -> (allowed: bool, restarts_left: u32) {
	if restart_count > RESTART_LIMIT {
		return false, 0
	}
	if restart_window_seconds != 0 {
		window_milliseconds := u64(restart_window_seconds) * 1000
		for window.taken > 0 {
			oldest := window.times_milliseconds[window.first_index]
			if now_milliseconds <= oldest || now_milliseconds - oldest < window_milliseconds {
				break
			}
			window.first_index = (window.first_index + 1) % RESTART_LIMIT
			window.taken -= 1
		}
	}
	if window.taken >= restart_count {
		return false, 0
	}
	if restart_window_seconds != 0 {
		window.times_milliseconds[(window.first_index + window.taken) % RESTART_LIMIT] = now_milliseconds
	}
	window.taken += 1
	return true, restart_count - window.taken
}

// What the starter of a row does at a stop of its process.
Row_Stop_Step :: enum u8 {
	Silent        = 0, // A row with no restart that stays stopped: the line of the root service is its one line.
	Not_Restarted = 1, // The row stopped itself with Done or Refused.
	Past_Bound    = 2, // Past its restart bound, and the machine is usable without it: the row stays stopped.
	Escalate      = 3, // A needed row past its restart bound: the machine is no longer usable.
	Restarted     = 4,
}

// row_stop_step decides the stop of the process of a row with the stop
// outcome outcome: no restart after Done or Refused, then the restart
// bound of restart_window_take, then the mark of the row past the bound
// (src/md/features/supervision.md, "A holder that stops in a loop, and the
// escalation"). A row with no restart that stays stopped is Silent, unless
// it is needed. It calls clock only for a row with a restart window, so a
// row with none never reads the time. restarts_left: what the window
// allows after a restart.
row_stop_step :: proc "contextless" (row: ^Start_Row, window: ^Restart_Window, outcome: op.Stop_Outcome, clock: proc "contextless" () -> u64) -> (step: Row_Stop_Step, restarts_left: u32) {
	if !stop_restarts(outcome) {
		return row.restart_count == 0 ? .Silent : .Not_Restarted, 0
	}
	now: u64
	if row.restart_window_seconds != 0 {
		now = clock()
	}
	allowed, left := restart_window_take(window, row.restart_count, row.restart_window_seconds, now)
	switch {
	case allowed:
		return .Restarted, left
	case row.usable_mark == .Needed:
		return .Escalate, 0
	case row.restart_count == 0:
		return .Silent, 0
	}
	return .Past_Bound, 0
}

// A part of the machine that a row can need. The member is the bit of the
// part in a word of Machine_Parts.
Machine_Part :: enum u8 {
	Screen         = 0, // The framebuffer of the firmware, with its size.
	Data_Disk      = 1,
	Scratch_Disk   = 2, // The disk of the measures.
	Network_Device = 3,
	Sound_Device   = 4,
	Entropy_Device = 5,
	Tpm            = 6, // The TPM into which the boot program measured the system.
	// No member for the PS/2 controller: the input service reads its
	// absence at its status port, as the one reader of it, and stops with
	// its line (src/md/features/missing_hardware.md).
}
Machine_Parts :: bit_set[Machine_Part;u64]

// first_part gives the first part of a set, in the order of the members,
// for the line of a row that a missing part leaves out; Screen for an
// empty set, which names no missing part.
first_part :: proc "contextless" (parts: Machine_Parts) -> Machine_Part {
	for part in Machine_Part {
		if part in parts {
			return part
		}
	}
	return .Screen
}

// The words of the parts in a sentence of the log.
@(rodata)
PART_NAMES := [Machine_Part]string {
	.Screen         = "screen",
	.Data_Disk      = "data disk",
	.Scratch_Disk   = "disk of the measures",
	.Network_Device = "network device",
	.Sound_Device   = "sound device",
	.Entropy_Device = "entropy device",
	.Tpm            = "TPM",
}

// What the start policy does with a row when a part that the row needs is
// absent.
// The zero value is the rule of a row that names no rule: no start, the
// safe one. A word past the members is still refused at the border.
Absent_Part_Rule :: enum u32 {
	Not_Started    = 0, // No start, with one line.
	Started_Anyway = 1,
}

// Whether the machine is usable without the process of a row.
Usable_Mark :: enum u32 {
	Not_Needed = 0,
	Needed     = 1, // The start policy sends Machine_Usable only when this row runs, or did not start because its part is absent.
}

// The header of a list, then row_count records of Row_Record, then
// wiring_count records of Wiring_Row_Record.
List_Header :: struct {
	magic:        u64,
	version:      u32,
	row_count:    u32,
	wiring_count: u32,
	reserved:     u32, // 0.
}
#assert(size_of(List_Header) == 24)

// One wiring row as the list holds it. The writer is the start row
// writer_row, the end Child of the Start that applies the row; the reader
// is the end Started, and wiring.reader_handle names its start row from 1,
// which comes before writer_row. A start list lends no memory, so the row
// has no terms and no condition.
Wiring_Row_Record :: struct {
	writer_row: u32, // The start row of the writer, from 1.
	reserved:   u32, // 0.
	wiring:     output.Wiring, // terms_offset 0; terms_count 0, or START_LIST_TERMS_BYTES with terms.
	// The terms of the row, which the start policy writes after the lent
	// handles of the list of its start: the terms of an audit space of the
	// collector. Zero bytes with no terms.
	terms:      [START_LIST_TERMS_BYTES]u8,
}
#assert(size_of(Wiring_Row_Record) == 104)

// The bytes of the terms of a wiring row: the size of the terms of a space
// of the collector (wide_grants.Space_Terms).
START_LIST_TERMS_BYTES :: 32

// One wiring row after the border.
Wiring_Row :: struct {
	writer_row: int, // The index of the start row of the writer, from 0.
	reader_row: int, // The index of the start row of the reader, from 0: before writer_row.
	wiring:     output.Wiring, // As the list holds it: reader_handle is reader_row + 1.
	terms:      [START_LIST_TERMS_BYTES]u8, // wiring.terms_count says if the row has terms.
}

// A list after its border: its start rows, then its wiring rows.
List :: struct {
	rows:         [ROW_CAPACITY]Start_Row,
	row_count:    int,
	wirings:      [WIRING_ROW_CAPACITY]Wiring_Row,
	wiring_count: int,
}

// One row as the list holds it: each field a word, which list_read reads.
Row_Record :: struct {
	module_name:   [MODULE_NAME_SIZE]u8, // Zero bytes after the name.
	needs:         u64, // A word of Machine_Parts.
	absent_rule:   u32, // A word of Absent_Part_Rule.
	usable_mark:   u32, // A word of Usable_Mark.
	restart_count: u32, // At most RESTART_LIMIT, and not 0 with a window.
	// Seconds of the clock of the system. 0: the whole run of the machine,
	// so a row that names no window never reads the clock.
	restart_window_seconds: u32,
}
#assert(size_of(Row_Record) == 56)

// One row after the border: its words are members.
Start_Row :: struct {
	module_name:            [MODULE_NAME_SIZE]u8,
	name_length:            int,
	needs:                  Machine_Parts,
	absent_rule:            Absent_Part_Rule,
	usable_mark:            Usable_Mark,
	restart_count:          u32,
	restart_window_seconds: u32, // 0: the whole run.
}

// row_name gives the name of the module of a row.
row_name :: proc "contextless" (row: ^Start_Row) -> string {
	return string(row.module_name[:row.name_length])
}

// What list_read refuses, with the row that it names when the fault is in
// a row.
List_Problem :: enum u8 {
	None                = 0,
	Too_Short           = 1, // Fewer bytes than the header, or than the rows that it counts.
	Wrong_Magic         = 2,
	Wrong_Version       = 3,
	No_Row              = 4,
	Too_Many_Rows       = 5, // Past ROW_CAPACITY.
	Bytes_After_Rows    = 6, // More bytes than the header and the rows.
	Bad_Name            = 7, // No byte, a byte that is not a-z, 0-9 or _, or a byte after the zero bytes.
	Unknown_Part        = 8, // A bit of needs that names no Machine_Part.
	Unknown_Rule        = 9,
	Unknown_Mark        = 10,
	Reserved_Not_Zero   = 11,
	Restarts_Past_Limit = 12,
	Name_Twice          = 13, // Two rows of one module: one start of each name.
	// The wiring rows: place is the wiring row from 0.
	Too_Many_Wirings     = 14, // Past WIRING_ROW_CAPACITY.
	Wiring_Row_Unknown   = 15, // A writer row of 0 or past the start rows.
	Wiring_Refused       = 16, // output.wiring_row_check refuses the wiring: its error record says the field.
	End_Not_Held         = 17, // A writer that is not Child, or a reader that is not Started: an end that the grant Start_Policy does not give.
	Wiring_Loops         = 18, // The reader row is the writer row: one process at both ends.
	Writer_Before_Reader = 19, // The reader row comes after the writer row: the writer would run before its reader.
	Log_Wired_Twice      = 20, // Two wiring rows wire the record output log of one writer row.
	Writer_Restarts      = 21, // The writer row of a wiring row has restarts: a restart applies its rows again, which a reader of one wiring refuses or not by its speed.
	// A start row again: place is the start row from 0.
	Window_Without_Restarts = 22, // A restart window on a row with no restart: a bound of nothing.
	// A wiring row again.
	Bad_Terms = 23, // Terms of another size, an offset of terms, terms that name no space Audit that keeps (wide_grants.server_audit_terms_valid), or bytes of terms in a row with no terms.
}

@(rodata)
LIST_PROBLEM_TEXTS := [List_Problem]string {
	.None                = "no fault",
	.Too_Short           = "it is shorter than its header and its rows",
	.Wrong_Magic         = "it does not start with the bytes STARTLST",
	.Wrong_Version       = "its version is not the version of this format",
	.No_Row              = "it has no row",
	.Too_Many_Rows       = "it has more rows than a list holds",
	.Bytes_After_Rows    = "it has bytes after its rows",
	.Bad_Name            = "a row has a module name that is not a name",
	.Unknown_Part        = "a row needs a part that names no part of the machine",
	.Unknown_Rule        = "a row has a rule for an absent part that names no rule",
	.Unknown_Mark        = "a row has a mark that is neither needed nor not needed",
	.Reserved_Not_Zero   = "a reserved word is not 0",
	.Restarts_Past_Limit = "a row has more restarts than a row holds",
	.Name_Twice          = "two rows name one module",
	.Too_Many_Wirings     = "it has more wiring rows than a list holds",
	.Wiring_Row_Unknown   = "a wiring row names no start row as its writer",
	.Wiring_Refused       = "a wiring row is refused by its border",
	.End_Not_Held         = "a wiring row names an end that no start policy holds",
	.Wiring_Loops         = "a wiring row has one start row at both ends",
	.Writer_Before_Reader = "a wiring row has its writer before its reader",
	.Log_Wired_Twice      = "two wiring rows wire the log of one row",
	.Writer_Restarts      = "a wiring row has a writer row with restarts",
	// A start row again.
	.Window_Without_Restarts = "a row has a restart window and no restart",
	.Bad_Terms               = "a wiring row has terms of another size, terms that name no audit of what leaves a server, or bytes of terms with no terms",
}

// parts_of_word is the border of a word of Machine_Parts: a bit that names
// no member refuses the whole word.
parts_of_word :: proc "contextless" (word: u64) -> (parts: Machine_Parts, ok: bool) {
	known: u64
	for part in Machine_Part {
		known |= u64(1) << u64(part)
	}
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Machine_Parts)word, true
}

// name_valid says if the bytes of a name field are 1 to 31 bytes of a-z,
// 0-9 and _, then zero bytes only. It gives the length of the name.
name_valid :: proc "contextless" (field: ^[MODULE_NAME_SIZE]u8) -> (length: int, ok: bool) {
	for length < MODULE_NAME_SIZE && field[length] != 0 {
		character := field[length]
		if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_') {
			return 0, false
		}
		length += 1
	}
	if length == 0 || length == MODULE_NAME_SIZE {
		return 0, false
	}
	for index in length ..< MODULE_NAME_SIZE {
		if field[index] != 0 {
			return 0, false
		}
	}
	return length, true
}

// row_of_record is the border of one row: each word becomes its member, or
// the row is refused with the problem of its first wrong field.
row_of_record :: proc "contextless" (record: ^Row_Record) -> (row: Start_Row, problem: List_Problem) {
	length, named := name_valid(&record.module_name)
	if !named {
		return {}, .Bad_Name
	}
	needs, parts_known := parts_of_word(record.needs)
	if !parts_known {
		return {}, .Unknown_Part
	}
	rule, rule_known := enum_word.member_of_word(Absent_Part_Rule, u64(record.absent_rule))
	if !rule_known {
		return {}, .Unknown_Rule
	}
	mark, mark_known := enum_word.member_of_word(Usable_Mark, u64(record.usable_mark))
	if !mark_known {
		return {}, .Unknown_Mark
	}
	if record.restart_count > RESTART_LIMIT {
		return {}, .Restarts_Past_Limit
	}
	if record.restart_window_seconds != 0 && record.restart_count == 0 {
		return {}, .Window_Without_Restarts
	}
	row = {module_name = record.module_name, name_length = length, needs = needs, absent_rule = rule, usable_mark = mark, restart_count = record.restart_count, restart_window_seconds = record.restart_window_seconds}
	return row, .None
}

// list_read is the border of a list: it copies each record out of bytes
// before it reads it, and gives the start rows and the wiring rows, or the
// problem and the place of the first row that it refuses: a start row for
// the problems of a start row, a wiring row for those of a wiring row. A
// wiring row that output.wiring_row_check refuses gives its error record
// too. A refused list gives no row: a start policy never starts half of a
// list.
// list_audit_count gives the wiring rows of a list that carry the terms of
// an audit space: the audits that the collector of the start policy keeps,
// whose memory its starter pays (src/md/features/wide_grants.md, "The
// starter pays for the audits"). A list that its border refuses has none.
list_audit_count :: proc "contextless" (list: ^List) -> (count: int) {
	for wiring in list.wirings[:list.wiring_count] {
		if wiring.wiring.terms_count == START_LIST_TERMS_BYTES {
			count += 1
		}
	}
	return count
}

list_read :: proc "contextless" (bytes: []u8, list: ^List) -> (problem: List_Problem, place: int, refusal: errors.Error_Record) {
	list^ = {}
	problem, place, refusal = list_read_rows(bytes, list)
	if problem != .None {
		list^ = {}
	}
	return
}

@(private = "file")
list_read_rows :: proc "contextless" (bytes: []u8, list: ^List) -> (problem: List_Problem, place: int, refusal: errors.Error_Record) {
	if len(bytes) < size_of(List_Header) {
		return .Too_Short, 0, {}
	}
	header: List_Header
	intrinsics.mem_copy_non_overlapping(&header, raw_data(bytes), size_of(List_Header))
	switch {
	case header.magic != LIST_MAGIC:
		return .Wrong_Magic, 0, {}
	case header.version != LIST_VERSION:
		return .Wrong_Version, 0, {}
	case header.reserved != 0:
		return .Reserved_Not_Zero, 0, {}
	case header.row_count == 0:
		return .No_Row, 0, {}
	case header.row_count > ROW_CAPACITY:
		return .Too_Many_Rows, 0, {}
	case header.wiring_count > WIRING_ROW_CAPACITY:
		return .Too_Many_Wirings, 0, {}
	}
	row_count := int(header.row_count)
	wiring_count := int(header.wiring_count)
	whole := list_size(row_count, wiring_count)
	if len(bytes) < whole {
		return .Too_Short, 0, {}
	}
	if len(bytes) > whole {
		return .Bytes_After_Rows, 0, {}
	}
	for index in 0 ..< row_count {
		record: Row_Record
		intrinsics.mem_copy_non_overlapping(&record, raw_data(bytes[size_of(List_Header) + index * size_of(Row_Record):]), size_of(Row_Record))
		row, row_problem := row_of_record(&record)
		if row_problem != .None {
			return row_problem, index, {}
		}
		for earlier in 0 ..< index {
			if row_name(&list.rows[earlier]) == row_name(&row) {
				return .Name_Twice, index, {}
			}
		}
		list.rows[index] = row
	}
	list.row_count = row_count
	wirings_start := size_of(List_Header) + row_count * size_of(Row_Record)
	for index in 0 ..< wiring_count {
		record: Wiring_Row_Record
		intrinsics.mem_copy_non_overlapping(&record, raw_data(bytes[wirings_start + index * size_of(Wiring_Row_Record):]), size_of(Wiring_Row_Record))
		wiring_row, wiring_problem, wiring_refusal := wiring_row_of_record(&record, index, row_count)
		if wiring_problem != .None {
			return wiring_problem, index, wiring_refusal
		}
		// One wiring list names the log of its child once: the wiring rows
		// of one writer row are the list of its start.
		for earlier in 0 ..< index {
			before := &list.wirings[earlier]
			if before.writer_row == wiring_row.writer_row && before.wiring.writer_stream == u32(output.Writer_Stream.Log) && wiring_row.wiring.writer_stream == u32(output.Writer_Stream.Log) {
				return .Log_Wired_Twice, index, {}
			}
		}
		// A restart of the writer applies its rows again while the ring
		// before it may still hold its reader: a record input of one
		// wiring is then refused or not by the speed of that reader.
		if list.rows[wiring_row.writer_row].restart_count > 0 {
			return .Writer_Restarts, index, {}
		}
		list.wirings[index] = wiring_row
	}
	list.wiring_count = wiring_count
	return .None, 0, {}
}

// wiring_row_of_record is the border of one wiring row, index from 0, in a
// list of row_count start rows. It refuses, in this order: a reserved word
// that is not 0; a writer row of 0 or past the start rows; what
// output.wiring_row_check refuses, with its error record, the start rows
// as the lent handles and no byte for terms or a condition; a paired row;
// an end that the
// grant Start_Policy does not give; a reader row that is the writer row;
// and a reader row after the writer row.
@(private = "file")
wiring_row_of_record :: proc "contextless" (record: ^Wiring_Row_Record, index: int, row_count: int) -> (row: Wiring_Row, problem: List_Problem, refusal: errors.Error_Record) {
	if record.reserved != 0 {
		return {}, .Reserved_Not_Zero, {}
	}
	if record.writer_row == 0 || int(record.writer_row) > row_count {
		return {}, .Wiring_Row_Unknown, {}
	}
	// The terms are in the row: the start policy gives them their place.
	// The row holds no offset, and no byte of terms when it has none.
	has_terms := record.wiring.terms_count == START_LIST_TERMS_BYTES
	if record.wiring.terms_offset != 0 || (record.wiring.terms_count != 0 && !has_terms) || (!has_terms && record.terms != ([START_LIST_TERMS_BYTES]u8{})) {
		return {}, .Bad_Terms, {}
	}
	// Terms name a space Audit that keeps what leaves a server, and nothing
	// else: a kind, a forwarding, a bound or a size out of range is refused
	// here, not by the collector at the start of the machine.
	#assert(size_of(wide_grants.Space_Terms) == START_LIST_TERMS_BYTES)
	if has_terms && !wide_grants.server_audit_terms_valid(transmute(wide_grants.Space_Terms)record.terms) {
		return {}, .Bad_Terms, {}
	}
	// A list of 0 bytes: a condition needs bytes that a start list does not
	// lend, so the border refuses it. The terms are checked above, so the
	// generic check reads the row without them.
	plain := record.wiring
	plain.terms_count = 0
	checked, row_refusal, checked_ok := output.wiring_row_check(plain, u32(index + 1), .Start, u32(row_count), 0, 0)
	if !checked_ok {
		return {}, .Wiring_Refused, row_refusal
	}
	// A pair needs terms that ask to forward, which a start list cannot
	// carry, and the start policy sends the rows of one writer at a time,
	// so a number of a row of this list names no row of what it sends.
	if checked.paired_row != 0 {
		return {}, .Wiring_Refused, errors.error_make(.Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Paired_Row), i64(checked.paired_row), 0, i64(index + 1))
	}
	if checked.writer_end != .Child || checked.reader_end != .Started {
		return {}, .End_Not_Held, {}
	}
	if checked.reader_handle == record.writer_row {
		return {}, .Wiring_Loops, {}
	}
	if checked.reader_handle > record.writer_row {
		return {}, .Writer_Before_Reader, {}
	}
	return {writer_row = int(record.writer_row) - 1, reader_row = int(checked.reader_handle) - 1, wiring = record.wiring, terms = record.terms}, .None, {}
}

// list_size gives the bytes of a list of row_count start rows and
// wiring_count wiring rows.
list_size :: proc "contextless" (row_count: int, wiring_count: int = 0) -> int {
	return size_of(List_Header) + row_count * size_of(Row_Record) + wiring_count * size_of(Wiring_Row_Record)
}

// row_make gives the row of a module, for a writer of a list. ok is false
// for a name that list_read refuses.
row_make :: proc "contextless" (name: string, needs: Machine_Parts, absent_rule: Absent_Part_Rule, usable_mark: Usable_Mark, restart_count: u32 = 0, restart_window_seconds: u32 = 0) -> (row: Start_Row, ok: bool) {
	if len(name) == 0 || len(name) >= MODULE_NAME_SIZE {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&row.module_name[0], raw_data(name), len(name))
	length, named := name_valid(&row.module_name)
	if !named {
		return {}, false
	}
	row.name_length, row.needs, row.absent_rule, row.usable_mark, row.restart_count = length, needs, absent_rule, usable_mark, restart_count
	row.restart_window_seconds = restart_window_seconds
	return row, true
}

// list_write writes the records of rows and of wirings into bytes, which
// holds list_size(len(rows), len(wirings)) bytes or more. ok is false when
// it does not, or for more rows than a list holds. It writes the words;
// list_read is the check.
list_write :: proc "contextless" (rows: []Start_Row, wirings: []Wiring_Row_Record, bytes: []u8) -> (size: int, ok: bool) {
	if len(rows) > ROW_CAPACITY || len(wirings) > WIRING_ROW_CAPACITY || len(bytes) < list_size(len(rows), len(wirings)) {
		return 0, false
	}
	header := List_Header{magic = LIST_MAGIC, version = LIST_VERSION, row_count = u32(len(rows)), wiring_count = u32(len(wirings))}
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &header, size_of(List_Header))
	for &row, index in rows {
		record := Row_Record {
			module_name            = row.module_name,
			needs                  = transmute(u64)row.needs,
			absent_rule            = u32(row.absent_rule),
			usable_mark            = u32(row.usable_mark),
			restart_count          = row.restart_count,
			restart_window_seconds = row.restart_window_seconds,
		}
		intrinsics.mem_copy_non_overlapping(raw_data(bytes[size_of(List_Header) + index * size_of(Row_Record):]), &record, size_of(Row_Record))
	}
	wirings_start := size_of(List_Header) + len(rows) * size_of(Row_Record)
	for &record, index in wirings {
		intrinsics.mem_copy_non_overlapping(raw_data(bytes[wirings_start + index * size_of(Wiring_Row_Record):]), &record, size_of(Wiring_Row_Record))
	}
	return list_size(len(rows), len(wirings)), true
}

// The page tables that the start policy makes when it maps its list page:
// a table of each of the three levels under the first one, at most. The
// sides of a wiring map its ring, and their budgets pay those tables; the
// start policy maps no ring.
LIST_PAGE_TABLE_PAGES :: 3

// The pages that each list with a wiring row costs the budget of its start
// policy, whatever its rows: the list page and its page tables, the wiring
// ring that the root service gives the start policy with it, and one
// wiring page.
WIRING_PAGES_OF_THE_ASKER :: output.WIRING_LIST_PAGES_MOST + LIST_PAGE_TABLE_PAGES + output.WIRING_RING_PAGES + 1

// wiring_pages_of_row gives the pages of one wiring row: its ring of
// capacity compartments (0: the default) for a record of record_size
// bytes, its end page, and its description file at its largest. 0: no
// ring has this record size.
wiring_pages_of_row :: proc "contextless" (capacity: u32, record_size: u32) -> u64 {
	compartment := output.compartment_size(record_size)
	if compartment == 0 {
		return 0
	}
	ring_capacity := capacity == 0 ? output.WIRING_CAPACITY_DEFAULT : capacity
	return ring.compartment_pages(ring_capacity, compartment) + 1 + output.DESCRIPTION_FILE_BYTES_MOST / ring.PAGE_SIZE
}

// wiring_pages_of_list gives the pages of the wirings of a list: 0 with no
// row, else the pages of the asker and the pages of each row, whose record
// sizes are record_sizes in the order of the wiring rows. ok is false when
// the counts differ, or a row has a size that no ring takes.
wiring_pages_of_list :: proc "contextless" (list: ^List, record_sizes: []u32) -> (pages: u64, ok: bool) {
	if len(record_sizes) != list.wiring_count {
		return 0, false
	}
	if list.wiring_count == 0 {
		return 0, true
	}
	pages = WIRING_PAGES_OF_THE_ASKER
	for &wiring_row, index in list.wirings[:list.wiring_count] {
		row_pages := wiring_pages_of_row(wiring_row.wiring.capacity, record_sizes[index])
		if row_pages == 0 {
			return 0, false
		}
		pages += row_pages
	}
	return pages, true
}

// list_has_usable_row says if a list has a row with the mark Needed: with
// none, the start policy would send Machine_Usable with no principal able
// to reach the machine, so the tool refuses such a rescue list.
list_has_usable_row :: proc "contextless" (rows: []Start_Row) -> bool {
	for &row in rows {
		if row.usable_mark == .Needed {
			return true
		}
	}
	return false
}

// The bytes "MACHPART" and the version of the machine parts page.
PARTS_PAGE_MAGIC :: u64(0x545241504843414D)
PARTS_PAGE_VERSION :: 1

// The machine parts page. The root service writes it once, before the
// start policy starts.
Machine_Parts_Page :: struct {
	magic:         u64,
	version:       u32,
	reserved:      u32, // 0.
	present:       u64, // A word of Machine_Parts: the parts that the root service found.
	screen_width:  u32, // Pixels. 0 with no screen.
	screen_height: u32,
}
#assert(size_of(Machine_Parts_Page) <= PAGE_SIZE)

// parts_page_read is the border of the machine parts page: it copies the
// page, then reads the copy. A page with another magic or version, a
// reserved word that is not 0, a bit that names no part, or a size that
// disagrees with the screen bit is refused whole.
parts_page_read :: proc "contextless" (page: rawptr) -> (parts: Machine_Parts, screen_width, screen_height: u32, ok: bool) {
	copied: Machine_Parts_Page
	intrinsics.mem_copy_non_overlapping(&copied, page, size_of(Machine_Parts_Page))
	if copied.magic != PARTS_PAGE_MAGIC || copied.version != PARTS_PAGE_VERSION || copied.reserved != 0 {
		return {}, 0, 0, false
	}
	known_parts, parts_known := parts_of_word(copied.present)
	if !parts_known {
		return {}, 0, 0, false
	}
	parts = known_parts
	sized := copied.screen_width != 0 && copied.screen_height != 0
	unsized := copied.screen_width == 0 && copied.screen_height == 0
	if .Screen in parts && !sized || .Screen not_in parts && !unsized {
		return {}, 0, 0, false
	}
	return parts, copied.screen_width, copied.screen_height, true
}

// parts_page_write is for the root service: the page of these parts.
parts_page_write :: proc "contextless" (page: ^Machine_Parts_Page, parts: Machine_Parts, screen_width, screen_height: u32) {
	page^ = {magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, present = transmute(u64)parts, screen_width = screen_width, screen_height = screen_height}
}
