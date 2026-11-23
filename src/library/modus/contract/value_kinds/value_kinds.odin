// The kinds of the values that the system shows, and the value runs of a
// text: which bytes of a text are a number, a size, a time or a module.
//
// One enumeration of kinds for the system and for the site of the system:
// the site writes each kind with its class and its icon, a process draws it
// in its color, and both take the color from one table of the design rules
// (src/library/modus/graphics/value_colors.odin). A writer states the kind of each
// part that it writes: no text is classified by its look.
//
// A log record keeps the runs of its text (operation.Log_Record), so that a
// reader shows each value in the color of its kind. The text itself does
// not change: the serial port, the machine tests and a reader that ignores
// the runs read the same bytes as before (docs/TOOLS.md, "The log").
package value_kinds

import "modus:contract/enum_word"

// What a value is: the kind of a part of a text. See
// [value run](term:value-run).
Value_Kind :: enum u8 {
	None      = 0, // Not a value: a name or a text.
	Number    = 1, // A count, a place, an index or an address.
	Size      = 2, // A size in bytes, pages or blocks.
	Time      = 3, // A duration, a date or a time.
	Handle    = 4, // A handle number, or the index of a handle in a context.
	Value     = 5, // A plain value of the context of a process: not a handle.
	Grant     = 6, // A grant of a process.
	Status    = 7, // A status, an error kind or the state of a property.
	Type      = 8, // A type of the contract or of a module.
	Operation = 9, // A kernel operation.
	Command   = 10, // A command of the console.
	Module    = 11, // A module or a process.
	File      = 12, // A file of the sources.
	Guide     = 13, // A guide of the documentation.
	Term      = 14, // A term of the glossary.
	Version   = 15, // A version, a release, a commit or a hash.
	Yes       = 16, // A fact that holds: a check that passed.
	No        = 17, // A fact that does not hold.
	Procedure = 18, // A procedure of the sources.
	Constant  = 19, // A constant of the sources.
	Variable  = 20, // A variable of the sources.
}

// The name of each kind: the class "value-<name>" of the site, and the kind
// of a value run in a table of the log.
@(rodata)
VALUE_KIND_NAMES := [Value_Kind]string {
	.None      = "",
	.Number    = "number",
	.Size      = "size",
	.Time      = "time",
	.Handle    = "handle",
	.Value     = "value",
	.Grant     = "grant",
	.Status    = "status",
	.Type      = "type",
	.Operation = "operation",
	.Command   = "command",
	.Module    = "module",
	.File      = "file",
	.Guide     = "guide",
	.Term      = "term",
	.Version   = "version",
	.Yes       = "yes",
	.No        = "no",
	.Procedure = "procedure",
	.Constant  = "constant",
	.Variable  = "variable",
}

// value_kind_of is the border of the kind of a byte that another party
// wrote: the member, or false for a byte that names none.
value_kind_of :: proc "contextless" (value: u8) -> (kind: Value_Kind, ok: bool) {
	for member in Value_Kind {
		if u8(member) == value {
			return member, true
		}
	}
	return {}, false
}

// A value run of a log record: start and length in bytes of the text of the
// record. A record has fewer than 256 bytes of text, so a byte holds its
// start. The kind is a byte, not a member: the record comes from the
// kernel to each reader, which takes the byte through value_run_in_text.
Value_Run :: struct {
	start:  u8, // The first byte of the value in the text of the record.
	length: u8, // The bytes of the value.
	kind:   u8, // What the value is: the byte of a Value_Kind.
}
#assert(size_of(Value_Run) == 3)

// A value run of a text that is longer than one record: the text of one Log
// operation (at most 4096 bytes), or the text that the kernel writes for
// itself. The kernel cuts these runs at the bounds of the records. The kind
// is a byte, not a member: a process writes the runs, and the kernel takes
// each byte through value_runs_check before it keeps them.
Value_Run_In_Call :: struct {
	start:    u16, // The first byte of the value in the text of the call.
	length:   u16, // The bytes of the value.
	kind:     u8, // What the value is: the byte of a Value_Kind.
	reserved: u8, // 0.
}
#assert(size_of(Value_Run_In_Call) == 6)

// The typed parts of a line of the log. Each one writes exactly the text
// that a number and a text after it wrote before the kinds existed: the
// value in decimal, then the unit with a space before it. The run covers the
// number and its unit.

// The unit of a `Size`.
Size_Unit :: enum u8 {
	Bytes     = 0, // " bytes".
	Kibibytes = 1, // " KiB": 1024 bytes.
	Mebibytes = 2, // " MiB": 1024 KiB.
	Pages     = 3, // " pages": 4096 bytes each.
	Blocks    = 4, // " blocks": blocks of a disk or a store.
}

// The text of each unit of a size, with the space before it.
@(rodata)
SIZE_UNIT_TEXTS := [Size_Unit]string {
	.Bytes     = " bytes",
	.Kibibytes = " KiB",
	.Mebibytes = " MiB",
	.Pages     = " pages",
	.Blocks    = " blocks",
}

