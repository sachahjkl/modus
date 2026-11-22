// Pure freestanding low-level kernel/driver resilience contracts:
//   - Flood_Serial_Ring: atomic SPSC serial line ring that drops whole lines
//     when full so partial lines are never torn.
//   - Silent_Disk_Watchdog: non-blocking timeout detector so a silent data disk
//     never freezes any processor.
//   - Memory_Copy_Range: zero-map kernel memory-object copy-out validator.
//   - Endpoint_Rx_Table: per-endpoint isolated receive queue with enqueue,
//     dequeue, and owner-bound registration/unregistration.
package serial_ring

import "base:intrinsics"

SERIAL_RING_CAPACITY :: 4096

Flood_Serial_Ring :: struct {
	buf:           [SERIAL_RING_CAPACITY]u8,
	head:          u32,
	tail:          u32,
	dropped_lines: u64,
}

serial_ring_used :: proc "contextless" (r: ^Flood_Serial_Ring) -> u32 {
	if r == nil {
		return 0
	}
	h := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	t := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	return h - t
}

// serial_ring_write_line atomically enqueues an entire line or drops the whole
// line when space is insufficient so lines are never torn mid-record.
serial_ring_write_line :: proc "contextless" (r: ^Flood_Serial_Ring, line: []u8) -> bool {
	if r == nil || len(line) == 0 || len(line) > SERIAL_RING_CAPACITY {
		return false
	}
	h := intrinsics.atomic_load_explicit(&r.head, .Relaxed)
	t := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	free_bytes := SERIAL_RING_CAPACITY - int(h - t)
	if len(line) > free_bytes {
		r.dropped_lines += 1
		return false
	}
	for b in line {
		r.buf[h % SERIAL_RING_CAPACITY] = b
		h += 1
	}
	intrinsics.atomic_store_explicit(&r.head, h, .Release)
	return true
}

serial_ring_drain :: proc "contextless" (r: ^Flood_Serial_Ring, out: []u8) -> int {
	if r == nil || len(out) == 0 {
		return 0
	}
	h := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	t := intrinsics.atomic_load_explicit(&r.tail, .Relaxed)
	n := 0
	for n < len(out) && t != h {
		out[n] = r.buf[t % SERIAL_RING_CAPACITY]
		t += 1
		n += 1
	}
	intrinsics.atomic_store_explicit(&r.tail, t, .Release)
	return n
}

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
		return true
	}
	return false
}

memory_copy_out_valid :: proc "contextless" (object_bytes, src_offset, length, dst_capacity: u64) -> bool {
	if length == 0 || length > dst_capacity {
		return false
	}
	if src_offset > object_bytes || length > object_bytes - src_offset {
		return false
	}
	return true
}

MAX_ENDPOINTS :: 16
MAX_PKTS_PER_ENDPOINT :: 8

Endpoint_Rx_Table :: struct {
	endpoint_ports: [MAX_ENDPOINTS]u16,
	owner_ids:      [MAX_ENDPOINTS]u64,
	active:         [MAX_ENDPOINTS]bool,
	queued:         [MAX_ENDPOINTS]u8,
	dropped:        [MAX_ENDPOINTS]u64,
}

endpoint_rx_register :: proc "contextless" (tbl: ^Endpoint_Rx_Table, owner_id: u64, port: u16) -> bool {
	if tbl == nil || owner_id == 0 || port == 0 {
		return false
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if tbl.active[i] && tbl.endpoint_ports[i] == port {
			return tbl.owner_ids[i] == owner_id
		}
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if !tbl.active[i] {
			tbl.active[i] = true
			tbl.endpoint_ports[i] = port
			tbl.owner_ids[i] = owner_id
			tbl.queued[i] = 0
			tbl.dropped[i] = 0
			return true
		}
	}
	return false
}

endpoint_rx_unregister :: proc "contextless" (tbl: ^Endpoint_Rx_Table, owner_id: u64, port: u16) -> bool {
	if tbl == nil || owner_id == 0 || port == 0 {
		return false
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if tbl.active[i] && tbl.endpoint_ports[i] == port && tbl.owner_ids[i] == owner_id {
			tbl.active[i] = false
			tbl.endpoint_ports[i] = 0
			tbl.owner_ids[i] = 0
			tbl.queued[i] = 0
			return true
		}
	}
	return false
}

endpoint_rx_enqueue :: proc "contextless" (tbl: ^Endpoint_Rx_Table, port: u16) -> bool {
	if tbl == nil || port == 0 {
		return false
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if tbl.active[i] && tbl.endpoint_ports[i] == port {
			if tbl.queued[i] >= MAX_PKTS_PER_ENDPOINT {
				tbl.dropped[i] += 1
				return false
			}
			tbl.queued[i] += 1
			return true
		}
	}
	return false
}

endpoint_rx_dequeue :: proc "contextless" (tbl: ^Endpoint_Rx_Table, owner_id: u64, port: u16) -> bool {
	if tbl == nil || owner_id == 0 || port == 0 {
		return false
	}
	for i in 0 ..< MAX_ENDPOINTS {
		if tbl.active[i] && tbl.endpoint_ports[i] == port && tbl.owner_ids[i] == owner_id {
			if tbl.queued[i] == 0 {
				return false
			}
			tbl.queued[i] -= 1
			return true
		}
	}
	return false
}
