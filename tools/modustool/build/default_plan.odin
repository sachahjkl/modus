package build

import "core:fmt"
import "core:os"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import "modus:contract/root_plan_values"
import "modustool:foundation"
import "modustool:resources"

// The signed boot-image resource file carrying default plan values for shipped
// modules whose post-ready allocations exceed twice their counted start floor.
// Shipped in both test and release boot images so no module floor holds a
// hand-written page count (src/md/features/module_budget_request.md).
DEFAULT_PLAN_VALUES_RESOURCE_FILE :: foundation.BUILD_FOLDER + "/default_plan_values.resource"

// Plan values: default post-ready budgets for shipped modules whose runtime
// allocations exceed twice their counted floor.
DEFAULT_CLOCK_PAGES :: u64(10_240)         // 40 MiB: floor plus two 1920x1080 resize surfaces, glyph cache, worker stack, and tables.
DEFAULT_PAINT_PAGES :: u64(16_384)         // 64 MiB: floor plus two 1920x1080 resize surfaces, 1280x720 picture/copy/history arenas, fill stack, and glyph cache.
DEFAULT_BROWSER_PAGES :: u64(24_576)       // 96 MiB: floor plus two resize surfaces, glyph cache, and 1 MiB HTML / 20,000-node document arenas.
DEFAULT_DOOM_PAGES :: u64(16_384)          // 64 MiB: floor, 29 MiB Freedoom WAD, 8 MiB Doom zone, C scratch, resize surfaces, and sound region.
DEFAULT_DEBUGGER_PAGES :: u64(5_632)       // 22 MiB: floor plus 8 MiB disk debug object, input history, kernel point copies/baselines, and replay stand-in mappings.
DEFAULT_RECIPES_SHARE_PARTS :: u64(256)    // 256/1024 (1/4 of machine pages): 128 MiB guest builds and native C builds on 1 GiB, scaling up on larger machines.
DEFAULT_LINUX_SHARE_PARTS :: u64(256)      // 256/1024 (1/4 of machine pages): >= 128 MiB guest RAM, nested page tables and reserve on 1 GiB, scaling up on larger machines.
DEFAULT_GUEST_BUILDER_PAGES :: u64(92_160) // 360 MiB: floor plus 256 MiB guest RAM, 16 MiB input disk, 64 MiB output disk, nested page tables and scratch.

// default_plan_values_encode builds and validates the signed plan-values set
// shipped in every boot image (test and release) for shipped module budget rows.
default_plan_values_encode :: proc(allocator := context.temp_allocator) -> (bytes: []u8, ok: bool) {
	empty_buf: [chosen_values.HEADER_SIZE]u8
	empty_len, empty_problem := chosen_values.write_record({}, nil, empty_buf[:])
	if empty_problem != .None {
		return nil, false
	}
	empty_rec := empty_buf[:empty_len]

	Row_Spec :: struct {
		owner: string,
		field: string,
		value: u64,
	}
	specs := [8]Row_Spec {
		{"browser", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_BROWSER_PAGES},
		{"clock", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_CLOCK_PAGES},
		{"debugger", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_DEBUGGER_PAGES},
		{"doom", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_DOOM_PAGES},
		{"guest_builder", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_GUEST_BUILDER_PAGES},
		{"linux", root_plan_values.BUDGET_SHARE_PARTS_FIELD, DEFAULT_LINUX_SHARE_PARTS},
		{"paint", root_plan_values.BUDGET_PAGES_FIELD, DEFAULT_PAINT_PAGES},
		{"recipes", root_plan_values.BUDGET_SHARE_PARTS_FIELD, DEFAULT_RECIPES_SHARE_PARTS},
	}

	row_bufs: [len(specs)][chosen_values.HEADER_SIZE + chosen_values.ENTRY_SIZE]u8
	blocks: [len(specs)]plan_values.Owner_Block
	for spec, index in specs {
		changes := [1]chosen_values.Change {
			{name = spec.field, kind = .Choose, value = spec.value},
		}
		written, problem := chosen_values.write_record({}, changes[:], row_bufs[index][:])
		if problem != .None {
			return nil, false
		}
		blocks[index] = {
			owner    = spec.owner,
			defaults = row_bufs[index][:written],
			locks    = empty_rec,
		}
	}

	raw := make([]u8, plan_values.SET_SIZE, allocator)
	written := plan_values.set_write(raw, 0, 1, blocks[:])
	if written == 0 {
		return nil, false
	}
	result := raw[:written]
	if _, check_problem := plan_values.set_check(result); check_problem != .None {
		return nil, false
	}
	return result, true
}

// default_plan_values_write encodes and writes the shipped default plan values
// resource file for build_modules.
default_plan_values_write :: proc() -> (resource: resources.Resource_File, ok: bool) {
	encoded, encoded_ok := default_plan_values_encode()
	if !encoded_ok {
		fmt.eprintln("modustool: cannot encode the default image plan values")
		return {}, false
	}
	if err := os.write_entire_file(DEFAULT_PLAN_VALUES_RESOURCE_FILE, encoded); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", DEFAULT_PLAN_VALUES_RESOURCE_FILE, err)
		return {}, false
	}
	return resources.Resource_File{name = plan_values.DEFAULT_IMAGE_PLAN_RESOURCE, path = DEFAULT_PLAN_VALUES_RESOURCE_FILE}, true
}
