// The kinds of the values that the system shows, and the value runs of a
// text: which bytes of a text are a number, a size, a time or a module.
//
// One enumeration of kinds for the system and for the site of the system:
// the site writes each kind with its class and its icon, a program draws it
// in its color, and both take the color from one table of the design rules
// (src/library/support/graphics/value_colors.odin). A writer states the kind of each
// part that it writes: no text is classified by its look.
//
// A log record keeps the runs of its text (operation.Log_Record), so that a
// reader shows each value in the color of its kind. The text itself does
// not change: the serial port, the machine tests and a reader that ignores
// the runs read the same bytes as before (docs/TOOLS.md, "The log").
package value_kinds

// What a value is: the kind of a part of a text. See
// [value run](term:value-run).
Value_Kind :: enum u8 {
	None      = 0, // Not a value: a name or a text.
	Number    = 1, // A count, a place, an index or an address.
	Size      = 2, // A size in bytes, pages or blocks.
	Time      = 3, // A duration, a date or a time.
	Handle    = 4, // A handle number, or the index of a handle in a context.
	Value     = 5, // A plain value of the context of a program: not a handle.
	Grant     = 6, // A grant of a program.
	Status    = 7, // A status, an error kind or the state of a property.
	Type      = 8, // A type of the contract or of a module.
	Operation = 9, // A kernel operation.
	Command   = 10, // A command of the console.
	Module    = 11, // A module or a program.
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
// start.
Value_Run :: struct {
	start:  u8, // The first byte of the value in the text of the record.
	length: u8, // The bytes of the value.
	kind:   Value_Kind, // What the value is.
}
#assert(size_of(Value_Run) == 3)

// A value run of a text that is longer than one record: the text of one Log
// operation (at most 4096 bytes), or the text that the kernel writes for
// itself. The kernel cuts these runs at the bounds of the records.
Value_Run_In_Call :: struct {
	start:    u16, // The first byte of the value in the text of the call.
	length:   u16, // The bytes of the value.
	kind:     Value_Kind, // What the value is.
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
		return SIZE_UNIT_TEXTS[Size_Unit(integer_unit.unit)]
	case .Time:
		return DURATION_UNIT_TEXTS[Duration_Unit(integer_unit.unit)]
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

// A hash, or the head of one: two hexadecimal digits for each byte, the
// first byte first. The kind is Version.
Hash :: struct {
	bytes: []u8, // The bytes of the hash, or of its head.
}

// The name of a program or of a module, as it is. The kind is Module.
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
	runs[count^] = {start = u16(start), length = u16(end - start), kind = kind}
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
// kind that exists and is not None. The runs come from another program: the
// kernel checks them once, in its own copy, before it uses them.
value_runs_check :: proc "contextless" (runs: []Value_Run_In_Call, length: int) -> bool {
	end := 0
	for run in runs {
		if run.length == 0 || int(run.start) < end || int(run.start) + int(run.length) > length {
			return false
		}
		if run.kind == .None || u8(run.kind) > u8(max(Value_Kind)) {
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

// value_run_in_text gives the bytes of a run of a record inside a text of
// text_count bytes: a run that the record cannot hold gives nothing. A
// reader of a record calls it before it indexes the text.
value_run_in_text :: proc "contextless" (run: Value_Run, text_count: int) -> (start, end: int, ok: bool) {
	start = int(run.start)
	end = start + int(run.length)
	if run.length == 0 || end > text_count || run.kind == .None || u8(run.kind) > u8(max(Value_Kind)) {
		return 0, 0, false
	}
	return start, end, true
}
