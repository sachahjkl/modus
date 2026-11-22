#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

@(private = "file")
READ_FACTS :: Plan_At_Start_Facts{data_disk = true, plans_module = true, storage_module = true}

// Each reason to skip ends the read at once, with no deadline, and the
// rescue comes first: a rescue on a machine with no disk names the rescue.
@(test)
plan_at_start_skips_a_machine_that_cannot_hold_a_plan :: proc(t: ^testing.T) {
	Case :: struct {
		facts: Plan_At_Start_Facts,
		skip:  Plan_At_Start_Skip,
	}
	cases := [?]Case {
		{{rescue = true}, .Rescue},
		{{rescue = true, data_disk = true, plans_module = true, storage_module = true}, .Rescue},
		{{}, .No_Data_Disk},
		{{plans_module = true, storage_module = true}, .No_Data_Disk},
		{{data_disk = true, storage_module = true}, .No_Plans_Module},
		{{data_disk = true, plans_module = true}, .No_Storage_Module},
	}
	for item in cases {
		read: Plan_At_Start
		skip, begun := plan_at_start_begin(&read, item.facts, 100, 60_000)
		testing.expect(t, begun)
		testing.expect_value(t, skip, item.skip)
		testing.expect_value(t, read.stage, Plan_At_Start_Stage.Ended)
		testing.expect_value(t, read.deadline, u64(0))
		// No wait: no deadline wakes the loop, a check ends nothing, and a
		// Loaded of a holder that starts later is not taken.
		testing.expect_value(t, plan_at_start_wake(&read, max(u64)), max(u64))
		testing.expect_value(t, plan_at_start_check(&read, max(u64), false), Plan_At_Start_End.None)
		testing.expect(t, !plan_at_start_loaded(&read, .Applied))
		testing.expect_value(t, read.outcome, rd.Plan_Roles_Load_Outcome.None)
	}
}

// A read begins once: a second begin is refused and changes nothing.
@(test)
plan_at_start_begins_once :: proc(t: ^testing.T) {
	read: Plan_At_Start
	skip, begun := plan_at_start_begin(&read, READ_FACTS, 10, 5)
	testing.expect(t, begun)
	testing.expect_value(t, skip, Plan_At_Start_Skip.None)
	testing.expect_value(t, read.stage, Plan_At_Start_Stage.Waiting)
	testing.expect_value(t, read.deadline, u64(15))
	kept := read
	_, again := plan_at_start_begin(&read, READ_FACTS, 1000, 5)
	testing.expect(t, !again)
	testing.expect_value(t, read, kept)
	_, again = plan_at_start_begin(&read, {}, 1000, 5)
	testing.expect(t, !again)
	testing.expect_value(t, read, kept)
}

// Loaded ends the wait once, with its outcome; None is no outcome and
// ends nothing; a check after the end ends nothing more.
@(test)
plan_at_start_takes_one_loaded :: proc(t: ^testing.T) {
	read: Plan_At_Start
	plan_at_start_begin(&read, READ_FACTS, 0, 100)
	testing.expect(t, !plan_at_start_loaded(&read, .None))
	testing.expect_value(t, read.stage, Plan_At_Start_Stage.Waiting)
	testing.expect(t, plan_at_start_loaded(&read, .Plan_Refused))
	testing.expect_value(t, read.stage, Plan_At_Start_Stage.Ended)
	testing.expect_value(t, read.outcome, rd.Plan_Roles_Load_Outcome.Plan_Refused)
	testing.expect(t, !plan_at_start_loaded(&read, .Applied))
	testing.expect_value(t, read.outcome, rd.Plan_Roles_Load_Outcome.Plan_Refused)
	testing.expect_value(t, plan_at_start_check(&read, max(u64), false), Plan_At_Start_End.None)

	// A Loaded before any begin is not taken either.
	before: Plan_At_Start
	testing.expect(t, !plan_at_start_loaded(&before, .Applied))
	testing.expect_value(t, before, Plan_At_Start{})
}

// The wait ends at the deadline, not one millisecond before; a holder that
// stopped ends it at once; the deadline of a start near the end of the
// clock does not wrap.
@(test)
plan_at_start_ends_at_the_bound_or_the_stop :: proc(t: ^testing.T) {
	read: Plan_At_Start
	plan_at_start_begin(&read, READ_FACTS, 1000, 500)
	testing.expect_value(t, plan_at_start_wake(&read, max(u64)), u64(1500))
	testing.expect_value(t, plan_at_start_check(&read, 1000, true), Plan_At_Start_End.None)
	testing.expect_value(t, plan_at_start_check(&read, 1499, true), Plan_At_Start_End.None)
	testing.expect_value(t, plan_at_start_check(&read, 1500, true), Plan_At_Start_End.Late)
	testing.expect_value(t, read.stage, Plan_At_Start_Stage.Ended)
	testing.expect_value(t, plan_at_start_check(&read, 1501, true), Plan_At_Start_End.None)
	testing.expect(t, !plan_at_start_loaded(&read, .Applied))

	stopped: Plan_At_Start
	plan_at_start_begin(&stopped, READ_FACTS, 0, 500)
	testing.expect_value(t, plan_at_start_check(&stopped, 0, false), Plan_At_Start_End.Holder_Stopped)
	testing.expect_value(t, stopped.stage, Plan_At_Start_Stage.Ended)

	late_clock: Plan_At_Start
	plan_at_start_begin(&late_clock, READ_FACTS, max(u64) - 1, 500)
	testing.expect_value(t, late_clock.deadline, max(u64))
	testing.expect_value(t, plan_at_start_check(&late_clock, max(u64) - 1, true), Plan_At_Start_End.None)

	zero_bound: Plan_At_Start
	plan_at_start_begin(&zero_bound, READ_FACTS, 7, 0)
	testing.expect_value(t, plan_at_start_check(&zero_bound, 7, true), Plan_At_Start_End.Late)
}

