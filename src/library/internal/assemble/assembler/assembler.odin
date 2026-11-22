// The assembler: a text of x86-64 assembly in the syntax of AT&T becomes
// the parts of a module file (docs/MODULE_CONTRACT.md, "The assembler").
// The design is src/md/features/assembler.md.
//
// The module `assemble` alone compiles it in. It allocates nothing and
// calls no kernel operation: the caller gives a `Workspace`, and gives the
// parts to the module file writer.
//
// ```odin
// parts, refusal := assembler.assemble("export one() -> Integer; one: mov $1, %rax; ret", &workspace)
// size, needed := module_file_writer.file_size_needed(parts)
// ```
//
// A text that the package does not assemble whole is refused with a
// `Refusal_Record`: what is wrong, its line and its column from 1, and its
// offset in the text. No part of a refused text is given.
package assembler

import "base:intrinsics"
import module "modus:contract/module"
import writer "modus:contract/module_file_writer"

// The bounds of a text. A bound is a cost that the workspace pays, not a
// rule of the language. The caller gives the memory of the workspace, so
// it chooses the bounds of the code, the data and the tables
// (workspace_make). The bounds below are those of `Workspace_Memory` and
// of the tier Unit, sized for a text of 256 KiB that chibicc writes: about
// 20 bytes of text for each instruction of about 5 bytes, a label for each
// 10 lines, a reference for each 5. The module `assemble` carves a
// workspace of a tier from an arena for each call (workspace_carve), which
// the budget of its call host pays (src/md/features/assembler.md, "The
// bounds of the workspace").
TEXT_BYTES_MOST :: 1 << 24 // The bytes of a text: a place counts its offset in 32 bits.
LINE_BYTES_MOST :: 1024 // The bytes of one line, its comment included.
CODE_BYTES_MOST :: 128 * 1024 // The bytes of the section code that a file stores.
DATA_BYTES_MOST :: 128 * 1024 // The bytes of the section data that a file stores.
// The extent of a section with its zero bytes: `zero` adds to it and
// writes no byte.
SECTION_EXTENT_MOST :: u64(1) << 40
LABEL_CAPACITY :: 2048
// The slots of the table of the names of the labels: a power of two, with
// room for each label and for the second slot of each global label, at
// most half full.
LABEL_SLOTS_PER_LABEL :: 4
REFERENCE_CAPACITY :: 4096 // The operands that name a label.
EXPORT_CAPACITY :: 32
REBASE_CAPACITY :: 2048 // The `quad` values that name a label: each is one rebase of the module.
LOCAL_LABEL_DIGITS :: 10 // The numeric local labels `0:` to `9:`.
// The largest alignment of `align`: the section data starts on a page, so
// an alignment of a page or less is exact in memory.
ALIGNMENT_MOST :: module.PAGE_SIZE

// The sections of a text. The section code comes first in the module, at
// the offset 0; the section data follows it on the next page.
Section :: enum u8 {
	Code = 0, // Instructions: a segment with Read and Execute.
	Data = 1, // Bytes: a segment with Read and Write.
}

// What is wrong with a text. The values are fixed: a test and a caller name
// the member, and the module `assemble` writes the number on its log.
Refusal :: enum u32 {
	None                   = 0, // The text is assembled.
	Text_Empty             = 1, // The text has no byte.
	Text_Too_Long          = 2, // The text has more than TEXT_BYTES_MOST bytes. value: its bytes.
	Line_Too_Long          = 3, // A line has more than LINE_BYTES_MOST bytes. value: its bytes.
	Character_Not_Valid    = 4, // A control byte other than a tab, or a byte past ASCII outside a comment. value: the byte.
	Mnemonic_Unknown       = 5, // The first word of a statement is no instruction of the subset and no directive.
	Register_Unknown       = 6, // A word after `%` names no register.
	Operand_Not_Valid      = 7, // An operand that the syntax does not read: no `)`, invalid scale, `%rsp` as index, an absolute address, `%rip` alone.
	Operand_Count_Wrong    = 8, // The instruction takes another count of operands. value: the count given.
	Operand_Form_Not_Valid = 9, // The instruction has no form with these kinds of operands: memory to memory, `push` of memory, `lea` of a register.
	Operand_Size_Wrong     = 10, // Two sizes disagree (a suffix and a register, two registers), or the form has no such size (`push %eax`).
	Operand_Size_Unknown   = 11, // No register and no suffix gives the size: `mov $1, (%rax)`.
	Immediate_Too_Large    = 12, // An immediate, or a value of `byte`, does not fit its field.
	Displacement_Too_Large = 13, // A displacement does not fit in 32 bits with a sign.
	Number_Not_Valid       = 14, // A number has no digit, or a byte that is no digit of its base.
	Label_Not_Valid        = 15, // A label starts with a digit, or has more than writer.NAME_BYTES_MOST bytes.
	Label_Defined_Twice    = 16, // A label is defined a second time. value: the line of the first definition.
	Label_Not_Defined      = 17, // An operand or an export names a label that the text never defines. The place is its first use.
	Label_In_Wrong_Section = 18, // A jump or a call names a label of the data, or an export a label that is not in the code.
	Distance_Too_Large     = 19, // A jump, a call or a `%rip` operand is more than 2 GiB from its label. value: the offset of the label in the module.
	Section_Unknown        = 20, // `section` names neither `code` nor `data`.
	Section_Past_Capacity  = 21, // A section passes the bytes of its buffer in the workspace, or SECTION_EXTENT_MOST of extent. value: the bytes that it would reach.
	Instruction_In_Data    = 22, // An instruction in the section data, which no processor runs.
	Directive_Not_Valid    = 23, // A directive with a wrong form: a missing `(`, `:` or `,`, words after its end.
	Type_Unknown           = 24, // A type of an export that the assembler does not take: parameters Integer and Text, the result Integer.
	Too_Many_Parameters    = 25, // An export with more than module.PARAMETER_CAPACITY parameters.
	Export_Twice           = 26, // Two exports have one name.
	Name_Not_Valid         = 27, // The name of an export or of a parameter is not a name of the module format.
	Labels_Full            = 28, // More labels than the workspace holds. value: its capacity.
	References_Full        = 29, // More operands that name a label than the workspace holds. value: its capacity.
	Exports_Full           = 30, // More than EXPORT_CAPACITY exports.
	No_Instruction         = 31, // The text has no byte in the section code.
	Rebase_Not_In_Data     = 32, // A `quad` names a label in the section code: a loader rebases writable data only.
	Rebase_Not_Aligned     = 33, // A `quad` that names a label is not on 8 bytes of the section data. value: its offset in the section.
	Rebases_Full           = 34, // More `quad` values that name a label than the workspace holds. value: its capacity.
	Address_Out_Of_Range   = 35, // A label with its offset is below 0 or past 2^63 - 1. value: the address with no sign, modulo 2^64.
	Global_Twice           = 36, // Two units make one name global. value: the line of the first `global`.
	Alignment_Not_Valid    = 37, // `align` takes a power of two from 1 to ALIGNMENT_MOST. value: the number, at most 2^64.
}

