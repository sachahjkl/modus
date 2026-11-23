package cache_server

import "core:net"
import "core:sys/linux"

// status_send_once sends with one call of the system, so the timeout of the
// socket bounds it. net.send_tcp calls the system again after a partial
// send, each time with the whole timeout, which a reader that takes one byte
// at a time stretches past any deadline.
status_send_once :: proc(socket: net.TCP_Socket, data: []u8) -> (count: int, failed: bool) {
	result, errno := linux.send(linux.Fd(socket), data, {.NOSIGNAL})
	if errno == .NONE {
		return result, false
	}
	if errno == .EAGAIN || errno == .EINTR {
		return 0, false
	}
	return 0, true
}

// status_reset_on_close makes the close of the socket a reset: the system
// drops what it still holds for the client in place of sending it after the
// close. An answer cut at its deadline must not leave megabytes queued for
// a reader that takes them at its own pace. The option of core:net passes a
// time value, not the record of SO_LINGER, so the call is made here.
status_reset_on_close :: proc(socket: net.TCP_Socket) {
	Linger :: struct {
		on:      i32,
		seconds: i32,
	}
	value := Linger{on = 1, seconds = 0}
	_ = linux.setsockopt(linux.Fd(socket), linux.SOL_SOCKET, linux.Socket_Option.LINGER, &value)
}
