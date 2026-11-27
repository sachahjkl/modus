// In-modus QUIC object cache client for the delegated recipes service
// (src/md/features/recipes.md, "The object cache and its protocol").
//
// Speaks ONE cache transport only — QUIC over UDP (default port 5010,
// ALPN = "modus-object-cache") via modus:quic over the scoped datagram
// endpoint granted to recipes by root. Never passed to builders or guests.
//
// Cache endpoints and trusted signers are keyed strictly per principal
// (src/md/features/recipes.md): a configuration set by one principal never
// applies to another principal.
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/hardware_keys"
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
// Hang bound: wait for the network service to answer .Info at startup.
REMOTE_CACHE_INFO_WAIT_MS :: system.ANSWER_BOUND_MILLISECONDS
// Hang bound: wait for a free send slot when all 64 datagram send slots are in flight.
REMOTE_CACHE_SEND_SLOT_WAIT_MS :: system.ANSWER_BOUND_MILLISECONDS
// Policy bound matching Put_Ledger: distinct principals with cache configs.
REMOTE_CACHE_PRINCIPALS_MOST :: recipes_core.PUT_PRINCIPALS_MOST

Principal_Cache_Config :: struct {
	used:             bool,
	has_cache:        bool,
	has_publisher:    bool,
	principal:        u64,
	server_key:       [object_cache.PUBLIC_KEY_SIZE]u8,
	signer_key:       [object_cache.PUBLIC_KEY_SIZE]u8,
	publisher_seed:   [32]u8,
	publisher_public: [object_cache.PUBLIC_KEY_SIZE]u8,
}

Pending_Recv_Completion :: struct {
	place:          int,
	length:         u64,
	remote_address: u32,
}

Remote_Cache_State :: struct {
	generator_ready:   bool,
	net_ready:         bool,
	datagrams:         ring.Ring,
	region:            [^]u8,
	region_bytes:      u64,
	local_address:     u32,
	local_port:        u16,
	remote_address:    u32,
	remote_port:       u16,
	send_next:         int,
	send_in_use:       [REMOTE_CACHE_SEND_SLOTS]bool,
	pending_recv:      [REMOTE_CACHE_RECV_SLOTS]Pending_Recv_Completion,
	pending_recv_head: int,
	pending_recv_tail: int,
	pending_recv_len:  int,
	generator:         random.Generator,
	cryptography:      quic.Cryptography,
	client:            recipes_core.Cache_Quic_Client,
	fetch_ctx:         recipes_core.Cache_Quic_Fetch_Context,
	configs:           [REMOTE_CACHE_PRINCIPALS_MOST]Principal_Cache_Config,
}

// Package-level BSS state so the ~5.5 MiB QUIC client never lives on the stack.
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
remote_cache_note_completion :: proc "contextless" (record: ring.Record) {
	if record.tag >= REMOTE_CACHE_SEND_TAG && record.tag < REMOTE_CACHE_SEND_TAG + REMOTE_CACHE_SEND_SLOTS {
		remote_cache.send_in_use[record.tag - REMOTE_CACHE_SEND_TAG] = false
		return
	}
	place := int(record.tag)
	if place < 0 || place >= REMOTE_CACHE_RECV_SLOTS {
		return
	}
	if record.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		remote_cache_post_receive(place)
		return
	}
	if remote_cache.pending_recv_len >= len(remote_cache.pending_recv) {
		remote_cache_post_receive(place)
		return
	}
	remote_cache.pending_recv[remote_cache.pending_recv_tail] = {
		place          = place,
		length         = record.values[1],
		remote_address = u32(record.values[2]),
	}
	remote_cache.pending_recv_tail = (remote_cache.pending_recv_tail + 1) % len(remote_cache.pending_recv)
	remote_cache.pending_recv_len += 1
}

@(private = "file")
remote_cache_drain_completions :: proc "contextless" () {
	for _ in 0 ..< ring.CAPACITY {
		record, got := system.receive(&remote_cache.datagrams.completions)
		if !got {
			break
		}
		remote_cache_note_completion(record)
	}
}

