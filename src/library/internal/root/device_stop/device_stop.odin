// The stop order of a device service (src/md/features/device_services.md):
// the root service turns PCI Bus Master off before calling Process_Stop on
// every device service, so a device makes no access to memory between the
// stop of its service and the reap, also on a machine with no IOMMU. When a
// device service stops on its own, the reap turns Bus Master off before
// closing its queue memory.
package device_stop

import "modus:contract/call_outcome"

// What the root service does when a process with the start grant Sound_Device
// starts (src/md/features/missing_hardware.md): a second process is refused
// while another holds the device, a soundless machine starts the process with
// no sound handles, and a machine with a sound device starts the sound service.
Sound_Device_Start_Action :: enum u8 {
	Start_Driver,
	Start_Without_Sound,
	Refuse_Busy,
}

// sound_device_start_decide chooses the start action for a process with the
// grant Sound_Device. A busy sound device refuses a second holder first.
sound_device_start_decide :: proc "contextless" (device_busy, sound_device_present: bool) -> Sound_Device_Start_Action {
	if device_busy {
		return .Refuse_Busy
	}
	if !sound_device_present {
		return .Start_Without_Sound
	}
	return .Start_Driver
}

// sound_device_driver_status_allows_silent reports whether a driver_start
// outcome means the sound device is absent so the client can start without
// sound handles. Every other refusal stops the start.
sound_device_driver_status_allows_silent :: proc "contextless" (status: call_outcome.Call_Outcome) -> bool {
	return status == .Nothing_Has_That_Name
}

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
