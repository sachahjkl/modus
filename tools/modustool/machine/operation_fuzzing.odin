package machine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import info "modus:contract/boot_info"
import debug_object "modus:contract/debug_object"
import "modus:contract/enum_word"
import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"
import "modustool:build"
import "modustool:fuzz"

// The loop of the kernel fuzzing (src/md/infrastructure/kernel_fuzzing.md,
// "The loop and the speed", "The engine guided by the counters";
// docs/TOOLS.md, "The fuzzing of the kernel operations"): generated
// operation sequences on machines of the counted kernel, one machine at a
// time, a new machine after each fault, each fault kept one time for its
// signature and minimized by machine lives and by steps. With the counters
// of the kernel, the engine keeps each choice sequence that reached a new
// feature in two runs, and mutates the kept ones; with no counters, each
// sequence is a new draw.
//
// The loop and the minimizer reach a machine through Operation_Machine
// only, so a host test runs them on a fake machine.

// The start of the boot line of the counted kernel, which the machine test
// refuses in each other machine (machine.odin).
OPERATION_COUNTERS_LINE_START :: fuzz.KERNEL_EDGE_COUNTERS_LINE_START

// One draw in this count is a new draw of choices, not a mutation of a
// kept input.
OPERATION_NEW_DRAW_ONE_IN :: 4

// The files of a run, which git ignores: the repository never holds a
// finding of a run. The findings of a run are in a folder of its seed.
OPERATION_FUZZING_FOLDER :: fuzz.FUZZING_BUILD_FOLDER + "/operations"
OPERATION_FUZZING_OUTPUT :: OPERATION_FUZZING_FOLDER + "/machine_log.txt"
OPERATION_FUZZING_MEMORY_FILE :: OPERATION_FUZZING_FOLDER + "/machine_memory.raw"

// The sequences of one machine life: the state that the kernel keeps
// between two sequences stays short, and a finding that needs earlier
// sequences has a short prefix to search.
OPERATION_MACHINE_SEQUENCES_MOST :: 1024
// The findings that end a run: each one costs up to
// OPERATION_MINIMIZE_BOOTS_MOST boots, and a kernel with that many faults
// is fixed first.
OPERATION_FINDINGS_MOST :: 8
// The boots that the minimization of one finding makes, at most: each try
// is a new machine, and a try can boot twice.
OPERATION_MINIMIZE_BOOTS_MOST :: 256
// The boots in a row with no line of the mailbox that end a run: then the
// build is wrong, and no sequence is the cause.
OPERATION_BOOT_TRIES :: 2
// The hexadecimal digits of the hash of a signature that name the folder
// of its finding: enough that two signatures of one run never share them.
OPERATION_FINDING_NAME_DIGITS :: 16
// The digits of a value that the kernel writes in hexadecimal, with no
// prefix (src/kernel/serial.odin, the type Hex).
OPERATION_KERNEL_HEX_DIGITS :: 16
// How long the tool reads the log after the last sequence of a life, for a
// line of a fault that a queued record of the log brings after the count.
// The kernel writes the queued records to the serial port at each tick of
// the first processor, many times in this bound; no line is a state that
// the tool can wait for, so the bound is the end of the look, and a line
// past it is lost with the life.
OPERATION_LOG_DRAIN_BOUND :: 1 * time.Second

// ---------------------------------------------------------------------
// The arguments.

Operation_Fuzzing_Arguments :: struct {
	executions: u64,
	seed:       u64,
	seed_given: bool,
}

// operation_count_read reads a count in decimal digits only: no sign, no
// `_`, no prefix, and no value past the largest u64. A count of 0 is a
// number here; the caller refuses it.
operation_count_read :: proc(text: string) -> (value: u64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return 0, false
		}
		digit := u64(character - '0')
		if value > (max(u64) - digit) / 10 {
			return 0, false
		}
		value = value * 10 + digit
	}
	return value, true
}

// operation_fuzzing_arguments_read reads the arguments of `fuzz
// operations`: a count of executions, then a seed. A run always names its
// count: no count, a count of 0, a negative count and a text that is no
// count are refused, because a forgotten argument must never start a run
// with no end, and each machine life boots a machine.
operation_fuzzing_arguments_read :: proc(args: []string) -> (arguments: Operation_Fuzzing_Arguments, problem: string) {
	if len(args) == 0 {
		return {}, "fuzz operations needs its count of executions, as `fuzz operations 1000`: a run with no count would have no end"
	}
	if len(args) > 2 {
		return {}, fmt.tprintf("fuzz operations takes a count of executions and a seed, and not %d arguments", len(args))
	}
	count, is_count := operation_count_read(args[0])
	if !is_count || count == 0 {
		return {}, fmt.tprintf("the count of executions is a number of 1 or more, not \"%s\"", args[0])
	}
	arguments.executions = count
	if len(args) == 2 {
		seed, is_seed := operation_count_read(args[1])
		if !is_seed {
			return {}, fmt.tprintf("the seed is a number of 0 or more, not \"%s\"", args[1])
		}
		arguments.seed = seed
		arguments.seed_given = true
	}
	return arguments, ""
}

// ---------------------------------------------------------------------
// The faults of the kernel and their signatures.

Operation_Fault_Kind :: enum u8 {
	None,      // The sequence ran, and each oracle held.
	Stop,      // The machine stopped: QEMU ended.
	Hang,      // The runner did not end its sequence within the hang bound, or the end line of the sequence did not come.
	Isolation, // operation_fuzzing or the root service stopped: a sequence reached a process whose handle it did not hold.
	Mailbox,   // The mailbox counts what the tool did not write: a sequence changed the memory of operation_fuzzing.
	Oracle,    // An oracle of the results broke.
	Tool,      // An error of the tool, never a fault of the kernel: the run ends with an error and keeps no finding.
}

Operation_Fault :: struct {
	kind:      Operation_Fault_Kind,
	signature: string, // Two faults with one signature are one fuzz finding.
	text:      string, // What the tool saw, with its values.
	log:       string, // The log of the machine at the fault, or "".
}

// The reasons of a stop of the kernel, as the kernel writes them to the
// debug exit port (src/kernel/serial.odin, Machine_Stop_Reason). QEMU then
// ends with the status of twice the code, plus one.
Kernel_Stop_Reason :: enum u64 {
	Normal_End       = 0,
	Start_Failed     = 1,
	Fault            = 2,
	Invariant_Broken = 3,
}

// operation_stop_reason_of_status is the border of the exit status of
// QEMU: an even status, a negative one, and a code that names no reason
// are refused.
operation_stop_reason_of_status :: proc(status: int) -> (reason: Kernel_Stop_Reason, known: bool) {
	if status < 0 || status & 1 == 0 {
		return {}, false
	}
	return enum_word.member_of_word(Kernel_Stop_Reason, u64(status >> 1))
}

@(private = "file")
operation_is_word_byte :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

@(private = "file")
operation_is_hexadecimal_byte :: proc(character: u8) -> bool {
	switch character {
	case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		return true
	}
	return false
}

// operation_numbers_removed writes as `#` each word that holds a decimal
// digit, and each word of the 16 hexadecimal digits of a value of the
// kernel, which can hold letters only (`ffffffffffffffff`): an address, a
// count, a slot or a hash changes from one run of a fault to the next, and
// the words around them do not.
operation_numbers_removed :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	place := 0
	for place < len(text) {
		if !operation_is_word_byte(text[place]) {
			strings.write_byte(&builder, text[place])
			place += 1
			continue
		}
		end := place
		has_digit := false
		all_hexadecimal := true
		for end < len(text) && operation_is_word_byte(text[end]) {
			has_digit ||= text[end] >= '0' && text[end] <= '9'
			all_hexadecimal &&= operation_is_hexadecimal_byte(text[end])
			end += 1
		}
		is_number := has_digit || (all_hexadecimal && end - place == OPERATION_KERNEL_HEX_DIGITS)
		strings.write_string(&builder, is_number ? "#" : text[place:end])
		place = end
	}
	return strings.to_string(builder)
}

// The line that the kernel writes before a report when the line before it
// is cut: it is no report.
OPERATION_REPORT_CUT_LINE :: "kernel: the line above is cut"

