// The operation sequence (src/md/infrastructure/kernel_fuzzing.md, "The
// sequence format and the grammar"): the fuzz input of the kernel
// operations. The tool writes it; a program of a test machine reads it,
// then runs each sequence step as one command record of its kernel ring.
//
// A sequence names no handle number and no address of one run. A handle
// argument names a start handle by its role, or the result of an earlier
// sequence step by the place of that step. An address argument names a
// sequence area and an offset in it. So one sequence means the same at
// each run.
//
// The bytes, all numbers little-endian:
//
//   Header_Record                         16 bytes
//   Area_Record, area_count times          8 bytes each
//   Step_Record, step_count times        232 bytes each
//   the content of each area, in the order of the areas
//
// and no other byte.
//
// The parts:
//
// - `Header_Record`, `Area_Record`, `Step_Record`, `Argument_Record`: the
//   bytes, as words.
// - `Sequence`, `Sequence_Step`, `Sequence_Area`, `Argument`: a sequence
//   that `check` accepted, with each word as its member.
// - `check`, `Refusal`, `Problem`: the reader, the one border of the words.
// - `write`, `size`: the writer.
//
// See [operation sequence](term:operation-sequence),
// [sequence step](term:sequence-step),
// [argument source](term:argument-source) and
// [sequence area](term:sequence-area).
package operation_sequence

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/operation"
import "modus:contract/ring"

MAGIC :: u64(0x5351_4553_5245_504F) // The bytes "OPERSEQS".
FORMAT :: 1 // The format of the bytes. The reader refuses another.

// The most sequence steps of one sequence. Each one is a kernel entry or a
// part of one, and one sequence runs in one new program, so a short
// sequence keeps the steps that a finding needs easy to read.
STEPS_MOST :: 64
// The values of one command record (`ring.Record`): the arguments of a
// sequence step, and the values of its completion that a later step names.
ARGUMENTS :: operation.ERROR_DETAILS_VALUE + 1
// The most sequence areas of one sequence.
AREAS_MOST :: 8
// The most pages of one sequence area. The runner maps one page with no
// access after each area, so a read past the end of an area faults.
AREA_PAGES_MOST :: 16
// The most content bytes of all the sequence areas of one sequence.
CONTENT_BYTES_MOST :: 4096
// The most sequence steps of one kernel entry: the smallest kernel ring
// holds their command records.
ENTRY_STEPS_MOST :: ring.CAPACITY
// The largest offset of the result of an earlier step: the bytes of the
// largest area and of its page with no access.
RESULT_OFFSET_MOST :: AREA_PAGES_MOST * operation.PAGE_SIZE + operation.PAGE_SIZE - 1

HEADER_SIZE :: 16
AREA_SIZE :: 8
ARGUMENT_SIZE :: 32
STEP_SIZE :: 8 + ARGUMENTS * ARGUMENT_SIZE
// The bytes of the largest sequence.
SEQUENCE_BYTES_MOST :: HEADER_SIZE + AREAS_MOST * AREA_SIZE + STEPS_MOST * STEP_SIZE + CONTENT_BYTES_MOST

// The first 16 bytes of a sequence.
Header_Record :: struct {
	magic:      u64, // `MAGIC`.
	format:     u32, // `FORMAT`.
	step_count: u16, // The sequence steps: at most `STEPS_MOST`. 0 is a valid sequence.
	area_count: u16, // The sequence areas: at most `AREAS_MOST`.
}
#assert(size_of(Header_Record) == HEADER_SIZE)

// One sequence area, as the bytes hold it.
Area_Record :: struct {
	pages:         u32, // From 1 to `AREA_PAGES_MOST`.
	content_bytes: u32, // The bytes at the start of the area that the sequence gives; the rest is zero.
}
#assert(size_of(Area_Record) == AREA_SIZE)

// One argument of a sequence step, as the bytes hold it: the word of its
// `Argument_Source`, then three words whose meaning the source gives. A
// word that the source does not use is 0.
Argument_Record :: struct {
	source: u64, // The word of an `Argument_Source`.
	index:  u64, // Area_Handle, Area_Address: the area. Thread_Entry: the word of a `Thread_Entry`. Result: the step.
	place:  u64, // Result: the value of the completion, below `ARGUMENTS`.
	value:  u64, // Value: the word. Area_Address, Result: the offset that the runner adds.
}
#assert(size_of(Argument_Record) == ARGUMENT_SIZE)