@(private = "file")
remote_cache_acquire_send_slot :: proc "contextless" () -> (slot_idx: int, ok: bool) {
	deadline := system.time() + REMOTE_CACHE_SEND_SLOT_WAIT_MS
	for {
		remote_cache_drain_completions()
		for step in 0 ..< REMOTE_CACHE_SEND_SLOTS {
			idx := (remote_cache.send_next + step) % REMOTE_CACHE_SEND_SLOTS
			if !remote_cache.send_in_use[idx] {
				remote_cache.send_next = (idx + 1) % REMOTE_CACHE_SEND_SLOTS
				remote_cache.send_in_use[idx] = true
				return idx, true
			}
		}
		if system.time() >= deadline {
			return 0, false
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &remote_cache.datagrams.completions)
		if system.wait_spin(&wait) {
			continue
		}
		_ = system.wait_end(&wait, deadline)
	}
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
	slot_idx, slot_ok := remote_cache_acquire_send_slot()
	if !slot_ok {
		return false
	}
	place := REMOTE_CACHE_SEND_FIRST + slot_idx
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
		remote_cache.send_in_use[slot_idx] = false
		return false
	}
	if !remote_cache_ring_send_cmd(.Send, REMOTE_CACHE_SEND_TAG + u32(slot_idx), {0 = u64(place * REMOTE_CACHE_PLACE_SIZE), 1 = u64(whole), 2 = u64(remote_cache.remote_address)}) {
		remote_cache.send_in_use[slot_idx] = false
		return false
	}
	return true
}

