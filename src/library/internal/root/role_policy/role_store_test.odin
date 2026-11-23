#+build !freestanding
package role_policy

import "core:testing"

// A holder that the plan puts in place of the default one, and the default
// one after a restart, get the store of the role and the grants of its row;
// a module that holds no role keeps its own store and its own row. A module
// that held the role before the plan replaced it holds it no more.
@(test)
a_replaced_holder_gets_the_store_and_the_grants_of_its_role :: proc(t: ^testing.T) {
	names: Holder_Names
	names.defaults[.Display] = "compositor"
	names.defaults[.Settings] = "settings"
	testing.expect_value(t, store_name_of_module(&names, "compositor"), "display")
	testing.expect_value(t, grant_row_name_of_module(&names, "compositor"), "compositor")
	testing.expect_value(t, store_name_of_module(&names, "settings"), "settings")
	testing.expect_value(t, store_name_of_module(&names, "paint"), "paint")
	testing.expect_value(t, grant_row_name_of_module(&names, "paint"), "paint")
	testing.expect_value(t, store_name_of_module(&names, ""), "")
	names.overrides[.Display] = "tiling_compositor"
	names.overrides[.Settings] = "settings_stand_in"
	testing.expect_value(t, store_name_of_module(&names, "tiling_compositor"), "display")
	testing.expect_value(t, grant_row_name_of_module(&names, "tiling_compositor"), "compositor")
	testing.expect_value(t, store_name_of_module(&names, "settings_stand_in"), "settings")
	testing.expect_value(t, grant_row_name_of_module(&names, "settings_stand_in"), "settings")
	// The module that the plan replaced is no holder: its own store, its own row.
	testing.expect_value(t, store_name_of_module(&names, "compositor"), "compositor")
	testing.expect_value(t, grant_row_name_of_module(&names, "settings"), "settings")
	testing.expect_value(t, store_name_of_module(&names, "settings"), "settings")
	// A role with no default holder gives the row of the module itself.
	names.overrides[.Speech] = "speaker"
	testing.expect_value(t, grant_row_name_of_module(&names, "speaker"), "speaker")
	testing.expect_value(t, store_name_of_module(&names, "speaker"), "speech")
}
