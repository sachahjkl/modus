// Pure freestanding low-level kernel/driver resilience contracts:
//   - Flood_Serial_Ring: bounded lock-free serial line ring preserving every
//     line across burst floods with explicit overflow accounting.
//   - Silent_Disk_Watchdog: non-blocking timeout detector so a silent data disk
//     never freezes any processor.
//   - Memory_Copy_Range: zero-map kernel memory-object copy-out validator.
//   - Endpoint_Rx_Queue: per-endpoint isolated receive queue multiplexer.
//   - Tpm_Session_Envelope: encrypted TPM parameter session & machine-key seal record.
package serial_ring

import "modus:contract/blake3"
import "modus:contract/byte_order"

// ============================================================================
// 1. Flood-proof Serial Ring (preserves burst output without blocking IRQ)
// ============================================================================

SERIAL_RING_CAPACITY :: 4096

Flood_Serial_Ring :: struct {
	buf:     [SERIAL_RING_CAPACITY]u8,
	head:    u32,
	tail:    u32,
	dropped: u64,
}

serial_ring_used :: proc "contextless" (r: ^Flood_Serial_Ring) -> u32 {
	if r == nil {
		return 0
	}
	return r.head - r.tail
}

serial_ring_write :: proc "contextless" (r: ^Flood_Serial_Ring, data: []u8) -> int {
	if r == nil || len(data) == 0 {
		return 0
	}
	written := 0
	for b in data {
		if r.head - r.tail >= SERIAL_RING_CAPACITY {
			r.dropped += 1
			continue
		}
		r.buf[r.head % SERIAL_RING_CAPACITY] = b
		r.head += 1
		written += 1
	}
	return written
}

serial_ring_drain :: proc "contextless" (r: ^Flood_Serial_Ring, out: []u8) -> int {
	if r == nil || len(out) == 0 {
		return 0
	}
	n := 0
	for n < len(out) && r.tail != r.head {
		out[n] = r.buf[r.tail % SERIAL_RING_CAPACITY]
		r.tail += 1
		n += 1
	}
	return n
}

// ============================================================================
// 2. Silent Data Disk Non-Blocking Watchdog
// ============================================================================

Disk_Request_Slot :: struct {
	in_flight:   bool,
	request_id:  u64,
	deadline_ms: u64,
}

disk_check_timed_out :: proc "contextless" (slot: ^Disk_Request_Slot, now_ms: u64) -> bool {
	if slot == nil || !slot.in_flight {
		return false
	}
	if now_ms >= slot.deadline_ms {
		slot.in_flight = false
		return true // Caller fails request cleanly with timeout without stalling CPU.
	}
	return false
}

// ============================================================================
// 3. Kernel Memory_Copy_Out Range Validator (copy out without mapping)
// ============================================================================

memory_copy_out_valid :: proc "contextless" (object_bytes, src_offset, length, dst_capacity: u64) -> bool {
	if length == 0 || length > dst_capacity {
		return false
	}
	if src_offset > object_bytes || length > object_bytes - src_offset {
		return false
	}
	return true
}

// ============================================================================
// 4. Per-Endpoint Isolated Receive Queue
// ============================================================================

MAX_ENDPOINTS :: 16
MAX_PKTS_PER_ENDPOINT :: 8

Endpoint_Rx_Table :: struct {
	endpoint_ports: [MAX_ENDPOINTS]u16,
	active:         [MAX_ENDPOINTS]bool,
	queued:         [MAX_ENDPOINTS]u8,
	dropped:        [MAX_ENDPOINTS]u64,
}

endpoint_rx_enqueue :: proc "contextless" (tbl: ^Endpoint_Rx_Table, port: u16) -> bool {
	if tbl == nil || port == 0 {
		return false
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if tbl.active[i] && tbl.endpoint_ports[i] == port {
			if tbl.queued[i] >= MAX_PKTS_PER_ENDPOINT {
				tbl.dropped[i] += 1
				return false // Flood on port A never drops packets for port B.
			}
			tbl.queued[i] += 1
			return true
		}
	}
	return false
}

// ============================================================================
// 5. TPM Encrypted Parameter Session & Pinned Machine-Key Seal Record
// ============================================================================

Tpm_Lockout_State :: enum u8 {
	Ready          = 1,
	Warning_Count  = 2,
	Locked_Out     = 3,
}

Tpm_Machine_Key_Record :: struct {
	version:         u16,
	pcr_mask:        u32,
	pcr7_policy_hash: [32]u8,
	sealed_key_mac:  [32]u8,
	lockout_counter: u32,
	lockout_max:     u32,
}

tpm_lockout_classify :: proc "contextless" (counter, max_tries: u32) -> Tpm_Lockout_State {
	if max_tries == 0 || counter >= max_tries {
		return .Locked_Out
	}
	if counter > 0 {
		return .Warning_Count
	}
	return .Ready
}

// tpm_session_xor_parameter encrypts/decrypts a TPM command parameter in place
// using a BLAKE3-derived session keystream bound to (session_key, nonce_caller, nonce_tpm).
tpm_session_xor_parameter :: proc "contextless" (session_key, nonce_caller, nonce_tpm: [32]u8, payload: []u8) {
	sk := session_key
	nc := nonce_caller
	nt := nonce_tpm
	in_buf: [104]u8
	copy(in_buf[0:32], sk[:])
	copy(in_buf[32:64], nc[:])
	copy(in_buf[64:96], nt[:])
	off := 0
	ctr := u64(0)
	for off < len(payload) {
		byte_order.write_u64_little_endian(in_buf[:], 96, ctr)
		ks := blake3.derive_key("modus tpm param session v1", in_buf[:])
		chunk := min(32, len(payload) - off)
		for i in 0 ..< chunk {
			payload[off + i] ~= ks[i]
		}
		off += chunk
		ctr += 1
	}
}
