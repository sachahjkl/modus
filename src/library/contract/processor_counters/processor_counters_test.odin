#+build !freestanding
package processor_counters

import "core:testing"

// The vendor strings of leaf 0, as the three registers give them.
@(private = "file")
INTEL_B, INTEL_C, INTEL_D :: u32(0x756E_6547), u32(0x6C65_746E), u32(0x4965_6E69)
@(private = "file")
AMD_B, AMD_C, AMD_D :: u32(0x6874_7541), u32(0x444D_4163), u32(0x6974_6E65)

// The processor of the host of the tests under KVM: an AMD Ryzen 7 5800X
// (family 0x19, Zen 3), with the core counter extension and no monitoring
// version 2, as the line of the boot of the test machine says.
@(private = "file")
zen_3 :: proc() -> Identification {
	return {
		vendor_b = AMD_B, vendor_c = AMD_C, vendor_d = AMD_D,
		highest_leaf = 0x10,
		signature = 0x00A2_0F10, // Base family 0xF, extended family 0xA: 0x19.
		highest_extended_leaf = 0x8000_0021,
		extended_features_c = AMD_CORE_EXTENSION_BIT,
	}
}

// An Intel processor with the architectural monitoring version 4, 8
// general counters and each event of leaf 0xA.
@(private = "file")
intel_version_4 :: proc() -> Identification {
	return {
		vendor_b = INTEL_B, vendor_c = INTEL_C, vendor_d = INTEL_D,
		highest_leaf = 0x20,
		intel_monitoring_a = 4 | 8 << 8 | 48 << 16 | 7 << 24, // Version 4, 8 counters of 48 bits, 7 bits in EBX.
	}
}

// The family of a processor: the extended family counts only with the base
// family 0xF.
@(test)
the_family_of_a_processor :: proc(t: ^testing.T) {
	testing.expect_value(t, family_of(0x00A2_0F10), u32(0x19))
	testing.expect_value(t, family_of(0x0080_0F82), u32(0x17))
	testing.expect_value(t, family_of(0x0060_0F20), u32(0x15))
	testing.expect_value(t, family_of(0x0009_06EA), u32(6)) // An Intel family 6: the extended family is not added.
}

// The machine of the tests gets the AMD plan: the counters of the core
// counter extension, each select with User and Enable and without
// Operating System, and no global control.
@(test)
the_plan_of_the_test_machine :: proc(t: ^testing.T) {
	plan, absence := plan_of_identification(zen_3())
	testing.expect_value(t, absence, Absence.None)
	testing.expect_value(t, plan.vendor, Vendor.Amd)
	for event in Event {
		testing.expect_value(t, plan.select_registers[event], AMD_EVENT_SELECT_FIRST + AMD_REGISTER_STEP * u32(event))
		testing.expect_value(t, plan.counter_registers[event], plan.select_registers[event] + 1)
		testing.expect_value(t, plan.select_values[event], AMD_EVENTS[event] | SELECT_USER_MODE | SELECT_ENABLE)
		// The bit Operating System (17) is clear: no count of kernel code.
		testing.expect(t, plan.select_values[event] & (u64(1) << 17) == 0)
		// The bit Interrupt (20) is clear, and so are Host Only and Guest Only (41, 40).
		testing.expect(t, plan.select_values[event] & (u64(1) << 20 | u64(1) << 40 | u64(1) << 41) == 0)
	}
	testing.expect_value(t, plan.select_values[.Instructions_Retired], u64(0x41_00C0))
	testing.expect_value(t, plan.global_control, u32(0))
}

// With the monitoring version 2 and enough counters, the plan turns on the
// counters 0 to 3 in the global control; with fewer counters it writes no
// bit that the processor reserves.
@(test)
the_global_control_of_amd :: proc(t: ^testing.T) {
	identification := zen_3()
	identification.highest_extended_leaf = AMD_MONITORING_LEAF
	identification.amd_monitoring_a = 1
	identification.amd_monitoring_b = 6
	plan, absence := plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.None)
	testing.expect_value(t, plan.global_control, AMD_GLOBAL_CONTROL)
	testing.expect_value(t, plan.global_control_value, u64(0b1111))
	identification.amd_monitoring_b = EVENT_COUNT - 1
	plan, _ = plan_of_identification(identification)
	testing.expect_value(t, plan.global_control, u32(0))
	// A leaf 0x80000022 that the highest extended leaf does not reach is not read.
	identification.amd_monitoring_b = 6
	identification.highest_extended_leaf = AMD_MONITORING_LEAF - 1
	plan, _ = plan_of_identification(identification)
	testing.expect_value(t, plan.global_control, u32(0))
}