// Where a refusal is in the text: its first byte.
Place :: struct {
	line:   u32, // From 1.
	column: u32, // From 1, in bytes.
	offset: u32, // From 0, in bytes from the start of the text.
}

// The refusal of a text, and where it is.
Refusal_Record :: struct {
	refusal: Refusal,
	place:   Place,
	value:   u64, // What the member of Refusal says.
}

// A label: a name of a unit and its place in a section. A label that an
// operand names before its definition is in the table with defined false.
// A label of a unit that the unit never defines takes the place of the
// global label of that name, once the text is read.
Label :: struct {
	name:       string, // A view of the text.
	unit:       u32, // The unit of the text that names it: 0 before the first `unit`.
	global:     bool, // A `global` of its unit names it: the other units see it.
	global_at:  Place, // The first `global` that names it.
	section:    Section,
	offset:     u64, // From the start of its section.
	defined:    bool,
	first_use:  Place, // Where the text names it first: its definition or an operand.
	defined_at: Place, // Its definition, when defined.
	// A numeric local label (`1:`) has no name of its own: the text defines
	// the digit many times, and `1f` or `1b` names one definition by its
	// order among the definitions of that digit.
	local:         bool,
	local_digit:   u8,
	local_ordinal: u32, // From 0: the definitions of the digit before this one.
}

// What the 4 bytes of a reference hold, once the label is placed.
Reference_Kind :: enum u8 {
	Jump_Target = 0, // The distance from the end of a jump or a call to a label of the code.
	Address     = 1, // The distance from the end of an instruction to the label of a `%rip` operand.
}

// An operand that names a label: 4 bytes of the code that the assembler
// writes once each label is placed.
Reference :: struct {
	label:           int, // The index of the label.
	kind:            Reference_Kind,
	field_offset:    u64, // The 4 bytes, from the start of the code.
	instruction_end: u64, // The end of the instruction, from the start of the code: the distance counts from there.
	place:           Place, // The operand.
}

// A `quad` that names a label: 8 bytes of the data that hold the address
// of the label in the module, which a loader rebases.
Data_Reference :: struct {
	label:       int, // The index of the label.
	addend:      i64, // The number after the label: `quad table + 16`.
	data_offset: u64, // The 8 bytes, from the start of the section data.
	place:       Place, // The operand.
}

// An export as the directive declares it.
Export_Declaration :: struct {
	name:            string,
	parameters:      [module.PARAMETER_CAPACITY]module.Type,
	parameter_names: [module.PARAMETER_CAPACITY]string,
	parameter_count: int,
	result:          module.Type,
	unit:            u32, // The unit of the directive: its label is a label of that unit, or a global label.
	place:           Place, // The name in the directive.
}

// A slot of the table of the names of the labels. A label has one slot
// for its unit and its name, a numeric local label one for its digit and
// its order, and a global label a second slot under GLOBAL_UNIT, where a
// label of another unit finds it.
Label_Slot :: struct {
	label: i32, // The index of the label, plus 1: 0 is an empty slot.
	unit:  u32, // The unit of the key: a unit of the text, GLOBAL_UNIT or LOCAL_LABEL_UNIT.
}

// The keys of the slots that are not the name of a unit.
GLOBAL_UNIT :: max(u32)
LOCAL_LABEL_UNIT :: max(u32) - 1

// The memory of one assembly, which the caller gives through
// workspace_make: the buffers of the sections and the tables are its
// slices, and their lengths are the bounds of a text. `assemble` resets
// the counts first. The parts that `assemble` gives are views of it and of
// the text: both must stay until the file is written.
Workspace :: struct {
	code:            []u8,
	data:            []u8,
	extents:         [Section]u64, // The place of the next byte of each section.
	stored:          [Section]u64, // The bytes of each section in its buffer: the zero bytes after them are not stored.
	labels:          []Label,
	label_count:     int,
	label_slots:     []Label_Slot, // A power of two of slots, LABEL_SLOTS_PER_LABEL for each label.
	references:      []Reference,
	reference_count: int,
	exports:         [EXPORT_CAPACITY]Export_Declaration,
	export_count:    int,
	data_references:      []Data_Reference,
	data_reference_count: int,
	rebases:              []u64, // The memory offset of each data reference, in the order of the data.
	// The definitions of each digit so far: `Nb` names the last one, `Nf`
	// the next one.
	local_label_definitions: [LOCAL_LABEL_DIGITS]u32,
	unit:            u32, // The unit of the statements from here: each `unit` adds 1.
	segments:        [2]writer.Segment_Part, // The code, and the data when the text has data.
	export_parts:    [EXPORT_CAPACITY]writer.Export_Part,
}

// The memory of a workspace with the bounds of the constants above, the
// tier Unit as one record: a host program and a host test take one.
Workspace_Memory :: struct {
	code:            [CODE_BYTES_MOST]u8,
	data:            [DATA_BYTES_MOST]u8,
	labels:          [LABEL_CAPACITY]Label,
	label_slots:     [LABEL_CAPACITY * LABEL_SLOTS_PER_LABEL]Label_Slot,
	references:      [REFERENCE_CAPACITY]Reference,
	data_references: [REBASE_CAPACITY]Data_Reference,
	rebases:         [REBASE_CAPACITY]u64,
}

// workspace_make gives a workspace over memory of the caller. The label
// slots are cut to a power of two, and the labels to the slots that they
// need; the rebases to the data references, one for each.
workspace_make :: proc "contextless" (code: []u8, data: []u8, labels: []Label, label_slots: []Label_Slot, references: []Reference, data_references: []Data_Reference, rebases: []u64) -> Workspace {
	slot_count := 1
	for slot_count * 2 <= len(label_slots) {
		slot_count *= 2
	}
	if len(label_slots) == 0 {
		slot_count = 0
	}
	label_count := min(len(labels), slot_count / LABEL_SLOTS_PER_LABEL)
	reference_count := min(len(data_references), len(rebases))
	return {
		code            = code,
		data            = data,
		labels          = labels[:label_count],
		label_slots     = label_slots[:slot_count],
		references      = references,
		data_references = data_references[:reference_count],
		rebases         = rebases[:reference_count],
	}
}

// The two sizes of a workspace that the module `assemble` carves from an
// arena for one call (src/md/features/assembler.md, "The bounds of the
// workspace"). The arena is made at the call and ended at its return, so the
// module keeps no table between calls.
Workspace_Tier :: enum u8 {
	Unit    = 0, // The bounds of Workspace_Memory: a text of one source, which a call host of the default budget pays.
	Program = 1, // The bounds of a program of many units, such as chibicc: 295 KiB of code, 52 KiB of data, 6928 labels.
}

// The bounds of a workspace: the lengths of its slices.
Workspace_Bounds :: struct {
	code_bytes: u64,
	data_bytes: u64,
	labels:     u64, // The label slots are LABEL_SLOTS_PER_LABEL for each label: labels times that is a power of two.
	references: u64,
	rebases:    u64, // The data references, one for each rebase.
}

