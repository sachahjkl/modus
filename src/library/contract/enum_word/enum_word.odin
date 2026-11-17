// The one conversion of a word of a record into a member of an enumeration
// (src/md/infrastructure/choice_constants.md).
//
// A word that comes from another party (a value of the context, a field of
// a record, a word of a ring) becomes its member at one place, the border,
// and that place refuses a word that names no member. A cast would take
// such a word for a member that does not exist, and a `switch` on it would
// then run no case.
//
// The procedure is in a contract package, so that a contract package and a
// support package call the same loop: a contract package imports no
// support package.
package enum_word

import "base:intrinsics"

// member_of_word reads a word of a record as a member of the enumeration
// `Enum`. A word that names no member is refused: the caller answers it
// with an error record, and never takes it for a member.
//
// Example: with `Mode :: enum u64 {First = 1, Second = 2}`,
// `member_of_word(Mode, 2)` is `.Second, true`, and `member_of_word(Mode, 3)`
// is `{}, false`.
member_of_word :: proc "contextless" ($Enum: typeid, word: u64) -> (member: Enum, ok: bool) where intrinsics.type_is_enum(Enum) {
	for candidate in Enum {
		if u64(candidate) == word {
			return candidate, true
		}
	}
	return {}, false
}
