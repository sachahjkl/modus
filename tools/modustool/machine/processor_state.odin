package machine

import info "modus:contract/boot_info"
import debug_object "modus:contract/debug_object"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:build"

// The state of the processors of a test machine when one of its steps
// failed. A step that ends at its bound says only that a line did not come:
// the log does not say where each processor was. So the tool asks the
// monitor of QEMU for the registers of each processor, before any other
// act of the failure, writes the answer beside the log, and names the code
// of each instruction address (docs/TOOLS.md, "A step that fails").

// The end of the name of the file of the state, after the name of the log.
PROCESSORS_STATE_SUFFIX :: "_processors.txt"
// The lines of the monitor: the registers of every processor, then the
// list of the processors with the thread of the host that runs each one.
REGISTERS_OF_ALL_PROCESSORS_LINE :: "info registers -a"
PROCESSOR_LIST_LINE :: "info cpus"

// QEMU maps the flash units of the firmware of a PC one under the other,
// so that the first one ends at 4 GiB; the reset vector is in it.
FIRMWARE_FLASH_END :: u64(0x1_0000_0000)
// QEMU also maps the last 128 KiB of the flash under 1 MiB, where a
// processor in real mode runs the firmware.
FIRMWARE_LOW_COPY_START :: u64(0xE_0000)
FIRMWARE_LOW_COPY_END :: u64(0x10_0000)
// The largest privilege level of x86-64, the level of a process.
PROCESS_PRIVILEGE_LEVEL :: 3
// The largest number of a processor that the reader takes: far more than
// the processors of a test machine, and small enough for an int.
LARGEST_PROCESSOR_NUMBER :: 1 << 16

Processor_State :: struct {
	number:                 int, // The number of the processor in QEMU, from 0.
	host_thread:            u64, // The thread of the host that runs it.
	current:                bool, // The processor that the monitor of QEMU marks with `*`.
	instruction_address:    u64, // The linear address: RIP in 64-bit code, else the base of CS and EIP.
	privilege_level:        u8,
	halted:                 bool,
	system_management_mode: bool,
}

Processor_Read_Fault :: enum {
	None,
	Not_A_Monitor_Text,
	No_Processor,
	Text_Before_The_First_Processor,
	Damaged_Processor_Header,
	Repeated_Processor,
	Missing_Instruction_Address,
	Missing_Field,
	Repeated_Field,
	Damaged_Value,
	Value_Past_64_Bits,
	Damaged_Processor_List_Line,
	Processor_Lists_Differ,
}

@(rodata)
processor_read_fault_sentences := [Processor_Read_Fault]string {
	.None                            = "",
	.Not_A_Monitor_Text              = "the answer of the monitor is not a JSON string",
	.No_Processor                    = "the text names no processor",
	.Text_Before_The_First_Processor = "a line comes before the first line CPU#<number>",
	.Damaged_Processor_Header        = "a line CPU#<number> has no number, or a number past the largest",
	.Repeated_Processor              = "two parts of the text name the same processor",
	.Missing_Instruction_Address     = "a processor has no RIP and no EIP",
	.Missing_Field                   = "a processor has no CPL, HLT, SMM, or no base of CS for its EIP",
	.Repeated_Field                  = "a processor has a field two times",
	.Damaged_Value                   = "a value has a character that is not a digit, or is out of its range",
	.Value_Past_64_Bits              = "a value is past 64 bits",
	.Damaged_Processor_List_Line     = "a line of the list of the processors is not \"[*] CPU #<number>: thread_id=<number>\"",
	.Processor_Lists_Differ          = "the registers and the list name different processors",
}

