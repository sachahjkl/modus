#+build !linux
package machine

// The share of the host and the available memory on a host with no /proc:
// each counter is unknown, the failure line says so, and the parts have no
// bound by memory (host_share_linux.odin reads them on Linux).

host_share_sample :: proc(process_identifier: int) -> (sample: Host_Share_Sample) {
	return {processor_fault = .Unreadable, run_delay_fault = .Unreadable, memory_fault = .Unreadable}
}

host_memory_available_mib :: proc() -> (mib: u64, known: bool) {
	return 0, false
}
