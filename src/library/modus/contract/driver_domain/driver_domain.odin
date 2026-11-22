// Pure freestanding driver-domain guest proxy and resilient device class ring
// keeper (src/md/features/device_services.md).
//
// 1. Class_Ring_Keeper retains the client-facing class ring across device
//    service crashes and restarts (bounded backoff and max restarts), so
//    clients observe a brief delay rather than a broken connection.
// 2. Driver_Domain_Proxy confines Linux-only hardware drivers (e.g. Wi-Fi)
//    inside a guest domain exchanging only bounded class-protocol frames.
package driver_domain

import "modus:contract/enum_word"

MAX_RESTARTS_IN_WINDOW :: u32(5)
RESTART_WINDOW_MS :: u64(60_000)
MAX_PROXY_FRAME_BYTES :: 2048

Keeper_State :: enum u8 {
	Ready      = 1,
	Restarting = 2,
	Failed     = 3,
}

keeper_state_of_word :: proc "contextless" (word: u64) -> (s: Keeper_State, ok: bool) {
	return enum_word.member_of_word(Keeper_State, word)
}

Class_Ring_Keeper :: struct {
	state:             Keeper_State,
	generation:        u64,
	restarts_in_window: u32,
	window_start_ms:   u64,
	last_time_ms:      u64,
	has_time:          bool,
	queued_while_down: u64,
}

keeper_init :: proc "contextless" (k: ^Class_Ring_Keeper) {
	if k == nil {
		return
	}
	k^ = {state = .Ready, generation = 1}
}

// keeper_on_driver_stopped transitions the class ring keeper to .Restarting
// (or .Failed if restarts exceed MAX_RESTARTS_IN_WINDOW within RESTART_WINDOW_MS).
keeper_on_driver_stopped :: proc "contextless" (k: ^Class_Ring_Keeper, now_ms: u64) -> (should_restart: bool, ok: bool) {
	if k == nil || (k.has_time && now_ms < k.last_time_ms) {
		return false, false
	}
	k.has_time = true
	k.last_time_ms = now_ms
	if k.state == .Failed {
		return false, true
	}
	if k.restarts_in_window == 0 || now_ms - k.window_start_ms >= RESTART_WINDOW_MS {
		k.window_start_ms = now_ms
		k.restarts_in_window = 0
	}
	if k.restarts_in_window >= MAX_RESTARTS_IN_WINDOW {
		k.state = .Failed
		return false, true
	}
	k.restarts_in_window += 1
	k.state = .Restarting
	return true, true
}

keeper_on_driver_restarted :: proc "contextless" (k: ^Class_Ring_Keeper) -> bool {
	if k == nil || k.state != .Restarting {
		return false
	}
	k.generation += 1
	k.state = .Ready
	return true
}

// ============================================================================
// Driver Domain Frame Proxy (Linux guest <-> modus class protocol)
// ============================================================================

Proxy_Device_Class :: enum u8 {
	Wifi_Network = 1,
	Bluetooth    = 2,
	Usb_Host     = 3,
}

proxy_device_class_of_word :: proc "contextless" (word: u64) -> (c: Proxy_Device_Class, ok: bool) {
	return enum_word.member_of_word(Proxy_Device_Class, word)
}

Proxy_Frame_Header :: struct {
	class_word: u8,
	direction:  u8, // 1 = guest->host (RX), 2 = host->guest (TX)
	length:     u16,
	sequence:   u32,
}

proxy_frame_validate :: proc "contextless" (hdr: Proxy_Frame_Header, payload: []u8) -> bool {
	if _, ok := proxy_device_class_of_word(u64(hdr.class_word)); !ok {
		return false
	}
	if hdr.direction != 1 && hdr.direction != 2 {
		return false
	}
	if hdr.length == 0 || int(hdr.length) > MAX_PROXY_FRAME_BYTES || len(payload) != int(hdr.length) {
		return false
	}
	return true
}
