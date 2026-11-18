package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import info "modus:contract/boot_info"
import debug_object "modus:contract/debug_object"
import "modus:contract/operation"
import "modus:contract/operation_sequence"

// ---------------------------------------------------------------------
// The arguments.

// A run always names its count: no count, 0, a negative count, a sign, a
// separator, a prefix, one past the largest u64, a text, an empty text and
// a third argument are refused, and so is a seed that is no number.
@(test)
fuzz_operations_refuses_a_run_with_no_count :: proc(t: ^testing.T) {
	refused := [?][]string{
		{},
		{"0"},
		{"-1"},
		{"-0"},
		{"+5"},
		{"1_000"},
		{"0x10"},
		{"18446744073709551616"},
		{"99999999999999999999"},
		{"many"},
		{""},
		{" 5"},
		{"5", "-1"},
		{"5", "seed"},
		{"5", "18446744073709551616"},
		{"5", "7", "9"},
	}
	for args in refused {
		arguments, problem := operation_fuzzing_arguments_read(args)
		testing.expectf(t, problem != "", "the arguments %v are taken", args)
		testing.expectf(t, arguments == Operation_Fuzzing_Arguments{}, "the refused arguments %v give %v", args, arguments)
	}
}

// The edges that a run takes: 1, the largest u64, and a seed of 0, which is
// a seed that the command names.
@(test)
fuzz_operations_reads_its_count_and_its_seed :: proc(t: ^testing.T) {
	one, one_problem := operation_fuzzing_arguments_read({"1"})
	testing.expect_value(t, one_problem, "")
	testing.expect_value(t, one, Operation_Fuzzing_Arguments{executions = 1})
	largest, largest_problem := operation_fuzzing_arguments_read({"18446744073709551615", "0"})
	testing.expect_value(t, largest_problem, "")
	testing.expect_value(t, largest, Operation_Fuzzing_Arguments{executions = max(u64), seed = 0, seed_given = true})
}

// ---------------------------------------------------------------------
// The signatures.

// The border of the exit status of QEMU refuses an even status, a negative
// one, and a code one past the largest reason; each reason reads back.
@(test)
the_exit_status_names_a_reason_of_the_kernel_or_is_refused :: proc(t: ^testing.T) {
	past := int(u64(max(Kernel_Stop_Reason)) + 1)
	for status in ([]int{0, 2, -1, past << 1 | 1, max(int)}) {
		_, known := operation_stop_reason_of_status(status)
		testing.expectf(t, !known, "the status %d names a reason", status)
	}
	for reason in Kernel_Stop_Reason {
		read, known := operation_stop_reason_of_status(int(u64(reason)) << 1 | 1)
		testing.expect(t, known)
		testing.expect_value(t, read, reason)
	}
}

@(test)
each_word_with_a_digit_is_removed_from_a_report :: proc(t: ^testing.T) {
	testing.expect_value(t, operation_numbers_removed("kernel: exception in the kernel: page fault vector 14 error 0000000000000002 at ffffffff8001a2b0 address 0000000000000010: write"), "kernel: exception in the kernel: page fault vector # error # at # address #: write")
	testing.expect_value(t, operation_numbers_removed("free bits 12, marked 1"), "free bits #, marked #")
	testing.expect_value(t, operation_numbers_removed(""), "")
	testing.expect_value(t, operation_numbers_removed("the lock order is broken: a lock Program_Table"), "the lock order is broken: a lock Program_Table")
}

// A value of the kernel in hexadecimal can hold letters only: each word of
// 16 hexadecimal digits goes, with no decimal digit too. A word of 16
// letters that are not all hexadecimal stays, and so do 15 and 17
// hexadecimal letters, which are no value of the kernel.
@(test)
each_hexadecimal_value_of_the_kernel_is_removed_from_a_report :: proc(t: ^testing.T) {
	testing.expect_value(t, operation_numbers_removed("at ffffffffffffffff address deadbeefdeadbeef"), "at # address #")
	testing.expect_value(t, operation_numbers_removed("at FFFFFFFFFFFFFFFF"), "at #")
	testing.expect_value(t, operation_numbers_removed("the word abcdefghijklmnop stays"), "the word abcdefghijklmnop stays")
	testing.expect_value(t, operation_numbers_removed("fffffffffffffff and fffffffffffffffff"), "fffffffffffffff and fffffffffffffffff")
	testing.expect_value(t, operation_numbers_removed("a deadbeef face"), "a deadbeef face")
	first, _ := operation_stop_signature(int(u64(Kernel_Stop_Reason.Fault)) << 1 | 1, "kernel: exception in the kernel: page fault vector 14 error 0000000000000000 at ffffffff8001a2b0 address ffffffffffffffff: write\n", nil)
	second, _ := operation_stop_signature(int(u64(Kernel_Stop_Reason.Fault)) << 1 | 1, "kernel: exception in the kernel: page fault vector 14 error 0000000000000000 at ffffffff8001a2b0 address 0000000000001000: write\n", nil)
	testing.expect_value(t, first, second)
}

// A log of a stop, with the address of the instruction and the numbers of
// one run.
@(private = "file")
stop_log :: proc(address: string, error: string) -> string {
	return fmt.tprintf("kernel: ok\r\n[operation_fuzzing] operation_fuzzing: mailbox at 1234\r\nkernel: program operation_sequence_runner stopped: page fault vector 14 at 0000000000401000\r\nkernel: the line above is cut: the report of a fault of the kernel starts here\r\nkernel: exception in the kernel: page fault vector 14 error %s at %s address 0000000000000010: a read of a page that is not present\r\n", error, address)
}

