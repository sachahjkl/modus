// The memory of one guest build (src/md/features/recipes.md, "The memory
// of a guest build"): the guest, its nested page table and its process,
// and the buffers of its kernel, its initial archive, its output disk and
// its inputs. Each build plans them from its spec, the sizes of its kernel
// and its archive, and the pages that the budget of the service has left:
// a larger grant gives larger input disks, and a build whose fixed needs
// do not fit is refused with Memory_Past_Bound before anything is made.
package recipes_core

import gb "modus:contract/guest_builder"
import pr "modus:contract/plans_recipes"

PLAN_PAGE_BYTES :: gb.GUEST_PAGE_BYTES

// The pages of the guest process beside its memory: its records, its
// handle table and the first pages of its tables, which its budget, the
// budget of the service, pays at its creation.
GUEST_PROCESS_RESERVE_PAGES :: u64(64)
// The least bytes of each of the two input buffers (the packed disk and
// the inputs read before they are packed): a build with no room for them
// has no room for its inputs.
INPUT_BUFFER_LEAST_BYTES :: u64(1024 * 1024)

// guest_table_pages gives the pages of the nested page table of a guest of
// memory_pages: one page of entries for each 2 MiB of the guest, and 64
// pages for the levels above them and the pages that a guest maps past its
// memory.
guest_table_pages :: proc "contextless" (memory_pages: u64) -> u64 {
	return memory_pages / 512 + 64
}

// The pages of one typical guest build, which the stated budget of the
// service asks for: 128 MiB of guest memory, a kernel of 16 MiB, an
// archive of 4 MiB, an output disk of 32 MiB and two input buffers of
// 8 MiB.
TYPICAL_GUEST_BUILD_PAGES :: 32_768 + (32_768 / 512 + 64) + GUEST_PROCESS_RESERVE_PAGES + (16 + 4 + 32 + 8 + 8) * 1024 * 1024 / PLAN_PAGE_BYTES

// The bytes of each buffer of one guest build.
Guest_Build_Plan :: struct {
	guest_pages:       u64, // The memory of the guest, as its spec states it.
	table_pages:       u64,
	kernel_bytes:      u64,
	archive_bytes:     u64,
	output_bytes:      u64,
	input_disk_bytes:  u64,
	input_staging_bytes: u64,
}

@(private = "file")
pages_of :: proc "contextless" (bytes: u64) -> u64 {
	return bytes / PLAN_PAGE_BYTES + u64(bytes % PLAN_PAGE_BYTES != 0)
}

// guest_build_plan plans one build. free_pages is what the budget of the
// service has left, reserve_pages what the service keeps for itself. The
// fixed needs come first: the guest, its table and its process, the
// kernel, the archive and the output disk of the spec, and the least of
// the two input buffers. The rest goes to the input buffers, half each, up
// to the most of an input disk. Each size is a whole number of pages.
guest_build_plan :: proc "contextless" (free_pages: u64, reserve_pages: u64, spec: ^gb.Guest_Build_Spec, kernel_bytes: u64, archive_bytes: u64) -> (plan: Guest_Build_Plan, refusal: pr.Recipe_Refusal) {
	if spec == nil || spec.memory_pages > gb.MAX_GUEST_MEMORY_PAGES || kernel_bytes > gb.MAX_GUEST_MEMORY_PAGES * PLAN_PAGE_BYTES || archive_bytes > gb.MAX_INITIAL_ARCHIVE_BYTES || spec.output_size_bound > gb.MAX_OUTPUT_DISK_BYTES {
		return {}, .Memory_Past_Bound
	}
	plan = {
		guest_pages   = spec.memory_pages,
		table_pages   = guest_table_pages(spec.memory_pages),
		kernel_bytes  = pages_of(kernel_bytes) * PLAN_PAGE_BYTES,
		archive_bytes = pages_of(archive_bytes) * PLAN_PAGE_BYTES,
		output_bytes  = pages_of(spec.output_size_bound) * PLAN_PAGE_BYTES,
	}
	// Each term is bounded by the contract, so the sum fits 64 bits.
	fixed := plan.guest_pages + plan.table_pages + GUEST_PROCESS_RESERVE_PAGES + pages_of(plan.kernel_bytes) + pages_of(plan.archive_bytes) + pages_of(plan.output_bytes) + 2 * pages_of(INPUT_BUFFER_LEAST_BYTES)
	if free_pages <= reserve_pages || fixed > free_pages - reserve_pages {
		return {}, .Memory_Past_Bound
	}
	rest := free_pages - reserve_pages - fixed
	each := min(pages_of(INPUT_BUFFER_LEAST_BYTES) + rest / 2, gb.MAX_INPUT_DISK_BYTES / PLAN_PAGE_BYTES)
	plan.input_disk_bytes = each * PLAN_PAGE_BYTES
	plan.input_staging_bytes = each * PLAN_PAGE_BYTES
	return plan, .None
}

// guest_build_plan_pages gives the pages of a plan, all buffers and the
// guest with its table and its process.
guest_build_plan_pages :: proc "contextless" (plan: Guest_Build_Plan) -> u64 {
	return plan.guest_pages + plan.table_pages + GUEST_PROCESS_RESERVE_PAGES + (plan.kernel_bytes + plan.archive_bytes + plan.output_bytes + plan.input_disk_bytes + plan.input_staging_bytes) / PLAN_PAGE_BYTES
}