// hexadecimal_word_read reads a whole word of hexadecimal digits.
@(private = "file")
hexadecimal_word_read :: proc(word: string) -> (value: u64, fault: Processor_Read_Fault) {
	if len(word) == 0 {
		return 0, .Damaged_Value
	}
	for index in 0 ..< len(word) {
		character := word[index]
		digit: u64
		switch character {
		case '0' ..= '9':
			digit = u64(character - '0')
		case 'a' ..= 'f':
			digit = u64(character - 'a') + 10
		case 'A' ..= 'F':
			digit = u64(character - 'A') + 10
		case:
			return 0, .Damaged_Value
		}
		// Leading zeros are not a value past 64 bits: only a digit that
		// would push a bit out is.
		if value > max(u64) >> 4 {
			return 0, .Value_Past_64_Bits
		}
		value = value << 4 | digit
	}
	return value, .None
}

// decimal_word_read reads a whole word of decimal digits, at most largest.
@(private = "file")
decimal_word_read :: proc(word: string, largest: u64) -> (value: u64, fault: Processor_Read_Fault) {
	if len(word) == 0 {
		return 0, .Damaged_Value
	}
	for index in 0 ..< len(word) {
		character := word[index]
		if character < '0' || character > '9' {
			return 0, .Damaged_Value
		}
		digit := u64(character - '0')
		// A digit past the largest value would make largest - digit wrap
		// around to a huge bound, which accepts any value.
		if digit > largest || value > (largest - digit) / 10 {
			return 0, .Damaged_Value
		}
		value = value * 10 + digit
	}
	return value, .None
}

// The fields of one processor while the reader reads its part of the text.
@(private = "file")
Processor_Under_Read :: struct {
	state:                      Processor_State,
	has_instruction_pointer:    bool,
	runs_64_bit_code:           bool, // RIP, not EIP: the base of CS does not count.
	instruction_pointer:        u64,
	has_code_segment_base:      bool,
	code_segment_base:          u64,
	has_privilege_level:        bool,
	has_halted:                 bool,
	has_system_management_mode: bool,
}

@(private = "file")
processor_under_read_end :: proc(reading: ^Processor_Under_Read) -> (state: Processor_State, fault: Processor_Read_Fault) {
	if !reading.has_instruction_pointer {
		return {}, .Missing_Instruction_Address
	}
	if !reading.has_privilege_level || !reading.has_halted || !reading.has_system_management_mode {
		return {}, .Missing_Field
	}
	state = reading.state
	if reading.runs_64_bit_code {
		state.instruction_address = reading.instruction_pointer
	} else {
		if !reading.has_code_segment_base {
			return {}, .Missing_Field
		}
		state.instruction_address = reading.code_segment_base + reading.instruction_pointer
	}
	return state, .None
}

// processor_word_read reads one word of a line of the registers, when it
// is a field that the reader needs. The other words are left.
@(private = "file")
processor_word_read :: proc(reading: ^Processor_Under_Read, word: string) -> Processor_Read_Fault {
	switch {
	case strings.has_prefix(word, "RIP=") || strings.has_prefix(word, "EIP="):
		if reading.has_instruction_pointer {
			return .Repeated_Field
		}
		value, fault := hexadecimal_word_read(word[len("RIP="):])
		if fault != .None {
			return fault
		}
		reading.runs_64_bit_code = word[0] == 'R'
		if !reading.runs_64_bit_code && value > u64(max(u32)) {
			return .Damaged_Value
		}
		reading.has_instruction_pointer = true
		reading.instruction_pointer = value
	case strings.has_prefix(word, "CPL="):
		if reading.has_privilege_level {
			return .Repeated_Field
		}
		value, fault := decimal_word_read(word[len("CPL="):], PROCESS_PRIVILEGE_LEVEL)
		if fault != .None {
			return fault
		}
		reading.has_privilege_level = true
		reading.state.privilege_level = u8(value)
	case strings.has_prefix(word, "HLT="):
		if reading.has_halted {
			return .Repeated_Field
		}
		value, fault := decimal_word_read(word[len("HLT="):], 1)
		if fault != .None {
			return fault
		}
		reading.has_halted = true
		reading.state.halted = value == 1
	case strings.has_prefix(word, "SMM="):
		if reading.has_system_management_mode {
			return .Repeated_Field
		}
		value, fault := decimal_word_read(word[len("SMM="):], 1)
		if fault != .None {
			return fault
		}
		reading.has_system_management_mode = true
		reading.state.system_management_mode = value == 1
	}
	return .None
}

