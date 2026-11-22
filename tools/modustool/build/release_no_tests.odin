// Release module filter excluding test modules from shipping release images.
package build

import "core:strings"
import "modustool:foundation"

// module_included_in_release_image reports whether module m belongs in a
// shipping release boot image (all system/library/demo image modules, excluding
// every module sourced under TEST_MODULE_SOURCES).
module_included_in_release_image :: proc(m: foundation.Module) -> bool {
	if !m.image {
		return false
	}
	return !strings.has_prefix(m.source, foundation.TEST_MODULE_SOURCES)
}

// release_image_module_count returns how many modules of table ship in a
// test-free release image and how many test modules were stripped.
release_image_module_count :: proc(table: []foundation.Module) -> (shipped: int, stripped_tests: int) {
	for m in table {
		if !m.image {
			continue
		}
		if module_included_in_release_image(m) {
			shipped += 1
		} else {
			stripped_tests += 1
		}
	}
	return shipped, stripped_tests
}
