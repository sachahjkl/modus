// In-modus QUIC object-cache transport for the delegated disk_processes
// service (src/md/features/script_fonts.md).
//
// Opens a per-load scoped UDP datagram ring and region given by root on
// Load_Kind.Script_Fonts_Cache, waits for the network service to hold a bound
// IPv4 address (polling .Info while watching core_ring.commands for Cancel),
// drives dpc.Cache_Quic_Fetcher over UDP port 5010 (ALPN "modus-object-cache",
// pinned Ed25519 server public key), and releases all network handles as soon
// as the load ends or is cancelled.
package disk_processes_service

import dpc "internal:disk_processes/disk_processes_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:network"
import "modus:quic"
import "modus:random"
import "modus:system"

// Foreign bindings to the imported cryptography library module.
foreign _ {
	@(require_results)
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 ---
	hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 ---
	@(require_results)
	hkdf_sha256_expand :: proc "c" (key, info: ^string, length: value_kinds.Size_In_Bytes, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	header_protection_mask_with_aes_128 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
	@(require_results)
	header_protection_mask_with_chacha20 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) ---
}

// Format property: 2 KiB slot per datagram inside the 512 KiB datagram region.
CACHE_PLACE_SIZE :: 2048
// Plan value: 64 receive slots and 64 send slots in the datagram region.
CACHE_RECV_SLOTS :: 64
CACHE_SEND_FIRST :: CACHE_RECV_SLOTS
CACHE_SEND_SLOTS :: 64
CACHE_SEND_TAG :: u32(1000)
CACHE_INFO_TAG_BASE :: u32(100_000)
// Plan value: pause between .Info polls while waiting for on-demand DHCP bind.
CACHE_DHCP_POLL_MS :: u64(25)

Cache_Pending_Recv :: struct {
	place:          int,
	length:         u64,
	remote_address: u32,
}

Cache_Fetch_State :: struct {
	generator_ready:   bool,
	generator:         random.Generator,
	cryptography:      quic.Cryptography,
	net_open:          bool,
	ring_memory:       system.Handle,
	region_memory:     system.Handle,
	datagrams:         ring.Ring,
	region:            [^]u8,
	region_bytes:      u64,
	local_address:     u32,
	local_port:        u16,
	remote_address:    u32,
	remote_port:       u16,
	send_next:         int,
	send_in_use:       [CACHE_SEND_SLOTS]bool,
	pending_recv:      [CACHE_RECV_SLOTS]Cache_Pending_Recv,
	pending_recv_head: int,
	pending_recv_tail: int,
	pending_recv_len:  int,
	info_seq:          u32,
	fetcher:           dpc.Cache_Quic_Fetcher,
	frame0_start:      int,
	frame0_len:        int,
}

// Static BSS state so the ~1.3 MiB QUIC fetcher never lives on the stack.
cache_fetch: Cache_Fetch_State

cache_fetch_crypto_init :: proc "contextless" (ctx: ^system.Context) {
	cache_fetch.cryptography = {
		seal_with_aes_128_gcm                = seal_with_aes_128_gcm,
		open_with_aes_128_gcm                = open_with_aes_128_gcm,
		seal_with_chacha20_poly1305          = seal_with_chacha20_poly1305,
		open_with_chacha20_poly1305          = open_with_chacha20_poly1305,
		hkdf_sha256_extract                  = hkdf_sha256_extract,
		hkdf_sha256_expand                   = hkdf_sha256_expand,
		header_protection_mask_with_aes_128  = header_protection_mask_with_aes_128,
		header_protection_mask_with_chacha20 = header_protection_mask_with_chacha20,
		sha256                               = sha256,
		hmac_sha256                          = hmac_sha256,
		x25519                               = x25519,
		ed25519_public_key                   = ed25519_public_key,
		ed25519_sign                         = ed25519_sign,
		ed25519_verify                       = ed25519_verify,
	}
	cache_fetch.generator_ready = random.generator_from_context(&cache_fetch.generator, ctx)
}

@(private = "file")
cache_place :: proc "contextless" (place: int) -> []u8 {
	return cache_fetch.region[place * CACHE_PLACE_SIZE:][:CACHE_PLACE_SIZE]
}

