// The exports of the guest builder that run no guest: the counts of its
// builds, and the check of the disks of a build before it runs
// (src/md/features/recipes.md, "The three kinds of builder").
package guest_builder_module

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import contract "modus:contract/guest_builder"
import "modus:contract/value_kinds"
import "modus:guest_regions"
import "modus:system"

// The counts of the builds of this process and the end of the last one.
Guest_Builder_Status :: struct {
	builds:                i64,
	succeeded:             i64,
	refused:               i64,
	failed:                i64,
	timed_out:             i64,
	last_state:            i64,
	last_refusal:          i64,
	last_tree_bytes:       i64,
	last_output_tree_hash: value_kinds.Hash_Field,
}

// The counts that build adds to at each end that it reports.
build_counts: Guest_Builder_Status

// builds_count adds one build that ended in state with refusal.
builds_count :: proc "contextless" (state: contract.Guest_Build_State, refusal: contract.Guest_Builder_Refusal) {
	build_counts.builds += 1
	switch state {
	case .Succeeded:
		build_counts.succeeded += 1
	case .Refused:
		build_counts.refused += 1
	case .Failed:
		build_counts.failed += 1
	case .Timed_Out:
		build_counts.timed_out += 1
	case .Prepared, .Running:
		// An end in these states is a build that stopped before its run:
		// it counts as failed, as no output came of it.
		build_counts.failed += 1
	}
	build_counts.last_state = i64(state)
	build_counts.last_refusal = i64(refusal)
	build_counts.last_tree_bytes = i64(sandbox_runner.output_tree_bytes_written)
	build_counts.last_output_tree_hash = value_kinds.Hash_Field(sandbox_runner.output_tree_hash)
}

// status gives the counts of the builds of this process in one row.
//
// The result is 1.
@(export, link_name = "status")
status :: proc "c" (result: ^[]Guest_Builder_Status, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if len(result^) > 0 {
		result[0] = build_counts
	}
	return .Succeeded, 1
}

// disks_check checks a build before it runs, with no guest: the spec, the
// input disk as a read-only disk of inputs, and the bound of the blank
// output disk against what this process holds. A build that passes it can
// still fail in its guest, never at its disks.
//
// - **spec_bytes**: the canonical Guest_Build_Spec.
// - **input_disk**: the MODGBD1 image of the inputs; empty for no input.
//
// The result is the bytes of the blank output disk that the build gives the
// guest, or the outcome Argument_Refused with an error record whose value found is the
// Guest_Builder_Refusal.
@(export, link_name = "disks_check")
disks_check :: proc "c" (spec_bytes: ^system.Bytes_To_Read, input_disk: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if spec_bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_SPEC)
	}
	spec_count := intrinsics.volatile_load(&spec_bytes.count)
	if spec_count != contract.SPEC_WIRE_SIZE {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, ARGUMENT_SPEC, i64(spec_count), contract.SPEC_WIRE_SIZE)
	}
	intrinsics.mem_copy_non_overlapping(&spec_wire_copy[0], spec_bytes.bytes, contract.SPEC_WIRE_SIZE)
	spec, spec_refusal := contract.decode_build_spec(spec_wire_copy[:])
	if spec_refusal != .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, ARGUMENT_SPEC, 0, 0, i64(spec_refusal))
	}
	if spec.memory_pages > GUEST_MEMORY_PAGES_MOST {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Pages, ARGUMENT_SPEC, i64(spec.memory_pages), i64(GUEST_MEMORY_PAGES_MOST), i64(contract.Guest_Builder_Refusal.Memory_Past_Bound))
	}
	memory, disk, copied := input_disk_copy(input_disk, error)
	if copied != .Succeeded {
		return copied, 0
	}
	defer guest_regions.owned_memory_end(&memory)
	if len(disk) > 0 {
		if _, disk_refusal := contract.validate_disk_image(disk, .Inputs_Read_Only, 0); disk_refusal != .None {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, ARGUMENT_INPUT_DISK, 0, 0, i64(disk_refusal))
		}
	}
	return .Succeeded, i64(spec.output_size_bound)
}