// The bounds of each tier. Each bound of Program is at least the bound of
// Unit, so a text that Unit holds, Program holds.
@(rodata)
WORKSPACE_BOUNDS := [Workspace_Tier]Workspace_Bounds {
	.Unit    = {code_bytes = CODE_BYTES_MOST, data_bytes = DATA_BYTES_MOST, labels = LABEL_CAPACITY, references = REFERENCE_CAPACITY, rebases = REBASE_CAPACITY},
	.Program = {code_bytes = PROGRAM_CODE_BYTES_MOST, data_bytes = PROGRAM_DATA_BYTES_MOST, labels = PROGRAM_LABEL_CAPACITY, references = PROGRAM_REFERENCE_CAPACITY, rebases = PROGRAM_REBASE_CAPACITY},
}

// The bounds of the tier Program: each is past the measure of chibicc by
// a factor of 1.7 or more (8505 operands that name a label, 246 rebases).
PROGRAM_CODE_BYTES_MOST :: 512 * 1024
PROGRAM_DATA_BYTES_MOST :: 128 * 1024
PROGRAM_LABEL_CAPACITY :: 16 * 1024
PROGRAM_REFERENCE_CAPACITY :: 16 * 1024
PROGRAM_REBASE_CAPACITY :: 2048
// The bytes of a text that the module `assemble` takes: a program of many
// units. chibicc and its jump.s join into about 2 MiB of text.
PROGRAM_TEXT_BYTES_MOST :: 4 * 1024 * 1024
// The bytes of a text up to which the module starts with the tier Unit: the
// bound of a text before the tier Program existed.
UNIT_TEXT_BYTES_MOST :: 256 * 1024

#assert(PROGRAM_TEXT_BYTES_MOST <= TEXT_BYTES_MOST)
#assert(PROGRAM_CODE_BYTES_MOST >= CODE_BYTES_MOST && PROGRAM_DATA_BYTES_MOST >= DATA_BYTES_MOST)
#assert(PROGRAM_LABEL_CAPACITY >= LABEL_CAPACITY && PROGRAM_REFERENCE_CAPACITY >= REFERENCE_CAPACITY && PROGRAM_REBASE_CAPACITY >= REBASE_CAPACITY)
#assert((PROGRAM_LABEL_CAPACITY * LABEL_SLOTS_PER_LABEL) & (PROGRAM_LABEL_CAPACITY * LABEL_SLOTS_PER_LABEL - 1) == 0)
#assert((LABEL_CAPACITY * LABEL_SLOTS_PER_LABEL) & (LABEL_CAPACITY * LABEL_SLOTS_PER_LABEL - 1) == 0)

// The alignment of the memory that workspace_carve takes, and of each table
// in it: the largest alignment of a record of the tables.
WORKSPACE_ALIGNMENT :: max(align_of(Label), align_of(Reference), align_of(Data_Reference), align_of(u64), align_of(Label_Slot))

// workspace_layout gives the offset of each slice of a workspace of these
// bounds in one block of memory, and the bytes of the block. The tables come
// first, each on WORKSPACE_ALIGNMENT, then the code and the data.
@(private)
Workspace_Layout :: struct {
	labels, label_slots, references, data_references, rebases, code, data, total: u64,
}

@(private)
workspace_layout :: proc "contextless" (bounds: Workspace_Bounds) -> Workspace_Layout {
	place :: proc "contextless" (cursor: ^u64, bytes: u64) -> u64 {
		start := (cursor^ + WORKSPACE_ALIGNMENT - 1) & ~u64(WORKSPACE_ALIGNMENT - 1)
		cursor^ = start + bytes
		return start
	}
	layout: Workspace_Layout
	cursor: u64
	layout.labels = place(&cursor, bounds.labels * size_of(Label))
	layout.label_slots = place(&cursor, bounds.labels * LABEL_SLOTS_PER_LABEL * size_of(Label_Slot))
	layout.references = place(&cursor, bounds.references * size_of(Reference))
	layout.data_references = place(&cursor, bounds.rebases * size_of(Data_Reference))
	layout.rebases = place(&cursor, bounds.rebases * size_of(u64))
	layout.code = place(&cursor, bounds.code_bytes)
	layout.data = place(&cursor, bounds.data_bytes)
	layout.total = cursor
	return layout
}

// workspace_bytes gives the bytes of the memory that a workspace of a tier
// takes in workspace_carve.
workspace_bytes :: proc "contextless" (tier: Workspace_Tier) -> u64 {
	return workspace_layout(WORKSPACE_BOUNDS[tier]).total
}

// workspace_carve gives a workspace of a tier over one block of memory of
// the caller. ok is false, and the workspace is zero, when the block has
// fewer bytes than workspace_bytes(tier) or its address is not a multiple
// of WORKSPACE_ALIGNMENT. The block must be zero or hold the bytes of an
// earlier workspace: assemble zeroes the label slots first.
workspace_carve :: proc "contextless" (memory: []u8, tier: Workspace_Tier) -> (workspace: Workspace, ok: bool) {
	bounds := WORKSPACE_BOUNDS[tier]
	layout := workspace_layout(bounds)
	if u64(len(memory)) < layout.total || uintptr(raw_data(memory)) & (WORKSPACE_ALIGNMENT - 1) != 0 {
		return {}, false
	}
	base := raw_data(memory)
	return workspace_make(
		code = base[layout.code:][:bounds.code_bytes],
		data = base[layout.data:][:bounds.data_bytes],
		labels = ([^]Label)(&base[layout.labels])[:bounds.labels],
		label_slots = ([^]Label_Slot)(&base[layout.label_slots])[:bounds.labels * LABEL_SLOTS_PER_LABEL],
		references = ([^]Reference)(&base[layout.references])[:bounds.references],
		data_references = ([^]Data_Reference)(&base[layout.data_references])[:bounds.rebases],
		rebases = ([^]u64)(&base[layout.rebases])[:bounds.rebases],
	), true
}

// refusal_is_capacity says if a refusal is a bound of the workspace that a
// larger tier can pass: a section past its buffer, or a full table. The
// value of Section_Past_Capacity past SECTION_EXTENT_MOST is no bound of the
// buffer, and the larger tier refuses it again.
refusal_is_capacity :: proc "contextless" (refusal: Refusal) -> bool {
	return refusal in CAPACITY_REFUSALS
}

// The refusals of a bound of the workspace.
CAPACITY_REFUSALS :: bit_set[Refusal]{.Section_Past_Capacity, .Labels_Full, .References_Full, .Rebases_Full}

// workspace_of_memory gives the workspace of a Workspace_Memory.
workspace_of_memory :: proc "contextless" (memory: ^Workspace_Memory) -> Workspace {
	return workspace_make(memory.code[:], memory.data[:], memory.labels[:], memory.label_slots[:], memory.references[:], memory.data_references[:], memory.rebases[:])
}

// workspace_reset sets the counts of a workspace to zero, and empties its
// table of names. The buffers keep their bytes: each byte that a part
// gives is written by this assembly.
workspace_reset :: proc "contextless" (workspace: ^Workspace) {
	workspace.extents = {}
	workspace.stored = {}
	workspace.label_count = 0
	workspace.reference_count = 0
	workspace.export_count = 0
	workspace.data_reference_count = 0
	workspace.local_label_definitions = {}
	workspace.unit = 0
	workspace.segments = {}
	if len(workspace.label_slots) > 0 {
		intrinsics.mem_zero(raw_data(workspace.label_slots), len(workspace.label_slots) * size_of(Label_Slot))
	}
}