// A size: the value in its unit. "Size{64, .Mebibytes}" writes "64 MiB".
Size :: struct {
	value: u64, // The number, in the unit.
	unit:  Size_Unit, // The unit.
}

// The unit of a `Duration`.
Duration_Unit :: enum u8 {
	Nanoseconds  = 0, // " ns".
	Microseconds = 1, // " us".
	Milliseconds = 2, // " ms".
	Seconds      = 3, // " s".
}

// The text of each unit of a duration, with the space before it.
@(rodata)
DURATION_UNIT_TEXTS := [Duration_Unit]string {
	.Nanoseconds  = " ns",
	.Microseconds = " us",
	.Milliseconds = " ms",
	.Seconds      = " s",
}

// A duration: the value in its unit. "Duration{820, .Microseconds}" writes
// "820 us".
Duration :: struct {
	value: u64, // The number, in the unit.
	unit:  Duration_Unit, // The unit.
}

// What an Integer counts, as a command states it for one parameter and a
// description of a record for one field: a size or a time, and the unit of
// that kind. See [integer unit](term:integer-unit). The palette shows the
// unit after the number of the field, and the principal types the number
// in that unit. The console draws a field with a unit in the color of its
// kind, with the unit in the head of its column.
//
// Example: the parameter of `buffer` is `{.Size, u8(Size_Unit.Pages)}`.
Integer_Unit :: struct {
	kind: Value_Kind, // None: a plain number. Size or Time.
	unit: u8, // A Size_Unit for a Size, a Duration_Unit for a Time; 0 for None.
}
#assert(size_of(Integer_Unit) == 2)

// size_in gives the integer unit of a size in a unit.
size_in :: proc "contextless" (unit: Size_Unit) -> Integer_Unit {
	return {kind = .Size, unit = u8(unit)}
}

// time_in gives the integer unit of a time in a unit.
time_in :: proc "contextless" (unit: Duration_Unit) -> Integer_Unit {
	return {kind = .Time, unit = u8(unit)}
}

// integer_unit_valid says if an integer unit that another party wrote is
// one of the contract: None with the unit 0, a Size with a Size_Unit, a
// Time with a Duration_Unit.
integer_unit_valid :: proc "contextless" (integer_unit: Integer_Unit) -> bool {
	switch integer_unit.kind {
	case .None:
		return integer_unit.unit == 0
	case .Size:
		return integer_unit.unit <= u8(max(Size_Unit))
	case .Time:
		return integer_unit.unit <= u8(max(Duration_Unit))
	case .Number, .Handle, .Value, .Grant, .Status, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Version, .Yes, .No, .Procedure, .Constant, .Variable:
		// An integer unit is a size or a time: the other kinds have no unit.
		return false
	}
	return false
}

// integer_unit_text gives the text of the unit of an integer unit, with
// the space before it, as a log writes it: " pages", " ms". A plain number
// and a unit out of the contract give an empty text.
integer_unit_text :: proc "contextless" (integer_unit: Integer_Unit) -> string {
	if !integer_unit_valid(integer_unit) {
		return ""
	}
	switch integer_unit.kind {
	case .Size:
		size_unit, known := enum_word.member_of_word(Size_Unit, u64(integer_unit.unit))
		return known ? SIZE_UNIT_TEXTS[size_unit] : ""
	case .Time:
		duration_unit, known := enum_word.member_of_word(Duration_Unit, u64(integer_unit.unit))
		return known ? DURATION_UNIT_TEXTS[duration_unit] : ""
	case .None, .Number, .Handle, .Value, .Grant, .Status, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Version, .Yes, .No, .Procedure, .Constant, .Variable:
	}
	return ""
}

// integer_unit_detail gives the detail of an Integer parameter of an
// export that counts in an integer unit (module.Function.parameter_details):
// the value kind in byte 1, the unit in byte 2. Byte 0 stays 0, because the
// console puts the size of an Integer field (1, 2 or 4) in the same word,
// and a size 2 must not read as a size in bytes. A plain number is 0.
integer_unit_detail :: proc "contextless" (integer_unit: Integer_Unit) -> u32 {
	if integer_unit.kind == .None {
		return 0
	}
	return u32(integer_unit.kind) << 8 | u32(integer_unit.unit) << 16
}

// integer_unit_of_detail gives the integer unit of the detail of an Integer
// parameter. A detail that another party wrote can be anything: ok is
// false for a detail that is not one of the contract, with a byte 0 or a
// byte 3 that is not 0, or a unit that does not exist. The detail 0 is a
// plain number, and ok.
integer_unit_of_detail :: proc "contextless" (detail: u32) -> (integer_unit: Integer_Unit, ok: bool) {
	if detail & 0xFF00_00FF != 0 {
		return {}, false
	}
	kind := value_kind_of(u8(detail >> 8)) or_return
	integer_unit = {kind = kind, unit = u8(detail >> 16)}
	if !integer_unit_valid(integer_unit) {
		return {}, false
	}
	return integer_unit, true
}