// An AMD processor with no core counter extension, or before Zen, has no
// plan.
@(test)
the_amd_processors_with_no_plan :: proc(t: ^testing.T) {
	identification := zen_3()
	identification.extended_features_c = 0
	_, absence := plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Amd_No_Core_Extension)
	identification = zen_3()
	identification.highest_extended_leaf = 0x8000_0000
	_, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Amd_No_Core_Extension)
	identification = zen_3()
	identification.signature = 0x0060_0F20 // Family 0x15.
	_, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Amd_Family_Before_Zen)
}

// An Intel processor gets the general counters 0 to 3 and their selects,
// and the global control from version 2.
@(test)
the_plan_of_intel :: proc(t: ^testing.T) {
	plan, absence := plan_of_identification(intel_version_4())
	testing.expect_value(t, absence, Absence.None)
	testing.expect_value(t, plan.vendor, Vendor.Intel)
	for event in Event {
		testing.expect_value(t, plan.select_registers[event], INTEL_EVENT_SELECT_FIRST + u32(event))
		testing.expect_value(t, plan.counter_registers[event], INTEL_COUNTER_FIRST + u32(event))
		testing.expect_value(t, plan.select_values[event], INTEL_EVENTS[event] | SELECT_USER_MODE | SELECT_ENABLE)
	}
	testing.expect_value(t, plan.select_values[.Cache_Misses], u64(0x41_412E))
	testing.expect_value(t, plan.global_control, INTEL_GLOBAL_CONTROL)
	testing.expect_value(t, plan.global_control_value, u64(0b1111))
	// Version 1 has no global control.
	identification := intel_version_4()
	identification.intel_monitoring_a = identification.intel_monitoring_a &~ 0xFF | 1
	plan, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.None)
	testing.expect_value(t, plan.global_control, u32(0))
}

// What an Intel processor lacks: the leaf, its version, four counters, or
// one of the four events.
@(test)
the_intel_processors_with_no_plan :: proc(t: ^testing.T) {
	identification := intel_version_4()
	identification.highest_leaf = INTEL_MONITORING_LEAF - 1
	_, absence := plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Intel_No_Monitoring)

	identification = intel_version_4()
	identification.intel_monitoring_a &~= 0xFF
	_, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Intel_No_Monitoring)

	identification = intel_version_4()
	identification.intel_monitoring_a = identification.intel_monitoring_a &~ 0xFF00 | (EVENT_COUNT - 1) << 8
	_, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Intel_Too_Few_Counters)

	for event in Event {
		identification = intel_version_4()
		identification.intel_monitoring_b = u32(1) << INTEL_EVENT_ABSENT_BITS[event]
		_, absence = plan_of_identification(identification)
		testing.expect_value(t, absence, Absence.Intel_Event_Absent)
	}

	// A vector of EBX too short to name the branch misses: absent.
	identification = intel_version_4()
	identification.intel_monitoring_a = identification.intel_monitoring_a &~ 0xFF00_0000 | INTEL_EVENT_ABSENT_BITS[.Branch_Misses] << 24
	_, absence = plan_of_identification(identification)
	testing.expect_value(t, absence, Absence.Intel_Event_Absent)
}

// A processor of another vendor has no plan, and each absence has a text.
@(test)
another_vendor_has_no_plan :: proc(t: ^testing.T) {
	plan, absence := plan_of_identification({vendor_b = 0x6E65_7448, highest_leaf = 0x20}) // Neither Intel nor AMD.
	testing.expect_value(t, absence, Absence.Unknown_Vendor)
	testing.expect_value(t, plan.vendor, Vendor.None)
	for text, which in ABSENCE_TEXTS {
		testing.expectf(t, (which == .None) == (text == ""), "the absence %v has the text %q", which, text)
	}
}

