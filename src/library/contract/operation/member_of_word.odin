package operation

import "base:intrinsics"

// member_of_word reads a word of a command record, of a ring or of a
// context as a member of the enumeration `Enum`. A word that names no
// member gives `ok` false: the caller refuses it, and never takes it for a
// member. It walks the members, so a member added with a hole in the
// numbering cannot let a word of the hole pass, as a test of the range
// would.
//
// The kernel reads each choice of an operation through it: a contract
// package imports no support package, so `system.member_of_word` is not
// there to call.
//
// Example: `member_of_word(Device_Kind, 6)` gives `ok` false;
// `member_of_word(Device_Kind, 4)` gives `.Message`.
member_of_word :: proc "contextless" ($Enum: typeid, word: u64) -> (member: Enum, ok: bool) where intrinsics.type_is_enum(Enum) {
	for candidate in Enum {
		if u64(candidate) == word {
			return candidate, true
		}
	}
	return {}, false
}
