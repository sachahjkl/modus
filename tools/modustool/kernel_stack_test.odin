package modustool

import "core:mem"
import "core:strings"
import "core:testing"

// The type of a table of strings in a section header.
KERNEL_STACK_TEST_STRING_TABLE :: 3

// One entry of the section .stack_sizes that a test writes.
Kernel_Stack_Test_Frame :: struct {
	address: u64,
	bytes:   u64,
}

// kernel_stack_test_elf gives the bytes of a linked file with one section
// .stack_sizes, as the link of llc writes it: for each procedure its
// address, then its frame in ULEB128.
kernel_stack_test_elf :: proc(frames: []Kernel_Stack_Test_Frame) -> []u8 {
	section_names := "\x00.shstrtab\x00.stack_sizes\x00"
	names_of_sections_name := strings.index(section_names, ".shstrtab")
	stack_sizes_name := strings.index(section_names, ".stack_sizes")
	sizes := make([dynamic]u8, context.temp_allocator)
	for frame in frames {
		for index in 0 ..< 8 {
			append(&sizes, u8(frame.address >> (8 * u64(index))))
		}
		value := frame.bytes
		for {
			byte_value := u8(value & 0x7F)
			value >>= 7
			if value != 0 {
				append(&sizes, byte_value | 0x80)
			} else {
				append(&sizes, byte_value)
				break
			}
		}
	}
	names_offset := size_of(Elf_Header)
	sizes_offset := names_offset + len(section_names)
	headers_offset := mem.align_forward_int(sizes_offset + len(sizes), 8)
	file := make([]u8, headers_offset + 3 * size_of(Elf_Section_Header), context.temp_allocator)
	header := Elf_Header {
		magic                      = ELF_MAGIC,
		class                      = ELF_CLASS_64,
		data                       = ELF_DATA_LITTLE_ENDIAN,
		identification_version     = 1,
		type                       = ELF_TYPE_SHARED,
		machine                    = ELF_MACHINE_X86_64,
		version                    = 1,
		section_header_offset      = u64(headers_offset),
		header_size                = size_of(Elf_Header),
		section_header_size        = size_of(Elf_Section_Header),
		section_header_count       = 3,
		section_name_section_index = 1,
	}
	mem.copy(&file[0], &header, size_of(header))
	copy(file[names_offset:], section_names)
	copy(file[sizes_offset:], sizes[:])
	sections := [3]Elf_Section_Header {
		{},
		{name = u32(names_of_sections_name), type = KERNEL_STACK_TEST_STRING_TABLE, offset = u64(names_offset), size = u64(len(section_names)), alignment = 1},
		{name = u32(stack_sizes_name), type = ELF_SECTION_PROGRAM_DATA, offset = u64(sizes_offset), size = u64(len(sizes)), alignment = 1},
	}
	mem.copy(&file[headers_offset], &sections[0], size_of(sections))
	return file
}

// A listing in the form of llvm-objdump, with: a call, a tail call, a
// recursion of two levels, a branch inside a procedure, a jump through a
// register, a procedure of assembly that the listing names by another of
// its names (memcpy) with labels of nasm under its first name, the idle
// wait, and a procedure on another stack.
KERNEL_STACK_TEST_LISTING :: `
build/modules/kernel/linked.elf:	file format elf64-x86-64

Disassembly of section .text:

0000000000001000 <kernel_interrupt>:
    1000:      	pushq	%rbp
    1001:      	callq	0x1100 <kernel::command_run>
    1006:      	callq	0x1400 <idle_wait>
    100b:      	retq

0000000000001100 <kernel::command_run>:
    1100:      	callq	0x1200 <kernel::execute>
    1105:      	jmp	0x1300 <kernel::log>

0000000000001200 <kernel::execute>:
    1200:      	callq	0x1200 <kernel::execute>
    1205:      	callq	0x1300 <kernel::log>
    120a:      	je	0x1205 <kernel::execute+0x5>
    120c:      	notrack	jmpq	*%rax

0000000000001300 <kernel::log>:
    1300:      	callq	0x1500 <memcpy>
    1305:      	retq

0000000000001400 <idle_wait>:
    1400:      	sti
    1401:      	hlt
    1402:      	cli
    1403:      	retq

0000000000001500 <memcpy>:
    1500:      	ja	0x1510 <copy_bytes_without_overlap.over16>
    1502:      	jb	0x1513 <copy_bytes_without_overlap.done>
    1504:      	retq

0000000000001510 <copy_bytes_without_overlap.over16>:
    1510:      	pushq	%rbx
    1511:      	popq	%rbx
    1512:      	retq

0000000000001513 <copy_bytes_without_overlap.done>:
    1513:      	retq

0000000000001600 <kernel::first_run>:
    1600:      	callq	0x1300 <kernel::log>

0000000000001700 <entry>:
    1700:      	callq	0x1300 <kernel::log>
`

