package modustool

import "modus:contract/enum_word"
import "modus:contract/operation"
import "modus:contract/operation_sequence"

// The records at the addresses of the kernel operations
// (src/md/infrastructure/kernel_fuzzing.md, "The records at the
// addresses"). Plain bytes where an operation reads a structured record
// stop most sequences at the first check of that record, so the code after
// the check never runs. The generator writes a record of the right type
// there, in the content of the area that the address names: mostly valid,
// with one edge value or one word that names nothing in a few records, so
// the refusals still run.

// What the generator writes at an address parameter. The row of the table
// of the address parameters names it.
Fuzz_Address_Record :: enum u8 {
	Plain_Bytes,            // The bytes that the choices gave the area.
	Page_Range_Table,       // A table of `Page_Range`, with the count of the next argument.
	Thread_Control_Command, // The record that the command of Thread_Control reads; plain bytes for a command that reads none.
}

// The record types that the generator writes.
Fuzz_Record_Type :: enum u8 {
	Page_Range_Table,    // `operation.Page_Range`, as many as the count argument.
	Register_Image,      // `operation.Thread_Registers`.
	Breakpoint_Image,    // `operation.Thread_Breakpoints`.
	Extended_State_Area, // The legacy part and the header of an extended state area.
}

// How a writer fills one record, the valid form first.
Fuzz_Record_Form :: enum u8 {
	Valid,         // Each field holds a value that its contract takes.
	Edge,          // One field holds 0, 1, a bound or one past a bound. Some edges are valid.
	Names_Nothing, // One field holds a word that names no member, or a number past each bound: the contract refuses the record.
}

// The mix of the forms: of FUZZ_RECORD_FORMS_OF records, FUZZ_RECORD_VALID_OF
// are valid, FUZZ_RECORD_EDGE_OF have one edge, and the rest one word that
// names nothing. Most records reach the code behind their check; the few
// others keep the refusals of each field under test.
FUZZ_RECORD_FORMS_OF :: 16
FUZZ_RECORD_VALID_OF :: 12
FUZZ_RECORD_EDGE_OF :: 3

// fuzz_record_form_choose gives the form of one record. The zero choice
// gives a valid record.
fuzz_record_form_choose :: proc(choices: ^Fuzz_Choices) -> Fuzz_Record_Form {
	value := fuzz_choice_below(choices, FUZZ_RECORD_FORMS_OF)
	if value < FUZZ_RECORD_VALID_OF {
		return .Valid
	}
	if value < FUZZ_RECORD_VALID_OF + FUZZ_RECORD_EDGE_OF {
		return .Edge
	}
	return .Names_Nothing
}

// One record that the generator wrote, for a host test.
Fuzz_Record_Written :: struct {
	type:         Fuzz_Record_Type,
	form:         Fuzz_Record_Form,
	step:         int,
	area:         int,
	offset:       int, // From the start of the area.
	bytes:        int, // The bytes in the content: fewer than record_bytes when the area or the content ends first.
	record_bytes: int,
	object_pages: u64, // Page_Range_Table: the pages of the memory object that the writer took.
}

// ---------------------------------------------------------------------
// The writer of each record type.

// The most pages between two ranges of a valid table, and the most pages
// of one range: a table of several ranges then fits a small object.
FUZZ_PAGE_RANGE_GAP_MOST :: 3
FUZZ_PAGE_RANGE_PAGES_MOST :: 4

