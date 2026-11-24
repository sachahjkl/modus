// The registers of the vector unit of each thread, which the kernel keeps
// apart. The design: docs/ARCHITECTURE.md, "The extended state of the
// processor".
//
// The process starts as many threads as the machine has processors, plus
// two, so that threads share processors and move between them. Each thread
// fills every register of the widest level that it can use (zmm0 to zmm31
// and k0 to k7, or ymm0 to ymm15, or xmm0 to xmm15), the x87 stack, the x87
// control word and MXCSR with a pattern of its own, new at each pass; then
// it spins, enters the kernel, and gives its processor away, many times;
// then it compares each register with its pattern. A wrong bit is a failed
// check that names the thread, the register and the pass.
//
// Each thread also checks the start state that the kernel gave it: the high
// halves of its ymm and zmm registers and its opmask registers are zero, the
// x87 control word is 0x037F and MXCSR is 0x1F80. A kernel that did not save
// the high halves would give a new thread the registers of another thread.
//
// Then the main thread measures one empty kernel entry with each level of
// registers in use.
//
// **What it is for.** The kernel keeps the [extended state](term:extended-state)
// of each thread (the vector registers, the x87 and MXCSR) and saves it
// only at a [switch of threads](term:switch-of-threads). A fault there
// leaks the registers of one process into another, or changes the result
// of a computation in silence. This process puts that work under load,
// with a pattern in each register, and checks every bit.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("extended_state")` in the console. The window shows the level of
// registers that the threads use, the threads, the passes and the checks.
// The log gets `extended_state: ok, <count> threads on <count> processors,
// <count> passes, <count> kernel entries ...`, or `extended_state: failed:
// <count> wrong registers after a pass, <count> parts of a start state
// wrong`, then the cost of one empty kernel entry with each level.
//
// **Its grants**: none. Its budget holds 32 threads: the main thread and
// up to 31 threads that hold their registers.
//
// **What it does not prove.** The widest level that it uses is the level
// of the processor of the run: under QEMU with no AVX-512, the zmm and k
// registers are not checked. The rules are in docs/SIMD.md.
package extended_state

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:display"
import "modus:graphics"
import sets "modus:instruction_sets"
import "modus:interface"
import "modus:contract/value_kinds"
import "modus:system"

// The main thread and up to 31 threads that hold their registers: 928
// pages. And the glyph memory of the copy of the text rendering of the
// drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 928 + 354 = 1282.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1282, processes = 1, threads = 32, window_width = WIDTH, window_height = HEIGHT}

LINE :: interface.TABLE_LINE
WIDTH :: 1000 // The window and its borders fit the window bound of 1024 columns.
HEIGHT :: 704 // And its 768 lines, under the bar and the title of the window.
WORKER_CAPACITY :: 31 // A process has 32 threads at most: the main thread and these. Its budget has 32.
RUN_MILLISECONDS :: 3000 // How long the threads hold their registers.
ROUNDS :: 16 // Kernel entries in one pass: above the round where the x87 control word changes alone (registers.asm).
SPINS :: 20_000 // Loops between two entries: the timer interrupts some of them.
MEASURE_ENTRIES :: 100_000
LOG_WRONG_LIMIT :: 16 // Lines of wrong registers on the log, for all threads.

// The registers of one pass: the layout of registers.asm.
Register_Image :: struct #align (64) {
	vectors:     [32][64]u8, // Register n at n * 64: xmm uses 16 bytes, ymm 32, zmm 64.
	opmasks:     [8]u64, // kmovw: the low 16 bits; kmovq: all 64.
	x87:         [8]i64, // In the order of the loads: the last is the top of the stack.
	// The x87 control word and MXCSR: the first values are loaded at the
	// start of a pass; in the middle of the pass each one changes alone to
	// its second value, which is the one expected at the end.
	x87_control:       u16,
	x87_control_first: u16,
	mxcsr:             u32,
	mxcsr_first:       u32,
}
#assert(offset_of(Register_Image, opmasks) == 2048)
#assert(offset_of(Register_Image, x87) == 2112)
#assert(offset_of(Register_Image, x87_control) == 2176)
#assert(offset_of(Register_Image, x87_control_first) == 2178)
#assert(offset_of(Register_Image, mxcsr) == 2180)
#assert(offset_of(Register_Image, mxcsr_first) == 2184)

Level :: enum u64 {
	Sse     = 0, // xmm0 to xmm15
	Avx     = 1, // ymm0 to ymm15
	Avx_512 = 2, // zmm0 to zmm31, k0 to k7 (16 bits of each: AVX-512 F)
	Avx_512_With_Wide_Opmasks = 3, // The same, 64 bits of each opmask (AVX-512 BW)
}