@(rodata)
kernel_stack_test_frames := [?]Kernel_Stack_Test_Frame {
	{0x1000, 40}, // kernel_interrupt
	{0x1100, 24}, // kernel::command_run
	{0x1200, 200}, // kernel::execute
	{0x1300, 56}, // kernel::log
	{0x1600, 16}, // kernel::first_run
	{0x1700, 8}, // entry
}

// kernel_stack_test_rules gives the rules of the test listing, with a
// stack of stack_bytes and a margin of least_free_bytes.
kernel_stack_test_rules :: proc(stack_bytes, least_free_bytes: int) -> Kernel_Stack_Rules {
	entries := make([]Kernel_Stack_Entry, 2, context.temp_allocator)
	entries[0] = {"kernel_interrupt", KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES, "an entry from a program"}
	entries[1] = {"kernel::first_run", RETURN_ADDRESS_BYTES, "the first run"}
	other_stack_entries := make([]string, 1, context.temp_allocator)
	other_stack_entries[0] = "entry"
	assembly_frames := make([]Kernel_Stack_Assembly_Frame, 2, context.temp_allocator)
	assembly_frames[0] = {"idle_wait", 0}
	// The row names the name that the listing gives the procedure.
	assembly_frames[1] = {"memcpy", 8}
	recursions := make([]Kernel_Stack_Recursion, 1, context.temp_allocator)
	recursions[0] = {"kernel::execute", 2}
	return {
		entries = entries,
		other_stack_entries = other_stack_entries,
		assembly_frames = assembly_frames,
		recursions = recursions,
		interrupt_entry = "kernel_interrupt",
		idle_wait = "idle_wait",
		stack_bytes = stack_bytes,
		least_free_bytes = least_free_bytes,
	}
}

// The frames of a linked file come back by address.
@(test)
kernel_stack_frames_come_from_the_section :: proc(t: ^testing.T) {
	frames := [?]Kernel_Stack_Test_Frame{{0x1000, 40}, {0x2000, 300}, {0x3000, 0}}
	read, problem := kernel_stack_frames_read(kernel_stack_test_elf(frames[:]))
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(read), 3)
	testing.expect_value(t, read[0x1000], 40)
	testing.expect_value(t, read[0x2000], 300)
	testing.expect_value(t, read[0x3000], 0)
}

// A linked file with no section .stack_sizes is refused: a measure that
// reads no frame proves nothing.
@(test)
kernel_stack_frames_need_the_section :: proc(t: ^testing.T) {
	elf := kernel_stack_test_elf(nil)
	// Another name for the section: ".stack_sizex".
	name := strings.index(string(elf), ".stack_sizes")
	if !testing.expect(t, name >= 0) {
		return
	}
	elf[name + len(".stack_sizes") - 1] = 'x'
	_, problem := kernel_stack_frames_read(elf)
	testing.expect(t, strings.contains(problem, "no section .stack_sizes"), problem)
}

