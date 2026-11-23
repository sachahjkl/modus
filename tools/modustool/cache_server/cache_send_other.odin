#+build !linux
package cache_server

import "core:net"

// status_send_once sends through net.send_tcp, which calls the system again
// after a partial send: on this host the deadline of a connection bounds
// each call, not the whole write.
status_send_once :: proc(socket: net.TCP_Socket, data: []u8) -> (count: int, failed: bool) {
	written, send_error := net.send_tcp(socket, data)
	if send_error == .None || send_error == .Timeout || send_error == .Would_Block || send_error == .Interrupted {
		return written, false
	}
	return written, true
}

// status_reset_on_close does nothing on this host: the system sends what it
// still holds after the close.
status_reset_on_close :: proc(socket: net.TCP_Socket) {
}