// fuzz_page_ranges_write fills a table of ranges of an object of
// `object_pages` pages: in increasing order, with no overlap, inside the
// object. A table with more ranges than the object has pages cannot be
// valid: its last ranges go past the object, and the form that it gives
// back is Edge. Else the valid form gives a valid table.
fuzz_page_ranges_write :: proc(choices: ^Fuzz_Choices, form: Fuzz_Record_Form, object_pages: u64, ranges: []operation.Page_Range) -> Fuzz_Record_Form {
	actual := form
	cursor: u64
	for &item, index in ranges {
		if cursor >= object_pages {
			item = {first = cursor, page_count = 1}
			cursor += 1
			if actual == .Valid {
				actual = .Edge
			}
			continue
		}
		// The gaps and the longer ranges take only the pages that the
		// ranges after this one do not need, so each range fits when the
		// object has a page for each.
		ranges_left := u64(len(ranges) - index)
		room := object_pages - cursor
		spare: u64
		if room > ranges_left {
			spare = room - ranges_left
		}
		gap := min(u64(fuzz_choice_below(choices, FUZZ_PAGE_RANGE_GAP_MOST + 1)), spare)
		spare -= gap
		longer := min(u64(fuzz_choice_below(choices, FUZZ_PAGE_RANGE_PAGES_MOST)), spare)
		item = {first = cursor + gap, page_count = 1 + longer}
		cursor = item.first + item.page_count
	}
	if form == .Valid || len(ranges) == 0 {
		return actual
	}
	broken := fuzz_choice_below(choices, 2 * len(ranges))
	place := broken / 2
	item := &ranges[place]
	if form == .Names_Nothing {
		if broken % 2 == 0 {
			item.first = max(u64)
		} else {
			item.page_count = max(u64)
		}
		return form
	}
	if broken % 2 == 0 {
		// The first page of the range before: an overlap.
		previous: u64
		if place > 0 {
			previous = ranges[place - 1].first
		}
		edges := [?]u64{0, object_pages - 1, object_pages, previous}
		item.first = edges[fuzz_choice_below(choices, len(edges))]
	} else {
		to_the_end: u64
		if item.first < object_pages {
			to_the_end = object_pages - item.first
		}
		edges := [?]u64{0, 1, to_the_end, to_the_end + 1}
		item.page_count = edges[fuzz_choice_below(choices, len(edges))]
	}
	return form
}

// The fields of a register image that a write checks
// (`operation.thread_registers_refusal`).
Fuzz_Register_Field :: enum u8 {
	Code_Selector,
	Stack_Selector,
	Flags,
	Instruction_Address,
	Stack_Address,
}

// fuzz_register_image_write fills a register image: any general register,
// an instruction address and a stack address below USER_END, the required
// flags with some of the allowed ones, and the two selectors of a process.
fuzz_register_image_write :: proc(choices: ^Fuzz_Choices, form: Fuzz_Record_Form) -> (registers: operation.Thread_Registers) {
	general := ([^]u8)(&registers)[:int(offset_of(operation.Thread_Registers, rip))]
	fuzz_choice_fill(choices, general)
	registers.rsp = fuzz_choice_word(choices, 8) & (operation.USER_END - 1)
	registers.rip = fuzz_choice_word(choices, 8) & (operation.USER_END - 1)
	registers.rflags = operation.THREAD_FLAGS_REQUIRED | fuzz_choice_word(choices, 4) & operation.THREAD_FLAGS_ALLOWED
	registers.cs = operation.THREAD_CODE_SELECTOR
	registers.ss = operation.THREAD_STACK_SELECTOR
	if form == .Valid {
		return registers
	}
	field := fuzz_member_of_choice(choices, Fuzz_Register_Field)
	// The lowest flag that a thread cannot hold.
	flag_outside := ~operation.THREAD_FLAGS_ALLOWED & (operation.THREAD_FLAGS_ALLOWED + 1)
	switch field {
	case .Code_Selector:
		edges := [?]u64{0, 1, operation.THREAD_STACK_SELECTOR, operation.THREAD_CODE_SELECTOR + 1}
		registers.cs = fuzz_edge_or_nothing(choices, form, edges[:], max(u64))
	case .Stack_Selector:
		edges := [?]u64{0, 1, operation.THREAD_CODE_SELECTOR, operation.THREAD_STACK_SELECTOR + 1}
		registers.ss = fuzz_edge_or_nothing(choices, form, edges[:], max(u64))
	case .Flags:
		edges := [?]u64{operation.THREAD_FLAGS_REQUIRED, operation.THREAD_FLAGS_ALLOWED, 0, operation.THREAD_FLAGS_ALLOWED | flag_outside}
		registers.rflags = fuzz_edge_or_nothing(choices, form, edges[:], max(u64))
	case .Instruction_Address:
		edges := [?]u64{0, 1, operation.USER_END - 1, operation.USER_END}
		registers.rip = fuzz_edge_or_nothing(choices, form, edges[:], max(u64))
	case .Stack_Address:
		// The first address of the kernel half is canonical: the contract
		// takes it as a stack, and the thread faults at its first push.
		edges := [?]u64{0, operation.USER_END - 1, operation.USER_END, FUZZ_KERNEL_HALF_FIRST}
		registers.rsp = fuzz_edge_or_nothing(choices, form, edges[:], u64(1) << 63)
	}
	return registers
}