// A holder that did not start abandons the wait; an abandon out of a wait
// changes nothing.
@(test)
plan_at_start_abandon_ends_a_wait_only :: proc(t: ^testing.T) {
	before: Plan_At_Start
	plan_at_start_abandon(&before)
	testing.expect_value(t, before.stage, Plan_At_Start_Stage.Before)
	read: Plan_At_Start
	plan_at_start_begin(&read, READ_FACTS, 0, 100)
	plan_at_start_abandon(&read)
	testing.expect_value(t, read.stage, Plan_At_Start_Stage.Ended)
	testing.expect(t, !plan_at_start_loaded(&read, .Applied))
}

@(private = "file")
boot_hash :: proc(tag: u8) -> (hash: blake3.Hash) {
	hash[0] = tag
	hash[31] = tag ~ 0x5A
	return hash
}

@(private = "file")
Boot_Image :: struct {
	hash: blake3.Hash,
	name: string,
}

@(private = "file")
boot_name_of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool) {
	image := (^Boot_Image)(user)
	if hash == image.hash {
		return image.name, true
	}
	return "", false
}

@(private = "file")
boot_fills :: proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool {
	return module_name != "old_compositor"
}

// At the start, the core holds the defaults of the image (serial 0,
// generation 0). The stored plan of generation 3 comes with the step
// Rollback: a holder of Display that the image holds replaces the default
// before the start policy; one that a newer image lacks, or that no longer
// fills the contract, is refused and the defaults hold.
@(test)
plan_at_start_the_stored_display_holder_holds_before_the_start_policy :: proc(t: ^testing.T) {
	override := rd.Plan_Role_Override{role_word = u64(role_contract.Role.Display), module_hash = boot_hash(1)}
	set := rd.Plan_Roles_Set{generation = 3, override_count = 1}
	set.overrides[0] = override

	names: Holder_Names
	names.defaults[.Display] = "compositor"
	kept: Override_Names
	image := Boot_Image{hash = boot_hash(1), name = "other_compositor"}
	resolver := Holder_Resolver{user = &image, name_of_hash = boot_name_of_hash, fills = boot_fills}
	refusal, _ := holder_overrides_replace(&names, &kept, &set, .Rollback, resolver)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Display), "other_compositor")
	testing.expect(t, !is_holder(&names, "compositor", .Display))
	testing.expect_value(t, kept.generation, u64(3))
	testing.expect_value(t, kept.serial, u64(1))

	// A newer image: the hash names no module.
	newer_names: Holder_Names
	newer_names.defaults[.Display] = "compositor"
	newer_kept: Override_Names
	newer_image := Boot_Image{hash = boot_hash(2), name = "other_compositor"}
	newer := Holder_Resolver{user = &newer_image, name_of_hash = boot_name_of_hash, fills = boot_fills}
	refusal, _ = holder_overrides_replace(&newer_names, &newer_kept, &set, .Rollback, newer)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.Not_In_Image)
	testing.expect_value(t, holder_name(&newer_names, .Display), "compositor")
	testing.expect_value(t, newer_kept, Override_Names{})

	// The module is there and no longer fills the contract of Display.
	old_image := Boot_Image{hash = boot_hash(1), name = "old_compositor"}
	old := Holder_Resolver{user = &old_image, name_of_hash = boot_name_of_hash, fills = boot_fills}
	refusal, _ = holder_overrides_replace(&newer_names, &newer_kept, &set, .Rollback, old)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.Contract_Not_Filled)
	testing.expect_value(t, holder_name(&newer_names, .Display), "compositor")
	testing.expect_value(t, newer_kept, Override_Names{})

	// After the fallback the next apply, with a module of the new image,
	// is taken at the serial of the defaults.
	next := rd.Plan_Roles_Set{generation = 4, override_count = 1}
	next.overrides[0] = {role_word = u64(role_contract.Role.Display), module_hash = boot_hash(2)}
	refusal, _ = holder_overrides_replace(&newer_names, &newer_kept, &next, .Apply, newer)
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&newer_names, .Display), "other_compositor")
}
