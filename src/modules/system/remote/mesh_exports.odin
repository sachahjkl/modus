// Described exports of the remote service for live multi-machine mesh control
// (src/md/features/several_machines.md): pairing by code, paired machine
// grants, outbound QUIC links, object-by-hash exchange, remote role call
// dispatch, multi-page store exchange, and end-to-end sealed NAT relay
// envelopes.
//
// Every export requires a caller that acts for its principal
// (isolated.CALLER_ACTS_FOR_PRINCIPAL), validates all arguments at the border,
// never blocks the service loop, and writes a complete error record on each
// refusal.
package remote_service

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "modus:quic_server"
import "modus:system"

// Aggregate mesh counters returned by mesh_status().
Mesh_Status :: struct {
	paired_machines:  i64,
	links_up:         i64,
	objects_stored:   i64,
	exchanged_stores: i64,
	relay_routes:     i64,
	role_calls_served: i64,
}

// Exchanged store state returned by mesh_store_info().
Mesh_Store_Info :: struct {
	entry_count:      i64,
	conflict_count:   i64,
	tree_hash:        value_kinds.Hash_Field,
	common_tree_hash: value_kinds.Hash_Field,
}

// Plan value: maximum per-call byte size staged by mesh_object_put when
// publishing multi-chunk objects (> 16 KiB) from a console or test caller.
MESH_PUBLISH_STAGING_LIMIT :: 48 * 1024
// Plan value: maximum repetition count accepted per mesh_object_put call.
MESH_PUBLISH_REPEAT_LIMIT :: 4096
@(private = "file")
mesh_publish_staging: [MESH_PUBLISH_STAGING_LIMIT]u8

// Format property: staging buffer for reading back a single role or relay
// request result in mesh_request_poll.
@(private = "file")
mesh_poll_staging: [machine_wire.RELAY_SEALED_LIMIT]u8

@(private = "file")
mesh_caller_check :: proc "contextless" (error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome, ok: bool) {
	caller := system.service_caller()
	if caller == nil {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Connection)
		return failure, false
	}
	if caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
		return failure, false
	}
	// remote is machine-scoped with a single principal-0 mesh peer; secondary
	// principals cannot read or alter principal 0's paired machines, stores,
	// or relay keys.
	if isolated.caller_principal(caller.grant) != 0 {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Principals)
		return failure, false
	}
	if !mesh.has_identity {
		failure, _ = call_outcome.fail(error, .Wrong_State, .State, .None)
		return failure, false
	}
	return .Succeeded, true
}

@(private = "file")
hex_nibble :: proc "contextless" (ch: u8) -> (value: u8, ok: bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}

@(private = "file")
hex_decode_exact :: proc "contextless" (text: ^string, out: []u8, argument: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, ok: bool) {
	if text == nil {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, argument)
		return outcome, false
	}
	raw := text^
	if len(raw) != len(out) * 2 {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, argument, i64(len(raw)), i64(len(out) * 2))
		return outcome, false
	}
	for index in 0 ..< len(out) {
		hi, hi_ok := hex_nibble(raw[2 * index])
		lo, lo_ok := hex_nibble(raw[2 * index + 1])
		if !hi_ok || !lo_ok {
			outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
			return outcome, false
		}
		out[index] = (hi << 4) | lo
	}
	return .Succeeded, true
}

@(private = "file")
ipv4_parse :: proc "contextless" (text: ^string, argument: i64, error: ^errors.Error_Record) -> (address: u32, outcome: call_outcome.Call_Outcome, ok: bool) {
	if text == nil {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, argument)
		return 0, outcome, false
	}
	raw := text^
	if len(raw) == 0 || len(raw) > 15 {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
		return 0, outcome, false
	}
	octets: [4]u32
	part := 0
	digits := 0
	value: u32 = 0
	for index in 0 ..< len(raw) {
		ch := raw[index]
		if ch == '.' {
			if digits == 0 || part >= 3 {
				outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
				return 0, outcome, false
			}
			octets[part] = value
			part += 1
			digits = 0
			value = 0
			continue
		}
		if ch < '0' || ch > '9' {
			outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
			return 0, outcome, false
		}
		value = value * 10 + u32(ch - '0')
		digits += 1
		if digits > 3 || value > 255 {
			outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
			return 0, outcome, false
		}
	}
	if part != 3 || digits == 0 {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
		return 0, outcome, false
	}
	octets[3] = value
	packed := (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
	if packed == 0 {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument)
		return 0, outcome, false
	}
	return packed, .Succeeded, true
}