// assemble reads a text and gives the parts of its module file: the
// segment of the code at the offset 0, the segment of the data after it
// when the text has data, and one export for each `export`. The parts are
// views of the workspace and of the text.
assemble :: proc "contextless" (text: string, workspace: ^Workspace) -> (parts: writer.Module_Parts, refusal: Refusal_Record) {
	workspace_reset(workspace)
	if len(text) == 0 {
		return {}, {refusal = .Text_Empty, place = {line = 1, column = 1}}
	}
	if len(text) > TEXT_BYTES_MOST {
		return {}, {refusal = .Text_Too_Long, place = place_of_offset(text, TEXT_BYTES_MOST), value = u64(len(text))}
	}
	if refusal = statements_read(text, workspace); refusal.refusal != .None {
		return {}, refusal
	}
	if workspace.extents[.Code] == 0 {
		return {}, {refusal = .No_Instruction, place = {line = 1, column = 1}}
	}
	if refusal = references_resolve(workspace); refusal.refusal != .None {
		return {}, refusal
	}
	return parts_fill(workspace)
}

// refusal_sentence gives the words of a refusal for a line of the log.
refusal_sentence :: proc "contextless" (refusal: Refusal) -> string {
	switch refusal {
	case .None:
		return "the text is assembled"
	case .Text_Empty:
		return "the text is empty"
	case .Text_Too_Long:
		return "the text has more than 16 MiB"
	case .Line_Too_Long:
		return "the line has more than 1024 bytes"
	case .Character_Not_Valid:
		return "a control byte, or a byte past ASCII outside a comment"
	case .Mnemonic_Unknown:
		return "no instruction of the subset and no directive has this name"
	case .Register_Unknown:
		return "no register has this name"
	case .Operand_Not_Valid:
		return "the operand has no form of the syntax: a register, $number, a memory operand, *operand, or a label"
	case .Operand_Count_Wrong:
		return "the instruction takes another count of operands"
	case .Operand_Form_Not_Valid:
		return "the instruction has no form with these kinds of operands"
	case .Operand_Size_Wrong:
		return "the sizes of the operands disagree, or the instruction has no form of this size"
	case .Operand_Size_Unknown:
		return "no register and no suffix gives the size of the operation"
	case .Immediate_Too_Large:
		return "the value does not fit its field"
	case .Displacement_Too_Large:
		return "the displacement does not fit in 32 bits with a sign"
	case .Number_Not_Valid:
		return "the number has a byte that is no digit"
	case .Label_Not_Valid:
		return "the label starts with a digit, or has more than 255 bytes"
	case .Label_Defined_Twice:
		return "the label is defined a second time"
	case .Label_Not_Defined:
		return "the text never defines this label"
	case .Label_In_Wrong_Section:
		return "a jump, a call and an export name a label of the code only"
	case .Distance_Too_Large:
		return "the label is more than 2 GiB away"
	case .Section_Unknown:
		return "the section is neither code nor data"
	case .Section_Past_Capacity:
		return "the section passes its capacity"
	case .Instruction_In_Data:
		return "an instruction in the section data"
	case .Directive_Not_Valid:
		return "the directive has a wrong form"
	case .Type_Unknown:
		return "an export takes Integer and Text parameters, and gives an Integer or nothing"
	case .Too_Many_Parameters:
		return "an export has at most 12 parameters"
	case .Export_Twice:
		return "two exports have this name"
	case .Name_Not_Valid:
		return "the name is not a name of the module format: ASCII letters, digits and _, with no digit first"
	case .Labels_Full:
		return "the text has more labels than the workspace holds"
	case .References_Full:
		return "the text has more operands that name a label than the workspace holds"
	case .Exports_Full:
		return "the text has more than 32 exports"
	case .No_Instruction:
		return "the text has no instruction"
	case .Rebase_Not_In_Data:
		return "a quad of a label is in the section data only"
	case .Rebase_Not_Aligned:
		return "a quad of a label is on 8 bytes of the section data"
	case .Rebases_Full:
		return "the text has more quad values that name a label than the workspace holds"
	case .Address_Out_Of_Range:
		return "the label with its offset is below 0 or past 2^63 - 1"
	case .Global_Twice:
		return "two units make this name global"
	case .Alignment_Not_Valid:
		return "align takes a power of two from 1 to 4096"
	}
	return "an unknown refusal"
}

// place_of_offset gives the line and the column of a byte of the text.
place_of_offset :: proc "contextless" (text: string, offset: int) -> Place {
	line := u32(1)
	line_start := 0
	for index in 0 ..< min(offset, len(text)) {
		if text[index] == '\n' {
			line += 1
			line_start = index + 1
		}
	}
	return {line = line, column = u32(offset - line_start + 1), offset = u32(offset)}
}

// The reader of one statement: the bytes from position to end, on one
// line of the text.
@(private)
Cursor :: struct {
	text:       string,
	position:   int,
	end:        int, // The first byte after the statement: a `;`, a `#`, the end of the line.
	line:       u32,
	line_start: int,
	section:    ^Section, // The section of the statements of the text from here.
}

@(private)
place_here :: proc "contextless" (cursor: ^Cursor) -> Place {
	return {line = cursor.line, column = u32(cursor.position - cursor.line_start + 1), offset = u32(cursor.position)}
}

@(private)
refuse :: proc "contextless" (refusal: Refusal, place: Place, value: u64 = 0) -> Refusal_Record {
	return {refusal = refusal, place = place, value = value}
}

// statements_read reads each line, checks its bytes, and reads each
// statement of it into the workspace.
@(private)
statements_read :: proc "contextless" (text: string, workspace: ^Workspace) -> Refusal_Record {
	section := Section.Code
	line := u32(1)
	line_start := 0
	for {
		line_end := line_start
		for line_end < len(text) && text[line_end] != '\n' {
			line_end += 1
		}
		if line_end - line_start > LINE_BYTES_MOST {
			return refuse(.Line_Too_Long, {line = line, column = LINE_BYTES_MOST + 1, offset = u32(line_start + LINE_BYTES_MOST)}, u64(line_end - line_start))
		}
		comment := line_end
		for index in line_start ..< line_end {
			character := text[index]
			if character == '#' && comment == line_end {
				comment = index
			}
			control := character < 0x20 && character != '\t' || character == 0x7F
			if control || character >= 0x80 && index < comment {
				return refuse(.Character_Not_Valid, {line = line, column = u32(index - line_start + 1), offset = u32(index)}, u64(character))
			}
		}
		statement_start := line_start
		for statement_start < comment {
			statement_end := statement_start
			for statement_end < comment && text[statement_end] != ';' {
				statement_end += 1
			}
			cursor := Cursor {
				text       = text,
				position   = statement_start,
				end        = statement_end,
				line       = line,
				line_start = line_start,
				section    = &section,
			}
			if refusal := statement_read(&cursor, workspace); refusal.refusal != .None {
				return refusal
			}
			statement_start = statement_end + 1
		}
		if line_end >= len(text) {
			return {}
		}
		line_start = line_end + 1
		line += 1
	}
}

