package kernel

import "modus:contract/kernel_fault_isolation"
import "modus:contract/serial_ring"

// Kernel helper for Machine Check (#MC) / NMI user-process fault isolation
// (contract helper; wired when the MCE interrupt vector dispatches user poison).
kernel_mce_can_isolate_user_process :: proc "contextless" (mci_status: u64, ser_supported, in_user_ring, rip_valid, addr_valid: bool) -> bool {
	return kernel_fault_isolation.classify_machine_check(mci_status, ser_supported, in_user_ring, rip_valid, addr_valid) == .Kill_User_Process
}

// Kernel helper validating zero-map memory-object copy-out byte ranges.
kernel_memory_copy_out_range_valid :: proc "contextless" (object_bytes, src_offset, length, dst_capacity: u64) -> bool {
	return serial_ring.memory_copy_out_valid(object_bytes, src_offset, length, dst_capacity)
}