@(private = "file")
role_set_of_word :: proc "contextless" (word: u64) -> (roles: machine_wire.Role_Set, ok: bool) {
	known: machine_wire.Role_Set
	for role in role_contract.Role {
		if role != .None {
			known += {role}
		}
	}
	if word & ~transmute(u64)known != 0 {
		return {}, false
	}
	return transmute(machine_wire.Role_Set)word, true
}

@(private = "file")
store_id_of_name :: proc "contextless" (name: ^string, argument: i64, error: ^errors.Error_Record) -> (id: blake3.Hash, outcome: call_outcome.Call_Outcome, ok: bool) {
	if name == nil {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, argument)
		return {}, outcome, false
	}
	raw := name^
	if len(raw) == 0 || len(raw) > 255 {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, argument, i64(len(raw)), 255)
		return {}, outcome, false
	}
	return blake3.hash(transmute([]u8)raw), .Succeeded, true
}

// mesh_identity returns the 64-character lowercase hexadecimal public machine
// identity key of this remote service instance.
//
// - **result**: output buffer receiving the 64 hexadecimal characters.
//
// Errors: `No_Grant` when the caller does not act for its principal.
@(export, link_name = "mesh_identity")
mesh_identity_export :: proc "c" (result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	text: [64]u8
	hex := quic_server.hex_text(text[:], mesh.identity.public_key[:])
	copy(result^, hex)
	return .Succeeded, i64(len(hex))
}

// mesh_status writes aggregate counters for the live mesh peer state into
// result.
//
// - **result**: record holding paired machine, link, object, store, relay
//   route, and remote role call counts.
//
// Errors: `No_Grant` when the caller does not act for its principal;
// `Bad_Address` when result is nil.
@(export, link_name = "mesh_status")
mesh_status_export :: proc "c" (result: ^Mesh_Status, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure
	}
	if result == nil {
		outcome, _ := call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
		return outcome
	}
	links_up: i64
	for &link in mesh_client.links {
		if link.in_use && link.session.state == .Up {
			links_up += 1
		}
	}
	stores_active: i64
	for &store in mesh.stores.rows {
		if store.in_use {
			stores_active += 1
		}
	}
	routes_active: i64
	for &route in mesh.relay.routes {
		if route.in_use {
			routes_active += 1
		}
	}
	result^ = {
		paired_machines   = i64(mesh.paired.count),
		links_up          = links_up,
		objects_stored    = i64(mesh.objects.count),
		exchanged_stores  = stores_active,
		relay_routes      = routes_active,
		role_calls_served = i64(mesh_role_calls_served),
	}
	return .Succeeded
}

// mesh_pair_offer starts a CPace pairing offer on this machine and writes the
// 10-character base32 one-time pairing code into result.
//
// - **uses_word**: bit word of remote.Client_Uses granted to the joining
//   machine upon confirmation.
// - **result**: output buffer receiving the 10-character pairing code.
//
// Errors: `No_Grant`, `Bad_Value`, `State`.
@(export, link_name = "mesh_pair_offer")
mesh_pair_offer_export :: proc "c" (uses_word: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	if uses_word < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, uses_word)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	code: [machine_mesh.PAIRING_CODE_TEXT_SIZE]u8
	defer machine_mesh.clear_bytes_explicitly(code[:])
	offer_outcome, _ := mesh_pairing_offer(&code, u64(uses_word), error)
	if offer_outcome != .Succeeded {
		return offer_outcome, 0
	}
	copy(result^, code[:])
	return .Succeeded, i64(len(code))
}

// mesh_pair_join prepares this machine as a CPace pairing joiner with the
// 10-character base32 pairing code shown on the offerer.
//
// - **code_text**: 10-character base32 pairing code.
// - **uses_word**: bit word of remote.Client_Uses granted to the offerer upon
//   confirmation.
//
// Errors: `No_Grant`, `Bad_Value`, `State`.
@(export, link_name = "mesh_pair_join")
mesh_pair_join_export :: proc "c" (code_text: ^string, uses_word: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	if code_text == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if uses_word < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, uses_word)
	}
	raw := code_text^
	return mesh_pairing_join(transmute([]u8)raw, u64(uses_word), error)
}

