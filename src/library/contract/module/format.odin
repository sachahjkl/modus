// The module format, version 2 (docs/MODULE_CONTRACT.md, sections 1 and 2).
//
// A module is one file:
//
//   Header
//   table directory   one Table_Entry per Table_Kind
//   tables            flat records
//   segment data      each segment starts on a page boundary of the file
//
// All numbers are little-endian. An all-zero record is valid (ZII).
// Record 0 of an indexed table is the empty record, so index 0 means "none".
// This package allocates no memory: the boot program, the kernel and the
// build tool use the same code.
//
// Who uses it: the build tool writes modules; the boot program checks the
// kernel and the root service; the kernel loads the root service;
// `src/library/support/system` loads every other module; the console, the process
// `manual` and the site read the descriptions of the exports. The parts:
//
// - `Header`, `Table_Kind`, `Table_Entry`: the frame of a file.
// - `Segment`, `Import`, `Slot`, `Export`, the rebase table: what a loader
//   reads (`load.odin`: `validate`, `rebase`, `bind`).
// - `Function`, `Type`, `Direction`, `Record`, `Field`, `Table_Place`: the
//   call form of an export (docs/MODULE_CONTRACT.md, section 4).
// - `Documentation`: the help of the module and of each export.
// - `Budget_Request`: the budget that the module asks for its process
//   (`budget_request`).
// - `Load_Error`, `Load_Stage`, `Difference` (`error.odin`) and `Error`
//   (`load.odin`): why a load failed.
//
// See [module](term:module) and [export](term:export).
package module

import "modus:contract/enum_word"
import "modus:contract/value_kinds"

MAGIC :: u64(0x0000_454C_5544_4F4D) // The bytes "MODULE", then two zero bytes.
VERSION :: 2 // The version of the format that this code reads and writes. A file of another version is refused. 2: a Function record of 168 bytes, with 12 parameters.
PAGE_SIZE :: 4096 // The alignment of each segment in the file and in memory: one page of the processor.
HASH_SIZE :: 32 // The bytes of a BLAKE3 hash: the name of a module.

// The feature bits that this code understands. A file that sets another bit
// in Header.must_understand is refused.
UNDERSTOOD_FEATURES :: u64(0)

// The processor whose instructions the segments hold. A loader refuses a
// module of another machine (`Error.Unknown_Machine`).
Machine :: enum u32 {
	None   = 0, // No machine: refused.
	X86_64 = 1, // The 64-bit x86 processor.
}

// The first 48 bytes of a module file. A loader reads it first and refuses
// the file when one field is not one that it takes (`validate`).
//
// Example: the header of a process starts with the bytes "MODULE", the
// version 2, the machine `X86_64`, and `entry_export` the index of its
// export `main`.
Header :: struct {
	magic:           u64, // `MAGIC`.
	version:         u32, // `VERSION`.
	header_size:     u32, // The table directory starts at this offset.
	must_understand: u64, // Feature bits: a reader refuses a file with a bit outside `UNDERSTOOD_FEATURES`.
	machine:         Machine, // The processor of the code.
	table_count:     u32, // The number of entries of the table directory.
	memory_size:     u64, // The size of the address range of the loaded module.
	entry_export:    u32, // An index in the export table. 0: the module has no entry.
	reserved:        u32, // 0.
}
#assert(size_of(Header) == 48)

// The number of a table is its index in the table directory.
Table_Kind :: enum u32 {
	None          = 0, // The entry 0 of the directory: no table.
	Segments      = 1, // `Segment` records: the bytes to map.
	Imports       = 2, // `Import` records: the modules that this one calls.
	Slots         = 3, // `Slot` records: the places that receive the address of an imported export.
	Exports       = 4, // `Export` records: the entry points that other modules call.
	Rebases       = 5, // The rebase table: words, not records.
	Functions     = 6, // `Function` records: the call form of each export.
	Strings       = 7, // The string table: bytes.
	Documentation = 8, // `Documentation` records: the help of the module and of each export.
	Records       = 9, // `Record` records: the descriptions of the records that the exports take and give.
	Fields        = 10, // `Field` records: the fields of those records.
	Budget        = 11, // One `Budget_Request` record, at index 1: the budget that the module asks for.
}
// The tables that this version of the format knows.
TABLE_COUNT :: len(Table_Kind)