// The fields of one breakpoint of a breakpoint image.
Fuzz_Breakpoint_Field :: enum u8 {
	Address,
	Kind,
	Length,
}

// fuzz_breakpoint_image_write fills the breakpoints of a thread: each
// place has a kind; an execute breakpoint has an address of a process; a
// data breakpoint has a length of 1, 2, 4 or 8 and an address of a process
// that is a multiple of it; an empty place is zero.
fuzz_breakpoint_image_write :: proc(choices: ^Fuzz_Choices, form: Fuzz_Record_Form) -> (image: operation.Thread_Breakpoints) {
	kinds := [?]operation.Thread_Breakpoint_Kind{.None, .Execute, .Write, .Read_Or_Write}
	lengths := [?]u32{1, 2, 4, 8}
	for &breakpoint in image.breakpoints {
		kind := kinds[fuzz_choice_below(choices, len(kinds))]
		address := fuzz_choice_word(choices, 8) & (operation.USER_END - 1)
		switch kind {
		case .None:
			breakpoint = {}
		case .Execute:
			breakpoint = {address = address, kind = kind}
		case .Write, .Read_Or_Write:
			length := lengths[fuzz_choice_below(choices, len(lengths))]
			breakpoint = {address = address & ~u64(length - 1), kind = kind, length = length}
		}
	}
	if form == .Valid {
		return image
	}
	place := fuzz_choice_below(choices, operation.THREAD_BREAKPOINT_CAPACITY)
	breakpoint := &image.breakpoints[place]
	switch fuzz_member_of_choice(choices, Fuzz_Breakpoint_Field) {
	case .Address:
		edges := [?]u64{0, 1, operation.USER_END - u64(max(breakpoint.length, 1)), operation.USER_END}
		breakpoint.address = fuzz_edge_or_nothing(choices, form, edges[:], max(u64))
	case .Kind:
		edges := [?]u64{0, 1, u64(max(operation.Thread_Breakpoint_Kind)), u64(max(operation.Thread_Breakpoint_Kind)) + 1}
		word := u32(fuzz_edge_or_nothing(choices, form, edges[:], u64(max(u32))))
		// The word goes into the bytes of the image as a number: it can
		// name no member, so no value of the enum holds it. The kernel
		// reads it through its own border.
		kind_bytes := ([^]u8)(breakpoint)[int(offset_of(operation.Thread_Breakpoint, kind)):][:size_of(u32)]
		fuzz_little_endian_put(kind_bytes, 0, size_of(u32), u64(word))
	case .Length:
		edges := [?]u64{0, 1, 8, 9}
		breakpoint.length = u32(fuzz_edge_or_nothing(choices, form, edges[:], u64(max(u32))))
	}
	return image
}