// mesh_grant sets the mesh uses and allowed remote roles for a paired machine.
//
// - **peer_key_hex**: 64-character hex identity key of the paired machine.
// - **uses_word**: bit word of machine_wire.Machine_Uses.
// - **roles_mask**: bit word of role_contract.Role members when Roles is set.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Full`.
@(export, link_name = "mesh_grant")
mesh_grant_export :: proc "c" (peer_key_hex: ^string, uses_word: i64, roles_mask: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if uses_word < 0 || uses_word > i64(max(u32)) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, uses_word)
	}
	uses, uses_ok := machine_wire.machine_uses_of_word(u32(uses_word))
	if !uses_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, uses_word)
	}
	if roles_mask < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, roles_mask)
	}
	roles, roles_ok := role_set_of_word(u64(roles_mask))
	if !roles_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, roles_mask)
	}
	if !machine_wire.machine_grant_set(&mesh, identity, uses, roles) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Grants, 2, uses_word, roles_mask)
	}
	return .Succeeded, 0
}

// mesh_paired_has returns 1 when peer_key_hex is present in the paired machine
// table, and 0 otherwise.
//
// - **peer_key_hex**: 64-character hex identity key.
//
// Errors: `No_Grant`, `Bad_Value`.
@(export, link_name = "mesh_paired_has")
mesh_paired_has_export :: proc "c" (peer_key_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	_, found := machine_mesh.paired_machine_find(&mesh.paired, identity)
	return .Succeeded, found ? 1 : 0
}

// mesh_link_open initiates an outbound QUIC connection pinning peer_key_hex at
// address_text:port for purpose_word (1 = Paired, 2 = Pairing).
//
// - **peer_key_hex**: 64-character hex identity key pinned in TLS 1.3.
// - **address_text**: dotted IPv4 address (for example "10.0.2.2").
// - **port**: remote UDP port (1..65535).
// - **purpose_word**: machine_wire.Mesh_Link_Purpose word (1 or 2).
//
// Errors: `No_Grant`, `Bad_Value`, `Exists`, `Full`, `Link_Down`.
@(export, link_name = "mesh_link_open")
mesh_link_open_export :: proc "c" (peer_key_hex: ^string, address_text: ^string, port: i64, purpose_word: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	address, addr_outcome, addr_ok := ipv4_parse(address_text, 2, error)
	if !addr_ok {
		return addr_outcome, 0
	}
	if port <= 0 || port > 65535 {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .None, 3, port, 65535)
	}
	if purpose_word <= 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 4, purpose_word)
	}
	return mesh_connect(identity, address, u16(port), u64(purpose_word), error)
}

// mesh_link_state returns the current Mesh_Link_State word for the outbound
// link to peer_key_hex (0 = Idle/absent, 1 = Connecting, 2 = Up, 3 = Broken).
//
// - **peer_key_hex**: 64-character hex identity key.
//
// Errors: `No_Grant`, `Bad_Value`.
@(export, link_name = "mesh_link_state")
mesh_link_state_export :: proc "c" (peer_key_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	link, _ := mesh_link_find(identity)
	if link == nil {
		return .Succeeded, i64(machine_wire.Mesh_Link_State.Idle)
	}
	return .Succeeded, i64(link.session.state)
}

// mesh_link_close closes the active outbound QUIC link to peer_key_hex.
//
// - **peer_key_hex**: 64-character hex identity key.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`.
@(export, link_name = "mesh_link_close")
mesh_link_close_export :: proc "c" (peer_key_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	return mesh_disconnect(identity, error)
}

// mesh_pair_send begins the CPace pairing frame exchange on an established
// Pairing link to peer_key_hex and returns its request identifier.
//
// - **peer_key_hex**: 64-character hex identity key of the offerer.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Link_Down`.
@(export, link_name = "mesh_pair_send")
mesh_pair_send_export :: proc "c" (peer_key_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	return mesh_pairing_join_send(identity, error)
}