// A table can gain fields at the end of its record: record_size says how
// large a record is in this file. A reader ignores the bytes that it does not
// know, and reads the bytes that the file does not have as zero.
Table_Entry :: struct {
	offset:      u64, // From the start of the file.
	count:       u32, // The records of the table, record 0 included; bytes for the string table.
	record_size: u32, // The bytes of one record in this file: at least the bytes that the reader needs, or the reader reads zeros. At least 1 when the table has records: `validate` refuses records of no byte.
}
#assert(size_of(Table_Entry) == 16)

// The access of a segment once loaded. A loader never maps a segment with
// `Write` and `Execute`: the kernel refuses such a mapping.
Segment_Flag :: enum u32 {
	Read                 = 0, // The module reads the bytes.
	Write                = 1, // The module writes the bytes: its data.
	Execute              = 2, // The bytes are instructions.
	Read_Only_After_Load = 3, // The loader writes it (rebases, slots), then removes Write.
}
// The flags of one `Segment`.
Segment_Flags :: bit_set[Segment_Flag;u32]

// One run of bytes of the module that a loader maps, with one access.
// memory_offset and memory_size are multiples of PAGE_SIZE. The bytes of
// memory after file_size are zero.
//
// Example: the code of a module is a segment with `flags = {.Read,
// .Execute}`, `memory_offset = 0`; its data a segment with `{.Read, .Write}`
// after it.
Segment :: struct {
	file_offset:   u64, // Where the bytes start in the file: a multiple of PAGE_SIZE.
	file_size:     u64, // The bytes in the file: at most memory_size.
	memory_offset: u64, // From the base of the module in memory.
	memory_size:   u64, // The bytes of addresses of the segment.
	flags:         Segment_Flags, // Its access.
	reserved:      u32, // 0.
}
#assert(size_of(Segment) == 40)

// One imported module, named by the BLAKE3 hash of its file.
//
// A loader finds the file in its load source by this hash, and refuses a
// file whose hash is another (`Load_Stage.Read`). A replacement can change the
// hash that an import names before the load (`Replacement`).
Import :: struct {
	hash: [HASH_SIZE]u8, // The BLAKE3 hash of the whole file of the module.
}

// One import slot: 8 bytes of memory that receive the address of an export.
//
// The loader writes there the address of the export `export_index` of the
// module `import_index`, then maps the segment without `Write` when it is
// `Read_Only_After_Load`.
Slot :: struct {
	memory_offset: u64, // The place of the 8 bytes, from the base of the module.
	import_index:  u32, // An index in the import table, from 1.
	export_index:  u32, // An index in the export table of that module, from 1.
}
#assert(size_of(Slot) == 16)

// One export: a procedure of the module that another module or the loader
// calls. Its index is its number in the module: an import slot and an error
// record name it by that index. See [export](term:export).
Export :: struct {
	code_offset: u64, // The memory offset of the first instruction.
	function:    u32, // An index in the function table.
	reserved:    u32, // 0.
}
#assert(size_of(Export) == 16)

