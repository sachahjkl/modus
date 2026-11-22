#+build !freestanding
package serial_ring

import "core:testing"

@(test)
serial_whole_line_ring_endpoint_dequeue_and_direction_separated_session :: proc(t: ^testing.T) {
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

	// Command vs Response direction separation produces distinct ciphertexts!
	sk, nc, nt: [32]u8
	sk[0] = 1; nc[0] = 2; nt[0] = 3
	cmd_buf := [10]u8{'p', 'a', 's', 's', 'p', 'h', 'r', 'a', 's', 'e'}
	rsp_buf := cmd_buf
	session_xor_mask(.Command, sk, nc, nt, cmd_buf[:])
	session_xor_mask(.Response, sk, nc, nt, rsp_buf[:])
	testing.expect(t, cmd_buf != rsp_buf)
}