@(rodata)
level_names := [Level]string {
	.Sse     = "xmm0 to xmm15",
	.Avx     = "ymm0 to ymm15",
	.Avx_512 = "zmm0 to zmm31 and k0 to k7 (16 bits)",
	.Avx_512_With_Wide_Opmasks = "zmm0 to zmm31 and k0 to k7 (64 bits)",
}

foreign _ {
	registers_hold :: proc "c" (expected, seen: ^Register_Image, level: Level, rounds, spins: u64) ---
	registers_store :: proc "c" (seen: ^Register_Image, level: Level) ---
	registers_enter_repeatedly :: proc "c" (expected: ^Register_Image, level: Level, count: u64) ---
	// The parts of a save and a restore, each alone (registers.asm): the cycles of the
	// cycle counter for `count` loops on the area.
	registers_upper_halves_in_use :: proc "c" (expected: ^Register_Image) ---
	registers_upper_halves_clean :: proc "c" () ---
	measure_loop_alone :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxsave_and_fxrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_vzeroupper_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_vzeroupper_and_xrstor_with_avx :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsave_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_vzeroupper :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxsave :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
}

// The parts of a save and a restore that the process measures alone, on its own
// area, with the mask of the kernel. Not privileged instructions: the kernel
// is not changed for the measure.
Part :: enum {
	Loop_Alone,
	Fxsave_And_Fxrstor,
	Xsaveopt_And_Xrstor,
	Xsaveopt_Vzeroupper_And_Xrstor,
	Xsaveopt_Vzeroupper_And_Xrstor_With_Avx,
	Xsave_And_Xrstor,
	Fxsave,
	Fxrstor,
	Xsaveopt,
	Xrstor,
	Vzeroupper,
}

@(rodata)
part_names := [Part]string {
	.Loop_Alone                              = "the loop",
	.Fxsave_And_Fxrstor                      = "fxsave64 + fxrstor64",
	.Xsaveopt_And_Xrstor                     = "xsaveopt64 + xrstor64",
	.Xsaveopt_Vzeroupper_And_Xrstor          = "xsaveopt64 + vzeroupper + xrstor64",
	.Xsaveopt_Vzeroupper_And_Xrstor_With_Avx = "the same with ymm in use",
	.Xsave_And_Xrstor                        = "xsave64 + xrstor64",
	.Fxsave                                  = "fxsave64",
	.Fxrstor                                 = "fxrstor64",
	.Xsaveopt                                = "xsaveopt64",
	.Xrstor                                  = "xrstor64",
	.Vzeroupper                              = "vzeroupper",
}

Part_Measure :: #type proc "c" (area: rawptr, count: u64) -> u64

// part_measure gives the routine of a part. A procedure, not a table: a
// global whose initializer is not a constant is not initialized.
part_measure :: proc "contextless" (part: Part) -> Part_Measure {
	switch part {
	case .Loop_Alone:
		return measure_loop_alone
	case .Fxsave_And_Fxrstor:
		return measure_fxsave_and_fxrstor
	case .Xsaveopt_And_Xrstor:
		return measure_xsaveopt_and_xrstor
	case .Xsaveopt_Vzeroupper_And_Xrstor:
		return measure_xsaveopt_vzeroupper_and_xrstor
	case .Xsaveopt_Vzeroupper_And_Xrstor_With_Avx:
		return measure_xsaveopt_vzeroupper_and_xrstor_with_avx
	case .Xsave_And_Xrstor:
		return measure_xsave_and_xrstor
	case .Fxsave:
		return measure_fxsave
	case .Fxrstor:
		return measure_fxrstor
	case .Xsaveopt:
		return measure_xsaveopt
	case .Xrstor:
		return measure_xrstor
	case .Vzeroupper:
		return measure_vzeroupper
	}
	return measure_loop_alone
}

PART_LOOPS :: 100_000
PART_RUNS :: 5 // The least of the runs: the others had an interrupt or a switch.

Part_Area :: struct #align (64) {
	bytes: [4096]u8,
}
part_area: Part_Area
// The cycles of the cycle counter for one loop of each part, in tenths. 0:
// the processor or the kernel does not give the instructions of that part.
part_tenths: [Part]u64

Register_Kind :: enum u8 {
	Vector, // xmm, ymm or zmm, by the level.
	Opmask,
	X87, // A register of the x87 stack, by its load.
	X87_Control,
	Mxcsr,
}

