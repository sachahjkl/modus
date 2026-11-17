package kernel

import "base:intrinsics"
import "kernel:stolen_time"

// The stolen time of a processor (docs/ARCHITECTURE.md, "Processor time";
// src/md/features/stolen_time.md): under KVM the cycle counter goes on
// while the host runs another task on the physical processor, and those
// cycles are not time of the thread that the processor ran. Each processor
// registers the steal-time record of KVM at its start, and each charge
// subtracts the time stolen since the charge before. A real machine, and a
// host that does not offer the record, charge each cycle of a run.

// Why the machine has no steal time; .None: it has. Written by the first
// processor in its setup, before any other processor starts.
stolen_time_absence: stolen_time.Absence
// The processors that registered their record (atomic: each processor adds
// itself in its setup).
stolen_time_processors: u32

// stolen_time_identification reads what the decision needs of CPUID: the
// hypervisor bit, then the first base of the leaves of a hypervisor that
// has the signature of KVM, as Linux searches, and the features of KVM
// there.
@(private = "file")
stolen_time_identification :: proc "contextless" () -> (identification: stolen_time.Identification) {
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	identification.hypervisor_present = features & stolen_time.HYPERVISOR_PRESENT_BIT != 0
	if !identification.hypervisor_present {
		return
	}
	for base := stolen_time.HYPERVISOR_LEAF_FIRST; base < stolen_time.HYPERVISOR_LEAF_END; base += stolen_time.HYPERVISOR_LEAF_STEP {
		_, b, c, d := intrinsics.x86_cpuid(base, 0)
		if stolen_time.is_kvm_signature(b, c, d) {
			identification.kvm_leaves_found = true
			identification.kvm_features, _, _, _ = intrinsics.x86_cpuid(base + stolen_time.KVM_FEATURES_LEAF_OFFSET, 0)
			return
		}
	}
	return
}

// stolen_time_processor_setup registers the record of the processor that
// runs it, at its start, before any thread runs. The first processor
// decides first if the machine offers steal time. The write is a register
// trial: a host that lists the feature and refuses the register leaves this
// processor with no steal time, and the machine goes on.
stolen_time_processor_setup :: proc "contextless" (cpu: ^Processor) {
	if cpu.index == 0 {
		stolen_time_absence = stolen_time.absence_of_identification(stolen_time_identification())
	}
	if stolen_time_absence != .None {
		return
	}
	// The host adds to the counter that it finds in the record: it must
	// start at 0.
	cpu.stolen_time_record = {}
	value, aligned := stolen_time.registration_value(physical_of(&cpu.stolen_time_record))
	if !aligned || !model_specific_register_trial_write(stolen_time.MSR_KVM_STEAL_TIME, value) {
		return
	}
	cpu.stolen_time_registered = true
	stolen_time_run_start(cpu)
	intrinsics.atomic_add(&stolen_time_processors, 1)
}

// stolen_time_read gives the steal counter of the record of this
// processor. false: no read in the bound saw the same even version before
// and after the counter. The loads are volatile, so the compiler keeps their
// order, and the processor does not reorder a load before an earlier load:
// the protocol needs no other fence on this processor.
@(private = "file")
stolen_time_read :: proc "contextless" (cpu: ^Processor) -> (steal: u64, whole: bool) {
	record := &cpu.stolen_time_record
	for _ in 0 ..< stolen_time.READ_ATTEMPT_LIMIT {
		version_before := intrinsics.volatile_load(&record.version)
		steal = intrinsics.volatile_load(&record.steal)
		version_after := intrinsics.volatile_load(&record.version)
		if stolen_time.read_is_whole(version_before, version_after) {
			return steal, true
		}
		intrinsics.cpu_relax()
	}
	return 0, false
}

// stolen_time_charged gives the part of a run of this processor that the
// host did not steal, and starts the count of the next run. A processor
// with no record, or a read that saw no whole value, charges the whole run;
// after a failed read the last counter stays, so the next charge that reads
// one subtracts the stolen time of both runs.
stolen_time_charged :: proc "contextless" (cpu: ^Processor, run_cycles: u64) -> u64 {
	if !cpu.stolen_time_registered {
		return run_cycles
	}
	steal, whole := stolen_time_read(cpu)
	if !whole {
		return run_cycles
	}
	charged, next_counted, _ := stolen_time.charge_without_stolen(run_cycles, cpu.stolen_counted, steal, cycle_frequency)
	cpu.stolen_counted = next_counted
	return charged
}

// stolen_time_run_start takes the counter as the start of a run, as the
// pick of a thread takes the cycle counter: the time stolen while the
// processor had no thread goes to no thread.
stolen_time_run_start :: proc "contextless" (cpu: ^Processor) {
	_ = stolen_time_charged(cpu, 0)
}

// stolen_time_log writes, at boot, after the start of the processors,
// whether the kernel subtracts the stolen time and on how many processors.
stolen_time_log :: proc "contextless" () {
	if stolen_time_absence != .None {
		log("kernel: steal time: off: ", stolen_time.ABSENCE_TEXTS[stolen_time_absence], "; the kernel charges each cycle of a run")
		return
	}
	log("kernel: steal time: on: ", u64(intrinsics.atomic_load(&stolen_time_processors)), " of ", u64(processor_count), " processors registered their record; the kernel does not charge the time that the host took from a processor")
}