// One sequence step, as the bytes hold it.
//
// The operation word passes to the kernel as it is: a word that names no
// operation reaches the kernel, which must refuse it with `Bad_Operation`.
// Only its bit `COMMAND_NAMES_ERROR_DETAILS` is refused, because the flag
// `No_Error_Details` says that fact.
Step_Record :: struct {
	operation: u32, // The kind of the command record, with no bit `COMMAND_NAMES_ERROR_DETAILS`.
	flags:     u32, // The word of the `Step_Flags`.
	arguments: [ARGUMENTS]Argument_Record,
}
#assert(size_of(Step_Record) == STEP_SIZE)

// Where the value of one argument comes from. The runner converts each
// argument into the word of the command record.
Argument_Source :: enum u64 {
	Value        = 0, // The word `value`, as it is.
	Budget       = 1, // The start handle of the budget of the sequence.
	Log          = 2, // The start handle of the log.
	Machine      = 3, // The start handle of the machine: 0 while the service holds the machine with Physical only, which it cannot give, so the kernel refuses each step that needs it.
	Area_Handle  = 4, // The start handle of the memory object of the area `area`.
	Area_Address = 5, // The address of the area `area`, plus `offset`: at most the area and its page with no access.
	Thread_Entry = 6, // The address of a thread entry of the runner: the only code that a sequence names.
	Result       = 7, // The value `place` of the completion of the earlier step `step`, plus `offset`.
}

// The thread entries of the runner, which a sequence step names as code.
Thread_Entry :: enum u64 {
	Wait_On_Word      = 0, // Waits on a word of the runner, with no deadline.
	Return            = 1, // Returns at once: the thread ends.
	Read_Address_Zero = 2, // Reads the address 0: a page fault of the thread.
}

Step_Flag :: enum u32 {
	// The command names no table of error details: its seventh value is
	// its seventh argument. With a table, the runner writes the place of
	// the table there, so the seventh argument does not pass.
	No_Error_Details = 0,
	// The step runs in the same kernel entry as the step before it: the
	// runner writes both command records, then enters the kernel once.
	Same_Entry       = 1,
}
Step_Flags :: bit_set[Step_Flag; u32]
// The bits of the flags that the format knows. The reader refuses each
// other bit.
STEP_FLAGS_KNOWN :: u32(1) << u32(Step_Flag.No_Error_Details) | u32(1) << u32(Step_Flag.Same_Entry)

// One argument of a sequence step that `check` accepted. Only the fields
// of its source have a meaning; the others are zero.
Argument :: struct {
	source: Argument_Source,
	area:   int, // Area_Handle, Area_Address: below the area count.
	step:   int, // Result: below the first step of the kernel entry of this step.
	place:  int, // Result: below `ARGUMENTS`.
	entry:  Thread_Entry, // Thread_Entry.
	value:  u64, // Value.
	offset: u64, // Area_Address, Result.
}

// One sequence step that `check` accepted.
Sequence_Step :: struct {
	operation: u32, // The kind of the command record, as the bytes give it.
	flags:     Step_Flags,
	arguments: [ARGUMENTS]Argument,
}

// One sequence area that `check` accepted.
Sequence_Area :: struct {
	pages:         int, // From 1 to `AREA_PAGES_MOST`.
	content_bytes: int, // At most the bytes of its pages.
}

// A sequence that `check` accepted: a copy of its bytes, with each word as
// its member. A caller holds it in its own memory, so no other party can
// change a value after the check.
Sequence :: struct {
	step_count: int,
	area_count: int,
	steps:      [STEPS_MOST]Sequence_Step,
	areas:      [AREAS_MOST]Sequence_Area,
	content:    [CONTENT_BYTES_MOST]u8, // The content of each area, one after the other, in the order of the areas.
}