@(private)
blanks_skip :: proc "contextless" (cursor: ^Cursor) {
	for cursor.position < cursor.end && (cursor.text[cursor.position] == ' ' || cursor.text[cursor.position] == '\t') {
		cursor.position += 1
	}
}

@(private)
at_end :: proc "contextless" (cursor: ^Cursor) -> bool {
	blanks_skip(cursor)
	return cursor.position >= cursor.end
}

// next_is says if the next byte, after the blanks, is character, and takes
// it when it is.
@(private)
next_is :: proc "contextless" (cursor: ^Cursor, character: u8) -> bool {
	blanks_skip(cursor)
	if cursor.position < cursor.end && cursor.text[cursor.position] == character {
		cursor.position += 1
		return true
	}
	return false
}

@(private)
is_word_byte :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_' || character == '.'
}

@(private)
is_digit :: proc "contextless" (character: u8) -> bool {
	return character >= '0' && character <= '9'
}

// word_read reads letters, digits, `_` and `.` from the position, with no
// blank first.
@(private)
word_read :: proc "contextless" (cursor: ^Cursor) -> string {
	start := cursor.position
	for cursor.position < cursor.end && is_word_byte(cursor.text[cursor.position]) {
		cursor.position += 1
	}
	return cursor.text[start:cursor.position]
}

// statement_read reads the labels at the start of a statement, then its
// directive or its instruction.
@(private)
statement_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	word: string
	word_place: Place
	for {
		if at_end(cursor) {
			return {}
		}
		word_place = place_here(cursor)
		word = word_read(cursor)
		if word == "" || cursor.position >= cursor.end || cursor.text[cursor.position] != ':' {
			break
		}
		cursor.position += 1
		refusal: Refusal_Record
		if len(word) == 1 && is_digit(word[0]) {
			refusal = local_label_define(workspace, word, word_place, cursor.section^)
		} else {
			refusal = label_define(workspace, word, word_place, cursor.section^)
		}
		if refusal.refusal != .None {
			return refusal
		}
	}
	switch word {
	case "section":
		return section_directive(cursor)
	case "export":
		return export_directive(cursor, workspace)
	case "byte":
		return byte_directive(cursor, workspace)
	case "zero":
		return zero_directive(cursor, workspace)
	case "quad":
		return quad_directive(cursor, workspace)
	case "align":
		return align_directive(cursor, workspace)
	case "unit":
		return unit_directive(cursor, workspace)
	case "global":
		return global_directive(cursor, workspace)
	}
	return instruction_read(cursor, workspace, word, word_place)
}

@(private)
label_name_check :: proc "contextless" (name: string, place: Place) -> Refusal_Record {
	if len(name) == 0 || len(name) > writer.NAME_BYTES_MOST || is_digit(name[0]) {
		return refuse(.Label_Not_Valid, place)
	}
	return {}
}

// label_slot_first gives the first slot of a key: the FNV-1a hash of the
// name, mixed with the unit, cut to the slots.
@(private)
label_slot_first :: proc "contextless" (workspace: ^Workspace, unit: u32, name: string) -> int {
	hash := u64(0xCBF29CE484222325)
	for character in transmute([]u8)name {
		hash = (hash ~ u64(character)) * 0x100000001B3
	}
	hash = (hash ~ u64(unit)) * 0x100000001B3
	return int(hash & u64(len(workspace.label_slots) - 1))
}

// label_slot_matches says if a slot holds the key: a name of a unit, or a
// digit and its order under LOCAL_LABEL_UNIT, whose name is the digit.
@(private)
label_slot_matches :: proc "contextless" (workspace: ^Workspace, slot: Label_Slot, unit: u32, name: string, ordinal: u32) -> bool {
	if slot.unit != unit {
		return false
	}
	label := &workspace.labels[slot.label - 1]
	if unit == LOCAL_LABEL_UNIT {
		return label.local_digit == name[0] - '0' && label.local_ordinal == ordinal
	}
	return label.name == name
}

// label_slot_find gives the slot of a key, or the empty slot where it goes.
// The table is at most half full, so an empty slot ends each search.
@(private)
label_slot_find :: proc "contextless" (workspace: ^Workspace, unit: u32, name: string, ordinal: u32 = 0) -> int {
	if len(workspace.label_slots) == 0 {
		return -1
	}
	mask := len(workspace.label_slots) - 1
	key_name := name
	if unit == LOCAL_LABEL_UNIT {
		// The ordinal tells two definitions of a digit apart.
		key_name = name[:1]
	}
	index := label_slot_first(workspace, unit ~ (unit == LOCAL_LABEL_UNIT ? ordinal : 0), key_name)
	for {
		slot := workspace.label_slots[index]
		if slot.label == 0 || label_slot_matches(workspace, slot, unit, name, ordinal) {
			return index
		}
		index = (index + 1) & mask
	}
}

// label_find gives the index of the label of the unit with the name, or -1.
@(private)
label_find :: proc "contextless" (workspace: ^Workspace, name: string, unit: u32) -> int {
	slot := label_slot_find(workspace, unit, name)
	if slot < 0 {
		return -1
	}
	return int(workspace.label_slots[slot].label) - 1
}

// local_label_find gives the index of a definition of a numeric local
// label, or -1 while the text has not named it.
@(private)
local_label_find :: proc "contextless" (workspace: ^Workspace, digit: u8, ordinal: u32) -> int {
	name := [1]u8{'0' + digit}
	slot := label_slot_find(workspace, LOCAL_LABEL_UNIT, string(name[:]), ordinal)
	if slot < 0 {
		return -1
	}
	return int(workspace.label_slots[slot].label) - 1
}

// label_slot_add puts a label in its empty slot. The capacity of the
// labels keeps the table at most half full.
@(private)
label_slot_add :: proc "contextless" (workspace: ^Workspace, slot: int, label: int, unit: u32) {
	workspace.label_slots[slot] = {label = i32(label + 1), unit = unit}
}

// local_label_add adds a definition of a numeric local label that the text
// names for the first time. Its name is a view of the text, for no lookup:
// only the digit and the order find it.
@(private)
local_label_add :: proc "contextless" (workspace: ^Workspace, name: string, digit: u8, ordinal: u32, place: Place) -> (index: int, refusal: Refusal_Record) {
	if workspace.label_count == len(workspace.labels) {
		return -1, refuse(.Labels_Full, place, u64(len(workspace.labels)))
	}
	index = workspace.label_count
	workspace.labels[index] = {name = name, unit = workspace.unit, first_use = place, local = true, local_digit = digit, local_ordinal = ordinal}
	workspace.label_count += 1
	label_slot_add(workspace, label_slot_find(workspace, LOCAL_LABEL_UNIT, name, ordinal), index, LOCAL_LABEL_UNIT)
	return index, {}
}

