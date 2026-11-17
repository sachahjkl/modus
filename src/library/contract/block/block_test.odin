#+build !freestanding
package block

import "core:testing"

// The command of an error record comes from the block service. A word that
// names no command gives no name of a command and no name of a value:
// -1, one past the last command, the largest and the smallest word. A
// value past the names of its command has no name. Then each command
// names itself.
@(test)
a_command_that_names_no_member_has_no_name :: proc(t: ^testing.T) {
	refused := [?]i64{-1, i64(max(Command)) + 1, max(i64), min(i64)}
	for word in refused {
		_, ok := command_of_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, command_name(word), "an unknown command")
		testing.expect_value(t, argument_name(word, 1), "")
	}
	arguments := [?]i64{0, -1, i64(len(ARGUMENT_NAMES[.Read])) + 1, 8, max(i64)}
	for argument in arguments {
		testing.expect_value(t, argument_name(i64(Command.Read), argument), "")
	}
	for member in Command {
		read, ok := command_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
		testing.expect_value(t, command_name(i64(member)), COMMAND_NAMES[member])
	}
	testing.expect_value(t, argument_name(i64(Command.Read), 3), "place")
	testing.expect_value(t, argument_name(i64(Command.Attach), 1), "region")
}