// mesh_object_put stores payload repeated repeat_count times in the local mesh
// object store under its BLAKE3 hash and writes the 64-character hex hash into
// result.
//
// - **kind_word**: object_cache.Cache_Object_Kind word.
// - **payload**: bytes to repeat and hash.
// - **repeat_count**: positive repetition count (1..4096) bounded by
//   MESH_PUBLISH_STAGING_LIMIT.
// - **result**: output buffer receiving the 64-character hex BLAKE3 hash.
//
// Errors: `No_Grant`, `Bad_Value`, `Too_Long`, `Full`.
@(export, link_name = "mesh_object_put")
mesh_object_put_export :: proc "c" (kind_word: i64, payload: ^string, repeat_count: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	if kind_word <= 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, kind_word)
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(u64(kind_word))
	if !kind_ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, kind_word)
	}
	if payload == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
	}
	if repeat_count <= 0 || repeat_count > MESH_PUBLISH_REPEAT_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .None, 3, repeat_count, MESH_PUBLISH_REPEAT_LIMIT)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 4)
	}
	raw := payload^
	if len(raw) == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 2, 0, MESH_PUBLISH_STAGING_LIMIT)
	}
	if i64(len(raw)) > MESH_PUBLISH_STAGING_LIMIT / repeat_count {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(raw)) * repeat_count, MESH_PUBLISH_STAGING_LIMIT)
	}
	total := int(i64(len(raw)) * repeat_count)
	offset := 0
	for _ in 0 ..< int(repeat_count) {
		copy(mesh_publish_staging[offset:], raw)
		offset += len(raw)
	}
	bytes := mesh_publish_staging[:total]
	hash := blake3.hash(bytes)
	mesh_assembly_partner = mesh.identity.public_key
	status := machine_wire.object_publish(&mesh, kind, hash, bytes)
	switch status {
	case .Stored, .Already_Stored:
		text: [64]u8
		hex := quic_server.hex_text(text[:], hash[:])
		copy(result^, hex)
		return .Succeeded, i64(len(hex))
	case .Refused_Full:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 0)
	case .Refused_Too_Large:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Too_Long, .Bytes, 2, i64(total))
	case .Refused_Hash_Mismatch, .Refused_Malformed, .Refused_Nil_Input:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Objects, 2, 0, 0, i64(status))
	}
	return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Objects, 2, 0, 0, i64(status))
}

// mesh_object_fetch starts an outbound Object_Request over the Paired QUIC link
// to peer_key_hex and returns its request identifier.
//
// - **peer_key_hex**: 64-character hex identity key of the paired peer.
// - **kind_word**: object_cache.Cache_Object_Kind word.
// - **hash_hex**: 64-character hex BLAKE3 hash of the object.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Link_Down`.
@(export, link_name = "mesh_object_fetch")
mesh_object_fetch_export :: proc "c" (peer_key_hex: ^string, kind_word: i64, hash_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if kind_word <= 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, kind_word)
	}
	hash: blake3.Hash
	if decode_outcome, ok := hex_decode_exact(hash_hex, hash[:], 3, error); !ok {
		return decode_outcome, 0
	}
	return mesh_fetch_object(identity, u64(kind_word), hash, error)
}

// mesh_object_has returns the stored byte length of the object named by
// hash_hex in the local mesh object store, or 0 when absent.
//
// - **hash_hex**: 64-character hex BLAKE3 hash.
//
// Errors: `No_Grant`, `Bad_Value`.
@(export, link_name = "mesh_object_has")
mesh_object_has_export :: proc "c" (hash_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	hash: blake3.Hash
	if decode_outcome, ok := hex_decode_exact(hash_hex, hash[:], 1, error); !ok {
		return decode_outcome, 0
	}
	bytes, found := mesh_object_lookup(hash)
	if !found {
		return .Succeeded, 0
	}
	return .Succeeded, i64(len(bytes))
}

