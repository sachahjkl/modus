package kernel

import "base:intrinsics"
import op "modus:contract/operation"
import "modulus:processor_counters"

// The counters of a thread (docs/ARCHITECTURE.md, "The counters of a
// thread"; src/md/features/processor_counters.md): the kernel programs the
// general counters 0 to 3 of the processor for the calling thread, in user
// mode only, and keeps their counts when the thread leaves a processor.
//
// The counter plan comes from CPUID once, on the first processor
// (processor_counters.plan_of_identification). Each processor then takes the
// trial of its registers (thread_counters_trial): a hypervisor can list the
// counters and refuse their registers, and a firmware can leave a counter
// on. A machine with no plan, or whose trial failed, gives Unsupported for
// each command.
//
// The registers of a processor count for one thread at most: the processor
// that takes a thread that counts writes 0 in the counters, then turns the
// selects on; the processor that leaves it turns the selects off, then adds
// the counters to the totals of the thread. From the leave to the next take
// the selects are off, so no count of another thread, of the idle wait or
// of the kernel reaches a thread. A switch to a thread that does not count
// tests one byte of its hot line (Thread.counting) and writes no register.

// The counter plan of the machine. Written by the first processor in
// processor_setup, before any other processor starts, and by a processor
// whose trial failed, at its start: the first processor waits for each
// start in turn, and the root service starts after the last one, so no
// thread reads the plan before its last write.
counter_plan: processor_counters.Plan
counter_absence: processor_counters.Absence
// The register of the step of the trial that failed, for the line of the
// boot.
counter_trial_register: u32

// processor_identification reads the CPUID values that the counter plan
// needs: each leaf only when the highest leaf of its range reaches it.
processor_identification :: proc "contextless" () -> (identification: processor_counters.Identification) {
	highest, vendor_b, vendor_c, vendor_d := processor_identification_read(0, 0)
	identification.highest_leaf = highest
	identification.vendor_b, identification.vendor_c, identification.vendor_d = vendor_b, vendor_c, vendor_d
	if highest >= 1 {
		identification.signature, _, _, _ = processor_identification_read(1, 0)
	}
	if highest >= processor_counters.INTEL_MONITORING_LEAF {
		identification.intel_monitoring_a, identification.intel_monitoring_b, _, _ = processor_identification_read(processor_counters.INTEL_MONITORING_LEAF, 0)
	}
	extended, _, _, _ := processor_identification_read(0x8000_0000, 0)
	identification.highest_extended_leaf = extended
	if extended >= 0x8000_0001 {
		_, _, identification.extended_features_c, _ = processor_identification_read(0x8000_0001, 0)
	}
	if extended >= processor_counters.AMD_MONITORING_LEAF {
		identification.amd_monitoring_a, identification.amd_monitoring_b, _, _ = processor_identification_read(processor_counters.AMD_MONITORING_LEAF, 0)
	}
	return identification
}

// thread_counters_processor_setup prepares the counters of a processor at
// its start, before any thread runs. The first processor finds the plan of
// the machine. Each processor takes the trial of the registers of the plan,
// which leaves its counters and its selects at 0 and turns on the counters
// 0 to 3 in its global control: a firmware can leave them off. A processor
// whose trial fails turns the plan off for the machine: a thread can run on
// any processor.
thread_counters_processor_setup :: proc "contextless" (cpu: ^Processor) {
	if cpu.index == 0 {
		counter_plan, counter_absence = processor_counters.plan_of_identification(processor_identification())
	}
	if counter_plan.vendor == .None {
		return
	}
	absence, register := thread_counters_trial()
	if absence == .None {
		return
	}
	// The trial can fail after it turned a select on and before its write of
	// 0: with no plan, no later code turns that select off. So each select
	// that the trial wrote gets a write of 0 again, and a refusal of it
	// changes nothing more. A select that was on before the trial belongs to
	// another user: the trial wrote none, so none is written.
	if absence != .Counter_In_Use {
		for event in processor_counters.Event {
			_ = model_specific_register_trial_write(counter_plan.select_registers[event], 0)
		}
	}
	// The vendor first, in its own store: each reader tests it first, so a
	// plan whose clear a reset of this processor cut in the middle reads as
	// no plan.
	intrinsics.atomic_store(&counter_plan.vendor, processor_counters.Vendor.None)
	counter_plan = {}
	counter_absence = absence
	counter_trial_register = register
	// The first processor writes the line of the boot after its setup
	// (thread_counters_log); another one writes its own line.
	if cpu.index != 0 {
		log("kernel: performance counters: none that the kernel uses: on the processor ", u64(cpu.index), ", ", processor_counters.ABSENCE_TEXTS[absence], " ", Hex(register), "; a command of the thread counters gives Unsupported")
	}
}

// thread_counters_trial takes each step of the trial of the plan on this
// processor (processor_counters.trial_steps_of_plan), with register trials:
// a refusal of the processor is an outcome, not a stop of the machine. It
// gives the outcome of the first step that fails, and its register.
thread_counters_trial :: proc "contextless" () -> (absence: processor_counters.Absence, register: u32) {
	steps, count := processor_counters.trial_steps_of_plan(counter_plan)
	for step in steps[:count] {
		value_read: u64
		accepted: bool
		switch step.kind {
		case .Read_Select_Off, .Read_Back:
			accepted = model_specific_register_trial_read(step.register, &value_read)
		case .Write:
			accepted = model_specific_register_trial_write(step.register, step.value)
		case .Add_Bits:
			accepted = model_specific_register_trial_read(step.register, &value_read) && model_specific_register_trial_write(step.register, value_read | step.value)
		}
		absence = processor_counters.trial_step_outcome(step, accepted, value_read)
		if absence != .None {
			return absence, step.register
		}
	}
	return .None, 0
}

