#+build !freestanding
#+build !modus
package operation

import "core:testing"

// A value that names no command reaches the three procedures of the rights
// of Thread_Control only through a cast that skips the border of the
// command; the cast here makes that value on purpose, to test the line
// after each whole switch. Each one fails closed: a requirement that no
// handle holds, no machine handle, no debug handle.
@(test)
a_command_of_no_member_gets_no_right :: proc(t: ^testing.T) {
	every_right: Rights
	for right in Right {
		every_right += {right}
	}
	for word in ([]u64{u64(max(Thread_Control_Command)) + 1, max(u64)}) {
		command := Thread_Control_Command(word)
		required := thread_control_rights(command)
		testing.expectf(t, !(required <= every_right), "the word %v requires a right that no handle holds", word)
		_, by_machine_number := thread_control_machine_rights(command)
		testing.expectf(t, !by_machine_number, "the word %v takes no machine handle", word)
		testing.expectf(t, !thread_control_takes_debug_handle(command), "the word %v takes no debug handle", word)
	}
}
