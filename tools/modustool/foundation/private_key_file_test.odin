package foundation

import "core:os"
import "core:strings"
import "core:testing"

@(test)
a_private_key_mode_with_a_bit_for_another_user_is_refused :: proc(t: ^testing.T) {
	read_modes := [?]int{0o640, 0o604, 0o644, 0o777}
	for mode in read_modes {
		problem := private_key_mode_problem("key", os.perm(mode))
		testing.expect(t, strings.contains(problem, "can be read by other users"))
	}
	write_modes := [?]int{0o620, 0o602, 0o622}
	for mode in write_modes {
		problem := private_key_mode_problem("key", os.perm(mode))
		testing.expect(t, strings.contains(problem, "can be written by other users"))
		testing.expect(t, !strings.contains(problem, "can be read"))
	}
	run_modes := [?]int{0o610, 0o601}
	for mode in run_modes {
		problem := private_key_mode_problem("key", os.perm(mode))
		testing.expect(t, strings.contains(problem, "can be run by other users"))
	}
	// Last: the modes of the owner alone.
	owner_modes := [?]int{0o600, 0o400, 0o700}
	for mode in owner_modes {
		testing.expect_value(t, private_key_mode_problem("key", os.perm(mode)), "")
	}
}