// Two runs of one stop give one signature, whatever the addresses and the
// counts; another reason, another report and a log with no line of the
// kernel give others.
@(test)
two_runs_of_one_stop_give_one_signature :: proc(t: ^testing.T) {
	fault_status := int(u64(Kernel_Stop_Reason.Fault)) << 1 | 1
	first, first_text := operation_stop_signature(fault_status, stop_log("ffffffff8001a2b0", "0000000000000000"), nil)
	second, second_text := operation_stop_signature(fault_status, stop_log("ffffffff8003c000", "0000000000000002"), nil)
	testing.expect_value(t, first, second)
	testing.expect(t, first_text != second_text, "the text keeps the values of each run")
	testing.expect_value(t, first, "stop Fault: a kernel address, with no debug object: kernel: exception in the kernel: page fault vector # error # at # address #: a read of a page that is not present")
	invariant, _ := operation_stop_signature(int(u64(Kernel_Stop_Reason.Invariant_Broken)) << 1 | 1, stop_log("ffffffff8001a2b0", "0000000000000000"), nil)
	testing.expect(t, invariant != first, "another reason gives the same signature")
	unknown, _ := operation_stop_signature(0, stop_log("ffffffff8001a2b0", "0000000000000000"), nil)
	testing.expect(t, unknown != first, "a status that names no reason gives the signature of a reason")
	other, _ := operation_stop_signature(fault_status, "kernel: the frames do not add up: free bits 3, free frames 4\n", nil)
	testing.expect_value(t, other, "stop Fault: no address: kernel: the frames do not add up: free bits #, free frames #")
	empty, _ := operation_stop_signature(fault_status, "[root] root: started\n", nil)
	testing.expect_value(t, empty, "stop Fault: no line of the kernel")
}

// The address of a report: none, too short, a byte that is no digit, an
// address below the kernel, and a kernel address with no debug object.
@(test)
the_procedure_of_a_report_names_no_number :: proc(t: ^testing.T) {
	testing.expect_value(t, operation_report_procedure("kernel: the lock order is broken", nil), "no address")
	testing.expect_value(t, operation_report_procedure("kernel: x at ffff8000", nil), "no address")
	testing.expect_value(t, operation_report_procedure("kernel: x at ffffffff8001a2bg", nil), "no address")
	below := fmt.tprintf("kernel: x at %016x", u64(info.KERNEL_BASE) - 1)
	testing.expect_value(t, operation_report_procedure(below, nil), "an address below the kernel")
	base := fmt.tprintf("kernel: x at %016x", u64(info.KERNEL_BASE))
	testing.expect_value(t, operation_report_procedure(base, nil), "a kernel address, with no debug object")
}

// The names of a small debug object of a kernel: one procedure and its
// file.
@(private = "file")
KERNEL_OBJECT_STRINGS :: "kernel::page_fault_handlesrc/kernel/program.odin"
@(private = "file")
KERNEL_OBJECT_PROCEDURE :: "kernel::page_fault_handle"
@(private = "file")
KERNEL_OBJECT_PROCEDURE_START :: 0x1000
@(private = "file")
KERNEL_OBJECT_PROCEDURE_SIZE :: 0x100

// A debug object of one procedure of the kernel, in the form that the build
// writes, which debug_object.check accepts.
@(private = "file")
kernel_object_of_one_procedure :: proc() -> []u8 {
	procedures := make([]debug_object.Procedure, 1, context.temp_allocator)
	procedures[0] = {start = KERNEL_OBJECT_PROCEDURE_START, size = KERNEL_OBJECT_PROCEDURE_SIZE, name_offset = 0, name_count = len(KERNEL_OBJECT_PROCEDURE), package_count = len("kernel")}
	files := make([]debug_object.File, 2, context.temp_allocator)
	files[1] = {path_offset = len(KERNEL_OBJECT_PROCEDURE), path_count = len(KERNEL_OBJECT_STRINGS) - len(KERNEL_OBJECT_PROCEDURE)}
	lines := make([]debug_object.Line, 2, context.temp_allocator)
	lines[0] = {offset = KERNEL_OBJECT_PROCEDURE_START, place = debug_object.row_place(1, 10)}
	lines[1] = {offset = KERNEL_OBJECT_PROCEDURE_START + KERNEL_OBJECT_PROCEDURE_SIZE}
	parts := debug_object.Encode_Parts {
		procedures = procedures,
		files      = files,
		lines      = lines,
		types      = make([]debug_object.Type, 1, context.temp_allocator),
		strings    = transmute([]u8)string(KERNEL_OBJECT_STRINGS),
	}
	object := make([]u8, debug_object.encoded_size(parts), context.temp_allocator)
	if !debug_object.encode(parts, object) {
		return nil
	}
	return object
}

// With a debug object, the procedure that holds the address names it, and
// two addresses in one procedure give one name; an address past each
// procedure names none.
@(test)
the_procedure_of_a_report_comes_from_the_debug_object :: proc(t: ^testing.T) {
	object := kernel_object_of_one_procedure()
	testing.expect(t, object != nil && debug_object.check(object) == .None, "the debug object of the test is refused")
	inside := fmt.tprintf("kernel: x at %016x address 0", u64(info.KERNEL_BASE) + KERNEL_OBJECT_PROCEDURE_START + 0x10)
	other := fmt.tprintf("kernel: x at %016x address 0", u64(info.KERNEL_BASE) + KERNEL_OBJECT_PROCEDURE_START + KERNEL_OBJECT_PROCEDURE_SIZE - 1)
	testing.expect_value(t, operation_report_procedure(inside, object), KERNEL_OBJECT_PROCEDURE)
	testing.expect_value(t, operation_report_procedure(other, object), KERNEL_OBJECT_PROCEDURE)
	past := fmt.tprintf("kernel: x at %016x address 0", u64(info.KERNEL_BASE) + 0x5000)
	testing.expect_value(t, operation_report_procedure(past, object), "a kernel address in no procedure")
	fault_status := int(u64(Kernel_Stop_Reason.Fault)) << 1 | 1
	first, _ := operation_stop_signature(fault_status, fmt.tprintf("%s\n", inside), object)
	second, _ := operation_stop_signature(fault_status, fmt.tprintf("%s\n", other), object)
	testing.expect_value(t, first, second)
}