// operation_report_line gives the last line of the log that the kernel
// wrote for itself, which is the report of a stop: the kernel writes no
// line after it. A line of a process starts with its name in brackets.
operation_report_line :: proc(log: string) -> string {
	rest := log
	report := ""
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_right(line, "\r")
		if strings.has_prefix(text, COMMON_FAILURE_LINE_START) && !strings.has_prefix(text, OPERATION_REPORT_CUT_LINE) {
			report = text
		}
	}
	return report
}

// The text before the address of the instruction in the report of an
// exception, which the kernel writes in hexadecimal.
OPERATION_REPORT_ADDRESS_MARK :: " at "

// operation_report_procedure names the procedure of the kernel at the
// address of a report, from the debug object of the kernel of the volume.
// The texts hold no number, because the signature holds them.
operation_report_procedure :: proc(report: string, kernel_object: []u8) -> string {
	at := strings.index(report, OPERATION_REPORT_ADDRESS_MARK)
	if at < 0 {
		return "no address"
	}
	digits := report[at + len(OPERATION_REPORT_ADDRESS_MARK):]
	if len(digits) < OPERATION_KERNEL_HEX_DIGITS {
		return "no address"
	}
	address: u64
	for character in transmute([]u8)digits[:OPERATION_KERNEL_HEX_DIGITS] {
		value: u64
		switch character {
		case '0' ..= '9':
			value = u64(character - '0')
		case 'a' ..= 'f':
			value = u64(character - 'a' + 10)
		case 'A' ..= 'F':
			value = u64(character - 'A' + 10)
		case:
			return "no address"
		}
		address = address << 4 | value
	}
	if address < u64(info.KERNEL_BASE) {
		return "an address below the kernel"
	}
	if kernel_object == nil {
		return "a kernel address, with no debug object"
	}
	place := debug_object.place_of(kernel_object, address - u64(info.KERNEL_BASE))
	if place.procedure == "" {
		return "a kernel address in no procedure"
	}
	return place.procedure
}

// operation_stop_signature gives the signature of a stop: the reason from
// the exit status, the procedure of the address of the report, and the
// report with its numbers removed.
operation_stop_signature :: proc(status: int, log: string, kernel_object: []u8) -> (signature, text: string) {
	reason, known := operation_stop_reason_of_status(status)
	head := fmt.tprintf("stop %v", reason)
	if !known {
		head = fmt.tprintf("stop with the status %d of QEMU, which names no reason of the kernel", status)
	}
	report := operation_report_line(log)
	if report == "" {
		return fmt.tprintf("%s: no line of the kernel", head), fmt.tprintf("QEMU ended with the status %d, and the log has no line of the kernel", status)
	}
	signature = fmt.tprintf("%s: %s: %s", head, operation_report_procedure(report, kernel_object), operation_numbers_removed(report))
	return signature, fmt.tprintf("QEMU ended with the status %d: %s", status, report)
}

// operation_word_name names the operation of a step word.
operation_word_name :: proc(word: u32) -> string {
	chosen, known := enum_word.member_of_word(operation.Operation, u64(word))
	if !known || chosen == .None {
		return "a word that names no operation"
	}
	return operation.OPERATIONS[chosen].name
}

// operation_hang_signature names the operation of the step that the runner
// started: step_started counts from 1, and comes from the memory of the
// machine, so it is checked against the sequence first.
operation_hang_signature :: proc(sequence: ^operation_sequence.Sequence, step_started: u64) -> string {
	if step_started == 0 {
		return "hang: before the first step"
	}
	if step_started > u64(sequence.step_count) {
		return "hang: at a step past the sequence"
	}
	return fmt.tprintf("hang: %s", operation_word_name(sequence.steps[step_started - 1].operation))
}

// The signature of a sequence whose count came and whose end line did not.
OPERATION_END_LINE_HANG_SIGNATURE :: "hang: the end line of the sequence did not come"

// operation_oracle_signature names the oracle of a finding and the
// operation of its step, or the outcome for an oracle of the whole
// sequence. The text of the finding has the values, and is no part of it.
operation_oracle_signature :: proc(finding: Operation_Finding, sequence: ^operation_sequence.Sequence, header: ^operation_sequence.Mailbox_Header) -> string {
	if finding.step >= 0 && finding.step < sequence.step_count {
		return fmt.tprintf("oracle %v: %s", finding.oracle, operation_word_name(sequence.steps[finding.step].operation))
	}
	if finding.oracle != .Outcome {
		return fmt.tprintf("oracle %v: the whole sequence", finding.oracle)
	}
	outcome, known := enum_word.member_of_word(operation_sequence.Execution_Outcome, header.outcome)
	if !known {
		return fmt.tprintf("oracle %v: an outcome word that names no outcome", finding.oracle)
	}
	return fmt.tprintf("oracle %v: the outcome %v", finding.oracle, outcome)
}

// The starts of the lines of the kernel when one of them stops.
@(rodata)
operation_isolation_marks := [?]string{"kernel: process " + foundation.OPERATION_FUZZING_MODULE + " stopped", "kernel: process " + fuzz.OPERATION_ROOT_MODULE + " stopped"}

// operation_isolation_line gives the first line of the log that starts
// with a mark of operation_isolation_marks, or "".
operation_isolation_line :: proc(log: string) -> string {
	for mark in operation_isolation_marks {
		place := 0
		for {
			at := strings.index(log[place:], mark)
			if at < 0 {
				break
			}
			at += place
			place = at + len(mark)
			if at > 0 && log[at - 1] != '\n' {
				continue
			}
			line := log[at:]
			if end := strings.index_byte(line, '\n'); end >= 0 {
				line = line[:end]
			}
			return strings.trim_right(line, "\r")
		}
	}
	return ""
}

operation_isolation_fault :: proc(line, log: string) -> Operation_Fault {
	return {kind = .Isolation, signature = fmt.tprintf("isolation: %s", operation_numbers_removed(line)), text = line, log = log}
}

// The start of each line of the process operation_fuzzing on the log.
OPERATION_SERVICE_LINE_START :: "[" + foundation.OPERATION_FUZZING_MODULE + "] "

// operation_end_line_through gives the bytes of a text up to the end of the
// end line of the sequence `number`, which the service writes after each
// sequence (operation_sequence.SEQUENCE_END_LINE_START). The line must
// start a line and end with its number, so the line of the sequence 1 is
// not the line of the sequence 12, and a process that quotes it in its
// own line is not taken. found is false while the whole line has not come.
operation_end_line_through :: proc(text: string, number: u64) -> (through: int, found: bool) {
	line := fmt.tprintf("%s%s%d%s", OPERATION_SERVICE_LINE_START, operation_sequence.SEQUENCE_END_LINE_START, number, operation_sequence.SEQUENCE_END_LINE_END)
	place := 0
	for place < len(text) {
		at := strings.index(text[place:], line)
		if at < 0 {
			return 0, false
		}
		at += place
		after := at + len(line)
		place = at + 1
		if at > 0 && text[at - 1] != '\n' {
			continue
		}
		if after >= len(text) || (text[after] != '\n' && text[after] != '\r') {
			continue
		}
		newline := strings.index_byte(text[after:], '\n')
		if newline < 0 {
			return 0, false
		}
		return after + newline + 1, true
	}
	return 0, false
}

// operation_findings_text gives each broken oracle of one execution, one
// line each.
operation_findings_text :: proc(findings: []Operation_Finding) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for finding, index in findings {
		if index > 0 {
			strings.write_byte(&builder, '\n')
		}
		fmt.sbprintf(&builder, "step %d: %v: %s", finding.step, finding.oracle, finding.text)
	}
	return strings.to_string(builder)
}

operation_fault_clone :: proc(fault: Operation_Fault) -> Operation_Fault {
	return {kind = fault.kind, signature = strings.clone(fault.signature), text = strings.clone(fault.text), log = strings.clone(fault.log)}
}

// ---------------------------------------------------------------------
// A machine, as the loop and the minimizer see it.

Operation_Machine :: struct {
	data:    rawptr,
	// Boots a new machine and waits for its mailbox: false when it does
	// not reach the line of the mailbox.
	start:   proc(data: rawptr) -> bool,
	// Runs one sequence that check accepted, as bytes and as the copy that
	// check read. A fault that it gives belongs to this sequence.
	execute: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault,
	// After the last sequence of a life: a fault that comes after its
	// count, within OPERATION_LOG_DRAIN_BOUND. It belongs to the last
	// sequence.
	drain:   proc(data: rawptr) -> Operation_Fault,
	// Ends the machine, whatever its state.
	end:     proc(data: rawptr),
	// Optional: the edge counters of the counted kernel after the last
	// sequence, which the machine set to zero before it. A problem is an
	// error of the tool. nil: a machine with no counters.
	counters: proc(data: rawptr) -> (counts: []u8, problem: string),
}

