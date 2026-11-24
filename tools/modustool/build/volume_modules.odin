package build

import "core:slice"
import "modustool:foundation"

// Minimal per-volume module filtering for `--fast` builds
// (src/md/infrastructure/fast_build.md, "Minimal per-volume module filtering in
// --fast").
//
// Default builds (`build`, `build whole`, `test` without `--fast`, `check`,
// `repeat`, `release`, `ship`, and `nix flake check`) leave the filter nil and
// build all modules and all boot images. When `--fast` targets specific boot
// volume(s), only the modules belonging to those volume(s)' boot images, their
// kernels, and their transitive `imports` and `children` are built.

// The module filter of the last build_modules call in this process. nil means
// all modules in foundation.module_builds were built.
build_last_module_filter: []bool

// build_last_module_filter_set records the filter of the current build in heap
// memory so downstream readers (such as fact_catalog_of_build during a machine
// test) know which modules were built.
build_last_module_filter_set :: proc(filter: []bool) {
	delete(build_last_module_filter)
	if filter == nil {
		build_last_module_filter = nil
		return
	}
	build_last_module_filter = slice.clone(filter)
}

// module_filter_allows says whether module at index is included by filter
// (a nil filter includes every module).
module_filter_allows :: proc(filter: []bool, index: int) -> bool {
	return filter == nil || (index >= 0 && index < len(filter) && filter[index])
}

// module_filter_count returns the number of modules enabled by filter, or the
// full module table length when filter is nil.
module_filter_count :: proc(filter: []bool) -> int {
	if filter == nil {
		return len(foundation.module_builds)
	}
	count := 0
	for included in filter {
		if included {
			count += 1
		}
	}
	return count
}

// module_in_named_boot_image says whether row belongs directly to the given
// boot image path (before transitive import/child closure).
module_in_named_boot_image :: proc(row: foundation.Module_Build, image_path: string) -> bool {
	switch image_path {
	case BOOT_IMAGE, BOOT_IMAGE_MEASURE:
		return foundation.module_in_boot_image(row)
	case BOOT_IMAGE_FAILS:
		return foundation.module_in_boot_image(row) && row.name != foundation.START_POLICY_MODULE
	case BOOT_IMAGE_SHORTAGE:
		return (foundation.module_in_boot_image(row) && row.name != "input") || (foundation.module_in_a_boot_image(row) && row.only_in_image == BOOT_IMAGE_SHORTAGE)
	case BOOT_IMAGE_MISSING_CONSOLE, BOOT_IMAGE_PLAN_AND_AUDIT, foundation.BOOT_IMAGE_OPERATION_SEQUENCES:
		return foundation.module_in_boot_image(row) || (foundation.module_in_a_boot_image(row) && row.only_in_image == image_path)
	case BOOT_IMAGE_RELEASE:
		return module_included_in_release_image(row)
	case BOOT_IMAGE_CONSOLE:
		console_modules := QEMU_CONSOLE_MODULES
		for name in console_modules {
			if row.name == name {
				return true
			}
		}
		return false
	}
	return foundation.module_in_boot_image(row)
}

// modules_needed_for_volumes computes the closed set of module_builds indexes
// needed to build volume_paths (each volume's boot image modules, its kernel,
// extra_modules, and transitive imports and children). ok is false when a path
// names no known boot volume or an unknown extra module.
modules_needed_for_volumes :: proc(volume_paths: []string, extra_modules: []string = nil, allocator := context.temp_allocator) -> (needed: []bool, ok: bool) {
	if len(volume_paths) == 0 {
		return nil, false
	}
	all_volumes := boot_volumes()
	needed = make([]bool, len(foundation.module_builds), allocator)

	mark_name :: proc(needed: []bool, name: string) -> bool {
		for row, index in foundation.module_builds {
			if row.name == name {
				needed[index] = true
				return true
			}
		}
		return false
	}

	for path in volume_paths {
		matched := false
		for volume in all_volumes {
			if volume.path != path {
				continue
			}
			matched = true
			if !mark_name(needed, volume.kernel) {
				return nil, false
			}
			for row, index in foundation.module_builds {
				if module_in_named_boot_image(row, volume.image) {
					needed[index] = true
				}
			}
			break
		}
		if !matched {
			return nil, false
		}
	}

	for name in extra_modules {
		if !mark_name(needed, name) {
			return nil, false
		}
	}

	// Transitive closure over imports and children: module_convert reads every
	// import's module file and every child's floor.
	for changed := true; changed; {
		changed = false
		for row, index in foundation.module_builds {
			if !needed[index] {
				continue
			}
			for dep in row.imports {
				for candidate, dep_index in foundation.module_builds {
					if candidate.name == dep && !needed[dep_index] {
						needed[dep_index] = true
						changed = true
					}
				}
			}
			for child in row.children {
				for candidate, child_index in foundation.module_builds {
					if candidate.name == child && !needed[child_index] {
						needed[child_index] = true
						changed = true
					}
				}
			}
		}
	}
	return needed, true
}

// boot_image_needed_for_volumes says whether at least one volume in
// volume_paths uses image_path (or true when volume_paths is nil).
boot_image_needed_for_volumes :: proc(volume_paths: []string, image_path: string) -> bool {
	if volume_paths == nil {
		return true
	}
	all_volumes := boot_volumes()
	for path in volume_paths {
		for volume in all_volumes {
			if volume.path == path && volume.image == image_path {
				return true
			}
		}
	}
	return false
}