// The bytes of an extended state area that the generator writes: the
// legacy part and the header. A write reads the rest of the area, which
// the zero pages of the area hold: a component with zero bytes is valid.
FUZZ_EXTENDED_STATE_BYTES :: operation.EXTENDED_STATE_LEGACY_BYTES + operation.EXTENDED_STATE_HEADER_BYTES
// The places in the legacy part of fxsave: the x87 control word and the
// first vector register (Intel SDM, volume 1, chapter 10).
FUZZ_EXTENDED_STATE_CONTROL_OFFSET :: 0
FUZZ_EXTENDED_STATE_FIRST_VECTOR_OFFSET :: 160
FUZZ_EXTENDED_STATE_VECTOR_BYTES :: 16
// The control word and MXCSR after a reset of the processor, with no
// exception flag.
FUZZ_EXTENDED_STATE_CONTROL_RESET :: 0x037F
FUZZ_EXTENDED_STATE_MXCSR_RESET :: 0x1F80
// The six exception flags of MXCSR: each processor takes them.
FUZZ_EXTENDED_STATE_MXCSR_FLAGS :: 0x3F
// The components x87 and SSE: each processor with xsave saves them, so
// XCR0 always holds them.
FUZZ_EXTENDED_STATE_COMPONENTS_LEAST :: u64(0b11)
// XCOMP_BV, after XSTATE_BV in the header.
FUZZ_EXTENDED_STATE_COMPACTION_OFFSET :: operation.EXTENDED_STATE_LEGACY_BYTES + 8
FUZZ_EXTENDED_STATE_RESERVED_OFFSET :: operation.EXTENDED_STATE_LEGACY_BYTES + 16

// The fields of an extended state area that a write checks
// (`operation.extended_state_refusal`).
Fuzz_Extended_State_Field :: enum u8 {
	Mxcsr,
	Components,
	Compaction,
	Reserved,
}

// fuzz_extended_state_write fills the legacy part and the header of an
// extended state area in the standard form: the control words after a
// reset, some exception flags of MXCSR, the first vector register from the
// choices, the components x87 and SSE or a part of them, and zero
// reserved bytes.
fuzz_extended_state_write :: proc(choices: ^Fuzz_Choices, form: Fuzz_Record_Form) -> (area: [FUZZ_EXTENDED_STATE_BYTES]u8) {
	fuzz_little_endian_put(area[:], FUZZ_EXTENDED_STATE_CONTROL_OFFSET, 2, FUZZ_EXTENDED_STATE_CONTROL_RESET)
	fuzz_little_endian_put(area[:], operation.EXTENDED_STATE_MXCSR_OFFSET, 4, FUZZ_EXTENDED_STATE_MXCSR_RESET | fuzz_choice_word(choices, 1) & FUZZ_EXTENDED_STATE_MXCSR_FLAGS)
	fuzz_choice_fill(choices, area[FUZZ_EXTENDED_STATE_FIRST_VECTOR_OFFSET:][:FUZZ_EXTENDED_STATE_VECTOR_BYTES])
	fuzz_little_endian_put(area[:], operation.EXTENDED_STATE_LEGACY_BYTES, 8, u64(fuzz_choice_below(choices, int(FUZZ_EXTENDED_STATE_COMPONENTS_LEAST) + 1)))
	if form == .Valid {
		return area
	}
	switch fuzz_member_of_choice(choices, Fuzz_Extended_State_Field) {
	case .Mxcsr:
		edges := [?]u64{0, 1, 0xFFFF, 0x1_0000}
		fuzz_little_endian_put(area[:], operation.EXTENDED_STATE_MXCSR_OFFSET, 4, fuzz_edge_or_nothing(choices, form, edges[:], u64(max(u32))))
	case .Components:
		// 0b111 adds AVX, which XCR0 of most machines holds; bit 63 of
		// XCR0 is reserved, so no machine holds it.
		edges := [?]u64{0, 1, 0b111, 0xFF}
		fuzz_little_endian_put(area[:], operation.EXTENDED_STATE_LEGACY_BYTES, 8, fuzz_edge_or_nothing(choices, form, edges[:], u64(1) << 63))
	case .Compaction:
		edges := [?]u64{0, 1, u64(1) << 63, max(u64)}
		fuzz_little_endian_put(area[:], FUZZ_EXTENDED_STATE_COMPACTION_OFFSET, 8, fuzz_edge_or_nothing(choices, form, edges[:], max(u64)))
	case .Reserved:
		words := (operation.EXTENDED_STATE_HEADER_BYTES - 16) / 8
		at := FUZZ_EXTENDED_STATE_RESERVED_OFFSET + 8 * fuzz_choice_below(choices, words)
		edges := [?]u64{0, 1, 0x80, max(u64)}
		fuzz_little_endian_put(area[:], at, 8, fuzz_edge_or_nothing(choices, form, edges[:], max(u64)))
	}
	return area
}