// The types that an export gives to an Integer parameter that counts a
// size or a time, in place of i64. Each is distinct, so the compiler
// refuses a number of another unit, or a plain i64, at a call in the
// build; the call form is the one of an i64. The tool that describes a
// module finds the unit of each name in INTEGER_UNIT_TYPES
// (docs/MODULE_CONTRACT.md, "The unit of an Integer parameter").
//
// Example: `hkdf_sha256_expand :: proc "c" (key, info: ^string, length:
// value_kinds.Size_In_Bytes, ...) -> i64`.

// An Integer parameter that counts a size in bytes.
Size_In_Bytes :: distinct i64
// An Integer parameter that counts a size in KiB.
Size_In_Kibibytes :: distinct i64
// An Integer parameter that counts a size in MiB.
Size_In_Mebibytes :: distinct i64
// An Integer parameter that counts a size in pages of 4096 bytes.
Size_In_Pages :: distinct i64
// An Integer parameter that counts a size in blocks of a disk or a store.
Size_In_Blocks :: distinct i64
// An Integer parameter that counts a time in nanoseconds.
Time_In_Nanoseconds :: distinct i64
// An Integer parameter that counts a time in microseconds.
Time_In_Microseconds :: distinct i64
// An Integer parameter that counts a time in milliseconds.
Time_In_Milliseconds :: distinct i64
// An Integer parameter that counts a time in seconds.
Time_In_Seconds :: distinct i64

// The name of a type of an Integer parameter with a unit, and its unit.
Integer_Unit_Type :: struct {
	name:         string, // The name of the type in this package.
	integer_unit: Integer_Unit, // What the Integer counts.
}

// Each type of an Integer parameter with a unit: the one table that names
// them for the tool. A test checks that it has one row for each unit.
@(rodata)
INTEGER_UNIT_TYPES := [?]Integer_Unit_Type {
	{"Size_In_Bytes", {kind = .Size, unit = u8(Size_Unit.Bytes)}},
	{"Size_In_Kibibytes", {kind = .Size, unit = u8(Size_Unit.Kibibytes)}},
	{"Size_In_Mebibytes", {kind = .Size, unit = u8(Size_Unit.Mebibytes)}},
	{"Size_In_Pages", {kind = .Size, unit = u8(Size_Unit.Pages)}},
	{"Size_In_Blocks", {kind = .Size, unit = u8(Size_Unit.Blocks)}},
	{"Time_In_Nanoseconds", {kind = .Time, unit = u8(Duration_Unit.Nanoseconds)}},
	{"Time_In_Microseconds", {kind = .Time, unit = u8(Duration_Unit.Microseconds)}},
	{"Time_In_Milliseconds", {kind = .Time, unit = u8(Duration_Unit.Milliseconds)}},
	{"Time_In_Seconds", {kind = .Time, unit = u8(Duration_Unit.Seconds)}},
}

// integer_unit_of_type_name gives the integer unit of the name of a type of
// INTEGER_UNIT_TYPES. ok is false for another name.
integer_unit_of_type_name :: proc "contextless" (name: string) -> (integer_unit: Integer_Unit, ok: bool) {
	for item in INTEGER_UNIT_TYPES {
		if item.name == name {
			return item.integer_unit, true
		}
	}
	return {}, false
}

// How a reader writes the value of a field of a record, past its type: the
// field kind of a description (module.Field.kind). See [field
// kind](term:field-kind). The byte crosses a border in each module file:
// a reader takes it through field_kind_of_word.
//
// Example: the field `check: value_kinds.Hexadecimal_32` of a record is an
// Integer of 4 bytes with the kind Hexadecimal: a reader writes "0x1a2b".
Field_Kind :: enum u8 {
	Plain       = 0, // As its type says: an Integer in decimal with its integer unit, a Text, a Handle.
	Hexadecimal = 1, // An Integer with no unit, written as "0x" and its hexadecimal digits. The value kind is Number.
	Status      = 2, // An unsigned Integer with no unit that holds a member of a contract enum: the reader writes the name of the member. The value kind is Status.
	Module_Name = 3, // A Text: the name of a module or of a process. The value kind is Module.
	Hash        = 4, // A field of the type Bytes: a hash, or its head, written as two hexadecimal digits for each byte. The value kind is Version.
	Fact_Values = 5, // A field of the type Bytes of FACT_VALUES_FIELD_BYTES: the values of a log fact, whose description the module hash and the fact key of the same record name. A reader with no description writes two hexadecimal digits for each byte up to the last byte that is not zero. The value kind is Number.
	Hexadecimal_Sixteen_Digits  = 6, // An unsigned Integer of 8 bytes with no unit, written as 16 hexadecimal digits with no "0x", as a line wrote an address or a code before the facts. The value kind is Number.
	Hash_Head                   = 7, // A field of the type Bytes of HASH_FIELD_BYTES: a whole hash, written as its head, the hexadecimal digits of its first HASH_HEAD_BYTES bytes and HASH_HEAD_MARK. The value kind is Version.
	Hundredths                  = 8, // An Integer with no unit that counts hundredths: n is written as n / 100 with two decimals, "1.05", "-0.50". The value kind is Number.
	Nanoseconds_As_Microseconds = 9, // An unsigned Integer with no unit that counts nanoseconds, written as microseconds with one decimal cut, not rounded, then " us": 812_499 is "812.4 us". The value kind is Time.
	Tenths                      = 10, // An Integer with no unit that counts tenths: n is written as n / 10 with one decimal, "12.3", "-0.5", "0.0". The value kind is Number.
	Hexadecimal_No_Leading_Zero = 11, // An unsigned Integer of 8 bytes with no unit, written as "0x" and its hexadecimal digits with no zero before the first, as an address: "0x1a2b", "0x0". The value kind is Number.
	Time_Of_Day                 = 12, // An unsigned Integer with no unit that counts the seconds of a day, written as its hours and its minutes, each of two digits at least: 25_440 is "07:04". The value kind is Time.
	Text_View                   = 13, // A field of the type Bytes of TEXT_VIEW_BYTES: a text of any length up to the out-of-line area of its fact, as a German string: its length, its first bytes, and the rest of the text or its offset in the out-of-line area (Text_View). The value kind is None: a text.
	Log_Body                    = 14, // A field of the type Bytes of LOG_BODY_FIELD_BYTES: the bytes of a log record after its head, the value runs and the text of a text record or one part of a log fact, as the form field of the same record says. A reader takes it through the border of the form; a reader with no border writes two hexadecimal digits for each byte up to the last byte that is not zero. The value kind is Number.
}

