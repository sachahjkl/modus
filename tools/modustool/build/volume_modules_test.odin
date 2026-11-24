package build

import "core:testing"
import "modustool:foundation"

// Helper to test whether module `name` is enabled in a filter slice.
@(private = "file")
filter_has_module :: proc(filter: []bool, name: string) -> bool {
	for row, index in foundation.module_builds {
		if row.name == name {
			return index < len(filter) && filter[index]
		}
	}
	return false
}

// Minimal per-volume filtering builds only the modules, kernels, and transitive
// dependencies needed by the requested boot volume(s), and refuses unknown
// volume or extra module names.
@(test)
modules_needed_for_volumes_filters_accurately_and_refuses_unknowns :: proc(t: ^testing.T) {
	// Refusals first.
	_, ok := modules_needed_for_volumes(nil)
	testing.expect(t, !ok, "empty volume list is refused")
	_, ok = modules_needed_for_volumes([]string{""})
	testing.expect(t, !ok, "blank volume path is refused")
	_, ok = modules_needed_for_volumes([]string{"build/no_such_volume.img"})
	testing.expect(t, !ok, "unknown volume path is refused")
	_, ok = modules_needed_for_volumes([]string{BOOT_VOLUME_CONSOLE}, []string{"no_such_module"})
	testing.expect(t, !ok, "unknown extra module is refused")

	total := len(foundation.module_builds)

	// Console volume: only QEMU_CONSOLE_MODULES + transitive imports + kernel.
	console_filter, console_ok := modules_needed_for_volumes([]string{BOOT_VOLUME_CONSOLE})
	testing.expect(t, console_ok)
	console_count := module_filter_count(console_filter)
	testing.expectf(t, console_count > 10 && console_count < 25, "console volume needs ~15 modules, got %d of %d", console_count, total)
	testing.expect(t, filter_has_module(console_filter, "kernel"), "console volume needs kernel")
	testing.expect(t, filter_has_module(console_filter, "root"), "console volume needs root")
	testing.expect(t, filter_has_module(console_filter, "serial_terminal"), "console volume needs serial_terminal")
	testing.expect(t, filter_has_module(console_filter, "console"), "console volume needs console")
	testing.expect(t, filter_has_module(console_filter, foundation.TEXT_RENDERING_MODULE), "console volume pulls transitive import text_rendering")
	for excluded in ([]string{"compositor", "drawing", "input", "flood", "shortage", "plan_applier", "visitor", "kernel_without_return_check", foundation.KERNEL_EDGE_COUNTERS_MODULE}) {
		testing.expectf(t, !filter_has_module(console_filter, excluded), "console volume excludes %s", excluded)
	}

	// Secure Boot release volume: shipped modules + transitive deps + kernel,
	// excluding test-only modules, disk modules, and test kernels.
	release_filter, release_ok := modules_needed_for_volumes([]string{BOOT_VOLUME_SECURE_BOOT})
	testing.expect(t, release_ok)
	release_count := module_filter_count(release_filter)
	testing.expectf(t, release_count > console_count && release_count < total, "secure_boot volume (%d) is strictly smaller than full table (%d)", release_count, total)
	testing.expect(t, filter_has_module(release_filter, "kernel"), "secure_boot needs kernel")
	testing.expect(t, filter_has_module(release_filter, "root"), "secure_boot needs root")
	testing.expect(t, filter_has_module(release_filter, "compositor"), "secure_boot needs compositor")
	testing.expect(t, filter_has_module(release_filter, "test_callee"), "secure_boot pulls transitive import test_callee of lonely")
	for excluded in ([]string{"flood", "probe", "shortage", "plan_applier", "stops_refused", "visitor", "test_caller", "display_conformance", "kernel_without_return_check", foundation.KERNEL_EDGE_COUNTERS_MODULE}) {
		testing.expectf(t, !filter_has_module(release_filter, excluded), "secure_boot volume excludes %s", excluded)
	}

	// Main volume: drops only_in_image, disk modules, and test kernels.
	main_filter, main_ok := modules_needed_for_volumes([]string{BOOT_VOLUME})
	testing.expect(t, main_ok)
	main_count := module_filter_count(main_filter)
	testing.expectf(t, main_count > release_count && main_count < total, "main volume (%d) sits between release (%d) and full table (%d)", main_count, release_count, total)
	testing.expect(t, filter_has_module(main_filter, "kernel"), "main volume needs kernel")
	testing.expect(t, filter_has_module(main_filter, "flood"), "main volume includes boot-image test module flood")
	for excluded in ([]string{"shortage", "plan_applier", "stops_refused", foundation.OPERATION_FUZZING_MODULE, foundation.DISK_MODULE_NAME, "test_caller", "display_conformance", "kernel_without_return_check", foundation.KERNEL_EDGE_COUNTERS_MODULE}) {
		testing.expectf(t, !filter_has_module(main_filter, excluded), "main volume excludes %s", excluded)
	}

	// Extra modules (e.g. disk_processes) add disk modules and their transitive
	// imports cleanly.
	disk_filter, disk_ok := modules_needed_for_volumes([]string{BOOT_VOLUME}, []string{foundation.DISK_MODULE_NAME, foundation.STORE_IMPORTER_MODULE})
	testing.expect(t, disk_ok)
	testing.expect(t, filter_has_module(disk_filter, foundation.DISK_MODULE_NAME), "extra disk module visitor included")
	testing.expect(t, filter_has_module(disk_filter, foundation.STORE_IMPORTER_MODULE), "extra disk module store_importer included")
	testing.expect(t, filter_has_module(disk_filter, foundation.STORE_LIBRARY_MODULE), "transitive import store_library pulled in")

	// Operation fuzzing volume selects the counted kernel and operation_fuzzing
	// modules, and omits the default kernel.
	fuzz_filter, fuzz_ok := modules_needed_for_volumes([]string{BOOT_VOLUME_OPERATION_FUZZING})
	testing.expect(t, fuzz_ok)
	testing.expect(t, filter_has_module(fuzz_filter, foundation.KERNEL_EDGE_COUNTERS_MODULE), "operation_fuzzing needs counted kernel")
	testing.expect(t, filter_has_module(fuzz_filter, foundation.OPERATION_FUZZING_MODULE), "operation_fuzzing needs operation_fuzzing")
	testing.expect(t, filter_has_module(fuzz_filter, foundation.OPERATION_SEQUENCE_RUNNER_MODULE), "operation_fuzzing needs operation_sequence_runner")
	testing.expect(t, !filter_has_module(fuzz_filter, "kernel"), "operation_fuzzing does not need default kernel")
	testing.expect(t, !filter_has_module(fuzz_filter, "kernel_without_return_check"), "operation_fuzzing does not need kernel_without_return_check")

	// Boot image filtering: each single volume needs only its own boot image.
	testing.expect(t, boot_image_needed_for_volumes(nil, BOOT_IMAGE_CONSOLE), "nil volume scope builds every image")
	testing.expect(t, boot_image_needed_for_volumes([]string{BOOT_VOLUME_CONSOLE}, BOOT_IMAGE_CONSOLE), "console volume needs console image")
	testing.expect(t, !boot_image_needed_for_volumes([]string{BOOT_VOLUME_CONSOLE}, BOOT_IMAGE), "console volume skips main boot image")
	testing.expect(t, !boot_image_needed_for_volumes([]string{BOOT_VOLUME_CONSOLE}, BOOT_IMAGE_RELEASE), "console volume skips release boot image")
	testing.expect(t, boot_image_needed_for_volumes([]string{BOOT_VOLUME_SECURE_BOOT}, BOOT_IMAGE_RELEASE), "secure_boot volume needs release image")
	testing.expect(t, !boot_image_needed_for_volumes([]string{BOOT_VOLUME_SECURE_BOOT}, BOOT_IMAGE), "secure_boot volume skips main boot image")
}

// Every module in a filtered set has every one of its imports and children
// also present in the filtered set.
@(test)
modules_needed_for_volumes_is_closed_under_imports_and_children :: proc(t: ^testing.T) {
	for volume in boot_volumes() {
		filter, ok := modules_needed_for_volumes([]string{volume.path})
		testing.expectf(t, ok, "volume %s resolves its module set", volume.path)
		testing.expectf(t, filter_has_module(filter, volume.kernel), "volume %s includes its kernel %s", volume.path, volume.kernel)
		for row, index in foundation.module_builds {
			if !filter[index] {
				continue
			}
			for imp in row.imports {
				testing.expectf(t, filter_has_module(filter, imp), "volume %s: module %s imports %s which must be in filter", volume.path, row.name, imp)
			}
			for child in row.children {
				testing.expectf(t, filter_has_module(filter, child), "volume %s: module %s starts child %s which must be in filter", volume.path, row.name, child)
			}
		}
	}
}