// The end line of a sequence: at the start of a line only, with its own
// number and not a longer one, and only when the whole line came.
@(test)
the_end_line_of_a_sequence_is_found_by_its_number :: proc(t: ^testing.T) {
	_, none := operation_end_line_through("", 1)
	testing.expect(t, !none)
	_, longer := operation_end_line_through("[operation_fuzzing] operation_fuzzing: sequence 12 ended\r\n", 1)
	testing.expect(t, !longer, "the line of the sequence 12 is the line of the sequence 1")
	_, quoted := operation_end_line_through("[runner] [operation_fuzzing] operation_fuzzing: sequence 1 ended\r\n", 1)
	testing.expect(t, !quoted, "a line that quotes the end line is taken")
	_, partial := operation_end_line_through("[operation_fuzzing] operation_fuzzing: sequence 1 ended\r", 1)
	testing.expect(t, !partial, "a line with no end is taken")
	text := "[operation_fuzzing] operation_fuzzing: sequence 12 ended\r\n[operation_fuzzing] operation_fuzzing: sequence 1 ended\r\nkernel: later\r\n"
	through, found := operation_end_line_through(text, 1)
	testing.expect(t, found)
	testing.expect_value(t, text[through:], "kernel: later\r\n")
}

// A line of the kernel that a sequence caused can come after the count of
// that sequence, while the tool waits for the next one: the lag of one
// sequence. The end line of each sequence comes after each such line, so
// the lines up to the end line of a sequence name only its own faults.
@(test)
a_late_line_of_isolation_belongs_to_the_sequence_that_caused_it :: proc(t: ^testing.T) {
	log := "[operation_fuzzing] operation_fuzzing: sequence 1 ended\r\nkernel: program root stopped: page fault vector 14 at 0000000000401000\r\n[operation_fuzzing] operation_fuzzing: sequence 2 ended\r\n[operation_fuzzing] operation_fuzzing: sequence 3 ended\r\n"
	first, first_found := operation_end_line_through(log, 1)
	testing.expect(t, first_found)
	testing.expect_value(t, operation_isolation_line(log[:first]), "")
	rest := log[first:]
	second, second_found := operation_end_line_through(rest, 2)
	testing.expect(t, second_found)
	testing.expect_value(t, operation_isolation_line(rest[:second]), "kernel: program root stopped: page fault vector 14 at 0000000000401000")
	third, third_found := operation_end_line_through(rest[second:], 3)
	testing.expect(t, third_found)
	testing.expect_value(t, operation_isolation_line(rest[second:][:third]), "")
}

// The whole lines of a log, read in parts: a line that the writer has not
// ended is not given, and comes whole at the next read; a file that does
// not exist gives no line.
@(test)
the_lines_of_a_log_are_read_whole :: proc(t: ^testing.T) {
	folder :: BUILD_FOLDER + "/operation_log_lines_test"
	defer {
		_ = os.remove_all(folder)
	}
	testing.expect(t, reset_folder(folder))
	path := folder + "/log.txt"
	scanned: i64
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "")
	testing.expect_value(t, scanned, 0)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("first\nsec")) == nil)
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "first\n")
	testing.expect_value(t, scanned, 6)
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "")
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("first\nsecond\r\nthi")) == nil)
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "second\r\n")
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("first\nsecond\r\nthird\n")) == nil)
	testing.expect_value(t, operation_log_lines_from(path, scanned), "third\n")
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "third\n")
	testing.expect_value(t, operation_log_new_lines(path, &scanned), "")
}

// A Program_Create whose name in its area is a protected name gets another
// first byte; a longer name, a shorter one, a name past the content of its
// area and a name of another source stay. The change is the same at each
// run, and the sequence still passes check.
@(test)
a_generated_sequence_never_names_a_protected_program :: proc(t: ^testing.T) {
	BEFORE_SERVICE :: "rootrootx"
	CONTENT :: BEFORE_SERVICE + OPERATION_FUZZING_MODULE
	name_place := operation_parameter_place(.Program_Create, "name")
	length_place := operation_parameter_place(.Program_Create, "name_length")
	testing.expect(t, name_place >= 0 && length_place >= 0, "Program_Create has no name or no name_length")
	if name_place < 0 || length_place < 0 {
		return
	}
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	sequence.area_count = 1
	sequence.areas[0] = {pages = 1, content_bytes = len(CONTENT)}
	copy(sequence.content[:], CONTENT)
	create :: proc(sequence: ^operation_sequence.Sequence, name_place, length_place: int, offset, length: u64) {
		item := &sequence.steps[sequence.step_count]
		item.operation = u32(operation.Operation.Program_Create)
		item.arguments[0] = {source = .Budget}
		item.arguments[name_place] = {source = .Area_Address, area = 0, offset = offset}
		item.arguments[length_place] = {source = .Value, value = length}
		sequence.step_count += 1
	}
	create(sequence, name_place, length_place, 0, 4) // "root"
	create(sequence, name_place, length_place, 4, 5) // "rootx"
	create(sequence, name_place, length_place, 4, 3) // "roo"
	create(sequence, name_place, length_place, len(BEFORE_SERVICE), len(OPERATION_FUZZING_MODULE))
	create(sequence, name_place, length_place, len(BEFORE_SERVICE), len(CONTENT)) // past the content
	testing.expect_value(t, operation_protected_names_changed(sequence), 2)
	testing.expect_value(t, string(sequence.content[:len(BEFORE_SERVICE)]), "_ootrootx")
	testing.expect_value(t, sequence.content[len(BEFORE_SERVICE)], u8(OPERATION_PROTECTED_NAME_CHANGE))
	testing.expect_value(t, string(sequence.content[len(BEFORE_SERVICE) + 1:len(CONTENT)]), string(OPERATION_FUZZING_MODULE)[1:])
	testing.expect_value(t, operation_protected_names_changed(sequence), 0)
	bytes, accepted := operation_sequence_encode(sequence)
	defer delete(bytes)
	testing.expect(t, accepted, "check refuses the changed sequence")
}

// A sequence of steps of these operation words, with arguments that are
// plain values of 0.
@(private = "file")
words_sequence :: proc(words: ..u32) -> ^operation_sequence.Sequence {
	steps := make([]operation_sequence.Sequence_Step, len(words))
	defer delete(steps)
	for word, place in words {
		steps[place] = {operation = word}
	}
	sequence := new(operation_sequence.Sequence)
	sequence^ = operation_seed_sequence(steps)
	return sequence
}