// The bytes of a text view: a length of 4 bytes, a prefix of 4 bytes, and
// 8 bytes that hold the rest of a short text or the offset of a long one.
TEXT_VIEW_BYTES :: 16
// The bytes of the prefix of a text view: the first bytes of its text,
// which a comparison reads before any out-of-line byte.
TEXT_VIEW_PREFIX_BYTES :: 4
// The longest text that a view holds whole in its 16 bytes, after its
// length: a longer text is in the out-of-line area of its fact.
TEXT_VIEW_INLINE_BYTES_MOST :: TEXT_VIEW_BYTES - 4

// A text of a log fact, as a German string (the string of Umbra and
// CedarDB, the string view of Arrow and DuckDB): its length, then its first
// TEXT_VIEW_PREFIX_BYTES bytes, then the next 8 bytes of a text of at most
// TEXT_VIEW_INLINE_BYTES_MOST bytes, or else the offset of the whole text
// in the out-of-line area of the fact, which follows the fixed record. The
// bytes past a text are zero, so an empty text is 16 zero bytes. No address
// crosses the log: a writer gives a string, and the write copies its bytes
// (system.log_fact). See [text view](term:text-view).
Text_View :: struct {
	length: u32, // The bytes of the text.
	prefix: [TEXT_VIEW_PREFIX_BYTES]u8, // Its first bytes; zero past its length.
	rest:   [8]u8, // A short text: its bytes after the prefix, zero past its length. A long one: the offset of the text in the out-of-line area, a u64, little-endian.
}
#assert(size_of(Text_View) == TEXT_VIEW_BYTES)

// text_view_read gives the text of a view, from its 16 bytes and the
// out-of-line area of its fact, after it checked them: a view is bytes of
// another party. ok is false for a short text with a byte past its length
// that is not zero, for a long text whose bytes pass the area, and for a
// long text whose prefix is not the start of its bytes.
//
// Example: the 16 bytes {5, 0, 0, 0, 'h', 'e', 'l', 'l', 'o', 0, ...} give
// "hello"; {13, 0, 0, 0, 'a', 'b', 'c', 'd', 8, 0, ...} give the 13 bytes
// of the area from the offset 8.
text_view_read :: proc "contextless" (view: []u8, area: []u8) -> (text: []u8, ok: bool) {
	if len(view) != TEXT_VIEW_BYTES {
		return nil, false
	}
	length := u64(view[0]) | u64(view[1]) << 8 | u64(view[2]) << 16 | u64(view[3]) << 24
	if length <= TEXT_VIEW_INLINE_BYTES_MOST {
		for value in view[4 + length:] {
			if value != 0 {
				return nil, false
			}
		}
		return view[4:][:length], true
	}
	offset: u64
	for index in 0 ..< 8 {
		offset |= u64(view[8 + index]) << (8 * u64(index))
	}
	if offset > u64(len(area)) || length > u64(len(area)) - offset {
		return nil, false
	}
	text = area[offset:][:length]
	for index in 0 ..< TEXT_VIEW_PREFIX_BYTES {
		if view[4 + index] != text[index] {
			return nil, false
		}
	}
	return text, true
}