// local_label_define places the next definition of a digit: a `Nf` before
// it names it already, and each `Nb` after it names it until the next one.
@(private)
local_label_define :: proc "contextless" (workspace: ^Workspace, word: string, place: Place, section: Section) -> Refusal_Record {
	digit := word[0] - '0'
	ordinal := workspace.local_label_definitions[digit]
	index := local_label_find(workspace, digit, ordinal)
	if index < 0 {
		refusal: Refusal_Record
		if index, refusal = local_label_add(workspace, word, digit, ordinal, place); refusal.refusal != .None {
			return refusal
		}
	}
	workspace.local_label_definitions[digit] = ordinal + 1
	label := &workspace.labels[index]
	label.section = section
	label.offset = workspace.extents[section]
	label.defined = true
	label.defined_at = place
	return {}
}

// is_local_reference_here says if the next word is `Nf` or `Nb`: one digit,
// then `f` or `b`, then no byte of a word.
@(private)
is_local_reference_here :: proc "contextless" (cursor: ^Cursor) -> bool {
	position := cursor.position
	if position + 1 >= cursor.end || !is_digit(cursor.text[position]) {
		return false
	}
	direction := cursor.text[position + 1]
	if direction != 'f' && direction != 'b' {
		return false
	}
	return position + 2 >= cursor.end || !is_word_byte(cursor.text[position + 2])
}

// local_reference_read reads `Nf` or `Nb` and gives the label that it names:
// `Nb` the last definition of the digit before it, `Nf` the next one.
@(private)
local_reference_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace, place: Place) -> (index: int, refusal: Refusal_Record) {
	name := cursor.text[cursor.position:cursor.position + 2]
	digit := name[0] - '0'
	cursor.position += 2
	definitions := workspace.local_label_definitions[digit]
	if name[1] == 'b' {
		if definitions == 0 {
			return -1, refuse(.Label_Not_Defined, place)
		}
		return local_label_find(workspace, digit, definitions - 1), {}
	}
	if index = local_label_find(workspace, digit, definitions); index >= 0 {
		return index, {}
	}
	return local_label_add(workspace, name, digit, definitions, place)
}

// label_reference_read reads the label that an operand names: a name, or a
// numeric local label `Nf` or `Nb`. It adds a name that the text did not
// name before.
@(private)
label_reference_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace, place: Place) -> (index: int, refusal: Refusal_Record) {
	if is_local_reference_here(cursor) {
		return local_reference_read(cursor, workspace, place)
	}
	name := word_read(cursor)
	if name == "" {
		return -1, refuse(.Operand_Not_Valid, place)
	}
	if refusal = label_name_check(name, place); refusal.refusal != .None {
		return -1, refusal
	}
	return label_named(workspace, name, place)
}

// label_add adds a label that the text names for the first time.
@(private)
label_add :: proc "contextless" (workspace: ^Workspace, name: string, place: Place) -> (index: int, refusal: Refusal_Record) {
	if refusal = label_name_check(name, place); refusal.refusal != .None {
		return -1, refusal
	}
	if workspace.label_count == len(workspace.labels) {
		return -1, refuse(.Labels_Full, place, u64(len(workspace.labels)))
	}
	index = workspace.label_count
	workspace.labels[index] = {name = name, unit = workspace.unit, first_use = place}
	workspace.label_count += 1
	label_slot_add(workspace, label_slot_find(workspace, workspace.unit, name), index, workspace.unit)
	return index, {}
}

// label_define places a label at the place of the next byte of its
// section.
@(private)
label_define :: proc "contextless" (workspace: ^Workspace, name: string, place: Place, section: Section) -> Refusal_Record {
	index := label_find(workspace, name, workspace.unit)
	if index >= 0 && workspace.labels[index].defined {
		return refuse(.Label_Defined_Twice, place, u64(workspace.labels[index].defined_at.line))
	}
	if index < 0 {
		refusal: Refusal_Record
		if index, refusal = label_add(workspace, name, place); refusal.refusal != .None {
			return refusal
		}
	}
	label := &workspace.labels[index]
	label.section = section
	label.offset = workspace.extents[section]
	label.defined = true
	label.defined_at = place
	return {}
}

// label_named gives the index of the label that an operand names, and adds
// it when the text did not name it before.
@(private)
label_named :: proc "contextless" (workspace: ^Workspace, name: string, place: Place) -> (index: int, refusal: Refusal_Record) {
	if index = label_find(workspace, name, workspace.unit); index >= 0 {
		return index, {}
	}
	return label_add(workspace, name, place)
}

// unit_directive starts the next unit of the text: the units of a program
// in one text, as a linker joins its objects. A name that no `global`
// names stays in its unit; a unit starts in the section code, as a text.
@(private)
unit_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	workspace.unit += 1
	cursor.section^ = .Code
	return {}
}

// global_directive makes a label of the unit seen by the other units: a
// unit that names it and does not define it takes its place.
@(private)
global_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	blanks_skip(cursor)
	place := place_here(cursor)
	// A name with a digit first, a numeric local label too, is refused here.
	name := word_read(cursor)
	if refusal := label_name_check(name, place); refusal.refusal != .None {
		return refusal
	}
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	index, refusal := label_named(workspace, name, place)
	if refusal.refusal != .None {
		return refusal
	}
	label := &workspace.labels[index]
	if label.global {
		return {}
	}
	slot := label_slot_find(workspace, GLOBAL_UNIT, name)
	if workspace.label_slots[slot].label != 0 {
		first := workspace.labels[workspace.label_slots[slot].label - 1]
		return refuse(.Global_Twice, place, u64(first.global_at.line))
	}
	label.global = true
	label.global_at = place
	label_slot_add(workspace, slot, index, GLOBAL_UNIT)
	return {}
}

// align_directive moves the place of the next byte of the section to a
// multiple of a power of two. The data takes zero bytes, which the file
// does not store at the end of the section; the code takes `nop` bytes,
// which a processor that runs into them passes.
@(private)
align_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	blanks_skip(cursor)
	place := place_here(cursor)
	alignment, ok := number_read(cursor)
	if !ok {
		return refuse(.Number_Not_Valid, place)
	}
	if alignment < 1 || alignment > ALIGNMENT_MOST || alignment & (alignment - 1) != 0 {
		return refuse(.Alignment_Not_Valid, place, u64(min(alignment, i128(max(u64)))))
	}
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	section := cursor.section^
	start := workspace.extents[section]
	padding := (u64(alignment) - start % u64(alignment)) % u64(alignment)
	if section == .Data {
		// SECTION_EXTENT_MOST is a multiple of each alignment, so the
		// padding never passes it.
		workspace.extents[.Data] = start + padding
		return {}
	}
	NOP :: 0x90
	nops: [ALIGNMENT_MOST]u8
	for index in 0 ..< padding {
		nops[index] = NOP
	}
	return section_write(workspace, .Code, nops[:padding], place)
}

@(private)
section_directive :: proc "contextless" (cursor: ^Cursor) -> Refusal_Record {
	blanks_skip(cursor)
	place := place_here(cursor)
	switch word_read(cursor) {
	case "code":
		cursor.section^ = .Code
	case "data":
		cursor.section^ = .Data
	case:
		return refuse(.Section_Unknown, place)
	}
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	return {}
}

