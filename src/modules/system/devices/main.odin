// Delegated devices service implementing Role.Devices
// (src/md/api/root_service_split.md).
//
// Owns PCI device identity matching and attenuated per-device grant minting so
// each device service receives only its own registers, interrupt, read-only
// configuration view, and IOMMU permission.
package devices_service

import "base:intrinsics"
import dc "internal:devices/devices_core"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/value_kinds"
import "modus:system"

// Working memory budget for the freestanding devices service process and its
// fixed-capacity identity and binding tables, and the shared region of the
// root service with one bind place for each process slot: 32 pages and
// their page tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 256, processes = 1, threads = 1}

// Status record returned by the status() export.
Devices_Status :: struct {
	identity_count:  i64,
	active_bindings: i64,
	total_binds:     i64,
	total_releases:  i64,
	total_refusals:  i64,
}

// Package-level BSS state so shared-memory staging never lives on the stack.
service_state: dc.Devices_State
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

copied_identity: rd.Device_Identity_Entry
copied_discovered: rd.Pci_Discovered_Device
staged_grant_spec: rd.Device_Grant_Spec
staged_binding: dc.Device_Binding

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

// status writes aggregate devices service counters into result.
@(export)
status :: proc "c" (result: ^Devices_Status, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	if result == nil {
		outcome, _ := call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
		return outcome
	}
	if !service_state.initialized {
		outcome, _ := call_outcome.fail(error, .Wrong_State, .State, .Requests)
		return outcome
	}
	result^ = {
		identity_count  = i64(service_state.counters.identity_count),
		active_bindings = i64(service_state.counters.active_bindings),
		total_binds     = i64(service_state.counters.total_binds),
		total_releases  = i64(service_state.counters.total_releases),
		total_refusals  = i64(service_state.counters.total_refusals),
	}
	return .Succeeded
}

@(private = "file")
reply_bad_command :: proc "contextless" (command: ring.Record, kind: errors.Kind, arg: i64, value: i64, limit: i64 = 0) {
	ring.push(
		&service_ring.completions,
		ring.Record{
			kind   = u32(rd.Devices_Ring_Status.Bad_Command),
			tag    = command.tag,
			values = errors.ring_fail(command.kind, kind, .Bytes, arg, value, limit),
		},
	)
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record) {
	parsed, ok := rd.devices_ring_command_from_word(command.kind)
	if !ok {
		reply_bad_command(command, .Unsupported, 0, i64(command.kind))
		return
	}

	switch parsed {
	case .None:
		reply_bad_command(command, .Unsupported, 0, i64(command.kind))

	case .Register_Identity:
		entry_offset := command.values[0]
		if !region_range_valid(entry_offset, size_of(rd.Device_Identity_Entry)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(entry_offset), i64(service_region_bytes))
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_identity, rawptr(&service_region_base[entry_offset]), size_of(rd.Device_Identity_Entry))
		refusal := dc.register_identity(&service_state, copied_identity)
		if refusal != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Devices_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Devices_Ring_Status.Ok),
				tag    = command.tag,
				values = {service_state.counters.identity_count, 0, 0, 0, 0, 0, 0},
			},
		)

	case .Bind_Device:
		disc_offset := command.values[0]
		service_slot := u32(command.values[1])
		out_offset := command.values[2]
		identity_word := command.values[3]
		if !region_range_valid(disc_offset, size_of(rd.Pci_Discovered_Device)) || !region_range_valid(out_offset, size_of(rd.Device_Grant_Spec)) {
			reply_bad_command(command, .Out_Of_Range, 1, i64(disc_offset), i64(service_region_bytes))
			return
		}
		// The check of the identity runs on the copy: the core can write
		// the place again after the copy, never between the check and the
		// bind.
		intrinsics.mem_copy_non_overlapping(&copied_discovered, rawptr(&service_region_base[disc_offset]), size_of(rd.Pci_Discovered_Device))
		spec, bind_ref, grant_ref := dc.bind_device(&service_state, &copied_discovered, service_slot, identity_word)
		if bind_ref != .None {
			system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind), refusal_code = u64(bind_ref)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Devices_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(bind_ref), u64(grant_ref), 0, 0, 0, 0, 0},
				},
			)
			return
		}
		staged_grant_spec = spec
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_grant_spec, size_of(rd.Device_Grant_Spec))
		system.log_fact(.Info, Device_Bound{
			role         = u64(spec.role),
			bus          = u64(spec.location.bus),
			device       = u64(spec.location.device),
			function     = u64(spec.location.function),
			service_slot = u64(service_slot),
		})
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Devices_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(spec.role), spec.granted_rights_word, 0, 0, 0, 0, 0},
			},
		)

	case .Release_Device:
		loc := rd.Pci_Location{bus = u8(command.values[0]), device = u8(command.values[1]), function = u8(command.values[2])}
		if !dc.release_device(&service_state, loc) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Devices_Ring_Status.Refused),
					tag    = command.tag,
					values = {0, 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Devices_Ring_Status.Ok),
				tag    = command.tag,
				values = {service_state.counters.active_bindings, 0, 0, 0, 0, 0, 0},
			},
		)

	case .Lookup_Identity:
		// A word past 16 bits names no PCI identifier, and a word after the
		// two identifiers is no part of the command.
		for word, index in command.values {
			limit := index < 2 ? u64(max(u16)) : 0
			if word > limit {
				reply_bad_command(command, .Out_Of_Range, i64(index) + 1, i64(word), i64(limit))
				return
			}
		}
		entry, refusal := dc.lookup_identity(&service_state, u16(command.values[0]), u16(command.values[1]))
		if refusal != .None {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Devices_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(refusal), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Devices_Ring_Status.Ok),
				tag    = command.tag,
				values = rd.device_identity_answer_values(entry),
			},
		)

	case .Query_Binding:
		loc := rd.Pci_Location{bus = u8(command.values[0]), device = u8(command.values[1]), function = u8(command.values[2])}
		out_offset := command.values[3]
		if !region_range_valid(out_offset, size_of(dc.Device_Binding)) {
			reply_bad_command(command, .Out_Of_Range, 4, i64(out_offset), i64(service_region_bytes))
			return
		}
		binding, found := dc.find_binding(&service_state, loc)
		if !found {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(rd.Devices_Ring_Status.Refused),
					tag    = command.tag,
					values = {0, 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		staged_binding = binding
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_binding, size_of(dc.Device_Binding))
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(rd.Devices_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(binding.grant_spec.role), u64(binding.service_slot), 0, 0, 0, 0, 0},
			},
		)
	}
}

// entry initializes the delegated devices service ring and serves PCI identity
// registration, device binding, release, and query commands until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: call_outcome.Call_Outcome
	if service_ring, open_status = system.ring_open(ctx.handles[rd.DEVICES_RING_SLOT]); open_status != .Succeeded {
		fail("no devices service ring")
	}
	region_handle := ctx.handles[rd.DEVICES_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Succeeded || pages == 0 {
			fail("the devices data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Succeeded {
			fail("cannot map the devices data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	dc.state_init(&service_state)
	system.log_fact(.Info, Service_Ready{identities = service_state.counters.identity_count})

	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
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