// Text_View_Comparison is what a reader learns of a view and a text from
// the 16 bytes of the view alone.
Text_View_Comparison :: enum u8 {
	Different = 0, // The length or the prefix differ: the texts differ, and no byte of the area was read.
	Equal     = 1, // The view holds the whole text, and it is the text.
	Read_Area = 2, // The length and the prefix are those of the text, and the rest is in the area: read it to know.
}

// text_view_compare_head compares a view with a text from the fixed record
// alone: its length, then its prefix, then the inline rest of a short text.
// A condition `where(path = "...")` reads the out-of-line bytes of a fact
// only when this gives Read_Area.
text_view_compare_head :: proc "contextless" (view: []u8, text: string) -> Text_View_Comparison {
	if len(view) != TEXT_VIEW_BYTES {
		return .Different
	}
	length := u64(view[0]) | u64(view[1]) << 8 | u64(view[2]) << 16 | u64(view[3]) << 24
	if length != u64(len(text)) {
		return .Different
	}
	head := min(len(text), TEXT_VIEW_PREFIX_BYTES)
	if string(view[4:][:head]) != text[:head] {
		return .Different
	}
	if length > TEXT_VIEW_INLINE_BYTES_MOST {
		return .Read_Area
	}
	return string(view[4:][:length]) == text ? .Equal : .Different
}

// The bytes of a hash that a field of the kind Hash_Head writes: the head
// of 8 hexadecimal digits that a line names a start policy by.
HASH_HEAD_BYTES :: 4
// The mark after the head of a hash, which says that the hash goes on.
HASH_HEAD_MARK :: "…"

// field_kind_of_word is the border of the byte of a field kind in a module
// file: the member, or false for a byte that names none.
field_kind_of_word :: proc "contextless" (word: u8) -> (kind: Field_Kind, ok: bool) {
	return enum_word.member_of_word(Field_Kind, u64(word))
}

// field_kind_value_kind gives the value kind of a field kind, for the color
// of its value. Plain gives None: the type of the field and its integer
// unit decide.
field_kind_value_kind :: proc "contextless" (kind: Field_Kind) -> Value_Kind {
	switch kind {
	case .Plain:
		return .None
	case .Hexadecimal:
		return .Number
	case .Status:
		return .Status
	case .Module_Name:
		return .Module
	case .Hash:
		return .Version
	case .Fact_Values:
		return .Number
	case .Hexadecimal_Sixteen_Digits:
		return .Number
	case .Hash_Head:
		return .Version
	case .Hundredths:
		return .Number
	case .Nanoseconds_As_Microseconds:
		return .Time
	case .Tenths, .Hexadecimal_No_Leading_Zero:
		return .Number
	case .Time_Of_Day:
		return .Time
	case .Text_View:
		return .None
	case .Log_Body:
		return .Number
	}
	return .None
}

// The enums of the contract whose members a field of the kind Status
// holds: each reader compiles the contract in, so it writes the name of
// the member (module.contract_enum_member_name). The byte crosses a
// border in each module file (module.Field.contract_enum): a reader takes
// it through contract_enum_of_word. A new enum that a field needs is a new
// member, with its names in the contract.
Contract_Enum :: enum u8 {
	None      = 0, // No enum: a field that is not a Status.
	Status    = 1, // operation.Status: the status of a kernel operation.
	Log_Level = 2, // operation.Log_Level: the level of a log record.
	Log_Record_Form = 3, // operation.Log_Record_Form: what a log record holds, a text or a fact.
	Stop_Cause      = 4, // operation.Stop_Cause: why a process stopped, as the kernel recorded it.
	Stop_Outcome    = 5, // operation.Stop_Outcome: what a process said of its work when it stopped itself.
	Error_Kind      = 6, // errors.Kind: what is wrong, in an error record.
	Error_Unit      = 7, // errors.Unit: what the values of an error record count.
	Object_Kind     = 8, // operation.Object_Kind: the kind of the object of a handle.
	Load_Stage      = 9, // module.Load_Stage: the stage of a load that failed.
	Module_Error    = 10, // module.Error: what is not valid in a module file.
	Load_Difference = 11, // module.Difference: what differs between an export and its replacement.
	Storage_Status  = 12, // storage_status.Status: the result of a call of a client of the storage service.
	Call_Outcome    = 13, // call_outcome.Call_Outcome: how a call ended (src/md/api/call_outcome.md).
	Pointer_Part    = 14, // pointer_pictures.Part: the part of a pointer theme file where a check found a problem.
	Pointer_Field   = 15, // pointer_pictures.Field: the field of a pointer theme file that holds the bad value.
	Pointer_Problem = 16, // pointer_pictures.Problem_Kind: the rule that a pointer theme file breaks.
}

// contract_enum_of_word is the border of the byte of a contract enum in a
// module file: the member, or false for a byte that names none.
contract_enum_of_word :: proc "contextless" (word: u8) -> (which: Contract_Enum, ok: bool) {
	return enum_word.member_of_word(Contract_Enum, u64(word))
}

