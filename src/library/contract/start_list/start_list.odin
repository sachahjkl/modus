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
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"

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
LIST_VERSION :: 1
// The rows of one list at most: a list is read into a table of this size,
// on the stack of the start policy.
ROW_CAPACITY :: 32
// The bytes of the name of a module in a row, with zero bytes after it: the
// size of the name of an entry of the boot image.
MODULE_NAME_SIZE :: 32
// The restarts of one row at most, for the whole run of the machine.
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

// The header of a list, then row_count records of Row_Record.
List_Header :: struct {
	magic:     u64,
	version:   u32,
	row_count: u32,
}
#assert(size_of(List_Header) == 16)

// One row as the list holds it: each field a word, which list_read reads.
Row_Record :: struct {
	module_name:   [MODULE_NAME_SIZE]u8, // Zero bytes after the name.
	needs:         u64, // A word of Machine_Parts.
	absent_rule:   u32, // A word of Absent_Part_Rule.
	usable_mark:   u32, // A word of Usable_Mark.
	restart_count: u32, // At most RESTART_LIMIT.
	reserved:      u32, // 0.
}
#assert(size_of(Row_Record) == 56)

// One row after the border: its words are members.
Start_Row :: struct {
	module_name:   [MODULE_NAME_SIZE]u8,
	name_length:   int,
	needs:         Machine_Parts,
	absent_rule:   Absent_Part_Rule,
	usable_mark:   Usable_Mark,
	restart_count: u32,
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
	.Reserved_Not_Zero   = "a row has a reserved word that is not 0",
	.Restarts_Past_Limit = "a row has more restarts than a row holds",
	.Name_Twice          = "two rows name one module",
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
	if record.reserved != 0 {
		return {}, .Reserved_Not_Zero
	}
	if record.restart_count > RESTART_LIMIT {
		return {}, .Restarts_Past_Limit
	}
	row = {module_name = record.module_name, name_length = length, needs = needs, absent_rule = rule, usable_mark = mark, restart_count = record.restart_count}
	return row, .None
}

// list_read is the border of a list: it copies each record out of bytes
// before it reads it, and gives the rows, or the problem and the place of
// the first row that it refuses. A refused list gives no row: a start
// policy never starts half of a list.
list_read :: proc "contextless" (bytes: []u8, rows: ^[ROW_CAPACITY]Start_Row) -> (count: int, problem: List_Problem, place: int) {
	if len(bytes) < size_of(List_Header) {
		return 0, .Too_Short, 0
	}
	header: List_Header
	intrinsics.mem_copy_non_overlapping(&header, raw_data(bytes), size_of(List_Header))
	if header.magic != LIST_MAGIC {
		return 0, .Wrong_Magic, 0
	}
	if header.version != LIST_VERSION {
		return 0, .Wrong_Version, 0
	}
	if header.row_count == 0 {
		return 0, .No_Row, 0
	}
	if header.row_count > ROW_CAPACITY {
		return 0, .Too_Many_Rows, 0
	}
	row_count := int(header.row_count)
	whole := size_of(List_Header) + row_count * size_of(Row_Record)
	if len(bytes) < whole {
		return 0, .Too_Short, 0
	}
	if len(bytes) > whole {
		return 0, .Bytes_After_Rows, 0
	}
	for index in 0 ..< row_count {
		record: Row_Record
		intrinsics.mem_copy_non_overlapping(&record, raw_data(bytes[size_of(List_Header) + index * size_of(Row_Record):]), size_of(Row_Record))
		row, row_problem := row_of_record(&record)
		if row_problem != .None {
			rows^ = {}
			return 0, row_problem, index
		}
		for earlier in 0 ..< index {
			if row_name(&rows[earlier]) == row_name(&row) {
				rows^ = {}
				return 0, .Name_Twice, index
			}
		}
		rows[index] = row
	}
	return row_count, .None, 0
}

// list_size gives the bytes of a list of row_count rows.
list_size :: proc "contextless" (row_count: int) -> int {
	return size_of(List_Header) + row_count * size_of(Row_Record)
}

// row_make gives the row of a module, for a writer of a list. ok is false
// for a name that list_read refuses.
row_make :: proc "contextless" (name: string, needs: Machine_Parts, absent_rule: Absent_Part_Rule, usable_mark: Usable_Mark, restart_count: u32 = 0) -> (row: Start_Row, ok: bool) {
	if len(name) == 0 || len(name) >= MODULE_NAME_SIZE {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&row.module_name[0], raw_data(name), len(name))
	length, named := name_valid(&row.module_name)
	if !named {
		return {}, false
	}
	row.name_length, row.needs, row.absent_rule, row.usable_mark, row.restart_count = length, needs, absent_rule, usable_mark, restart_count
	return row, true
}

// list_write writes the records of rows into output, which holds
// list_size(len(rows)) bytes or more. ok is false when it does not, or for
// more rows than a list holds. It writes the words; list_read is the check.
list_write :: proc "contextless" (rows: []Start_Row, output: []u8) -> (size: int, ok: bool) {
	if len(rows) > ROW_CAPACITY || len(output) < list_size(len(rows)) {
		return 0, false
	}
	header := List_Header{magic = LIST_MAGIC, version = LIST_VERSION, row_count = u32(len(rows))}
	intrinsics.mem_copy_non_overlapping(raw_data(output), &header, size_of(List_Header))
	for &row, index in rows {
		record := Row_Record {
			module_name   = row.module_name,
			needs         = transmute(u64)row.needs,
			absent_rule   = u32(row.absent_rule),
			usable_mark   = u32(row.usable_mark),
			restart_count = row.restart_count,
		}
		intrinsics.mem_copy_non_overlapping(raw_data(output[size_of(List_Header) + index * size_of(Row_Record):]), &record, size_of(Row_Record))
	}
	return list_size(len(rows)), true
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
