// The performance counters of the processor that the kernel programs for a
// thread: the four events of the thread counters, their encodings on Intel
// and on AMD Zen, and the registers of each vendor. The formats are those of
// the "Intel 64 and IA-32 Architectures Software Developer's Manual", volume
// 3, chapter "Performance Monitoring", and of the "AMD64 Architecture
// Programmer's Manual", volume 2, "Performance Monitoring Counters", with the
// event numbers of the "Processor Programming Reference" of the family 0x17
// and 0x19. The design is src/md/features/processor_counters.md.
//
// The kernel reads the CPUID values once at boot, and plan_of_identification
// gives the counter plan: a pure function, with host tests. Each processor
// then takes the trial of the registers of the plan (trial_steps_of_plan,
// trial_step_outcome), pure functions too.
package processor_counters

// The four events of the thread counters, in the order of
// op.Thread_Counters. The general counter n of the processor counts the
// event n.
Event :: enum u32 {
	Instructions_Retired = 0,
	Cycles               = 1,
	Cache_Misses         = 2,
	Branch_Misses        = 3,
}

// The count of the events, and of the general counters that the kernel uses.
EVENT_COUNT :: u32(max(Event)) + 1

// The vendor of a counter plan.
Vendor :: enum u8 {
	None  = 0, // No plan: the machine has no thread counters.
	Intel = 1,
	Amd   = 2,
}

// The bits of an event select register that the kernel sets, the same on
// both vendors: the event in bits 0 to 7, the mask in bits 8 to 15.
SELECT_USER_MODE :: u64(1) << 16 // Count while the processor runs at the privilege of a program.
SELECT_ENABLE :: u64(1) << 22 // The counter counts.

// The registers of Intel.
INTEL_EVENT_SELECT_FIRST :: u32(0x186) // IA32_PERFEVTSEL0; the next counters follow.
INTEL_COUNTER_FIRST :: u32(0xC1) // IA32_PMC0; the next counters follow.
INTEL_GLOBAL_CONTROL :: u32(0x38F) // IA32_PERF_GLOBAL_CTRL, from version 2: bit n turns on the general counter n.
// The leaf of the architectural performance monitoring of Intel.
INTEL_MONITORING_LEAF :: u32(0xA)

// The registers of AMD with the core counter extension: the select of the
// counter n at AMD_EVENT_SELECT_FIRST + 2n, its count just after.
AMD_EVENT_SELECT_FIRST :: u32(0xC001_0200)
AMD_COUNTER_FIRST :: u32(0xC001_0201)
AMD_REGISTER_STEP :: u32(2)
AMD_GLOBAL_CONTROL :: u32(0xC000_0301) // PerfCntrGlobalCtl, with the monitoring version 2: bit n turns on the counter n.
// The bit of the core counter extension in ECX of CPUID 0x80000001.
AMD_CORE_EXTENSION_BIT :: u32(1) << 23
// The leaf of the monitoring version 2 of AMD.
AMD_MONITORING_LEAF :: u32(0x8000_0022)
// The first family of Zen: the events of the table below are its events.
AMD_FAMILY_ZEN :: u32(0x17)

// The event and the mask of each event, as bits 0 to 15 of a select.
@(rodata)
INTEL_EVENTS := [Event]u64 {
	.Instructions_Retired = 0x00C0,
	.Cycles               = 0x003C, // Core cycles, not halted.
	.Cache_Misses         = 0x412E, // Misses of the last level cache.
	.Branch_Misses        = 0x00C5, // Branches mispredicted, retired.
}

@(rodata)
AMD_EVENTS := [Event]u64 {
	.Instructions_Retired = 0x00C0,
	.Cycles               = 0x0076, // Cycles, not halted.
	.Cache_Misses         = 0x0964, // Misses of the L2 cache, from the data cache and the instruction cache.
	.Branch_Misses        = 0x00C3, // Branches mispredicted, retired.
}

// The bit of EBX of the Intel leaf 0xA that says that an event is absent.
@(rodata)
INTEL_EVENT_ABSENT_BITS := [Event]u32 {
	.Instructions_Retired = 1,
	.Cycles               = 0,
	.Cache_Misses         = 4,
	.Branch_Misses        = 6,
}

// The values of CPUID that the plan reads. The kernel fills each one that
// its highest leaf allows, and leaves the others 0.
Identification :: struct {
	vendor_b, vendor_c, vendor_d: u32, // The vendor string of leaf 0.
	highest_leaf:                 u32, // EAX of leaf 0.
	signature:                    u32, // EAX of leaf 1: the family and the model.
	intel_monitoring_a:           u32, // EAX of leaf 0xA.
	intel_monitoring_b:           u32, // EBX of leaf 0xA.
	highest_extended_leaf:        u32, // EAX of leaf 0x80000000.
	extended_features_c:          u32, // ECX of leaf 0x80000001.
	amd_monitoring_a:             u32, // EAX of leaf 0x80000022.
	amd_monitoring_b:             u32, // EBX of leaf 0x80000022.
}