// One thread of the test. The thread writes its counts with atomic stores;
// the main thread reads them.
Worker :: struct {
	number:            u32,
	thread:            system.Thread,
	passes:            u64,
	entries:           u64,
	wrong_registers:   u64,
	start_state_wrong: u64, // Parts of the start state that were not the start state.
	start_state_done:  bool,
	done:              bool,
	// The registers of each vector register, for the window: 1 when that
	// register was wrong once.
	wrong_vectors:     u32,
	wrong_others:      u8, // Bit n: Register_Kind n other than Vector was wrong once.
	expected:          Register_Image,
	seen:              Register_Image,
}

workers: [WORKER_CAPACITY]Worker
worker_count: int
processor_count: u32
held_level: Level // The widest registers that the threads hold.
usable: sets.Instruction_Sets
facts: sets.Processor_Facts
start_time: u64
wrong_lines: u64 // The lines of wrong registers on the log, for all threads (atomic).
entry_nanoseconds: [Level]u64 // 0: not measured (the level is not usable).
finished: bool
passed: bool

window_memory: interface.Window_Memory(1024, 16384)

// mix gives 64 bits from a number: the finalizer of splitmix64.
mix :: proc "contextless" (value: u64) -> u64 {
	z := value + 0x9E37_79B9_7F4A_7C15
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// pattern_fill writes the pattern of one thread for one pass. Each byte
// depends on the thread, the pass and the place: a register that came from
// another thread or from another pass differs.
pattern_fill :: proc "contextless" (image: ^Register_Image, thread: u32, pass: u64) {
	// The places use the low 24 bits: the thread and the pass are above them.
	seed := u64(thread) << 56 ~ pass << 24
	for &register, index in image.vectors {
		for part in 0 ..< 8 {
			value := mix(seed ~ u64(index) << 3 ~ u64(part))
			(^u64)(&register[part * 8])^ = value
		}
	}
	for &value, index in image.opmasks {
		value = mix(seed ~ 0x1_0000 ~ u64(index))
	}
	for &value, index in image.x87 {
		value = i64(mix(seed ~ 0x2_0000 ~ u64(index)))
		if value == min(i64) {
			value = 1 // min(i64) is the "integer indefinite" of fistp.
		}
	}
	turn := u64(thread) + pass
	// Only the rounding control changes: every exception stays masked.
	image.x87_control_first = 0x037F | u16(turn & 3) << 10
	image.mxcsr_first = 0x1F80 | u32(turn & 3) << 13 | u32(thread & 1) << 15 // Rounding control; flush to zero.
	// The second values: another rounding control, the rest the same.
	image.x87_control = image.x87_control_first ~ 1 << 10
	image.mxcsr = image.mxcsr_first ~ 1 << 13
}

vector_width :: proc "contextless" (level: Level) -> int {
	switch level {
	case .Sse:
		return 16
	case .Avx:
		return 32
	case .Avx_512, .Avx_512_With_Wide_Opmasks:
		return 64
	}
	return 16
}

vector_count :: proc "contextless" (level: Level) -> int {
	return level >= .Avx_512 ? 32 : 16
}

// opmask_mask gives the bits of each opmask register that the test moves:
// kmovw moves 16, kmovq 64.
opmask_mask :: proc "contextless" () -> u64 {
	return held_level == .Avx_512_With_Wide_Opmasks ? max(u64) : 0xFFFF
}

register_name :: proc "contextless" (builder: ^interface.Text_Builder, kind: Register_Kind, index: int) -> string {
	builder.count = 0
	switch kind {
	case .Vector:
		interface.text_put(builder, held_level >= .Avx_512 ? "zmm" : (held_level == .Avx ? "ymm" : "xmm"))
		interface.text_put_number(builder, u64(index))
	case .Opmask:
		interface.text_put(builder, "k")
		interface.text_put_number(builder, u64(index))
	case .X87:
		interface.text_put(builder, "x87 load ")
		interface.text_put_number(builder, u64(index))
	case .X87_Control:
		interface.text_put(builder, "the x87 control word")
	case .Mxcsr:
		interface.text_put(builder, "MXCSR")
	}
	return interface.text_of(builder)
}

// wrong_note counts one wrong register and logs the first ones.
wrong_note :: proc "contextless" (worker: ^Worker, kind: Register_Kind, index: int, pass: u64, expected, found: u64, what: string) {
	worker.wrong_registers += 1
	if kind == .Vector {
		worker.wrong_vectors |= 1 << u32(index)
	} else {
		worker.wrong_others |= 1 << u8(kind)
	}
	if intrinsics.atomic_add(&wrong_lines, 1) < LOG_WRONG_LIMIT {
		name: interface.Text_Builder
		system.log_fact(.Info, Register_Wrong{thread_number = u64(worker.number), pass = pass, expected = value_kinds.Hexadecimal_Sixteen_Digits(expected), found = value_kinds.Hexadecimal_Sixteen_Digits(found), register = value_kinds.text_field(register_name(&name, kind, index), 24), moment = value_kinds.text_field(what, 24)})
	}
}

// pass_compare compares what the registers held after a pass with what the
// thread loaded.
pass_compare :: proc "contextless" (worker: ^Worker, pass: u64) {
	expected := &worker.expected
	seen := &worker.seen
	width := vector_width(held_level)
	for index in 0 ..< vector_count(held_level) {
		for part in 0 ..< width / 8 {
			want := (^u64)(&expected.vectors[index][part * 8])^
			got := (^u64)(&seen.vectors[index][part * 8])^
			if want != got {
				wrong_note(worker, .Vector, index, pass, want, got, "pass")
				break
			}
		}
	}
	if held_level >= .Avx_512 {
		mask := opmask_mask()
		for index in 0 ..< 8 {
			if expected.opmasks[index] & mask != seen.opmasks[index] & mask {
				wrong_note(worker, .Opmask, index, pass, expected.opmasks[index] & mask, seen.opmasks[index] & mask, "pass")
			}
		}
	}
	for index in 0 ..< 8 {
		if expected.x87[index] != seen.x87[index] {
			wrong_note(worker, .X87, index, pass, u64(expected.x87[index]), u64(seen.x87[index]), "pass")
		}
	}
	if expected.x87_control != seen.x87_control {
		wrong_note(worker, .X87_Control, 0, pass, u64(expected.x87_control), u64(seen.x87_control), "pass")
	}
	if expected.mxcsr != seen.mxcsr {
		wrong_note(worker, .Mxcsr, 0, pass, u64(expected.mxcsr), u64(seen.mxcsr), "pass")
	}
}

// start_state_check compares the registers of a new thread with the start
// state of the kernel. The low 16 bytes of the vector registers are not
// checked: the compiled code of the thread used them before this point.
start_state_check :: proc "contextless" (worker: ^Worker) {
	seen := &worker.seen
	seen^ = {}
	// Not zero, so that a register that the store does not write is seen.
	for &register in seen.vectors {
		for &place in register {
			place = 0xA5
		}
	}
	for &value in seen.opmasks {
		value = 0xA5A5_A5A5_A5A5_A5A5
	}
	registers_store(seen, held_level)
	wrong: u64
	note :: proc "contextless" (worker: ^Worker, wrong: ^u64, kind: Register_Kind, index: int, expected, found: u64) {
		wrong^ += 1
		wrong_note(worker, kind, index, 0, expected, found, "start state, pass")
	}
	if held_level != .Sse {
		for index in 0 ..< vector_count(held_level) {
			first := index < 16 ? 16 : 0 // zmm16 to zmm31 have no part that SSE code uses.
			for part in first / 8 ..< vector_width(held_level) / 8 {
				if value := (^u64)(&seen.vectors[index][part * 8])^; value != 0 {
					note(worker, &wrong, .Vector, index, 0, value)
					break
				}
			}
		}
	}
	if held_level >= .Avx_512 {
		for index in 0 ..< 8 {
			if value := seen.opmasks[index] & opmask_mask(); value != 0 {
				note(worker, &wrong, .Opmask, index, 0, value)
			}
		}
	}
	if seen.x87_control != 0x037F {
		note(worker, &wrong, .X87_Control, 0, 0x037F, u64(seen.x87_control))
	}
	if seen.mxcsr != 0x1F80 {
		note(worker, &wrong, .Mxcsr, 0, 0x1F80, u64(seen.mxcsr))
	}
	intrinsics.atomic_store(&worker.start_state_wrong, wrong)
	intrinsics.atomic_store(&worker.start_state_done, true)
}

// worker_run is the entry of each thread of the test.
worker_run :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	start_state_check(worker)
	pass: u64 = 1
	for {
		pattern_fill(&worker.expected, worker.number, pass)
		worker.seen = {}
		registers_hold(&worker.expected, &worker.seen, held_level, ROUNDS, SPINS)
		pass_compare(worker, pass)
		intrinsics.atomic_store(&worker.passes, pass)
		intrinsics.atomic_add(&worker.entries, ROUNDS)
		if system.time() - start_time >= RUN_MILLISECONDS {
			break
		}
		pass += 1
	}
	intrinsics.atomic_store(&worker.done, true)
	system.thread_stop()
}