@(private = "file")
remote_cache_transport_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, _: rawptr) -> (length: int, ok: bool) {
	if !remote_cache.net_ready {
		return 0, false
	}
	deadline_ms := (deadline_us + 999) / 1000
	for {
		remote_cache_drain_completions()
		for remote_cache.pending_recv_len > 0 {
			item := remote_cache.pending_recv[remote_cache.pending_recv_head]
			remote_cache.pending_recv_head = (remote_cache.pending_recv_head + 1) % len(remote_cache.pending_recv)
			remote_cache.pending_recv_len -= 1
			whole := remote_cache_place(item.place)[:min(item.length, REMOTE_CACHE_PLACE_SIZE)]
			payload, valid := network.udp_data_read(whole, item.remote_address, remote_cache.local_address, .Verify)
			if valid && len(payload) > 0 && len(payload) <= len(buffer) {
				copied := copy(buffer, payload)
				remote_cache_post_receive(item.place)
				return copied, true
			}
			remote_cache_post_receive(item.place)
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

// Live hardware-key verification gate for realisation signing.
realisation_hardware_key_gate: recipes_core.Realisation_Key_Gate

// remote_cache_issue_realisation_challenge issues a single-use challenge on
// realisation_hardware_key_gate requiring User_Present and User_Verified.
remote_cache_issue_realisation_challenge :: proc "contextless" (
	output_hash: blake3.Hash,
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
	scope_out: ^[recipes_core.REALISATION_SCOPE_BYTES]u8,
) -> (challenge: hardware_keys.Hardware_Key_Challenge, refusal: hardware_keys.Hardware_Key_Refusal) {
	return recipes_core.realisation_key_challenge_issue(&realisation_hardware_key_gate, output_hash, nonce, scope_out)
}

// remote_cache_verify_realisation_hardware_key consumes the pending single-use
// challenge and verifies a canonical hardware-key assertion bound to
// output_hash under .Sign_Realisation using the imported cryptography module's
// Ed25519 verifier.
remote_cache_verify_realisation_hardware_key :: proc "contextless" (
	output_hash: blake3.Hash,
	wire_assertion: []u8,
) -> hardware_keys.Hardware_Key_Refusal {
	return recipes_core.realisation_hardware_key_verify(
		&realisation_hardware_key_gate,
		output_hash,
		wire_assertion,
		remote_cache_ed25519_verify,
	)
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

@(private = "file")
remote_cache_ed25519_sign :: proc "contextless" (
	message: []u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	if out_signature == nil || user == nil {
		return false
	}
	seed := (^[32]u8)(user)
	secret_str := string(seed[:])
	msg_str := string(message)
	sig_slice := out_signature[:]
	err: errors.Error_Record
	outcome, written := ed25519_sign(&secret_str, &msg_str, &sig_slice, &err)
	return outcome == .Succeeded && written == object_cache.SIGNATURE_SIZE
}

@(private = "file")
remote_cache_derive_public :: proc "contextless" (seed: ^[32]u8) -> (pub: [object_cache.PUBLIC_KEY_SIZE]u8, ok: bool) {
	if seed == nil || object_cache.hash_is_zero(seed^) {
		return {}, false
	}
	secret_str := string(seed[:])
	pub_slice := pub[:]
	err: errors.Error_Record
	outcome, written := ed25519_public_key(&secret_str, &pub_slice, &err)
	if outcome != .Succeeded || written != object_cache.PUBLIC_KEY_SIZE || object_cache.hash_is_zero(pub) {
		return {}, false
	}
	return pub, true
}

@(private = "file")
remote_cache_hex_write :: proc "contextless" (dst: ^[64]u8, bytes: [32]u8) {
	hex := "0123456789abcdef"
	for value, index in bytes {
		dst[2 * index] = hex[value >> 4]
		dst[2 * index + 1] = hex[value & 0x0f]
	}
}

// publisher_key_object_name returns "publisher_key_<principal>": never 64 hex
// digits (so read_output and retention_collect never touch it) and never
// prefixed with "realisation_" (so retention_make_room never evicts it).
@(private = "file")
publisher_key_object_name :: proc "contextless" (principal: u64) -> (name: pr.Private_Object_Name) {
	pr.private_object_name_append(&name, "publisher_key_")
	pr.private_object_name_append_decimal(&name, principal)
	return name
}

@(private = "file")
remote_cache_load_publisher_from_store :: proc "contextless" (principal: u64, cfg: ^Principal_Cache_Config) -> bool {
	if cfg == nil || service_state.store.read == nil {
		return false
	}
	name := publisher_key_object_name(principal)
	seed_buf: [32]u8
	defer intrinsics.mem_zero_volatile(&seed_buf[0], len(seed_buf))
	bytes, status := pr.private_store_read(&service_state.store, pr.private_object_name_text(&name), seed_buf[:])
	if status != .Ok || len(bytes) != len(seed_buf) || object_cache.hash_is_zero(seed_buf) {
		return false
	}
	pub, pub_ok := remote_cache_derive_public(&seed_buf)
	if !pub_ok {
		return false
	}
	cfg.used = true
	cfg.principal = principal
	cfg.has_publisher = true
	cfg.publisher_seed = seed_buf
	cfg.publisher_public = pub
	return true
}

@(private = "file")
remote_cache_persist_publisher_to_store :: proc "contextless" (principal: u64, seed: ^[32]u8) -> bool {
	if service_state.store.write == nil {
		return true
	}
	name := publisher_key_object_name(principal)
	return pr.private_store_write(&service_state.store, pr.private_object_name_text(&name), seed[:]) == .Ok
}

@(private = "file")
remote_cache_ensure_client :: proc "contextless" (server_key: [object_cache.PUBLIC_KEY_SIZE]u8) -> bool {
	if !remote_cache.client.configured || remote_cache.client.server_public_key != server_key {
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
			return false
		}
	}
	return true
}

@(private = "file")
remote_cache_config_find :: proc "contextless" (principal: u64, create: bool) -> ^Principal_Cache_Config {
	for &cfg in remote_cache.configs {
		if cfg.used && cfg.principal == principal {
			return &cfg
		}
	}
	if !create {
		return nil
	}
	for &cfg in remote_cache.configs {
		if !cfg.used {
			return &cfg
		}
	}
	return nil
}

// remote_cache_prepare_for_principal binds the QUIC remote cache client and
// returns a Substitution_Policy carrying ONLY the trusted signer configured by
// principal. If principal has not configured a cache, remote_cache_fetch is
// cleared so another principal's cache or signer is never consulted.
@(private)
remote_cache_prepare_for_principal :: proc "contextless" (
	principal: u64,
	signer_slot: ^[1][object_cache.PUBLIC_KEY_SIZE]u8,
) -> (policy: object_cache.Substitution_Policy) {
	service_state.remote_cache_fetch = nil
	service_state.remote_cache_user = nil
	if !remote_cache.net_ready {
		return {}
	}
	cfg := remote_cache_config_find(principal, false)
	if cfg == nil || !cfg.has_cache {
		return {}
	}
	if !remote_cache_ensure_client(cfg.server_key) {
		return {}
	}
	remote_cache.fetch_ctx = {
		client           = &remote_cache.client,
		verify_signature = remote_cache_ed25519_verify,
	}
	service_state.remote_cache_fetch = recipes_core.cache_quic_fetch_realisation
	service_state.remote_cache_user = &remote_cache.fetch_ctx
	signer_slot[0] = cfg.signer_key
	return {trusted_signers = signer_slot[:]}
}

@(private)
remote_cache_clear_active :: proc "contextless" () {
	service_state.remote_cache_fetch = nil
	service_state.remote_cache_user = nil
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
	remote_cache.generator_ready = true
	ring_handle := ctx.handles[datagram.GRANT_RING]
	region_handle := ctx.handles[datagram.GRANT_REGION]
	if ring_handle == 0 || region_handle == 0 {
		return
	}
	opened_ring, ring_status := system.ring_open(ring_handle)
	if ring_status != .Succeeded {
		return
	}
	pages, size_status := system.memory_size(region_handle)
	if size_status != .Succeeded || pages * system.PAGE_SIZE < (REMOTE_CACHE_SEND_FIRST + REMOTE_CACHE_SEND_SLOTS) * REMOTE_CACHE_PLACE_SIZE {
		return
	}
	addr, map_status := system.memory_map(region_handle, {.Write})
	if map_status != .Succeeded {
		return
	}
	remote_cache.datagrams = opened_ring
	remote_cache.region = ([^]u8)(addr)
	remote_cache.region_bytes = pages * system.PAGE_SIZE

	if !remote_cache_ring_send_cmd(.Info, REMOTE_CACHE_INFO_TAG) {
		return
	}
	deadline := system.time() + REMOTE_CACHE_INFO_WAIT_MS
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

// configure_cache configures the caller principal's remote QUIC object cache
// pinned Ed25519 server public key and trusted realisation signer public key
// (each 64 lowercase hexadecimal digits). Scoped strictly to caller_principal().
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
	server_ptr := intrinsics.volatile_load(&server_public_key_hex.bytes)
	if server_ptr == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	signer_ptr := intrinsics.volatile_load(&trusted_signer_hex.bytes)
	if signer_ptr == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	server_digits: [64]u8
	signer_digits: [64]u8
	intrinsics.mem_copy_non_overlapping(&server_digits[0], server_ptr, 64)
	intrinsics.mem_copy_non_overlapping(&signer_digits[0], signer_ptr, 64)

	server_key, server_ok := pr.hash_of_hexadecimal(server_digits[:])
	if !server_ok || object_cache.hash_is_zero(server_key) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}
	signer_key, signer_ok := pr.hash_of_hexadecimal(signer_digits[:])
	if !signer_ok || object_cache.hash_is_zero(signer_key) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2)
	}

	principal := caller_principal()
	cfg := remote_cache_config_find(principal, true)
	if cfg == nil {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .Objects, 0, REMOTE_CACHE_PRINCIPALS_MOST, REMOTE_CACHE_PRINCIPALS_MOST)
	}
	cfg.used = true
	cfg.has_cache = true
	cfg.principal = principal
	cfg.server_key = server_key
	cfg.signer_key = signer_key
	system.log_fact(.Info, Remote_Cache_Configured{port = u64(remote_cache.remote_port), server_key = value_kinds.Hash_Field(server_key)})
	return .Succeeded, 1
}