// The type of the source of a field of the kind Status: the package of the
// contract that declares the enum, and its name there. An enum whose words
// a process carries from another party, or that a record holds beside
// fields of 8 bytes, also has a word type: a distinct unsigned or signed
// integer at least as large as the enum (module.CONTRACT_ENUM_WORD_SIZES),
// which holds the word as it came. A writer of a log fact copies a word
// that names no member with no cast to the enum, and a field of 8 bytes
// leaves no padding; the reader writes the name of the member, or the
// number.
Contract_Enum_Type :: struct {
	package_name: string, // The folder of the package under src/library/modus/contract.
	name:         string, // The name of the enum in that package.
	word_name:    string, // The name of its word type in that package, or "" when it has none.
}

// The type of the source of each contract enum: the one table that names
// them for the tool and for a reader that writes the type of a field.
@(rodata)
CONTRACT_ENUM_TYPES := [Contract_Enum]Contract_Enum_Type {
	.None      = {},
	.Status    = {package_name = "operation", name = "Status", word_name = "Status_Word"},
	.Log_Level = {package_name = "operation", name = "Log_Level"},
	.Log_Record_Form = {package_name = "operation", name = "Log_Record_Form", word_name = "Log_Record_Form_Word"},
	.Stop_Cause      = {package_name = "operation", name = "Stop_Cause", word_name = "Stop_Cause_Word"},
	.Stop_Outcome    = {package_name = "operation", name = "Stop_Outcome", word_name = "Stop_Outcome_Word"},
	.Error_Kind      = {package_name = "errors", name = "Kind", word_name = "Kind_Word"},
	.Error_Unit      = {package_name = "errors", name = "Unit", word_name = "Unit_Word"},
	.Object_Kind     = {package_name = "operation", name = "Object_Kind", word_name = "Object_Kind_Word"},
	.Load_Stage      = {package_name = "module", name = "Load_Stage", word_name = "Load_Stage_Word"},
	.Module_Error    = {package_name = "module", name = "Error", word_name = "Error_Word"},
	.Load_Difference = {package_name = "module", name = "Difference", word_name = "Difference_Word"},
	.Storage_Status  = {package_name = "storage_status", name = "Status", word_name = "Status_Word"},
	.Call_Outcome    = {package_name = "call_outcome", name = "Call_Outcome", word_name = "Call_Outcome_Word"},
	.Pointer_Part    = {package_name = "pointer_pictures", name = "Part", word_name = "Part_Word"},
	.Pointer_Field   = {package_name = "pointer_pictures", name = "Field", word_name = "Field_Word"},
	.Pointer_Problem = {package_name = "pointer_pictures", name = "Problem_Kind", word_name = "Problem_Kind_Word"},
}

// The types that a field of a record takes to state its field kind, in
// place of an integer or of an array of bytes. Each is distinct, so the
// compiler refuses a value of another kind at a write of the field; its
// bytes are those of the type that it names. The tool that describes a
// module finds the kind of each name in FIELD_KIND_TYPES
// (docs/MODULE_CONTRACT.md, "The kind of a field").

// An Integer field of 1 byte, written in hexadecimal.
Hexadecimal_8 :: distinct u8
// An Integer field of 2 bytes, written in hexadecimal.
Hexadecimal_16 :: distinct u16
// An Integer field of 4 bytes, written in hexadecimal.
Hexadecimal_32 :: distinct u32
// An Integer field of 8 bytes, written in hexadecimal.
Hexadecimal_64 :: distinct u64

// The bytes of a Text field that holds the name of a module or of a
// process: the longest name of a process and one zero byte.
MODULE_NAME_FIELD_BYTES :: 32
// A Text field that holds the name of a module or of a process, with zero
// bytes after it.
Module_Name_Field :: distinct [MODULE_NAME_FIELD_BYTES]u8

// module_name_field gives the field of a record that holds the name of a
// module or of a process: its bytes, cut after MODULE_NAME_FIELD_BYTES - 1
// bytes, then zero bytes. The last byte is always zero, so a reader finds
// the end of the name in the field.
//
// Example: `module_name_field("storage")` is "storage" and 25 zero bytes.
module_name_field :: proc "contextless" (name: string) -> (field: Module_Name_Field) {
	copy(field[:MODULE_NAME_FIELD_BYTES - 1], name)
	return
}

// text_field gives a Text field of N bytes: the text, cut after N - 1
// bytes, then zero bytes. A writer of a log fact fills a field of a name
// with it: the last byte is always zero.
//
// Example: `text_field("alice", 24)` is "alice" and 19 zero bytes.
text_field :: proc "contextless" (text: string, $N: int) -> (field: [N]u8) where N >= 1 {
	copy(field[:N - 1], text)
	return
}

// The bytes of a hash of a module: the most bytes of a field of the kind
// Hash. A shorter field holds the head of a hash.
HASH_FIELD_BYTES :: 32
// A field of the type Bytes that holds a BLAKE3 hash.
Hash_Field :: distinct [HASH_FIELD_BYTES]u8

