#+build !freestanding
package checks

import "core:testing"

@(test)
image_checks_check_finds_the_field_and_no_variable :: proc(t: ^testing.T) {
	// A read of the field, and the field in a literal: two uses.
	source := `package sample

give :: proc(table: ^int) -> Source {
	return {image = nil, image_checks = table}
}

read :: proc(source: Source) -> bool {
	return source.image_checks != nil
}
`
	uses, parsed := image_checks_uses_of_source("sample.odin", source)
	testing.expect(t, parsed)
	testing.expect_value(t, len(uses), 2)
	if len(uses) == 2 {
		testing.expect_value(t, uses[0].line, 4)
		testing.expect_value(t, uses[1].line, 8)
	}
	// A variable of the same name, a comment and a text name no field.
	plain := `package sample

image_checks: int

// image_checks in a comment
use :: proc() -> (int, string) {
	return image_checks, "image_checks"
}
`
	uses, parsed = image_checks_uses_of_source("plain.odin", plain)
	testing.expect(t, parsed)
	testing.expect_value(t, len(uses), 0)
	// A source that does not parse is refused, not passed.
	_, parsed = image_checks_uses_of_source("broken.odin", "package sample\nuse :: proc( {")
	testing.expect(t, !parsed)
}

@(test)
image_checks_check_allows_the_loader_the_root_service_and_their_tests :: proc(t: ^testing.T) {
	testing.expect(t, !image_checks_path_allowed("src/modules/system/root/trust.odin"))
	testing.expect(t, !image_checks_path_allowed("src/modules/system/console/main.odin"))
	testing.expect(t, !image_checks_path_allowed("src/library/modus/system/run.odin"))
	testing.expect(t, !image_checks_path_allowed("src/library/modus/system/sub/load_test.odin"))
	testing.expect(t, !image_checks_path_allowed("src/library/modus/interface/load_test.odin"))
	testing.expect(t, image_checks_path_allowed("src/library/modus/system/load_checks_test.odin"))
	testing.expect(t, image_checks_path_allowed("src/modules/system/root/main.odin"))
	testing.expect(t, image_checks_path_allowed("src/library/modus/system/load.odin"))
}
