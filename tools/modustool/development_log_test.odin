package modustool

import "core:testing"

// A run in a worktree writes the development log beside the main working
// tree, not beside the worktree.
@(test)
development_log_is_beside_the_main_working_tree :: proc(t: ^testing.T) {
	testing.expect_value(t, development_log_folder_of("gitdir: /home/a/kernel/.git/worktrees/palette\n"), "/home/a/kernel/../kernel-devlog")
	testing.expect_value(t, development_log_folder_of(""), "../kernel-devlog")
	testing.expect_value(t, development_log_folder_of("gitdir: /home/a/other.git\n"), "../kernel-devlog")
}
