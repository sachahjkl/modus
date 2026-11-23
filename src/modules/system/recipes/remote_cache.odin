// In-modus QUIC object cache client for the delegated recipes service
// (src/md/features/recipes.md, "The object cache and its protocol").
//
// Speaks ONE cache transport only — QUIC over UDP (default port 5010,
// ALPN = "modus-object-cache") via modus:quic over the scoped datagram
// endpoint granted to recipes by root. Never passed to builders or guests.
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/call_outcome"
import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:network"
import "modus:quic"
import "modus:random"
import "modus:system"

// Foreign bindings to the imported cryptography library module (exact contract
// used by remote and quic_echo).
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
REMOTE_CACHE_PLACE_SIZE :: 2048
// Plan value: 64 receive slots and 64 send slots in the datagram region.
REMOTE_CACHE_RECV_SLOTS :: 64
REMOTE_CACHE_SEND_FIRST :: REMOTE_CACHE_RECV_SLOTS
REMOTE_CACHE_SEND_SLOTS :: 64
REMOTE_CACHE_SEND_TAG :: u32(1000)
REMOTE_CACHE_INFO_TAG :: u32(100_000)

Remote_Cache_State :: struct {
	net_ready:      bool,
	datagrams:      ring.Ring,
	region:         [^]u8,
	region_bytes:   u64,
	local_address:  u32,
	local_port:     u16,
	remote_address: u32,
	remote_port:    u16,
	send_next:      int,
	generator:      random.Generator,
	cryptography:   quic.Cryptography,
	client:         recipes_core.Cache_Quic_Client,
	fetch_ctx:      recipes_core.Cache_Quic_Fetch_Context,
}

// Package-level BSS state so the ~2.3 MiB QUIC client never lives on the stack.
remote_cache: Remote_Cache_State

@(private = "file")
remote_cache_place :: proc "contextless" (place: int) -> []u8 {
	return remote_cache.region[place * REMOTE_CACHE_PLACE_SIZE:][:REMOTE_CACHE_PLACE_SIZE]
}

@(private = "file")
remote_cache_ring_send_cmd :: proc "contextless" (command: datagram.Command, tag: u32, values: [7]u64 = {}) -> bool {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for attempt := 0; attempt < 16; attempt += 1 {
		if system.send(&remote_cache.datagrams.commands, record) {
			return true
		}
		wait := system.wait_begin()
		system.wait_room(&wait, &remote_cache.datagrams.commands)
		_ = system.wait_end(&wait, system.time() + 10)
	}
	return false
}

@(private = "file")
remote_cache_post_receive :: proc "contextless" (place: int) {
	_ = remote_cache_ring_send_cmd(.Receive, u32(place), {0 = u64(place * REMOTE_CACHE_PLACE_SIZE), 1 = REMOTE_CACHE_PLACE_SIZE})
}

@(private = "file")
remote_cache_transport_now_us :: proc "contextless" (_: rawptr) -> u64 {
	return system.time() * 1000 + 1
}

@(private = "file")
remote_cache_transport_send :: proc "contextless" (bytes: []u8, _: rawptr) -> bool {
	if !remote_cache.net_ready || len(bytes) == 0 || len(bytes) > datagram.DATA_LIMIT {
		return false
	}
	place := REMOTE_CACHE_SEND_FIRST + remote_cache.send_next
	remote_cache.send_next = (remote_cache.send_next + 1) % REMOTE_CACHE_SEND_SLOTS
	slot := remote_cache_place(place)
	copy(slot[network.UDP_HEADER:], bytes)
	whole := network.udp_header_write(
		slot,
		remote_cache.local_address,
		remote_cache.remote_address,
		remote_cache.local_port,
		remote_cache.remote_port,
		len(bytes),
	)
	if whole <= 0 {
		return false
	}
	return remote_cache_ring_send_cmd(.Send, REMOTE_CACHE_SEND_TAG + u32(place), {0 = u64(place * REMOTE_CACHE_PLACE_SIZE), 1 = u64(whole), 2 = u64(remote_cache.remote_address)})
}

@(private = "file")
remote_cache_transport_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, _: rawptr) -> (length: int, ok: bool) {
	if !remote_cache.net_ready {
		return 0, false
	}
	deadline_ms := (deadline_us + 999) / 1000
	for {
		if record, got := system.receive(&remote_cache.datagrams.completions); got {
			if record.tag >= REMOTE_CACHE_SEND_TAG {
				continue
			}
			place := int(record.tag)
			if place < 0 || place >= REMOTE_CACHE_RECV_SLOTS {
				continue
			}
			if record.kind != u32(call_outcome.Call_Outcome.Succeeded) {
				remote_cache_post_receive(place)
				continue
			}
			whole := remote_cache_place(place)[:min(record.values[1], REMOTE_CACHE_PLACE_SIZE)]
			payload, valid := network.udp_data_read(whole, u32(record.values[2]), remote_cache.local_address, .Verify)
			if valid && len(payload) > 0 && len(payload) <= len(buffer) {
				copied := copy(buffer, payload)
				remote_cache_post_receive(place)
				return copied, true
			}
			remote_cache_post_receive(place)
			continue
		}
		if system.time() >= deadline_ms {
			return 0, false
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &remote_cache.datagrams.completions)
		if system.wait_spin(&wait) {
			continue
		}
		_ = system.wait_end(&wait, deadline_ms)
	}
}