// publisher_key returns the caller principal's 64-hex Ed25519 cache publisher
// public key. Loads a persisted seed from recipes's private store when present
// or generates and persists a fresh 32-byte seed; never exposes the seed.
@(export, link_name = "publisher_key")
publisher_key :: proc "c" (
	result: ^[]u8,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if len(result^) < 64 {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, 1, i64(len(result^)), 64)
	}
	principal := caller_principal()
	cfg := remote_cache_config_find(principal, true)
	if cfg == nil {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .Objects, 0, REMOTE_CACHE_PRINCIPALS_MOST, REMOTE_CACHE_PRINCIPALS_MOST)
	}
	if !cfg.has_publisher {
		if !remote_cache_load_publisher_from_store(principal, cfg) {
			if !remote_cache.generator_ready {
				return call_outcome.fail(error, .Wrong_State, .State, .Requests)
			}
			seed: [32]u8
			defer intrinsics.mem_zero_volatile(&seed[0], len(seed))
			if !random.fill_for_a_key(&remote_cache.generator, seed[:], random.seed_strength(&remote_cache.generator), error) {
				return .Wrong_State, 0
			}
			pub, pub_ok := remote_cache_derive_public(&seed)
			if !pub_ok {
				return call_outcome.fail(error, .Wrong_State, .Refused, .Requests)
			}
			if !remote_cache_persist_publisher_to_store(principal, &seed) {
				return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
			}
			cfg.used = true
			cfg.principal = principal
			cfg.has_publisher = true
			cfg.publisher_seed = seed
			cfg.publisher_public = pub
		}
	}
	digits: [64]u8
	remote_cache_hex_write(&digits, cfg.publisher_public)
	copy(result^[:64], digits[:])
	return .Succeeded, 64
}

