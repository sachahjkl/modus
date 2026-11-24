package build

import "core:fmt"
import "core:os"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import "modus:contract/root_plan_values"
import "modustool:foundation"
import "modustool:resources"

// The boot-image resource file carrying the plan values of test modules
// (limits and log_flood). Test boot images ship it as a signed resource;
// release_boot_image_of excludes it so release images carry no test plan rows
// (src/md/features/module_budget_request.md).
TEST_PLAN_VALUES_RESOURCE_FILE :: foundation.BUILD_FOLDER + "/test_plan_values.resource"

// Test module budget policy constants written into the test boot image's plan
// file so root needs no hardcoded exception tables.
TEST_LIMITS_PROCESSOR :: u64(1_500_000) // Reaches the processor-time limit quickly in the limits test.
TEST_LIMITS_LOG_RECORDS :: u64(40)      // Burst of 100 reaches the per-second log limit.
TEST_LOG_FLOOD_LOG_RECORDS :: u64(0)    // Kernel log refuses every line so the wired record output carries them.

// test_plan_values_encode builds and validates the signed plan-values set
// shipped in test boot images for test-only budget policy rows.
test_plan_values_encode :: proc(allocator := context.temp_allocator) -> (bytes: []u8, ok: bool) {
	empty_buf: [chosen_values.HEADER_SIZE]u8
	empty_len, empty_problem := chosen_values.write_record({}, nil, empty_buf[:])
	if empty_problem != .None {
		return nil, false
	}

	limits_changes := [2]chosen_values.Change {
		{name = root_plan_values.BUDGET_PROCESSOR_FIELD, kind = .Choose, value = TEST_LIMITS_PROCESSOR},
		{name = root_plan_values.BUDGET_LOG_RECORDS_FIELD, kind = .Choose, value = TEST_LIMITS_LOG_RECORDS},
	}
	limits_buf: [chosen_values.HEADER_SIZE + 2 * chosen_values.ENTRY_SIZE]u8
	limits_len, limits_problem := chosen_values.write_record({}, limits_changes[:], limits_buf[:])
	if limits_problem != .None {
		return nil, false
	}

	log_flood_changes := [1]chosen_values.Change {
		{name = root_plan_values.BUDGET_LOG_RECORDS_FIELD, kind = .Choose, value = TEST_LOG_FLOOD_LOG_RECORDS},
	}
	log_flood_buf: [chosen_values.HEADER_SIZE + chosen_values.ENTRY_SIZE]u8
	log_flood_len, log_flood_problem := chosen_values.write_record({}, log_flood_changes[:], log_flood_buf[:])
	if log_flood_problem != .None {
		return nil, false
	}

	blocks := [2]plan_values.Owner_Block {
		{owner = "limits", defaults = limits_buf[:limits_len], locks = empty_buf[:empty_len]},
		{owner = "log_flood", defaults = log_flood_buf[:log_flood_len], locks = empty_buf[:empty_len]},
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

// test_plan_values_write encodes and writes the test-image plan values
// resource file for build_modules.
test_plan_values_write :: proc() -> (resource: resources.Resource_File, ok: bool) {
	encoded, encoded_ok := test_plan_values_encode()
	if !encoded_ok {
		fmt.eprintln("modustool: cannot encode the test image plan values")
		return {}, false
	}
	if err := os.write_entire_file(TEST_PLAN_VALUES_RESOURCE_FILE, encoded); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_PLAN_VALUES_RESOURCE_FILE, err)
		return {}, false
	}
	return resources.Resource_File{name = plan_values.TEST_IMAGE_PLAN_RESOURCE, path = TEST_PLAN_VALUES_RESOURCE_FILE}, true
}
