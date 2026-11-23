#+build !linux
package cache_server

// cache_disk_free_bytes gives no free space on a host with no statfs that
// the tool calls: the page then says that it does not know it.
cache_disk_free_bytes :: proc(folder: string) -> (bytes: u64, known: bool) {
	return 0, false
}