FAKE_FIRST :: u32(operation.Operation.Memory_Create)
FAKE_SECOND :: u32(operation.Operation.Handle_Close)
FAKE_NOISE :: u32(operation.Operation.Budget_Read)
FAKE_OTHER_NOISE :: u32(operation.Operation.Handle_State)

// Two runs of one hang give one signature: the operation of the step that
// the runner started, from 1, whatever the other steps; 0 and a step past
// the sequence, which the memory of the machine can hold, name no step.
@(test)
two_runs_of_one_hang_give_one_signature :: proc(t: ^testing.T) {
	first := words_sequence(FAKE_NOISE, FAKE_FIRST)
	defer free(first)
	second := words_sequence(FAKE_OTHER_NOISE, FAKE_FIRST, FAKE_NOISE)
	defer free(second)
	testing.expect_value(t, operation_hang_signature(first, 2), operation_hang_signature(second, 2))
	testing.expect_value(t, operation_hang_signature(first, 2), "hang: Memory_Create")
	testing.expect(t, operation_hang_signature(first, 1) != operation_hang_signature(second, 1), "two operations give one signature")
	testing.expect_value(t, operation_hang_signature(first, 0), "hang: before the first step")
	testing.expect_value(t, operation_hang_signature(first, 3), "hang: at a step past the sequence")
	testing.expect_value(t, operation_hang_signature(first, max(u64)), "hang: at a step past the sequence")
	unknown := words_sequence(u32(max(operation.Operation)) + 1)
	defer free(unknown)
	testing.expect_value(t, operation_hang_signature(unknown, 1), "hang: a word that names no operation")
}

// Two runs of one broken oracle give one signature: the oracle and the
// operation of its step; the values of the text are no part of it.
@(test)
two_runs_of_one_broken_oracle_give_one_signature :: proc(t: ^testing.T) {
	sequence := words_sequence(FAKE_NOISE, FAKE_FIRST)
	defer free(sequence)
	header: operation_sequence.Mailbox_Header
	first := operation_oracle_signature({.Status_Not_Listed, 1, "Memory_Create gave No_Right"}, sequence, &header)
	second := operation_oracle_signature({.Status_Not_Listed, 1, "Memory_Create gave Bad_State"}, sequence, &header)
	testing.expect_value(t, first, second)
	testing.expect_value(t, first, "oracle Status_Not_Listed: Memory_Create")
	testing.expect(t, operation_oracle_signature({.Details_Count, 1, ""}, sequence, &header) != first, "two oracles give one signature")
	testing.expect_value(t, operation_oracle_signature({.Budget_Not_Back, -1, "pages 3"}, sequence, &header), "oracle Budget_Not_Back: the whole sequence")
	testing.expect_value(t, operation_oracle_signature({.Status_Word, 5, ""}, sequence, &header), "oracle Status_Word: the whole sequence")
	header.outcome = u64(operation_sequence.Execution_Outcome.Not_Started)
	testing.expect_value(t, operation_oracle_signature({.Outcome, -1, "status 3"}, sequence, &header), "oracle Outcome: the outcome Not_Started")
	header.outcome = u64(max(operation_sequence.Execution_Outcome)) + 1
	testing.expect_value(t, operation_oracle_signature({.Outcome, -1, ""}, sequence, &header), "oracle Outcome: an outcome word that names no outcome")
}

// The stop of operation_fuzzing or of the root service is found at the
// start of a line only: a program that quotes the line is no fault.
@(test)
a_line_of_isolation_is_found_at_the_start_of_a_line :: proc(t: ^testing.T) {
	testing.expect_value(t, operation_isolation_line(""), "")
	testing.expect_value(t, operation_isolation_line("[log] said kernel: program root stopped: x\n"), "")
	testing.expect_value(t, operation_isolation_line("kernel: program operation_sequence_runner stopped: page fault\n"), "")
	testing.expect_value(t, operation_isolation_line("[log] kernel: program root stopped\nkernel: program root stopped: page fault vector 14 at 00000000004010a0\r\n"), "kernel: program root stopped: page fault vector 14 at 00000000004010a0")
	first := operation_isolation_fault("kernel: program operation_fuzzing stopped: page fault vector 14 at 0000000000401000", "")
	second := operation_isolation_fault("kernel: program operation_fuzzing stopped: page fault vector 14 at 0000000000402000", "")
	testing.expect_value(t, first.signature, second.signature)
	testing.expect_value(t, first.kind, Operation_Fault_Kind.Isolation)
}

// ---------------------------------------------------------------------
// The minimization, on a fake machine.

// The fake machine: a sequence gives a fault when it holds the word
// `second` after the word `first`; with across_sequences, the first word can
// be in an earlier sequence of the same life.
@(private = "file")
Fake_Machine :: struct {
	first, second:       u32,
	across_sequences:    bool,
	first_boot_only:     bool, // The fault comes in the first machine only: a fault that does not come back.
	always:              bool, // Each sequence gives the fault.
	at_drain:            bool, // The fault of a sequence comes after its count: the drain of the life gives it.
	temporary_signature: bool, // The signature is in the temporary memory, as a signature of the real machine is.
	tool_error_at:       int,  // The execution, from 1, that gives an error of the tool; 0: none.
	refused_boots:       int,  // The next boots that do not reach the mailbox.
	first_seen:          bool,
	pending:             bool, // A fault came after the count, and the drain has not given it.
	running:             bool,
	boots:               int,
	executions:          int,
	drains:              int,
}

FAKE_SIGNATURE :: "oracle Status_Not_Listed: the pair of the fake machine"

@(private = "file")
fake_fault :: proc(machine: ^Fake_Machine) -> Operation_Fault {
	signature: string = FAKE_SIGNATURE
	if machine.temporary_signature {
		signature = fmt.tprintf("%s", FAKE_SIGNATURE)
	}
	return {kind = .Oracle, signature = signature, text = fmt.tprintf("the execution %d", machine.executions)}
}

@(private = "file")
fake_start :: proc(data: rawptr) -> bool {
	machine := (^Fake_Machine)(data)
	if machine.refused_boots > 0 {
		machine.refused_boots -= 1
		return false
	}
	machine.running = true
	machine.first_seen = false
	machine.pending = false
	machine.boots += 1
	return true
}