// Why the reader refuses a sequence. The comment of each problem says what
// the `index` of the `Refusal` names.
Problem :: enum u8 {
	None              = 0, // The sequence follows its format.
	Too_Small         = 1, // It has fewer bytes than a header.
	Magic             = 2, // It does not start with `MAGIC`.
	Format            = 3, // It has another format.
	Step_Count        = 4, // It counts more steps than `STEPS_MOST`.
	Area_Count        = 5, // It counts more areas than `AREAS_MOST`.
	Size              = 6, // Its size is not its header, its areas, its steps and their contents exactly.
	Area_Pages        = 7, // The area `index` has 0 pages, or more than `AREA_PAGES_MOST`.
	Area_Content      = 8, // The content of the area `index` passes its pages, or the contents up to it pass `CONTENT_BYTES_MOST`.
	Operation_Word    = 9, // The operation word of the step `index` has the bit `COMMAND_NAMES_ERROR_DETAILS`.
	Step_Flags        = 10, // The step `index` has a flag that the format does not know.
	Entry_First       = 11, // The first step has the flag `Same_Entry`: no step is before it.
	Entry_Steps       = 12, // The step `index` makes its kernel entry longer than `ENTRY_STEPS_MOST`.
	Argument_Source   = 13, // The argument `argument` of the step `index` has a source word that names no member.
	Unused_Field      = 14, // The argument has a word that its source does not use, and the word is not 0.
	Area_Index        = 15, // The argument names an area that the sequence does not have.
	Offset            = 16, // The offset of the argument passes its area and its page with no access, or `RESULT_OFFSET_MOST`.
	Thread_Entry      = 17, // The argument has an entry word that names no `Thread_Entry`.
	Result_Later      = 18, // The argument names the result of this step or of a later one.
	Result_Same_Entry = 19, // The argument names the result of a step of the same kernel entry: the runner writes the command before that result exists.
	Result_Place      = 20, // The argument names a value of a completion at `ARGUMENTS` or past it.
}

// What `check` found: the problem, the step or the area that it names
// (-1 for a problem of the header or of the size), and the argument of the
// step (-1 for a problem of a whole step or of an area).
Refusal :: struct {
	problem:  Problem,
	index:    int,
	argument: int,
}

// check reads the bytes of a sequence into `sequence`, and checks each
// rule of the format on the way. Each word that names a member becomes the
// member here, at the one border; a word that names none is refused.
//
// The caller gives a copy of the bytes that no other party changes while
// `check` reads them. A refused sequence leaves `sequence` zero, so a
// caller cannot run a part of it.
//
// Example: a sequence whose second step names the result of its third
// step gives `{.Result_Later, 1, <the argument>}`.
check :: proc "contextless" (bytes: []u8, sequence: ^Sequence) -> Refusal {
	refusal := check_into(bytes, sequence)
	if refusal.problem != .None {
		sequence^ = {}
	}
	return refusal
}

@(private = "file")
check_into :: proc "contextless" (bytes: []u8, sequence: ^Sequence) -> Refusal {
	sequence^ = {}
	if len(bytes) < HEADER_SIZE {
		return {.Too_Small, -1, -1}
	}
	if byte_order.read_u64_little_endian(bytes, int(offset_of(Header_Record, magic))) != MAGIC {
		return {.Magic, -1, -1}
	}
	if byte_order.read_u32_little_endian(bytes, int(offset_of(Header_Record, format))) != FORMAT {
		return {.Format, -1, -1}
	}
	step_count := int(byte_order.read_u16_little_endian(bytes, int(offset_of(Header_Record, step_count))))
	area_count := int(byte_order.read_u16_little_endian(bytes, int(offset_of(Header_Record, area_count))))
	if step_count > STEPS_MOST {
		return {.Step_Count, -1, -1}
	}
	if area_count > AREAS_MOST {
		return {.Area_Count, -1, -1}
	}
	records_size := HEADER_SIZE + area_count * AREA_SIZE + step_count * STEP_SIZE
	if len(bytes) < records_size {
		return {.Size, -1, -1}
	}
	sequence.step_count = step_count
	sequence.area_count = area_count

	content_total := 0
	for area in 0 ..< area_count {
		offset := HEADER_SIZE + area * AREA_SIZE
		pages := byte_order.read_u32_little_endian(bytes, offset + int(offset_of(Area_Record, pages)))
		content_bytes := byte_order.read_u32_little_endian(bytes, offset + int(offset_of(Area_Record, content_bytes)))
		if pages == 0 || pages > AREA_PAGES_MOST {
			return {.Area_Pages, area, -1}
		}
		if u64(content_bytes) > u64(pages) * operation.PAGE_SIZE || content_total + int(content_bytes) > CONTENT_BYTES_MOST {
			return {.Area_Content, area, -1}
		}
		content_total += int(content_bytes)
		sequence.areas[area] = {pages = int(pages), content_bytes = int(content_bytes)}
	}
	if len(bytes) != records_size + content_total {
		return {.Size, -1, -1}
	}

	entry_first := 0
	entry_steps := 0
	for step in 0 ..< step_count {
		offset := HEADER_SIZE + area_count * AREA_SIZE + step * STEP_SIZE
		operation_word := byte_order.read_u32_little_endian(bytes, offset + int(offset_of(Step_Record, operation)))
		flags_word := byte_order.read_u32_little_endian(bytes, offset + int(offset_of(Step_Record, flags)))
		if operation_word & operation.COMMAND_NAMES_ERROR_DETAILS != 0 {
			return {.Operation_Word, step, -1}
		}
		if flags_word & ~STEP_FLAGS_KNOWN != 0 {
			return {.Step_Flags, step, -1}
		}
		flags := transmute(Step_Flags)flags_word
		if .Same_Entry in flags {
			if step == 0 {
				return {.Entry_First, step, -1}
			}
			entry_steps += 1
			if entry_steps > ENTRY_STEPS_MOST {
				return {.Entry_Steps, step, -1}
			}
		} else {
			entry_first = step
			entry_steps = 1
		}
		read := &sequence.steps[step]
		read.operation = operation_word
		read.flags = flags
		for argument in 0 ..< ARGUMENTS {
			argument_offset := offset + int(offset_of(Step_Record, arguments)) + argument * ARGUMENT_SIZE
			problem := argument_read(bytes, argument_offset, sequence, step, entry_first, &read.arguments[argument])
			if problem != .None {
				return {problem, step, argument}
			}
		}
	}
	content_offset := records_size
	copy(sequence.content[:content_total], bytes[content_offset:content_offset + content_total])
	return {.None, -1, -1}
}