// mesh_role_call starts an outbound Role_Call over the Paired QUIC link to
// peer_key_hex and returns its request identifier.
//
// - **peer_key_hex**: 64-character hex identity key of the paired peer.
// - **role_word**: role_contract.Role word.
// - **export_index**: zero-based index of the export in the role holder.
// - **flags_word**: machine_wire.Role_Call_Flags word.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Link_Down`.
@(export, link_name = "mesh_role_call")
mesh_role_call_export :: proc "c" (peer_key_hex: ^string, role_word: i64, export_index: i64, flags_word: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if role_word <= 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, role_word)
	}
	if export_index < 0 || export_index > i64(max(u32)) {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .None, 3, export_index, i64(max(u32)))
	}
	if flags_word < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 4, flags_word)
	}
	return mesh_call_role(identity, u64(role_word), u32(export_index), u64(flags_word), nil, error)
}

// mesh_store_add registers a named store for exchange with peer_key_hex.
//
// - **store_name**: name hashed into the store identifier.
// - **peer_key_hex**: 64-character hex identity key of the exchange partner.
//
// Errors: `No_Grant`, `Bad_Value`, `Exists`, `Full`.
@(export, link_name = "mesh_store_add")
mesh_store_add_export :: proc "c" (store_name: ^string, peer_key_hex: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	store_id, id_outcome, id_ok := store_id_of_name(store_name, 1, error)
	if !id_ok {
		return id_outcome, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 2, error); !ok {
		return decode_outcome, 0
	}
	_, status := machine_wire.store_exchange_add(&mesh.stores, store_id, identity)
	if status != .Ok {
		return call_outcome.fail(error, status == .Refused_Full ? .Budget_Or_Capacity_Exhausted : .Argument_Refused, status == .Refused_Full ? .Full : .Bad_Value, .Stores, 1, 0, 0, i64(status))
	}
	return .Succeeded, 0
}

// mesh_store_put writes an entry into an exchanged store under object_name
// with the BLAKE3 hash of value_text.
//
// - **store_name**: exchanged store name.
// - **object_name**: object identifier name.
// - **value_text**: object content hashed as the entry's value.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `State` (unresolved conflict).
@(export, link_name = "mesh_store_put")
mesh_store_put_export :: proc "c" (store_name: ^string, object_name: ^string, value_text: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	store_id, id_outcome, id_ok := store_id_of_name(store_name, 1, error)
	if !id_ok {
		return id_outcome, 0
	}
	object_id, obj_outcome, obj_ok := store_id_of_name(object_name, 2, error)
	if !obj_ok {
		return obj_outcome, 0
	}
	if value_text == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 3)
	}
	store := machine_wire.store_exchange_find(&mesh.stores, store_id)
	if store == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Stores, 1)
	}
	raw := value_text^
	content_hash := blake3.hash(transmute([]u8)raw)
	status := machine_wire.store_write(store, object_id, content_hash)
	if status != .Ok {
		return call_outcome.fail(error, status == .Refused_Holds_Conflict ? .Wrong_State : .Budget_Or_Capacity_Exhausted, status == .Refused_Holds_Conflict ? .State : .Full, .Stores, 2, 0, 0, i64(status))
	}
	return .Succeeded, 0
}

// mesh_store_resolve resolves an active conflict on object_name in store_name
// with the BLAKE3 hash of value_text.
//
// - **store_name**: exchanged store name.
// - **object_name**: conflicted object identifier name.
// - **value_text**: resolved content hashed as the new entry value.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `State`.
@(export, link_name = "mesh_store_resolve")
mesh_store_resolve_export :: proc "c" (store_name: ^string, object_name: ^string, value_text: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	store_id, id_outcome, id_ok := store_id_of_name(store_name, 1, error)
	if !id_ok {
		return id_outcome, 0
	}
	object_id, obj_outcome, obj_ok := store_id_of_name(object_name, 2, error)
	if !obj_ok {
		return obj_outcome, 0
	}
	if value_text == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 3)
	}
	store := machine_wire.store_exchange_find(&mesh.stores, store_id)
	if store == nil {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Stores, 1)
	}
	raw := value_text^
	content_hash := blake3.hash(transmute([]u8)raw)
	status := machine_wire.store_conflict_resolve(store, object_id, content_hash)
	if status != .Ok {
		return call_outcome.fail(error, .Wrong_State, .State, .Stores, 2, 0, 0, i64(status))
	}
	return .Succeeded, 0
}