@(private = "file")
fake_execute :: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault {
	machine := (^Fake_Machine)(data)
	machine.executions += 1
	if machine.tool_error_at != 0 && machine.executions == machine.tool_error_at {
		return {kind = .Tool, text = fmt.tprintf("the fake cannot read %d bytes", len(bytes))}
	}
	if machine.always {
		return fake_fault(machine)
	}
	if machine.first_boot_only && machine.boots > 1 {
		return {}
	}
	seen := machine.across_sequences && machine.first_seen
	for item in sequence.steps[:sequence.step_count] {
		if seen && item.operation == machine.second {
			if machine.at_drain {
				machine.pending = true
				return {}
			}
			return fake_fault(machine)
		}
		if item.operation == machine.first {
			seen = true
		}
	}
	machine.first_seen = seen
	return {}
}

@(private = "file")
fake_drain :: proc(data: rawptr) -> Operation_Fault {
	machine := (^Fake_Machine)(data)
	machine.drains += 1
	if machine.pending {
		machine.pending = false
		return fake_fault(machine)
	}
	return {}
}

@(private = "file")
fake_end :: proc(data: rawptr) {
	(^Fake_Machine)(data).running = false
}

@(private = "file")
fake_machine_of :: proc(fake: ^Fake_Machine) -> Operation_Machine {
	return {data = fake, start = fake_start, execute = fake_execute, drain = fake_drain, end = fake_end}
}

@(private = "file")
words_bytes :: proc(words: ..u32) -> []u8 {
	sequence := words_sequence(..words)
	defer free(sequence)
	bytes, accepted := operation_sequence_encode(sequence)
	assert(accepted)
	return bytes
}

// The operation words of the steps of a sequence, or nil for bytes that
// check refuses.
@(private = "file")
words_of :: proc(bytes: []u8) -> []u32 {
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	if operation_sequence.check(bytes, sequence).problem != .None {
		return nil
	}
	words := make([]u32, sequence.step_count, context.temp_allocator)
	for item, place in sequence.steps[:sequence.step_count] {
		words[place] = item.operation
	}
	return words
}

// A removed step: a later step that named its result names the plain value
// 0, a later result names its new place, an earlier one stays, and the new
// first step joins no earlier kernel entry. Removing every step leaves no
// step, and each result passes check.
@(test)
the_steps_removed_keep_the_results_that_stay :: proc(t: ^testing.T) {
	// The step 2 joins the kernel entry of the step 1, and names the result
	// of the step 0, before that entry.
	from := words_sequence(FAKE_NOISE, FAKE_FIRST, FAKE_NOISE, FAKE_SECOND, FAKE_NOISE)
	defer free(from)
	from.steps[2].flags = {.Same_Entry}
	from.steps[2].arguments[0] = {source = .Result, step = 0}
	from.steps[3].arguments[0] = {source = .Result, step = 2, place = 1, offset = 8}
	from.steps[4].arguments[0] = {source = .Result, step = 1}
	from_bytes, from_accepted := operation_sequence_encode(from)
	defer delete(from_bytes)
	testing.expect(t, from_accepted, "check refuses the sequence before the removal")
	into := new(operation_sequence.Sequence)
	defer free(into)
	operation_steps_removed(from, 0, 2, into)
	testing.expect_value(t, into.step_count, 3)
	testing.expect_value(t, into.steps[0].operation, FAKE_NOISE)
	testing.expect_value(t, into.steps[0].arguments[0], operation_sequence.Argument{source = .Value})
	testing.expect(t, .Same_Entry not_in into.steps[0].flags, "the first step joins a kernel entry before it")
	testing.expect_value(t, into.steps[1].arguments[0], operation_sequence.Argument{source = .Result, step = 0, place = 1, offset = 8})
	testing.expect_value(t, into.steps[2].arguments[0], operation_sequence.Argument{source = .Value})
	testing.expect_value(t, into.steps[3], operation_sequence.Sequence_Step{})
	removed_bytes, accepted := operation_sequence_encode(into)
	delete(removed_bytes)
	testing.expect(t, accepted, "check refuses the sequence with two steps removed")
	operation_steps_removed(from, 4, 1, into)
	testing.expect_value(t, into.steps[3].arguments[0], operation_sequence.Argument{source = .Result, step = 2, place = 1, offset = 8})
	operation_steps_removed(from, 0, from.step_count, into)
	testing.expect_value(t, into.step_count, 0)
	empty, empty_accepted := operation_sequence_encode(into)
	defer delete(empty)
	testing.expect(t, empty_accepted, "check refuses a sequence with no step")
}

// The step after a removed range joins no earlier kernel entry, and a step
// after it keeps its flag; a range at the end leaves no step after it.
@(test)
the_step_after_a_removed_range_starts_a_kernel_entry :: proc(t: ^testing.T) {
	from := words_sequence(FAKE_NOISE, FAKE_FIRST, FAKE_NOISE, FAKE_SECOND)
	defer free(from)
	from.steps[2].flags = {.Same_Entry}
	from.steps[3].flags = {.Same_Entry}
	into := new(operation_sequence.Sequence)
	defer free(into)
	operation_steps_removed(from, 1, 1, into)
	testing.expect_value(t, into.step_count, 3)
	testing.expect(t, .Same_Entry not_in into.steps[1].flags, "the step after the range joins the entry before the range")
	testing.expect(t, .Same_Entry in into.steps[2].flags, "a later step lost its kernel entry")
	bytes, accepted := operation_sequence_encode(into)
	delete(bytes)
	testing.expect(t, accepted)
	operation_steps_removed(from, 3, 1, into)
	testing.expect_value(t, into.step_count, 3)
	testing.expect(t, .Same_Entry in into.steps[2].flags, "a step before a range at the end lost its kernel entry")
}