@(private = "file")
remote_cache_ed25519_verify :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	pub := public_key
	sig := signature
	pub_str := string(pub[:])
	msg_str := string(message)
	sig_str := string(sig[:])
	err: errors.Error_Record
	outcome, _ := ed25519_verify(&pub_str, &msg_str, &sig_str, &err)
	return outcome == .Succeeded
}

// remote_cache_bind opens the scoped UDP datagram endpoint granted to recipes
// when present in ctx and prepares the QUIC cryptography table and PRNG.
remote_cache_bind :: proc "contextless" (ctx: ^system.Context) {
	remote_cache.cryptography = {
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
	if !random.generator_from_context(&remote_cache.generator, ctx) {
		return
	}
	ring_handle := ctx.handles[datagram.GRANT_RING]
	region_handle := ctx.handles[datagram.GRANT_REGION]
	if ring_handle == 0 || region_handle == 0 {
		return
	}
	opened_ring, ring_status := system.ring_open(ring_handle)
	if ring_status != .Ok {
		return
	}
	pages, size_status := system.memory_size(region_handle)
	if size_status != .Ok || pages * system.PAGE_SIZE < (REMOTE_CACHE_SEND_FIRST + REMOTE_CACHE_SEND_SLOTS) * REMOTE_CACHE_PLACE_SIZE {
		return
	}
	addr, map_status := system.memory_map(region_handle, {.Write})
	if map_status != .Ok {
		return
	}
	remote_cache.datagrams = opened_ring
	remote_cache.region = ([^]u8)(addr)
	remote_cache.region_bytes = pages * system.PAGE_SIZE

	if !remote_cache_ring_send_cmd(.Info, REMOTE_CACHE_INFO_TAG) {
		return
	}
	deadline := system.time() + 2000
	info_ok := false
	info: ring.Record
	for system.time() < deadline {
		if rec, got := system.receive(&remote_cache.datagrams.completions); got && rec.tag == REMOTE_CACHE_INFO_TAG {
			info = rec
			info_ok = rec.kind == u32(call_outcome.Call_Outcome.Succeeded)
			break
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &remote_cache.datagrams.completions)
		_ = system.wait_end(&wait, deadline)
	}
	if !info_ok {
		return
	}
	grant, grant_ok := datagram.grant_unpack(info.values[6])
	if !grant_ok || grant.tcp || grant.listen || grant.address == 0 || grant.port == 0 {
		return
	}
	remote_cache.local_address = u32(info.values[0])
	remote_cache.local_port = u16(info.values[1])
	remote_cache.remote_address = grant.address
	remote_cache.remote_port = grant.port
	for place in 0 ..< REMOTE_CACHE_RECV_SLOTS {
		remote_cache_post_receive(place)
	}
	remote_cache.net_ready = true
}

// configure_cache configures the remote QUIC object cache endpoint's pinned
// Ed25519 server public key and trusted realisation signer public key (each
// 64 lowercase hexadecimal digits).
@(export, link_name = "configure_cache")
configure_cache :: proc "c" (
	server_public_key_hex: ^system.Bytes_To_Read,
	trusted_signer_hex: ^system.Bytes_To_Read,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if !remote_cache.net_ready {
		return call_outcome.fail(error, .Operation_Unsupported, .No_Grant, .Connection)
	}
	if server_public_key_hex == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if trusted_signer_hex == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	server_count := intrinsics.volatile_load(&server_public_key_hex.count)
	signer_count := intrinsics.volatile_load(&trusted_signer_hex.count)
	if server_count != 64 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 1, i64(server_count), 64)
	}
	if signer_count != 64 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 2, i64(signer_count), 64)
	}
	server_digits: [64]u8
	signer_digits: [64]u8
	intrinsics.mem_copy_non_overlapping(&server_digits[0], server_public_key_hex.bytes, 64)
	intrinsics.mem_copy_non_overlapping(&signer_digits[0], trusted_signer_hex.bytes, 64)

	server_key, server_ok := pr.hash_of_hexadecimal(server_digits[:])
	if !server_ok || object_cache.hash_is_zero(server_key) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}
	signer_key, signer_ok := pr.hash_of_hexadecimal(signer_digits[:])
	if !signer_ok || object_cache.hash_is_zero(signer_key) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2)
	}

	recipes_core.cache_quic_client_close(&remote_cache.client)
	transport := recipes_core.Cache_Datagram_Transport {
		send   = remote_cache_transport_send,
		recv   = remote_cache_transport_recv,
		now_us = remote_cache_transport_now_us,
	}
	if !recipes_core.cache_quic_client_init(
		&remote_cache.client,
		server_key,
		&remote_cache.cryptography,
		&remote_cache.generator,
		transport,
	) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}
	remote_cache.fetch_ctx = {
		client           = &remote_cache.client,
		verify_signature = remote_cache_ed25519_verify,
	}
	service_state.remote_cache_fetch = recipes_core.cache_quic_fetch_realisation
	service_state.remote_cache_user = &remote_cache.fetch_ctx
	service_state.remote_cache_signers[0] = signer_key
	service_state.remote_cache_signer_count = 1
	system.log_fact(.Info, Remote_Cache_Configured{port = u64(remote_cache.remote_port), server_key = value_kinds.Hash_Field(server_key)})
	return .Succeeded, 1
}