// fuzz_edge_or_nothing gives one of the edges for the form Edge, and the
// word that names nothing for the form Names_Nothing.
@(private = "file")
fuzz_edge_or_nothing :: proc(choices: ^Fuzz_Choices, form: Fuzz_Record_Form, edges: []u64, nothing: u64) -> u64 {
	if form == .Names_Nothing {
		return nothing
	}
	return edges[fuzz_choice_below(choices, len(edges))]
}

@(private = "file")
fuzz_member_of_choice :: proc(choices: ^Fuzz_Choices, $Enum: typeid) -> Enum {
	count := 0
	for _ in Enum {
		count += 1
	}
	place := fuzz_choice_below(choices, count)
	for member in Enum {
		if place == 0 {
			return member
		}
		place -= 1
	}
	return {}
}

@(private = "file")
fuzz_little_endian_put :: proc(bytes: []u8, at, size: int, value: u64) {
	for index in 0 ..< size {
		bytes[at + index] = u8(value >> (8 * u64(index)))
	}
}

// ---------------------------------------------------------------------
// The records of one step.

// fuzz_step_records_write writes, for each address of the step whose row
// names a record, that record at the address, when the address is in an
// area. An address in no area, or past its area, gets no record: the
// sequence holds no byte there.
fuzz_step_records_write :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, chosen: operation.Operation, item: ^operation_sequence.Sequence_Step, step: int, written: ^[dynamic]Fuzz_Record_Written) {
	for row in fuzz_address_parameters {
		if row.operation != chosen {
			continue
		}
		address := item.arguments[row.parameter]
		if address.source != .Area_Address || address.area < 0 || address.area >= sequence.area_count {
			continue
		}
		place := Fuzz_Record_Place{sequence = sequence, written = written, step = step, area = address.area, offset = int(address.offset)}
		switch row.record {
		case .Plain_Bytes:
		case .Page_Range_Table:
			count := item.arguments[row.parameter + 1]
			if count.source != .Value || count.value < 1 || count.value > operation.RANGE_TABLE_CAPACITY {
				continue
			}
			pages := fuzz_memory_pages_of(sequence, chosen, item)
			ranges: [operation.RANGE_TABLE_CAPACITY]operation.Page_Range
			table := ranges[:count.value]
			form := fuzz_page_ranges_write(choices, fuzz_record_form_choose(choices), pages, table)
			place.object_pages = pages
			fuzz_record_place(&place, .Page_Range_Table, form, ([^]u8)(&ranges[0])[:len(table) * size_of(operation.Page_Range)])
		case .Thread_Control_Command:
			command_place := operation_parameter_place(chosen, "command")
			if command_place < 0 || item.arguments[command_place].source != .Value {
				continue
			}
			command, known := enum_word.member_of_word(operation.Thread_Control_Command, item.arguments[command_place].value)
			if !known {
				continue
			}
			switch command {
			case .Write_Registers:
				form := fuzz_record_form_choose(choices)
				registers := fuzz_register_image_write(choices, form)
				fuzz_record_place(&place, .Register_Image, form, ([^]u8)(&registers)[:size_of(registers)])
			case .Write_Breakpoints:
				form := fuzz_record_form_choose(choices)
				image := fuzz_breakpoint_image_write(choices, form)
				fuzz_record_place(&place, .Breakpoint_Image, form, ([^]u8)(&image)[:size_of(image)])
			case .Write_Extended_State:
				form := fuzz_record_form_choose(choices)
				area := fuzz_extended_state_write(choices, form)
				fuzz_record_place(&place, .Extended_State_Area, form, area[:])
			case .None, .Stop, .Resume, .Read_Registers, .Read_Extended_State, .Read_Schedule, .Write_Schedule, .Read_Breakpoints, .Read_Memory, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Start_Counters, .Read_Counters, .Stop_Counters:
				// No record type is described for these commands yet, or
				// the command reads no record.
			}
		}
	}
}

