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
// register of a table of a switch, a procedure of assembly that the
// listing names by another of its names (memcpy) with labels of nasm under
// its first name, the idle wait, and a procedure on another stack.
KERNEL_STACK_TEST_LISTING :: `
build/modules/kernel/linked.elf:	file format elf64-x86-64

Disassembly of section .text:

0000000000001000 <kernel_interrupt>:
    1000:      	pushq	%rbp
    1001:      	callq	0x1100 <kernel::command_run>
    1006:      	callq	0x1400 <idle_wait>
    100b:      	popq	%rbp
    100c:      	retq

0000000000001100 <kernel::command_run>:
    1100:      	callq	0x1200 <kernel::execute>
    1105:      	jmp	0x1300 <kernel::log>

0000000000001200 <kernel::execute>:
    1200:      	pushq	%rbp
    1201:      	callq	0x1200 <kernel::execute>
    1206:      	callq	0x1300 <kernel::log>
    120b:      	je	0x1206 <kernel::execute+0x6>
    120d:      	notrack	jmpq	*%rax

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
	"    1105:      \tretq\n" +
	"0000000000001200 <kernel::lock_order_broken>:\n" +
	"    1200:      \tcallq\t0x1250 <kernel::log>\n" +
	"    1205:      \tretq\n" +
	"0000000000001250 <kernel::log>:\n" +
	"    1250:      \tcallq\t0x1100 <kernel::lock_take>\n" +
	"    1255:      \tretq\n" +
	"0000000000001300 <kernel::self_test>:\n" +
	"    1300:      \tcallq\t0x900 <kernel::test_code>\n" +
	"    1305:      \tcallq\t0x1350 <kernel::self_test.walk-12>\n" +
	"    130a:      \tretq\n" +
	"0000000000001350 <kernel::self_test.walk-12>:\n" +
	"    1350:      \tcallq\t0x1350 <kernel::self_test.walk-12>\n" +
	"    1355:      \tretq\n" +
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
		"    1105:      \tretq\n" +
		"0000000000001200 <kernel::thread_finish>:\n" +
		"    1200:      \tcallq\t0x1100 <kernel::program_stop>\n" +
		"    1205:      \tretq\n" +
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

// A listing with two arguments pushed outside the frame before a call, and
// a jump through a register where no frame stays: an indirect tail call.
KERNEL_STACK_TEST_PUSH_LISTING :: "0000000000001000 <kernel_interrupt>:\n" +
	"    1000:      \tpushq\t%rbp\n" +
	"    1001:      \tmovq\t%rsp, %rbp\n" +
	"    1004:      \tsubq\t$0x8, %rsp            # imm = 0x8\n" +
	"    1008:      \tpushq\t%rax\n" +
	"    1009:      \tpushq\t$0x0\n" +
	"    100b:      \tcallq\t0x1100 <kernel::thread_create>\n" +
	"    1010:      \taddq\t$0x10, %rsp\n" +
	"    1014:      \tcallq\t0x1200 <kernel::log_dispatch>\n" +
	"    1019:      \tcallq\t0x1400 <idle_wait>\n" +
	"    101e:      \taddq\t$0x8, %rsp\n" +
	"    1022:      \tpopq\t%rbp\n" +
	"    1023:      \tretq\n" +
	"0000000000001100 <kernel::thread_create>:\n" +
	"    1100:      \tretq\n" +
	"0000000000001200 <kernel::log_dispatch>:\n" +
	"    1200:      \tjmpq\t*%rax\n" +
	"0000000000001300 <kernel::log_serial>:\n" +
	"    1300:      \tretq\n" +
	"0000000000001400 <idle_wait>:\n" +
	"    1400:      \tretq\n"

// The frame of kernel_interrupt is what its prologue pushes and
// subtracts: 8 + 8.
@(rodata)
kernel_stack_test_push_frames := [?]Kernel_Stack_Test_Frame {
	{0x1000, 16}, // kernel_interrupt
	{0x1100, 48}, // kernel::thread_create
	{0x1200, 8}, // kernel::log_dispatch
	{0x1300, 24}, // kernel::log_serial
}

// kernel_stack_test_push_rules gives the rules of the listing of the
// pushes, with the row of the indirect tail call or without it.
kernel_stack_test_push_rules :: proc(with_indirect_row: bool) -> Kernel_Stack_Rules {
	entries := make([]Kernel_Stack_Entry, 1, context.temp_allocator)
	entries[0] = {"kernel_interrupt", KERNEL_ENTRY_FRAME_BYTES + RETURN_ADDRESS_BYTES, "an entry from a program"}
	assembly_frames := make([]Kernel_Stack_Assembly_Frame, 1, context.temp_allocator)
	assembly_frames[0] = {"idle_wait", 0}
	rules := Kernel_Stack_Rules {
		entries = entries,
		assembly_frames = assembly_frames,
		interrupt_entry = "kernel_interrupt",
		idle_wait = "idle_wait",
		stack_bytes = 4096,
		least_free_bytes = 1024,
	}
	if with_indirect_row {
		targets := make([]string, 1, context.temp_allocator)
		targets[0] = "kernel::log_serial"
		indirect_calls := make([]Kernel_Stack_Indirect_Call, 1, context.temp_allocator)
		indirect_calls[0] = {"kernel::log_dispatch", targets}
		rules.indirect_calls = indirect_calls
	}
	return rules
}

// The depths of the listing of the pushes:
//   the call of thread_create: 16 + 16 pushed + 8 + 48 = 88;
//   log_dispatch: its tail call to log_serial, 24; its call: 16 + 8 + 24 = 48;
//   kernel_interrupt 88, and 184 above it: 272;
//   the interrupt at the idle wait: 184 + 16 + 8 + 0 = 208, then
//   8 + 176 + 8 + 88: 488, the deepest;
//   a fault over it: 488 + 8 + 176 + 8 + 88 = 768.
// With a frame of 400 for log_serial, the indirect tail call is the
// deepest: 16 + 8 + 400 = 424, and 208 + 8 + 176 + 8 + 424 = 824.
@(test)
kernel_stack_measure_counts_the_pushes_and_the_indirect_tail_calls :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_push_frames[:]))
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_PUSH_LISTING, frames, kernel_stack_test_push_rules(true))
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	testing.expect_value(t, measure.deepest, 488)
	if testing.expect_value(t, len(measure.lines), 2) {
		testing.expect_value(t, measure.lines[0], "the kernel stack of kernel: the deepest chain uses 488 of 4096 bytes, 3608 bytes free, and the build fails under 1024 bytes free: an interrupt at the idle wait over kernel_interrupt -> idle_wait (208 bytes), then kernel_interrupt (16 bytes pushed for the call) -> kernel::thread_create")
		testing.expect_value(t, measure.lines[1], "the kernel stack of kernel: each entry: an entry from a program 272 bytes; an interrupt at the idle wait 488 bytes; a fault of the kernel over the deepest chain 768 bytes (not checked)")
	}

	deep_frames := kernel_stack_test_push_frames
	deep_frames[3].bytes = 400
	deep, _ := kernel_stack_frames_read(kernel_stack_test_elf(deep_frames[:]))
	through_the_tail_call := kernel_stack_measure("kernel", KERNEL_STACK_TEST_PUSH_LISTING, deep, kernel_stack_test_push_rules(true))
	testing.expectf(t, len(through_the_tail_call.problems) == 0, "%v", through_the_tail_call.problems[:])
	testing.expect_value(t, through_the_tail_call.deepest, 824)
	if len(through_the_tail_call.lines) == 2 {
		testing.expect(t, strings.has_suffix(through_the_tail_call.lines[0], "then kernel_interrupt -> kernel::log_dispatch -> kernel::log_serial (a tail call)"), through_the_tail_call.lines[0])
	}
}

// Each fact that the scan of the stack pointer cannot read, and an
// indirect tail call with no row, stops the measure.
@(test)
kernel_stack_scan_refuses_what_it_cannot_read :: proc(t: ^testing.T) {
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(kernel_stack_test_push_frames[:]))
	cases := [?]struct {
		about, old, new, problem: string,
		with_indirect_row:        bool,
	} {
		{"an indirect tail call with no row", "", "", "kernel::log_dispatch has 1 indirect tail calls (jmpq\t*%rax), and the table of the indirect calls has no row for it", false},
		{"a return with bytes on the stack", "    1022:      \tpopq\t%rbp\n", "    1022:      \tnop\n", "kernel_interrupt returns with 8 bytes on its stack: retq", true},
		{"a write of the stack pointer that the scan does not read", "    1004:      \tsubq\t$0x8, %rsp            # imm = 0x8\n", "    1004:      \tandq\t$-0x10, %rsp\n", "kernel_interrupt writes its stack pointer in a form that the scan does not read: andq\t$-0x10, %rsp", true},
		{"a tail call with bytes on the stack", "    1019:      \tcallq\t0x1400 <idle_wait>\n", "    1019:      \tjmp\t0x1300 <kernel::log_serial>\n", "kernel_interrupt jumps to kernel::log_serial with 16 bytes on its stack: jmp\t0x1300 <kernel::log_serial>", true},
		{"a pop under the entry", "    1000:      \tpushq\t%rbp\n", "    1000:      \tnop\n", "kernel_interrupt takes more bytes off its stack than it put on it: popq\t%rbp", true},
		{"a jump to an address where nothing starts", "    1019:      \tcallq\t0x1400 <idle_wait>\n", "    1019:      \tjmp\t0x1050 <kernel_interrupt+0x50>\n", "kernel_interrupt jumps to an address where no instruction of it and no procedure starts: jmp\t0x1050 <kernel_interrupt+0x50>", true},
	}
	for item in cases {
		listing := KERNEL_STACK_TEST_PUSH_LISTING
		if item.old != "" {
			replaced: bool
			listing, replaced = strings.replace(KERNEL_STACK_TEST_PUSH_LISTING, item.old, item.new, 1, context.temp_allocator)
			testing.expect(t, replaced, item.about)
		}
		measure := kernel_stack_measure("kernel", listing, frames, kernel_stack_test_push_rules(item.with_indirect_row))
		found := false
		for problem in measure.problems {
			found ||= problem == item.problem
		}
		testing.expectf(t, found, "%s: %v", item.about, measure.problems[:])
	}
}

// A listing with a table of a switch whose branches no path reaches, and
// calls of a procedure that never returns after pushed arguments.
KERNEL_STACK_TEST_TABLE_LISTING :: "0000000000001000 <kernel_interrupt>:\n" +
	"    1000:      \tpushq\t%rbp\n" +
	"    1001:      \tcallq\t0x1200 <kernel::dispatch>\n" +
	"    1006:      \tje\t0x100f <kernel_interrupt+0xf>\n" +
	"    1008:      \tpushq\t$0x0\n" +
	"    100a:      \tcallq\t0x1100 <kernel::machine_stop>\n" +
	"    100f:      \tpopq\t%rbp\n" +
	"    1010:      \tretq\n" +
	"0000000000001100 <kernel::machine_stop>:\n" +
	"    1100:      \thlt\n" +
	"    1101:      \tjmp\t0x1100 <kernel::machine_stop>\n" +
	"0000000000001200 <kernel::dispatch>:\n" +
	"    1200:      \tpushq\t%rbp\n" +
	"    1201:      \tpushq\t%rax\n" +
	"    1202:      \tjmpq\t*%rcx\n" +
	"    1204:      \tnopw\t%cs:(%rax,%rax)\n" +
	"    120e:      \tpushq\t$0x0\n" +
	"    1210:      \tcallq\t0x1100 <kernel::machine_stop>\n" +
	"    1215:      \tpopq\t%rax\n" +
	"    1216:      \tpopq\t%rbp\n" +
	"    1217:      \tretq\n" +
	"0000000000001400 <idle_wait>:\n" +
	"    1400:      \tretq\n"

// The depths of the listing of the table:
//   machine_stop 16; it never returns, so the 8 bytes pushed before each
//   call of it do not flow into the block after the call;
//   dispatch: the branch of its table starts at 16, and pushes 8 before
//   the call: 16 + 8 + 8 + 16 = 48;
//   kernel_interrupt: 8 + 8 + 48 = 64 (its call of machine_stop:
//   8 + 8 + 8 + 16 = 40), and 184 above it: 248;
//   a fault over it: 248 + 8 + 176 + 8 + 64 = 504.
@(test)
kernel_stack_scan_follows_the_tables_and_the_calls_that_never_return :: proc(t: ^testing.T) {
	table_frames := [?]Kernel_Stack_Test_Frame{{0x1000, 8}, {0x1100, 16}, {0x1200, 16}}
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(table_frames[:]))
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_TABLE_LISTING, frames, kernel_stack_test_push_rules(false))
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	testing.expect_value(t, measure.deepest, 248)
	if testing.expect_value(t, len(measure.lines), 2) {
		testing.expect_value(t, measure.lines[0], "the kernel stack of kernel: the deepest chain uses 248 of 4096 bytes, 3848 bytes free, and the build fails under 1024 bytes free: an entry from a program, 184 bytes above it: kernel_interrupt -> kernel::dispatch (8 bytes pushed for the call) -> kernel::machine_stop")
		testing.expect_value(t, measure.lines[1], "the kernel stack of kernel: each entry: an entry from a program 248 bytes; no chain reaches the idle wait; a fault of the kernel over the deepest chain 504 bytes (not checked)")
	}
}

// Lines of the listing of the kernel: a prefix that llvm-objdump writes on
// its own line, at the address that a jump goes to (memory_protect), and
// gdt_load, which returns with a far return, before a call of log_in
// (processor_setup). The prologues and the ends are added.
KERNEL_STACK_TEST_REAL_LINES_LISTING :: "0000000000001000 <kernel_interrupt>:\n" +
	"    1000:      \tcallq\t0x23170 <kernel::memory_protect>\n" +
	"    1005:      \tcallq\t0x2a6e0 <kernel::processor_setup>\n" +
	"    100a:      \tcallq\t0x1400 <idle_wait>\n" +
	"    100f:      \tretq\n" +
	"0000000000023170 <kernel::memory_protect>:\n" +
	"   23170:      \tpushq\t%rbp\n" +
	"   2391a:      \tjmp\t0x23941 <kernel::memory_protect+0x7d1>\n" +
	"   2391c:      \tlock\n" +
	"   2391d:      \tdecq\t0x48(%rsi)\n" +
	"   23921:      \tmovabsq\t$0xffffffffff000, %r11  # imm = 0xFFFFFFFFFF000\n" +
	"   23941:      \tincq\t%r8\n" +
	"   239e1:      \tje\t0x2391c <kernel::memory_protect+0x7ac>\n" +
	"   239e7:      \tpopq\t%rbp\n" +
	"   239e8:      \tretq\n" +
	"000000000002a6e0 <kernel::processor_setup>:\n" +
	"   2a6e0:      \tpushq\t%rbp\n" +
	"   2a70c:      \tmovq\t%rbx, %rdi\n" +
	"   2a70f:      \tcallq\t0xa5f58 <gdt_load>\n" +
	"   2a714:      \tmovl\t%r14d, %eax\n" +
	"   2ab0d:      \tcallq\t0x1b470 <kernel::log_in>\n" +
	"   2ab12:      \tpopq\t%rbp\n" +
	"   2ab13:      \tretq\n" +
	"000000000001b470 <kernel::log_in>:\n" +
	"   1b470:      \tretq\n" +
	"00000000000a5f58 <gdt_load>:\n" +
	"   a5f58:      \tlgdtq\t(%rdi)\n" +
	"   a5f5b:      \tmovw\t$0x10, %ax\n" +
	"   a5f5f:      \tmovl\t%eax, %ds\n" +
	"   a5f61:      \tmovl\t%eax, %es\n" +
	"   a5f63:      \tmovl\t%eax, %ss\n" +
	"   a5f65:      \txorl\t%eax, %eax\n" +
	"   a5f67:      \tmovl\t%eax, %fs\n" +
	"   a5f69:      \tmovl\t%eax, %gs\n" +
	"   a5f6b:      \tpopq\t%rax\n" +
	"   a5f6c:      \tpushq\t$0x8\n" +
	"   a5f6e:      \tpushq\t%rax\n" +
	"   a5f6f:      \tlretq\n" +
	"0000000000001400 <idle_wait>:\n" +
	"    1400:      \tretq\n"

// The depths, with the frames of the kernel:
//   memory_protect 968; processor_setup: 200 + 8 + log_in 744 = 952 (its
//   call of gdt_load: 200 + 8 + 8 = 216);
//   kernel_interrupt 16 + 8 + 968 = 992, and 184 above it: 1176;
//   the interrupt at the idle wait: 184 + 16 + 8 + 0 = 208, then
//   8 + 176 + 8 + 992: 1392, the deepest.
@(test)
kernel_stack_scan_reads_a_prefix_line_and_a_far_return :: proc(t: ^testing.T) {
	real_frames := [?]Kernel_Stack_Test_Frame{{0x1000, 16}, {0x23170, 968}, {0x2a6e0, 200}, {0x1b470, 744}}
	frames, _ := kernel_stack_frames_read(kernel_stack_test_elf(real_frames[:]))
	rules := kernel_stack_test_push_rules(false)
	assembly_frames := make([]Kernel_Stack_Assembly_Frame, 2, context.temp_allocator)
	assembly_frames[0] = {"idle_wait", 0}
	// It takes the return address off and pushes the code selector and the
	// return address.
	assembly_frames[1] = {"gdt_load", 8}
	rules.assembly_frames = assembly_frames
	measure := kernel_stack_measure("kernel", KERNEL_STACK_TEST_REAL_LINES_LISTING, frames, rules)
	testing.expectf(t, len(measure.problems) == 0, "%v", measure.problems[:])
	testing.expect_value(t, measure.deepest, 1392)
	if testing.expect_value(t, len(measure.lines), 2) {
		testing.expect(t, strings.contains(measure.lines[1], "each entry: an entry from a program 1176 bytes;"), measure.lines[1])
	}
}