cache_core_has_command :: proc "contextless" () -> bool {
	return core_ring.head != nil && ring.count(&core_ring.commands) > 0
}

@(private = "file")
cache_ring_send_cmd :: proc "contextless" (command: datagram.Command, tag: u32, values: [7]u64 = {}) -> bool {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for attempt := 0; attempt < 16; attempt += 1 {
		if cache_core_has_command() {
			return false
		}
		if system.send(&cache_fetch.datagrams.commands, record) {
			return true
		}
		wait := system.wait_begin()
		system.wait_room(&wait, &cache_fetch.datagrams.commands)
		system.wait_records(&wait, &core_ring.commands)
		_ = system.wait_end(&wait, system.time() + 10)
	}
	return false
}

@(private = "file")
cache_post_receive :: proc "contextless" (place: int) {
	_ = cache_ring_send_cmd(.Receive, u32(place), {0 = u64(place * CACHE_PLACE_SIZE), 1 = CACHE_PLACE_SIZE})
}

@(private = "file")
cache_note_completion :: proc "contextless" (record: ring.Record) {
	if record.tag >= CACHE_SEND_TAG && record.tag < CACHE_SEND_TAG + CACHE_SEND_SLOTS {
		cache_fetch.send_in_use[record.tag - CACHE_SEND_TAG] = false
		return
	}
	place := int(record.tag)
	if place < 0 || place >= CACHE_RECV_SLOTS {
		return
	}
	if record.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		cache_fetch.net_open = false
		return
	}
	if cache_fetch.pending_recv_len >= len(cache_fetch.pending_recv) {
		cache_post_receive(place)
		return
	}
	cache_fetch.pending_recv[cache_fetch.pending_recv_tail] = {
		place          = place,
		length         = record.values[1],
		remote_address = u32(record.values[2]),
	}
	cache_fetch.pending_recv_tail = (cache_fetch.pending_recv_tail + 1) % len(cache_fetch.pending_recv)
	cache_fetch.pending_recv_len += 1
}

@(private = "file")
cache_drain_completions :: proc "contextless" () {
	for _ in 0 ..< ring.CAPACITY {
		record, got := system.receive(&cache_fetch.datagrams.completions)
		if !got {
			break
		}
		cache_note_completion(record)
	}
}

@(private = "file")
cache_acquire_send_slot :: proc "contextless" () -> (slot_idx: int, ok: bool) {
	deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS
	for {
		if !cache_fetch.net_open || cache_core_has_command() {
			return 0, false
		}
		cache_drain_completions()
		if !cache_fetch.net_open {
			return 0, false
		}
		for step in 0 ..< CACHE_SEND_SLOTS {
			idx := (cache_fetch.send_next + step) % CACHE_SEND_SLOTS
			if !cache_fetch.send_in_use[idx] {
				cache_fetch.send_next = (idx + 1) % CACHE_SEND_SLOTS
				cache_fetch.send_in_use[idx] = true
				return idx, true
			}
		}
		if system.time() >= deadline {
			return 0, false
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &cache_fetch.datagrams.completions)
		system.wait_records(&wait, &core_ring.commands)
		if system.wait_spin(&wait) {
			continue
		}
		_ = system.wait_end(&wait, deadline)
	}
}

@(private = "file")
cache_transport_now_us :: proc "contextless" (_: rawptr) -> u64 {
	return system.time() * 1000 + 1
}

@(private = "file")
cache_transport_cancelled :: proc "contextless" (_: rawptr) -> bool {
	return cache_core_has_command()
}

@(private = "file")
cache_transport_send :: proc "contextless" (bytes: []u8, _: rawptr) -> bool {
	if !cache_fetch.net_open || len(bytes) == 0 || len(bytes) > datagram.DATA_LIMIT {
		return false
	}
	slot_idx, slot_ok := cache_acquire_send_slot()
	if !slot_ok {
		return false
	}
	place := CACHE_SEND_FIRST + slot_idx
	slot := cache_place(place)
	copy(slot[network.UDP_HEADER:], bytes)
	whole := network.udp_header_write(
		slot,
		cache_fetch.local_address,
		cache_fetch.remote_address,
		cache_fetch.local_port,
		cache_fetch.remote_port,
		len(bytes),
	)
	if whole <= 0 {
		cache_fetch.send_in_use[slot_idx] = false
		return false
	}
	if !cache_ring_send_cmd(.Send, CACHE_SEND_TAG + u32(slot_idx), {0 = u64(place * CACHE_PLACE_SIZE), 1 = u64(whole), 2 = u64(cache_fetch.remote_address)}) {
		cache_fetch.send_in_use[slot_idx] = false
		return false
	}
	return true
}

