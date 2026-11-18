package modustool

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

// The loop of the kernel fuzzing with no counters
// (src/md/infrastructure/kernel_fuzzing.md, "The loop and the speed";
// docs/TOOLS.md, "The fuzzing of the kernel operations"): generated
// operation sequences on machines of the kernel that ships, one machine at
// a time, a new machine after each fault, each fault kept one time for its
// signature and minimized by machine lives and by steps.
//
// The loop and the minimizer reach a machine through Operation_Machine
// only, so a host test runs them on a fake machine.

// The command `fuzz operations`, as the table of the volumes of the
// commands names it.
OPERATION_FUZZING_COMMAND :: "operation_fuzzing"
// The files of a run, which git ignores: the repository never holds a
// finding of a run.
OPERATION_FUZZING_FOLDER :: FUZZING_BUILD_FOLDER + "/operations"
OPERATION_FINDINGS_FOLDER :: OPERATION_FUZZING_FOLDER + "/" + FUZZ_FINDINGS_PART
OPERATION_FUZZING_OUTPUT :: OPERATION_FUZZING_FOLDER + "/machine_log.txt"
OPERATION_FUZZING_MEMORY_FILE :: OPERATION_FUZZING_FOLDER + "/machine_memory.raw"

// The sequences of one machine life: the state that the kernel keeps
// between two sequences stays short, and a finding that needs earlier
// sequences has a short prefix to search.
OPERATION_MACHINE_SEQUENCES_MOST :: 1024
// The findings that end a run: each one costs up to
// OPERATION_MINIMIZE_MACHINES_MOST boots, and a kernel with that many
// faults is fixed first.
OPERATION_FINDINGS_MOST :: 8
// The machines that the minimization of one finding boots, at most: each
// try is a new machine.
OPERATION_MINIMIZE_MACHINES_MOST :: 256
// The boots in a row with no line of the mailbox that end a run: then the
// build is wrong, and no sequence is the cause.
OPERATION_BOOT_TRIES :: 2
// The choices that the generator reads for one sequence: more than the
// largest sequence reads, so the bytes never run out in a normal draw.
OPERATION_CHOICE_BYTES :: 4096
// The hexadecimal digits of the hash of a signature that name the folder
// of its finding: enough that two signatures of one run never share them.
OPERATION_FINDING_NAME_DIGITS :: 16

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
	Hang,      // The runner did not end its sequence within the hang bound.
	Isolation, // operation_fuzzing or the root service stopped: a sequence reached a program whose handle it did not hold.
	Mailbox,   // The mailbox counts what the tool did not write: a sequence changed the memory of operation_fuzzing.
	Oracle,    // An oracle of the results broke.
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

// operation_numbers_removed writes each word that holds a digit as `#`: an
// address, a count, a slot or a hash changes from one run of a fault to the
// next, and the words around them do not.
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
		for end < len(text) && operation_is_word_byte(text[end]) {
			has_digit ||= text[end] >= '0' && text[end] <= '9'
			end += 1
		}
		strings.write_string(&builder, has_digit ? "#" : text[place:end])
		place = end
	}
	return strings.to_string(builder)
}

// The line that the kernel writes before a report when the line before it
// is cut: it is no report.
OPERATION_REPORT_CUT_LINE :: "kernel: the line above is cut"

// operation_report_line gives the last line of the log that the kernel
// wrote for itself, which is the report of a stop: the kernel writes no
// line after it. A line of a program starts with its name in brackets.
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
// exception, which the kernel writes as 16 hexadecimal digits.
OPERATION_REPORT_ADDRESS_MARK :: " at "
OPERATION_REPORT_ADDRESS_DIGITS :: 16

