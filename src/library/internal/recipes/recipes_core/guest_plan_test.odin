#+build !freestanding
package recipes_core

import "core:testing"
import gb "modus:contract/guest_builder"
import pr "modus:contract/plans_recipes"

@(private = "file")
plan_spec :: proc() -> (spec: gb.Guest_Build_Spec) {
	spec.memory_pages = 32_768
	spec.output_size_bound = 32 * 1024 * 1024
	return spec
}

// At the edge: the fixed needs and the reserve exactly give a plan with the
// least input buffers, one page less gives Memory_Past_Bound; no budget, a
// reserve past the budget, a spec past the contract and no spec are
// refused; the stated budget of a typical build plans a typical build, and
// a larger budget gives larger input buffers up to the most of a disk.
@(test)
guest_build_plan_edges :: proc(t: ^testing.T) {
	spec := plan_spec()
	KERNEL :: u64(16 * 1024 * 1024)
	ARCHIVE :: u64(4 * 1024 * 1024)
	RESERVE :: u64(4096)
	fixed := spec.memory_pages + guest_table_pages(spec.memory_pages) + GUEST_PROCESS_RESERVE_PAGES + (KERNEL + ARCHIVE + spec.output_size_bound + 2 * INPUT_BUFFER_LEAST_BYTES) / PLAN_PAGE_BYTES
	plan, refusal := guest_build_plan(RESERVE + fixed, RESERVE, &spec, KERNEL, ARCHIVE)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, plan.input_disk_bytes, INPUT_BUFFER_LEAST_BYTES)
	testing.expect_value(t, guest_build_plan_pages(plan), fixed)
	for free in ([?]u64{0, RESERVE, RESERVE + fixed - 1}) {
		_, past := guest_build_plan(free, RESERVE, &spec, KERNEL, ARCHIVE)
		testing.expectf(t, past == .Memory_Past_Bound, "%d pages left give no build", free)
	}
	_, nil_spec := guest_build_plan(max(u64), 0, nil, 0, 0)
	testing.expect_value(t, nil_spec, pr.Recipe_Refusal.Memory_Past_Bound)
	big := spec
	big.memory_pages = gb.MAX_GUEST_MEMORY_PAGES + 1
	_, past_contract := guest_build_plan(max(u64), 0, &big, 0, 0)
	testing.expect_value(t, past_contract, pr.Recipe_Refusal.Memory_Past_Bound)
	_, past_archive := guest_build_plan(max(u64), 0, &spec, 0, gb.MAX_INITIAL_ARCHIVE_BYTES + 1)
	testing.expect_value(t, past_archive, pr.Recipe_Refusal.Memory_Past_Bound)

	// A typical build fits its typical pages, and the input buffers grow
	// with the budget, up to the most of an input disk.
	typical, typical_refusal := guest_build_plan(RESERVE + TYPICAL_GUEST_BUILD_PAGES, RESERVE, &spec, KERNEL, ARCHIVE)
	testing.expect_value(t, typical_refusal, pr.Recipe_Refusal.None)
	testing.expect(t, guest_build_plan_pages(typical) <= TYPICAL_GUEST_BUILD_PAGES)
	testing.expect(t, typical.input_disk_bytes >= 8 * 1024 * 1024)
	huge, _ := guest_build_plan(max(u64) / 2, RESERVE, &spec, KERNEL, ARCHIVE)
	testing.expect_value(t, huge.input_disk_bytes, gb.MAX_INPUT_DISK_BYTES)
}
