#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

// The image of these tests: one other holder of Plans, and one other
// holder of Display.
@(private = "file")
other_plans_hash :: blake3.Hash{0 = 7, 31 = 7}
@(private = "file")
other_display_hash :: blake3.Hash{0 = 9, 31 = 9}

@(private = "file")
name_of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool) {
	switch hash {
	case other_plans_hash:
		return "other_plans", true
	case other_display_hash:
		return "other_display", true
	}
	return "", false
}

@(private = "file")
fills :: proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool {
	return true
}

@(private = "file")
names_of_the_image :: proc() -> Holder_Names {
	names: Holder_Names
	names.defaults[.Display] = "compositor"
	names.defaults[.Plans] = "plans"
	names.defaults[.Console] = "console"
	return names
}

@(private = "file")
roles_move :: proc(t: ^testing.T, names: ^Holder_Names, kept: ^Override_Names, overrides: ..rd.Plan_Role_Override) {
	set: rd.Plan_Roles_Set
	set.generation = kept.generation + 1
	set.expected_serial = kept.serial
	set.override_count = u64(len(overrides))
	copy(set.overrides[:], overrides)
	refusal, _ := holder_overrides_replace(names, kept, &set, .Apply, {name_of_hash = name_of_hash, fills = fills})
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
}

@(test)
display_caller_amount_refuses_each_caller_that_is_not_the_holder_of_plans :: proc(t: ^testing.T) {
	names := names_of_the_image()
	// A caller that holds no role, or another role.
	testing.expect_value(t, display_caller_amount(&names, "compositor", "console", false), 0)
	testing.expect_value(t, display_caller_amount(&names, "compositor", "visitor", false), 0)
	testing.expect_value(t, display_caller_amount(&names, "compositor", "", false), 0)
	// The holder of Plans, to a service that does not hold Display.
	testing.expect_value(t, display_caller_amount(&names, "storage", "plans", false), 0)
	testing.expect_value(t, display_caller_amount(&names, "", "plans", false), 0)
	// The name of the role is no module name.
	testing.expect_value(t, display_caller_amount(&names, "display", "plans", false), 0)
}

@(test)
display_caller_amount_follows_the_role_and_not_the_module_name :: proc(t: ^testing.T) {
	names := names_of_the_image()
	kept: Override_Names
	// The role Plans moves: the module plans holds it no more.
	roles_move(t, &names, &kept, {role_word = u64(role_contract.Role.Plans), module_hash = other_plans_hash})
	testing.expect_value(t, display_caller_amount(&names, "compositor", "plans", false), 0)
	// The role Display moves too: the old display serves nobody as the
	// holder of Plans.
	roles_move(t, &names, &kept, {role_word = u64(role_contract.Role.Plans), module_hash = other_plans_hash}, {role_word = u64(role_contract.Role.Display), module_hash = other_display_hash})
	testing.expect_value(t, display_caller_amount(&names, "compositor", "other_plans", false), 0)
	testing.expect_value(t, display_caller_amount(&names, "other_display", "plans", false), 0)
	// The holders in force, last.
	testing.expect_value(t, display_caller_amount(&names, "other_display", "other_plans", false), pr.DISPLAY_AMOUNT_PLANS_HOLDER)
}

@(test)
display_caller_amount_gives_the_holder_of_the_image :: proc(t: ^testing.T) {
	names := names_of_the_image()
	testing.expect_value(t, display_caller_amount(&names, "compositor", "plans", false), pr.DISPLAY_AMOUNT_PLANS_HOLDER)
}

// The term asks_acts gives the amount of an asker of acts on a connection
// to the holder of Display only, and never to the holder of Plans, whose
// amount stays its own.
@(test)
display_caller_amount_gives_an_asker_of_acts_its_amount_to_the_display_only :: proc(t: ^testing.T) {
	names := names_of_the_image()
	testing.expect_value(t, display_caller_amount(&names, "storage", "assistant", true), 0)
	testing.expect_value(t, display_caller_amount(&names, "", "assistant", true), 0)
	testing.expect_value(t, display_caller_amount(&names, "display", "assistant", true), 0)
	testing.expect_value(t, display_caller_amount(&names, "compositor", "assistant", false), 0)
	testing.expect_value(t, display_caller_amount(&names, "compositor", "plans", true), pr.DISPLAY_AMOUNT_PLANS_HOLDER)
	testing.expect_value(t, display_caller_amount(&names, "compositor", "assistant", true), pr.DISPLAY_AMOUNT_ACT_ASKER)
}