// The steps of a sequence that gives the fault: the result is the pair
// alone, in its order, and the result still gives the fault.
@(test)
the_minimization_keeps_the_smallest_sequence_that_holds_the_pair :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	life := [1][]u8{words_bytes(FAKE_NOISE, FAKE_FIRST, FAKE_OTHER_NOISE, FAKE_NOISE, FAKE_SECOND, FAKE_OTHER_NOISE)}
	defer delete(life[0])
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE)
	defer operation_life_free(minimized.life)
	testing.expect(t, minimized.reproduced)
	testing.expect_value(t, minimized.end, Operation_Minimize_End.Done)
	testing.expect_value(t, len(minimized.life), 1)
	if len(minimized.life) == 1 {
		words := words_of(minimized.life[0])
		testing.expectf(t, slice.equal(words, []u32{FAKE_FIRST, FAKE_SECOND}), "the minimized steps are %v", words)
	}
	testing.expect_value(t, minimized.boots, fake.boots)
	testing.expect(t, !fake.running, "a machine of the minimization was not ended")
	again := operation_life_run(&machine, minimized.life)
	testing.expect_value(t, again.faulting, 0)
	testing.expect_value(t, again.fault.signature, FAKE_SIGNATURE)
}

// A fault that needs an earlier sequence of its life: the sequences that it
// does not need go, the one that it needs stays whole, and the steps of the
// last sequence become the one step of the pair.
@(test)
the_minimization_removes_the_sequences_that_the_fault_does_not_need :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, across_sequences = true}
	machine := fake_machine_of(&fake)
	life := [?][]u8{words_bytes(FAKE_NOISE), words_bytes(FAKE_OTHER_NOISE), words_bytes(FAKE_FIRST), words_bytes(FAKE_NOISE, FAKE_NOISE), words_bytes(FAKE_NOISE), words_bytes(FAKE_OTHER_NOISE, FAKE_SECOND, FAKE_NOISE)}
	defer {
		for bytes in life {
			delete(bytes)
		}
	}
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE)
	defer operation_life_free(minimized.life)
	testing.expect(t, minimized.reproduced)
	testing.expect_value(t, len(minimized.life), 2)
	if len(minimized.life) == 2 {
		testing.expect(t, slice.equal(minimized.life[0], life[2]), "the sequence that the fault needs changed")
		words := words_of(minimized.life[1])
		testing.expectf(t, slice.equal(words, []u32{FAKE_SECOND}), "the minimized steps are %v", words)
	}
}

// A fault that does not come back on a new machine keeps its life whole,
// and the minimization says so.
@(test)
a_fault_that_does_not_come_back_keeps_its_life_whole :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, first_boot_only = true, boots = 1}
	machine := fake_machine_of(&fake)
	life := [?][]u8{words_bytes(FAKE_NOISE), words_bytes(FAKE_FIRST, FAKE_NOISE, FAKE_SECOND)}
	defer {
		for bytes in life {
			delete(bytes)
		}
	}
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE)
	defer operation_life_free(minimized.life)
	testing.expect(t, !minimized.reproduced, "a fault that does not come back is reproduced")
	testing.expect_value(t, minimized.boots, 2)
	testing.expect_value(t, len(minimized.life), len(life))
	for bytes, place in minimized.life {
		testing.expect(t, slice.equal(bytes, life[place]))
	}
}

// Two boots in a row with no mailbox during a minimization stop it.
@(test)
a_minimization_stops_when_no_machine_boots :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, refused_boots = OPERATION_BOOT_TRIES}
	machine := fake_machine_of(&fake)
	life := [1][]u8{words_bytes(FAKE_FIRST, FAKE_SECOND)}
	defer delete(life[0])
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE)
	defer operation_life_free(minimized.life)
	testing.expect(t, !minimized.reproduced)
	testing.expect_value(t, minimized.end, Operation_Minimize_End.No_Boot)
	testing.expect_value(t, minimized.boots, OPERATION_BOOT_TRIES)
}

// A fake that always gives the fault: the minimization stops at its bound
// of boots exactly, and no try runs past it.
@(test)
a_minimization_stops_at_its_bound_of_boots :: proc(t: ^testing.T) {
	BOOTS_MOST :: 2
	fake := Fake_Machine{always = true}
	machine := fake_machine_of(&fake)
	life := [1][]u8{words_bytes(FAKE_NOISE, FAKE_NOISE, FAKE_NOISE, FAKE_NOISE)}
	defer delete(life[0])
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE, BOOTS_MOST)
	defer operation_life_free(minimized.life)
	testing.expect(t, minimized.reproduced)
	testing.expect_value(t, minimized.end, Operation_Minimize_End.Bound)
	testing.expect_value(t, minimized.boots, BOOTS_MOST)
	testing.expect_value(t, fake.boots, BOOTS_MOST)
	// The second try removed half of the steps; no later try ran.
	testing.expect_value(t, len(words_of(minimized.life[0])), 2)
}

// A try whose fault comes at an earlier sequence with the same signature
// does not hold, and a try with another signature does not hold.
@(test)
a_try_holds_only_for_its_signature_at_its_last_sequence :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	earlier := [?][]u8{words_bytes(FAKE_FIRST, FAKE_SECOND), words_bytes(FAKE_NOISE)}
	defer {
		for bytes in earlier {
			delete(bytes)
		}
	}
	at_earlier := operation_fault_minimize(&machine, earlier[:], FAKE_SIGNATURE)
	defer operation_life_free(at_earlier.life)
	testing.expect(t, !at_earlier.reproduced, "a fault at an earlier sequence holds")
	testing.expect_value(t, at_earlier.boots, 2)
	other := [1][]u8{words_bytes(FAKE_FIRST, FAKE_SECOND)}
	defer delete(other[0])
	with_other := operation_fault_minimize(&machine, other[:], "oracle Status_Not_Listed: another fault")
	defer operation_life_free(with_other.life)
	testing.expect(t, !with_other.reproduced, "a fault with another signature holds")
	testing.expect_value(t, with_other.boots, 1)
}

// A life with bytes that check refuses ends with no fault and no execution
// of those bytes.
@(test)
a_life_with_refused_bytes_ends_with_no_fault :: proc(t: ^testing.T) {
	fake := Fake_Machine{always = true}
	machine := fake_machine_of(&fake)
	refused := []u8{1, 2, 3}
	life := [1][]u8{refused}
	outcome := operation_life_run(&machine, life[:])
	testing.expect(t, outcome.booted)
	testing.expect_value(t, outcome.faulting, -1)
	testing.expect_value(t, outcome.fault.kind, Operation_Fault_Kind.None)
	testing.expect_value(t, fake.executions, 0)
	testing.expect(t, !fake.running, "the machine of the life was not ended")
}