// processor_registers_read reads what the monitor prints for
// REGISTERS_OF_ALL_PROCESSORS_LINE: for each processor a line
// "CPU#<number>", then its registers in the form of QEMU. line is the line
// of the fault, from 1, or 0.
processor_registers_read :: proc(text: string) -> (states: []Processor_State, fault: Processor_Read_Fault, line: int) {
	list := make([dynamic]Processor_State, context.temp_allocator)
	reading: Processor_Under_Read
	reading_a_processor := false
	CODE_SEGMENT_MARK :: "CS ="
	for raw_line, index in strings.split_lines(text, context.temp_allocator) {
		trimmed := strings.trim_space(raw_line)
		if trimmed == "" {
			continue
		}
		if strings.has_prefix(trimmed, "CPU#") {
			if reading_a_processor {
				state, end_fault := processor_under_read_end(&reading)
				if end_fault != .None {
					return nil, end_fault, index + 1
				}
				append(&list, state)
			}
			number, number_fault := decimal_word_read(trimmed[len("CPU#"):], LARGEST_PROCESSOR_NUMBER)
			if number_fault != .None {
				return nil, .Damaged_Processor_Header, index + 1
			}
			for state in list {
				if state.number == int(number) {
					return nil, .Repeated_Processor, index + 1
				}
			}
			reading = {}
			reading.state.number = int(number)
			reading_a_processor = true
			continue
		}
		if !reading_a_processor {
			return nil, .Text_Before_The_First_Processor, index + 1
		}
		if strings.has_prefix(trimmed, CODE_SEGMENT_MARK) {
			// The selector, the base, the limit, the flags.
			words := strings.fields(trimmed[len(CODE_SEGMENT_MARK):], context.temp_allocator)
			if len(words) < 2 {
				return nil, .Damaged_Value, index + 1
			}
			if reading.has_code_segment_base {
				return nil, .Repeated_Field, index + 1
			}
			base, base_fault := hexadecimal_word_read(words[1])
			if base_fault != .None {
				return nil, base_fault, index + 1
			}
			reading.has_code_segment_base = true
			reading.code_segment_base = base
			continue
		}
		for word in strings.fields(trimmed, context.temp_allocator) {
			if word_fault := processor_word_read(&reading, word); word_fault != .None {
				return nil, word_fault, index + 1
			}
		}
	}
	if !reading_a_processor {
		return nil, .No_Processor, 0
	}
	state, end_fault := processor_under_read_end(&reading)
	if end_fault != .None {
		return nil, end_fault, 0
	}
	append(&list, state)
	return list[:], .None, 0
}

// One line of what the monitor prints for PROCESSOR_LIST_LINE.
Processor_List_Entry :: struct {
	number:      int,
	host_thread: u64,
	current:     bool,
	halted:      bool, // An older QEMU writes "(halted)"; a newer one says it only in HLT of the registers.
}

