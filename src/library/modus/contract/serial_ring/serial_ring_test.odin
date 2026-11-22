#+build !freestanding
package serial_ring

import "core:testing"

@(test)
serial_whole_line_ring_and_endpoint_dequeue :: proc(t: ^testing.T) {
	// Whole-line serial ring refuses partial tear when full.
	r: Flood_Serial_Ring
	chunk: [2048]u8
	for i in 0 ..< len(chunk) { chunk[i] = 'A' }
	testing.expect(t, serial_ring_write_line(&r, chunk[:]))
	testing.expect(t, serial_ring_write_line(&r, chunk[:]))
	testing.expect(t, !serial_ring_write_line(&r, chunk[:10]))
	testing.expect_value(t, r.dropped_lines, u64(1))
	out: [64]u8
	testing.expect_value(t, serial_ring_drain(&r, out[:]), 64)
	testing.expect_value(t, out[0], u8('A'))

	// Per-endpoint RX queue supports enqueue, dequeue, owner check, and unregister.
	rx: Endpoint_Rx_Table
	testing.expect(t, endpoint_rx_register(&rx, owner_id = 10, port = 80))
	testing.expect(t, !endpoint_rx_register(&rx, owner_id = 99, port = 80)) // Different owner refused.
	for _ in 0 ..< MAX_PKTS_PER_ENDPOINT {
		testing.expect(t, endpoint_rx_enqueue(&rx, 80))
	}
	testing.expect(t, !endpoint_rx_enqueue(&rx, 80))
	testing.expect(t, !endpoint_rx_dequeue(&rx, 99, 80)) // Wrong owner cannot dequeue.
	testing.expect(t, endpoint_rx_dequeue(&rx, 10, 80))
	testing.expect(t, endpoint_rx_enqueue(&rx, 80)) // Room freed!
	testing.expect(t, endpoint_rx_unregister(&rx, 10, 80))
}
