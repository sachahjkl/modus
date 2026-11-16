package modustool

import info "modus:contract/boot_info"
import iommu "modus:contract/iommu"
import op "modus:contract/operation"
import "core:fmt"
import "core:os"
import "core:strings"

// The measure of the deepest stack of the kernel (src/md/infrastructure/kernel_stack_depth.md;
// docs/TOOLS.md, "The deepest stack of the kernel"). The frames come from
// the section .stack_sizes that llc writes, the calls from the listing of
// the linked kernel. Each rule that the graph cannot read is a row of a
// table below, with its reason.

// The frame that interrupt_common and kernel_enter push before they call
// kernel_interrupt: the 15 registers, the vector, the error code, and the
// five values of the processor (src/kernel/processor.asm).
KERNEL_ENTRY_FRAME_BYTES :: 22 * 8
// The return address that a call pushes: the frame of llc does not hold
// it.
RETURN_ADDRESS_BYTES :: 8
// In 64-bit mode the processor aligns the stack pointer to 16 bytes before
// it pushes the frame of an interrupt on the stack where the kernel runs.
INTERRUPT_ALIGNMENT_BYTES :: 8
// At the iretq of resume the stack pointer is 40 bytes under the top: the
// five values of the return. Aligned to 16 bytes, the frame of a fault of
// that iretq starts 48 bytes under the top.
REFUSED_RETURN_BYTES_ABOVE :: 48
KERNEL_STACK_BYTES :: op.KERNEL_STACK_PAGES * info.PAGE_SIZE
// The build fails when less stays free. The listing does not show a push
// of an argument outside the frame, nor an indirect jump that is a tail
// call: the margin is the room for them.
KERNEL_STACK_LEAST_FREE_PAGES :: 4

// A place where the kernel starts on the kernel stack.
Kernel_Stack_Entry :: struct {
	name:        string, // The symbol of the procedure.
	bytes_above: int, // What is on the stack before its first instruction.
	label:       string, // What starts it, in the measure line.
}

// The bytes that one procedure of assembly pushes, read from its source:
// nasm writes no frame.
Kernel_Stack_Assembly_Frame :: struct {
	name:  string,
	bytes: int,
}

// A procedure that calls itself. levels: the most frames of it on one
// chain. 0: the measure leaves out each call into it.
Kernel_Stack_Recursion :: struct {
	name:   string,
	levels: int,
}

// A procedure whose indirect calls reach only the procedures of targets.
// No target: the call reaches no procedure of the kernel.
Kernel_Stack_Indirect_Call :: struct {
	caller:  string,
	targets: []string,
}

// A direct call of a procedure into data: the address is no procedure of
// the kernel, and the listing names the data symbol.
Kernel_Stack_Data_Call :: struct {
	caller: string,
	data:   string,
}

// A cycle of calls that a state of the kernel cuts: below procedure, no
// chain runs never_reaches again. The measure takes the depth of
// procedure with never_reaches left out.
Kernel_Stack_Cycle_Break :: struct {
	procedure:     string,
	never_reaches: string,
}

// The tables and the sizes of one measure. The build gives
// kernel_stack_rules; a host test gives its own.
Kernel_Stack_Rules :: struct {
	entries:                  []Kernel_Stack_Entry,
	// Procedures that start on another stack: their chains are not
	// measured, and what they reach counts as reached.
	other_stack_entries:      []string,
	assembly_frames:          []Kernel_Stack_Assembly_Frame,
	recursions:               []Kernel_Stack_Recursion,
	indirect_calls:           []Kernel_Stack_Indirect_Call,
	data_calls:               []Kernel_Stack_Data_Call,
	cycle_breaks:             []Kernel_Stack_Cycle_Break,
	// Compiled procedures that no code calls.
	not_run:                  []string,
	interrupt_entry:          string, // The procedure that each interrupt runs.
	idle_wait:                string, // The one place where the kernel takes an interrupt.
	stack_bytes:              int,
	least_free_bytes:         int,
	interrupt_stack_bytes:    int,
	double_fault_stack_bytes: int,
}