Operation_Life_Outcome :: struct {
	booted:     bool,
	boots:      int,  // The boots that the life made: 1 or more.
	tool_error: bool, // An error of the tool ended the life: fault holds its text.
	fault:      Operation_Fault,
	faulting:   int, // The place in the life of the sequence of the fault; -1 with no fault.
}

// operation_life_run runs a life on a new machine, with at most
// boot_tries boots, up to its first fault, then drains the log after its
// last sequence and ends the machine.
operation_life_run :: proc(machine: ^Operation_Machine, life: [][]u8, boot_tries := OPERATION_BOOT_TRIES) -> (outcome: Operation_Life_Outcome) {
	outcome.faulting = -1
	for _ in 0 ..< boot_tries {
		outcome.boots += 1
		if machine.start(machine.data) {
			outcome.booted = true
			break
		}
	}
	if !outcome.booted {
		return outcome
	}
	defer machine.end(machine.data)
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	for bytes, place in life {
		// Each sequence of a life passed check when it was made; one that
		// does not ends the life with no fault, so it never holds.
		if operation_sequence.check(bytes, sequence).problem != .None {
			return outcome
		}
		fault := machine.execute(machine.data, sequence, bytes)
		if fault.kind == .Tool {
			outcome.tool_error = true
			outcome.fault = fault
			return outcome
		}
		if fault.kind != .None {
			outcome.fault = fault
			outcome.faulting = place
			return outcome
		}
	}
	if len(life) == 0 {
		return outcome
	}
	fault := machine.drain(machine.data)
	switch fault.kind {
	case .None:
	case .Tool:
		outcome.tool_error = true
		outcome.fault = fault
	case .Stop, .Hang, .Isolation, .Mailbox, .Oracle:
		outcome.fault = fault
		outcome.faulting = len(life) - 1
	}
	return outcome
}

// ---------------------------------------------------------------------
// The minimization.

// Why a minimization ended.
Operation_Minimize_End :: enum u8 {
	Done,       // Each pass ran.
	Bound,      // The bound of the boots stopped the passes: the life is the smallest found before it.
	No_Boot,    // Two boots in a row did not reach the mailbox: an error of the build.
	Tool_Error, // An error of the tool stopped the passes.
}

Operation_Minimized :: struct {
	life:       [][]u8, // In the allocator of the context.
	boots:      int,    // The boots that the minimization made.
	reproduced: bool,   // The fault came again on a new machine; else the life is the life of the run.
	end:        Operation_Minimize_End,
}

@(private = "file")
Operation_Minimizer :: struct {
	machine:    ^Operation_Machine,
	signature:  string,
	boots_most: int,
	boots:      int,
	end:        Operation_Minimize_End,
}

// operation_life_holds runs a candidate life on a new machine. It holds
// when its last sequence gives the fault of the signature: a fault at an
// earlier sequence does not hold, so the last sequence stays the one of the
// fault. The boots of the tries never pass the bound: a try gets the boots
// that are left, and with none left no try runs. The temporary memory is
// freed after each try: a minimization boots up to its bound, and each
// execution uses some.
@(private = "file")
operation_life_holds :: proc(minimizer: ^Operation_Minimizer, life: [][]u8) -> bool {
	if minimizer.end != .Done {
		return false
	}
	left := minimizer.boots_most - minimizer.boots
	if left <= 0 {
		minimizer.end = .Bound
		return false
	}
	outcome := operation_life_run(minimizer.machine, life, min(OPERATION_BOOT_TRIES, left))
	minimizer.boots += outcome.boots
	if outcome.tool_error {
		fmt.eprintfln("modustool: fuzz operations: an error of the tool during a minimization: %s", outcome.fault.text)
		minimizer.end = .Tool_Error
	} else if !outcome.booted {
		minimizer.end = outcome.boots >= OPERATION_BOOT_TRIES ? .No_Boot : .Bound
	}
	holds := outcome.booted && !outcome.tool_error && outcome.faulting == len(life) - 1 && outcome.fault.signature == minimizer.signature
	free_all(context.temp_allocator)
	return holds
}

// operation_fault_minimize gives the smallest life that still gives the
// fault of the signature at its last sequence: the last sequence alone, or
// the whole life; then the sequences before the last, by ranges; then the
// steps of the last sequence, by ranges
// (src/md/infrastructure/kernel_fuzzing.md, "The loop and the speed"). It
// boots at most boots_most machines. It frees the temporary memory after
// each machine: the caller keeps nothing there.
operation_fault_minimize :: proc(machine: ^Operation_Machine, life: [][]u8, signature: string, boots_most := OPERATION_MINIMIZE_BOOTS_MOST) -> (minimized: Operation_Minimized) {
	minimizer := Operation_Minimizer{machine = machine, signature = signature, boots_most = boots_most}
	current := make([dynamic][]u8)
	last := life[len(life) - 1]
	alone := [1][]u8{last}
	if operation_life_holds(&minimizer, alone[:]) {
		append(&current, slice.clone(last))
		minimized.reproduced = true
	} else {
		for bytes in life {
			append(&current, slice.clone(bytes))
		}
		minimized.reproduced = len(life) > 1 && operation_life_holds(&minimizer, life)
	}
	if minimized.reproduced {
		operation_prefix_minimize(&minimizer, &current)
		operation_steps_minimize(&minimizer, &current)
	}
	minimized.life = current[:]
	minimized.boots = minimizer.boots
	minimized.end = minimizer.end
	return minimized
}

// operation_prefix_minimize removes ranges of the sequences before the
// last, from half of them down to one, while a try holds.
@(private = "file")
operation_prefix_minimize :: proc(minimizer: ^Operation_Minimizer, current: ^[dynamic][]u8) {
	chunk := max((len(current^) - 1) / 2, 1)
	for chunk >= 1 {
		start := 0
		for start < len(current^) - 1 {
			end := min(start + chunk, len(current^) - 1)
			candidate := make([dynamic][]u8, 0, len(current^) - (end - start))
			append(&candidate, ..current^[:start])
			append(&candidate, ..current^[end:])
			holds := operation_life_holds(minimizer, candidate[:])
			delete(candidate)
			if !holds {
				start = end
				continue
			}
			for bytes in current^[start:end] {
				delete(bytes)
			}
			remove_range(current, start, end)
		}
		chunk /= 2
	}
}

// operation_steps_removed copies a sequence with `count` steps from `first`
// removed. An argument that names the result of a removed step becomes the
// plain value 0; one that names a later step names it at its new place.
// The step that comes after the range joins no earlier kernel entry: the
// entry that it joined lost steps, and a smaller entry passes check more
// often, so more candidates run.
operation_steps_removed :: proc(from: ^operation_sequence.Sequence, first, count: int, into: ^operation_sequence.Sequence) {
	into^ = from^
	into.step_count = from.step_count - count
	for place in 0 ..< into.step_count {
		source := place < first ? place : place + count
		item := from.steps[source]
		for &argument in item.arguments {
			if argument.source != .Result {
				continue
			}
			if argument.step >= first + count {
				argument.step -= count
			} else if argument.step >= first {
				argument = {source = .Value}
			}
		}
		into.steps[place] = item
	}
	for place in into.step_count ..< from.step_count {
		into.steps[place] = {}
	}
	if into.step_count > 0 {
		into.steps[0].flags -= {.Same_Entry}
	}
	if count > 0 && first < into.step_count {
		into.steps[first].flags -= {.Same_Entry}
	}
}

