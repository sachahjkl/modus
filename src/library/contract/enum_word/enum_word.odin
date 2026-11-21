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

// member_of_argument is the border of an Enum parameter of an export
// (src/md/features/enum_parameters.md): the argument comes in a register
// that the caller wrote, so it can hold a value that names no member.
// given is false for the absent word of an optional parameter that the call
// left out: each bit of the size of the enum set (module.enum_absent_word).
// ok is false for any other value that names no member: the export answers
// it with an error record.
//
// Example: with `Font :: enum u32 {Vector = 0, Spleen = 1}`,
// `member_of_argument(Font(1))` is `.Spleen, true, true`,
// `member_of_argument(Font(0xFFFF_FFFF))` is `{}, false, true`, and
// `member_of_argument(Font(2))` is `{}, true, false`.
member_of_argument :: proc "contextless" (argument: $Enum) -> (member: Enum, given: bool, ok: bool) where intrinsics.type_is_enum(Enum) {
	argument := argument
	bytes := transmute([size_of(Enum)]u8)argument
	absent := true
	for byte in bytes {
		absent &= byte == 0xFF
	}
	if absent {
		return {}, false, true
	}
	member, ok = member_of_word(Enum, u64(argument))
	return member, true, ok
}