kernel_stack_rules := Kernel_Stack_Rules {
	entries = {
		{"kernel_interrupt", KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES, "an entry from a program"},
		{"kernel_interrupt", REFUSED_RETURN_BYTES_ABOVE + KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES, "a return that the processor refused"},
		// stack_switch and the start code push a null return address.
		{"kernel::first_run", RETURN_ADDRESS_BYTES, "the first run after the boot"},
		{"kernel::schedule_from_the_top", RETURN_ADDRESS_BYTES, "a fresh stack after a refused return"},
		{"kernel::processor_entry", RETURN_ADDRESS_BYTES, "the start of another processor"},
	},
	// The boot runs on the stack of the boot program.
	other_stack_entries = {"entry"},
	assembly_frames = {
		{"processor_stop", 0},
		{"idle_wait", 0},
		// It takes the return address off and pushes the code selector and
		// the return address: 8 bytes under its entry.
		{"gdt_load", 8},
		// Both move the stack pointer and never return: what runs after them
		// is an entry of this table or the program.
		{"resume", 0},
		{"stack_switch", 0},
		{"extended_state_save", 0},
		{"extended_state_restore", 0},
		{"extended_state_restore_and_read", 0},
		// Six saved registers, the address of the general registers of the
		// guest and the host area.
		{"guest_enter", 64},
		// src/runtime/memory.asm, the kernel form: rbx is saved for a copy of
		// 17 to 64 bytes.
		{"copy_bytes_without_overlap", 8},
		{"memcpy", 8},
		{"copy_bytes_with_overlap", 0},
		{"memmove", 0},
		{"fill_bytes_with_value", 0},
		{"memset", 0},
	},
	recursions = {
		// The default branch runs the operation of a command with a table of
		// error details once more, with the bit of the table removed: that
		// run never takes the branch again.
		{"kernel::execute", 2},
		// The self test fills the stack on purpose, until the guard page.
		{"kernel::self_test.overflow", 0},
		// One call for each level of the tables of a domain of the IOMMU.
		{"kernel::[iommu.odin]::tables_free", iommu.DOMAIN_TABLE_LEVELS_MOST},
		// One call for each level of a page table of the processor.
		{"kernel::mappings_report.walk", info.PAGE_TABLE_LEVELS},
	},
	indirect_calls = {
		// The self test calls the code of a program, to prove that the
		// processor refuses it: it faults at the first instruction, and the
		// fault stops the machine.
		{"kernel::self_test", {}},
	},
	data_calls = {
		// The self test calls data of the kernel, to prove that the processor
		// refuses to run it: it faults at the first instruction, and the
		// fault stops the machine. llc makes the call direct.
		{"kernel::self_test", "kernel::test_code"},
	},
	cycle_breaks = {
		// lock_order_broken calls fault_report_begin first: from then the log
		// writes the serial port only and takes no lock (log_take), and
		// machine_stop takes none. So no lock is taken below it.
		{"kernel::[lock.odin]::lock_order_broken", "kernel::lock_take"},
		// queue_ready logs only when a thread enters a queue outside its
		// placement (queue_push, a check of the test build), after
		// fault_report_begin: from then log_record returns before its wake
		// of the readers of the log, and the machine stops. That log is the
		// one way from queue_ready to word_wake.
		{"kernel::queue_ready", "kernel::word_wake"},
		// program_stop marks its program Stopped before it finishes its
		// threads and cleans it up. thread_finish stops the program of its
		// thread only while that program is not Stopped, and each thread
		// that program_stop and program_cleanup finish is of that program.
		// So below program_stop, no chain runs program_stop again.
		{"kernel::program_stop", "kernel::program_stop"},
	},
	// The conversions of 16-bit floating point numbers that Odin defines in
	// each module: the kernel has no floating point number.
	not_run = {"__truncsfhf2", "__gnu_f2h_ieee", "__truncdfhf2", "__gnu_h2f_ieee", "__extendhfsf2"},
	interrupt_entry = "kernel_interrupt",
	idle_wait = "idle_wait",
	stack_bytes = KERNEL_STACK_BYTES,
	least_free_bytes = KERNEL_STACK_LEAST_FREE_PAGES * info.PAGE_SIZE,
	interrupt_stack_bytes = op.KERNEL_INTERRUPT_STACK_PAGES * info.PAGE_SIZE,
	double_fault_stack_bytes = op.KERNEL_FAULT_STACK_PAGES * info.PAGE_SIZE,
}

// One procedure of the listing. names[0] is the first name at its address.
Stack_Procedure :: struct {
	names:               [dynamic]string,
	address:             u64,
	edges:               [dynamic]Stack_Edge,
	indirect_calls:      int,
	first_indirect_call: string, // The text of the first one.
	unknown_calls:       [dynamic]string, // The calls to an address where no procedure starts.
}

