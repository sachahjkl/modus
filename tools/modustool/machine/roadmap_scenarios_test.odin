// Host unit tests for decoupled roadmap machine scenario builders
// (roadmap_scenarios.odin).
package machine

import "core:strings"
import "core:testing"
import op "modus:contract/operation"

@(test)
roadmap_write_combining_matrix_and_steps_hold :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for item in write_combining_refusal_cases() {
		refused := op.map_write_combining_refused(item.flags, item.device_memory)
		testing.expectf(t, refused == item.must_refuse, "write-combining case %s expected refused=%v got %v", item.label, item.must_refuse, refused)
	}

	steps := scenario_write_combining_steps(context.temp_allocator)
	testing.expect(t, len(steps) >= 4, "write-combining scenario has boot, check, and shutdown steps")
	for step, index in steps {
		if step.kind == .Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "write-combining step %d untypeable at %d: %q", index + 1, unknown, step.text)
		}
	}
	testing.expect_value(t, steps[len(steps) - 1].text, "kernel: the machine stops with code 0")
}

@(test)
roadmap_display_contract_steps_forbid_compositor_internals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Bad module names are refused.
	_, ref := scenario_display_contract_steps("", context.temp_allocator)
	testing.expect_value(t, ref, Roadmap_Scenario_Refusal.Empty_Module_Name)
	_, ref = scenario_display_contract_steps("bad name", context.temp_allocator)
	testing.expect_value(t, ref, Roadmap_Scenario_Refusal.Invalid_Module_Name)
	_, ref = scenario_display_contract_steps("../escape", context.temp_allocator)
	testing.expect_value(t, ref, Roadmap_Scenario_Refusal.Invalid_Module_Name)

	// Valid display-contract scenario passes validator with zero compositor internals.
	steps, ok_ref := scenario_display_contract_steps("monitor", context.temp_allocator)
	testing.expect_value(t, ok_ref, Roadmap_Scenario_Refusal.None)
	testing.expect_value(t, scenario_display_contract_validate(steps), Roadmap_Scenario_Refusal.None)

	// Validator refuses empty steps and any compositor internal wait/call/button.
	testing.expect_value(t, scenario_display_contract_validate(nil), Roadmap_Scenario_Refusal.Empty_Steps)
	for bad_step in ([]Step{
		{kind = .Wait, text = "compositor: surface monitor"},
		{kind = .Type, text = "compositor.windows()"},
		{kind = .Click, text = BAR_START_BUTTON},
		{kind = .Click, text = BAR_WINDOWS_BUTTON},
	}) {
		one := [1]Step{bad_step}
		testing.expect_value(t, scenario_display_contract_validate(one[:]), Roadmap_Scenario_Refusal.Forbidden_Compositor_Internal)
	}
}

@(test)
roadmap_collector_sources_and_tpm_pins_steps_are_well_formed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Collector sources refuses empty and invalid server names.
	_, bad_ref := scenario_collector_sources_steps("", context.temp_allocator)
	testing.expect_value(t, bad_ref, Roadmap_Scenario_Refusal.Empty_Module_Name)
	_, bad_ref = scenario_collector_sources_steps("bad/name", context.temp_allocator)
	testing.expect_value(t, bad_ref, Roadmap_Scenario_Refusal.Invalid_Module_Name)

	col_steps, col_ref := scenario_collector_sources_steps("sample", context.temp_allocator)
	testing.expect_value(t, col_ref, Roadmap_Scenario_Refusal.None)
	has_wire := false
	has_follow := false
	for step, index in col_steps {
		if step.kind == .Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "collector step %d untypeable at %d: %q", index + 1, unknown, step.text)
			if strings.contains(step.text, "wire(sample.log, collector.sources)") {
				has_wire = true
			}
			if strings.contains(step.text, "log.follow |> where(level = Warning)") {
				has_follow = true
			}
		}
	}
	testing.expect(t, has_wire, "collector scenario wires sample.log to collector.sources")
	testing.expect(t, has_follow, "collector scenario runs log.follow filtered by Warning")

	// TPM pins two-boot scenarios cover seal on boot 1 and tamper refusal on boot 2.
	boot1 := scenario_tpm_pins_steps(.First_Boot_Seal, context.temp_allocator)
	boot2 := scenario_tpm_pins_steps(.Second_Boot_Tampered_Refusal, context.temp_allocator)
	has_seal := false
	for step, index in boot1 {
		if step.kind == .Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "tpm boot1 step %d untypeable at %d: %q", index + 1, unknown, step.text)
			if step.text == "machine_seal()" {
				has_seal = true
			}
		}
	}
	testing.expect(t, has_seal, "tpm boot1 runs machine_seal()")

	has_refusal_wait := false
	for step in boot2 {
		if step.kind == .Wait && strings.has_prefix(step.text, "unlock: the TPM service refuses") {
			has_refusal_wait = true
			testing.expect(t, strings.contains(step.fails_on, "unlock: the TPM releases the machine key"), "tpm boot2 fails if tampered key unseals")
		}
	}
	testing.expect(t, has_refusal_wait, "tpm boot2 waits for TPM refusal on tampered record")
}
