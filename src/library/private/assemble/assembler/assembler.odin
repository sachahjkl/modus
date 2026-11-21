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
// rule of the language.
TEXT_BYTES_MOST :: 1 << 20 // The bytes of a text.
LINE_BYTES_MOST :: 1024 // The bytes of one line, its comment included.
CODE_BYTES_MOST :: 64 * 1024 // The bytes of the section code that a file stores.
DATA_BYTES_MOST :: 64 * 1024 // The bytes of the section data that a file stores.
// The extent of a section with its zero bytes: `zero` adds to it and
// writes no byte.
SECTION_EXTENT_MOST :: u64(1) << 40
LABEL_CAPACITY :: 512
REFERENCE_CAPACITY :: 2048 // The operands that name a label.
EXPORT_CAPACITY :: 32

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
	Section_Past_Capacity  = 21, // A section passes CODE_BYTES_MOST or DATA_BYTES_MOST bytes, or SECTION_EXTENT_MOST of extent. value: the bytes that it would reach.
	Instruction_In_Data    = 22, // An instruction in the section data, which no processor runs.
	Directive_Not_Valid    = 23, // A directive with a wrong form: a missing `(`, `:` or `,`, words after its end.
	Type_Unknown           = 24, // A type of an export that the assembler does not take: parameters Integer and Text, the result Integer.
	Too_Many_Parameters    = 25, // An export with more than module.PARAMETER_CAPACITY parameters.
	Export_Twice           = 26, // Two exports have one name.
	Name_Not_Valid         = 27, // The name of an export or of a parameter is not a name of the module format.
	Labels_Full            = 28, // More than LABEL_CAPACITY labels.
	References_Full        = 29, // More than REFERENCE_CAPACITY operands that name a label.
	Exports_Full           = 30, // More than EXPORT_CAPACITY exports.
	No_Instruction         = 31, // The text has no byte in the section code.
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

// A label: a name and its place in a section. A label that an operand names
// before its definition is in the table with defined false.
Label :: struct {
	name:       string, // A view of the text.
	section:    Section,
	offset:     u64, // From the start of its section.
	defined:    bool,
	first_use:  Place, // Where the text names it first: its definition or an operand.
	defined_at: Place, // Its definition, when defined.
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

// An export as the directive declares it.
Export_Declaration :: struct {
	name:            string,
	parameters:      [module.PARAMETER_CAPACITY]module.Type,
	parameter_names: [module.PARAMETER_CAPACITY]string,
	parameter_count: int,
	result:          module.Type,
	place:           Place, // The name in the directive.
}

// The memory of one assembly, which the caller gives. `assemble` sets it to
// zero first. The parts that `assemble` gives are views of it and of the
// text: both must stay until the file is written.
Workspace :: struct {
	code:            [CODE_BYTES_MOST]u8,
	data:            [DATA_BYTES_MOST]u8,
	extents:         [Section]u64, // The place of the next byte of each section.
	stored:          [Section]u64, // The bytes of each section in its buffer: the zero bytes after them are not stored.
	labels:          [LABEL_CAPACITY]Label,
	label_count:     int,
	references:      [REFERENCE_CAPACITY]Reference,
	reference_count: int,
	exports:         [EXPORT_CAPACITY]Export_Declaration,
	export_count:    int,
	segments:        [2]writer.Segment_Part, // The code, and the data when the text has data.
	export_parts:    [EXPORT_CAPACITY]writer.Export_Part,
}

// assemble reads a text and gives the parts of its module file: the
// segment of the code at the offset 0, the segment of the data after it
// when the text has data, and one export for each `export`. The parts are
// views of the workspace and of the text.
assemble :: proc "contextless" (text: string, workspace: ^Workspace) -> (parts: writer.Module_Parts, refusal: Refusal_Record) {
	intrinsics.mem_zero(workspace, size_of(Workspace))
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
		return "the text has more than 1 MiB"
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
		return "the text has more than 512 labels"
	case .References_Full:
		return "the text has more than 2048 operands that name a label"
	case .Exports_Full:
		return "the text has more than 32 exports"
	case .No_Instruction:
		return "the text has no instruction"
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
		if refusal := label_define(workspace, word, word_place, cursor.section^); refusal.refusal != .None {
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

// label_find gives the index of the label with the name, or -1.
@(private)
label_find :: proc "contextless" (workspace: ^Workspace, name: string) -> int {
	for index in 0 ..< workspace.label_count {
		if workspace.labels[index].name == name {
			return index
		}
	}
	return -1
}

// label_add adds a label that the text names for the first time.
@(private)
label_add :: proc "contextless" (workspace: ^Workspace, name: string, place: Place) -> (index: int, refusal: Refusal_Record) {
	if refusal = label_name_check(name, place); refusal.refusal != .None {
		return -1, refusal
	}
	if workspace.label_count == LABEL_CAPACITY {
		return -1, refuse(.Labels_Full, place, LABEL_CAPACITY)
	}
	index = workspace.label_count
	workspace.labels[index] = {name = name, first_use = place}
	workspace.label_count += 1
	return index, {}
}

// label_define places a label at the place of the next byte of its
// section.
@(private)
label_define :: proc "contextless" (workspace: ^Workspace, name: string, place: Place, section: Section) -> Refusal_Record {
	index := label_find(workspace, name)
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
	if index = label_find(workspace, name); index >= 0 {
		return index, {}
	}
	return label_add(workspace, name, place)
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
	if workspace.export_count == EXPORT_CAPACITY {
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
	// The bytes between the last stored byte and start are zero already:
	// the workspace starts at zero and nothing writes past the extent.
	intrinsics.mem_copy_non_overlapping(&buffer[start], raw_data(bytes), len(bytes))
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

// references_resolve writes the 4 bytes of each reference, once each label
// has its place: the section code at the offset 0, the section data on the
// first page after the code.
@(private)
references_resolve :: proc "contextless" (workspace: ^Workspace) -> Refusal_Record {
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
		label_index := label_find(workspace, declaration.name)
		if label_index < 0 {
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
	}
	return parts, {}
}