Stack_Edge :: struct {
	target: int, // The index of the procedure.
	tail:   bool, // A jump: the callee takes the place of the frame of the caller.
}

// A call or a jump of the listing to an address, before the procedures
// are all known.
Stack_Call :: struct {
	from:        int,
	address:     u64,
	tail:        bool,
	instruction: string,
}

// What the measure of one kernel gives: the lines, or the problems.
Kernel_Stack_Measure :: struct {
	lines:    [dynamic]string,
	problems: [dynamic]string,
	deepest:  int,
}

// The name of the file of the measure lines of a kernel module: an output
// of its compile step.
kernel_stack_measure_file :: proc(name: string) -> string {
	return join(module_build_folder, "/", name, "/kernel_stack.measure")
}

// kernel_stack_check measures the kernel stack of a linked kernel, prints
// each problem, and writes the measure lines when there is none.
kernel_stack_check :: proc(build: Module_Build, linked, listing: string) -> bool {
	path := kernel_stack_measure_file(build.name)
	// A failed check must not leave the lines of an earlier build.
	_ = os.remove(path)
	elf := read_file(linked) or_return
	frames, problem := kernel_stack_frames_read(elf)
	if problem != "" {
		fmt.eprintfln("modustool: the measure of the kernel stack of %s fails: %s", build.name, problem)
		return false
	}
	measure := kernel_stack_measure(build.name, listing, frames, kernel_stack_rules)
	if len(measure.problems) > 0 {
		for item in measure.problems {
			fmt.eprintfln("modustool: the measure of the kernel stack of %s fails: %s", build.name, item)
		}
		return false
	}
	text := strings.join(measure.lines[:], "\n", context.temp_allocator)
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// kernel_stack_measure_print prints the measure lines of each kernel
// module, a kept one too. A module that this command did not build has no
// file: it prints nothing.
kernel_stack_measure_print :: proc() {
	for build in module_builds {
		if !build.kernel {
			continue
		}
		text, error := os.read_entire_file(kernel_stack_measure_file(build.name), context.temp_allocator)
		if error != nil {
			continue
		}
		remaining := string(text)
		for line in strings.split_lines_iterator(&remaining) {
			if line != "" {
				fmt.printfln("modustool: measure: %s", line)
			}
		}
	}
}

// kernel_stack_frames_read gives the frame of each compiled procedure, by
// its address, from the sections .stack_sizes of a linked file: for each
// procedure, an address of 8 bytes, then the bytes of its frame in
// ULEB128. problem is not "" when the file has no such section or a cut
// entry: a measure that reads nothing proves nothing.
kernel_stack_frames_read :: proc(elf: []u8) -> (frames: map[u64]int, problem: string) {
	frames = make(map[u64]int, context.temp_allocator)
	header, sections, is_elf := elf_sections(elf)
	if !is_elf {
		return frames, "the linked file is not an ELF file of 64 bits"
	}
	if int(header.section_name_section_index) >= len(sections) {
		return frames, "the linked file has no table of section names"
	}
	names, has_names := elf_section_bytes(elf, sections[header.section_name_section_index])
	if !has_names {
		return frames, "the table of section names is outside the linked file"
	}
	found := false
	for section in sections {
		if text_until_zero(names, u64(section.name)) != ".stack_sizes" {
			continue
		}
		bytes, inside := elf_section_bytes(elf, section)
		if !inside {
			return frames, "a section .stack_sizes is outside the linked file"
		}
		found = true
		at := 0
		for at < len(bytes) {
			if len(bytes) - at < 8 {
				return frames, "an entry of .stack_sizes is cut in its address"
			}
			address: u64
			for index in 0 ..< 8 {
				address |= u64(bytes[at + index]) << (8 * u64(index))
			}
			at += 8
			size: u64
			shift: u64
			for {
				if at >= len(bytes) {
					return frames, "an entry of .stack_sizes is cut in its size"
				}
				value := bytes[at]
				at += 1
				if shift > 28 {
					return frames, "an entry of .stack_sizes has a size of more than 5 bytes"
				}
				size |= u64(value & 0x7F) << shift
				if value & 0x80 == 0 {
					break
				}
				shift += 7
			}
			frames[address] = max(frames[address], int(size))
		}
	}
	if !found {
		return frames, "the linked file has no section .stack_sizes: llc wrote no frame (-stack-size-section)"
	}
	return frames, ""
}

// listing_hexadecimal reads a number of the listing, with no prefix.
listing_hexadecimal :: proc(text: string) -> (value: u64, ok: bool) {
	if text == "" || len(text) > 16 {
		return 0, false
	}
	for character in transmute([]u8)text {
		digit: u64
		switch character {
		case '0' ..= '9':
			digit = u64(character - '0')
		case 'a' ..= 'f':
			digit = u64(character - 'a') + 10
		case 'A' ..= 'F':
			digit = u64(character - 'A') + 10
		case:
			return 0, false
		}
		value = value << 4 | digit
	}
	return value, true
}

// stack_name_matches says if a symbol is the name of a row: the same, or
// the name, "-" and the digits that Odin gives a nested procedure.
stack_name_matches :: proc(symbol, name: string) -> bool {
	if symbol == name {
		return true
	}
	if !strings.has_prefix(symbol, name) || len(symbol) < len(name) + 2 || symbol[len(name)] != '-' {
		return false
	}
	digits := symbol[len(name) + 1:]
	for character in digits {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

// stack_procedure_matches says if one name of a procedure is the name of
// a row.
stack_procedure_matches :: proc(procedure: Stack_Procedure, name: string) -> bool {
	for symbol in procedure.names {
		if stack_name_matches(symbol, name) {
			return true
		}
	}
	return false
}

// stack_procedure_named gives the index of the first procedure that has
// the name of a row, or -1.
stack_procedure_named :: proc(procedures: []Stack_Procedure, name: string) -> int {
	for procedure, index in procedures {
		if stack_procedure_matches(procedure, name) {
			return index
		}
	}
	return -1
}

// kernel_call_graph_read reads the procedures and the calls of a listing
// of `llvm-objdump -d --no-show-raw-insn --x86-asm-syntax=att`. frames
// tells a compiled procedure from a label of assembly.
kernel_call_graph_read :: proc(listing: string, frames: map[u64]int) -> []Stack_Procedure {
	procedures := make([dynamic]Stack_Procedure, context.temp_allocator)
	calls := make([dynamic]Stack_Call, context.temp_allocator)
	current := -1
	current_has_instructions := false
	text := listing
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		// "0000000000025800 <copy_bytes_without_overlap>:"
		if strings.has_suffix(trimmed, ">:") {
			if open := strings.index(trimmed, " <"); open > 0 {
				if address, is_address := listing_hexadecimal(trimmed[:open]); is_address {
					name := trimmed[open + 2:len(trimmed) - 2]
					_, compiled := frames[address]
					if current >= 0 && address == procedures[current].address && !current_has_instructions {
						// Two names at one address: one procedure.
						append(&procedures[current].names, name)
						continue
					}
					// A label of nasm inside a procedure of assembly:
					// "procedure.label", with no frame from llc. The listing
					// gives one name to an address, which can be another name
					// of the procedure: "memcpy", whose labels are
					// "copy_bytes_without_overlap.over16". So the name before
					// the dot is not compared.
					if current >= 0 && !compiled && strings.contains(name, ".") {
						_, current_compiled := frames[procedures[current].address]
						if !current_compiled {
							continue
						}
					}
					names := make([dynamic]string, context.temp_allocator)
					append(&names, name)
					append(&procedures, Stack_Procedure{names = names, address = address, edges = make([dynamic]Stack_Edge, context.temp_allocator), unknown_calls = make([dynamic]string, context.temp_allocator)})
					current = len(procedures) - 1
					current_has_instructions = false
					continue
				}
			}
		}
		// "25800:      	callq	0x25900 <kernel::log>"
		colon := strings.index(trimmed, ":")
		if colon <= 0 || current < 0 {
			continue
		}
		if _, is_address := listing_hexadecimal(trimmed[:colon]); !is_address {
			continue
		}
		instruction := strings.trim_space(trimmed[colon + 1:])
		if instruction == "" {
			continue
		}
		current_has_instructions = true
		mnemonic := instruction_mnemonic(instruction)
		is_call := mnemonic == "call" || mnemonic == "callq"
		is_jump := len(mnemonic) > 0 && mnemonic[0] == 'j'
		if !is_call && !is_jump {
			continue
		}
		operand := strings.trim_space(instruction[strings.index(instruction, mnemonic) + len(mnemonic):])
		if strings.has_prefix(operand, "*") {
			// A jump through a register is taken as a jump inside its
			// procedure: a table of the branches of a switch.
			if is_call {
				procedures[current].indirect_calls += 1
				if procedures[current].first_indirect_call == "" {
					procedures[current].first_indirect_call = instruction
				}
			}
			continue
		}
		target_text := operand
		if space := strings.index_any(operand, " \t"); space >= 0 {
			target_text = operand[:space]
		}
		target, is_target := listing_hexadecimal(strings.trim_prefix(target_text, "0x"))
		if !is_target {
			continue
		}
		append(&calls, Stack_Call{from = current, address = target, tail = is_jump, instruction = instruction})
	}
	starts := make(map[u64]int, context.temp_allocator)
	for procedure, index in procedures {
		starts[procedure.address] = index
	}
	for call in calls {
		target, is_start := starts[call.address]
		if !is_start {
			// A jump to an address inside a procedure is a branch.
			if !call.tail {
				append(&procedures[call.from].unknown_calls, call.instruction)
			}
			continue
		}
		append(&procedures[call.from].edges, Stack_Edge{target = target, tail = call.tail})
	}
	return procedures[:]
}

// What the search of the depths knows of the graph.
@(private = "file")
Depth_Search :: struct {
	procedures: []Stack_Procedure,
	frames:     []int, // -1: not known.
	levels:     []int, // 0: left out.
	target:     int, // The procedure where a chain ends; -1: any procedure.
	depth:      []int, // DEPTH_NOT_COMPUTED, DEPTH_NO_CHAIN, or the bytes from the entry of the procedure.
	next:       []int, // The callee of the deepest chain; -1: none.
	next_tail:  []bool,
	recursive:  []bool, // The deepest chain holds more than one level of it.
	// For a procedure of a cycle break: the procedure that no chain below
	// it runs; -1 for the others.
	cut:        []int,
	start:      int, // The cycle break whose search this is; -1: none.
	below:      []^Depth_Search, // The search below each cycle break, made at its first use.
}

// cut_levels gives a copy of levels with the procedure cut left out.
@(private = "file")
cut_levels :: proc(levels: []int, cut: int) -> []int {
	copied := make([]int, len(levels), context.temp_allocator)
	copy(copied, levels)
	copied[cut] = 0
	return copied
}

@(private = "file")
DEPTH_NOT_COMPUTED :: -1
@(private = "file")
DEPTH_NO_CHAIN :: -2

// depth_of gives the bytes of the deepest chain from the entry of one
// procedure, under its return address, to the end of a chain or to the
// target. The graph has no cycle but a call of a procedure to itself.
@(private = "file")
depth_of :: proc(search: ^Depth_Search, index: int) -> int {
	if search.depth[index] != DEPTH_NOT_COMPUTED {
		return search.depth[index]
	}
	if search.cut[index] >= 0 && index != search.start {
		// A cycle break: its depth comes from a search where the procedure
		// that no chain below it runs is left out.
		if search.below[index] == nil {
			search.below[index] = new(Depth_Search, context.temp_allocator)
			search.below[index]^ = depth_search_make(search.procedures, search.frames, cut_levels(search.levels, search.cut[index]), search.target, search.cut, index)
		}
		search.depth[index] = depth_of(search.below[index], index)
		return search.depth[index]
	}
	// A cycle was a problem before the search; a mark ends it if one stays.
	search.depth[index] = DEPTH_NO_CHAIN
	frame := max(search.frames[index], 0)
	if index == search.target {
		search.depth[index] = frame
		return frame
	}
	best := search.target < 0 ? frame : DEPTH_NO_CHAIN
	calls_itself := false
	for edge in search.procedures[index].edges {
		if search.levels[edge.target] == 0 {
			continue
		}
		if edge.target == index {
			calls_itself ||= !edge.tail
			continue
		}
		below := depth_of(search, edge.target)
		if below == DEPTH_NO_CHAIN {
			continue
		}
		through := edge.tail ? below : frame + RETURN_ADDRESS_BYTES + below
		if through > best {
			best = through
			search.next[index] = edge.target
			search.next_tail[index] = edge.tail
		}
	}
	if best != DEPTH_NO_CHAIN && calls_itself && search.levels[index] > 1 {
		best += (search.levels[index] - 1) * (frame + RETURN_ADDRESS_BYTES)
		search.recursive[index] = true
	}
	search.depth[index] = best
	return best
}

@(private = "file")
depth_search_make :: proc(procedures: []Stack_Procedure, frames, levels: []int, target: int, cut: []int, start: int) -> Depth_Search {
	search := Depth_Search {
		procedures = procedures,
		frames     = frames,
		levels     = levels,
		target     = target,
		depth      = make([]int, len(procedures), context.temp_allocator),
		next       = make([]int, len(procedures), context.temp_allocator),
		next_tail  = make([]bool, len(procedures), context.temp_allocator),
		recursive  = make([]bool, len(procedures), context.temp_allocator),
		cut        = cut,
		start      = start,
		below      = make([]^Depth_Search, len(procedures), context.temp_allocator),
	}
	for index in 0 ..< len(procedures) {
		search.depth[index] = DEPTH_NOT_COMPUTED
		search.next[index] = -1
	}
	return search
}

// chain_text names the procedures of the deepest chain from one procedure.
@(private = "file")
chain_text :: proc(search: ^Depth_Search, start: int) -> string {
	text := strings.builder_make(context.temp_allocator)
	search := search
	index := start
	tail := false
	for index >= 0 {
		// Below a cycle break, the chain is the one of its own search.
		if search.below[index] != nil && index != search.start {
			search = search.below[index]
		}
		if index != start {
			strings.write_string(&text, " -> ")
		}
		strings.write_string(&text, search.procedures[index].names[0])
		if search.recursive[index] {
			fmt.sbprintf(&text, " (%d levels)", search.levels[index])
		}
		if tail {
			strings.write_string(&text, " (a tail call)")
		}
		tail = search.next_tail[index]
		index = search.next[index]
	}
	return strings.to_string(text)
}

// The colors of the search of a cycle.
@(private = "file")
Cycle_Color :: enum u8 {
	Not_Seen,
	On_Path,
	Done,
}

// cycle_find gives the procedures of one cycle of calls that passes
// through more than one procedure, or nil. A cycle break other than start
// is an end: the search below it, with its cut procedure left out, is its
// own.
@(private = "file")
cycle_find :: proc(procedures: []Stack_Procedure, levels, cut: []int, start: int, colors: []Cycle_Color, path: ^[dynamic]int, index: int) -> []int {
	colors[index] = .On_Path
	append(path, index)
	edges := procedures[index].edges[:]
	if cut[index] >= 0 && index != start {
		edges = nil
	}
	for edge in edges {
		if edge.target == index || levels[edge.target] == 0 {
			continue
		}
		switch colors[edge.target] {
		case .On_Path:
			for item, position in path^ {
				if item == edge.target {
					return path^[position:]
				}
			}
		case .Not_Seen:
			if found := cycle_find(procedures, levels, cut, start, colors, path, edge.target); found != nil {
				return found
			}
		case .Done:
		}
	}
	pop(path)
	colors[index] = .Done
	return nil
}

// kernel_stack_measure measures the deepest chains of one kernel from its
// listing and its frames, with the tables of rules. The measure is good
// when problems is empty.
kernel_stack_measure :: proc(module_name: string, listing: string, frames: map[u64]int, rules: Kernel_Stack_Rules) -> (measure: Kernel_Stack_Measure) {
	measure.lines = make([dynamic]string, context.temp_allocator)
	measure.problems = make([dynamic]string, context.temp_allocator)
	procedures := kernel_call_graph_read(listing, frames)
	count := len(procedures)

	frame_of := make([]int, count, context.temp_allocator)
	levels := make([]int, count, context.temp_allocator)
	compiled := make([]bool, count, context.temp_allocator)
	indirect_stated := make([]bool, count, context.temp_allocator)
	for procedure, index in procedures {
		levels[index] = 1
		frame_of[index] = -1
		if frame, is_compiled := frames[procedure.address]; is_compiled {
			frame_of[index] = frame
			compiled[index] = true
			continue
		}
		for row in rules.assembly_frames {
			if stack_procedure_matches(procedure, row.name) {
				frame_of[index] = row.bytes
			}
		}
	}
	for row in rules.recursions {
		for procedure, index in procedures {
			if stack_procedure_matches(procedure, row.name) {
				levels[index] = row.levels
			}
		}
	}
	for row in rules.indirect_calls {
		for &procedure, index in procedures {
			if !stack_procedure_matches(procedure, row.caller) {
				continue
			}
			indirect_stated[index] = true
			for target_name in row.targets {
				target := stack_procedure_named(procedures, target_name)
				if target < 0 {
					append(&measure.problems, fmt.tprintf("the indirect calls of %s reach %s, and the listing has no such procedure", procedure.names[0], target_name))
					continue
				}
				append(&procedure.edges, Stack_Edge{target = target})
			}
		}
	}

	cut := make([]int, count, context.temp_allocator)
	for index in 0 ..< count {
		cut[index] = -1
	}
	for row in rules.cycle_breaks {
		at := stack_procedure_named(procedures, row.procedure)
		never := stack_procedure_named(procedures, row.never_reaches)
		if at < 0 || never < 0 {
			append(&measure.problems, fmt.tprintf("the cycle break of %s names a procedure that the listing does not have: %s or %s", row.procedure, row.procedure, row.never_reaches))
			continue
		}
		cut[at] = never
	}

	// The entries, and what they reach.
	entry_indexes := make([]int, len(rules.entries), context.temp_allocator)
	reached := make([]bool, count, context.temp_allocator)
	pending := make([dynamic]int, context.temp_allocator)
	for entry, position in rules.entries {
		entry_indexes[position] = stack_procedure_named(procedures, entry.name)
		if entry_indexes[position] < 0 {
			append(&measure.problems, fmt.tprintf("the listing has no procedure %s, an entry of the kernel stack (%s)", entry.name, entry.label))
			continue
		}
		append(&pending, entry_indexes[position])
	}
	for name in rules.other_stack_entries {
		if index := stack_procedure_named(procedures, name); index >= 0 {
			append(&pending, index)
		} else {
			append(&measure.problems, fmt.tprintf("the listing has no procedure %s, which starts on another stack", name))
		}
	}
	interrupt_entry := stack_procedure_named(procedures, rules.interrupt_entry)
	idle_wait := stack_procedure_named(procedures, rules.idle_wait)
	if interrupt_entry < 0 {
		append(&measure.problems, fmt.tprintf("the listing has no procedure %s: the measure cannot place an interrupt", rules.interrupt_entry))
	}
	if idle_wait < 0 {
		append(&measure.problems, fmt.tprintf("the listing has no procedure %s: the measure cannot place an interrupt over the kernel", rules.idle_wait))
	}
	for len(pending) > 0 {
		index := pop(&pending)
		if reached[index] {
			continue
		}
		reached[index] = true
		for edge in procedures[index].edges {
			if levels[edge.target] != 0 && !reached[edge.target] {
				append(&pending, edge.target)
			}
		}
	}

	// Each rule that the graph cannot read has a row.
	not_reached := make([dynamic]string, context.temp_allocator)
	for procedure, index in procedures {
		if !reached[index] {
			if compiled[index] && levels[index] != 0 {
				stated := false
				for name in rules.not_run {
					stated ||= stack_procedure_matches(procedure, name)
				}
				if !stated {
					append(&not_reached, procedure.names[0])
				}
			}
			continue
		}
		name := procedure.names[0]
		if frame_of[index] < 0 {
			append(&measure.problems, fmt.tprintf("a chain reaches %s, which has no frame: llc wrote none (a variable size on the stack), and the table of the assembly procedures has no row for it", name))
		}
		for call in procedure.unknown_calls {
			// A stated call into data: the listing names the data symbol
			// itself, at no offset, and no procedure has that name.
			stated := false
			for row in rules.data_calls {
				stated ||= stack_procedure_matches(procedure, row.caller) && strings.has_suffix(call, strings.concatenate({"<", row.data, ">"}, context.temp_allocator)) && stack_procedure_named(procedures, row.data) < 0
			}
			if !stated {
				append(&measure.problems, fmt.tprintf("%s calls an address where no procedure starts: %s", name, call))
			}
		}
		if procedure.indirect_calls > 0 && !indirect_stated[index] {
			append(&measure.problems, fmt.tprintf("%s has %d indirect calls (%s), and the table of the indirect calls has no row for it", name, procedure.indirect_calls, procedure.first_indirect_call))
		}
		for edge in procedure.edges {
			if edge.target == index && !edge.tail && levels[index] == 1 {
				append(&measure.problems, fmt.tprintf("%s calls itself, and the table of the recursions gives it no bound", name))
				break
			}
		}
	}
	if len(not_reached) > 0 {
		append(&measure.problems, fmt.tprintf("%d compiled procedures are reached from no entry: an entry that the table does not know, or code that no code calls: %s", len(not_reached), strings.join(not_reached[:min(len(not_reached), 12)], ", ", context.temp_allocator)))
	}
	// The graph of the entries, where each cycle break is an end, then the
	// graph below each cycle break, with its cut procedure left out.
	searches := make([dynamic]int, context.temp_allocator)
	append(&searches, -1)
	for index in 0 ..< count {
		if cut[index] >= 0 && reached[index] {
			append(&searches, index)
		}
	}
	search_cycles: for start in searches {
		search_levels := start < 0 ? levels : cut_levels(levels, cut[start])
		colors := make([]Cycle_Color, count, context.temp_allocator)
		path := make([dynamic]int, context.temp_allocator)
		for index in 0 ..< count {
			if (start >= 0 && index != start) || !reached[index] || colors[index] != .Not_Seen {
				continue
			}
			clear(&path)
			if cycle := cycle_find(procedures, search_levels, cut, start, colors, &path, index); cycle != nil {
				names := make([dynamic]string, context.temp_allocator)
				for item in cycle {
					append(&names, procedures[item].names[0])
				}
				append(&measure.problems, fmt.tprintf("a cycle of calls has no depth: %s", strings.join(names[:], " -> ", context.temp_allocator)))
				break search_cycles
			}
		}
	}
	if len(measure.problems) > 0 {
		return
	}

	// The depths.
	deepest := depth_search_make(procedures, frame_of, levels, -1, cut, -1)
	to_idle := depth_search_make(procedures, frame_of, levels, idle_wait, cut, -1)
	handler := depth_of(&deepest, interrupt_entry)
	measure.deepest = -1
	deepest_text := ""
	entries_text := strings.builder_make(context.temp_allocator)
	for entry, position in rules.entries {
		index := entry_indexes[position]
		bytes := entry.bytes_above + depth_of(&deepest, index)
		fmt.sbprintf(&entries_text, "%s%s %d bytes", position > 0 ? ", " : "", entry.label, bytes)
		if bytes > measure.deepest {
			measure.deepest = bytes
			deepest_text = fmt.tprintf("%s, %d bytes above it: %s", entry.label, entry.bytes_above, chain_text(&deepest, index))
		}
	}
	// One interrupt over the deepest chain to the idle wait.
	idle_bytes := -1
	idle_text := ""
	for entry, position in rules.entries {
		index := entry_indexes[position]
		below := depth_of(&to_idle, index)
		if below == DEPTH_NO_CHAIN || entry.bytes_above + below <= idle_bytes {
			continue
		}
		idle_bytes = entry.bytes_above + below
		idle_text = chain_text(&to_idle, index)
	}
	idle_line := "no chain reaches the idle wait"
	if idle_bytes >= 0 {
		over := idle_bytes
		idle_bytes += INTERRUPT_ALIGNMENT_BYTES + KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES + handler
		idle_line = fmt.tprintf("an interrupt at the idle wait %d bytes", idle_bytes)
		if idle_bytes > measure.deepest {
			measure.deepest = idle_bytes
			deepest_text = fmt.tprintf("an interrupt at the idle wait over %s (%d bytes), then %s", idle_text, over, chain_text(&deepest, interrupt_entry))
		}
	}
	free_bytes := rules.stack_bytes - measure.deepest
	if free_bytes < rules.least_free_bytes {
		append(&measure.problems, fmt.tprintf("the deepest chain leaves %d of the %d bytes of the kernel stack free, under the margin of %d bytes: %s", free_bytes, rules.stack_bytes, rules.least_free_bytes, deepest_text))
	}
	fault := measure.deepest + INTERRUPT_ALIGNMENT_BYTES + KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES + handler
	on_interrupt_stack := KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES + handler
	append(&measure.lines, fmt.tprintf("the kernel stack of %s: the deepest chain uses %d of %d bytes, %d bytes free, and the build fails under %d bytes free: %s", module_name, measure.deepest, rules.stack_bytes, free_bytes, rules.least_free_bytes, deepest_text))
	append(&measure.lines, fmt.tprintf("the kernel stack of %s: each entry: %s; %s; a fault of the kernel over the deepest chain %d bytes (not checked); %s with its frame %d bytes, on an interrupt stack of %d bytes and on the stack of the double fault of %d bytes (not checked)", module_name, strings.to_string(entries_text), idle_line, fault, rules.interrupt_entry, on_interrupt_stack, rules.interrupt_stack_bytes, rules.double_fault_stack_bytes))
	return
}