// Why a machine has no plan, for the line of the boot.
Absence :: enum u8 {
	None                     = 0, // A plan.
	Unknown_Vendor           = 1, // Neither "GenuineIntel" nor "AuthenticAMD".
	Intel_No_Monitoring      = 2, // No leaf 0xA, or its version 0.
	Intel_Too_Few_Counters   = 3, // Fewer than EVENT_COUNT general counters.
	Intel_Event_Absent       = 4, // Leaf 0xA says that one of the four events is absent.
	Amd_No_Core_Extension    = 5, // No core counter extension.
	Amd_Family_Before_Zen    = 6, // A family before 0x17: other event numbers.
	// The outcomes of the trial of the registers (trial_step_outcome). Each
	// one names the register of the step that failed.
	Register_Refused         = 7, // The processor refused an access with a protection fault.
	Counter_In_Use           = 8, // A select was on: another user counts with its counter.
	Counter_Not_Kept         = 9, // A counter did not give back the value that the kernel wrote.
}

// The text of each absence, after "none that the kernel uses: ". The text
// of an outcome of the trial ends with the register, which the kernel
// writes after it.
@(rodata)
ABSENCE_TEXTS := [Absence]string {
	.None                   = "",
	.Unknown_Vendor         = "the vendor is not Intel or AMD",
	.Intel_No_Monitoring    = "Intel with no architectural performance monitoring",
	.Intel_Too_Few_Counters = "Intel with fewer than 4 general counters",
	.Intel_Event_Absent     = "Intel, and CPUID leaf 0xA says that one of the four events is absent",
	.Amd_No_Core_Extension  = "AMD with no core counter extension",
	.Amd_Family_Before_Zen  = "AMD before the family 0x17 (Zen)",
	.Register_Refused       = "CPUID lists the counters, and the processor refused a trial access with a protection fault, to the register",
	.Counter_In_Use         = "a counter was on before the kernel: another user counts with it, at the select register",
	.Counter_Not_Kept       = "a counter did not give back the value that the kernel wrote, at the register",
}

// absence_names_a_register says if the line of an absence names a register:
// the outcomes of the trial do.
absence_names_a_register :: proc "contextless" (absence: Absence) -> bool {
	return absence == .Register_Refused || absence == .Counter_In_Use || absence == .Counter_Not_Kept
}

// The counter plan of a machine: for each event, its select register, its
// counter register and the select value that turns it on; and the global
// control register with the bits that turn on the counters 0 to 3, or 0
// when the processor has none.
Plan :: struct {
	vendor:                Vendor,
	select_registers:      [Event]u32,
	counter_registers:     [Event]u32,
	select_values:         [Event]u64,
	global_control:        u32,
	global_control_value:  u64,
}

// The bits of a global control register for the counters 0 to 3.
GLOBAL_CONTROL_FOUR_COUNTERS :: (u64(1) << EVENT_COUNT) - 1

// "GenuineIntel" and "AuthenticAMD", as the three registers of leaf 0 give them.
@(private = "file")
is_intel :: proc "contextless" (identification: Identification) -> bool {
	return identification.vendor_b == 0x756E_6547 && identification.vendor_d == 0x4965_6E69 && identification.vendor_c == 0x6C65_746E
}

@(private = "file")
is_amd :: proc "contextless" (identification: Identification) -> bool {
	return identification.vendor_b == 0x6874_7541 && identification.vendor_d == 0x6974_6E65 && identification.vendor_c == 0x444D_4163
}

// family_of gives the family of a processor from EAX of leaf 1: the base
// family, plus the extended family when the base family is 0xF.
family_of :: proc "contextless" (signature: u32) -> u32 {
	base := signature >> 8 & 0xF
	if base == 0xF {
		return base + (signature >> 20 & 0xFF)
	}
	return base
}