// The golden measure of the test listing:
//   log 56 + 8 + memcpy 8 = 72;
//   execute two levels: 200 + 8, then 200 + 8 + log 72: 488;
//   command_run 24 + 8 + execute 488 = 520 (its tail call to log: 72);
//   kernel_interrupt 40 + 8 + command_run 520 = 568, and 184 above it: 752;
//   first_run 16 + 8 + log 72 = 96, and 8 above it: 104;
//   the interrupt at the idle wait: 184 + 40 + 8 + 0 = 232, then
//   8 + 176 + 8 + 568: 992, the deepest;
//   a fault over it: 992 + 8 + 176 + 8 + 568 = 1752.
@(test)
kernel_stack_measure_golden :: proc(t: ^testing.T) {
	elf := kernel_stack_test_elf(kernel_stack_test_frames[:])
	frames, problem := kernel_stack_frames_read(elf)
	testing.expect_value(t, problem, "")
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, kernel_stack_test_rules(4096, 1024))
	testing.expect_value(t, len(measure.problems), 0)
	for item in measure.problems {
		testing.expect_value(t, item, "")
	}
	testing.expect_value(t, measure.deepest, 992)
	if !testing.expect_value(t, len(measure.lines), 2) {
		return
	}
	testing.expect_value(t, measure.lines[0], "the kernel stack of kernel: the deepest chain uses 992 of 4096 bytes, 3104 bytes free, and the build fails under 1024 bytes free: an interrupt at the idle wait over kernel_interrupt -> idle_wait (232 bytes), then kernel_interrupt -> kernel::command_run -> kernel::execute (2 levels) -> kernel::log -> memcpy")
	testing.expect_value(t, measure.lines[1], "the kernel stack of kernel: each entry: an entry from a program 752 bytes, the first run 104 bytes; an interrupt at the idle wait 992 bytes; a fault of the kernel over the deepest chain 1752 bytes (not checked)")
}

// A stack with less room than the margin after the deepest chain fails
// the build, and the problem names the chain.
@(test)
kernel_stack_measure_fails_under_the_margin :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_frames[:]))
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, kernel_stack_test_rules(992 + 63, 64))
	if !testing.expect_value(t, len(measure.problems), 1) {
		return
	}
	testing.expect(t, strings.has_prefix(measure.problems[0], "the deepest chain leaves 63 of the 1055 bytes of the kernel stack free, under the margin of 64 bytes: an interrupt at the idle wait"), measure.problems[0])
	passing := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, kernel_stack_test_rules(992 + 64, 64))
	testing.expect_value(t, len(passing.problems), 0)
}

// Each rule that the graph cannot read stops the measure when no row
// states it.
@(test)
kernel_stack_measure_refuses_what_no_row_states :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_frames[:]))
	// What a case changes in the rules of the test.
	Rule_Change :: enum {
		None,
		Without_First_Run, // The entry first_run is left out: nothing reaches it.
		Without_Idle_Wait_Frame, // The table of the assembly procedures has no row for idle_wait.
	}
	cases := [?]struct {
		about, old, new, problem: string,
		change:                   Rule_Change,
	} {
		{"an indirect call", "    1305:      \tretq", "    1305:      \tcallq\t*%rax", "kernel::log has 1 indirect calls (callq\t*%rax), and the table of the indirect calls has no row for it", .None},
		{"a call to an address where no procedure starts", "    1305:      \tretq", "    1305:      \tcallq\t0x1205 <kernel::execute+0x5>", "kernel::log calls an address where no procedure starts: callq\t0x1205 <kernel::execute+0x5>", .None},
		{"a call to a label of assembly", "    1006:      \tcallq\t0x1400 <idle_wait>", "    1006:      \tcallq\t0x1510 <copy_bytes_without_overlap.over16>", "kernel_interrupt calls an address where no procedure starts: callq\t0x1510 <copy_bytes_without_overlap.over16>", .None},
		{"a recursion with no row", "    1305:      \tretq", "    1305:      \tcallq\t0x1300 <kernel::log>", "kernel::log calls itself, and the table of the recursions gives it no bound", .None},
		{"a cycle of three procedures", "    1305:      \tretq", "    1305:      \tcallq\t0x1100 <kernel::command_run>", "a cycle of calls has no depth: kernel::command_run -> kernel::execute -> kernel::log", .None},
		{"a procedure with no frame", "", "", "a chain reaches idle_wait, which has no frame: llc wrote none (a variable size on the stack), and the table of the assembly procedures has no row for it", .Without_Idle_Wait_Frame},
		{"a compiled procedure that no entry reaches", "", "", "1 compiled procedures are reached from no entry: an entry that the table does not know, or code that no code calls: kernel::first_run", .Without_First_Run},
	}
	for item in cases {
		listing := KERNEL_STACK_TEST_LISTING
		if item.old != "" {
			replaced: bool
			listing, replaced = strings.replace(KERNEL_STACK_TEST_LISTING, item.old, item.new, 1, context.temp_allocator)
			testing.expect(t, replaced, item.about)
		}
		rules := kernel_stack_test_rules(4096, 1024)
		switch item.change {
		case .None:
		case .Without_First_Run:
			rules.entries = rules.entries[:1]
		case .Without_Idle_Wait_Frame:
			// The second row, memcpy, stays.
			rules.assembly_frames = rules.assembly_frames[1:]
		}
		measure := kernel_stack_measure("kernel", listing, frames, rules)
		found := false
		for problem in measure.problems {
			found ||= problem == item.problem
		}
		testing.expectf(t, found, "%s: %v", item.about, measure.problems[:])
	}
}