// The bytes of the head of a hash that a line writes whole, as 32
// hexadecimal digits, before "...".
HASH_SIXTEEN_BYTES :: 16
// A field of the type Bytes of the kind Hash that holds the first 16 bytes
// of a hash: a reader writes its 32 digits, and the template writes what
// follows them.
Hash_Sixteen_Bytes_Field :: distinct [HASH_SIXTEEN_BYTES]u8

// The bytes of the values of one log fact: operation.LOG_FACT_VALUE_CAPACITY,
// which module checks, because this package imports no other.
FACT_VALUES_FIELD_BYTES :: 144
// A field of the type Bytes that holds the values of a log fact, whose
// description the module hash and the fact key of the same record name
// (src/md/features/log_facts.md, "The reader path").
Fact_Values_Field :: distinct [FACT_VALUES_FIELD_BYTES]u8

// The bytes of the body of a log record, after its head of 64 bytes: its
// value runs and its text, or one part of a log fact
// (operation.Log_Record, from runs; the contract output.Log_Output_Record).
// operation checks the number, because this package imports no other.
LOG_BODY_FIELD_BYTES :: 192
// A field of the type Bytes that holds the body of a log record, whose
// form field in the same record says what it holds.
Log_Body_Field :: distinct [LOG_BODY_FIELD_BYTES]u8

// An Integer field of 8 bytes, written as 16 hexadecimal digits with no
// "0x": an address, or a response code of a device.
Hexadecimal_Sixteen_Digits :: distinct u64

// A field of the type Bytes that holds a whole BLAKE3 hash, which a reader
// writes as its head: "1a2b3c4d…". The field keeps the whole hash, so a
// reader that filters or compares has each byte.
Hash_Head_Field :: distinct [HASH_FIELD_BYTES]u8

// An Integer field of 8 bytes with a sign that counts hundredths: 105 is
// written "1.05", -50 "-0.50".
Hundredths :: distinct i64

// An Integer field of 8 bytes that counts nanoseconds, written as
// microseconds with one decimal: 812_499 is "812.4 us".
Nanoseconds_As_Microseconds :: distinct u64

// An Integer field of 8 bytes with a sign that counts tenths: 123 is
// written "12.3", -5 "-0.5".
Tenths :: distinct i64

// An Integer field of 8 bytes written as "0x" and its digits with no zero
// before the first, as an address: "0x1a2b".
Hexadecimal_No_Leading_Zero :: distinct u64

// An Integer field of 8 bytes that counts the seconds of a day, written as
// "07:04".
Time_Of_Day :: distinct u64

// The name of a type of a field with a field kind, its kind, its size in
// bytes, and its sign for an Integer.
Field_Kind_Type :: struct {
	name:     string, // The name of the type in this package.
	kind:     Field_Kind, // How a reader writes the value.
	size:     u32, // The bytes of the field.
	unsigned: bool, // An Integer: true for an unsigned integer.
}

// Each type of a field with a field kind: the one table that names them
// for the tool. A test checks each size and each sign against the type.
@(rodata)
FIELD_KIND_TYPES := [?]Field_Kind_Type {
	{"Hexadecimal_8", .Hexadecimal, 1, true},
	{"Hexadecimal_16", .Hexadecimal, 2, true},
	{"Hexadecimal_32", .Hexadecimal, 4, true},
	{"Hexadecimal_64", .Hexadecimal, 8, true},
	{"Module_Name_Field", .Module_Name, MODULE_NAME_FIELD_BYTES, false},
	{"Hash_Field", .Hash, HASH_FIELD_BYTES, false},
	{"Hash_Sixteen_Bytes_Field", .Hash, HASH_SIXTEEN_BYTES, false},
	{"Fact_Values_Field", .Fact_Values, FACT_VALUES_FIELD_BYTES, false},
	{"Hexadecimal_Sixteen_Digits", .Hexadecimal_Sixteen_Digits, 8, true},
	{"Hash_Head_Field", .Hash_Head, HASH_FIELD_BYTES, false},
	{"Hundredths", .Hundredths, 8, false},
	{"Nanoseconds_As_Microseconds", .Nanoseconds_As_Microseconds, 8, true},
	{"Tenths", .Tenths, 8, false},
	{"Hexadecimal_No_Leading_Zero", .Hexadecimal_No_Leading_Zero, 8, true},
	{"Time_Of_Day", .Time_Of_Day, 8, true},
	{"Text_View", .Text_View, TEXT_VIEW_BYTES, false},
	{"Log_Body_Field", .Log_Body, LOG_BODY_FIELD_BYTES, false},
}

