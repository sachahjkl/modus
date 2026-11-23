package role_policy

import "modus:contract/blake3"

// The choice of the script font set of a start (src/md/features/script_fonts.md,
// "The plan names it; the boot image names the default"): the plan of
// principal 0 names a set with its roles, and a plan with no entry gives
// the set back to the boot image. Before the read of this start, the
// choice holds at once; after it, at the next start.

// Where the set of this start stands.
Script_Fonts_Stage :: enum u8 {
	Unnamed, // Neither the plan nor the boot image names a set.
	Named, // A set is named; its read waits until the machine is usable.
	Reading, // The delegated service reads it.
	Mapped, // Checked: each process that starts maps it.
	Absent, // The machine does not hold it, or it was refused: the box stays until the next start.
}

// What a plan did to the set.
Script_Fonts_Outcome :: enum u8 {
	Unchanged, // The plan names the set of this start already.
	Named_By_Plan, // The plan names another set, which this start reads.
	Back_To_Image, // The plan names none: this start reads the set of the boot image again.
	Unnamed_Again, // The plan names none, and the boot image names none: no set this start.
	Next_Start, // The read of this start began: the choice holds at the next start.
}

// script_fonts_plan_choice gives the set and the stage after a plan of
// principal 0 that names planned (all zero: no entry), at a stage of the
// start, with the set named now and the set that the boot image names.
script_fonts_plan_choice :: proc "contextless" (stage: Script_Fonts_Stage, named, image, planned: blake3.Hash) -> (next_stage: Script_Fonts_Stage, next_named: blake3.Hash, outcome: Script_Fonts_Outcome) {
	wanted := planned == {} ? image : planned
	if wanted == named {
		return stage, named, .Unchanged
	}
	switch stage {
	case .Unnamed, .Named:
		switch {
		case planned != {}:
			return .Named, wanted, .Named_By_Plan
		case wanted != {}:
			return .Named, wanted, .Back_To_Image
		}
		return .Unnamed, {}, .Unnamed_Again
	case .Reading, .Mapped, .Absent:
	}
	return stage, named, .Next_Start
}