// plan_of_identification gives the counter plan of a processor, or the
// reason that it has none (Absence). The plan is the same for each
// processor of the machine: the kernel reads the first one.
plan_of_identification :: proc "contextless" (identification: Identification) -> (plan: Plan, absence: Absence) {
	switch {
	case is_intel(identification):
		if identification.highest_leaf < INTEL_MONITORING_LEAF {
			return {}, .Intel_No_Monitoring
		}
		version := identification.intel_monitoring_a & 0xFF
		if version == 0 {
			return {}, .Intel_No_Monitoring
		}
		if (identification.intel_monitoring_a >> 8) & 0xFF < EVENT_COUNT {
			return {}, .Intel_Too_Few_Counters
		}
		// The length of the vector of EBX: an event past it is absent.
		length := identification.intel_monitoring_a >> 24 & 0xFF
		for event in Event {
			bit := INTEL_EVENT_ABSENT_BITS[event]
			if bit >= length || identification.intel_monitoring_b & (u32(1) << bit) != 0 {
				return {}, .Intel_Event_Absent
			}
		}
		plan.vendor = .Intel
		for event in Event {
			plan.select_registers[event] = INTEL_EVENT_SELECT_FIRST + u32(event)
			plan.counter_registers[event] = INTEL_COUNTER_FIRST + u32(event)
			plan.select_values[event] = INTEL_EVENTS[event] | SELECT_USER_MODE | SELECT_ENABLE
		}
		if version >= 2 {
			plan.global_control, plan.global_control_value = INTEL_GLOBAL_CONTROL, GLOBAL_CONTROL_FOUR_COUNTERS
		}
		return plan, .None
	case is_amd(identification):
		if identification.highest_extended_leaf < 0x8000_0001 || identification.extended_features_c & AMD_CORE_EXTENSION_BIT == 0 {
			return {}, .Amd_No_Core_Extension
		}
		if family_of(identification.signature) < AMD_FAMILY_ZEN {
			return {}, .Amd_Family_Before_Zen
		}
		plan.vendor = .Amd
		for event in Event {
			plan.select_registers[event] = AMD_EVENT_SELECT_FIRST + AMD_REGISTER_STEP * u32(event)
			plan.counter_registers[event] = AMD_COUNTER_FIRST + AMD_REGISTER_STEP * u32(event)
			plan.select_values[event] = AMD_EVENTS[event] | SELECT_USER_MODE | SELECT_ENABLE
		}
		// The global control exists only with the monitoring version 2, and
		// a bit past the counters of the processor is reserved.
		version_2 := identification.highest_extended_leaf >= AMD_MONITORING_LEAF && identification.amd_monitoring_a & 1 != 0
		if version_2 && identification.amd_monitoring_b & 0xF >= EVENT_COUNT {
			plan.global_control, plan.global_control_value = AMD_GLOBAL_CONTROL, GLOBAL_CONTROL_FOUR_COUNTERS
		}
		return plan, .None
	}
	return {}, .Unknown_Vendor
}

// The trial of the registers of a plan. CPUID lists the counters, but a
// hypervisor can list them and refuse each access to their registers, or
// take the writes and keep nothing; and a firmware can leave a counter on.
// So each processor, at its start and before any thread runs, takes each
// access that the kernel makes later, once, in this order, and the first
// step that fails ends the trial.

// The value that the trial writes to each counter and reads back. Bit 31 is
// clear: on Intel with no full-width writes, a write to a counter keeps 32
// bits and extends bit 31, and this value reads back the same.
TRIAL_COUNTER_VALUE :: u64(0xABCD)

Trial_Step_Kind :: enum u8 {
	Read_Select_Off = 0, // Read a select: Enable must be clear, else another user counts with it.
	Write           = 1, // Write the value.
	Read_Back       = 2, // Read the register: it must give the value.
	Add_Bits        = 3, // Read the register, then write it with the bits of the value added.
}

// One access of the trial to one register.
Trial_Step :: struct {
	kind:     Trial_Step_Kind,
	register: u32,
	value:    u64,
}

// The most steps of a trial: a read of each select; for each counter, a
// write, a read back and a write of 0, then the select value and 0 to its
// select; and the global control.
TRIAL_STEP_CAPACITY :: 6 * EVENT_COUNT + 1

// trial_steps_of_plan gives the steps of the trial of a plan, in their
// order. Each select is read before the trial writes any register: a select
// that is on belongs to another user, and the kernel then writes nothing.
// The trial ends with each counter and each select at 0, as the switch
// leaves them.
trial_steps_of_plan :: proc "contextless" (plan: Plan) -> (steps: [TRIAL_STEP_CAPACITY]Trial_Step, count: u32) {
	if plan.vendor == .None {
		return
	}
	for event in Event {
		steps[count] = {.Read_Select_Off, plan.select_registers[event], 0}
		count += 1
	}
	for event in Event {
		steps[count + 0] = {.Write, plan.counter_registers[event], TRIAL_COUNTER_VALUE}
		steps[count + 1] = {.Read_Back, plan.counter_registers[event], TRIAL_COUNTER_VALUE}
		steps[count + 2] = {.Write, plan.counter_registers[event], 0}
		steps[count + 3] = {.Write, plan.select_registers[event], plan.select_values[event]}
		steps[count + 4] = {.Write, plan.select_registers[event], 0}
		count += 5
	}
	if plan.global_control != 0 {
		steps[count] = {.Add_Bits, plan.global_control, plan.global_control_value}
		count += 1
	}
	return
}

// trial_step_outcome judges one step: accepted is false when the processor
// refused an access of the step with a protection fault, and value_read is
// the value of its read.
trial_step_outcome :: proc "contextless" (step: Trial_Step, accepted: bool, value_read: u64) -> Absence {
	if !accepted {
		return .Register_Refused
	}
	switch step.kind {
	case .Read_Select_Off:
		if value_read & SELECT_ENABLE != 0 {
			return .Counter_In_Use
		}
	case .Read_Back:
		if value_read != step.value {
			return .Counter_Not_Kept
		}
	case .Write, .Add_Bits:
		// The access itself is the test: the processor took it.
	}
	return .None
}