// A fault that comes after the count of the last sequence of a life, which
// the drain gives: the life holds it at its last sequence, and the
// minimization keeps the pair.
@(test)
a_fault_after_the_last_count_belongs_to_the_last_sequence :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, at_drain = true}
	machine := fake_machine_of(&fake)
	life := [?][]u8{words_bytes(FAKE_NOISE), words_bytes(FAKE_NOISE, FAKE_FIRST, FAKE_SECOND)}
	defer {
		for bytes in life {
			delete(bytes)
		}
	}
	outcome := operation_life_run(&machine, life[:])
	testing.expect_value(t, outcome.faulting, 1)
	testing.expect_value(t, outcome.fault.signature, FAKE_SIGNATURE)
	minimized := operation_fault_minimize(&machine, life[:], FAKE_SIGNATURE)
	defer operation_life_free(minimized.life)
	testing.expect(t, minimized.reproduced)
	testing.expect_value(t, len(minimized.life), 1)
	if len(minimized.life) == 1 {
		words := words_of(minimized.life[0])
		testing.expectf(t, slice.equal(words, []u32{FAKE_FIRST, FAKE_SECOND}), "the minimized steps are %v", words)
	}
}

// ---------------------------------------------------------------------
// The loop, on a fake machine.

@(private = "file")
fake_generate_noise :: proc(random: ^Fuzz_Random, sequence: ^operation_sequence.Sequence) {
	steps: [3]operation_sequence.Sequence_Step
	for &item in steps {
		item.operation = fuzz_random_below(random, 2) == 0 ? FAKE_NOISE : FAKE_OTHER_NOISE
	}
	sequence^ = operation_seed_sequence(steps[:])
}

@(private = "file")
fake_generate_pairs :: proc(random: ^Fuzz_Random, sequence: ^operation_sequence.Sequence) {
	words := [3]u32{FAKE_NOISE, FAKE_FIRST, FAKE_SECOND}
	steps: [4]operation_sequence.Sequence_Step
	for &item in steps {
		item.operation = words[fuzz_random_below(random, len(words))]
	}
	sequence^ = operation_seed_sequence(steps[:])
}

FAKE_SEED :: 12345

// A run whose sequences never give a fault keeps nothing, runs its whole
// count, and boots a machine for each life of at most four sequences.
@(test)
a_run_with_no_fault_keeps_nothing :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_noise, FAKE_SEED, {executions = 50, life_sequences = 4, findings_most = OPERATION_FINDINGS_MOST})
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, run.executions, 50)
	testing.expect_value(t, run.faults, 0)
	testing.expect_value(t, len(run.kept), 0)
	testing.expect_value(t, run.lives, 13)
	testing.expect_value(t, fake.boots, 13)
	testing.expect(t, !fake.running, "the last machine was not ended")
}

// A run whose sequences often give one fault keeps it one time, minimized
// to the pair, and counts the others.
@(test)
a_run_keeps_each_signature_one_time :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_pairs, FAKE_SEED, {executions = 200, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST})
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, run.executions, 200)
	testing.expect_value(t, len(run.kept), 1)
	testing.expectf(t, run.faults > 1, "the run gave %d faults", run.faults)
	if len(run.kept) == 1 {
		kept := run.kept[0]
		testing.expect_value(t, kept.fault.signature, FAKE_SIGNATURE)
		testing.expect(t, kept.minimized.reproduced)
		testing.expect_value(t, len(kept.minimized.life), 1)
		if len(kept.minimized.life) == 1 {
			words := words_of(kept.minimized.life[0])
			testing.expectf(t, slice.equal(words, []u32{FAKE_FIRST, FAKE_SECOND}), "the minimized steps are %v", words)
		}
		// The life of the run ends at the sequence of the fault.
		testing.expect(t, len(kept.life) >= 1 && kept.execution >= u64(len(kept.life)))
	}
	testing.expect(t, !fake.running, "the last machine was not ended")
}

// One seed gives one run: the same executions, faults and kept lives.
@(test)
a_run_is_the_same_for_one_seed :: proc(t: ^testing.T) {
	bounds := Operation_Run_Bounds{executions = 120, life_sequences = 8, findings_most = OPERATION_FINDINGS_MOST}
	first_fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	first_machine := fake_machine_of(&first_fake)
	first, first_ok := operation_fuzzing_loop(&first_machine, fake_generate_pairs, FAKE_SEED, bounds)
	defer operation_run_free(&first)
	second_fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	second_machine := fake_machine_of(&second_fake)
	second, second_ok := operation_fuzzing_loop(&second_machine, fake_generate_pairs, FAKE_SEED, bounds)
	defer operation_run_free(&second)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.faults, second.faults)
	testing.expect_value(t, first.lives, second.lives)
	testing.expect_value(t, len(first.kept), len(second.kept))
	for kept, index in first.kept {
		if index >= len(second.kept) {
			break
		}
		other := second.kept[index]
		testing.expect_value(t, kept.execution, other.execution)
		testing.expect_value(t, len(kept.life), len(other.life))
		testing.expect_value(t, len(kept.minimized.life), len(other.minimized.life))
		for bytes, place in kept.minimized.life {
			if place < len(other.minimized.life) {
				testing.expect(t, slice.equal(bytes, other.minimized.life[place]))
			}
		}
	}
}