@(private = "file")
cache_transport_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, _: rawptr) -> (length: int, ok: bool) {
	if !cache_fetch.net_open {
		return 0, false
	}
	deadline_ms := (deadline_us + 999) / 1000
	for {
		if !cache_fetch.net_open || cache_core_has_command() {
			return 0, false
		}
		cache_drain_completions()
		if !cache_fetch.net_open {
			return 0, false
		}
		for cache_fetch.pending_recv_len > 0 {
			item := cache_fetch.pending_recv[cache_fetch.pending_recv_head]
			cache_fetch.pending_recv_head = (cache_fetch.pending_recv_head + 1) % len(cache_fetch.pending_recv)
			cache_fetch.pending_recv_len -= 1
			whole := cache_place(item.place)[:min(item.length, CACHE_PLACE_SIZE)]
			payload, valid := network.udp_data_read(whole, item.remote_address, cache_fetch.local_address, .Verify)
			if valid && len(payload) > 0 && len(payload) <= len(buffer) {
				copied := copy(buffer, payload)
				cache_post_receive(item.place)
				return copied, true
			}
			cache_post_receive(item.place)
		}
		if system.time() >= deadline_ms {
			return 0, false
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &cache_fetch.datagrams.completions)
		system.wait_records(&wait, &core_ring.commands)
		if system.wait_spin(&wait) {
			continue
		}
		_ = system.wait_end(&wait, deadline_ms)
	}
}

cache_fetch_release :: proc "contextless" () {
	// Never block on ring sends during load teardown or Cancel: drop the QUIC
	// state locally and release the endpoint handles immediately.
	cache_fetch.net_open = false
	dpc.cache_quic_fetcher_close(&cache_fetch.fetcher, false)
	if cache_fetch.datagrams.head != nil {
		system.ring_close(&cache_fetch.datagrams)
		cache_fetch.datagrams = {}
	}
	if cache_fetch.region != nil {
		system.memory_unmap(cache_fetch.region)
		cache_fetch.region = nil
	}
	if cache_fetch.ring_memory != 0 {
		system.close(cache_fetch.ring_memory)
		cache_fetch.ring_memory = 0
	}
	if cache_fetch.region_memory != 0 {
		system.close(cache_fetch.region_memory)
		cache_fetch.region_memory = 0
	}
	cache_fetch.net_open = false
	cache_fetch.region_bytes = 0
	cache_fetch.local_address = 0
	cache_fetch.local_port = 0
	cache_fetch.remote_address = 0
	cache_fetch.remote_port = 0
	cache_fetch.send_next = 0
	cache_fetch.send_in_use = {}
	cache_fetch.pending_recv_head = 0
	cache_fetch.pending_recv_tail = 0
	cache_fetch.pending_recv_len = 0
	cache_fetch.frame0_start = 0
	cache_fetch.frame0_len = 0
}