// part_usable says if this process can run the instructions of a part:
// xsave, xsaveopt and xrstor need CR4.OSXSAVE, which the kernel sets only
// when it saves with xsaveopt; vzeroupper and ymm need AVX.
part_usable :: proc "contextless" (part: Part) -> bool {
	with_xsave := facts.leaf_1_ecx & sets.LEAF_1_ECX_OSXSAVE != 0
	switch part {
	case .Loop_Alone, .Fxsave_And_Fxrstor, .Fxsave, .Fxrstor:
		// The loop and fxsave need no state past what each processor has.
	case .Xsaveopt_And_Xrstor, .Xsave_And_Xrstor, .Xsaveopt, .Xrstor:
		return with_xsave
	case .Xsaveopt_Vzeroupper_And_Xrstor, .Xsaveopt_Vzeroupper_And_Xrstor_With_Avx, .Vzeroupper:
		return with_xsave && .Avx in usable
	}
	return true
}

// parts_measure measures each part that this processor and this kernel
// give, PART_RUNS times, and keeps the least.
parts_measure :: proc "contextless" () {
	for part in Part {
		if !part_usable(part) {
			continue
		}
		least := max(u64)
		for _ in 0 ..< PART_RUNS {
			least = min(least, part_measure(part)(&part_area, PART_LOOPS))
		}
		part_tenths[part] = max(least * 10 / PART_LOOPS, 1)
	}
}

