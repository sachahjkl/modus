package kernel

// The interrupt controller of each processor of a browser machine, in
// software (src/md/features/browser_machine.md, "The timer and the cycle
// counter"). It has the procedures of the local APIC of x86-64
// (apic_amd64.odin), so the kernel above it is the same source. It has no
// register in memory: the controller of each processor is a record in the
// shared memory, whose rules are the kernel part virtual_interrupt_controller,
// and the timer is a deadline on the clock of the page.
//
// A browser machine has no 8254 and no ACPI table of the processors: the
// clock of the page is the time base, and the page gives the count of the
// processors.

import "base:intrinsics"
import interrupts "modulus:virtual_interrupt_controller"

// The controller of one processor. Each processor and each device model
// sets a bit of pending with an atomic OR; only its processor clears one,
// and only its processor reads or writes its timer.
Virtual_Interrupt_Controller :: struct {
	pending: interrupts.Pending_Words,
	timer:   interrupts.Timer,
}

// The controller of each processor, at the index of its identifier.
virtual_interrupt_controllers: [PROCESSOR_CAPACITY]Virtual_Interrupt_Controller

// interrupt_pending_set makes vector wait for the controller. false: the
// vector is an exception.
interrupt_pending_set :: proc "contextless" (controller: ^Virtual_Interrupt_Controller, vector: u8) -> bool {
	index, mask, ok := interrupts.vector_bit(vector)
	if !ok {
		return false
	}
	intrinsics.atomic_or(&controller.pending[index], mask)
	return true
}

// interrupt_take gives the highest vector that waits, and clears it. A
// setter that adds a bit between the read and the clear keeps it: the AND
// clears one bit only.
interrupt_take :: proc "contextless" (controller: ^Virtual_Interrupt_Controller) -> (vector: u8, taken: bool) {
	for {
		snapshot: interrupts.Pending_Words
		for &word, index in snapshot {
			word = intrinsics.atomic_load(&controller.pending[index])
		}
		found: bool
		vector, found = interrupts.highest_pending(snapshot)
		if !found {
			return 0, false
		}
		index, mask, _ := interrupts.vector_bit(vector)
		if intrinsics.atomic_and(&controller.pending[index], ~mask) & mask != 0 {
			return vector, true
		}
	}
}

// interrupt_timer_check sets the vector of the timer when its deadline
// passed.
@(private = "file")
interrupt_timer_check :: proc "contextless" (controller: ^Virtual_Interrupt_Controller) {
	if interrupts.timer_check(&controller.timer, cycles_now()) {
		_ = interrupt_pending_set(controller, controller.timer.vector)
	}
}

// The identifier of the processor of this worker. The page gives each
// worker its index; the first worker is 0.
@(thread_local)
virtual_apic_identifier: u32

// The clock of the page counts nanoseconds, so it is a cycle counter at
// 1 GHz (cycles_now).
PAGE_CLOCK_HERTZ :: u64(1_000_000_000)
NANOSECONDS_PER_TICK :: PAGE_CLOCK_HERTZ / TICKS_PER_SECOND

// A send to a processor that does not exist, or a start command, which
// only the start code of x86-64 sends. The tick writes the count
// (delivery_faults_log).
apic_sends_not_sent: u64

apic_id :: #force_inline proc "contextless" () -> u32 {
	return virtual_apic_identifier
}

// apic_send makes the vector wait for the processor with this identifier,
// then wakes the idle wait of that processor. A vector waits as one bit,
// so a send never waits for the target. false: the identifier names no
// processor, or value is not the vector of an interrupt; the send is
// counted.
apic_send :: proc "contextless" (id: u32, value: u32) -> (sent: bool) {
	if id >= PROCESSOR_CAPACITY || value > 0xFF || !interrupt_pending_set(&virtual_interrupt_controllers[id], u8(value)) {
		intrinsics.atomic_add(&apic_sends_not_sent, 1)
		return false
	}
	// The vector is set before the word, so the target that clears its
	// word and then looks at its vectors sees it.
	intrinsics.atomic_store(&pending_vector_words[id], 1)
	when intrinsics.has_target_feature("atomics") {
		_ = intrinsics.wasm_memory_atomic_notify32(&pending_vector_words[id], 1)
	}
	return true
}

// The controller clears a vector when the processor takes it: it has no
// register of the vectors in service, so the end of an interrupt has
// nothing to clear.
apic_end_of_interrupt :: #force_inline proc "contextless" () {
}

apic_start :: proc "contextless" () {
}

// apic_setup starts the controller of the processor that runs it empty.
apic_setup :: proc "contextless" (cpu: ^Processor) {
	virtual_interrupt_controllers[cpu.apic_id] = {}
}

// timer_calibrate has nothing to measure: the clock of the page is the
// cycle counter and the timer.
timer_calibrate :: proc "contextless" () {
	cycle_frequency = PAGE_CLOCK_HERTZ
	log("kernel: the time base is the clock of the page, at ", PAGE_CLOCK_HERTZ, " Hz")
}

timer_frequency_hertz :: proc "contextless" () -> u64 {
	return PAGE_CLOCK_HERTZ
}

// timer_start starts the tick of the processor that runs it.
timer_start :: proc "contextless" () {
	if !interrupts.timer_arm(&virtual_interrupt_controllers[apic_id()].timer, cycles_now(), NANOSECONDS_PER_TICK, VECTOR_TIMER) {
		intrinsics.trap()
	}
}

// timer_pause stops, or continues, the tick of the processor that runs it.
timer_pause :: proc "contextless" (pause: bool) {
	interrupts.timer_pause(&virtual_interrupt_controllers[apic_id()].timer, pause)
}

// interrupts_deliver_in_kernel gives the kernel each interrupt that waits
// for this processor, the timer first checked against the clock, as the
// processor delivers them when the kernel opens a window with sti. true:
// at least one came.
interrupts_deliver_in_kernel :: proc "contextless" () -> (delivered: bool) {
	controller := &virtual_interrupt_controllers[apic_id()]
	interrupt_timer_check(controller)
	for {
		vector, taken := interrupt_take(controller)
		if !taken {
			return
		}
		frame := Frame {
			vector = u64(vector),
			cs     = SELECTOR_KERNEL_CODE,
		}
		kernel_interrupt(&frame)
		delivered = true
	}
}

// interrupt_take_for_process gives the vector that interrupts the process
// that runs on this processor: the highest that waits, after the check of
// the timer. false: none waits, and the process goes on.
interrupt_take_for_process :: proc "contextless" () -> (vector: u8, taken: bool) {
	controller := &virtual_interrupt_controllers[apic_id()]
	interrupt_timer_check(controller)
	return interrupt_take(controller)
}

// interrupt_wait_bound is the longest wait of the idle processor before
// its next deadline: 0 when an interrupt waits.
interrupt_wait_bound :: proc "contextless" (longest_nanoseconds: u64) -> u64 {
	controller := &virtual_interrupt_controllers[apic_id()]
	for &word in controller.pending {
		if intrinsics.atomic_load(&word) != 0 {
			return 0
		}
	}
	return interrupts.wait_bound(controller.timer, cycles_now(), longest_nanoseconds)
}