// operation_steps_minimize removes ranges of the steps of the last
// sequence, from half of them down to one, while a try holds. A candidate
// that check refuses is not run.
@(private = "file")
operation_steps_minimize :: proc(minimizer: ^Operation_Minimizer, current: ^[dynamic][]u8) {
	last := len(current^) - 1
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	candidate := new(operation_sequence.Sequence)
	defer free(candidate)
	if operation_sequence.check(current^[last], sequence).problem != .None {
		return
	}
	life := make([][]u8, len(current^))
	defer delete(life)
	copy(life, current^[:])
	chunk := max(sequence.step_count / 2, 1)
	for chunk >= 1 && sequence.step_count > 0 {
		start := 0
		for start < sequence.step_count {
			count := min(chunk, sequence.step_count - start)
			operation_steps_removed(sequence, start, count, candidate)
			if bytes, accepted := fuzz.operation_sequence_encode(candidate); accepted {
				life[last] = bytes
				if operation_life_holds(minimizer, life) {
					delete(current^[last])
					current^[last] = bytes
					sequence^ = candidate^
					continue
				}
				delete(bytes)
				life[last] = current^[last]
			}
			start += count
		}
		chunk /= 2
	}
}

// ---------------------------------------------------------------------
// The loop.

// A generator of sequences: the same random state gives the same sequence.
Operation_Generator :: #type proc(random: ^fuzz.Fuzz_Random, sequence: ^operation_sequence.Sequence)

Operation_Run_Bounds :: struct {
	executions:     u64,
	life_sequences: int, // The sequences of one machine life, at most.
	findings_most:  int, // The kept faults that end the run.
}

Operation_Kept_Fault :: struct {
	fault:       Operation_Fault, // In the allocator of the context.
	life:        [][]u8,          // The life up to the fault, as the run gave it.
	minimized:   Operation_Minimized,
	execution:   u64, // The number of the execution of the fault, from 1.
	life_number: int, // The number of the machine life of the fault, from 1.
}

Operation_Run :: struct {
	executions:        u64,
	lives:             int,
	faults:            int, // Each fault, with those whose signature a kept fault has.
	kept:              [dynamic]Operation_Kept_Fault,
	ended_by_findings: bool,
	sequence_time:     time.Duration, // A measure: the time in the executions.
	boot_time:         time.Duration, // A measure: the time of the boots of the lives.
}

// The procedure that writes a kept fault where the run keeps them; nil
// keeps it in the run only. false: it could not, an error of the tool.
Operation_Fault_Keeper :: #type proc(kept: ^Operation_Kept_Fault, seed: u64) -> bool

operation_life_free :: proc(life: [][]u8) {
	for bytes in life {
		delete(bytes)
	}
	delete(life)
}

operation_run_free :: proc(run: ^Operation_Run) {
	for &kept in run.kept {
		delete(kept.fault.signature)
		delete(kept.fault.text)
		delete(kept.fault.log)
		operation_life_free(kept.life)
		operation_life_free(kept.minimized.life)
	}
	delete(run.kept)
	run^ = {}
}