// processor_list_read reads the list of the processors: one line
// "[*] CPU #<number>: thread_id=<number>" for each.
processor_list_read :: proc(text: string) -> (entries: []Processor_List_Entry, fault: Processor_Read_Fault, line: int) {
	list := make([dynamic]Processor_List_Entry, context.temp_allocator)
	PROCESSOR_MARK :: "CPU #"
	THREAD_MARK :: "thread_id="
	for raw_line, index in strings.split_lines(text, context.temp_allocator) {
		rest := strings.trim_space(raw_line)
		if rest == "" {
			continue
		}
		entry: Processor_List_Entry
		if strings.has_prefix(rest, "*") {
			entry.current = true
			rest = strings.trim_left_space(rest[1:])
		}
		if !strings.has_prefix(rest, PROCESSOR_MARK) {
			return nil, .Damaged_Processor_List_Line, index + 1
		}
		rest = rest[len(PROCESSOR_MARK):]
		colon := strings.index_byte(rest, ':')
		if colon < 0 {
			return nil, .Damaged_Processor_List_Line, index + 1
		}
		number, number_fault := decimal_word_read(rest[:colon], LARGEST_PROCESSOR_NUMBER)
		if number_fault != .None {
			return nil, .Damaged_Processor_List_Line, index + 1
		}
		entry.number = int(number)
		has_thread := false
		for word in strings.fields(rest[colon + 1:], context.temp_allocator) {
			switch {
			case word == "(halted)":
				entry.halted = true
			case strings.has_prefix(word, THREAD_MARK):
				if has_thread {
					return nil, .Repeated_Field, index + 1
				}
				thread, thread_fault := decimal_word_read(word[len(THREAD_MARK):], max(u64))
				if thread_fault != .None {
					return nil, thread_fault, index + 1
				}
				entry.host_thread = thread
				has_thread = true
			}
		}
		if !has_thread {
			return nil, .Damaged_Processor_List_Line, index + 1
		}
		for earlier in list {
			if earlier.number == entry.number {
				return nil, .Repeated_Processor, index + 1
			}
		}
		append(&list, entry)
	}
	if len(list) == 0 {
		return nil, .No_Processor, 0
	}
	return list[:], .None, 0
}

// processors_read reads the two texts of the monitor, and joins them: each
// processor of the list must have its registers, and no other.
processors_read :: proc(registers_text, list_text: string) -> (states: []Processor_State, fault: Processor_Read_Fault, where_text: string) {
	registers, registers_fault, registers_line := processor_registers_read(registers_text)
	if registers_fault != .None {
		return nil, registers_fault, fmt.tprintf("%s, line %d", REGISTERS_OF_ALL_PROCESSORS_LINE, registers_line)
	}
	entries, list_fault, list_line := processor_list_read(list_text)
	if list_fault != .None {
		return nil, list_fault, fmt.tprintf("%s, line %d", PROCESSOR_LIST_LINE, list_line)
	}
	if len(entries) != len(registers) {
		return nil, .Processor_Lists_Differ, REGISTERS_OF_ALL_PROCESSORS_LINE + " and " + PROCESSOR_LIST_LINE
	}
	for entry in entries {
		found := false
		for &state in registers {
			if state.number == entry.number {
				state.host_thread = entry.host_thread
				state.current = entry.current
				state.halted = state.halted || entry.halted
				found = true
			}
		}
		if !found {
			return nil, .Processor_Lists_Differ, REGISTERS_OF_ALL_PROCESSORS_LINE + " and " + PROCESSOR_LIST_LINE
		}
	}
	return registers, .None, ""
}

// monitor_text_decode gives the text that the monitor printed, from the
// value of the reply of human-monitor-command: a JSON string.
monitor_text_decode :: proc(value: string) -> (text: string, ok: bool) {
	// The parser of the core library takes a string that the end of the
	// input cuts before its closing quote: the reader checks that quote
	// itself, with no backslash that escapes it.
	whole := strings.trim_space(value)
	if len(whole) < 2 || whole[0] != '"' || whole[len(whole) - 1] != '"' {
		return "", false
	}
	backslashes := 0
	for index := len(whole) - 2; index > 0 && whole[index] == '\\'; index -= 1 {
		backslashes += 1
	}
	if backslashes % 2 == 1 {
		return "", false
	}
	parsed, error := json.parse_string(whole, .JSON, false, context.temp_allocator)
	if error != .None {
		return "", false
	}
	decoded, is_text := parsed.(json.String)
	return string(decoded), is_text
}

// The kind of code that holds an instruction address.
Code_Place_Kind :: enum {
	Kernel,
	Firmware, // Its flash, or the copy of its end under 1 MiB.
	Firmware_System_Management_Mode,
	Process, // Privilege level 3.
	No_Known_Code,
}