// field_kind_of_type_name gives the row of FIELD_KIND_TYPES of the name of
// a type. ok is false for another name.
field_kind_of_type_name :: proc "contextless" (name: string) -> (row: Field_Kind_Type, ok: bool) {
	for item in FIELD_KIND_TYPES {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// A hash, or the head of one: two hexadecimal digits for each byte, the
// first byte first. The kind is Version.
Hash :: struct {
	bytes: []u8, // The bytes of the hash, or of its head.
}

// The name of a process or of a module, as it is. The kind is Module.
Module_Name :: struct {
	name: string, // The name.
}

// size_unit_text gives the text of a unit of a size, or an empty text for a
// unit out of the enumeration.
size_unit_text :: proc "contextless" (unit: Size_Unit) -> string {
	return unit <= max(Size_Unit) ? SIZE_UNIT_TEXTS[unit] : ""
}

// duration_unit_text gives the text of a unit of a duration, or an empty
// text for a unit out of the enumeration.
duration_unit_text :: proc "contextless" (unit: Duration_Unit) -> string {
	return unit <= max(Duration_Unit) ? DURATION_UNIT_TEXTS[unit] : ""
}

// value_run_add adds the run of a part that a writer put at the bytes
// start ..< end of its text. A part of no kind, a part with no byte, a part
// past the bytes that a start can name, or a table of runs that is full:
// no run, and the part stays plain. The text never changes.
value_run_add :: proc "contextless" (runs: []Value_Run_In_Call, count: ^int, start, end: int, kind: Value_Kind) {
	if kind == .None || start < 0 || end <= start || end > 0xFFFF || count^ >= len(runs) {
		return
	}
	runs[count^] = {start = u16(start), length = u16(end - start), kind = u8(kind)}
	count^ += 1
}

// value_runs_cut keeps the runs inside the first `length` bytes of a text:
// a run that starts at or after the end goes, and a run that crosses it
// ends there. It gives the new count. A writer calls it when the text ends
// with the cut mark, so that no run colors the mark.
value_runs_cut :: proc "contextless" (runs: []Value_Run_In_Call, count: int, length: int) -> int {
	kept := 0
	for index in 0 ..< min(count, len(runs)) {
		run := runs[index]
		if int(run.start) >= length {
			break
		}
		run.length = u16(min(int(run.length), length - int(run.start)))
		runs[kept] = run
		kept += 1
	}
	return kept
}

// value_runs_after keeps the parts of the runs at or after the byte `from`
// of a text, from the start of what follows it: a writer that sent the first
// `from` bytes as one line keeps the runs of the rest. It gives the new
// count.
value_runs_after :: proc "contextless" (runs: []Value_Run_In_Call, count: int, from: int) -> int {
	kept := 0
	for index in 0 ..< min(count, len(runs)) {
		run := runs[index]
		start := int(run.start)
		end := start + int(run.length)
		if end <= from {
			continue
		}
		start = max(start, from)
		runs[kept] = {start = u16(start - from), length = u16(end - start), kind = run.kind}
		kept += 1
	}
	return kept
}

// value_runs_check says if the runs fit a text of `length` bytes: each run
// inside the text, after the run before it, with at least one byte and a
// kind that exists and is not None. The runs come from another process: the
// kernel checks them once, in its own copy, before it uses them.
value_runs_check :: proc "contextless" (runs: []Value_Run_In_Call, length: int) -> bool {
	end := 0
	for run in runs {
		if run.length == 0 || int(run.start) < end || int(run.start) + int(run.length) > length {
			return false
		}
		if kind, kind_ok := value_kind_of(run.kind); !kind_ok || kind == .None {
			return false
		}
		// The byte with no use yet is zero, so that it can get a use later.
		if run.reserved != 0 {
			return false
		}
		end = int(run.start) + int(run.length)
	}
	return true
}

// value_runs_of_record gives the runs of one record: the part of the runs
// of a text that falls in the bytes record_start ..< record_start +
// record_length, from the start of the record. A run that crosses the bound
// of two records is one run in each. At most len(into) runs: a record with
// more parts keeps its first runs, and the rest of its text is plain. The
// runs must be in order (value_runs_check). The work is one pass over the
// runs: at most len(runs) steps.
value_runs_of_record :: proc "contextless" (runs: []Value_Run_In_Call, record_start, record_length: int, into: []Value_Run) -> int {
	count := 0
	record_end := record_start + record_length
	for run in runs {
		run_start := int(run.start)
		run_end := run_start + int(run.length)
		if run_end <= record_start {
			continue
		}
		if run_start >= record_end || count == len(into) {
			break
		}
		start := max(run_start, record_start) - record_start
		end := min(run_end, record_end) - record_start
		if start > 0xFF || end - start > 0xFF {
			break
		}
		into[count] = {start = u8(start), length = u8(end - start), kind = run.kind}
		count += 1
	}
	return count
}

// value_run_in_text gives the bytes and the kind of a run of a record inside
// a text of text_count bytes: a run that the record cannot hold, and a byte
// of a kind that names no kind or None, give nothing. A reader of a record
// calls it before it indexes the text: it is the border of the kind.
value_run_in_text :: proc "contextless" (run: Value_Run, text_count: int) -> (start, end: int, kind: Value_Kind, ok: bool) {
	start = int(run.start)
	end = start + int(run.length)
	read, read_ok := value_kind_of(run.kind)
	if run.length == 0 || end > text_count || !read_ok || read == .None {
		return 0, 0, .None, false
	}
	return start, end, read, true
}