// Two boots in a row with no mailbox end the run as an error, with no
// execution; one such boot does not.
@(test)
a_run_ends_when_two_boots_in_a_row_fail :: proc(t: ^testing.T) {
	bounds := Operation_Run_Bounds{executions = 10, life_sequences = 4, findings_most = OPERATION_FINDINGS_MOST}
	failing := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, refused_boots = OPERATION_BOOT_TRIES}
	failing_machine := fake_machine_of(&failing)
	failed, failed_ok := operation_fuzzing_loop(&failing_machine, fake_generate_noise, FAKE_SEED, bounds)
	defer operation_run_free(&failed)
	testing.expect(t, !failed_ok, "two failed boots in a row are taken")
	testing.expect_value(t, failed.executions, 0)
	once := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, refused_boots = OPERATION_BOOT_TRIES - 1}
	once_machine := fake_machine_of(&once)
	passed, passed_ok := operation_fuzzing_loop(&once_machine, fake_generate_noise, FAKE_SEED, bounds)
	defer operation_run_free(&passed)
	testing.expect(t, passed_ok)
	testing.expect_value(t, passed.executions, 10)
}

// The bound of the findings ends a run: with a bound of one, the first kept
// fault ends it.
@(test)
a_run_ends_at_its_bound_of_findings :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_pairs, FAKE_SEED, {executions = 200, life_sequences = 16, findings_most = 1})
	defer operation_run_free(&run)
	testing.expect(t, ok && run.ended_by_findings)
	testing.expect_value(t, len(run.kept), 1)
	testing.expect_value(t, run.faults, 1)
	testing.expect(t, run.executions < 200)
	testing.expect(t, !fake.running, "the last machine was not ended")
}

// A fault that comes after the count of the last sequence of a life is not
// lost: the loop drains each life that ends with no fault, and keeps the
// fault with the life.
@(test)
a_run_keeps_a_fault_after_the_last_count_of_a_life :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, at_drain = true}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_pairs, FAKE_SEED, {executions = 100, life_sequences = 1, findings_most = OPERATION_FINDINGS_MOST})
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, len(run.kept), 1)
	testing.expect(t, fake.drains > 0, "no life was drained")
	if len(run.kept) == 1 {
		testing.expect_value(t, len(run.kept[0].life), 1)
		words := words_of(run.kept[0].minimized.life[0])
		testing.expectf(t, slice.equal(words, []u32{FAKE_FIRST, FAKE_SECOND}), "the minimized steps are %v", words)
	}
}

// The count of executions ends the last life of a run before its bound of
// sequences: the loop drains it too.
@(test)
a_run_drains_its_last_life :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_noise, FAKE_SEED, {executions = 1, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST})
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, fake.drains, 1)
	testing.expect_value(t, run.executions, 1)
	testing.expect_value(t, len(run.kept), 0)
}

// An error of the tool ends the run with an error, and is never a finding.
@(test)
an_error_of_the_tool_ends_the_run_and_is_no_finding :: proc(t: ^testing.T) {
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, tool_error_at = 3}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_noise, FAKE_SEED, {executions = 50, life_sequences = 4, findings_most = OPERATION_FINDINGS_MOST})
	defer operation_run_free(&run)
	testing.expect(t, !ok, "an error of the tool is taken")
	testing.expect_value(t, run.executions, 3)
	testing.expect_value(t, run.faults, 0)
	testing.expect_value(t, len(run.kept), 0)
	testing.expect(t, !fake.running, "the machine was not ended")
}

// What the keeper saw: the signature of the kept fault, after the loop
// freed the temporary memory and the keeper wrote over it.
@(private = "file")
@(thread_local)
keeper_saw_the_signature: bool

@(private = "file")
keeper_over_temporary_memory :: proc(kept: ^Operation_Kept_Fault, seed: u64) -> bool {
	junk := make([]u8, 1 << 16, context.temp_allocator)
	for &value in junk {
		value = 'x'
	}
	keeper_saw_the_signature = kept.fault.signature == FAKE_SIGNATURE && seed == FAKE_SEED
	return true
}

@(private = "file")
keeper_that_cannot_write :: proc(kept: ^Operation_Kept_Fault, seed: u64) -> bool {
	_, _ = kept, seed
	return false
}

// The signature of a real machine is in the temporary memory, which the
// loop frees after each execution: the kept fault holds its own copy. A
// keeper that cannot write ends the run as an error of the tool.
@(test)
a_kept_fault_outlives_the_temporary_memory :: proc(t: ^testing.T) {
	keeper_saw_the_signature = false
	fake := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND, temporary_signature = true}
	machine := fake_machine_of(&fake)
	run, ok := operation_fuzzing_loop(&machine, fake_generate_pairs, FAKE_SEED, {executions = 200, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, keeper_over_temporary_memory)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect(t, keeper_saw_the_signature, "the keeper saw another signature")
	testing.expect_value(t, len(run.kept), 1)
	if len(run.kept) == 1 {
		testing.expect_value(t, run.kept[0].fault.signature, FAKE_SIGNATURE)
	}
	failing := Fake_Machine{first = FAKE_FIRST, second = FAKE_SECOND}
	failing_machine := fake_machine_of(&failing)
	failed, failed_ok := operation_fuzzing_loop(&failing_machine, fake_generate_pairs, FAKE_SEED, {executions = 200, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, keeper_that_cannot_write)
	defer operation_run_free(&failed)
	testing.expect(t, !failed_ok, "a keeper that cannot write is taken")
	testing.expect_value(t, len(failed.kept), 1)
}

// The generator of the run builds sequences that check accepts, and the
// same random state builds the same sequence.
@(test)
the_generator_of_the_run_is_a_function_of_its_seed :: proc(t: ^testing.T) {
	testing.expect(t, fuzz_operation_sequence_start())
	first_sequence := new(operation_sequence.Sequence)
	defer free(first_sequence)
	second_sequence := new(operation_sequence.Sequence)
	defer free(second_sequence)
	first_random := Fuzz_Random{state = FAKE_SEED}
	second_random := Fuzz_Random{state = FAKE_SEED}
	for _ in 0 ..< 64 {
		operation_sequence_generate_random(&first_random, first_sequence)
		operation_sequence_generate_random(&second_random, second_sequence)
		first_bytes, first_accepted := operation_sequence_encode(first_sequence)
		second_bytes, second_accepted := operation_sequence_encode(second_sequence)
		testing.expect(t, first_accepted && second_accepted, "check refuses a sequence of the generator")
		testing.expect(t, slice.equal(first_bytes, second_bytes), "one random state gives two sequences")
		delete(first_bytes)
		delete(second_bytes)
	}
}
