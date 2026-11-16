#+build !freestanding
package system

import "core:testing"

// A word of the root ring becomes its member at member_of_word only. Each
// word that names no member is refused first: 0 where 0 is no member, one
// past the largest member, a word between two members, the largest word.
// Then each member comes back from its own word.
@(test)
member_of_word_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	refuse :: proc(t: ^testing.T, $Enum: typeid, words: []u64) {
		for word in words {
			_, ok := member_of_word(Enum, word)
			testing.expectf(t, !ok, "%v: the word %d names no member, and it is taken", typeid_of(Enum), word)
		}
	}
	accept_each :: proc(t: ^testing.T, $Enum: typeid) {
		for member in Enum {
			read, ok := member_of_word(Enum, u64(member))
			testing.expect(t, ok)
			testing.expect_value(t, read, member)
		}
	}
	// Enumerations whose first member is not 0: 0 is refused.
	refuse(t, Remote_Client_Action, {0, u64(max(Remote_Client_Action)) + 1, 1 << 32, max(u64)})
	refuse(t, Principal_Change, {0, u64(max(Principal_Change)) + 1, max(u64)})
	refuse(t, Disk_Grant_Action, {0, u64(max(Disk_Grant_Action)) + 1, max(u64)})
	refuse(t, Machine_Key_State, {0, u64(max(Machine_Key_State)) + 1, max(u64)})
	refuse(t, Principal_Key_Origin, {0, u64(max(Principal_Key_Origin)) + 1, max(u64)})
	// Enumerations whose first member is 0.
	refuse(t, Remote_Client_State, {u64(max(Remote_Client_State)) + 1, max(u64)})
	refuse(t, Machine_Key_Form, {u64(max(Machine_Key_Form)) + 1, max(u64)})
	accept_each(t, Remote_Client_Action)
	accept_each(t, Remote_Client_State)
	accept_each(t, Principal_Change)
	accept_each(t, Disk_Grant_Action)
	accept_each(t, Machine_Key_State)
	accept_each(t, Machine_Key_Form)
	accept_each(t, Principal_Key_Origin)
}

// An enumeration whose values have a gap: a word in the gap names no
// member, though it is between the smallest and the largest.
@(test)
member_of_word_refuses_a_word_in_a_gap :: proc(t: ^testing.T) {
	With_A_Gap :: enum u64 {
		First = 1,
		Third = 3,
	}
	_, ok := member_of_word(With_A_Gap, u64(With_A_Gap.First) + 1)
	testing.expect(t, !ok)
	read, read_ok := member_of_word(With_A_Gap, u64(With_A_Gap.Third))
	testing.expect(t, read_ok)
	testing.expect_value(t, read, With_A_Gap.Third)
}
