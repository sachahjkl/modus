// Decoupled pure scenario step builders and validators for roadmap machine
// cases: write-combining device memory, second display holder contract-only
// verification, collector `sources` record-input wiring, and TPM pins tamper
// and rollback refusal across two boots.
//
// Keeps zero direct references to `scenario` or `BOOT_VOLUME` so per-part Nix
// binaries stay decoupled.
package machine

import "core:strings"
import op "modus:contract/operation"

// Format property: safe ASCII module name length bound for scenario builders.
ROADMAP_SCENARIO_NAME_MAX_BYTES :: 48

// Closed refusal set for decoupled roadmap scenario builders and validators.
Roadmap_Scenario_Refusal :: enum u8 {
	None,
	Empty_Module_Name,
	Invalid_Module_Name,
	Empty_Steps,
	Forbidden_Compositor_Internal,
}

// Closed boot phase selection for the two-boot TPM pins tamper scenario.
Tpm_Pins_Phase :: enum u8 {
	First_Boot_Seal,
	Second_Boot_Tampered_Refusal,
}

// One write-combining device memory refusal or acceptance check row.
Write_Combining_Case :: struct {
	label:         string,
	flags:         op.Map_Flags,
	device_memory: bool,
	must_refuse:   bool,
}

@(private = "file")
roadmap_module_name_valid :: proc(name: string) -> Roadmap_Scenario_Refusal {
	if len(name) == 0 {
		return .Empty_Module_Name
	}
	if len(name) > ROADMAP_SCENARIO_NAME_MAX_BYTES {
		return .Invalid_Module_Name
	}
	for b in transmute([]u8)name {
		is_alpha := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
		is_digit := b >= '0' && b <= '9'
		if !is_alpha && !is_digit && b != '_' {
			return .Invalid_Module_Name
		}
	}
	return .None
}

// write_combining_refusal_cases returns the canonical refusal and acceptance
// matrix for Map_Flag.Write_Combining (normal memory, Execute, device memory).
write_combining_refusal_cases :: proc() -> [6]Write_Combining_Case {
	return {
		{label = "normal_memory_wc_refused", flags = {.Write_Combining}, device_memory = false, must_refuse = true},
		{label = "normal_memory_rw_wc_refused", flags = {.Write, .Write_Combining}, device_memory = false, must_refuse = true},
		{label = "device_memory_wc_exec_refused", flags = {.Write_Combining, .Execute}, device_memory = true, must_refuse = true},
		{label = "device_memory_rw_wc_exec_refused", flags = {.Write, .Write_Combining, .Execute}, device_memory = true, must_refuse = true},
		{label = "device_memory_ro_wc_accepted", flags = {.Write_Combining}, device_memory = true, must_refuse = false},
		{label = "device_memory_rw_wc_accepted", flags = {.Write, .Write_Combining}, device_memory = true, must_refuse = false},
	}
}

// scenario_write_combining_steps builds the machine step sequence verifying
// console boot, memory mapping report stability, and clean shutdown for the
// write-combining device memory case.
scenario_write_combining_steps :: proc(allocator := context.allocator) -> []Step {
	steps := make([dynamic]Step, allocator)
	append(&steps, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "memory()"})
	append(&steps, Step{kind = .Wait, text = "[console]   interrupts"})
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return steps[:]
}

// scenario_display_contract_steps builds a second-display-holder scenario that
// waits strictly on display-contract lines (`display: ...`) and console
// process commands rather than compositor-specific internals.
scenario_display_contract_steps :: proc(window_module := "monitor", allocator := context.allocator) -> (steps: []Step, refusal: Roadmap_Scenario_Refusal) {
	if name_ref := roadmap_module_name_valid(window_module); name_ref != .None {
		return nil, name_ref
	}
	list := make([dynamic]Step, allocator)
	append(&list, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&list, Step{kind = .Type, text = strings.concatenate({"start(\"", window_module, "\")"}, allocator)})
	append(&list, Step{kind = .Wait, text = strings.concatenate({"display: ", window_module, WINDOW_TAKEN}, allocator), any_order = true})
	append(&list, Step{kind = .Type, text = strings.concatenate({"stop(\"", window_module, "\")"}, allocator)})
	append(&list, Step{kind = .Wait, text = strings.concatenate({"root: ", window_module, " stopped"}, allocator)})
	append(&list, Step{kind = .Type, text = "shutdown()"})
	append(&list, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return list[:], .None
}

// scenario_display_contract_validate ensures a display-contract scenario never
// depends on compositor-specific log prefixes, `compositor.windows()`, or
// bar start-menu internals.
scenario_display_contract_validate :: proc(steps: []Step) -> Roadmap_Scenario_Refusal {
	if len(steps) == 0 {
		return .Empty_Steps
	}
	for step in steps {
		if strings.contains(step.text, "compositor:") ||
		   strings.contains(step.text, "compositor.") ||
		   step.text == BAR_START_BUTTON ||
		   step.text == BAR_WINDOWS_BUTTON {
			return .Forbidden_Compositor_Internal
		}
	}
	return .None
}

// scenario_collector_sources_steps builds the machine step sequence wiring a
// module's `log` record output into `collector.sources` and following warnings
// in the console without drawing self-echo rows.
scenario_collector_sources_steps :: proc(server_module := "sample", allocator := context.allocator) -> (steps: []Step, refusal: Roadmap_Scenario_Refusal) {
	if name_ref := roadmap_module_name_valid(server_module); name_ref != .None {
		return nil, name_ref
	}
	list := make([dynamic]Step, allocator)
	append(&list, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&list, Step{kind = .Front, text = "console"})
	append(&list, Step{kind = .Type, text = strings.concatenate({"start(\"", server_module, "\", wire(", server_module, ".log, collector.sources))"}, allocator)})
	append(&list, Step{kind = .Type, text = "log.follow |> where(level = Warning) |> first(1)"})
	append(&list, Step{kind = .Type, text = "shutdown()"})
	append(&list, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return list[:], .None
}

// scenario_tpm_pins_steps builds either boot of the two-boot TPM pins
// tampering and rollback refusal machine scenario.
scenario_tpm_pins_steps :: proc(phase: Tpm_Pins_Phase, allocator := context.allocator) -> []Step {
	list := make([dynamic]Step, allocator)
	append(&list, Step{kind = .Wait, text = "boot program: started"})
	append(&list, Step{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE})
	append(&list, Step{kind = .Wait, text = "root: started tpm for the TPM at ", any_order = true})
	append(&list, Step{kind = .Wait, text = "tpm: ok, the CRB interface at ", any_order = true})
	append(&list, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	switch phase {
	case .First_Boot_Seal:
		append(&list, Step{kind = .Front, text = "console"})
		append(&list, Step{kind = .Type, text = "machine_seal()"})
		append(&list, Step{kind = .Wait, text = "unlock: the record of the machine key sealed by the TPM is in the store of unlock: its recovery key is written down"})
	case .Second_Boot_Tampered_Refusal:
		append(&list, Step{kind = .Wait, text = "unlock: the TPM service refuses the ", fails_on = "unlock: the TPM releases the machine key: "})
	}
	append(&list, Step{kind = .Front, text = "console"})
	append(&list, Step{kind = .Type, text = "shutdown()"})
	append(&list, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return list[:]
}