// The type of a parameter or of a result of an export, in the call form
// (docs/MODULE_CONTRACT.md, section 4).
//
// The site shows each member as a wire form. A description that names a type
// outside this list is refused by `isolated.record_size`.
Type :: enum u8 {
	None    = 0, // No parameter, or no result: an export with the result None gives nothing.
	Integer = 1, // A signed integer of 64 bits, in a register.
	Text    = 2, // The address of a slice record {address, count} of UTF-8 bytes.
	// A Text result: the caller gives one more argument after the parameters,
	// the address of a buffer record {address, capacity}. The callee writes
	// the text in the buffer, and its integer result is the count of bytes of
	// the full text. A count larger than the capacity means "the text did
	// not fit": the caller owns all memory, and the callee allocates no
	// larger buffer.
	Record  = 3, // The address of a record: bytes with a fixed size and described fields (Record).
	// A record holds values only, and no address: its bytes mean the same
	// in each process. The detail of the parameter is the index of the
	// description of the record, in the record table.
	// A Record result: the caller gives one more argument after the
	// parameters, the address of the memory of the record. The callee
	// writes the record there. The export has no integer result.
	Handle  = 4, // A handle that the caller lends for the time of the call, in a register.
	// The detail of the parameter is the rights that the callee needs: a
	// bit set of rights (the kernel operations name the bits). The caller
	// keeps its handle. In an isolated call, the receiver has a copy of the
	// handle with these rights only, and closes it when the export returns.
	Table   = 5, // Records of one description that follow each other (a table).
	// The detail is the index of the description of the record, in the
	// record table. A record of a table has no Handle field.
	// A Table parameter: the address of a Table_Place in memory of the
	// caller, with a Direction (Function.parameter_directions).
	// A Table result: the caller gives one more argument after the
	// parameters, the address of a buffer record {address, capacity}: the
	// capacity is a count of records. The callee writes the records that
	// fit, and its integer result is the count of records of the full
	// table. A count larger than the capacity means "the table did not
	// fit". It is the case of an Append table from a count of 0 whose new
	// count is the integer result.
	Bytes   = 6, // A parameter only: bytes with no description, with a Direction.
	// The address of a Table_Place in memory of the caller, where the
	// count and the capacity are in bytes. The detail is 0.
}

// type_of_word is the border of the byte of a Type in a module file
// (Function.result, Function.parameters, Field.type): the member, or false
// for a byte that names no type. A module file comes from its build or from
// a disk, so its bytes are words: a reader takes each through this border
// and never casts it.
type_of_word :: proc "contextless" (word: u8) -> (type: Type, ok: bool) {
	return enum_word.member_of_word(Type, u64(word))
}

// function_result_type reads the type of the result of an export through
// the border.
function_result_type :: proc "contextless" (function: Function) -> (type: Type, ok: bool) {
	return type_of_word(function.result)
}

// function_parameter_type reads the type of the parameter index of an
// export through the border: false for an index past PARAMETER_CAPACITY,
// or negative, and for a byte that names no type.
function_parameter_type :: proc "contextless" (function: Function, index: int) -> (type: Type, ok: bool) {
	if index < 0 || index >= PARAMETER_CAPACITY {
		return {}, false
	}
	return type_of_word(function.parameters[index])
}

// field_type reads the type of a field of a record through the border.
field_type :: proc "contextless" (field: Field) -> (type: Type, ok: bool) {
	return type_of_word(field.type)
}

// What the callee does with the memory of a Table or Bytes parameter
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters"). 0 is the
// direction with the least power.
Direction :: enum u8 {
	Read   = 0, // It reads the records 0 ..< count, and writes nothing.
	Change = 1, // It reads and writes the records 0 ..< count. The count stays.
	// It writes the records count ..< capacity and reads none before count.
	// The count is the count of the full answer, across calls: the callee
	// adds the records of its answer, also those that did not fit. A count
	// larger than the capacity means "the answer did not fit"; on entry it
	// means that earlier calls did not fit, and the callee then writes
	// nothing. It never writes a record at an index >= capacity.
	Append = 2,
}

// The table place: the record that names the memory of a Table or Bytes
// parameter in a direct call. The register of the parameter has its
// address. address is aligned on the alignment of the record. count and
// capacity are in records (in bytes for Bytes).
Table_Place :: struct {
	address:  u64, // The first record.
	count:    u64, // The records of the table: see `Direction` for who changes it.
	capacity: u64, // The records that fit at `address`.
}
#assert(size_of(Table_Place) == 24)

