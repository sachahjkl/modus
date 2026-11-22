package build

import "core:testing"
import "modustool:foundation"

@(test)
release_image_strips_test_modules_only :: proc(t: ^testing.T) {
	shipped, stripped := release_image_module_count(foundation.MODULES[:])
	testing.expect(t, shipped > 30)
	testing.expect(t, stripped > 0)
	for m in foundation.MODULES {
		if strings_has_test := m.image && !module_included_in_release_image(m); strings_has_test {
			testing.expect(t, len(m.source) >= len(foundation.TEST_MODULE_SOURCES))
		}
	}
}