// Where one record goes.
@(private = "file")
Fuzz_Record_Place :: struct {
	sequence:     ^operation_sequence.Sequence,
	written:      ^[dynamic]Fuzz_Record_Written,
	step:         int,
	area:         int,
	offset:       int,
	object_pages: u64,
}

@(private = "file")
fuzz_record_place :: proc(place: ^Fuzz_Record_Place, type: Fuzz_Record_Type, form: Fuzz_Record_Form, record: []u8) {
	into := fuzz_area_content_reserve(place.sequence, place.area, place.offset, len(record))
	if len(into) == 0 {
		return
	}
	copy(into, record)
	if place.written != nil {
		append(place.written, Fuzz_Record_Written{type = type, form = form, step = place.step, area = place.area, offset = place.offset, bytes = len(into), record_bytes = len(record), object_pages = place.object_pages})
	}
}

// fuzz_memory_pages_of gives the pages of the memory object of a step when
// the sequence says them: an area, or a Memory_Create of an earlier step
// with a plain count. Else AREA_PAGES_MOST, the size of the largest area.
fuzz_memory_pages_of :: proc(sequence: ^operation_sequence.Sequence, chosen: operation.Operation, item: ^operation_sequence.Sequence_Step) -> u64 {
	memory_place := -1
	for parameter, place in operation.OPERATIONS[chosen].parameters {
		if (parameter.form == .Handle || parameter.form == .Handle_Or_Zero) && parameter.kind == .Memory {
			memory_place = place
			break
		}
	}
	if memory_place < 0 {
		return operation_sequence.AREA_PAGES_MOST
	}
	memory := item.arguments[memory_place]
	if memory.source == .Area_Handle && memory.area >= 0 && memory.area < sequence.area_count {
		return u64(sequence.areas[memory.area].pages)
	}
	pages_place := operation_parameter_place(.Memory_Create, "pages")
	if memory.source != .Result || pages_place < 0 || memory.step < 0 || memory.step >= sequence.step_count || sequence.steps[memory.step].operation != u32(operation.Operation.Memory_Create) {
		return operation_sequence.AREA_PAGES_MOST
	}
	pages := sequence.steps[memory.step].arguments[pages_place]
	if pages.source == .Value && pages.value >= 1 && pages.value <= operation.MEMORY_PAGE_LIMIT {
		return pages.value
	}
	return operation_sequence.AREA_PAGES_MOST
}

// fuzz_area_content_reserve makes the content of an area hold the bytes
// from `offset` for `length` bytes, and gives them: the content grows with
// zero bytes, and the content of each later area moves after it. The
// bytes stop at the end of the area and where the content of all the
// areas reaches CONTENT_BYTES_MOST, so they can be fewer than `length`, or
// none: then the content does not change.
fuzz_area_content_reserve :: proc(sequence: ^operation_sequence.Sequence, area, offset, length: int) -> []u8 {
	if area < 0 || area >= sequence.area_count {
		return nil
	}
	area_bytes := sequence.areas[area].pages * operation.PAGE_SIZE
	if offset < 0 || length <= 0 || offset >= area_bytes {
		return nil
	}
	start, total := 0, 0
	for item, index in sequence.areas[:sequence.area_count] {
		if index < area {
			start += item.content_bytes
		}
		total += item.content_bytes
	}
	held := sequence.areas[area].content_bytes
	wanted := min(offset + length, area_bytes)
	growth := clamp(wanted - held, 0, operation_sequence.CONTENT_BYTES_MOST - total)
	end := min(wanted, held + growth)
	// A record that gets no byte changes nothing: no zeros with no record.
	if offset >= end {
		return nil
	}
	if growth > 0 {
		after := start + held
		// copy moves bytes that overlap correctly.
		copy(sequence.content[after + growth:total + growth], sequence.content[after:total])
		for &byte_value in sequence.content[after:after + growth] {
			byte_value = 0
		}
		sequence.areas[area].content_bytes = held + growth
	}
	return sequence.content[start + offset:start + end]
}