// parts_log writes one fact for each part: the parts of a save and a
// restore, then the instructions alone. A time is in hundredths, from the
// tenths that the measure keeps.
parts_log :: proc "contextless" () {
	frequency := max(system.cycle_frequency(), 1)
	for part in Part {
		name := value_kinds.text_field(part_names[part], 40)
		cycles := value_kinds.Hundredths(part_tenths[part] * 10)
		part_time := value_kinds.Hundredths(part_tenths[part] * 1_000_000_000 / frequency * 10)
		instruction := part >= .Fxsave
		switch {
		case part_tenths[part] == 0 && instruction:
			system.log_fact(.Info, Instruction_Not_Measured{part_name = name})
		case part_tenths[part] == 0:
			system.log_fact(.Info, Save_Part_Not_Measured{part_name = name})
		case instruction:
			system.log_fact(.Info, Instruction_Measured{cycles = cycles, part_time = part_time, part_name = name})
		case:
			system.log_fact(.Info, Save_Part_Measured{cycles = cycles, part_time = part_time, part_name = name})
		}
	}
}



// The hand-over between two threads: the main thread takes the even turns,
// the second thread the odd ones. Each hand-over is a wake and a wait: the
// thread that waits leaves its processor, so the kernel saves its extended
// state, and the thread that it wakes is restored where it runs. With the
// AVX component in use in both threads, each save and restore holds it.
HAND_OVER_MILLISECONDS :: 500
Hand_Over :: struct {
	turn:      u32,
	stop:      u32,
	with_avx:  bool,
	ready:     u32, // The second thread loaded its registers.
}
hand_over: Hand_Over
hand_over_image: Register_Image
// The nanoseconds of one hand-over: [0] with x87 and SSE in use, [1] with
// the AVX component in use too. 0: not measured.
hand_over_nanoseconds: [2]u64
hand_over_counts: [2]u64

// hand_over_registers puts the registers of a hand-over in use: only the
// x87 and SSE of compiled code, or the ymm high halves too.
hand_over_registers :: proc "contextless" (with_avx: bool) {
	if with_avx {
		registers_upper_halves_in_use(&hand_over_image)
	} else if .Avx in usable {
		registers_upper_halves_clean()
	}
}

hand_over_second :: proc "c" (_: rawptr) -> ! {
	hand_over_registers(hand_over.with_avx)
	intrinsics.atomic_store(&hand_over.ready, 1)
	for intrinsics.atomic_load(&hand_over.stop) == 0 {
		turn := intrinsics.atomic_load(&hand_over.turn)
		if turn % 2 == 0 {
			system.word_wait(&hand_over.turn, turn, system.time() + 100)
			continue
		}
		intrinsics.atomic_store(&hand_over.turn, turn + 1)
		system.word_wake(&hand_over.turn)
	}
	if hand_over.with_avx {
		registers_upper_halves_clean()
	}
	system.thread_stop()
}