// configure_publisher configures the caller principal's Ed25519 cache publisher
// key from a 64-hex non-zero seed, persists it in recipes's private store,
// zeroes temporary seed buffers, and returns only the 64-hex public key.
@(export, link_name = "configure_publisher")
configure_publisher :: proc "c" (
	seed_hex: ^system.Bytes_To_Read,
	result: ^[]u8,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if seed_hex == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	if len(result^) < 64 {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, 2, i64(len(result^)), 64)
	}
	seed_count := intrinsics.volatile_load(&seed_hex.count)
	if seed_count != 64 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 1, i64(seed_count), 64)
	}
	seed_ptr := intrinsics.volatile_load(&seed_hex.bytes)
	if seed_ptr == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	seed_digits: [64]u8
	defer intrinsics.mem_zero_volatile(&seed_digits[0], len(seed_digits))
	intrinsics.mem_copy_non_overlapping(&seed_digits[0], seed_ptr, 64)

	seed, seed_ok := pr.hash_of_hexadecimal(seed_digits[:])
	defer intrinsics.mem_zero_volatile(&seed[0], len(seed))
	if !seed_ok || object_cache.hash_is_zero(seed) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}
	pub, pub_ok := remote_cache_derive_public(&seed)
	if !pub_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}
	principal := caller_principal()
	cfg := remote_cache_config_find(principal, true)
	if cfg == nil {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Over_Limit, .Objects, 0, REMOTE_CACHE_PRINCIPALS_MOST, REMOTE_CACHE_PRINCIPALS_MOST)
	}
	if !remote_cache_persist_publisher_to_store(principal, &seed) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store)
	}
	cfg.used = true
	cfg.principal = principal
	cfg.has_publisher = true
	cfg.publisher_seed = seed
	cfg.publisher_public = pub

	digits: [64]u8
	remote_cache_hex_write(&digits, pub)
	copy(result^[:64], digits[:])
	return .Succeeded, 64
}

// publish uploads a locally realised recipe's output closure bottom-up and its
// signed Realisation_Record to the caller principal's configured QUIC object
// cache, returning one Publish_Row summary.
@(export, link_name = "publish")
publish :: proc "c" (
	recipe_hash_hex: ^system.Bytes_To_Read,
	result: ^[]pr.Publish_Row,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := caller_check(true, error); !ok {
		return failure, 0
	}
	if !remote_cache.net_ready {
		return call_outcome.fail(error, .Operation_Unsupported, .No_Grant, .Connection)
	}
	if recipe_hash_hex == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	if len(result^) < 1 {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Records, 2, i64(len(result^)), 1)
	}
	hash_count := intrinsics.volatile_load(&recipe_hash_hex.count)
	if hash_count != 64 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 1, i64(hash_count), 64)
	}
	hash_ptr := intrinsics.volatile_load(&recipe_hash_hex.bytes)
	if hash_ptr == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	hash_digits: [64]u8
	intrinsics.mem_copy_non_overlapping(&hash_digits[0], hash_ptr, 64)
	recipe_hash, hash_ok := pr.hash_of_hexadecimal(hash_digits[:])
	if !hash_ok || object_cache.hash_is_zero(recipe_hash) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1)
	}

	principal := caller_principal()
	cfg := remote_cache_config_find(principal, false)
	if cfg == nil || !cfg.has_cache {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	if !cfg.has_publisher {
		if !remote_cache_load_publisher_from_store(principal, cfg) {
			return call_outcome.fail(error, .Wrong_State, .State, .Requests)
		}
	}
	if !remote_cache_ensure_client(cfg.server_key) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Connection)
	}

	stats, pub_refusal, server_status, client_err := recipes_core.cache_quic_publish_realisation(
		&remote_cache.client,
		&service_state,
		recipe_hash,
		cfg.publisher_public,
		remote_cache_ed25519_sign,
		&cfg.publisher_seed,
	)
	if pub_refusal != .None || client_err != .None || server_status != .Ok {
		refusal := pub_refusal != .None ? pub_refusal : pr.Recipe_Refusal.Malformed_Output
		if error != nil {
			error^ = recipes_core.recipe_refusal_record(refusal, 1, 0)
		}
		return recipes_core.recipe_refusal_outcome(refusal), 0
	}

	system.log_fact(.Info, Remote_Cache_Published{
		recipe_hash      = value_kinds.Hash_Field(stats.recipe_hash),
		output_hash      = value_kinds.Hash_Field(stats.output_hash),
		objects_uploaded = stats.objects_uploaded,
		objects_skipped  = stats.objects_skipped,
		bytes_uploaded   = stats.bytes_uploaded,
	})
	result[0] = {
		recipe_hash       = value_kinds.Hash_Field(stats.recipe_hash),
		output_hash       = value_kinds.Hash_Field(stats.output_hash),
		signer_public_key = value_kinds.Hash_Field(stats.signer_public_key),
		objects_uploaded  = stats.objects_uploaded,
		objects_skipped   = stats.objects_skipped,
		bytes_uploaded    = stats.bytes_uploaded,
	}
	return .Succeeded, 1
}
