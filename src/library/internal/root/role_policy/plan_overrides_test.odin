#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

// The boot image of these tests: two modules that fill each contract, and
// one that fills none.
@(private = "file")
Test_Image :: struct {
	hashes: [3]blake3.Hash,
	names:  [3]string,
}

@(private = "file")
test_hash :: proc(tag: u8) -> (hash: blake3.Hash) {
	hash[0] = tag
	hash[31] = tag ~ 0xA5
	return hash
}

@(private = "file")
test_image := Test_Image {
	hashes = {{0 = 1, 31 = 1 ~ 0xA5}, {0 = 2, 31 = 2 ~ 0xA5}, {0 = 3, 31 = 3 ~ 0xA5}},
	names  = {"other_compositor", "other_storage", "no_contract"},
}

@(private = "file")
test_name_of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool) {
	image := (^Test_Image)(user)
	for item, index in image.hashes {
		if item == hash {
			return image.names[index], true
		}
	}
	return "", false
}

@(private = "file")
test_fills :: proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool {
	return module_name != "no_contract"
}

@(private = "file")
test_resolver :: proc() -> Holder_Resolver {
	return {user = &test_image, name_of_hash = test_name_of_hash, fills = test_fills}
}

@(private = "file")
test_names :: proc() -> Holder_Names {
	names: Holder_Names
	names.defaults[.Display] = "compositor"
	names.defaults[.Storage] = "storage"
	names.defaults[.Plans] = "plans"
	return names
}

@(private = "file")
set_of :: proc(generation, serial: u64, overrides: ..rd.Plan_Role_Override) -> (set: rd.Plan_Roles_Set) {
	set.generation = generation
	set.expected_serial = serial
	set.override_count = u64(len(overrides))
	copy(set.overrides[:], overrides)
	return set
}

@(test)
plan_overrides_refuse_each_bad_set_and_change_nothing :: proc(t: ^testing.T) {
	names := test_names()
	kept: Override_Names
	resolver := test_resolver()
	good := rd.Plan_Role_Override{role_word = u64(role_contract.Role.Display), module_hash = test_hash(1)}

	Case :: struct {
		set:     rd.Plan_Roles_Set,
		step:    rd.Plan_Roles_Step,
		refusal: rd.Plan_Roles_Refusal,
		index:   int,
	}
	named_principal := set_of(1, 0, good)
	named_principal.principal = 1
	past_capacity := set_of(1, 0, good)
	past_capacity.override_count = rd.PLAN_ROLES_OVERRIDE_CAPACITY + 1
	largest_count := set_of(1, 0, good)
	largest_count.override_count = max(u64)
	bytes_after := set_of(1, 0, good)
	bytes_after.overrides[rd.PLAN_ROLES_OVERRIDE_CAPACITY - 1].role_word = 1
	cases := [?]Case {
		{named_principal, .Apply, .Not_Machine, 0},
		{set_of(1, 1, good), .Apply, .Stale_Serial, 0},
		{set_of(1, max(u64), good), .Apply, .Stale_Serial, 0},
		{set_of(0, 0, good), .Apply, .Zero_Generation, 0},
		{past_capacity, .Apply, .Too_Many_Overrides, 0},
		{largest_count, .Apply, .Too_Many_Overrides, 0},
		{set_of(1, 0, good, {role_word = 0, module_hash = test_hash(2)}), .Apply, .Unknown_Role, 1},
		{set_of(1, 0, good, {role_word = u64(max(role_contract.Role)) + 1, module_hash = test_hash(2)}), .Apply, .Unknown_Role, 1},
		{set_of(1, 0, {role_word = max(u64), module_hash = test_hash(2)}), .Apply, .Unknown_Role, 0},
		{set_of(1, 0, {role_word = u64(role_contract.Role.Principals), module_hash = test_hash(2)}), .Apply, .Role_Not_Replaceable, 0},
		{set_of(1, 0, {role_word = u64(role_contract.Role.Start_Policy), module_hash = test_hash(2)}), .Apply, .Role_Not_Replaceable, 0},
		{set_of(1, 0, {role_word = u64(role_contract.Role.Block_Device), module_hash = test_hash(2)}), .Apply, .Role_Not_Replaceable, 0},
		{set_of(1, 0, {role_word = u64(role_contract.Role.Storage)}), .Apply, .Zero_Module_Hash, 0},
		{set_of(1, 0, good, good), .Apply, .Duplicate_Role, 1},
		{bytes_after, .Apply, .Bytes_After_Set, rd.PLAN_ROLES_OVERRIDE_CAPACITY - 1},
		{set_of(1, 0, good, {role_word = u64(role_contract.Role.Storage), module_hash = test_hash(9)}), .Apply, .Not_In_Image, 1},
		{set_of(1, 0, good, {role_word = u64(role_contract.Role.Storage), module_hash = test_hash(3)}), .Apply, .Contract_Not_Filled, 1},
		{set_of(1, 0, good, {role_word = u64(role_contract.Role.Storage), module_hash = test_hash(3)}), .Rollback, .Contract_Not_Filled, 1},
	}
	for &item in cases {
		refusal, index := holder_overrides_replace(&names, &kept, &item.set, item.step, resolver)
		testing.expect_value(t, refusal, item.refusal)
		testing.expect_value(t, index, item.index)
		// The good override before the bad one did not take the role.
		testing.expect_value(t, holder_name(&names, .Display), "compositor")
		testing.expect_value(t, holder_name(&names, .Storage), "storage")
		testing.expect_value(t, kept.serial, 0)
		testing.expect_value(t, kept.generation, 0)
	}
}