// The code whose place the tool knows on a test machine.
Known_Code :: struct {
	firmware_flash_start: u64, // 0: the tool did not find the sizes of the files of the flash.
	kernel_module:        string, // The name of the kernel module of the boot volume.
	kernel_debug_object:  []u8, // nil: no debug object of the kernel passed its check.
}

code_place_kind :: proc(state: Processor_State, known: Known_Code) -> Code_Place_Kind {
	address := state.instruction_address
	switch {
	case state.system_management_mode:
		// System management memory is the firmware's alone.
		return .Firmware_System_Management_Mode
	case state.privilege_level == PROCESS_PRIVILEGE_LEVEL:
		return .Process
	case address >= u64(info.KERNEL_BASE):
		return .Kernel
	case known.firmware_flash_start != 0 && address >= known.firmware_flash_start && address < FIRMWARE_FLASH_END:
		return .Firmware
	case address >= FIRMWARE_LOW_COPY_START && address < FIRMWARE_LOW_COPY_END:
		return .Firmware
	}
	return .No_Known_Code
}

// processor_line gives the line of one processor: its number, halted or
// running, its instruction address, and the code that holds the address.
processor_line :: proc(state: Processor_State, known: Known_Code) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "processor %d, %s, at 0x%x: ", state.number, state.halted ? "halted" : "running", state.instruction_address)
	switch code_place_kind(state, known) {
	case .Kernel:
		offset := state.instruction_address - u64(info.KERNEL_BASE)
		if known.kernel_module == "" {
			fmt.sbprintf(&builder, "the kernel, at the offset 0x%x: the table of the volumes names no kernel module for this volume", offset)
			break
		}
		if known.kernel_debug_object == nil {
			fmt.sbprintf(&builder, "the kernel: %s + 0x%x, with no debug object of %s", known.kernel_module, offset, known.kernel_module)
			break
		}
		place := debug_object.place_of(known.kernel_debug_object, offset)
		if place.procedure == "" {
			fmt.sbprintf(&builder, "the kernel: %s + 0x%x, in no procedure of its debug object", known.kernel_module, offset)
			break
		}
		fmt.sbprintf(&builder, "the kernel: %s + 0x%x", place.procedure, place.offset_in_procedure)
		if place.file != "" {
			fmt.sbprintf(&builder, " (%s:%d)", place.file, place.line)
		}
	case .Firmware:
		strings.write_string(&builder, "the firmware")
	case .Firmware_System_Management_Mode:
		strings.write_string(&builder, "the firmware, in system management mode")
	case .Process:
		strings.write_string(&builder, "a process, at privilege level 3")
	case .No_Known_Code:
		strings.write_string(&builder, "no known code")
	}
	return strings.to_string(builder)
}

// known_code_of gives the code that the tool knows on a machine of this
// boot volume and firmware, from the files of its build and of QEMU.
@(private = "file")
known_code_of :: proc(output, volume: string, firmware: Machine_Firmware) -> Known_Code {
	known: Known_Code
	// The kernel module of the volume comes from the table of the volumes,
	// the one place that says which kernel each boot program holds.
	for row in build.boot_volumes() {
		if row.path == volume {
			known.kernel_module = row.kernel
		}
	}
	if known.kernel_module != "" {
		if object, error := os.read_entire_file(build.debug_object_path(known.kernel_module), context.temp_allocator); error == nil && debug_object.check(object) == .None {
			known.kernel_debug_object = object
		}
	}
	code_variable, _, _, variables_suffix := firmware_files(firmware)
	code_size, variables_size: i64 = -1, -1
	if code_information, error := os.stat(os.get_env(code_variable, context.temp_allocator), context.temp_allocator); error == nil {
		code_size = code_information.size
	}
	if variables_information, error := os.stat(machine_file(output, variables_suffix), context.temp_allocator); error == nil {
		variables_size = variables_information.size
	}
	if code_size > 0 && variables_size > 0 && u64(code_size + variables_size) < FIRMWARE_FLASH_END {
		known.firmware_flash_start = FIRMWARE_FLASH_END - u64(code_size + variables_size)
	}
	return known
}

