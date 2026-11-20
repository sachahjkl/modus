#+build !linux
package foundation

import "core:fmt"
import "core:os"

// The path that starts the binary of this process again. With no
// /proc/self/exe, the path of the file: a new build of the tool during a
// long command makes the host processes after it fail
// (tool_executable_linux.odin).
tool_executable_path :: proc() -> (path: string, ok: bool) {
	executable, path_error := os.get_executable_path(context.temp_allocator)
	if path_error != nil {
		fmt.eprintfln("modustool: cannot find the file of the tool: %v", path_error)
		return "", false
	}
	return executable, true
}
