package foundation

import "core:os"
import "core:testing"

// The path that starts this binary again names the file that this process
// runs: the same inode as the path of its file, so a host process runs the
// code of its parent. The path holds no folder of the repository, so a
// new file at build/tool cannot change what it names.
@(test)
tool_executable_path_names_the_binary_of_this_process :: proc(t: ^testing.T) {
	path, ok := tool_executable_path()
	testing.expect(t, ok, "the path is known")
	testing.expect_value(t, path, TOOL_EXECUTABLE_OF_THIS_PROCESS)
	executable, path_error := os.get_executable_path(context.temp_allocator)
	testing.expect(t, path_error == nil, "the file of this process is known")
	of_the_path, path_stat_error := os.stat(path, context.temp_allocator)
	of_the_file, file_stat_error := os.stat(executable, context.temp_allocator)
	testing.expect(t, path_stat_error == nil && file_stat_error == nil, "both can be read")
	testing.expect(t, of_the_path.inode != 0 && of_the_path.inode == of_the_file.inode, "the path names the file that this process runs")
}