operation_signature_kept :: proc(kept: []Operation_Kept_Fault, signature: string) -> bool {
	for item in kept {
		if item.fault.signature == signature {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------
// The engine guided by the counters.

// The state of the engine guided by the counters of the kernel. Each slice
// and array is in the allocator of the context.
Operation_Guide :: struct {
	edges:     fuzz.Kernel_Edge_Map, // Made at the first counters, with their count.
	entries:   [dynamic]fuzz.Operation_Reach_Entry, // The kept inputs, in the order of their keep.
	seeds:     [][]u8, // The reach inputs of the corpus, which run first.
	seeds_run: int,
	// A choice sequence that gave a new feature, while repeat_waiting: its
	// second run is the next execution. Its own flag, because an empty
	// sequence of choices can be nil.
	repeat:         []u8,
	repeat_waiting: bool,
	first:     []u8, // The counters of the first run of `repeat`.
	stable:    []u8, // The part of the two runs that agrees.
	choices:   [dynamic]u8, // The choices of the execution that runs.
	read:      int, // The bytes of choices that the generator read.
	repeats:   int, // The second runs, a measure.
}

// operation_guide_make gives a guide that runs the reach inputs of a
// folder first, in the order of their names.
operation_guide_make :: proc(reach_folder: string) -> Operation_Guide {
	stored := fuzz.fuzz_inputs_read(reach_folder, context.temp_allocator)
	seeds := make([][]u8, len(stored))
	for input, place in stored {
		seeds[place] = slice.clone(input.bytes)
	}
	return {entries = make([dynamic]fuzz.Operation_Reach_Entry), seeds = seeds, choices = make([dynamic]u8)}
}

operation_guide_free :: proc(guide: ^Operation_Guide) {
	fuzz.kernel_edge_map_destroy(&guide.edges)
	for entry in guide.entries {
		delete(entry.choices)
		delete(entry.features)
	}
	delete(guide.entries)
	for seed in guide.seeds {
		delete(seed)
	}
	delete(guide.seeds)
	delete(guide.repeat)
	delete(guide.first)
	delete(guide.stable)
	delete(guide.choices)
	guide^ = {}
}

// operation_guide_next writes the choices of the next execution: the
// second run that waits, then each reach input of the corpus, then one new
// draw in OPERATION_NEW_DRAW_ONE_IN, else a kept input with 1, 2, 4 or 8
// mutations, from the newest eighth for half of the draws.
operation_guide_next :: proc(guide: ^Operation_Guide, random: ^fuzz.Fuzz_Random) {
	clear(&guide.choices)
	switch {
	case guide.repeat_waiting:
		append(&guide.choices, ..guide.repeat)
	case guide.seeds_run < len(guide.seeds):
		append(&guide.choices, ..guide.seeds[guide.seeds_run])
		guide.seeds_run += 1
	case len(guide.entries) == 0 || fuzz.fuzz_random_one_in(random, OPERATION_NEW_DRAW_ONE_IN):
		resize(&guide.choices, fuzz.OPERATION_CHOICE_BYTES)
		for place := 0; place < len(guide.choices); place += 8 {
			word := fuzz.fuzz_random_next(random)
			for index in 0 ..< min(8, len(guide.choices) - place) {
				guide.choices[place + index] = u8(word >> (8 * u64(index)))
			}
		}
	case:
		count := len(guide.entries)
		place := fuzz.fuzz_random_below(random, count)
		if fuzz.fuzz_random_one_in(random, 2) {
			place = count - 1 - fuzz.fuzz_random_below(random, max(count / 8, 1))
		}
		append(&guide.choices, ..guide.entries[place].choices)
		other := guide.entries[fuzz.fuzz_random_below(random, count)].choices
		mutations := 1 << uint(fuzz.fuzz_random_below(random, 4))
		for _ in 0 ..< mutations {
			fuzz.operation_choices_mutate(random, &guide.choices, other)
		}
	}
}

// operation_guide_after reads the counters of an execution that broke no
// oracle. A first run that gives a new feature waits for its second run; a
// second run keeps its input when the part that agrees with the first run
// gives a new feature, and marks that part. A problem is an error of the
// tool: counters of another count than the first ones.
operation_guide_after :: proc(guide: ^Operation_Guide, counts: []u8) -> (problem: string) {
	if guide.edges.edge_count == 0 {
		edges, made := fuzz.kernel_edge_map_make(len(counts))
		if !made {
			return fmt.tprintf("the counted kernel gave %d counters, and the tool takes 1 to %d", len(counts), fuzz.KERNEL_EDGES_MOST)
		}
		guide.edges = edges
		guide.first = make([]u8, len(counts))
		guide.stable = make([]u8, len(counts))
	}
	if guide.repeat_waiting {
		defer operation_guide_fault(guide)
		guide.repeats += 1
		if !fuzz.kernel_edge_counters_stable(guide.first, counts, guide.stable) {
			return fmt.tprintf("the counted kernel gave %d counters, after %d", len(counts), len(guide.first))
		}
		fresh, _ := fuzz.kernel_edge_features_new(&guide.edges, guide.stable)
		if fresh == 0 {
			return ""
		}
		_, _ = fuzz.kernel_edge_features_mark(&guide.edges, guide.stable)
		append(&guide.entries, fuzz.Operation_Reach_Entry{choices = slice.clone(guide.repeat), features = fuzz.kernel_edge_features_of(guide.stable)})
		return ""
	}
	fresh, same_count := fuzz.kernel_edge_features_new(&guide.edges, counts)
	if !same_count {
		return fmt.tprintf("the counted kernel gave %d counters, after %d", len(counts), guide.edges.edge_count)
	}
	if fresh > 0 {
		copy(guide.first, counts)
		guide.repeat = slice.clone(guide.choices[:guide.read])
		guide.repeat_waiting = true
	}
	return ""
}

// operation_guide_fault forgets the second run that waits: after that run,
// or when a run gave a fault, whose input is a finding and not a reach
// input.
operation_guide_fault :: proc(guide: ^Operation_Guide) {
	delete(guide.repeat)
	guide.repeat = nil
	guide.repeat_waiting = false
}

// operation_guide_reach_write writes the reach inputs of the corpus from
// the kept inputs of a run: the smallest set that gives each of their
// features, in the room of the bounds of the corpus. A run that did not run
// each reach input of the corpus changes nothing: its kept inputs do not
// hold their features.
operation_guide_reach_write :: proc(guide: ^Operation_Guide, corpus_folder: string) -> (written, left_out: int, changed, ok: bool) {
	if guide.seeds_run < len(guide.seeds) {
		return 0, 0, false, true
	}
	cover := fuzz.operation_reach_cover(guide.entries[:], context.temp_allocator)
	inputs := make([][]u8, len(cover), context.temp_allocator)
	for place, index in cover {
		inputs[index] = guide.entries[place].choices
	}
	written, left_out, ok = fuzz.operation_reach_inputs_write(corpus_folder, inputs)
	return written, left_out, true, ok
}

// operation_fuzzing_loop runs generated sequences on machines, one machine
// at a time, until the count of executions, the bound of the findings, an
// error of the tool, or two boots in a row with no mailbox. A machine life
// ends at its bound of sequences, at the end of the run, or at a fault;
// before a life ends with no fault, the machine drains its log, and a fault
// found there belongs to the last sequence. A fault with a new signature is
// minimized and kept, a fault with a known one is only counted. With a
// guide and a machine with counters, the guide gives the choices of each
// sequence and reads the counters after each one that broke no oracle;
// else `generate` draws each sequence. ok is false at an error of the build
// or of the tool. The loop frees the temporary memory after each
// execution: the caller keeps nothing there.
operation_fuzzing_loop :: proc(machine: ^Operation_Machine, generate: Operation_Generator, seed: u64, bounds: Operation_Run_Bounds, keeper: Operation_Fault_Keeper = nil, guide: ^Operation_Guide = nil) -> (run: Operation_Run, ok: bool) {
	guided := guide != nil && machine.counters != nil
	random := fuzz.Fuzz_Random{state = seed}
	life := make([dynamic][]u8)
	defer {
		for bytes in life {
			delete(bytes)
		}
		delete(life)
	}
	generated := new(operation_sequence.Sequence)
	defer free(generated)
	checked := new(operation_sequence.Sequence)
	defer free(checked)
	running := false
	defer {
		if running {
			machine.end(machine.data)
		}
	}
	failed_boots := 0
	for run.executions < bounds.executions {
		if !running {
			boot_started := time.tick_now()
			booted := machine.start(machine.data)
			run.boot_time += time.tick_since(boot_started)
			if !booted {
				failed_boots += 1
				if failed_boots >= OPERATION_BOOT_TRIES {
					fmt.eprintfln("modustool: fuzz operations: %d machines in a row did not reach the line \"%s\": an error of the build, not a finding", failed_boots, OPERATION_MAILBOX_LINE)
					return run, false
				}
				continue
			}
			failed_boots = 0
			running = true
			run.lives += 1
			for bytes in life {
				delete(bytes)
			}
			clear(&life)
		}
		if guided {
			operation_guide_next(guide, &random)
			guide.read = fuzz.operation_sequence_of_choices(guide.choices[:], generated)
		} else {
			generate(&random, generated)
		}
		bytes, accepted := fuzz.operation_sequence_encode(generated)
		if !accepted || operation_sequence.check(bytes, checked).problem != .None {
			fmt.eprintln("modustool: fuzz operations: the generator built a sequence that check refuses: a fault of the tool")
			delete(bytes)
			return run, false
		}
		append(&life, bytes)
		execution_started := time.tick_now()
		fault := machine.execute(machine.data, checked, bytes)
		run.sequence_time += time.tick_since(execution_started)
		run.executions += 1
		life_ends := len(life) >= bounds.life_sequences || run.executions >= bounds.executions
		if fault.kind == .None && life_ends {
			fault = machine.drain(machine.data)
		}
		// The counters, before the end of the machine: a fault, the drain
		// too, belongs to the sequence, which keeps no input then.
		if guided && fault.kind == .None {
			counts, problem := machine.counters(machine.data)
			if problem == "" {
				problem = operation_guide_after(guide, counts)
			}
			if problem != "" {
				fault = {kind = .Tool, text = problem}
			}
		} else if guided {
			operation_guide_fault(guide)
		}
		if fault.kind == .Tool {
			fmt.eprintfln("modustool: fuzz operations: an error of the tool, not a finding: %s", fault.text)
			return run, false
		}
		if fault.kind == .None {
			if life_ends {
				machine.end(machine.data)
				running = false
			}
			free_all(context.temp_allocator)
			continue
		}
		machine.end(machine.data)
		running = false
		run.faults += 1
		if operation_signature_kept(run.kept[:], fault.signature) {
			free_all(context.temp_allocator)
			continue
		}
		kept := Operation_Kept_Fault{fault = operation_fault_clone(fault), execution = run.executions, life_number = run.lives}
		kept.life = make([][]u8, len(life))
		for item, place in life {
			kept.life[place] = slice.clone(item)
		}
		fmt.eprintfln("modustool: fuzz operations: a fault of the kernel at the execution %d, the sequence %d of the life of the machine %d: %s", kept.execution, len(life), kept.life_number, kept.fault.signature)
		free_all(context.temp_allocator)
		kept.minimized = operation_fault_minimize(machine, kept.life, kept.fault.signature)
		append(&run.kept, kept)
		if keeper != nil && !keeper(&run.kept[len(run.kept) - 1], seed) {
			return run, false
		}
		free_all(context.temp_allocator)
		switch kept.minimized.end {
		case .Done, .Bound:
		case .No_Boot:
			fmt.eprintfln("modustool: fuzz operations: %d machines in a row did not reach the line \"%s\" during a minimization: an error of the build, not a finding", OPERATION_BOOT_TRIES, OPERATION_MAILBOX_LINE)
			return run, false
		case .Tool_Error:
			return run, false
		}
		if len(run.kept) >= bounds.findings_most {
			run.ended_by_findings = true
			break
		}
	}
	return run, true
}

// operation_sequence_generate_random draws the choices of one sequence
// from the random state, then builds it with the generator of the fuzz
// target operation_sequence_generated, which a host test and that target
// check: each sequence that it builds is one that check accepts. It then
// changes each protected process name.
operation_sequence_generate_random :: proc(random: ^fuzz.Fuzz_Random, sequence: ^operation_sequence.Sequence) {
	fuzz.operation_sequence_generate_random_written(random, sequence, nil)
}

// ---------------------------------------------------------------------
// The findings in the build folder.

// operation_run_folder gives the folder of the findings of the run of a
// seed: a run never mixes its findings with those of another seed, and
// the same seed writes the same findings again.
operation_run_folder :: proc(seed: u64) -> string {
	return fmt.tprintf("%s/%d", OPERATION_FUZZING_FOLDER, seed)
}

// operation_life_write writes each sequence of a life in a folder, in its
// order, after it removed the files of an earlier run of the same seed.
@(private = "file")
operation_life_write :: proc(folder: string, life: [][]u8) -> bool {
	_ = os.remove_all(folder)
	if !foundation.make_folder(folder) {
		return false
	}
	for bytes, place in life {
		path := fmt.tprintf("%s/sequence_%04d", folder, place)
		if error := os.write_entire_file(path, bytes); error != nil {
			fmt.eprintfln("modustool: fuzz operations: an error of the tool: cannot write %s: %v", path, error)
			return false
		}
	}
	return true
}

@(private = "file")
operation_text_write :: proc(path, text: string) -> bool {
	if error := os.write_entire_file(path, transmute([]u8)text); error != nil {
		fmt.eprintfln("modustool: fuzz operations: an error of the tool: cannot write %s: %v", path, error)
		return false
	}
	return true
}

// operation_fault_write writes a kept fault in the folder of its run,
// named by the start of the hash of its signature, and prints where it is.
// false: a file was not written, an error of the tool.
operation_fault_write :: proc(kept: ^Operation_Kept_Fault, seed: u64) -> bool {
	name := fuzz.fuzz_input_name(transmute([]u8)kept.fault.signature)
	folder := fmt.tprintf("%s/%s", operation_run_folder(seed), name[:OPERATION_FINDING_NAME_DIGITS])
	if !foundation.make_folder(folder) || !operation_life_write(fmt.tprintf("%s/life", folder), kept.life) || !operation_life_write(fmt.tprintf("%s/minimized", folder), kept.minimized.life) {
		return false
	}
	minimized := kept.minimized.life
	last := new(operation_sequence.Sequence)
	defer free(last)
	steps := -1
	if len(minimized) > 0 && operation_sequence.check(minimized[len(minimized) - 1], last).problem == .None {
		steps = last.step_count
	}
	summary := kept.minimized.reproduced ? fmt.tprintf("minimized to %d sequences, %d steps in the last one, with %d boots (%v)", len(minimized), steps, kept.minimized.boots, kept.minimized.end) : fmt.tprintf("the fault did not come again on a new machine, in %d boots: the life is kept whole", kept.minimized.boots)
	text := fmt.tprintf("%s\n%s\nthe seed %d, the execution %d, the machine life %d of %d sequences\n%s\n", kept.fault.signature, kept.fault.text, seed, kept.execution, kept.life_number, len(kept.life), summary)
	if !operation_text_write(fmt.tprintf("%s/finding.txt", folder), text) {
		return false
	}
	if kept.fault.log != "" && !operation_text_write(fmt.tprintf("%s/machine_log.txt", folder), kept.fault.log) {
		return false
	}
	fmt.eprintfln("modustool:   %s", kept.fault.text)
	fmt.eprintfln("modustool:   %s: %s", summary, folder)
	if len(minimized) == 1 {
		fmt.eprintfln("modustool:   `modustool fuzz replay operations %s/minimized/sequence_0000` runs it again", folder)
	}
	return true
}

// ---------------------------------------------------------------------
// The log of a machine.

// operation_log_lines_from gives the whole lines of a log file from the
// byte `from`: a last line that QEMU has not ended yet is not given, so a
// line is never read in two parts.
operation_log_lines_from :: proc(path: string, from: i64) -> string {
	information, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil || information.size <= from {
		return ""
	}
	file, open_error := os.open(path, {.Read})
	if open_error != nil {
		return ""
	}
	defer os.close(file)
	bytes := make([]u8, information.size - from, context.temp_allocator)
	count, _ := os.read_at(file, bytes, from)
	if count <= 0 {
		return ""
	}
	text := string(bytes[:count])
	return text[:strings.last_index_byte(text, '\n') + 1]
}

// operation_log_new_lines gives the whole lines from `scanned`, and moves
// `scanned` past them.
operation_log_new_lines :: proc(path: string, scanned: ^i64) -> string {
	text := operation_log_lines_from(path, scanned^)
	scanned^ += i64(len(text))
	return text
}

// ---------------------------------------------------------------------
// The machine of the operation sequences under QEMU.

// The machine of the commands, behind Operation_Machine. After a life with
// no fault, `results` holds the answers of its last sequence.
Operation_Qemu :: struct {
	part:          Test_Part_Run, // Its data disk, which no process of the image drives.
	peer:          Peer,
	peer_started:  bool,
	host_process:       os.Process,
	monitor_read:  ^os.File,
	monitor_write: ^os.File,
	mailbox:       Operation_Mailbox,
	mailbox_open:  bool,
	running:       bool,
	exited:        bool, // QEMU ended, and the tool read the state of its end.
	log_scanned:   i64,  // The bytes of the log that belong to the sequences counted and ended.
	grammar:       Operation_Grammar,
	kernel_object: []u8, // The debug object of the kernel of the volume, or nil.
	header:        ^operation_sequence.Mailbox_Header,
	results:       ^operation_sequence.Runner_Results,
	volume:        string, // The boot volume of the command: a constant of the build.
	// The kernel of the volume is a counted kernel: its boot line names its
	// counters, which the tool sets to zero before each sequence and reads
	// after it.
	counted:          bool,
	counters_found:   bool, // This machine wrote the boot line of its counters.
	counters_address: u64, // Their physical address: their offset in the memory file.
	counts:           []u8, // The counters after the last sequence.
	zeros:            []u8, // As many zeros, written after each read of the counters.
	// The guards that the link of the counted kernel kept: the counters
	// past them must stay 0.
	linked_guards:    int,
}

// operation_counters_problem says why counters that must be 0 are not:
// the counted kernel counted code that it must not count. "": each is 0.
operation_counters_problem :: proc(counts: []u8, from: int, what: string) -> string {
	start := min(max(from, 0), len(counts))
	for count, edge in counts[start:] {
		if count != 0 {
			return fmt.tprintf("a fault of the counted kernel, not a finding: the counter of the edge %d is %d %s", edge + start, count, what)
		}
	}
	return ""
}

// operation_counters_read reads the counters of the counted kernel from
// the memory file into state.counts.
@(private = "file")
operation_counters_read :: proc(state: ^Operation_Qemu) -> (problem: string) {
	read, error := os.read_at(state.mailbox.file, state.counts, i64(state.counters_address))
	if error != nil || read != len(state.counts) {
		return fmt.tprintf("cannot read the %d counters at %d of the memory file: %v", len(state.counts), state.counters_address, error)
	}
	return ""
}

@(private = "file")
operation_log_whole :: proc() -> string {
	bytes, error := os.read_entire_file(OPERATION_FUZZING_OUTPUT, context.temp_allocator)
	if error != nil {
		return ""
	}
	return string(bytes)
}

@(private = "file")
operation_stop_fault :: proc(state: ^Operation_Qemu, exit_code: int) -> Operation_Fault {
	state.exited = true
	log := operation_log_whole()
	signature, text := operation_stop_signature(exit_code, log, state.kernel_object)
	return {kind = .Stop, signature = signature, text = text, log = log}
}

// operation_machine_stopped says if QEMU ended, with the fault of its stop.
@(private = "file")
operation_machine_stopped :: proc(state: ^Operation_Qemu) -> (fault: Operation_Fault, stopped: bool) {
	// A wait of 0 does not block: Timeout says that QEMU runs.
	if ended, wait_error := os.process_wait(state.host_process, 0); wait_error == nil && ended.exited {
		return operation_stop_fault(state, ended.exit_code), true
	}
	return {}, false
}

// operation_machine_kernel_object reads the debug object of the kernel of a
// volume, which names the procedure of the address of a report.
operation_machine_kernel_object :: proc(volume: string) -> []u8 {
	for row in build.boot_volumes() {
		if row.path != volume || row.kernel == "" {
			continue
		}
		object, error := os.read_entire_file(build.debug_object_path(row.kernel), context.allocator)
		if error != nil {
			return nil
		}
		if debug_object.check(object) != .None {
			delete(object)
			return nil
		}
		return object
	}
	return nil
}

// operation_machine_start boots a new machine with a new memory file and
// waits for the line of its mailbox, until QEMU ends or BOOT_HANG_BOUND.
operation_machine_start :: proc(data: rawptr) -> bool {
	state := (^Operation_Qemu)(data)
	_ = os.remove(OPERATION_FUZZING_MEMORY_FILE)
	_ = os.remove(OPERATION_FUZZING_OUTPUT)
	clock := machine_clock_of(time.time_to_unix(time.now()))
	command, made := machine_command(state.volume, OPERATION_FUZZING_OUTPUT, state.part.data_disk, &state.peer, clock_argument = clock.argument, memory_file = OPERATION_FUZZING_MEMORY_FILE)
	if !made {
		return false
	}
	monitor_read, monitor_write, pipe_error := os.pipe()
	if pipe_error != nil {
		peer_machine_socket_lent_close(&state.peer)
		fmt.eprintfln("modustool: cannot create a pipe: %v", pipe_error)
		return false
	}
	host_process, start_error := os.process_start({command = command, stdin = monitor_read, stderr = os.stderr})
	// QEMU has its copy of the socket of the peer now.
	peer_machine_socket_lent_close(&state.peer)
	if start_error != nil {
		os.close(monitor_write)
		os.close(monitor_read)
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	state.host_process = host_process
	state.monitor_read, state.monitor_write = monitor_read, monitor_write
	state.running, state.exited, state.mailbox_open, state.log_scanned = true, false, false, 0
	state.counters_found = false
	memory_bytes := u64(MACHINE_MEMORY_MIB) * 1024 * 1024
	for started := time.tick_now(); time.tick_since(started) < BOOT_HANG_BOUND; {
		lines := operation_log_new_lines(OPERATION_FUZZING_OUTPUT, &state.log_scanned)
		// The counted kernel writes the line of its counters at its start,
		// before the root service starts operation_fuzzing.
		if state.counted && !state.counters_found {
			counters_address, count, found, problem := fuzz.kernel_edge_counters_line_read(lines, memory_bytes)
			if problem != "" {
				fmt.eprintfln("modustool: fuzz operations: an error of the build: %s", problem)
				operation_machine_end(state)
				return false
			}
			if found && state.linked_guards > count {
				fmt.eprintfln("modustool: fuzz operations: an error of the build: the linked kernel has %d guards, and its boot line %d counters", state.linked_guards, count)
				operation_machine_end(state)
				return false
			}
			if found {
				state.counters_found = true
				state.counters_address = counters_address
				if len(state.counts) != count {
					delete(state.counts)
					delete(state.zeros)
					state.counts = make([]u8, count)
					state.zeros = make([]u8, count)
				}
			}
		}
		if address, found := number_after(lines, OPERATION_MAILBOX_LINE); found {
			if state.counted && !state.counters_found {
				fmt.eprintfln("modustool: fuzz operations: the counted kernel of %s wrote no line \"%s\" before the line of the mailbox", state.volume, OPERATION_COUNTERS_LINE_START)
				operation_machine_end(state)
				return false
			}
			mailbox, problem := operation_mailbox_open(OPERATION_FUZZING_MEMORY_FILE, address)
			if problem != "" {
				fmt.eprintfln("modustool: fuzz operations: %s", problem)
				operation_machine_end(state)
				return false
			}
			state.mailbox, state.mailbox_open = mailbox, true
			// The start ran the root service and operation_fuzzing, their
			// kernel entries and many ticks, and no counted process: each
			// counter is 0.
			if state.counted {
				counted_problem := operation_counters_read(state)
				if counted_problem == "" {
					counted_problem = operation_counters_problem(state.counts, 0, "before the first sequence")
				}
				if counted_problem != "" {
					fmt.eprintfln("modustool: fuzz operations: %s", counted_problem)
					operation_machine_end(state)
					return false
				}
			}
			return true
		}
		if ended, wait_error := os.process_wait(host_process, 0); wait_error == nil && ended.exited {
			state.exited = true
			fmt.eprintfln("modustool: fuzz operations: QEMU ended with the status %d before the line \"%s\"; the log is %s", ended.exit_code, OPERATION_MAILBOX_LINE, OPERATION_FUZZING_OUTPUT)
			operation_machine_end(state)
			return false
		}
		time.sleep(fuzz.FUZZ_POLL_INTERVAL)
	}
	fmt.eprintfln("modustool: fuzz operations: the machine wrote no line \"%s\" within %v; the log is %s", OPERATION_MAILBOX_LINE, BOOT_HANG_BOUND, OPERATION_FUZZING_OUTPUT)
	operation_machine_end(state)
	return false
}

// operation_machine_execute runs one sequence and reads its fault: the
// stop of QEMU, a stall, a broken mailbox, then, after the end line of the
// sequence, the stop of a process that no sequence reaches in the lines of
// this sequence only, then the oracles of the results. Each line of the
// kernel that this sequence caused comes before its end line, and each line
// of an earlier sequence came before the end line of that one, so a fault
// belongs to the sequence that caused it.
@(private = "file")
operation_machine_execute :: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault {
	state := (^Operation_Qemu)(data)
	// The counters count this sequence only: the read of the sequence
	// before wrote their zeros, or the start found them at 0, and no
	// counted process ran since, through the ticks and the kernel entries
	// of operation_fuzzing between the two sequences.
	if state.counted {
		counted_problem := operation_counters_read(state)
		if counted_problem == "" {
			counted_problem = operation_counters_problem(state.counts, 0, "while no sequence ran")
		}
		if counted_problem != "" {
			return {kind = .Tool, text = counted_problem}
		}
	}
	end, ended, problem := operation_execute_watched(&state.mailbox, bytes, state.header, state.results, &state.host_process)
	switch end {
	case .Counted:
	case .Machine_Ended:
		return operation_stop_fault(state, ended.exit_code)
	case .Stalled:
		if line := operation_isolation_line(operation_log_lines_from(OPERATION_FUZZING_OUTPUT, state.log_scanned)); line != "" {
			return operation_isolation_fault(line, operation_log_whole())
		}
		return {kind = .Hang, signature = operation_hang_signature(sequence, operation_runner_step_started(&state.mailbox)), text = problem, log = operation_log_whole()}
	case .Mailbox_Broken:
		return {kind = .Mailbox, signature = "mailbox: the counts of the mailbox are not the counts that the tool wrote", text = problem, log = operation_log_whole()}
	case .Tool_Error:
		return {kind = .Tool, text = problem}
	}
	number := state.mailbox.written
	lines := ""
	found := false
	for started := time.tick_now(); time.tick_since(started) < foundation.HANG_BOUND; {
		text := operation_log_lines_from(OPERATION_FUZZING_OUTPUT, state.log_scanned)
		if through, has_end := operation_end_line_through(text, number); has_end {
			lines = text[:through]
			state.log_scanned += i64(through)
			found = true
			break
		}
		if fault, stopped := operation_machine_stopped(state); stopped {
			return fault
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	if !found {
		return {kind = .Hang, signature = OPERATION_END_LINE_HANG_SIGNATURE, text = fmt.tprintf("operation_fuzzing counted the sequence %d and wrote no line \"%s%d%s\" within %v", number, operation_sequence.SEQUENCE_END_LINE_START, number, operation_sequence.SEQUENCE_END_LINE_END, foundation.HANG_BOUND), log = operation_log_whole()}
	}
	if line := operation_isolation_line(lines); line != "" {
		return operation_isolation_fault(line, operation_log_whole())
	}
	if outcome, known := enum_word.member_of_word(operation_sequence.Execution_Outcome, state.header.outcome); known && outcome == .Hung {
		return {kind = .Hang, signature = operation_hang_signature(sequence, state.results.step_started), text = fmt.tprintf("operation_fuzzing stopped the runner after its hang bound, at the step %d", state.results.step_started), log = operation_log_whole()}
	}
	if findings := operation_findings(sequence, state.header, state.results, &state.grammar); len(findings) > 0 {
		return {kind = .Oracle, signature = operation_oracle_signature(findings[0], sequence, state.header), text = operation_findings_text(findings)}
	}
	return {}
}

// operation_machine_drain reads the log after the end line of the last
// sequence of a life, for OPERATION_LOG_DRAIN_BOUND, or until QEMU ends:
// a line of isolation, or a stop, belongs to the last sequence.
@(private = "file")
operation_machine_drain :: proc(data: rawptr) -> Operation_Fault {
	state := (^Operation_Qemu)(data)
	if !state.running || state.exited {
		return {}
	}
	for started := time.tick_now(); time.tick_since(started) < OPERATION_LOG_DRAIN_BOUND; {
		if line := operation_isolation_line(operation_log_lines_from(OPERATION_FUZZING_OUTPUT, state.log_scanned)); line != "" {
			return operation_isolation_fault(line, operation_log_whole())
		}
		if fault, stopped := operation_machine_stopped(state); stopped {
			return fault
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return {}
}

// operation_machine_counters reads the counters of the counted kernel from
// the memory file, after the end line of the sequence: the runner and its
// children stopped then. The bytes come from the machine; the guide checks
// their count, and each byte is a count.
@(private = "file")
operation_machine_counters :: proc(data: rawptr) -> (counts: []u8, problem: string) {
	state := (^Operation_Qemu)(data)
	if !state.counters_found || !state.mailbox_open {
		return nil, "the machine wrote no line of its counters"
	}
	if problem = operation_counters_read(state); problem != "" {
		return nil, problem
	}
	// No call of the callback names a guard that the link dropped.
	if problem = operation_counters_problem(state.counts, state.linked_guards, "past the guards of the linked kernel"); problem != "" {
		return nil, problem
	}
	// The zeros for the next sequence, which checks that they stay.
	if written, error := os.write_at(state.mailbox.file, state.zeros, i64(state.counters_address)); error != nil || written != len(state.zeros) {
		return nil, fmt.tprintf("cannot write the zeros of the counters at %d of the memory file: %v", state.counters_address, error)
	}
	return state.counts, ""
}

// operation_machine_end ends QEMU through its monitor, or kills it past
// the hang bound, and removes its memory file.
operation_machine_end :: proc(data: rawptr) {
	state := (^Operation_Qemu)(data)
	if !state.running {
		return
	}
	if state.mailbox_open {
		os.close(state.mailbox.file)
		state.mailbox_open = false
	}
	if !state.exited {
		_, _ = os.write_string(state.monitor_write, "quit\n")
		ended, wait_error := os.process_wait(state.host_process, foundation.HANG_BOUND)
		if wait_error != nil || !ended.exited {
			_ = os.process_kill(state.host_process)
			_, _ = os.process_wait(state.host_process)
		}
		state.exited = true
	}
	os.close(state.monitor_write)
	os.close(state.monitor_read)
	_ = os.remove(OPERATION_FUZZING_MEMORY_FILE)
	state.running = false
}

// operation_qemu_open builds the one volume of a command of the table of
// the volumes, then prepares its machine: the grammar of the oracles, the
// debug object of the kernel, the data disk and the peer. nil: an error,
// which it printed. `fuzz operations` boots the counted kernel, and `fuzz
// regression operations` the kernel that ships, on the same image, with the
// same mailbox and the same oracles.
operation_qemu_open :: proc(command: string) -> ^Operation_Qemu {
	if !fuzz.fuzz_operation_sequence_start() {
		return nil
	}
	grammar, grammar_read := operation_grammar_read()
	if !grammar_read {
		return nil
	}
	volumes := build.boot_volumes_of_command(command)
	if len(volumes) != 1 {
		fmt.eprintfln("modustool: the command %s has %d boot volumes in the table of the volumes, and its machine boots one", command, len(volumes))
		return nil
	}
	if code := build.build_system(volumes); code != 0 {
		return nil
	}
	if !foundation.make_folder(OPERATION_FUZZING_FOLDER) {
		return nil
	}
	state := new(Operation_Qemu)
	state.grammar = grammar
	state.header = new(operation_sequence.Mailbox_Header)
	state.results = new(operation_sequence.Runner_Results)
	state.volume = volumes[0]
	state.counted = build.boot_volume_counts_kernel_edges(state.volume)
	if state.counted {
		for row in build.boot_volumes() {
			if row.path != state.volume {
				continue
			}
			guards, counted := build.kernel_linked_guard_count(row.kernel)
			if !counted {
				fmt.eprintfln("modustool: fuzz operations: the linked file of the counted kernel %s has no section of guards that the tool reads", row.kernel)
				operation_qemu_close(state)
				return nil
			}
			state.linked_guards = guards
		}
	}
	state.kernel_object = operation_machine_kernel_object(state.volume)
	if state.kernel_object == nil {
		fmt.println("modustool: fuzz operations: no debug object of the kernel: a signature of a stop names no procedure")
	}
	state.part = test_part_run_make(command)
	if !test_part_run_start(&state.part) || !peer_start(&state.peer) {
		operation_qemu_close(state)
		return nil
	}
	state.peer_started = true
	return state
}

// operation_qemu_close ends the machine, the peer and the files of a
// command. The data disk stays when state.part.passed is false.
operation_qemu_close :: proc(state: ^Operation_Qemu) {
	operation_machine_end(state)
	if state.peer_started {
		peer_stop(&state.peer)
	}
	_ = os.remove(machine_file(OPERATION_FUZZING_OUTPUT, SCRATCH_DISK_SUFFIX))
	_ = os.remove(machine_file(OPERATION_FUZZING_OUTPUT, FIRMWARE_VARIABLES_SUFFIX))
	test_part_run_free(&state.part)
	free(state.header)
	free(state.results)
	delete(state.kernel_object)
	delete(state.counts)
	delete(state.zeros)
	free(state)
}

operation_qemu_machine :: proc(state: ^Operation_Qemu) -> Operation_Machine {
	machine := Operation_Machine{data = state, start = operation_machine_start, execute = operation_machine_execute, drain = operation_machine_drain, end = operation_machine_end}
	if state.counted {
		machine.counters = operation_machine_counters
	}
	return machine
}

// operation_fuzzing_run is `fuzz operations <executions> [<seed>]`
// (docs/TOOLS.md, "The fuzzing of the kernel operations").
operation_fuzzing_run :: proc(args: []string) -> int {
	arguments, problem := operation_fuzzing_arguments_read(args)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return foundation.EXIT_USAGE
	}
	seed := arguments.seed
	if !arguments.seed_given {
		seed = fuzz.fuzz_sources_seed() ~ u64(time.time_to_unix_nano(time.now()))
	}
	state := operation_qemu_open(build.OPERATION_FUZZING_COMMAND)
	if state == nil {
		return foundation.EXIT_FAILURE
	}
	defer operation_qemu_close(state)
	machine := operation_qemu_machine(state)
	fmt.printfln("modustool: fuzz operations: %d executions from the seed %d, one machine at a time, at most %d sequences in a machine life, on %s", arguments.executions, seed, OPERATION_MACHINE_SEQUENCES_MOST, state.volume)
	// The engine guided by the counters of the counted kernel, which runs
	// the reach inputs of the corpus first.
	guide := operation_guide_make(OPERATION_REACH_FOLDER)
	defer operation_guide_free(&guide)
	run_started := time.tick_now()
	bounds := Operation_Run_Bounds{executions = arguments.executions, life_sequences = OPERATION_MACHINE_SEQUENCES_MOST, findings_most = OPERATION_FINDINGS_MOST}
	run, completed := operation_fuzzing_loop(&machine, operation_sequence_generate_random, seed, bounds, operation_fault_write, &guide)
	defer operation_run_free(&run)
	if machine.counters != nil {
		fmt.printfln("modustool: fuzz operations: %d inputs kept for a new feature of the counted kernel, %d features of %d edges; %d second runs", len(guide.entries), guide.edges.feature_count, guide.edges.edge_count, guide.repeats)
	}
	if completed && machine.counters != nil {
		written, left_out, changed, reach_written := operation_guide_reach_write(&guide, OPERATION_CORPUS_FOLDER)
		switch {
		case !reach_written:
			return foundation.EXIT_FAILURE
		case !changed:
			fmt.printfln("modustool: fuzz operations: the run ended before it ran each of the %d reach inputs of the corpus: %s does not change", len(guide.seeds), OPERATION_REACH_FOLDER)
		case:
			fmt.printfln("modustool: fuzz operations: %d reach inputs in %s, %d left out past the bounds of the corpus: read the change before the commit", written, OPERATION_REACH_FOLDER, left_out)
		}
	}
	run_seconds := time.duration_seconds(time.tick_since(run_started))
	sequence_seconds := time.duration_seconds(run.sequence_time)
	fmt.printfln("modustool: measure: fuzz operations: %d executions in %d machine lives; %.1f executions in one second of the sequences (%.1f s), %.1f in one second of the whole run with the boots and the minimizations (%.1f s, the boots of the lives %.1f s)", run.executions, run.lives, sequence_seconds > 0 ? f64(run.executions) / sequence_seconds : 0, sequence_seconds, run_seconds > 0 ? f64(run.executions) / run_seconds : 0, run_seconds, time.duration_seconds(run.boot_time))
	fmt.printfln("modustool: fuzz operations: %d faults of the kernel, %d signatures kept in %s%s", run.faults, len(run.kept), operation_run_folder(seed), run.ended_by_findings ? fmt.tprintf("; the run ended at %d findings", OPERATION_FINDINGS_MOST) : "")
	for kept in run.kept {
		fmt.printfln("modustool:   %s", kept.fault.signature)
	}
	if !completed {
		return foundation.EXIT_FAILURE
	}
	// The data disk of a run that ended stays only when the run failed.
	state.part.passed = len(run.kept) == 0
	return len(run.kept) == 0 ? 0 : foundation.EXIT_FAILURE
}