// kernel_stack_test_interrupt_rules gives the rules of the test listing
// with a stack that runs the report, of report_stack_bytes, and a stack of
// the stub only. The report runs command_run, with execute never run under
// it, and a fault inside the report runs idle_wait.
kernel_stack_test_interrupt_rules :: proc(report_stack_bytes: int) -> Kernel_Stack_Rules {
	rules := kernel_stack_test_rules(4096, 1024)
	stacks := make([]Kernel_Stack_Interrupt_Stack, 2, context.temp_allocator)
	stacks[0] = {"the test stack", report_stack_bytes, 256, true}
	stacks[1] = {"the stub stack", 512, 128, false}
	rules.interrupt_stacks = stacks
	report_callees := make([]string, 1, context.temp_allocator)
	report_callees[0] = "kernel::command_run"
	rules.report_callees = report_callees
	nested_report_callees := make([]string, 1, context.temp_allocator)
	nested_report_callees[0] = "idle_wait"
	rules.nested_report_callees = nested_report_callees
	report_never_reaches := make([]string, 1, context.temp_allocator)
	report_never_reaches[0] = "kernel::execute"
	rules.report_never_reaches = report_never_reaches
	return rules
}

// The interrupt stacks of the test listing:
//   the report: command_run with execute left out, 24, or its tail call to
//   log 72: 72; 8 + 72 = 80;
//   the stack that runs the report: 176 + 8 + 40 + 80 = 304, then a fault
//   inside it: 8 + 176 + 8 + 40 + 8 + idle_wait 0 = 240: 544;
//   the stack of the stub: 176.
@(test)
kernel_stack_interrupt_stacks_are_checked :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_frames[:]))
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, kernel_stack_test_interrupt_rules(1024))
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	if !testing.expect_value(t, len(measure.lines), 3) {
		return
	}
	testing.expect_value(t, measure.lines[2], "the interrupt stacks of kernel: the test stack 544 of 1024 bytes, 480 free, the build fails under 256; the stub stack 176 of 512 bytes, 336 free, the build fails under 128 (the stub only); the report: kernel_interrupt -> kernel::command_run -> kernel::log (a tail call) -> memcpy, then a fault inside it: kernel_interrupt -> idle_wait")

	small := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, kernel_stack_test_interrupt_rules(700))
	testing.expectf(t, len(small.problems) == 1 && strings.has_prefix(small.problems[0], "the interrupt stack of the test stack keeps 156 of its 700 bytes free, under the margin of 256 bytes: kernel_interrupt -> kernel::command_run"), "%v", small.problems[:])

	// A row of the report that names a procedure that kernel_interrupt does
	// not call holds nothing.
	rules := kernel_stack_test_interrupt_rules(1024)
	rules.report_callees[0] = "kernel::execute"
	wrong := kernel_stack_measure("kernel", KERNEL_STACK_TEST_LISTING, frames, rules)
	testing.expectf(t, len(wrong.problems) == 1 && wrong.problems[0] == "kernel_interrupt calls no procedure kernel::execute, which a row of the report names", "%v", wrong.problems[:])
}

// A row names a nested procedure of Odin without the number that the
// compiler gives it.
@(test)
kernel_stack_names_match_without_the_number :: proc(t: ^testing.T) {
	testing.expect(t, stack_name_matches("kernel::self_test.overflow-11736", "kernel::self_test.overflow"))
	testing.expect(t, stack_name_matches("kernel::execute", "kernel::execute"))
	testing.expect(t, !stack_name_matches("kernel::execute_locked", "kernel::execute"))
	testing.expect(t, !stack_name_matches("kernel::self_test.overflow", "kernel::self_test"))
	testing.expect(t, !stack_name_matches("kernel::execute-", "kernel::execute"))
	testing.expect(t, !stack_name_matches("kernel::execute-1a", "kernel::execute"))
}

