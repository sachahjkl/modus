#+build !freestanding
#+build !modus
package isolated

import "core:testing"

// Connections for clients of another machine fill a service up to its
// reserve and the table up to their share, one past each is refused, and
// then a local caller still connects to that service and to the table.
@(test)
remote_clients_fill_their_share_and_a_local_caller_still_connects :: proc(t: ^testing.T) {
	TABLE :: 256
	SHARE :: 128
	// A service: the remote callers take every place but the reserve.
	service_count := 0
	for connection_place_open(true, service_count, service_count, service_count, TABLE, SHARE) {
		service_count += 1
	}
	testing.expect_value(t, service_count, SERVICE_CONNECTION_CAPACITY - SERVICE_CONNECTION_LOCAL_RESERVE)
	testing.expect(t, connection_place_open(false, service_count, service_count, service_count, TABLE, SHARE), "a local caller found the service full")
	// The local callers fill the reserve; one past the capacity is refused.
	local := service_count
	for connection_place_open(false, local, local, service_count, TABLE, SHARE) {
		local += 1
	}
	testing.expect_value(t, local, SERVICE_CONNECTION_CAPACITY)
	// The table: remote connections spread over many services stop at
	// their share, and a local caller still gets a place.
	testing.expect(t, !connection_place_open(true, 0, SHARE, SHARE, TABLE, SHARE), "a remote client passed its share of the table")
	testing.expect(t, connection_place_open(true, 0, SHARE - 1, SHARE - 1, TABLE, SHARE))
	testing.expect(t, connection_place_open(false, 0, SHARE, SHARE, TABLE, SHARE), "a local caller found the table full at the share of the remote clients")
	testing.expect(t, !connection_place_open(false, 0, TABLE, SHARE, TABLE, SHARE), "a full table took one more")
	testing.expect(t, !connection_place_open(false, SERVICE_CONNECTION_CAPACITY, 0, 0, TABLE, SHARE))
}