// The trial of the plan of the test machine: each select is read before any
// write, each counter is written, read back and written 0 before the select
// of its event, and each select ends at 0.
@(test)
the_trial_of_the_test_machine :: proc(t: ^testing.T) {
	plan, _ := plan_of_identification(zen_3())
	steps, count := trial_steps_of_plan(plan)
	testing.expect_value(t, count, 6 * EVENT_COUNT) // No global control on the test machine.
	for event in Event {
		testing.expect_value(t, steps[u32(event)], Trial_Step{.Read_Select_Off, plan.select_registers[event], 0})
		first := EVENT_COUNT + 5 * u32(event)
		testing.expect_value(t, steps[first + 0], Trial_Step{.Write, plan.counter_registers[event], TRIAL_COUNTER_VALUE})
		testing.expect_value(t, steps[first + 1], Trial_Step{.Read_Back, plan.counter_registers[event], TRIAL_COUNTER_VALUE})
		testing.expect_value(t, steps[first + 2], Trial_Step{.Write, plan.counter_registers[event], 0})
		testing.expect_value(t, steps[first + 3], Trial_Step{.Write, plan.select_registers[event], plan.select_values[event]})
		testing.expect_value(t, steps[first + 4], Trial_Step{.Write, plan.select_registers[event], 0})
	}
	// No write before the last read of a select.
	for step, index in steps[:count] {
		if step.kind != .Read_Select_Off {
			testing.expectf(t, u32(index) >= EVENT_COUNT, "the step %d writes before each select was read", index)
		}
	}
	// On Intel with no full-width writes, a counter keeps 32 bits and extends bit 31.
	testing.expect(t, TRIAL_COUNTER_VALUE & (u64(1) << 31) == 0)
	testing.expect(t, TRIAL_COUNTER_VALUE != 0)
}

// A plan with a global control ends its trial with it; no plan has no
// trial.
@(test)
the_trial_of_a_global_control :: proc(t: ^testing.T) {
	plan, _ := plan_of_identification(intel_version_4())
	steps, count := trial_steps_of_plan(plan)
	testing.expect_value(t, count, TRIAL_STEP_CAPACITY)
	testing.expect_value(t, steps[count - 1], Trial_Step{.Add_Bits, INTEL_GLOBAL_CONTROL, GLOBAL_CONTROL_FOUR_COUNTERS})
	_, none_count := trial_steps_of_plan({})
	testing.expect_value(t, none_count, u32(0))
}

// Each outcome of a step: a refusal of the processor at any step, a select
// that is on, a counter that keeps another value; else the step passes.
@(test)
the_outcome_of_a_trial_step :: proc(t: ^testing.T) {
	plan, _ := plan_of_identification(zen_3())
	steps, count := trial_steps_of_plan(plan)
	for step in steps[:count] {
		testing.expect_value(t, trial_step_outcome(step, false, 0), Absence.Register_Refused)
	}
	select_read := steps[0]
	testing.expect_value(t, trial_step_outcome(select_read, true, 0), Absence.None)
	// A select with event bits and Enable clear is off.
	testing.expect_value(t, trial_step_outcome(select_read, true, plan.select_values[.Instructions_Retired] &~ SELECT_ENABLE), Absence.None)
	testing.expect_value(t, trial_step_outcome(select_read, true, SELECT_ENABLE), Absence.Counter_In_Use)
	read_back := steps[EVENT_COUNT + 1]
	testing.expect_value(t, read_back.kind, Trial_Step_Kind.Read_Back)
	testing.expect_value(t, trial_step_outcome(read_back, true, TRIAL_COUNTER_VALUE), Absence.None)
	testing.expect_value(t, trial_step_outcome(read_back, true, 0), Absence.Counter_Not_Kept)
	testing.expect_value(t, trial_step_outcome(read_back, true, TRIAL_COUNTER_VALUE + 1), Absence.Counter_Not_Kept)
	// A write that the processor took passes, whatever it wrote.
	testing.expect_value(t, trial_step_outcome(steps[EVENT_COUNT], true, 0), Absence.None)
}

// The line of an outcome of the trial names its register; the line of an
// absence in CPUID does not.
@(test)
the_absences_that_name_a_register :: proc(t: ^testing.T) {
	for which in Absence {
		names := absence_names_a_register(which)
		testing.expectf(t, names == (which >= .Register_Refused), "the absence %v names a register: %v", which, names)
	}
}