// cache_fetch_open opens the per-load datagram ring and region, waits for the
// network service to finish DHCP address binding, and initializes the QUIC
// fetcher pinned to server_key.
cache_fetch_open :: proc "contextless" (ring_handle, region_handle: system.Handle, server_key: [32]u8) -> bool {
	cache_fetch_release()
	if !cache_fetch.generator_ready || ring_handle == 0 || region_handle == 0 {
		return false
	}
	opened_ring, ring_status := system.ring_open(ring_handle)
	if ring_status != .Succeeded {
		return false
	}
	pages, size_status := system.memory_size(region_handle)
	if size_status != .Succeeded || pages * system.PAGE_SIZE < (CACHE_SEND_FIRST + CACHE_SEND_SLOTS) * CACHE_PLACE_SIZE {
		system.ring_close(&opened_ring)
		return false
	}
	addr, map_status := system.memory_map(region_handle, {.Write})
	if map_status != .Succeeded {
		system.ring_close(&opened_ring)
		return false
	}
	cache_fetch.ring_memory = ring_handle
	cache_fetch.region_memory = region_handle
	cache_fetch.datagrams = opened_ring
	cache_fetch.region = ([^]u8)(addr)
	cache_fetch.region_bytes = pages * system.PAGE_SIZE

	// Poll .Info until the network service has completed DHCP and link_up is set.
	deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS
	bound := false
	info: ring.Record
	for system.time() < deadline {
		if cache_core_has_command() {
			cache_fetch_release()
			return false
		}
		tag := CACHE_INFO_TAG_BASE + cache_fetch.info_seq
		cache_fetch.info_seq += 1
		if !cache_ring_send_cmd(.Info, tag) {
			cache_fetch_release()
			return false
		}
		got_info := false
		for system.time() < deadline {
			if cache_core_has_command() {
				cache_fetch_release()
				return false
			}
			if rec, got := system.receive(&cache_fetch.datagrams.completions); got && rec.tag == tag {
				info = rec
				got_info = rec.kind == u32(call_outcome.Call_Outcome.Succeeded)
				break
			}
			wait := system.wait_begin()
			system.wait_records(&wait, &cache_fetch.datagrams.completions)
			system.wait_records(&wait, &core_ring.commands)
			_ = system.wait_end(&wait, deadline)
		}
		if !got_info {
			cache_fetch_release()
			return false
		}
		if info.values[0] != 0 && info.values[5] != 0 {
			bound = true
			break
		}
		// DHCP is still binding on a newly started network service; pause briefly.
		wait := system.wait_begin()
		system.wait_records(&wait, &core_ring.commands)
		_ = system.wait_end(&wait, min(deadline, system.time() + CACHE_DHCP_POLL_MS))
	}
	if !bound {
		cache_fetch_release()
		return false
	}
	grant, grant_ok := datagram.grant_unpack(info.values[6])
	if !grant_ok || grant.tcp || grant.listen || grant.address == 0 || grant.port == 0 {
		cache_fetch_release()
		return false
	}
	cache_fetch.local_address = u32(info.values[0])
	cache_fetch.local_port = u16(info.values[1])
	cache_fetch.remote_address = grant.address
	cache_fetch.remote_port = grant.port
	for place in 0 ..< CACHE_RECV_SLOTS {
		cache_post_receive(place)
	}
	cache_fetch.net_open = true

	transport := dpc.Cache_Quic_Transport {
		send      = cache_transport_send,
		recv      = cache_transport_recv,
		now_us    = cache_transport_now_us,
		cancelled = cache_transport_cancelled,
	}
	if !dpc.cache_quic_fetcher_init(&cache_fetch.fetcher, server_key, &cache_fetch.cryptography, &cache_fetch.generator, transport) {
		cache_fetch_release()
		return false
	}
	return true
}

cache_fetch_frame :: proc "contextless" (hash: blake3.Hash, offset: u64) -> dpc.Cache_Frame_Answer {
	if !cache_fetch.net_open {
		return {kind = .Not_Configured}
	}
	answer := dpc.cache_quic_fetcher_get_frame(&cache_fetch.fetcher, hash, offset)
	if offset == 0 && answer.kind == .Ok && len(answer.payload) > 0 {
		base := uintptr(raw_data(cache_fetch.fetcher.response_buf[:]))
		ptr := uintptr(raw_data(answer.payload))
		if ptr >= base && ptr - base <= uintptr(len(cache_fetch.fetcher.response_buf)) {
			cache_fetch.frame0_start = int(ptr - base)
			cache_fetch.frame0_len = len(answer.payload)
		}
	}
	return answer
}

cache_frame0_payload :: proc "contextless" () -> []u8 {
	if cache_fetch.frame0_len <= 0 || cache_fetch.frame0_start + cache_fetch.frame0_len > len(cache_fetch.fetcher.response_buf) {
		return nil
	}
	return cache_fetch.fetcher.response_buf[cache_fetch.frame0_start:][:cache_fetch.frame0_len]
}