// The arguments of the call form of one export: its parameters, the buffer
// or the place of a result, and the address of an error record. The first 6
// are in the integer registers, the others on the stack, as the convention of
// the machine passes them (docs/MODULE_CONTRACT.md, section 4). A fixed bound
// keeps a Function record and the private copy of a receiver of one size.
PARAMETER_CAPACITY :: 12

// The description of one export. It is sufficient to call the export: the
// console reads it. The loader does not.
Function :: struct {
	name_offset:           u32, // In the string table.
	name_count:            u32, // The bytes of the name.
	about_offset:          u32, // One line of help, in the string table.
	about_count:           u32, // The bytes of the line of help.
	parameter_names:       [PARAMETER_CAPACITY]u32, // The name of each parameter, in the string table.
	parameter_count:       u8, // At most PARAMETER_CAPACITY, and call_argument_count at most PARAMETER_CAPACITY.
	result:                u8, // The type of the result, the byte of a Type (function_result_type): None, Integer, Text, Record or Table.
	parameters:            [PARAMETER_CAPACITY]u8, // The type of each parameter, the byte of a Type (function_parameter_type), in the order of the arguments.
	parameter_name_counts: [PARAMETER_CAPACITY]u8, // The bytes of the name of each parameter.
	// The direction of each Table or Bytes parameter, 0 (Read) for each other
	// parameter.
	parameter_directions:  [PARAMETER_CAPACITY]Direction,
	reserved:              [2]u8, // 0.
	text_offset:           u32, // The documentation text of the export, in the string table.
	text_count:            u32, // The bytes of the documentation text.
	// What the type of each parameter needs: Type says what it is. An
	// Integer: what it counts, 0 for a plain number
	// (value_kinds.integer_unit_detail).
	parameter_details:     [PARAMETER_CAPACITY]u32,
	result_detail:         u32, // A Record or Table result: the index of the description of the record.
	// Not 0: the export gives an error record (src/library/contract/errors), and this is
	// the index of its description in the record table. The caller gives one
	// more argument after all the others, after the buffer of a result too:
	// the address of the record. The export writes it when it fails, and only
	// then: it fails when its integer result is negative.
	error_record:          u32,
}
#assert(size_of(Function) == 168)

// call_argument_count gives the arguments of the call form of an export:
// its parameters, one for the buffer of a Text or Table result or the place
// of a Record result, and one for the address of an error record. A
// description is valid only when it is at most PARAMETER_CAPACITY.
//
// Example: an export with 9 parameters, a Text result and an error record
// has 11 arguments.
//
// result is the byte of the type of the result, as Function.result holds it:
// a byte that names no type takes no argument, and the check of the
// description refuses it.
call_argument_count :: proc "contextless" (parameter_count: int, result: u8, has_error_record: bool) -> int {
	return parameter_count + int(result == u8(Type.Text) || result == u8(Type.Table) || result == u8(Type.Record)) + int(has_error_record)
}

RECORD_SIZE_LIMIT :: 256 // The bytes of a record that a call carries.
HANDLE_CAPACITY :: 16 // The handles that one call lends: its Handle parameters, and the Handle fields of its Record parameters.

// The description of a record: a parameter or a result of the type Record.
// Record 0 of the record table is the empty record.
//
// Example: the description of `errors.Error_Record` is the record
// "Error_Record" of 56 bytes, with seven Integer fields of 8 bytes.
Record :: struct {
	name_offset: u32, // In the string table.
	name_count:  u32, // The bytes of the name.
	size:        u32, // In bytes: at most RECORD_SIZE_LIMIT.
	first_field: u32, // An index in the field table. The fields of a record follow each other.
	field_count: u32, // The fields of the record.
	reserved:    u32, // 0.
}
#assert(size_of(Record) == 24)