// A listing with a call into data, a recursion over the levels of a table
// and a cycle that a state of the kernel cuts.
KERNEL_STACK_TEST_BREAK_LISTING :: "0000000000001000 <kernel_interrupt>:\n" +
	"    1000:      \tcallq\t0x1100 <kernel::lock_take>\n" +
	"    1005:      \tcallq\t0x1300 <kernel::self_test>\n" +
	"    100a:      \tcallq\t0x1400 <idle_wait>\n" +
	"0000000000001100 <kernel::lock_take>:\n" +
	"    1100:      \tcallq\t0x1200 <kernel::lock_order_broken>\n" +
	"0000000000001200 <kernel::lock_order_broken>:\n" +
	"    1200:      \tcallq\t0x1250 <kernel::log>\n" +
	"0000000000001250 <kernel::log>:\n" +
	"    1250:      \tcallq\t0x1100 <kernel::lock_take>\n" +
	"0000000000001300 <kernel::self_test>:\n" +
	"    1300:      \tcallq\t0x900 <kernel::test_code>\n" +
	"    1305:      \tcallq\t0x1350 <kernel::self_test.walk-12>\n" +
	"0000000000001350 <kernel::self_test.walk-12>:\n" +
	"    1350:      \tcallq\t0x1350 <kernel::self_test.walk-12>\n" +
	"0000000000001400 <idle_wait>:\n" +
	"    1400:      \tretq\n"

@(rodata)
kernel_stack_test_break_frames := [?]Kernel_Stack_Test_Frame {
	{0x1000, 16}, // kernel_interrupt
	{0x1100, 32}, // kernel::lock_take
	{0x1200, 48}, // kernel::lock_order_broken
	{0x1250, 64}, // kernel::log
	{0x1300, 24}, // kernel::self_test
	{0x1350, 40}, // kernel::self_test.walk-12
}

// The levels of the recursion of the test.
KERNEL_STACK_TEST_WALK_LEVELS :: 4

// kernel_stack_test_break_rules gives the rules of the listing of the
// breaks, each stated rule given or left out.
kernel_stack_test_break_rules :: proc(with_data_call, with_cycle_break: bool) -> Kernel_Stack_Rules {
	entries := make([]Kernel_Stack_Entry, 2, context.temp_allocator)
	entries[0] = {"kernel_interrupt", KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES, "an entry from a program"}
	entries[1] = {"kernel::lock_take", RETURN_ADDRESS_BYTES, "a lock"}
	assembly_frames := make([]Kernel_Stack_Assembly_Frame, 1, context.temp_allocator)
	assembly_frames[0] = {"idle_wait", 0}
	recursions := make([]Kernel_Stack_Recursion, 1, context.temp_allocator)
	recursions[0] = {"kernel::self_test.walk", KERNEL_STACK_TEST_WALK_LEVELS}
	rules := Kernel_Stack_Rules {
		entries = entries,
		assembly_frames = assembly_frames,
		recursions = recursions,
		interrupt_entry = "kernel_interrupt",
		idle_wait = "idle_wait",
		stack_bytes = 4096,
		least_free_bytes = 1024,
	}
	if with_data_call {
		data_calls := make([]Kernel_Stack_Data_Call, 1, context.temp_allocator)
		data_calls[0] = {"kernel::self_test", "kernel::test_code"}
		rules.data_calls = data_calls
	}
	if with_cycle_break {
		cycle_breaks := make([]Kernel_Stack_Cycle_Break, 1, context.temp_allocator)
		cycle_breaks[0] = {"kernel::lock_order_broken", "kernel::lock_take"}
		rules.cycle_breaks = cycle_breaks
	}
	return rules
}

