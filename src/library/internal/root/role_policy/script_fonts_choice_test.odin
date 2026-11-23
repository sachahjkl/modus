#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
hash_of :: proc(value: u8) -> (hash: blake3.Hash) {
	hash[0] = value
	return hash
}

// A plan names a set before the read; a later plan with no entry, still
// before the read, gives the set back to the boot image (the rollback);
// with no set in the boot image, none. After the read began, each choice
// waits for the next start, and the set of this start stays.
@(test)
a_plan_with_no_entry_gives_the_set_back_to_the_image :: proc(t: ^testing.T) {
	image, planned := hash_of(1), hash_of(2)
	stage, named, outcome := script_fonts_plan_choice(.Named, image, image, planned)
	testing.expect(t, stage == .Named && named == planned && outcome == .Named_By_Plan)
	// The rollback before the read.
	stage, named, outcome = script_fonts_plan_choice(stage, named, image, {})
	testing.expect(t, stage == .Named && named == image && outcome == .Back_To_Image)
	// The same plan again changes nothing.
	_, _, outcome = script_fonts_plan_choice(stage, named, image, {})
	testing.expect_value(t, outcome, Script_Fonts_Outcome.Unchanged)
	_, _, outcome = script_fonts_plan_choice(.Named, planned, image, planned)
	testing.expect_value(t, outcome, Script_Fonts_Outcome.Unchanged)
	// No set in the image: a plan names one, then none.
	stage, named, outcome = script_fonts_plan_choice(.Unnamed, {}, {}, planned)
	testing.expect(t, stage == .Named && named == planned && outcome == .Named_By_Plan)
	stage, named, outcome = script_fonts_plan_choice(stage, named, {}, {})
	testing.expect(t, stage == .Unnamed && named == {} && outcome == .Unnamed_Again)
	// After the read began: the next start, and nothing changes now.
	for later in ([3]Script_Fonts_Stage{.Reading, .Mapped, .Absent}) {
		stage, named, outcome = script_fonts_plan_choice(later, planned, image, {})
		testing.expectf(t, stage == later && named == planned && outcome == .Next_Start, "%v: %v %v", later, stage, outcome)
		stage, named, outcome = script_fonts_plan_choice(later, image, image, planned)
		testing.expectf(t, stage == later && named == image && outcome == .Next_Start, "%v: %v %v", later, stage, outcome)
	}
}