// operation_report_procedure names the procedure of the kernel at the
// address of a report, from the debug object of the kernel of the volume.
// The texts hold no number, because the signature holds them.
operation_report_procedure :: proc(report: string, kernel_object: []u8) -> string {
	at := strings.index(report, OPERATION_REPORT_ADDRESS_MARK)
	if at < 0 {
		return "no address"
	}
	digits := report[at + len(OPERATION_REPORT_ADDRESS_MARK):]
	if len(digits) < OPERATION_REPORT_ADDRESS_DIGITS {
		return "no address"
	}
	address: u64
	for character in transmute([]u8)digits[:OPERATION_REPORT_ADDRESS_DIGITS] {
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

// The starts of the lines of the kernel when a program that a sequence
// must never reach stops.
@(rodata)
operation_isolation_marks := [?]string{"kernel: program " + OPERATION_FUZZING_MODULE + " stopped", "kernel: program root stopped"}

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
	// check read.
	execute: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault,
	// Ends the machine, whatever its state.
	end:     proc(data: rawptr),
}

// operation_sequence_encode writes a sequence, then reads the bytes back
// with check: the bytes are what a machine gets, and a sequence that check
// refuses gives none.
operation_sequence_encode :: proc(sequence: ^operation_sequence.Sequence, allocator := context.allocator) -> (bytes: []u8, accepted: bool) {
	size, sized := operation_sequence.size(sequence)
	if !sized {
		return nil, false
	}
	bytes = make([]u8, size, allocator)
	read_back := new(operation_sequence.Sequence)
	defer free(read_back)
	if _, written := operation_sequence.write(bytes, sequence); !written || operation_sequence.check(bytes, read_back).problem != .None {
		delete(bytes, allocator)
		return nil, false
	}
	return bytes, true
}

Operation_Life_Outcome :: struct {
	booted:   bool,
	fault:    Operation_Fault,
	faulting: int, // The place in the life of the sequence of the fault; -1 with no fault.
}

// operation_life_run runs a life on a new machine, up to its first fault,
// then ends the machine.
operation_life_run :: proc(machine: ^Operation_Machine, life: [][]u8) -> (outcome: Operation_Life_Outcome) {
	outcome.faulting = -1
	for _ in 0 ..< OPERATION_BOOT_TRIES {
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
		if fault := machine.execute(machine.data, sequence, bytes); fault.kind != .None {
			outcome.fault = fault
			outcome.faulting = place
			return outcome
		}
	}
	return outcome
}

// ---------------------------------------------------------------------
// The minimization.

Operation_Minimized :: struct {
	life:       [][]u8, // In the allocator of the context.
	machines:   int,    // The machines that the minimization booted.
	reproduced: bool,   // The fault came again on a new machine; else the life is the life of the run.
	booted:     bool,   // false: two boots in a row did not reach the mailbox, and the minimization stopped.
}

@(private = "file")
Operation_Minimizer :: struct {
	machine:   ^Operation_Machine,
	signature: string,
	machines:  int,
	booted:    bool,
}

// operation_life_holds runs a candidate life on a new machine. It holds
// when its last sequence gives the fault of the signature: a fault at an
// earlier sequence does not hold, so the last sequence stays the one of the
// fault. Past the bound of the machines no try holds. The temporary memory
// is freed after each try: a minimization boots up to
// OPERATION_MINIMIZE_MACHINES_MOST machines, and each execution uses some.
@(private = "file")
operation_life_holds :: proc(minimizer: ^Operation_Minimizer, life: [][]u8) -> bool {
	if !minimizer.booted || minimizer.machines >= OPERATION_MINIMIZE_MACHINES_MOST {
		return false
	}
	minimizer.machines += 1
	outcome := operation_life_run(minimizer.machine, life)
	holds := outcome.booted && outcome.faulting == len(life) - 1 && outcome.fault.signature == minimizer.signature
	if !outcome.booted {
		minimizer.booted = false
	}
	free_all(context.temp_allocator)
	return holds
}

// operation_fault_minimize gives the smallest life that still gives the
// fault of the signature at its last sequence: the last sequence alone, or
// the whole life; then the sequences before the last, by ranges; then the
// steps of the last sequence, by ranges
// (src/md/infrastructure/kernel_fuzzing.md, "The loop and the speed"). It
// frees the temporary memory after each machine: the caller keeps nothing
// there.
operation_fault_minimize :: proc(machine: ^Operation_Machine, life: [][]u8, signature: string) -> (minimized: Operation_Minimized) {
	minimizer := Operation_Minimizer{machine = machine, signature = signature, booted = true}
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
	minimized.machines = minimizer.machines
	minimized.booted = minimizer.booted
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
// plain value 0; one that names a later step names it at its new place. The
// new first step joins no earlier kernel entry.
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
			if bytes, accepted := operation_sequence_encode(candidate); accepted {
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
Operation_Generator :: #type proc(random: ^Fuzz_Random, sequence: ^operation_sequence.Sequence)

Operation_Run_Bounds :: struct {
	executions:     u64,
	life_sequences: int, // The sequences of one machine life, at most.
	findings_most:  int, // The kept faults that end the run.
}

Operation_Kept_Fault :: struct {
	fault:     Operation_Fault, // In the allocator of the context.
	life:      [][]u8,          // The life up to the fault, as the run gave it.
	minimized: Operation_Minimized,
	execution: u64, // The number of the execution of the fault, from 1.
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
// keeps it in the run only.
Operation_Fault_Keeper :: #type proc(kept: ^Operation_Kept_Fault, seed: u64)

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

// operation_fuzzing_loop runs generated sequences on machines, one machine
// at a time, until the count of executions, the bound of the findings, or
// two boots in a row with no mailbox. A machine life ends at its bound of
// sequences or at a fault; a fault with a new signature is minimized and
// kept, a fault with a known one is only counted. ok is false at an error
// of the build or of the tool. The loop frees the temporary memory after
// each execution: the caller keeps nothing there.
operation_fuzzing_loop :: proc(machine: ^Operation_Machine, generate: Operation_Generator, seed: u64, bounds: Operation_Run_Bounds, keeper: Operation_Fault_Keeper = nil) -> (run: Operation_Run, ok: bool) {
	random := Fuzz_Random{state = seed}
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
		generate(&random, generated)
		bytes, accepted := operation_sequence_encode(generated)
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
		if fault.kind == .None {
			if len(life) >= bounds.life_sequences {
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
		if keeper != nil {
			keeper(&run.kept[len(run.kept) - 1], seed)
		}
		free_all(context.temp_allocator)
		if !kept.minimized.booted {
			fmt.eprintfln("modustool: fuzz operations: %d machines in a row did not reach the line \"%s\" during a minimization: an error of the build, not a finding", OPERATION_BOOT_TRIES, OPERATION_MAILBOX_LINE)
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
// check: each sequence that it builds is one that check accepts.
operation_sequence_generate_random :: proc(random: ^Fuzz_Random, sequence: ^operation_sequence.Sequence) {
	choice_bytes: [OPERATION_CHOICE_BYTES]u8
	for place := 0; place < len(choice_bytes); place += 8 {
		word := fuzz_random_next(random)
		for index in 0 ..< 8 {
			choice_bytes[place + index] = u8(word >> (8 * u64(index)))
		}
	}
	choices := fuzz_choices_of(choice_bytes[:])
	fuzz_operation_sequence_generate(&choices, sequence)
}

// ---------------------------------------------------------------------
// The findings in the build folder.

// operation_life_write writes each sequence of a life in a folder, in its
// order, after it removed the files of an earlier run.
@(private = "file")
operation_life_write :: proc(folder: string, life: [][]u8) -> bool {
	_ = os.remove_all(folder)
	if !make_folder(folder) {
		return false
	}
	for bytes, place in life {
		path := fmt.tprintf("%s/sequence_%04d", folder, place)
		if error := os.write_entire_file(path, bytes); error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", path, error)
			return false
		}
	}
	return true
}

// operation_fault_write writes a kept fault in its folder, named by the
// start of the hash of its signature, and prints where it is.
operation_fault_write :: proc(kept: ^Operation_Kept_Fault, seed: u64) {
	name := fuzz_input_name(transmute([]u8)kept.fault.signature)
	folder := fmt.tprintf("%s/%s", OPERATION_FINDINGS_FOLDER, name[:OPERATION_FINDING_NAME_DIGITS])
	if !make_folder(folder) || !operation_life_write(fmt.tprintf("%s/life", folder), kept.life) || !operation_life_write(fmt.tprintf("%s/minimized", folder), kept.minimized.life) {
		return
	}
	minimized := kept.minimized.life
	last := new(operation_sequence.Sequence)
	defer free(last)
	steps := -1
	if len(minimized) > 0 && operation_sequence.check(minimized[len(minimized) - 1], last).problem == .None {
		steps = last.step_count
	}
	summary := kept.minimized.reproduced ? fmt.tprintf("minimized to %d sequences, %d steps in the last one, with %d machines", len(minimized), steps, kept.minimized.machines) : fmt.tprintf("the fault did not come again on a new machine, in %d machines: the life is kept whole", kept.minimized.machines)
	text := fmt.tprintf("%s\n%s\nthe seed %d, the execution %d, the machine life %d of %d sequences\n%s\n", kept.fault.signature, kept.fault.text, seed, kept.execution, kept.life_number, len(kept.life), summary)
	_ = os.write_entire_file(fmt.tprintf("%s/finding.txt", folder), transmute([]u8)text)
	if kept.fault.log != "" {
		_ = os.write_entire_file(fmt.tprintf("%s/machine_log.txt", folder), transmute([]u8)kept.fault.log)
	}
	fmt.eprintfln("modustool:   %s", kept.fault.text)
	fmt.eprintfln("modustool:   %s: %s", summary, folder)
	if len(minimized) == 1 {
		fmt.eprintfln("modustool:   `modustool fuzz replay operations %s/minimized/sequence_0000` runs it again", folder)
	}
}

// ---------------------------------------------------------------------
// The machine of the operation sequences under QEMU.

@(private = "file")
Operation_Qemu :: struct {
	part:          Test_Part_Run, // Its data disk, which no program of the image drives.
	peer:          Peer,
	process:       os.Process,
	monitor_read:  ^os.File,
	monitor_write: ^os.File,
	mailbox:       Operation_Mailbox,
	mailbox_open:  bool,
	running:       bool,
	exited:        bool, // QEMU ended, and the tool read the state of its end.
	log_scanned:   i64,  // The bytes of the log whose whole lines the tool read.
	grammar:       Operation_Grammar,
	kernel_object: []u8, // The debug object of the kernel of the volume, or nil.
	header:        ^operation_sequence.Mailbox_Header,
	results:       ^operation_sequence.Runner_Results,
}

// operation_log_new_lines gives the whole lines that the machine wrote
// since the last read: a check after each execution reads only them.
@(private = "file")
operation_log_new_lines :: proc(state: ^Operation_Qemu) -> string {
	information, stat_error := os.stat(OPERATION_FUZZING_OUTPUT, context.temp_allocator)
	if stat_error != nil || information.size <= state.log_scanned {
		return ""
	}
	file, open_error := os.open(OPERATION_FUZZING_OUTPUT, {.Read})
	if open_error != nil {
		return ""
	}
	defer os.close(file)
	bytes := make([]u8, information.size - state.log_scanned, context.temp_allocator)
	count, _ := os.read_at(file, bytes, state.log_scanned)
	if count <= 0 {
		return ""
	}
	text := string(bytes[:count])
	whole := strings.last_index_byte(text, '\n') + 1
	state.log_scanned += i64(whole)
	return text[:whole]
}

@(private = "file")
operation_log_whole :: proc() -> string {
	bytes, error := os.read_entire_file(OPERATION_FUZZING_OUTPUT, context.temp_allocator)
	if error != nil {
		return ""
	}
	return string(bytes)
}

// operation_machine_kernel_object reads the debug object of the kernel of
// the volume, which names the procedure of the address of a report.
operation_machine_kernel_object :: proc() -> []u8 {
	for row in boot_volumes() {
		if row.path != BOOT_VOLUME_OPERATION_SEQUENCES || row.kernel == "" {
			continue
		}
		object, error := os.read_entire_file(debug_object_path(row.kernel), context.allocator)
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
	command, made := machine_command(BOOT_VOLUME_OPERATION_SEQUENCES, OPERATION_FUZZING_OUTPUT, state.part.data_disk, &state.peer, clock_argument = clock.argument, memory_file = OPERATION_FUZZING_MEMORY_FILE)
	if !made {
		return false
	}
	monitor_read, monitor_write, pipe_error := os.pipe()
	if pipe_error != nil {
		peer_machine_socket_lent_close(&state.peer)
		fmt.eprintfln("modustool: cannot create a pipe: %v", pipe_error)
		return false
	}
	process, start_error := os.process_start({command = command, stdin = monitor_read, stderr = os.stderr})
	// QEMU has its copy of the socket of the peer now.
	peer_machine_socket_lent_close(&state.peer)
	if start_error != nil {
		os.close(monitor_write)
		os.close(monitor_read)
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	state.process = process
	state.monitor_read, state.monitor_write = monitor_read, monitor_write
	state.running, state.exited, state.mailbox_open, state.log_scanned = true, false, false, 0
	for started := time.tick_now(); time.tick_since(started) < BOOT_HANG_BOUND; {
		if address, found := number_after(operation_log_new_lines(state), OPERATION_MAILBOX_LINE); found {
			mailbox, problem := operation_mailbox_open(OPERATION_FUZZING_MEMORY_FILE, address)
			if problem != "" {
				fmt.eprintfln("modustool: fuzz operations: %s", problem)
				operation_machine_end(state)
				return false
			}
			state.mailbox, state.mailbox_open = mailbox, true
			return true
		}
		if ended, wait_error := os.process_wait(process, 0); wait_error == nil && ended.exited {
			state.exited = true
			fmt.eprintfln("modustool: fuzz operations: QEMU ended with the status %d before the line \"%s\"; the log is %s", ended.exit_code, OPERATION_MAILBOX_LINE, OPERATION_FUZZING_OUTPUT)
			operation_machine_end(state)
			return false
		}
		time.sleep(FUZZ_POLL_INTERVAL)
	}
	fmt.eprintfln("modustool: fuzz operations: the machine wrote no line \"%s\" within %v; the log is %s", OPERATION_MAILBOX_LINE, BOOT_HANG_BOUND, OPERATION_FUZZING_OUTPUT)
	operation_machine_end(state)
	return false
}

// operation_machine_execute runs one sequence and reads its fault: the
// stop of QEMU, a stall, a broken mailbox, the stop of a program that no
// sequence reaches, then the oracles of the results.
@(private = "file")
operation_machine_execute :: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault {
	state := (^Operation_Qemu)(data)
	end, ended, problem := operation_execute_watched(&state.mailbox, bytes, state.header, state.results, &state.process)
	switch end {
	case .Counted:
	case .Machine_Ended:
		state.exited = true
		log := operation_log_whole()
		signature, text := operation_stop_signature(ended.exit_code, log, state.kernel_object)
		return {kind = .Stop, signature = signature, text = text, log = log}
	case .Stalled:
		log := operation_log_whole()
		if line := operation_isolation_line(log); line != "" {
			return operation_isolation_fault(line, log)
		}
		return {kind = .Hang, signature = operation_hang_signature(sequence, operation_runner_step_started(&state.mailbox)), text = problem, log = log}
	case .Mailbox_Broken:
		return {kind = .Mailbox, signature = "mailbox: the counts of the mailbox are not the counts that the tool wrote", text = problem, log = operation_log_whole()}
	}
	if line := operation_isolation_line(operation_log_new_lines(state)); line != "" {
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
		ended, wait_error := os.process_wait(state.process, HANG_BOUND)
		if wait_error != nil || !ended.exited {
			_ = os.process_kill(state.process)
			_, _ = os.process_wait(state.process)
		}
		state.exited = true
	}
	os.close(state.monitor_write)
	os.close(state.monitor_read)
	_ = os.remove(OPERATION_FUZZING_MEMORY_FILE)
	state.running = false
}

// operation_fuzzing_run is `fuzz operations <executions> [<seed>]`
// (docs/TOOLS.md, "The fuzzing of the kernel operations").
operation_fuzzing_run :: proc(args: []string) -> int {
	arguments, problem := operation_fuzzing_arguments_read(args)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return EXIT_USAGE
	}
	seed := arguments.seed
	if !arguments.seed_given {
		seed = fuzz_sources_seed() ~ u64(time.time_to_unix_nano(time.now()))
	}
	if !fuzz_operation_sequence_start() {
		return EXIT_FAILURE
	}
	grammar, grammar_read := operation_grammar_read()
	if !grammar_read {
		return EXIT_FAILURE
	}
	if code := build_system(boot_volumes_of_command(OPERATION_FUZZING_COMMAND)); code != 0 {
		return code
	}
	if !make_folder(OPERATION_FUZZING_FOLDER) {
		return EXIT_FAILURE
	}
	state := new(Operation_Qemu)
	defer free(state)
	state.grammar = grammar
	state.header = new(operation_sequence.Mailbox_Header)
	defer free(state.header)
	state.results = new(operation_sequence.Runner_Results)
	defer free(state.results)
	state.kernel_object = operation_machine_kernel_object()
	defer delete(state.kernel_object)
	if state.kernel_object == nil {
		fmt.println("modustool: fuzz operations: no debug object of the kernel: a signature of a stop names no procedure")
	}
	state.part = test_part_run_make(OPERATION_FUZZING_COMMAND)
	defer test_part_run_free(&state.part)
	if !test_part_run_start(&state.part) || !peer_start(&state.peer) {
		return EXIT_FAILURE
	}
	defer peer_stop(&state.peer)
	defer {
		_ = os.remove(machine_file(OPERATION_FUZZING_OUTPUT, SCRATCH_DISK_SUFFIX))
		_ = os.remove(machine_file(OPERATION_FUZZING_OUTPUT, FIRMWARE_VARIABLES_SUFFIX))
	}
	machine := Operation_Machine{data = state, start = operation_machine_start, execute = operation_machine_execute, end = operation_machine_end}
	fmt.printfln("modustool: fuzz operations: %d executions from the seed %d, one machine at a time, at most %d sequences in a machine life", arguments.executions, seed, OPERATION_MACHINE_SEQUENCES_MOST)
	run_started := time.tick_now()
	bounds := Operation_Run_Bounds{executions = arguments.executions, life_sequences = OPERATION_MACHINE_SEQUENCES_MOST, findings_most = OPERATION_FINDINGS_MOST}
	run, completed := operation_fuzzing_loop(&machine, operation_sequence_generate_random, seed, bounds, operation_fault_write)
	defer operation_run_free(&run)
	run_seconds := time.duration_seconds(time.tick_since(run_started))
	sequence_seconds := time.duration_seconds(run.sequence_time)
	fmt.printfln("modustool: measure: fuzz operations: %d executions in %d machine lives; %.1f executions in one second of the sequences (%.1f s), %.1f in one second of the whole run with the boots and the minimizations (%.1f s, the boots of the lives %.1f s)", run.executions, run.lives, sequence_seconds > 0 ? f64(run.executions) / sequence_seconds : 0, sequence_seconds, run_seconds > 0 ? f64(run.executions) / run_seconds : 0, run_seconds, time.duration_seconds(run.boot_time))
	fmt.printfln("modustool: fuzz operations: %d faults of the kernel, %d signatures kept in %s%s", run.faults, len(run.kept), OPERATION_FINDINGS_FOLDER, run.ended_by_findings ? fmt.tprintf("; the run ended at %d findings", OPERATION_FINDINGS_MOST) : "")
	for kept in run.kept {
		fmt.printfln("modustool:   %s", kept.fault.signature)
	}
	if !completed {
		return EXIT_FAILURE
	}
	// The data disk of a run that ended stays only when the run failed.
	state.part.passed = len(run.kept) == 0
	return len(run.kept) == 0 ? 0 : EXIT_FAILURE
}