// The depths of the listing of the breaks:
//   below lock_order_broken, lock_take is left out: log 64, then
//   lock_order_broken 48 + 8 + 64 = 120, lock_take 32 + 8 + 120 = 160;
//   walk four levels: 3 * (40 + 8) + 40 = 184; self_test 24 + 8 + 184 = 216;
//   kernel_interrupt 16 + 8 + 216 = 240, and 184 above it: 424;
//   the entry a lock: 8 + 160 = 168;
//   the interrupt at the idle wait: 184 + 16 + 8 + 0 = 208, then
//   8 + 176 + 8 + 240: 640, the deepest.
@(test)
kernel_stack_measure_takes_the_stated_breaks :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_break_frames[:]))
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_BREAK_LISTING, frames, kernel_stack_test_break_rules(true, true))
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	testing.expect_value(t, measure.deepest, 640)
	if !testing.expect_value(t, len(measure.lines), 2) {
		return
	}
	testing.expect(t, strings.has_suffix(measure.lines[0], "then kernel_interrupt -> kernel::self_test -> kernel::self_test.walk-12 (4 levels)"), measure.lines[0])
	testing.expect(t, strings.contains(measure.lines[1], "each entry: an entry from a program 424 bytes, a lock 168 bytes;"), measure.lines[1])

	without_data_call := kernel_stack_measure("kernel", KERNEL_STACK_TEST_BREAK_LISTING, frames, kernel_stack_test_break_rules(false, true))
	testing.expectf(t, len(without_data_call.problems) == 1 && without_data_call.problems[0] == "kernel::self_test calls an address where no procedure starts: callq\t0x900 <kernel::test_code>", "%v", without_data_call.problems[:])

	without_cycle_break := kernel_stack_measure("kernel", KERNEL_STACK_TEST_BREAK_LISTING, frames, kernel_stack_test_break_rules(true, false))
	testing.expectf(t, len(without_cycle_break.problems) == 1 && without_cycle_break.problems[0] == "a cycle of calls has no depth: kernel::lock_take -> kernel::lock_order_broken -> kernel::log", "%v", without_cycle_break.problems[:])
}

// A cycle break whose procedure never runs again below itself:
// kernel_interrupt 16 + 8 + stop; stop 32 + 8 + finish; finish 48, its
// call of stop left out: stop 88, kernel_interrupt 112, and 184 above it.
@(test)
kernel_stack_cycle_break_of_a_procedure_itself :: proc(t: ^testing.T) {
	listing := "0000000000001000 <kernel_interrupt>:\n" +
		"    1000:      \tcallq\t0x1100 <kernel::program_stop>\n" +
		"    1005:      \tcallq\t0x1400 <idle_wait>\n" +
		"0000000000001100 <kernel::program_stop>:\n" +
		"    1100:      \tcallq\t0x1200 <kernel::thread_finish>\n" +
		"0000000000001200 <kernel::thread_finish>:\n" +
		"    1200:      \tcallq\t0x1100 <kernel::program_stop>\n" +
		"0000000000001400 <idle_wait>:\n" +
		"    1400:      \tretq\n"
	stop_frames := [?]Kernel_Stack_Test_Frame{{0x1000, 16}, {0x1100, 32}, {0x1200, 48}}
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(stop_frames[:]))
	rules := kernel_stack_test_break_rules(false, false)
	rules.entries = rules.entries[:1]
	rules.recursions = nil
	cycle_breaks := make([]Kernel_Stack_Cycle_Break, 1, context.temp_allocator)
	cycle_breaks[0] = {"kernel::program_stop", "kernel::program_stop"}
	rules.cycle_breaks = cycle_breaks
	measure := kernel_stack_measure("kernel", listing, frames, rules)
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	if len(measure.lines) == 2 {
		testing.expect(t, strings.contains(measure.lines[1], "each entry: an entry from a program 296 bytes;"), measure.lines[1])
	}
}

// The chain below a cycle break is named through it.
@(test)
kernel_stack_chain_passes_a_cycle_break :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_break_frames[:]))
	rules := kernel_stack_test_break_rules(true, true)
	// With 1000 bytes above it, the entry a lock is the deepest: 1160.
	rules.entries[1].bytes_above = 1000
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_BREAK_LISTING, frames, rules)
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	testing.expect_value(t, measure.deepest, 1160)
	if len(measure.lines) == 2 {
		testing.expect(t, strings.has_suffix(measure.lines[0], "a lock, 1000 bytes above it: kernel::lock_take -> kernel::lock_order_broken -> kernel::log"), measure.lines[0])
	}
}