@(test)
plan_overrides_refuse_with_no_resolver :: proc(t: ^testing.T) {
	names := test_names()
	kept: Override_Names
	set := set_of(1, 0, {role_word = u64(role_contract.Role.Display), module_hash = test_hash(1)})
	refusal, _ := holder_overrides_replace(&names, &kept, &set, .Apply, {})
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.Not_In_Image)
	testing.expect_value(t, holder_name(&names, .Display), "compositor")
}

@(test)
plan_overrides_apply_then_roll_back_whole :: proc(t: ^testing.T) {
	names := test_names()
	kept: Override_Names
	resolver := test_resolver()

	first := set_of(1, 0, {role_word = u64(role_contract.Role.Display), module_hash = test_hash(1)})
	refusal, _ := holder_overrides_replace(&names, &kept, &first, .Apply, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Display), "other_compositor")
	testing.expect_value(t, holder_name(&names, .Storage), "storage")
	testing.expect_value(t, kept.serial, 1)
	testing.expect_value(t, kept.generation, 1)

	// A replay of the first set does not follow the set in force.
	refusal, _ = holder_overrides_replace(&names, &kept, &first, .Apply, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.Stale_Serial)
	testing.expect_value(t, kept.serial, 1)

	// The second generation drops the display and takes the storage.
	second := set_of(2, 1, {role_word = u64(role_contract.Role.Storage), module_hash = test_hash(2)})
	refusal, _ = holder_overrides_replace(&names, &kept, &second, .Apply, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Display), "compositor")
	testing.expect_value(t, holder_name(&names, .Storage), "other_storage")
	testing.expect_value(t, is_holder(&names, "storage", .Storage), false)

	// A refused rollback leaves the second generation whole.
	bad_rollback := set_of(1, 2, {role_word = u64(role_contract.Role.Display), module_hash = test_hash(3)})
	refusal, _ = holder_overrides_replace(&names, &kept, &bad_rollback, .Rollback, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.Contract_Not_Filled)
	testing.expect_value(t, holder_name(&names, .Storage), "other_storage")
	testing.expect_value(t, holder_name(&names, .Display), "compositor")
	testing.expect_value(t, kept.generation, 2)

	// The rollback to the first generation restores its holders whole.
	rollback := set_of(1, 2, {role_word = u64(role_contract.Role.Display), module_hash = test_hash(1)})
	refusal, _ = holder_overrides_replace(&names, &kept, &rollback, .Rollback, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Display), "other_compositor")
	testing.expect_value(t, holder_name(&names, .Storage), "storage")
	testing.expect_value(t, kept.serial, 3)
	testing.expect_value(t, kept.generation, 1)

	// The rollback to the defaults of the image: a set with no override.
	defaults := set_of(0, 3)
	refusal, _ = holder_overrides_replace(&names, &kept, &defaults, .Rollback, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Display), "compositor")
	testing.expect_value(t, kept.generation, 0)
}

@(test)
plan_overrides_border_of_the_step :: proc(t: ^testing.T) {
	_, ok := rd.plan_roles_step_of_word(0)
	testing.expect(t, !ok)
	_, ok = rd.plan_roles_step_of_word(4)
	testing.expect(t, !ok)
	_, ok = rd.plan_roles_step_of_word(max(u64))
	testing.expect(t, !ok)
	step: rd.Plan_Roles_Step
	step, ok = rd.plan_roles_step_of_word(3)
	testing.expect(t, ok)
	testing.expect_value(t, step, rd.Plan_Roles_Step.Rollback)
}
