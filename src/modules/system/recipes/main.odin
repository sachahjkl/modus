// Delegated recipes service implementing Role.Recipes
// (src/md/features/recipes.md).
//
// Evaluates recipes.build requests against local content-addressed storage,
// remote object_cache substitution policies, and deterministic sandboxed
// builders, hashing outputs with tree_hash and recording provenance.
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"

// Working memory budget for the freestanding recipes service process, including
// local object staging and realisation tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1024, processes = 1, threads = 1}

// Status record returned by the status() export.
Recipes_Status :: struct {
	total_builds:         i64,
	cache_hits_local:     i64,
	cache_hits_remote:    i64,
	local_builds:         i64,
	verify_agreements:    i64,
	verify_disagreements: i64,
	total_refusals:       i64,
}

// Package-level BSS state so large staging buffers never live on the stack.
service_state: recipes_core.Recipes_State
service_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64

// Private BSS buffers for copy-then-check reading of shared memory.
copied_spec: pr.Recipe_Spec
staged_result: pr.Recipe_Build_Result
staged_provenance: recipes_core.Local_Realisation_Slot

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

// status writes aggregate recipes service counters into out.
@(export)
status :: proc "c" (out: ^Recipes_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return errors.fail(error, -2, .State, .Requests)
	}
	out^ = {
		total_builds         = i64(service_state.counters.total_builds),
		cache_hits_local     = i64(service_state.counters.cache_hits_local),
		cache_hits_remote    = i64(service_state.counters.cache_hits_remote),
		local_builds         = i64(service_state.counters.local_builds),
		verify_agreements    = i64(service_state.counters.verify_agreements),
		verify_disagreements = i64(service_state.counters.verify_disagreements),
		total_refusals       = i64(service_state.counters.total_refusals),
	}
	return 0
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record) {
	parsed, ok := pr.recipes_ring_command_of_word(command.kind)
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
	case .Build_Recipe:
		spec_offset := command.values[0]
		mode_word := command.values[1]
		result_offset := command.values[2]
		if !region_range_valid(spec_offset, size_of(pr.Recipe_Spec)) || !region_range_valid(result_offset, size_of(pr.Recipe_Build_Result)) {
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
		mode, mode_ok := pr.build_mode_of_word(mode_word)
		if !mode_ok {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(pr.Recipe_Refusal.Bad_Build_Mode), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		intrinsics.mem_copy_non_overlapping(&copied_spec, rawptr(&service_region_base[spec_offset]), size_of(pr.Recipe_Spec))
		policy := object_cache.Substitution_Policy{mode = .Prefer_Cache}
		staged_result = recipes_core.build_recipe(&service_state, &copied_spec, mode, policy, nil, nil, nil, nil, nil)
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[result_offset]), &staged_result, size_of(pr.Recipe_Build_Result))
		if staged_result.refusal == .Verify_Disagreement {
			system.log_fact(.Warning, Realisation_Disagreement{disagreements = service_state.counters.verify_disagreements})
		} else {
			system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(staged_result.outcome), refusal_code = u64(staged_result.refusal)})
		}
		status_word := staged_result.refusal == .None ? u32(pr.Service_Ring_Status.Ok) : u32(pr.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(staged_result.outcome), u64(staged_result.refusal), staged_result.verified_reproducible ? 1 : 0, 0, 0, 0, 0},
			},
		)
	case .Query_Provenance:
		hash_offset := command.values[0]
		out_offset := command.values[1]
		if !region_range_valid(hash_offset, size_of(blake3.Hash)) || !region_range_valid(out_offset, size_of(recipes_core.Local_Realisation_Slot)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(hash_offset), i64(service_region_bytes)),
				},
			)
			return
		}
		rhash: blake3.Hash
		intrinsics.mem_copy_non_overlapping(&rhash, rawptr(&service_region_base[hash_offset]), size_of(blake3.Hash))
		slot, found := recipes_core.query_provenance(&service_state, rhash)
		if !found {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(pr.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(pr.Recipe_Refusal.Cache_Miss), 0, 0, 0, 0, 0, 0},
				},
			)
			return
		}
		staged_provenance = slot
		intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[out_offset]), &staged_provenance, size_of(recipes_core.Local_Realisation_Slot))
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(slot.origin), slot.verified_reproducible ? 1 : 0, 0, 0, 0, 0, 0},
			},
		)
	case .Query_Counts:
		counters := service_state.counters
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(pr.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					counters.total_builds,
					counters.cache_hits_local,
					counters.cache_hits_remote,
					counters.local_builds,
					counters.verify_agreements,
					counters.verify_disagreements,
					counters.total_refusals,
				},
			},
		)
	}
}

// entry initializes the delegated recipes service ring and loops over build
// and provenance commands until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	open_status: system.Status
	if service_ring, open_status = system.ring_open(ctx.handles[pr.RECIPES_SERVICE_RING_SLOT]); open_status != .Ok {
		fail("no recipes service ring")
	}
	region_handle := ctx.handles[pr.RECIPES_SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the recipes data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the recipes data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	recipes_core.state_init(&service_state)
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