// processors_report writes the state of the processors of a machine whose
// step failed, beside its log, and prints the line of each processor. It
// runs first after the failure, while QEMU still runs, so that the
// processors have not moved on. It never fails the test and never prints
// "test failed": the first fault stays the first such line.
processors_report :: proc(machine: ^Machine, output, volume: string, firmware: Machine_Firmware) {
	path := machine_file(output, PROCESSORS_STATE_SUFFIX)
	if machine.qmp.ended || !machine.qmp.open {
		fmt.eprintfln("modustool: the processors of %s at the failure: none: QEMU ended", output)
		return
	}
	// A stop gives the registers of each processor at one moment; the
	// machine runs again after the reads, as it did before.
	was_running := false
	if status, answered := qmp_command(&machine.qmp, "{\"execute\":\"query-status\"}", false); answered {
		// The value of the reply is the object of the status.
		if parsed, error := json.parse_string(status, .JSON, false, context.temp_allocator); error == .None {
			if object, is_object := parsed.(json.Object); is_object {
				running, _ := object["running"].(json.Boolean)
				was_running = bool(running)
			}
		}
	}
	stopped := false
	if was_running {
		_, stopped = qmp_command(&machine.qmp, "{\"execute\":\"stop\"}", false)
	}
	registers_value, registers_answered := qmp_command(&machine.qmp, qmp_monitor_command(REGISTERS_OF_ALL_PROCESSORS_LINE), false)
	list_value, list_answered := qmp_command(&machine.qmp, qmp_monitor_command(PROCESSOR_LIST_LINE), false)
	if stopped {
		_, _ = qmp_command(&machine.qmp, "{\"execute\":\"cont\"}", false)
	}
	if !registers_answered || !list_answered {
		fmt.eprintfln("modustool: the processors of %s at the failure: none: QEMU did not answer \"%s\" and \"%s\"", output, REGISTERS_OF_ALL_PROCESSORS_LINE, PROCESSOR_LIST_LINE)
		return
	}
	registers_text, registers_decoded := monitor_text_decode(registers_value)
	list_text, list_decoded := monitor_text_decode(list_value)
	file := strings.builder_make(context.temp_allocator)
	// The texts as the monitor printed them, or the raw value of a reply
	// that is not a JSON string.
	fmt.sbprintf(&file, "# %s\n%s\n# %s\n%s\n", PROCESSOR_LIST_LINE, list_decoded ? list_text : list_value, REGISTERS_OF_ALL_PROCESSORS_LINE, registers_decoded ? registers_text : registers_value)
	written := os.write_entire_file(path, file.buf[:]) == nil
	// One write: the lines of a machine of another part that runs at the
	// same time do not come between them.
	report := strings.builder_make(context.temp_allocator)
	if written {
		fmt.sbprintfln(&report, "modustool: the processors of %s at the failure: %s", output, path)
	} else {
		fmt.sbprintfln(&report, "modustool: the processors of %s at the failure: %s could not be written", output, path)
	}
	states: []Processor_State
	fault := Processor_Read_Fault.Not_A_Monitor_Text
	where_text := "the reply of the monitor"
	if registers_decoded && list_decoded {
		states, fault, where_text = processors_read(registers_text, list_text)
	}
	if fault != .None {
		fmt.sbprintfln(&report, "    the tool cannot read them: %s (%s)", processor_read_fault_sentences[fault], where_text)
	} else {
		known := known_code_of(output, volume, firmware)
		for state in states {
			fmt.sbprintfln(&report, "    %s", processor_line(state, known))
		}
	}
	fmt.eprint(strings.to_string(report))
}
