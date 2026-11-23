// The module format, version 7 (docs/MODULE_CONTRACT.md, sections 1 and 2).
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
// `src/library/modus/system` loads every other module; the console, the process
// `manual` and the site read the descriptions of the exports. The parts:
//
// - `Header`, `Table_Kind`, `Table_Entry`: the frame of a file.
// - `Segment`, `Import`, `Import_Slot`, `Export`, the rebase table: what a loader
//   reads (`load.odin`: `validate`, `rebase`, `bind`).
// - `Function`, `Type`, `Direction`, `Record`, `Field`, `Table_Place`: the
//   call form of an export (docs/MODULE_CONTRACT.md, section 4).
// - `Documentation`: the help of the module and of each export.
// - `Floor`: what its process needs to reach its first state of work
//   (`floor_read`).
// - `Fact`, `Own_Hash_Place` (`facts.odin`): the log facts that the module
//   writes, and the place where a loader writes the hash of the module.
// - `Record_Output`, `Record_Input` (`record_streams.odin`): the record
//   outputs and the record inputs that the module declares.
// - `Enum_Type`, `Member` (`enums.odin`): the enums that the exports take
//   and give, by the names and the values of their members.
// - `Load_Error`, `Load_Stage`, `Difference` (`error.odin`) and `Error`
//   (`load.odin`): why a load failed.
//
// See [module](term:module) and [export](term:export).
package module

import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

MAGIC :: u64(0x0000_454C_5544_4F4D) // The bytes "MODULE", then two zero bytes.
VERSION :: 7 // The version of the format that this code reads and writes. A file of another version is refused. 7: the display texts of the members, the table Member_Texts.
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
// Example: the header of a module with an entry starts with the bytes "MODULE", the
// version 7, the machine `X86_64`, and `entry_export` the index of its
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
	category:        Module_Category, // What the module is to a reader: the manual groups its list by it; the start menu has it from the table of the modules of the tool.
	reserved:        u8, // 0.
	tags:            Module_Tags, // What the module is about: the manual filters on these words.
}
#assert(size_of(Header) == 48)

// The module category: what a module is to a reader, one word for each
// module (docs/glossary/communication.md, "Module category"). The tool
// writes it from the table of the modules, and refuses a category that
// disagrees with the module group, the folder of the source. The manual
// groups the modules of the boot image by it; the start menu reads no
// module file, and its lists come from the same table. No loader and no
// root service decides anything by it. The values cross the border of the file:
// they are fixed.
Module_Category :: enum u8 {
	None           = 0, // The file states no category: a kernel, or a file that a host test writes.
	Application    = 1, // A program of the principal with a window, for the work of the principal: the group applications.
	System_Tool    = 2, // A window that shows or sets the system for the principal: the console, the monitor, the log, the settings, the manual.
	Developer_Tool = 3, // A window that shows how the system runs, for a developer: inspect, the debugger, the pages.
	Service        = 4, // A process with no window of its own, that serves other processes: the root service, the devices, the storage, the compositor.
	Library        = 5, // A module that other modules import or wire: the group libraries.
	Demonstration  = 6, // A module that shows one property of the system to a principal: the group demonstrations.
	Test           = 7, // A module that only a machine test starts or imports: the group tests.
}

// A module tag: one word of what a module is about. The manual filters the
// list of the modules on the words of the tags as on the names. A closed
// set, so that two modules about one thing carry one word.
Module_Tag :: enum u8 {
	Graphics  = 0, // Draws pictures, shapes or text.
	Text      = 1, // Reads, writes or shows text.
	Network   = 2, // Talks to another machine.
	Storage   = 3, // Keeps data on a disk.
	Security  = 4, // Rights, keys, grants, isolation.
	Processes = 5, // Starts, stops, schedules or counts processes.
	Memory    = 6, // Pages, memory objects, address spaces.
	Time      = 7, // Clocks, dates, timers.
	Sound     = 8, // Plays or records sound.
	Input     = 9, // Keys, pointer, devices of input.
	Faults    = 10, // Shows or contains a fault.
	Kernel    = 11, // Shows a mechanism of the kernel.
}
Module_Tags :: bit_set[Module_Tag; u16]
#assert(size_of(Module_Tags) == 2)