// hand_over_measure measures one hand-over between two threads, with the
// x87 and SSE registers in use, then with the AVX component in use. It
// gives the count of hand-overs and the nanoseconds of one.
hand_over_measure :: proc "contextless" (with_avx: bool) -> (count: u64, nanoseconds: u64) {
	hand_over = {with_avx = with_avx}
	pattern_fill(&hand_over_image, 77, 1)
	thread, status := system.thread_start(hand_over_second, nil)
	if status != .Succeeded {
		return 0, 0
	}
	for intrinsics.atomic_load(&hand_over.ready) == 0 {
		intrinsics.cpu_relax()
	}
	hand_over_registers(with_avx)
	start := system.nanoseconds()
	end := system.time() + HAND_OVER_MILLISECONDS
	for system.time() < end {
		turn := intrinsics.atomic_load(&hand_over.turn)
		if turn % 2 == 1 {
			system.word_wait(&hand_over.turn, turn, system.time() + 100)
			continue
		}
		intrinsics.atomic_store(&hand_over.turn, turn + 1)
		system.word_wake(&hand_over.turn)
		count += 1
	}
	took := system.nanoseconds() - start
	if with_avx {
		registers_upper_halves_clean()
	}
	intrinsics.atomic_store(&hand_over.stop, 1)
	intrinsics.atomic_add(&hand_over.turn, 2)
	system.word_wake(&hand_over.turn, system.WAKE_ALL)
	system.thread_wait(thread)
	// Each count of this thread is two hand-overs: to the second thread and back.
	return count * 2, took / max(count * 2, 1)
}

// entry_measure measures one empty kernel entry with the registers of a
// level in use, after the threads of the test ended.
entry_measure :: proc "contextless" () {
	image: Register_Image
	pattern_fill(&image, 99, 1)
	for measured in Level {
		// The wide opmasks are the same state component: no other measure.
		if measured > held_level || measured == .Avx_512_With_Wide_Opmasks {
			break
		}
		before := system.nanoseconds()
		registers_enter_repeatedly(&image, measured, MEASURE_ENTRIES)
		entry_nanoseconds[measured] = max((system.nanoseconds() - before) / MEASURE_ENTRIES, 1)
	}
}

sets_text :: proc "contextless" (builder: ^interface.Text_Builder, chosen: sets.Instruction_Sets, from, to: sets.Instruction_Set) -> string {
	builder.count = 0
	for set in sets.Instruction_Set {
		if set >= from && set <= to && set in chosen {
			if builder.count > 0 {
				interface.text_put(builder, ", ")
			}
			interface.text_put(builder, sets.instruction_set_names[set])
		}
	}
	if builder.count == 0 {
		interface.text_put(builder, "none")
	}
	return interface.text_of(builder)
}

