package text_model

// Undo and redo as a walk over the versions of the object in the store
// (src/md/features/editor.md, "The chosen form"). Ctrl+Z restores the
// version before the one that the editor shows; Ctrl+Y goes forward again,
// only along the restores that Ctrl+Z made. The walk holds no text: the
// store keeps each version, so an undo works after a restart too.
//
// The decisions are pure: the editor lists the generations of the
// versions, asks the walk for the generation to restore, restores it, and
// only then tells the walk that the step was taken. A restore that the
// store refuses leaves the walk as it was.

// The steps back that Ctrl+Y can go forward along. A longer run of Ctrl+Z
// forgets its oldest step: Ctrl+Y then stops one step short of the start.
WALK_FORWARD_CAPACITY :: 256

Version_Walk :: struct {
	// The generation whose text the editor shows after a restore: the walk
	// goes back from it, not from the commit of the restore. 0: the
	// current version, after a change or at the start.
	shown:         i64,
	forward:       [WALK_FORWARD_CAPACITY]i64, // The generations that Ctrl+Z left, the newest last.
	forward_count: int,
	forgotten:     int, // The steps that a full forward list dropped.
}

// One step of the walk: from the generation shown to the one to restore.
Walk_Step :: struct {
	from: i64,
	to:   i64,
}

// Why the walk takes no step. The editor writes it on the log and does
// nothing else.
Walk_Problem :: enum u8 {
	None             = 0,
	No_Version       = 1, // The list has no generation: the object has no commit yet.
	Not_In_Order     = 2, // The list is not in the order of the store, the oldest first, or names a generation below 1: the walk refuses it whole.
	No_Older_Version = 3, // Ctrl+Z at the first version: nothing is before it.
	No_Newer_Version = 4, // Ctrl+Y with no Ctrl+Z to go forward along.
}

// The words of each problem, for a line of the log.
@(rodata)
walk_problem_texts := [Walk_Problem]string {
	.None             = "no problem",
	.No_Version       = "the text has no version yet",
	.Not_In_Order     = "the list of the versions is not in order",
	.No_Older_Version = "no version is older",
	.No_Newer_Version = "no undo to go forward along",
}

// walk_back finds the step of Ctrl+Z: the newest generation of the list
// below the one shown. generations is the list of the store, the oldest
// first and the current version last.
walk_back :: proc "contextless" (walk: ^Version_Walk, generations: []i64) -> (step: Walk_Step, problem: Walk_Problem) {
	if len(generations) == 0 {
		return {}, .No_Version
	}
	for generation, index in generations {
		if generation < 1 || index > 0 && generation <= generations[index - 1] {
			return {}, .Not_In_Order
		}
	}
	from := walk.shown != 0 ? walk.shown : generations[len(generations) - 1]
	for index := len(generations) - 1; index >= 0; index -= 1 {
		if generations[index] < from {
			return {from = from, to = generations[index]}, .None
		}
	}
	return {}, .No_Older_Version
}

// walk_went_back records a step of Ctrl+Z that the store took.
walk_went_back :: proc "contextless" (walk: ^Version_Walk, step: Walk_Step) {
	if walk.forward_count == WALK_FORWARD_CAPACITY {
		copy(walk.forward[:WALK_FORWARD_CAPACITY - 1], walk.forward[1:])
		walk.forward_count -= 1
		walk.forgotten += 1
	}
	walk.forward[walk.forward_count] = step.from
	walk.forward_count += 1
	walk.shown = step.to
}

// walk_forward finds the step of Ctrl+Y: back to the generation that the
// last Ctrl+Z left.
walk_forward :: proc "contextless" (walk: ^Version_Walk) -> (step: Walk_Step, problem: Walk_Problem) {
	if walk.forward_count == 0 {
		return {}, .No_Newer_Version
	}
	return {from = walk.shown, to = walk.forward[walk.forward_count - 1]}, .None
}

// walk_went_forward records a step of Ctrl+Y that the store took.
walk_went_forward :: proc "contextless" (walk: ^Version_Walk, step: Walk_Step) {
	if walk.forward_count > 0 {
		walk.forward_count -= 1
	}
	walk.shown = step.to
}

// walk_changed records a change of the text: the next Ctrl+Z goes back
// from the current version, and Ctrl+Y has nothing to go forward along.
walk_changed :: proc "contextless" (walk: ^Version_Walk) {
	walk.shown = 0
	walk.forward_count = 0
}
