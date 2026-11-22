// Delegated projects service implementing Role.Projects
// (src/md/features/declarations.md, "The services of the declarations").
//
// Reads pins.lex for projects.inputs, coordinates canonical pins.lex-only
// updates through the unified Source_Resolver contract for projects.update,
// and manages ephemeral child console contexts for projects.enter and exit
// with zero installed state.
package projects_service

import "base:intrinsics"
import "internal:projects/projects_core"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"

// Working memory budget for the freestanding projects service process.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256, processes = 1, threads = 1}

// Status record returned by the status() export.
Projects_Status :: struct {
	total_inputs_queries: i64,
	total_updates:        i64,
	total_enters:         i64,
	total_exits:          i64,
	active_consoles:      i64,
	total_refusals:       i64,
}

// Package-level BSS state so buffers never live on the stack.
service_state: projects_core.Projects_State
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Private BSS buffers for copy-then-check reading of shared memory.
copied_pins_lex: [pr.MAX_PINS_LEX_BYTES]u8
staged_pins: [pr.MAX_PROJECT_PINS]pr.Pin_Entry
copied_console_spec: pr.Project_Console_Spec
copied_caller_stores: [pr.MAX_CONSOLE_STORES]pr.Project_Console_Store
staged_console_ctx: projects_core.Child_Console_Context

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

@(private = "file")
region_range_valid :: proc "contextless" (offset: u64, length: u64) -> bool {
	if service_region_base == nil || length == 0 || length > service_region_bytes {
		return false
	}
	return offset <= service_region_bytes - length
}

// status writes aggregate projects service counters into out.
@(export)
status :: proc "c" (out: ^Projects_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	out^ = {
		total_inputs_queries = i64(service_state.counters.total_inputs_queries),
		total_updates        = i64(service_state.counters.total_updates),
		total_enters         = i64(service_state.counters.total_enters),
		total_exits          = i64(service_state.counters.total_exits),
		active_consoles      = i64(service_state.counters.active_consoles),
		total_refusals       = i64(service_state.counters.total_refusals),
	}
	return 0
}

// active_console_count returns the number of currently open child consoles.
@(export)
active_console_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !service_state.initialized {
		return errors.fail(error, -1, .State, .Requests)
	}
	return i64(service_state.counters.active_consoles)
}

// pin_count returns the pins of the last pins.lex that a command List_Inputs
// read whole, or 0 before the first one. A pins.lex that the service refuses
// does not change it.
@(export)
pin_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !service_state.initialized {
		return errors.fail(error, -1, .State, .Requests)
	}
	return i64(service_state.counters.last_pin_count)
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record) {
	parsed, ok := pr.projects_ring_command_of_word(command.kind)
	if !ok {
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return
	}

	switch parsed {
	case .None:
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
	case .List_Inputs:
		pins_offset := command.values[0]
		pins_length := command.values[1]
		out_offset := command.values[2]
		if pins_length == 0 || pins_length > pr.MAX_PINS_LEX_BYTES || !region_range_valid(pins_offset, pins_length) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(pins_length), pr.MAX_PINS_LEX_BYTES),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_pins_lex[0], rawptr(&service_region_base[pins_offset]), int(pins_length))
		count, refusal := projects_core.list_inputs(&service_state, copied_pins_lex[:pins_length], staged_pins[:])
		if refusal != .None {
			system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		if count > 0 {
			byte_len := u64(count) * size_of(pr.Pin_Entry)
			if region_range_valid(out_offset, byte_len) {
				intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_pins[0], int(byte_len))
			}
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(count), 0, 0, 0, 0, 0, 0},
			},
		)
	case .Update_Pins:
		// Without an attached source resolver module on the ring, refuse cleanly.
		system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(pr.Project_Refusal.Bad_Resolver_Status)})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Refused),
				tag    = command.tag,
				values = {u64(pr.Project_Refusal.Bad_Resolver_Status), 0, 0, 0, 0, 0, 0},
			},
		)
	case .Enter_Project:
		spec_offset := command.values[0]
		caller_stores_offset := command.values[1]
		caller_stores_count := command.values[2]
		ctx_out_offset := command.values[3]
		if caller_stores_count > pr.MAX_CONSOLE_STORES || !region_range_valid(spec_offset, size_of(pr.Project_Console_Spec)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(spec_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_console_spec, rawptr(&service_region_base[spec_offset]), size_of(pr.Project_Console_Spec))
		caller_slice: []pr.Project_Console_Store = nil
		if caller_stores_count > 0 {
			stores_bytes := caller_stores_count * size_of(pr.Project_Console_Store)
			if !region_range_valid(caller_stores_offset, stores_bytes) {
				ring.push(
					&service_ring.completions,
					ring.Record{
						kind   = u32(pr.Service_Ring_Status.Bad_Command),
						tag    = command.tag,
						values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 2, i64(caller_stores_offset), i64(service_region_bytes)),
					},
				)
				return
			}
			intrinsics.mem_copy_non_overlapping(&copied_caller_stores[0], rawptr(&service_region_base[caller_stores_offset]), int(stores_bytes))
			caller_slice = copied_caller_stores[:caller_stores_count]
		}
		ctx, refusal := projects_core.enter_project(&service_state, &copied_console_spec, caller_slice)
		if refusal != .None {
			system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		staged_console_ctx = ctx
		if region_range_valid(ctx_out_offset, size_of(projects_core.Child_Console_Context)) {
			intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[ctx_out_offset]), &staged_console_ctx, size_of(projects_core.Child_Console_Context))
		}
		system.log_fact(.Info, Project_Entered{console_id = ctx.console_id, principal = ctx.principal})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {ctx.console_id, u64(ctx.module_count), u64(ctx.store_count), u64(ctx.depth), 0, 0, 0},
			},
		)
	case .Exit_Project:
		console_id := command.values[0]
		principal := command.values[1]
		report: projects_core.Exit_Teardown_Report
		refusal: pr.Project_Refusal
		if console_id == 0 {
			report, refusal = projects_core.exit_current_project(&service_state, principal)
		} else {
			report, refusal = projects_core.exit_project_with_report(&service_state, console_id, principal)
		}
		if refusal != .None {
			system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		system.log_fact(.Info, Project_Exited{console_id = report.exited_console_id, principal = principal})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {report.exited_console_id, service_state.counters.active_consoles, report.restored_parent_id, u64(report.restored_depth), u64(report.revoked_module_count), u64(report.revoked_store_count), 0},
			},
		)
	}
}

// entry initializes the delegated projects service ring and serves project
// input, update, enter, and exit commands until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: system.Status
	if service_ring, open_status = system.ring_open(ctx.handles[pr.PROJECTS_SERVICE_RING_SLOT]); open_status != .Ok {
		fail("no projects service ring")
	}
	region_handle := ctx.handles[pr.PROJECTS_SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the projects data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the projects data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	projects_core.state_init(&service_state, u32(ctx.values[pr.PROJECTS_CONTEXT_VALUE_DISPLAY_SLOT]))
	system.log_fact(.Info, Service_Ready{})

	for {
		wait := system.wait_begin()
		answered := false
		for ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
			command := system.receive(&service_ring.commands) or_break
			handle_command(command)
			answered = true
		}
		if answered {
			system.wake_reader(&service_ring.completions)
		}
		system.wait_records(&wait, &service_ring.commands)
		system.wait_end(&wait)
	}
}
