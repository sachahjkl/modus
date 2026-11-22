package kernel

import "modus:contract/kernel_fault_isolation"
import "modus:contract/serial_ring"

// Live kernel hook for Machine Check (#MC) / NMI single-process fault
// containment: returns true when a hardware fault in user ring (CPL=3) can be
// safely isolated by terminating only the interrupted user process.
kernel_mce_can_isolate_user_process :: proc "contextless" (mci_status: u64, in_user_ring, rip_valid, addr_valid: bool) -> bool {
	return kernel_fault_isolation.classify_machine_check(mci_status, in_user_ring, rip_valid, addr_valid) == .Kill_User_Process
}

// Live kernel hook validating zero-map memory-object copy-out byte ranges.
kernel_memory_copy_out_range_valid :: proc "contextless" (object_bytes, src_offset, length, dst_capacity: u64) -> bool {
	return serial_ring.memory_copy_out_valid(object_bytes, src_offset, length, dst_capacity)
}