// argument_read reads one argument record: its source word becomes its
// member, and each other word is checked against what that source uses.
@(private = "file")
argument_read :: proc "contextless" (bytes: []u8, offset: int, sequence: ^Sequence, step, entry_first: int, argument: ^Argument) -> Problem {
	source_word := byte_order.read_u64_little_endian(bytes, offset + int(offset_of(Argument_Record, source)))
	index_word := byte_order.read_u64_little_endian(bytes, offset + int(offset_of(Argument_Record, index)))
	place_word := byte_order.read_u64_little_endian(bytes, offset + int(offset_of(Argument_Record, place)))
	value_word := byte_order.read_u64_little_endian(bytes, offset + int(offset_of(Argument_Record, value)))
	source, known := enum_word.member_of_word(Argument_Source, source_word)
	if !known {
		return .Argument_Source
	}
	argument^ = {source = source}
	switch source {
	case .Value:
		if index_word != 0 || place_word != 0 {
			return .Unused_Field
		}
		argument.value = value_word
	case .Budget, .Log, .Machine:
		if index_word != 0 || place_word != 0 || value_word != 0 {
			return .Unused_Field
		}
	case .Area_Handle:
		if place_word != 0 || value_word != 0 {
			return .Unused_Field
		}
		if index_word >= u64(sequence.area_count) {
			return .Area_Index
		}
		argument.area = int(index_word)
	case .Area_Address:
		if place_word != 0 {
			return .Unused_Field
		}
		if index_word >= u64(sequence.area_count) {
			return .Area_Index
		}
		// The offset can reach the page with no access after the area: a
		// record across the end of an area is an input that the kernel
		// must refuse.
		area_bytes := u64(sequence.areas[index_word].pages) * operation.PAGE_SIZE
		if value_word > area_bytes + operation.PAGE_SIZE - 1 {
			return .Offset
		}
		argument.area = int(index_word)
		argument.offset = value_word
	case .Thread_Entry:
		if place_word != 0 || value_word != 0 {
			return .Unused_Field
		}
		entry, entry_known := enum_word.member_of_word(Thread_Entry, index_word)
		if !entry_known {
			return .Thread_Entry
		}
		argument.entry = entry
	case .Result:
		if index_word >= u64(step) {
			return .Result_Later
		}
		if index_word >= u64(entry_first) {
			return .Result_Same_Entry
		}
		if place_word >= ARGUMENTS {
			return .Result_Place
		}
		if value_word > RESULT_OFFSET_MOST {
			return .Offset
		}
		argument.step = int(index_word)
		argument.place = int(place_word)
		argument.offset = value_word
	}
	return .None
}

// size gives the bytes that `write` writes for a sequence, or false when
// a count does not fit its array or its record: a step count or an area
// count out of 0 to its most, a negative count of pages or of content
// bytes, or contents that pass `CONTENT_BYTES_MOST`.
size :: proc "contextless" (sequence: ^Sequence) -> (bytes: int, ok: bool) {
	if sequence.step_count < 0 || sequence.step_count > STEPS_MOST || sequence.area_count < 0 || sequence.area_count > AREAS_MOST {
		return 0, false
	}
	content_total := 0
	for area in sequence.areas[:sequence.area_count] {
		if area.pages < 0 || u64(area.pages) > u64(max(u32)) || area.content_bytes < 0 || area.content_bytes > CONTENT_BYTES_MOST - content_total {
			return 0, false
		}
		content_total += area.content_bytes
	}
	return HEADER_SIZE + sequence.area_count * AREA_SIZE + sequence.step_count * STEP_SIZE + content_total, true
}

