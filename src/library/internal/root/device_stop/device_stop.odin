// The stop order of a device service (src/md/features/device_services.md):
// the root service turns PCI Bus Master off before calling Process_Stop on
// every device service, so a device makes no access to memory between the
// stop of its service and the reap, also on a machine with no IOMMU. When a
// device service stops on its own, the reap turns Bus Master off before
// closing its queue memory.
package device_stop

// Stop_Actions names what the root service does when it stops a started
// process: disable_bus_master_before_stop runs before stop_process.
Stop_Actions :: struct {
	disable_bus_master_before_stop: bool,
	stop_process:                   bool,
}

// Reap_Actions names what the root service does when it reaps a stopped
// device service: disable_bus_master runs before close_queues.
Reap_Actions :: struct {
	disable_bus_master: bool,
	close_queues:       bool,
}

// stop_decide gives the actions for stopping a started process and clears
// bus_master_active once Bus Master is scheduled to be turned off.
stop_decide :: proc "contextless" (has_process, is_driver: bool, bus_master_active: ^bool) -> Stop_Actions {
	if !has_process {
		return {}
	}
	disable := is_driver && bus_master_active != nil && bus_master_active^
	if disable {
		bus_master_active^ = false
	}
	return {disable_bus_master_before_stop = disable, stop_process = true}
}

// reap_decide gives the actions for reaping a stopped process and clears
// bus_master_active if the device service stopped on its own while Bus
// Master was still on.
reap_decide :: proc "contextless" (is_driver: bool, bus_master_active: ^bool) -> Reap_Actions {
	if !is_driver {
		return {}
	}
	disable := bus_master_active != nil && bus_master_active^
	if disable {
		bus_master_active^ = false
	}
	return {disable_bus_master = disable, close_queues = true}
}
