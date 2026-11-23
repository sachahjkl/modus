package foundation

import "core:strings"
import "core:sys/linux"

// file_owned_by_this_user says if the user of this process owns the file.
file_owned_by_this_user :: proc(path: string) -> bool {
	record: linux.Stat
	path_text := strings.clone_to_cstring(path, context.temp_allocator)
	return linux.stat(path_text, &record) == .NONE && record.uid == linux.getuid()
}