components_text :: proc "contextless" (builder: ^interface.Text_Builder, components: sets.State_Components) -> string {
	builder.count = 0
	interface.text_put(builder, "x87, SSE")
	if .Avx in components {
		interface.text_put(builder, ", AVX")
	}
	if sets.AVX_512_COMPONENTS <= components {
		interface.text_put(builder, ", AVX-512")
	}
	interface.text_put(builder, "; one save writes at most ")
	interface.text_put_number(builder, u64(facts.saved_area_size))
	interface.text_put(builder, " bytes")
	return interface.text_of(builder)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder

	content := interface.card(&frame, {8, 8, WIDTH - 16, 152}, "WHAT THE KERNEL SAVES", "XCR0 and CPUID, read by this process with no kernel operation", graphics.colors.kernel)
	column := interface.column_of(content)
	saved := sets.saved_components(facts)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "components", components_text(&builder, saved), graphics.colors.text, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "SSE family", sets_text(&builder, usable, .Sse, .Pclmulqdq), graphics.colors.text, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "AVX family", sets_text(&builder, usable, .Avx, .Avx512_Vl), .Avx in usable ? graphics.colors.text : graphics.colors.dim, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "general registers", sets_text(&builder, usable, .Popcnt, .Bmi2), graphics.colors.text, 168)

	// One row for each thread, one square for each register.
	builder.count = 0
	interface.text_put_number(&builder, u64(worker_count))
	interface.text_put(&builder, " threads on ")
	interface.text_put_number(&builder, u64(processor_count))
	interface.text_put(&builder, " processors hold ")
	interface.text_put(&builder, level_names[held_level])
	interface.text_put(&builder, ", the x87 stack and MXCSR")
	content = interface.card(&frame, {8, 168, WIDTH - 16, 376}, "EACH REGISTER OF EACH THREAD", interface.text_of(&builder), graphics.colors.process)
	column = interface.column_of(content)
	// A row of 16 pixels has room for a line of text. More threads than
	// 21 (a machine with more than 19 processors) get rows of 11 pixels
	// with the squares only; the log has their counts.
	with_text := worker_count * 16 <= content.height - LINE
	row_height := with_text ? 16 : 11
	square_size := with_text ? 10 : 8
	for &worker, index in workers[:worker_count] {
		if (index + 1) * row_height > content.height - LINE {
			break
		}
		row := interface.column_take(&column, row_height)
		if with_text {
			builder.count = 0
			interface.text_put(&builder, "thread ")
			interface.text_put_number(&builder, u64(worker.number))
			interface.draw_text(frame.table, row.x, row.y, interface.text_of(&builder), graphics.colors.dim)
		}
		done := intrinsics.atomic_load(&worker.done)
		x := row.x + 96
		for register in 0 ..< 32 {
			color: graphics.Color = graphics.colors.not_usable
			if register < vector_count(held_level) {
				color = worker.wrong_vectors & (1 << u32(register)) != 0 ? graphics.colors.failed : (done ? graphics.colors.process : graphics.colors.track)
			}
			interface.mark(&frame, x + register * (square_size + 2), row.y + 2, square_size, color)
		}
		x += 32 * (square_size + 2) + 8
		others := [?]Register_Kind{.Opmask, .X87, .X87_Control, .Mxcsr}
		for kind, place in others {
			color: graphics.Color = graphics.colors.not_usable
			if kind != .Opmask || held_level >= .Avx_512 {
				color = worker.wrong_others & (1 << u8(kind)) != 0 ? graphics.colors.failed : (done ? graphics.colors.process : graphics.colors.track)
			}
			interface.mark(&frame, x + place * (square_size + 2), row.y + 2, square_size, color)
		}
		x += 4 * (square_size + 2) + 16
		if !with_text {
			continue
		}
		builder.count = 0
		interface.text_put_number(&builder, intrinsics.atomic_load(&worker.passes))
		interface.text_put(&builder, " passes, ")
		interface.text_put_number(&builder, intrinsics.atomic_load(&worker.entries))
		interface.text_put(&builder, " entries")
		if intrinsics.atomic_load(&worker.start_state_done) {
			interface.text_put(&builder, intrinsics.atomic_load(&worker.start_state_wrong) == 0 ? ", start state good" : ", START STATE WRONG")
		}
		wrong := worker.wrong_registers != 0 || worker.start_state_wrong != 0
		interface.draw_text(frame.table, x, row.y, interface.text_of(&builder), wrong ? graphics.colors.failed : graphics.colors.text)
	}
	interface.cell_text(&frame, {content.x, content.y + content.height - LINE, content.width, LINE}, "a square: one vector register; then the opmasks, the x87 stack, the x87 control word, MXCSR", graphics.colors.dim)

	// The value starts after the longest name of a level, "zmm0 to zmm31
	// and k0 to k7 (16 bits)": 36 characters, in either font of the names.
	ENTRY_VALUE_X :: 36 * graphics.CELL_WIDTH + 16
	content = interface.card(&frame, {8, 552, WIDTH - 16, HEIGHT - 560}, "ONE EMPTY KERNEL ENTRY", "a syscall with no command and no wait, 100000 times, after the test", graphics.colors.machine)
	column = interface.column_of(content)
	for measured in Level {
		if measured == .Avx_512_With_Wide_Opmasks {
			continue
		}
		builder.count = 0
		if entry_nanoseconds[measured] == 0 {
			interface.text_put(&builder, measured > held_level ? "not usable here" : "not measured yet")
		} else {
			interface.text_put_number(&builder, entry_nanoseconds[measured])
			interface.text_put(&builder, " ns")
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), level_names[measured], interface.text_of(&builder), entry_nanoseconds[measured] == 0 ? graphics.colors.dim : graphics.colors.text, ENTRY_VALUE_X)
	}
	if finished {
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "result", passed ? "each register of each thread was kept" : "a register was not kept: see the log", passed ? graphics.colors.process : graphics.colors.failed, ENTRY_VALUE_X)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry starts the threads that fill and check the registers
// (`registers.asm` holds the code that touches each register), waits for
// their passes, writes the summary line, measures the empty kernel entry
// with each level of registers in use, then keeps the window open until the
// process is stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "extended_state")
	if !ok {
		system.stop(.Failed)
	}
	facts = sets.processor_facts_read()
	usable = sets.usable_from(facts)
	held_level = .Sse
	if .Avx in usable {
		held_level = .Avx
	}
	if .Avx512_F in usable {
		held_level = .Avx_512
	}
	if .Avx512_Bw in usable {
		held_level = .Avx_512_With_Wide_Opmasks
	}
	builder, second_builder, third_builder: interface.Text_Builder
	// The names of the saved components, as components_text writes them
	// before the size of a save.
	saved := sets.saved_components(facts)
	saved_names: string = "x87, SSE"
	switch {
	case .Avx in saved && sets.AVX_512_COMPONENTS <= saved:
		saved_names = "x87, SSE, AVX, AVX-512"
	case .Avx in saved:
		saved_names = "x87, SSE, AVX"
	case sets.AVX_512_COMPONENTS <= saved:
		saved_names = "x87, SSE, AVX-512"
	}
	system.log_fact(.Info, Saved_Components{saved_area_bytes = u64(facts.saved_area_size), components = value_kinds.text_field(saved_names, 24)})
	system.log_fact(.Info, Usable_Sets{xmm_sets = value_kinds.text_field(sets_text(&builder, usable, .Sse, .Pclmulqdq), 56)})
	system.log_fact(.Info, Usable_Sets_Of_Avx{avx_sets = value_kinds.text_field(sets_text(&second_builder, usable, .Avx, .Avx512_Vl), 80)})
	system.log_fact(.Info, Usable_Sets_Of_General_Registers{general_register_sets = value_kinds.text_field(sets_text(&third_builder, usable, .Popcnt, .Bmi2), 24)})
	if held_level == .Sse {
		system.log_fact(.Info, Avx_Not_Usable{})
	}

	processor_count = max(system.thread_record().processors, 1)
	worker_count = min(int(processor_count) + 2, WORKER_CAPACITY)
	if worker_count < int(processor_count) + 2 {
		// A process has 32 threads: on a larger machine some processors run
		// no thread of the test, and the threads still move at each wait.
		system.log_fact(.Info, Threads_Fewer_Than_Processors{processors = u64(processor_count), threads = u64(worker_count)})
	}
	start_time = system.time()
	for index in 0 ..< worker_count {
		worker := &workers[index]
		worker.number = u32(index + 1)
		status: call_outcome.Call_Outcome
		worker.thread, status = system.thread_start(worker_run, worker)
		if status != .Succeeded {
			system.log_fact(.Info, Thread_Not_Started{thread_number = u64(index + 1)})
			system.stop(.Failed)
		}
	}
	for !finished {
		draw(&window)
		display.wait(&window, system.time() + 100)
		interface.window_events(&window_memory.drawing, &window)
		all_done := true
		for &worker in workers[:worker_count] {
			if !intrinsics.atomic_load(&worker.done) {
				all_done = false
			}
		}
		if !all_done {
			continue
		}
		passes, entries, wrong, start_wrong: u64
		for &worker in workers[:worker_count] {
			system.thread_wait(worker.thread)
			passes += worker.passes
			entries += worker.entries
			wrong += worker.wrong_registers
			start_wrong += worker.start_state_wrong
		}
		entry_measure()
		parts_measure()
		hand_over_counts[0], hand_over_nanoseconds[0] = hand_over_measure(false)
		if .Avx in usable {
			hand_over_counts[1], hand_over_nanoseconds[1] = hand_over_measure(true)
		}
		parts_log()
		system.log_fact(.Info, Hand_Over_Measured{x87_and_sse_time = u64(hand_over_nanoseconds[0]), ymm_time = u64(hand_over_nanoseconds[1]), x87_and_sse_hand_overs = u64(hand_over_counts[0]), ymm_hand_overs = u64(hand_over_counts[1]), period = u64(HAND_OVER_MILLISECONDS)})
		system.log_fact(.Info, Kernel_Entry_Measured{kernel_entries = u64(MEASURE_ENTRIES), xmm_time = entry_nanoseconds[.Sse], ymm_time = entry_nanoseconds[.Avx], zmm_time = entry_nanoseconds[.Avx_512]})
		passed = wrong == 0 && start_wrong == 0
		finished = true
		if passed {
			system.log_fact(.Info, Registers_Kept{threads = u64(worker_count), processors = u64(processor_count), passes = u64(passes), kernel_entries = u64(entries), kept_registers = value_kinds.text_field(level_names[held_level], 40)})
		} else {
			system.log_fact(.Info, Registers_Wrong{wrong_registers = u64(wrong), wrong_start_parts = u64(start_wrong)})
		}
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&window_memory.drawing, &window)
	}
}
