package foundation

// The path that starts the binary of this process again, as a host process
// of the tool (a step of a module, a boot volume, an outside module, the
// notes of a release).
//
// Not the path of the file in build/tool: a later command of the tool,
// after a change of its sources, compiles a new binary and renames it over
// that file while this process runs. The path then names a file that is
// gone, or a binary of other sources, and every host process of a long
// command fails, or runs other code than its parent. The kernel keeps the
// file of a running process, and an exec of /proc/self/exe in the child of
// a fork runs that file: the same code as the parent, whatever happened to
// the path.
TOOL_EXECUTABLE_OF_THIS_PROCESS :: "/proc/self/exe"

tool_executable_path :: proc() -> (path: string, ok: bool) {
	return TOOL_EXECUTABLE_OF_THIS_PROCESS, true
}