// mesh_store_info writes the entry count, conflict count, current tree hash,
// and common tree hash of store_name into result.
//
// - **store_name**: exchanged store name.
// - **result**: Mesh_Store_Info record.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Bad_Address`.
@(export, link_name = "mesh_store_info")
mesh_store_info_export :: proc "c" (store_name: ^string, result: ^Mesh_Store_Info, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure
	}
	store_id, id_outcome, id_ok := store_id_of_name(store_name, 1, error)
	if !id_ok {
		return id_outcome
	}
	if result == nil {
		outcome, _ := call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 2)
		return outcome
	}
	store := machine_wire.store_exchange_find(&mesh.stores, store_id)
	if store == nil {
		outcome, _ := call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Stores, 1)
		return outcome
	}
	current_hash := machine_wire.store_version_hash(&store.current)
	common_hash := machine_wire.store_version_hash(&store.common)
	result^ = {
		entry_count      = i64(store.current.count),
		conflict_count   = i64(store.current.conflict_count),
		tree_hash        = value_kinds.Hash_Field(current_hash),
		common_tree_hash = value_kinds.Hash_Field(common_hash),
	}
	return .Succeeded
}

// mesh_store_sync initiates a multi-page Store_Offer exchange for store_name
// over the Paired QUIC link to peer_key_hex and returns its request identifier.
//
// - **peer_key_hex**: 64-character hex identity key of the partner.
// - **store_name**: exchanged store name.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Link_Down`.
@(export, link_name = "mesh_store_sync")
mesh_store_sync_export :: proc "c" (peer_key_hex: ^string, store_name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	store_id, id_outcome, id_ok := store_id_of_name(store_name, 2, error)
	if !id_ok {
		return id_outcome, 0
	}
	return mesh_sync_store(identity, store_id, error)
}

// mesh_relay_token derives the 32-character hex directional routing token for
// outbound envelopes from this machine to peer_key_hex in epoch.
//
// - **peer_key_hex**: 64-character hex identity key of the paired recipient.
// - **epoch**: non-negative relay epoch number.
// - **result**: output buffer receiving the 32-character hex routing token.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `State`.
@(export, link_name = "mesh_relay_token")
mesh_relay_token_export :: proc "c" (peer_key_hex: ^string, epoch: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if epoch < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, epoch)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 3)
	}
	relay_key, found := machine_mesh.paired_machine_relay_key(&mesh.paired, identity)
	defer machine_mesh.clear_bytes_explicitly(relay_key[:])
	if !found {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Records, 1)
	}
	if machine_mesh.key_is_zero(relay_key) {
		return call_outcome.fail(error, .Wrong_State, .State, .Records, 1)
	}
	token := machine_wire.relay_directional_routing_token(relay_key, mesh.identity.public_key, identity, u64(epoch))
	text: [32]u8
	hex := quic_server.hex_text(text[:], token[:])
	copy(result^, hex)
	return .Succeeded, i64(len(hex))
}

// mesh_relay_route adds (add_flag = 1) or removes (add_flag = 0) a relay
// forwarding route on this machine bound to sender_key_hex and receiver_key_hex.
//
// - **sender_key_hex**: 64-character hex identity key of the depositor.
// - **receiver_key_hex**: 64-character hex identity key of the collector.
// - **token_hex**: 32-character hex routing token.
// - **add_flag**: 1 to add the route, 0 to remove it.
//
// Errors: `No_Grant`, `Bad_Value`, `Exists`, `Full`, `Absent`.
@(export, link_name = "mesh_relay_route")
mesh_relay_route_export :: proc "c" (sender_key_hex: ^string, receiver_key_hex: ^string, token_hex: ^string, add_flag: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	sender: [32]u8
	receiver: [32]u8
	token: machine_wire.Routing_Token
	if decode_outcome, ok := hex_decode_exact(sender_key_hex, sender[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if decode_outcome, ok := hex_decode_exact(receiver_key_hex, receiver[:], 2, error); !ok {
		return decode_outcome, 0
	}
	if decode_outcome, ok := hex_decode_exact(token_hex, token[:], 3, error); !ok {
		return decode_outcome, 0
	}
	if add_flag != 0 && add_flag != 1 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 4, add_flag, 1)
	}
	status: machine_wire.Relay_Status
	if add_flag == 1 {
		status = machine_wire.relay_route_add(&mesh.relay, token, sender, receiver)
	} else {
		status = machine_wire.relay_route_remove(&mesh.relay, token)
	}
	if status != .Ok {
		return call_outcome.fail(error, status == .Refused_Table_Full ? .Budget_Or_Capacity_Exhausted : .Argument_Refused, status == .Refused_Table_Full ? .Full : .Bad_Value, .Records, 3, 0, 0, i64(status))
	}
	return .Succeeded, 0
}