// One field of a record. A field is an Integer (1, 2, 4 or 8 bytes), a
// Handle (4 bytes) or a Text (detail bytes). An Integer is little-endian,
// at an offset that is a multiple of its size. A Text field holds its
// bytes in the record: UTF-8, and zero bytes after the text; the text ends
// at the first zero byte or at the end of the field. It holds no address,
// so a record still means the same in each process. The fields are in the
// order of their offsets, and no two fields share a byte.
//
// An Integer field can state what it counts, as an Integer parameter does:
// a size or a time, in one unit (docs/MODULE_CONTRACT.md, "The unit of an
// Integer field"). A reader shows the value in the color of that kind, with
// its unit.
//
// Example: the field `time` of the record `Process` of the monitor is an
// Integer of 8 bytes with the integer unit `{.Time, Milliseconds}`.
Field :: struct {
	name_offset:  u32, // In the string table.
	name_count:   u32, // The bytes of the name.
	offset:       u32, // From the start of the record, in bytes.
	type:         u8, // The byte of a Type (field_type): Integer, Handle or Text.
	unsigned:     bool, // An Integer: true for an unsigned integer, false for a signed one.
	integer_unit: value_kinds.Integer_Unit, // An Integer: what it counts, {} for a plain number. {} for a Handle and a Text.
	detail:       u32, // An Integer: its size in bytes, 0 for 8. A Handle: the rights that the callee needs. A Text: its size in bytes.
	reserved:     u32, // 0.
}
#assert(size_of(Field) == 24)

// The documentation of the module, for a reader. Record 1 of the
// documentation table is the documentation of the module. No loader reads it.
//
// The line that says what the module is, and the line of help of an
// export, are plain text: the first sentence of the comment, with no mark.
//
// A documentation text is UTF-8 bytes: the comment of the source, as its
// author wrote it, in a small part of Markdown (docs/TOOLS.md, "The form of
// a documented comment"). Lines that follow each other are one paragraph:
// the reader breaks it at the width that it has. An empty line separates
// two blocks. A line that starts with "- " or with a number and a period is
// a list item. A line that starts with a space, outside a list, and a line
// between two fences of three backticks, are kept as they are. A reader in
// the system reads it with `src/library/private/manual/source_comment_markdown`.
Documentation :: struct {
	about_offset: u32, // One line, in the string table: what the module is.
	about_count:  u32, // The bytes of the line.
	text_offset:  u32, // The documentation text, in the string table.
	text_count:   u32, // The bytes of the text.
}
#assert(size_of(Documentation) == 16)

// The budget that a module asks for: record 1 of the table Budget
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"). It is a
// request, never a grant: the starter of the process accepts it, limits it
// or widens it. A part that is 0 asks for the least budget of that part, and
// a file with no table Budget asks for the least budget. No loader reads it.
// The build writes it: the parts that the source states (system.Stated_Budget)
// and the pages that the tool counts, of the modules, the threads and the
// pictures of the window.
//
// The record can gain fields at its end: a reader reads a part that a
// shorter record does not have as 0, the least.
//
// Example: `{pages = 4096, processes = 1, threads = 2}` asks for 16 MiB, the
// process itself and no child, and two threads.
Budget_Request :: struct {
	pages:    u64, // Pages of memory: its modules, its stacks, its pictures and its working memory.
	processes: u64, // Process slots: the process itself, and each child that runs at one time.
	threads:  u64, // Thread slots: each thread that runs at one time, the first one included, and the threads of its children.
}
#assert(size_of(Budget_Request) == 24)

// The rebase table is not indexed. It is a sequence of 64-bit words in the
// RELR form, and it names the 8-byte locations that hold a memory offset:
//   an even word   is a memory offset: rebase that location; the cursor is
//                  the next location.
//   an odd word    is a bitmap: bit n (1 to 63) set means "rebase the
//                  location at cursor + 8 * (n - 1)"; then the cursor
//                  advances by 63 locations.
REBASE_WORD_SIZE :: 8 // The bytes of one word of the rebase table, and of one location that it names.
REBASE_BITMAP_LOCATIONS :: 63 // The locations that one bitmap word names: its bits 1 to 63.

// The string table is bytes. Its byte 0 is zero, so that offset 0 is no name.
