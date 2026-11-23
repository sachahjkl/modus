package cache_server

import "core:strings"
import "core:sys/linux"

// cache_disk_free_bytes gives the bytes of the file system of the folder
// that a process with no special right can still write.
cache_disk_free_bytes :: proc(folder: string) -> (bytes: u64, known: bool) {
	path := strings.clone_to_cstring(folder, context.temp_allocator)
	information: linux.Stat_FS
	if linux.statfs(path, &information) != .NONE {
		return 0, false
	}
	return u64(information.bavail) * u64(information.bsize), true
}