// mesh_relay_send seals payload with ChaCha20-Poly1305 under the CPace relay
// key shared with peer_key_hex and sends a Relay_Deposit to relay_key_hex over
// QUIC, returning its request identifier.
//
// - **relay_key_hex**: 64-character hex identity key of the relay machine.
// - **peer_key_hex**: 64-character hex identity key of the recipient machine.
// - **epoch**: non-negative routing epoch.
// - **payload**: plaintext payload to seal end-to-end.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Too_Long`, `Link_Down`.
@(export, link_name = "mesh_relay_send")
mesh_relay_send_export :: proc "c" (relay_key_hex: ^string, peer_key_hex: ^string, epoch: i64, payload: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	relay_id: [32]u8
	peer_id: [32]u8
	if decode_outcome, ok := hex_decode_exact(relay_key_hex, relay_id[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, peer_id[:], 2, error); !ok {
		return decode_outcome, 0
	}
	if epoch < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, epoch)
	}
	if payload == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 4)
	}
	raw := payload^
	return mesh_relay_deposit(relay_id, peer_id, u64(epoch), transmute([]u8)raw, error)
}

// mesh_relay_receive sends a Relay_Collect to relay_key_hex for the routing
// token of peer_key_hex at epoch over QUIC, returning its request identifier.
//
// - **relay_key_hex**: 64-character hex identity key of the relay machine.
// - **peer_key_hex**: 64-character hex identity key of the sender machine.
// - **epoch**: non-negative routing epoch.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, `Link_Down`.
@(export, link_name = "mesh_relay_receive")
mesh_relay_receive_export :: proc "c" (relay_key_hex: ^string, peer_key_hex: ^string, epoch: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	relay_id: [32]u8
	peer_id: [32]u8
	if decode_outcome, ok := hex_decode_exact(relay_key_hex, relay_id[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, peer_id[:], 2, error); !ok {
		return decode_outcome, 0
	}
	if epoch < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, epoch)
	}
	return mesh_relay_collect(relay_id, peer_id, u64(epoch), error)
}

// mesh_request_poll polls an outbound mesh request. Returns "pending" while
// in flight, or "ok:<value>" / "ok:<payload>" when complete, freeing the
// request slot once read. On failure returns the session call outcome and error
// record.
//
// - **peer_key_hex**: 64-character hex identity key of the link peer.
// - **request_id**: positive request identifier returned when the request began.
// - **result**: output buffer receiving the status text.
//
// Errors: `No_Grant`, `Bad_Value`, `Absent`, or the failed request's outcome.
@(export, link_name = "mesh_request_poll")
mesh_request_poll_export :: proc "c" (peer_key_hex: ^string, request_id: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if failure, ok := mesh_caller_check(error); !ok {
		return failure, 0
	}
	identity: [32]u8
	if decode_outcome, ok := hex_decode_exact(peer_key_hex, identity[:], 1, error); !ok {
		return decode_outcome, 0
	}
	if request_id <= 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, request_id)
	}
	if result == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 3)
	}
	role_value: i64
	result_count: int
	req_outcome, done := mesh_request_result(identity, u64(request_id), &role_value, mesh_poll_staging[:], &result_count, error)
	if req_outcome != .Succeeded {
		return req_outcome, 0
	}
	if done == 0 {
		copied := copy(result^, "pending")
		return .Succeeded, i64(copied)
	}
	written: string
	if result_count > 0 {
		written = system.format(result^, "ok:", string(mesh_poll_staging[:result_count]))
		machine_mesh.clear_bytes_explicitly(mesh_poll_staging[:result_count])
	} else {
		written = system.format(result^, "ok:", role_value)
	}
	return .Succeeded, i64(len(written))
}