// write writes the bytes of a sequence at the start of `out`, and gives
// them. It refuses only a sequence that `size` refuses, and an `out` that
// is too short. It checks no other rule of the format, so a test writes a
// sequence that `check` must refuse, and the generator of the tool is
// checked by `check`, not by its writer.
//
// A field of an argument that its source does not use is not written: the
// bytes hold 0 there.
write :: proc "contextless" (out: []u8, sequence: ^Sequence) -> (written: []u8, ok: bool) {
	total, total_ok := size(sequence)
	if !total_ok || len(out) < total {
		return nil, false
	}
	bytes := out[:total]
	byte_order.write_u64_little_endian(bytes, int(offset_of(Header_Record, magic)), MAGIC)
	byte_order.write_u32_little_endian(bytes, int(offset_of(Header_Record, format)), FORMAT)
	byte_order.write_u16_little_endian(bytes, int(offset_of(Header_Record, step_count)), u16(sequence.step_count))
	byte_order.write_u16_little_endian(bytes, int(offset_of(Header_Record, area_count)), u16(sequence.area_count))
	content_total := 0
	for area, index in sequence.areas[:sequence.area_count] {
		offset := HEADER_SIZE + index * AREA_SIZE
		byte_order.write_u32_little_endian(bytes, offset + int(offset_of(Area_Record, pages)), u32(area.pages))
		byte_order.write_u32_little_endian(bytes, offset + int(offset_of(Area_Record, content_bytes)), u32(area.content_bytes))
		content_total += area.content_bytes
	}
	for step in 0 ..< sequence.step_count {
		item := &sequence.steps[step]
		offset := HEADER_SIZE + sequence.area_count * AREA_SIZE + step * STEP_SIZE
		byte_order.write_u32_little_endian(bytes, offset + int(offset_of(Step_Record, operation)), item.operation)
		byte_order.write_u32_little_endian(bytes, offset + int(offset_of(Step_Record, flags)), transmute(u32)item.flags)
		for argument in 0 ..< ARGUMENTS {
			argument_offset := offset + int(offset_of(Step_Record, arguments)) + argument * ARGUMENT_SIZE
			index, place, value := argument_words(item.arguments[argument])
			byte_order.write_u64_little_endian(bytes, argument_offset + int(offset_of(Argument_Record, source)), u64(item.arguments[argument].source))
			byte_order.write_u64_little_endian(bytes, argument_offset + int(offset_of(Argument_Record, index)), index)
			byte_order.write_u64_little_endian(bytes, argument_offset + int(offset_of(Argument_Record, place)), place)
			byte_order.write_u64_little_endian(bytes, argument_offset + int(offset_of(Argument_Record, value)), value)
		}
	}
	content_offset := total - content_total
	copy(bytes[content_offset:], sequence.content[:content_total])
	return bytes, true
}

// argument_words gives the three words after the source of an argument:
// the fields of its source, and 0 for each other.
@(private = "file")
argument_words :: proc "contextless" (argument: Argument) -> (index, place, value: u64) {
	switch argument.source {
	case .Value:
		value = argument.value
	case .Budget, .Log, .Machine:
	case .Area_Handle:
		index = u64(argument.area)
	case .Area_Address:
		index = u64(argument.area)
		value = argument.offset
	case .Thread_Entry:
		index = u64(argument.entry)
	case .Result:
		index = u64(argument.step)
		place = u64(argument.place)
		value = argument.offset
	}
	return
}

// area_content gives the content of one area of a sequence that `check`
// accepted: its first `content_bytes` bytes, which the runner writes at the
// start of the area.
area_content :: proc "contextless" (sequence: ^Sequence, area: int) -> []u8 {
	start := 0
	for item in sequence.areas[:area] {
		start += item.content_bytes
	}
	return sequence.content[start:start + sequence.areas[area].content_bytes]
}

// step_offset gives the place of the record of one step in the bytes of a
// sequence with `area_count` areas; argument_offset the place of one of its
// argument records. The tests of the format and the field mutator of the
// tool damage one record there.
step_offset :: proc "contextless" (area_count, step: int) -> int {
	return HEADER_SIZE + area_count * AREA_SIZE + step * STEP_SIZE
}

argument_offset :: proc "contextless" (area_count, step, argument: int) -> int {
	return step_offset(area_count, step) + int(offset_of(Step_Record, arguments)) + argument * ARGUMENT_SIZE
}