// The bits of Module_Tags that name a member, one for each member from bit
// 0: a reader refuses each other.
MODULE_TAG_BITS :: u16(1 << len(Module_Tag) - 1)
#assert(int(max(Module_Tag)) == len(Module_Tag) - 1)

// The number of a table is its index in the table directory.
Table_Kind :: enum u32 {
	None          = 0, // The entry 0 of the directory: no table.
	Segments      = 1, // `Segment` records: the bytes to map.
	Imports       = 2, // `Import` records: the modules that this one calls.
	Import_Slots  = 3, // `Import_Slot` records: the places that receive the address of an imported export.
	Exports       = 4, // `Export` records: the entry points that other modules call.
	Rebases       = 5, // The rebase table: words, not records.
	Functions     = 6, // `Function` records: the call form of each export.
	Strings       = 7, // The string table: bytes.
	Documentation = 8, // `Documentation` records: the help of the module and of each export.
	Records       = 9, // `Record` records: the descriptions of the records that the exports take and give.
	Fields        = 10, // `Field` records: the fields of those records.
	Floor         = 11, // One `Floor` record, at index 1: what the process of the module needs to reach its first state of work.
	Facts         = 12, // `Fact` records: the log facts that the module writes, sorted by fact key.
	Own_Hash      = 13, // One `Own_Hash_Place` record, at index 1: where a loader writes the hash of the module.
	Record_Outputs = 14, // `Record_Output` records: the record outputs that the module declares, sorted by name.
	Record_Inputs  = 15, // `Record_Input` records: the record inputs that the module declares, sorted by name.
	Enums          = 16, // `Enum_Type` records: the descriptions of the enums that the exports take and give.
	Members        = 17, // `Member` records: the members of those enums.
	Member_Texts   = 18, // `Member_Text` records: the display text of a member in a language, in the order of the enum, the member and the language.
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
	Read_Only_After_Load = 3, // The loader writes it (rebases, import slots), then removes Write.
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
Import_Slot :: struct {
	memory_offset: u64, // The place of the 8 bytes, from the base of the module.
	import_index:  u32, // An index in the import table, from 1.
	export_index:  u32, // An index in the export table of that module, from 1.
}
#assert(size_of(Import_Slot) == 16)

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
	// writes the record there. The export has no integer value: an export
	// that can fail gives its call outcome alone.
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
	Bytes   = 6, // Bytes with no description. A parameter: with a Direction.
	// The address of a Table_Place in memory of the caller, where the
	// count and the capacity are in bytes. The detail is 0.
	// A field of a record: detail bytes in the record, of the field kind
	// Hash only (Field.kind): a reader has no form for other bytes.
	Enum    = 7, // One member of a closed set, as its value, in a register (enums.odin).
	// A parameter: the detail names the description of the enum in the
	// table Enums and the export that gives the value in use
	// (enum_detail_of). An optional parameter that a call leaves out gets
	// the absent word (enum_absent_word). A result: the detail is the
	// index of the description of the enum, and the callee gives the value
	// in the low bytes of its integer result. A field of a record is never
	// an Enum.
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

// direction_of_word is the border of the byte of a Direction in a module
// file (Function.parameter_directions, Described.direction): the member,
// or false for a byte that names no direction.
direction_of_word :: proc "contextless" (word: u8) -> (direction: Direction, ok: bool) {
	return enum_word.member_of_word(Direction, u64(word))
}

// function_parameter_direction reads the direction of the parameter index
// of an export through the border: false for an index past
// PARAMETER_CAPACITY or negative, and for a byte that names no direction.
function_parameter_direction :: proc "contextless" (function: Function, index: int) -> (direction: Direction, ok: bool) {
	if index < 0 || index >= PARAMETER_CAPACITY {
		return {}, false
	}
	return direction_of_word(function.parameter_directions[index])
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
	// The direction of each Table or Bytes parameter, the byte of a
	// Direction (function_parameter_direction), 0 (Read) for each other
	// parameter.
	parameter_directions:  [PARAMETER_CAPACITY]u8,
	// Bit n: a call may leave out the parameter n, an Enum. The other
	// bits are 0 (function_enums_check).
	optional_parameters:   u16,
	text_offset:           u32, // The documentation text of the export, in the string table.
	text_count:            u32, // The bytes of the documentation text.
	// What the type of each parameter needs: Type says what it is. An
	// Integer: what it counts, 0 for a plain number
	// (value_kinds.integer_unit_detail).
	parameter_details:     [PARAMETER_CAPACITY]u32,
	result_detail:         u32, // A Record or Table result: the index of the description of the record. An Enum result: the index of the description of the enum.
	// Not 0: the export gives an error record (src/library/modus/contract/errors), and this is
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
// Handle (4 bytes), a Text (detail bytes) or Bytes (detail bytes, a hash).
// An Integer is little-endian, at an offset that is a multiple of its
// size. A Text field holds its bytes in the record: UTF-8, and zero bytes
// after the text; the text ends at the first zero byte or at the end of
// the field. It holds no address, so a record still means the same in
// each process. The fields are in the order of their offsets, and no two
// fields share a byte.
//
// An Integer field can state what it counts, as an Integer parameter does:
// a size or a time, in one unit (docs/MODULE_CONTRACT.md, "The unit of an
// Integer field"). A reader shows the value in the color of that kind, with
// its unit.
//
// A field can state its field kind: how a reader writes its value
// (docs/MODULE_CONTRACT.md, "The kind of a field"). field_kind_valid says
// which kind each type takes.
//
// Example: the field `time` of the record `Process` of the monitor is an
// Integer of 8 bytes with the integer unit `{.Time, Milliseconds}`; a field
// `level: operation.Log_Level` is an unsigned Integer of 1 byte with the
// kind Status and the contract enum Log_Level.
Field :: struct {
	name_offset:   u32, // In the string table.
	name_count:    u32, // The bytes of the name.
	offset:        u32, // From the start of the record, in bytes.
	type:          u8, // The byte of a Type (field_type): Integer, Handle, Text or Bytes.
	unsigned:      bool, // An Integer: true for an unsigned integer, false for a signed one.
	integer_unit:  value_kinds.Integer_Unit, // An Integer: what it counts, {} for a plain number. {} for a Handle, a Text and Bytes, and beside a field kind.
	detail:        u32, // An Integer: its size in bytes, 0 for 8. A Handle: the rights that the callee needs. A Text or Bytes: its size in bytes.
	kind:          u8, // The byte of a value_kinds.Field_Kind (field_kind): how a reader writes the value. 0 is Plain.
	contract_enum: u8, // A Status: the byte of a value_kinds.Contract_Enum (field_contract_enum). 0 (None) for each other field.
	reserved:      [2]u8, // 0.
}
#assert(size_of(Field) == 24)
// A hash field holds at most a hash of a module.
#assert(value_kinds.HASH_FIELD_BYTES == HASH_SIZE)

// field_kind reads the field kind of a field through the border: false for
// a byte that names no kind.
field_kind :: proc "contextless" (item: Field) -> (kind: value_kinds.Field_Kind, ok: bool) {
	return value_kinds.field_kind_of_word(item.kind)
}

// field_contract_enum reads the contract enum of a field through the
// border: false for a byte that names no enum.
field_contract_enum :: proc "contextless" (item: Field) -> (which: value_kinds.Contract_Enum, ok: bool) {
	return value_kinds.contract_enum_of_word(item.contract_enum)
}

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
// the system reads it with `src/library/internal/manual/source_comment_markdown`.
Documentation :: struct {
	about_offset: u32, // One line, in the string table: what the module is.
	about_count:  u32, // The bytes of the line.
	text_offset:  u32, // The documentation text, in the string table.
	text_count:   u32, // The bytes of the text.
}
#assert(size_of(Documentation) == 16)

// The floor of a module: record 1 of the table Floor
// (src/md/features/module_budget_request.md, "The chosen form"). It is what
// the process needs to reach its first state of work, a fact of the module
// and of the build, never a grant: the starter adds the parts of the
// machine and of the plan to it (the floor of a start), reserves it, and
// gives a size from its own policy (system.budget_size). The build writes
// it for each module with an entry: the parts that the source states
// (system.Stated_Budget, its start objects and its children) and the pages
// that the tool counts. A file with no table Floor does not start: before
// 1.0 nothing is kept for an older tool. No loader reads it.
//
// Example: `{pages = 4096, processes = 1, threads = 2}` needs 16 MiB, the
// process itself and no child, and two threads.
Floor :: struct {
	pages:    u64, // Pages of memory: its modules, their load, its stacks, its pictures, its start objects, the floors of its children and its working memory.
	processes: u64, // Process slots: the process itself, and each child that runs at one time. At least 1.
	threads:  u64, // Thread slots: each thread that runs at one time, the first one included, and the threads of its children. At least 1.
	// Pictures of the size of the screen in force, 4 bytes a pixel, that the
	// process holds: the copies of a screen of the compositor and of the
	// remote display. A build cannot know the screen, so the starter adds
	// their pages for the screen of the machine (floor_of_screen),
	// and a 4K machine pays a 4K screen. SCREEN_PICTURES_LIMIT at most.
	screen_pictures: u64,
	// The pages of the rings of the wirings that the process asks for, in
	// pages: the root service carves its wiring budget to that measure at
	// its first wiring. 0: half of pages. A shorter record of an older file
	// reads 0 (src/md/features/module_outputs.md, "The bounds of the wirings").
	wiring_pages: u64,
}
#assert(size_of(Floor) == 40)

// The most screen pictures that a module asks for: the compositor holds
// two, the remote display three.
SCREEN_PICTURES_LIMIT :: 4

// screen_picture_pages gives the pages of one picture of a screen, 4 bytes a
// pixel, the last page whole.
screen_picture_pages :: proc "contextless" (width, height: u64) -> u64 {
	return (width * height * 4 + PAGE_SIZE - 1) / PAGE_SIZE
}

// floor_of_screen gives the floor of a module with the pages of its screen
// pictures added, for a screen of width x height: a part of the floor of a
// start. plan_screen_pages is the most pages that a row
// of the plan of principal 0 gives these pictures, 0 for no row: the screen
// is a fact of the machine, and its cost a machine policy, which a plan may
// lower and never raise. ok is false for a floor of more than
// SCREEN_PICTURES_LIMIT pictures, or a screen whose pages pass 64 bits:
// the starter refuses the module, as a file that is not valid.
//
// Example: 3 pictures of 3840 x 2160 add 3 x 8100 pages; with a plan row of
// 10 000 pages they add 10 000.
floor_of_screen :: proc "contextless" (floor: Floor, width, height: u64, plan_screen_pages: u64 = 0) -> (with_screen: Floor, ok: bool) {
	if floor.screen_pictures > SCREEN_PICTURES_LIMIT || width > 1 << 20 || height > 1 << 20 {
		return {}, false
	}
	screen := floor.screen_pictures * screen_picture_pages(width, height)
	if plan_screen_pages != 0 {
		screen = min(screen, plan_screen_pages)
	}
	with_screen = floor
	with_screen.pages += screen
	with_screen.screen_pictures = 0
	if with_screen.pages < floor.pages {
		return {}, false
	}
	return with_screen, true
}

// The largest budget of a process of the boot image is a share of the
// memory and of the threads of the machine: no size passes it, and a floor
// above it is the size (largest_budget_of_machine, system.budget_size).
// Until the growth exists, the share is the most that a start gets. The share is a value of
// the plan of principal 0, because it spends a resource of the machine
// (src/md/features/module_budget_request.md): a share of n gives one
// process at most 1/n of the machine. With no value in the plan, the share
// is one quarter, so the largest process leaves three quarters to the
// others.
LARGEST_BUDGET_SHARE_DEFAULT :: 4
// The share of a plan: 1 (one process can take the whole machine) to 64.
LARGEST_BUDGET_SHARE_LEAST :: 1
LARGEST_BUDGET_SHARE_MOST :: 64

// budget_share_of_word is the border of the share that a plan gives: the
// share, or false for a word below LARGEST_BUDGET_SHARE_LEAST or above
// LARGEST_BUDGET_SHARE_MOST. A refused word changes no budget.
budget_share_of_word :: proc "contextless" (word: u64) -> (share: u64, ok: bool) {
	if word < LARGEST_BUDGET_SHARE_LEAST || word > LARGEST_BUDGET_SHARE_MOST {
		return 0, false
	}
	return word, true
}
// The least largest budget: what a process of the boot image can always
// get, on the smallest machine that the system supports. A module that
// sizes its memory to run on any machine checks its sum against these
// pages at compile time.
LARGEST_BUDGET_LEAST_PAGES :: 16384
LARGEST_BUDGET_LEAST :: op.Budget_Amounts{pages = LARGEST_BUDGET_LEAST_PAGES, processes = 8, threads = 32}

// The size of a budget with no row of the plan is the floor of its start
// times this factor (system.budget_size). A value of the plan of principal
// 0, default_growth_factor, because the size spends the memory of the
// machine; 2 is its default: a process can double its start memory before
// it needs a growth or a row, and its default follows its real need, not a
// fixed count (src/md/features/module_budget_request.md, "The size, part
// by part"). The plan carries no such row yet, so the starter reads this
// default.
DEFAULT_GROWTH_FACTOR :: 2

// growth_factor_of_word is the border of the growth factor that a plan
// gives: the factor, or false for 0, which would give a size below the
// floor. A factor of 1 gives the floor alone. No upper border: a size never
// passes the share of the machine (system.budget_size).
growth_factor_of_word :: proc "contextless" (word: u64) -> (factor: u64, ok: bool) {
	if word == 0 {
		return 0, false
	}
	return word, true
}

// The least machine that the system supports, and the machine of the
// machine tests: 1 GiB (the tool checks it against its machine), whose root
// service holds at least 200 000 pages at its start, less the kernel. The
// tool proves at the build that the floors of the default start list fit
// in these pages (start_lists.odin), so the default image starts there.
TEST_MACHINE_MEMORY_MIB :: 1024
TEST_MACHINE_ROOT_PAGES :: 200_000
TEST_MACHINE_LARGEST_BUDGET_PAGES :: TEST_MACHINE_ROOT_PAGES / LARGEST_BUDGET_SHARE_DEFAULT
#assert(TEST_MACHINE_ROOT_PAGES <= TEST_MACHINE_MEMORY_MIB * 256)

// largest_budget_of_machine gives the largest budget of a process of the
// boot image on a machine whose root service holds machine at its start:
// one share of its pages and of its threads, never less than
// LARGEST_BUDGET_LEAST, and never more threads than a process holds
// (op.THREAD_CAPACITY). share passed its border (budget_share_of_word).
//
// Example: 200 000 pages and 1023 threads (a machine of 1 GiB) with the
// share 4 give 50 000 pages and 255 threads; 0 pages give 16 384.
largest_budget_of_machine :: proc "contextless" (machine: op.Budget_Amounts, share: u64) -> op.Budget_Amounts {
	parts := max(share, LARGEST_BUDGET_SHARE_LEAST)
	largest := LARGEST_BUDGET_LEAST
	largest.pages = max(machine.pages / parts, LARGEST_BUDGET_LEAST_PAGES)
	largest.threads = clamp(machine.threads / parts, LARGEST_BUDGET_LEAST.threads, op.THREAD_CAPACITY)
	return largest
}

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