// type_of_word reads a type of an export: Integer or Text for a parameter,
// Integer for a result.
@(private)
type_of_word :: proc "contextless" (word: string, result: bool) -> (type: module.Type, ok: bool) {
	switch word {
	case "Integer":
		return .Integer, true
	case "Text":
		return .Text, !result
	}
	return .None, false
}

@(private)
export_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	blanks_skip(cursor)
	declaration := Export_Declaration {
		unit  = workspace.unit,
		place = place_here(cursor),
	}
	declaration.name = word_read(cursor)
	if !writer.is_name(declaration.name) {
		return refuse(.Name_Not_Valid, declaration.place)
	}
	for item in workspace.exports[:workspace.export_count] {
		if item.name == declaration.name {
			return refuse(.Export_Twice, declaration.place)
		}
	}
	if workspace.export_count == len(workspace.exports) {
		return refuse(.Exports_Full, declaration.place, EXPORT_CAPACITY)
	}
	if !next_is(cursor, '(') {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	if !next_is(cursor, ')') {
		for {
			blanks_skip(cursor)
			name_place := place_here(cursor)
			name := word_read(cursor)
			if !writer.is_name(name) {
				return refuse(.Name_Not_Valid, name_place)
			}
			if declaration.parameter_count == module.PARAMETER_CAPACITY {
				return refuse(.Too_Many_Parameters, name_place, module.PARAMETER_CAPACITY + 1)
			}
			if !next_is(cursor, ':') {
				return refuse(.Directive_Not_Valid, place_here(cursor))
			}
			blanks_skip(cursor)
			type_place := place_here(cursor)
			type, known := type_of_word(word_read(cursor), false)
			if !known {
				return refuse(.Type_Unknown, type_place)
			}
			declaration.parameters[declaration.parameter_count] = type
			declaration.parameter_names[declaration.parameter_count] = name
			declaration.parameter_count += 1
			if next_is(cursor, ')') {
				break
			}
			if !next_is(cursor, ',') {
				return refuse(.Directive_Not_Valid, place_here(cursor))
			}
		}
	}
	if next_is(cursor, '-') {
		if cursor.position >= cursor.end || cursor.text[cursor.position] != '>' {
			return refuse(.Directive_Not_Valid, place_here(cursor))
		}
		cursor.position += 1
		blanks_skip(cursor)
		type_place := place_here(cursor)
		type, known := type_of_word(word_read(cursor), true)
		if !known {
			return refuse(.Type_Unknown, type_place)
		}
		declaration.result = type
	}
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	workspace.exports[workspace.export_count] = declaration
	workspace.export_count += 1
	return {}
}

// number_read reads a number with no sign: decimal digits, or `0x` and
// hexadecimal digits. A number past 2^64 - 1 gives 2^64: each field
// refuses it by its range. ok is false for a number with no digit, or
// with a word byte that is no digit of its base.
@(private)
number_read :: proc "contextless" (cursor: ^Cursor) -> (value: i128, ok: bool) {
	PAST_64_BITS :: i128(1) << 64
	base := i128(10)
	if cursor.position + 1 < cursor.end && cursor.text[cursor.position] == '0' && (cursor.text[cursor.position + 1] == 'x' || cursor.text[cursor.position + 1] == 'X') {
		base = 16
		cursor.position += 2
	}
	digits := 0
	for cursor.position < cursor.end && is_word_byte(cursor.text[cursor.position]) {
		character := cursor.text[cursor.position]
		digit: i128
		switch {
		case character >= '0' && character <= '9':
			digit = i128(character - '0')
		case base == 16 && character >= 'a' && character <= 'f':
			digit = i128(character - 'a' + 10)
		case base == 16 && character >= 'A' && character <= 'F':
			digit = i128(character - 'A' + 10)
		case:
			return 0, false
		}
		value = min(value * base + digit, PAST_64_BITS)
		digits += 1
		cursor.position += 1
	}
	return value, digits > 0
}

// signed_number_read reads a number with an optional `-` first.
@(private)
signed_number_read :: proc "contextless" (cursor: ^Cursor) -> (value: i128, ok: bool) {
	negative := false
	if cursor.position < cursor.end && cursor.text[cursor.position] == '-' {
		negative = true
		cursor.position += 1
	}
	value, ok = number_read(cursor)
	return negative ? -value : value, ok
}

// section_write writes bytes at the place of the next byte of a section.
@(private)
section_write :: proc "contextless" (workspace: ^Workspace, section: Section, bytes: []u8, place: Place) -> Refusal_Record {
	buffer := section == .Code ? workspace.code[:] : workspace.data[:]
	start := workspace.extents[section]
	if start > u64(len(buffer)) || u64(len(bytes)) > u64(len(buffer)) - start {
		return refuse(.Section_Past_Capacity, place, start + u64(len(bytes)))
	}
	// The bytes between the last stored byte and start are the zero bytes
	// of `zero` and `align`: the buffer holds the bytes of an earlier text.
	stored := workspace.stored[section]
	if start > stored {
		intrinsics.mem_zero(&buffer[stored], int(start - stored))
	}
	if len(bytes) > 0 {
		intrinsics.mem_copy_non_overlapping(&buffer[start], raw_data(bytes), len(bytes))
	}
	workspace.extents[section] = start + u64(len(bytes))
	workspace.stored[section] = workspace.extents[section]
	return {}
}

@(private)
byte_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	for {
		blanks_skip(cursor)
		place := place_here(cursor)
		value, ok := signed_number_read(cursor)
		if !ok {
			return refuse(.Number_Not_Valid, place)
		}
		if value < -128 || value > 255 {
			return refuse(.Immediate_Too_Large, place)
		}
		one := [1]u8{u8(value & 0xFF)}
		if refusal := section_write(workspace, cursor.section^, one[:], place); refusal.refusal != .None {
			return refusal
		}
		if at_end(cursor) {
			return {}
		}
		if !next_is(cursor, ',') {
			return refuse(.Directive_Not_Valid, place_here(cursor))
		}
	}
}

@(private)
zero_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	blanks_skip(cursor)
	place := place_here(cursor)
	count, ok := number_read(cursor)
	if !ok {
		return refuse(.Number_Not_Valid, place)
	}
	extent := i128(workspace.extents[cursor.section^]) + count
	if extent > i128(SECTION_EXTENT_MOST) {
		return refuse(.Section_Past_Capacity, place, u64(min(extent, i128(max(u64)))))
	}
	if !at_end(cursor) {
		return refuse(.Directive_Not_Valid, place_here(cursor))
	}
	workspace.extents[cursor.section^] = u64(extent)
	return {}
}

