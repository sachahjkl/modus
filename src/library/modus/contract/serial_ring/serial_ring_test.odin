#+build !freestanding
package serial_ring

import "core:testing"

@(test)
serial_flood_silent_disk_memory_copy_endpoint_rx_and_tpm_session :: proc(t: ^testing.T) {
	// Serial flood ring keeps full 4096 bytes and counts exact overflow.
	r: Flood_Serial_Ring
	chunk: [2048]u8
	for i in 0 ..< len(chunk) {
		chunk[i] = 'A'
	}
	testing.expect_value(t, serial_ring_write(&r, chunk[:]), 2048)
	testing.expect_value(t, serial_ring_write(&r, chunk[:]), 2048)
	testing.expect_value(t, serial_ring_write(&r, chunk[:10]), 0)
	testing.expect_value(t, r.dropped, u64(10))
	out: [64]u8
	testing.expect_value(t, serial_ring_drain(&r, out[:]), 64)
	testing.expect_value(t, out[0], u8('A'))

	// Silent data disk watchdog times out without blocking CPU.
	req := Disk_Request_Slot{in_flight = true, request_id = 5, deadline_ms = 5_000}
	testing.expect(t, !disk_check_timed_out(&req, 4_999))
	testing.expect(t, disk_check_timed_out(&req, 5_000))
	testing.expect(t, !req.in_flight)

	// Memory_Copy bounds.
	testing.expect(t, memory_copy_out_valid(4096, 1024, 512, 512))
	testing.expect(t, !memory_copy_out_valid(4096, 4000, 512, 512))

	// Per-endpoint RX queue isolation.
	rx: Endpoint_Rx_Table
	rx.active[0] = true; rx.endpoint_ports[0] = 80
	rx.active[1] = true; rx.endpoint_ports[1] = 443
	for _ in 0 ..< MAX_PKTS_PER_ENDPOINT {
		testing.expect(t, endpoint_rx_enqueue(&rx, 80))
	}
	testing.expect(t, !endpoint_rx_enqueue(&rx, 80)) // Port 80 full
	testing.expect(t, endpoint_rx_enqueue(&rx, 443)) // Port 443 completely unaffected!

	// TPM lockout state & encrypted session round trip.
	testing.expect_value(t, tpm_lockout_classify(0, 3), Tpm_Lockout_State.Ready)
	testing.expect_value(t, tpm_lockout_classify(2, 3), Tpm_Lockout_State.Warning_Count)
	testing.expect_value(t, tpm_lockout_classify(3, 3), Tpm_Lockout_State.Locked_Out)
	sk, nc, nt: [32]u8
	sk[0] = 1; nc[0] = 2; nt[0] = 3
	secret := [10]u8{'p', 'a', 's', 's', 'p', 'h', 'r', 'a', 's', 'e'}
	orig := secret
	tpm_session_xor_parameter(sk, nc, nt, secret[:])
	testing.expect(t, secret != orig)
	tpm_session_xor_parameter(sk, nc, nt, secret[:])
	testing.expect(t, secret == orig)
}