// thread_counters_log writes one line at boot: the counter plan and the
// trial of the first processor, or why the machine has none.
thread_counters_log :: proc "contextless" () {
	_, _, features, _ := processor_identification_read(1, 0)
	guest := features & (1 << 31) != 0 // A hypervisor runs this machine.
	where_text := guest ? string(" (a guest of a hypervisor)") : string("")
	switch counter_plan.vendor {
	case .Intel:
		log("kernel: performance counters", where_text, ": Intel architectural monitoring, the general counters 0 to 3: instructions retired, cycles, cache misses of the last level, branch misses; the thread counters count in user mode only; the first processor passed the trial of the registers")
	case .Amd:
		log("kernel: performance counters", where_text, ": AMD core counters, the counters 0 to 3: instructions retired, cycles, cache misses of the L2, branch misses; the thread counters count in user mode only; the first processor passed the trial of the registers")
	case .None:
		if processor_counters.absence_names_a_register(counter_absence) {
			log("kernel: performance counters", where_text, ": none that the kernel uses: ", processor_counters.ABSENCE_TEXTS[counter_absence], " ", Hex(counter_trial_register), "; a command of the thread counters gives Unsupported")
		} else {
			log("kernel: performance counters", where_text, ": none that the kernel uses: ", processor_counters.ABSENCE_TEXTS[counter_absence], "; a command of the thread counters gives Unsupported")
		}
	}
}

// thread_counters_load turns the counters of this processor on for the
// thread that it takes: the counters from 0, then the selects. The caller
// checked Thread.counting.
thread_counters_load :: proc "contextless" () {
	for event in processor_counters.Event {
		model_specific_register_write(counter_plan.counter_registers[event], 0)
	}
	for event in processor_counters.Event {
		model_specific_register_write(counter_plan.select_registers[event], counter_plan.select_values[event])
	}
}

// thread_counters_unload turns the selects of this processor off, then adds
// its counters to the totals of the thread that it leaves. The selects go
// first, so the counts that it reads are final. The caller checked
// Thread.counting.
thread_counters_unload :: proc "contextless" (thread: ^Thread) {
	for event in processor_counters.Event {
		model_specific_register_write(counter_plan.select_registers[event], 0)
	}
	for event in processor_counters.Event {
		thread.counter_totals[event] += model_specific_register_read(counter_plan.counter_registers[event])
	}
}

// thread_counters_control runs the three commands of the thread counters
// on the calling thread, which is the current thread of this processor:
// its counts are in the registers of this processor. The caller checked
// the command (op.thread_control_counts_the_caller). The caller holds the
// process lock of the calling process.
thread_counters_control :: proc "contextless" (caller_index: u32, caller_process: ^Process, command: op.Thread_Control_Command, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	thread := &threads[caller_index]
	// A stop only takes a capability away and gives nothing, so it needs no
	// handle and no right: a thread whose right was revoked can still stop
	// counting, and its switches stop paying for the counter registers.
	if command == .Stop_Counters {
		if thread.counting {
			thread_counters_unload(thread)
			thread.counting = false
		}
		return .Succeeded
	}
	if v[0] == 0 {
		return .Argument_Refused
	}
	named := handle_find(caller_process, v[0], .None) or_return
	if named.kind != .Machine {
		return .Argument_Refused
	}
	if !(op.THREAD_COUNTERS_RIGHTS <= named.rights) {
		return .Grant_Or_Right_Missing
	}
	// The diagnosis gives the error kind Unsupported for it.
	if counter_plan.vendor == .None {
		return .Operation_Unsupported
	}
	// Stop_Counters returned above; each other command of the set comes to
	// this procedure only by a fault of its caller.
	switch command {
	case .None, .Stop, .Resume, .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State, .Read_Schedule, .Write_Schedule, .Read_Breakpoints, .Write_Breakpoints, .Read_Memory, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Stop_Counters, .Record_Start, .Record_End, .Replay_Start, .Wait_Room:
		return .Argument_Refused
	case .Start_Counters:
		if thread.counting {
			thread_counters_unload(thread)
		}
		thread.counter_totals = {}
		thread.counting = true
		thread_counters_load()
	case .Read_Counters:
		size := u64(size_of(op.Thread_Counters))
		if v[4] < size || !user_range(caller_process, v[3], size, true) {
			return .Argument_Refused
		}
		if !thread.counting {
			return thread_control_state_refuse(.Counters_Not_Started, 3, u64(command), 1, u64(op.Process_State.Ready))
		}
		// The totals up to the last take, and the counts of this processor
		// since it: the selects stay on, so the thread goes on counting.
		counts := thread.counter_totals
		for event in processor_counters.Event {
			counts[event] += model_specific_register_read(counter_plan.counter_registers[event])
		}
		counters := op.Thread_Counters {
			instructions_retired = counts[.Instructions_Retired],
			cycles               = counts[.Cycles],
			cache_misses         = counts[.Cache_Misses],
			branch_misses        = counts[.Branch_Misses],
		}
		user_copy_to_process(v[3], &counters, size)
		results[0] = size
	}
	return .Succeeded
}