// quad_directive writes 8 bytes for each value: a number, or a label with
// an optional `+ number` or `- number`. A label gives its address in the
// module, which the module records as a rebase: the loader adds the base of
// the load, so a table of pointers holds addresses at any base.
@(private)
quad_directive :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> Refusal_Record {
	for {
		blanks_skip(cursor)
		place := place_here(cursor)
		if cursor.position >= cursor.end {
			return refuse(.Number_Not_Valid, place)
		}
		character := cursor.text[cursor.position]
		value := [8]u8{}
		if (character == '-' || is_digit(character)) && !is_local_reference_here(cursor) {
			number, ok := signed_number_read(cursor)
			if !ok {
				return refuse(.Number_Not_Valid, place)
			}
			if number < i128(min(i64)) || number > i128(max(u64)) {
				return refuse(.Immediate_Too_Large, place)
			}
			intrinsics.unaligned_store((^u64le)(&value[0]), u64le(u64(number & i128(max(u64)))))
			if refusal := section_write(workspace, cursor.section^, value[:], place); refusal.refusal != .None {
				return refusal
			}
		} else if refusal := quad_label_read(cursor, workspace, place); refusal.refusal != .None {
			return refusal
		}
		if at_end(cursor) {
			return {}
		}
		if !next_is(cursor, ',') {
			return refuse(.Directive_Not_Valid, place_here(cursor))
		}
	}
}

// quad_label_read reads a label with its offset, and keeps its 8 bytes of
// the data: their value is known once the code has its size.
@(private)
quad_label_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace, place: Place) -> Refusal_Record {
	label, refusal := label_reference_read(cursor, workspace, place)
	if refusal.refusal != .None {
		return refusal
	}
	addend := i128(0)
	blanks_skip(cursor)
	if cursor.position < cursor.end && (cursor.text[cursor.position] == '+' || cursor.text[cursor.position] == '-') {
		negative := cursor.text[cursor.position] == '-'
		cursor.position += 1
		blanks_skip(cursor)
		addend_place := place_here(cursor)
		ok: bool
		if addend, ok = number_read(cursor); !ok {
			return refuse(.Number_Not_Valid, addend_place)
		}
		if negative {
			addend = -addend
		}
		if addend < i128(min(i64)) || addend > i128(max(i64)) {
			return refuse(.Immediate_Too_Large, addend_place)
		}
	}
	// The loader writes the segment of the data only: the code is never
	// writable, so no loader rebases an address there.
	if cursor.section^ != .Data {
		return refuse(.Rebase_Not_In_Data, place)
	}
	data_offset := workspace.extents[.Data]
	if data_offset % module.REBASE_WORD_SIZE != 0 {
		return refuse(.Rebase_Not_Aligned, place, data_offset)
	}
	if workspace.data_reference_count == len(workspace.data_references) {
		return refuse(.Rebases_Full, place, u64(len(workspace.data_references)))
	}
	zero := [8]u8{}
	if refusal = section_write(workspace, .Data, zero[:], place); refusal.refusal != .None {
		return refusal
	}
	workspace.data_references[workspace.data_reference_count] = {
		label       = label,
		addend      = i64(addend),
		data_offset = data_offset,
		place       = place,
	}
	workspace.data_reference_count += 1
	return {}
}

// references_resolve writes the 4 bytes of each reference, once each label
// has its place: the section code at the offset 0, the section data on the
// first page after the code.
@(private)
references_resolve :: proc "contextless" (workspace: ^Workspace) -> Refusal_Record {
	// A unit that names a label that it does not define names the global
	// label of that name, which a unit defines.
	for &label in workspace.labels[:workspace.label_count] {
		if label.defined || label.local {
			continue
		}
		slot := label_slot_find(workspace, GLOBAL_UNIT, label.name)
		if workspace.label_slots[slot].label == 0 {
			continue
		}
		global := workspace.labels[workspace.label_slots[slot].label - 1]
		if global.defined {
			label.section = global.section
			label.offset = global.offset
			label.defined = true
			label.defined_at = global.defined_at
		}
	}
	for label in workspace.labels[:workspace.label_count] {
		if !label.defined {
			return refuse(.Label_Not_Defined, label.first_use)
		}
	}
	bases := [Section]u64 {
		.Code = 0,
		.Data = page_round(workspace.extents[.Code]),
	}
	for reference in workspace.references[:workspace.reference_count] {
		label := workspace.labels[reference.label]
		if reference.kind == .Jump_Target && label.section != .Code {
			return refuse(.Label_In_Wrong_Section, reference.place)
		}
		target := bases[label.section] + label.offset
		distance := i128(target) - i128(reference.instruction_end)
		if distance < i128(min(i32)) || distance > i128(max(i32)) {
			return refuse(.Distance_Too_Large, reference.place, target)
		}
		intrinsics.unaligned_store((^i32le)(&workspace.code[reference.field_offset]), i32le(distance))
	}
	// The data references are in the order of the data, so the rebases are
	// in order, as the module file writer requires.
	for reference, index in workspace.data_references[:workspace.data_reference_count] {
		label := workspace.labels[reference.label]
		address := i128(bases[label.section] + label.offset) + i128(reference.addend)
		if address < 0 || address > i128(max(i64)) {
			return refuse(.Address_Out_Of_Range, reference.place, u64(address & i128(max(u64))))
		}
		intrinsics.unaligned_store((^u64le)(&workspace.data[reference.data_offset]), u64le(u64(address)))
		workspace.rebases[index] = bases[.Data] + reference.data_offset
	}
	return {}
}

@(private)
page_round :: proc "contextless" (size: u64) -> u64 {
	return (size + module.PAGE_SIZE - 1) / module.PAGE_SIZE * module.PAGE_SIZE
}

// parts_fill binds each export to its label and gives the parts.
@(private)
parts_fill :: proc "contextless" (workspace: ^Workspace) -> (parts: writer.Module_Parts, refusal: Refusal_Record) {
	for &declaration, index in workspace.exports[:workspace.export_count] {
		label_index := label_find(workspace, declaration.name, declaration.unit)
		if label_index < 0 {
			if slot := label_slot_find(workspace, GLOBAL_UNIT, declaration.name); slot >= 0 {
				label_index = int(workspace.label_slots[slot].label) - 1
			}
		}
		if label_index < 0 || !workspace.labels[label_index].defined {
			return {}, refuse(.Label_Not_Defined, declaration.place)
		}
		label := workspace.labels[label_index]
		if label.section != .Code {
			return {}, refuse(.Label_In_Wrong_Section, declaration.place)
		}
		workspace.export_parts[index] = {
			name            = declaration.name,
			code_offset     = label.offset,
			parameters      = declaration.parameters[:declaration.parameter_count],
			parameter_names = declaration.parameter_names[:declaration.parameter_count],
			result          = declaration.result,
		}
	}
	code_size := page_round(workspace.extents[.Code])
	workspace.segments[0] = {
		memory_offset = 0,
		memory_size   = code_size,
		flags         = {.Read, .Execute},
		data          = workspace.code[:workspace.stored[.Code]],
	}
	segment_count := 1
	if workspace.extents[.Data] > 0 {
		workspace.segments[1] = {
			memory_offset = code_size,
			memory_size   = page_round(workspace.extents[.Data]),
			flags         = {.Read, .Write},
			data          = workspace.data[:workspace.stored[.Data]],
		}
		segment_count = 2
	}
	parts = {
		segments = workspace.segments[:segment_count],
		exports  = workspace.export_parts[:workspace.export_count],
		rebases  = workspace.rebases[:workspace.data_reference_count],
	}
	return parts, {}
}
