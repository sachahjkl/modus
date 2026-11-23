package remote_service

// The state of this machine among the other machines of its principal
// (src/md/features/several_machines.md): its identity, the pairing by a code,
// the paired machines, the newest signed machine list, the signed grants
// that it serves, the objects by hash, the exchanged stores, the roles that
// it holds for paired machines, and the routes of the relay.
//
// The contracts decide (modus:contract/machine_wire, machine_mesh,
// machine_sync and object_cache); this file holds their state for the
// process, draws the random bytes, checks the Ed25519 signatures through the
// module cryptography, gives each refusal as an error record, and answers
// each mesh frame that a stream of a paired machine carries (mesh_serve).
//
// The identity is the public key of this start of the service. The design
// derives it from the machine key in the root service, which then signs
// for remote; until then a pairing lasts until the service stops, as the
// design says of a machine with no machine key.

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/machine_mesh"
import "modus:contract/machine_sync"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import op "modus:contract/operation"
import "modus:contract/remote"
import "modus:random"
import "modus:system"

// The state of the mesh: in the data of the process, never on a stack.
mesh: machine_wire.Peer
// The tables of the mesh that grow with the principal: the bytes and the
// rows of the objects by hash and the rows of the exchanged stores, each
// in an arena of the budget of remote that reserves as many pages as the
// budget held at the start and commits the exact pages of each growth;
// and the versions of each store, each in a memory object of its own. No
// count of this file refuses a sync: the budget does, with its kept
// pages and its shares (machine_wire.memory_growth_allowed). The bytes,
// the object rows and the store rows grow in place, since a pointer to a
// row stays in use. A version moves to a larger object and closes the old
// one, so its pages go back to the budget at once, and a refused version
// gives back its object (mesh_version_trim).
mesh_object_bytes_arena: system.Arena
mesh_object_rows_arena: system.Arena
mesh_store_rows_arena: system.Arena

// The pages of the budget that a growth of a table always leaves free, so
// that the streams, the call regions and the window of remote still get
// their pages when the principal syncs more than the budget holds.
MESH_BUDGET_KEPT_PAGES :: 512

// The shares of the mesh, from the budget at the start of the mesh.
mesh_shares: machine_wire.Memory_Shares

// mesh_growth_allowed says if a growth that commits push_pages may run:
// the budget keeps its kept pages after it, and the store and the partner
// that grow stay in their shares.
@(private = "file")
mesh_growth_allowed :: proc "contextless" (push_pages, store_pages, peer_pages: u64) -> bool {
	amounts, status := system.budget_read()
	return status == .Ok && machine_wire.memory_growth_allowed(mesh_shares, amounts.pages, push_pages, store_pages, peer_pages)
}

// mesh_extend pushes bytes more onto an arena that holds one table, and
// is true when they follow the end of the table: the table then grows in
// place. The pages that the push commits, which the arena counts before
// it, are the pages that the shares see.
@(private = "file")
mesh_extend :: proc "contextless" (arena: ^system.Arena, table_end: rawptr, bytes: int, alignment: int, store_pages, peer_pages: u64) -> bool {
	if bytes <= 0 {
		return true
	}
	pages, fits := system.arena_push_commit_pages(arena, u64(bytes), u64(alignment))
	if !fits || !mesh_growth_allowed(pages, store_pages, peer_pages) {
		return false
	}
	address, status := system.arena_push(arena, u64(bytes), u64(alignment))
	return status == .Ok && (table_end == nil || address == table_end)
}

// The growth of a table in place: the double of its length when the
// budget pays it, else the least that is asked.
@(private = "file")
mesh_grow_in_place :: proc "contextless" (arena: ^system.Arena, $T: typeid, table: ^[]T, least: int, store_pages, peer_pages: u64) -> bool {
	if least <= len(table^) {
		return true
	}
	base := ([^]T)(arena.base)
	end: rawptr = len(table^) == 0 ? nil : rawptr(&base[len(table^)])
	for wanted in ([2]int{max(least, 2 * len(table^)), least}) {
		if mesh_extend(arena, end, (wanted - len(table^)) * size_of(T), align_of(T), store_pages, peer_pages) {
			table^ = base[:wanted]
			return true
		}
	}
	return false
}

// The paired machine whose object the store of objects assembles now: the
// link of the client sets it before each piece (mesh_client.odin). An
// object in assembly names no store, and belongs to that partner.
mesh_assembly_partner: [machine_mesh.PUBLIC_KEY_SIZE]u8

// The bytes of an object in assembly hold at most the share of a store,
// and count in the share of the partner that sends it, with the versions
// of its stores: a partner holds at most half of the mesh, the object
// that it sends included, and cannot take the mesh with an object that
// will not prove its hash.
@(private = "file")
mesh_object_grow :: proc "contextless" (_: rawptr, store: ^machine_sync.Object_Store, bytes_least, rows_least: int) -> bool {
	assembly_pages := u64(max(len(store.bytes) - store.bytes_used, 0)) / system.PAGE_SIZE
	peer_pages := mesh_partner_pages(mesh_assembly_partner) + assembly_pages
	return mesh_grow_in_place(&mesh_object_bytes_arena, u8, &store.bytes, bytes_least, assembly_pages, peer_pages) && mesh_grow_in_place(&mesh_object_rows_arena, machine_sync.Stored_Object, &store.objects, rows_least, 0, 0)
}

// mesh_partner_pages gives the pages that the versions of the stores of
// one partner hold.
@(private = "file")
mesh_partner_pages :: proc "contextless" (partner: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> (pages: u64) {
	for &other in mesh.stores.rows {
		if other.in_use && other.partner_identity == partner {
			pages += other.memory_pages
		}
	}
	return
}

// After an object that did not prove its hash, or that stopped between
// two pieces, the bytes past those in use go back to the budget.
@(private = "file")
mesh_object_trim :: proc "contextless" (_: rawptr, store: ^machine_sync.Object_Store) {
	if system.arena_trim(&mesh_object_bytes_arena, u64(store.bytes_used)) == .Ok {
		store.bytes = ([^]u8)(mesh_object_bytes_arena.base)[:store.bytes_used]
	}
}

@(private = "file")
mesh_store_table_grow :: proc "contextless" (_: rawptr, table: ^machine_wire.Store_Table, rows_least: int) -> bool {
	return mesh_grow_in_place(&mesh_store_rows_arena, machine_wire.Exchanged_Store, &table.rows, rows_least, 0, 0)
}

// The head of the memory object of a version, before its entries: the
// object and the pages that the budget paid for it, its frame list
// included, so a growth or a trim closes the old one and counts them back.
Mesh_Version_Head :: struct {
	memory:     system.Handle,
	paid_pages: u64,
}
MESH_VERSION_HEAD_BYTES :: 64
#assert(size_of(Mesh_Version_Head) <= MESH_VERSION_HEAD_BYTES)

@(private = "file")
mesh_version_head :: proc "contextless" (version: ^machine_wire.Store_Version) -> ^Mesh_Version_Head {
	data := rawptr(raw_data(version.entries))
	if data == nil {
		return nil
	}
	return (^Mesh_Version_Head)(uintptr(data) - MESH_VERSION_HEAD_BYTES)
}

// mesh_store_of_version gives the row of the store that holds a version,
// and the pages that the stores of its partner hold.
@(private = "file")
mesh_store_of_version :: proc "contextless" (version: ^machine_wire.Store_Version) -> (store: ^machine_wire.Exchanged_Store, peer_pages: u64) {
	rows := mesh.stores.rows
	if len(rows) == 0 {
		return nil, 0
	}
	first := uintptr(raw_data(rows))
	place := uintptr(version)
	if place < first || place >= first + uintptr(len(rows) * size_of(machine_wire.Exchanged_Store)) {
		return nil, 0
	}
	store = &rows[(place - first) / size_of(machine_wire.Exchanged_Store)]
	return store, mesh_partner_pages(store.partner_identity)
}

// mesh_version_free closes the object of a version and counts its pages
// back.
@(private = "file")
mesh_version_free :: proc "contextless" (version: ^machine_wire.Store_Version, store: ^machine_wire.Exchanged_Store) {
	head := mesh_version_head(version)
	if head == nil {
		return
	}
	memory, paid_pages := head.memory, head.paid_pages
	system.memory_unmap(rawptr(head))
	system.close(memory)
	if store != nil {
		store.memory_pages -= min(store.memory_pages, paid_pages)
	}
	version.entries, version.conflicts = nil, nil
}

// A version moves to a new object of the double of its size, with its
// content: no pointer names an entry of a version across a call. The
// object is paid whole at its creation, so its pages are the pages that
// the shares see; the old object closes after the copy.
@(private = "file")
mesh_version_grow :: proc "contextless" (_: rawptr, version: ^machine_wire.Store_Version, entries_least, conflicts_least: int) -> bool {
	if entries_least <= len(version.entries) && conflicts_least <= len(version.conflicts) {
		return true
	}
	store, peer_pages := mesh_store_of_version(version)
	store_pages := store != nil ? store.memory_pages : 0
	doubled := [2]int{max(entries_least, len(version.entries) >= entries_least ? len(version.entries) : 2 * len(version.entries), 64), max(conflicts_least, len(version.conflicts) >= conflicts_least ? len(version.conflicts) : 2 * len(version.conflicts), 8)}
	least := [2]int{max(entries_least, len(version.entries)), max(conflicts_least, len(version.conflicts))}
	for wanted in ([2][2]int{doubled, least}) {
		bytes := u64(MESH_VERSION_HEAD_BYTES + wanted[0] * size_of(machine_wire.Store_Entry) + wanted[1] * size_of(machine_wire.Store_Conflict))
		pages := (bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE
		// The budget pays the frame list of the object beside its pages:
		// the shares and the kept pages see both.
		paid_pages := pages + op.memory_list_pages(pages)
		if !mesh_growth_allowed(paid_pages, store_pages, peer_pages) {
			continue
		}
		memory, status := system.memory_create(pages)
		if status != .Ok {
			continue
		}
		address, map_status := system.memory_map(memory, {.Write})
		if map_status != .Ok {
			system.close(memory)
			continue
		}
		(^Mesh_Version_Head)(address)^ = {memory = memory, paid_pages = paid_pages}
		entries := ([^]machine_wire.Store_Entry)(uintptr(address) + MESH_VERSION_HEAD_BYTES)[:wanted[0]]
		conflicts := ([^]machine_wire.Store_Conflict)(uintptr(address) + MESH_VERSION_HEAD_BYTES + uintptr(wanted[0] * size_of(machine_wire.Store_Entry)))[:wanted[1]]
		copy(entries, version.entries[:version.count])
		copy(conflicts, version.conflicts[:version.conflict_count])
		mesh_version_free(version, store)
		version.entries, version.conflicts = entries, conflicts
		if store != nil {
			store.memory_pages += paid_pages
		}
		return true
	}
	return false
}

// A version that a refusal emptied gives its object back.
@(private = "file")
mesh_version_trim :: proc "contextless" (_: rawptr, version: ^machine_wire.Store_Version) {
	store, _ := mesh_store_of_version(version)
	mesh_version_free(version, store)
}

// mesh_memory_make reserves the arenas of the tables, each as large as the
// budget of remote holds now, with exact commits; their pages come at the
// first sync. The tables start empty, and the shares come from the same
// budget.
@(private = "file")
mesh_memory_make :: proc "contextless" (error: ^errors.Error_Record) -> (memory: machine_wire.Peer_Memory, status: system.Status) {
	arenas := [3]^system.Arena{&mesh_object_bytes_arena, &mesh_object_rows_arena, &mesh_store_rows_arena}
	for arena in arenas {
		system.arena_end(arena)
	}
	amounts: system.Budget_Amounts
	amounts, status = system.budget_read(error = error)
	if status != .Ok {
		return {}, status
	}
	mesh_shares = machine_wire.memory_shares_of(amounts.pages, MESH_BUDGET_KEPT_PAGES)
	reserve := system.arena_reservation_pages(amounts.pages)
	for arena in arenas {
		arena^, status = system.arena_create(reserve, error = error)
		if status != .Ok {
			for other in arenas {
				system.arena_end(other)
			}
			return {}, status
		}
		arena.exact_commits = true
	}
	memory.object_grow = mesh_object_grow
	memory.object_trim = mesh_object_trim
	memory.store_table_grow = mesh_store_table_grow
	memory.version_grow = mesh_version_grow
	memory.version_trim = mesh_version_trim
	return memory, .Ok
}

// The answer of one mesh frame, before it goes to the buffer of its stream,
// which still holds the request.
mesh_answer: [machine_wire.FRAME_LIMIT]u8

// mesh_signature_verify gives the contracts the strict Ed25519 check of the
// module cryptography.
mesh_signature_verify :: proc "contextless" (
	public_key: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [machine_mesh.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	key := public_key
	signature_copy := signature
	key_text := string(key[:])
	message_text := string(message)
	signature_text := string(signature_copy[:])
	error: errors.Error_Record
	crypto_outcome, crypto_count := ed25519_verify(&key_text, &message_text, &signature_text, &error)
	return crypto_outcome == .Succeeded && crypto_count == 0
}

// mesh_fill_random draws the CPace scalar of an exchange from the generator
// for keys of this process.
mesh_fill_random :: proc "contextless" (bytes: []u8, _: rawptr) -> bool {
	error: errors.Error_Record
	return random.fill_for_a_key(&process_generator, bytes, .Processor, &error)
}

// mesh_identity_set takes the public key of this service as the machine
// identity, and makes the state of the mesh empty. No role holder is given
// yet: a role call of a paired machine is refused until the root service
// gives remote a connection to the real holder for the row of that machine.
// 0, or -1 with an error record.
mesh_identity_set :: proc "contextless" (public_key: [32]u8, error: ^errors.Error_Record) -> i64 {
	services := machine_wire.Peer_Services {
		signature_verify = mesh_signature_verify,
		fill_random      = mesh_fill_random,
	}
	memory, memory_status := mesh_memory_make(error)
	if memory_status != .Ok {
		return -1
	}
	if !machine_wire.peer_init(&mesh, public_key, services, memory) {
		return errors.fail(error, -1, .Bad_Value, .None, 1)
	}
	return 0
}

// mesh_serve answers one mesh frame of a stream: the request is in
// buffer[:received], and the answer replaces it. peer_identity is the key
// that the handshake proved. It gives the length of the answer.
mesh_serve :: proc "contextless" (buffer: []u8, received: int, peer_identity: [32]u8) -> int {
	serve_context := machine_wire.Serve_Context {
		peer_identity   = peer_identity,
		channel_binding = machine_wire.channel_binding_of_identities(mesh.identity.public_key, peer_identity),
		now_ms          = system.time(),
	}
	// The principal of the sender: a machine that the newest machine list
	// of this principal names. The machine lists of other principals are
	// not presented yet, so a machine of another principal proves none.
	if row, paired := machine_mesh.paired_machine_find(&mesh.paired, peer_identity); paired && row.source == .Machine_List && mesh.machine_list.has_list {
		serve_context.peer_root_public_key = mesh.machine_list.principal_root_public_key
	}
	answer := machine_wire.serve(&mesh, &serve_context, buffer[:received], mesh_answer[:])
	return copy(buffer, answer)
}

// mesh_principal_set names the principal root key whose signed machine list
// this machine follows. A second call with another key starts again with no
// list and no row of a list.
mesh_principal_set :: proc "contextless" (principal_root_public_key: [32]u8, error: ^errors.Error_Record) -> i64 {
	if !machine_mesh.machine_list_holder_init(&mesh.machine_list, principal_root_public_key) {
		return errors.fail(error, -1, .Bad_Value, .None, 1)
	}
	index := mesh.paired.count - 1
	for index >= 0 {
		row := mesh.paired.machines[index]
		if row.source == .Machine_List {
			machine_mesh.paired_machine_remove(&mesh.paired, row.identity_key)
			machine_wire.machine_grant_clear(&mesh, row.identity_key)
		}
		index -= 1
	}
	mesh.revocations = {}
	mesh.has_revocations = false
	mesh.has_principal = true
	return 0
}

@(private = "file")
mesh_identity_check :: proc "contextless" (error: ^errors.Error_Record) -> bool {
	if !mesh.has_identity {
		errors.fail(error, -1, .State, .None, 0, 0, 0, 0)
		return false
	}
	return true
}

// mesh_pairing_offer starts a pairing on this machine and writes the code to
// show. uses_word is the word of the uses that the principal gives the
// machine that types the code: its row takes them when the exchange of the
// mesh frames confirms (machine_wire.serve). 0, or -1 with an error record.
mesh_pairing_offer :: proc "contextless" (code_text: ^[machine_mesh.PAIRING_CODE_TEXT_SIZE]u8, uses_word: u64, error: ^errors.Error_Record) -> i64 {
	if code_text == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !mesh_identity_check(error) {
		return -1
	}
	uses, uses_known := remote.client_uses_of_word(uses_word)
	if !uses_known {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(uses_word), i64(remote.client_uses_word({.Calls, .View, .Input})))
	}
	mesh.pairing_uses = uses
	random_bytes: [8]u8
	defer machine_mesh.clear_bytes_explicitly(random_bytes[:])
	if !random.fill_for_a_key(&process_generator, random_bytes[:], .Processor, error) {
		return -1
	}
	text, status := machine_mesh.pairing_offer(&mesh.pairing, mesh.identity.public_key, random_bytes, system.time())
	if status != .Ok {
		return mesh_pairing_fail(error, status, 0)
	}
	code_text^ = text
	return 0
}

// mesh_pairing_join starts a pairing with the code that the principal
// typed, and the uses that it gives the machine that showed the code.
mesh_pairing_join :: proc "contextless" (code_text: []u8, uses_word: u64, error: ^errors.Error_Record) -> i64 {
	if !mesh_identity_check(error) {
		return -1
	}
	uses, uses_known := remote.client_uses_of_word(uses_word)
	if !uses_known {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(uses_word), i64(remote.client_uses_word({.Calls, .View, .Input})))
	}
	mesh.pairing_uses = uses
	status := machine_mesh.pairing_join(&mesh.pairing, mesh.identity.public_key, code_text, system.time())
	if status != .Ok {
		return mesh_pairing_fail(error, status, 1)
	}
	return 0
}

// mesh_machine_list_update takes the wire bytes of a signed machine list.
// 0 when it is accepted, 1 when it is accepted with a machine that has no
// TPM attestation (the setting allowed it, and the window warns), or -1
// with an error record. revoked counts the rows that left at once.
mesh_machine_list_update :: proc "contextless" (wire: []u8, revoked: ^int, error: ^errors.Error_Record) -> i64 {
	if !mesh_identity_check(error) {
		return -1
	}
	if !mesh.has_principal {
		return errors.fail(error, -1, .Absent, .Principals, 0)
	}
	candidate, decode_status := machine_mesh.machine_list_decode(wire)
	if !machine_mesh.machine_list_status_accepted(decode_status) {
		return mesh_machine_list_fail(error, decode_status, 0)
	}
	status, revoked_count, _, not_added := machine_mesh.machine_list_holder_update(
		&mesh.machine_list,
		&mesh.paired,
		mesh.identity.public_key,
		&candidate,
		mesh.join_policy,
		mesh_signature_verify,
		system.time(),
	)
	if revoked != nil {
		revoked^ = revoked_count
	}
	if !machine_mesh.machine_list_status_accepted(status) {
		return mesh_machine_list_fail(error, status, candidate.sequence_number)
	}
	if not_added > 0 {
		// The list holds: its revocations took effect. A machine with no
		// free row is said, never dropped in silence.
		return errors.fail(error, -1, .Full, .Records, 1, i64(not_added), machine_mesh.MAX_PAIRED_MACHINES)
	}
	if status == .Accepted_Without_Tpm_Warning {
		return 1
	}
	return 0
}

// mesh_revocation_list_update takes a newer revocation list of the
// principal, signed by a machine of its newest machine list.
mesh_revocation_list_update :: proc "contextless" (candidate: ^machine_mesh.Revocation_List, error: ^errors.Error_Record) -> i64 {
	if candidate == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if !mesh.machine_list.has_list {
		return errors.fail(error, -1, .Absent, .Versions, 1)
	}
	status := machine_mesh.revocation_list_apply_update(
		&mesh.machine_list.list,
		&mesh.revocations,
		mesh.has_revocations,
		candidate,
		mesh_signature_verify,
	)
	switch status {
	case .Accepted:
		mesh.has_revocations = true
		return 0
	case .Refused_Invalid_Signature, .Refused_Wrong_Grantor, .Refused_Signer_Not_Active:
		return errors.fail(error, -1, .Not_Authentic, .None, 1, 0, 0, i64(status))
	case .Refused_Replay_Or_Downgrade:
		return errors.fail(error, -1, .Bad_Value, .Versions, 1, i64(candidate.epoch), 0, i64(mesh.revocations.epoch))
	case .Refused_Too_Many_Entries:
		return errors.fail(error, -1, .Too_Long, .Records, 1, i64(candidate.revoked_count), machine_mesh.MAX_REVOKED_GRANTS)
	case .Refused_Buffer_Too_Small:
		return errors.fail(error, -1, .Too_Small, .Bytes, 1)
	case .Refused_Nil_Input, .Refused_Zero_Key, .Refused_Zero_Epoch, .Refused_Zero_Serial, .Refused_Not_Strictly_Sorted:
		return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, i64(status))
	}
	return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, i64(status))
}

// mesh_grant_check checks the wire bytes of a signed grant that a principal
// of another machine presents to this machine, for the receiver root key
// that the handshake proved: signature against the newest machine list,
// this machine as the server, the receiver, a life of one day at most or
// the revocation list, and the time. 0, or -1 with an error record.
mesh_grant_check :: proc "contextless" (wire: []u8, grantee_root_public_key: [32]u8, error: ^errors.Error_Record) -> i64 {
	if !mesh_identity_check(error) {
		return -1
	}
	if !mesh.machine_list.has_list {
		return errors.fail(error, -1, .Absent, .Versions, 1)
	}
	grant, decode_status := machine_mesh.signed_grant_decode(wire)
	if decode_status != .Accepted {
		return mesh_grant_fail(error, decode_status, &grant, 0)
	}
	revocations: ^machine_mesh.Revocation_List = mesh.has_revocations ? &mesh.revocations : nil
	now := system.time()
	status := machine_mesh.signed_grant_check(
		&grant,
		&mesh.machine_list.list,
		mesh.identity.public_key,
		grantee_root_public_key,
		now,
		revocations,
		mesh_signature_verify,
	)
	if status != .Accepted {
		return mesh_grant_fail(error, status, &grant, now)
	}
	return 0
}

// mesh_partner_connection_end ends the exchanges of a paired machine whose
// connection closed: an offer that it left between two pages gives its
// pages back to the budget of remote, and the partner holds them no more.
// A key of no paired machine names no store, and ends nothing.
mesh_partner_connection_end :: proc "contextless" (partner: [32]u8) {
	machine_wire.store_exchange_partner_end(&mesh.stores, partner)
}

// mesh_object_accept keeps an object that a paired machine sent for a
// requested hash, only when its bytes hash to it. 0, or -1 with an error
// record.
mesh_object_accept :: proc "contextless" (
	peer_identity: [32]u8,
	kind_word: u64,
	requested_hash: blake3.Hash,
	payload: []u8,
	error: ^errors.Error_Record,
) -> i64 {
	if !mesh_identity_check(error) {
		return -1
	}
	if _, paired := machine_mesh.paired_machine_find(&mesh.paired, peer_identity); !paired {
		return errors.fail(error, -1, .Absent, .Records, 1)
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(kind_word)
	if !kind_ok {
		return errors.fail(error, -1, .Bad_Value, .None, 2, i64(kind_word))
	}
	// The bytes that the store takes for this object count in the share of
	// the partner that sent it (mesh_object_grow), as for an object that
	// comes in pieces.
	mesh_assembly_partner = peer_identity
	status := machine_sync.object_store_accept(&mesh.objects, kind, requested_hash, payload)
	switch status {
	case .Stored, .Already_Stored:
		return 0
	case .Refused_Hash_Mismatch:
		return errors.fail(error, -1, .Not_Authentic, .None, 4)
	case .Refused_Malformed:
		return errors.fail(error, -1, .Bad_Value, .None, 4, 0, 0, i64(status))
	case .Refused_Full:
		return errors.fail(error, -1, .Full, .Objects, 0, 0, i64(len(mesh.objects.objects)))
	case .Refused_Too_Large:
		return errors.fail(error, -1, .Too_Long, .Bytes, 4, i64(len(payload)), i64(len(mesh.objects.bytes) - mesh.objects.bytes_used))
	case .Refused_Nil_Input:
		return errors.fail(error, -1, .State, .None, 0)
	}
	return errors.fail(error, -1, .Bad_Value, .None, 0, 0, 0, i64(status))
}

// mesh_object_lookup gives the bytes of an object that this process kept.
mesh_object_lookup :: proc "contextless" (hash: blake3.Hash) -> (bytes: []u8, found: bool) {
	bytes, _, found = machine_sync.object_store_lookup(&mesh.objects, hash)
	return bytes, found
}

@(private = "file")
mesh_pairing_fail :: proc "contextless" (error: ^errors.Error_Record, status: machine_mesh.Pairing_Status, argument: i64) -> i64 {
	found := i64(status)
	switch status {
	case .Ok:
		return 0
	case .Refused_Nil_Input, .Refused_Bad_Phase:
		return errors.fail(error, -1, .State, .None, 0, 0, 0, i64(mesh.pairing.phase))
	case .Refused_Code_Expired:
		return errors.fail(error, -1, .Over_Limit, .Milliseconds, argument, 0, i64(machine_mesh.PAIRING_CODE_LIFETIME_MS))
	case .Refused_Spent_Ledger_Full:
		return errors.fail(error, -1, .Full, .Records, 0, 0, machine_mesh.MAX_SPENT_PAIRING_CODES)
	case .Refused_Table_Full:
		return errors.fail(error, -1, .Full, .Records, 0, 0, machine_mesh.MAX_PAIRED_MACHINES)
	case .Refused_Already_Paired:
		return errors.fail(error, -1, .Exists, .Records, argument)
	case .Refused_Peer_Key_Mismatch, .Refused_Exchange, .Refused_Confirmation_Failed:
		return errors.fail(error, -1, .Not_Authentic, .None, argument, 0, 0, found)
	case .Refused_Bad_Side, .Refused_Zero_Key, .Refused_Same_Machine, .Refused_Zero_Code, .Refused_Bad_Code_Text,
	     .Refused_Code_Spent, .Refused_Bad_Channel_Binding, .Refused_Bad_Uses:
		return errors.fail(error, -1, .Bad_Value, .None, argument, 0, 0, found)
	}
	return errors.fail(error, -1, .Bad_Value, .None, argument, 0, 0, found)
}

@(private = "file")
mesh_machine_list_fail :: proc "contextless" (error: ^errors.Error_Record, status: machine_mesh.Machine_List_Status, sequence_number: u64) -> i64 {
	found := i64(status)
	switch status {
	case .Accepted, .Accepted_Without_Tpm_Warning:
		return 0
	case .Refused_Invalid_Signature, .Refused_Root_Key_Mismatch:
		return errors.fail(error, -1, .Not_Authentic, .None, 1, 0, 0, found)
	case .Refused_Replay_Or_Downgrade:
		// The list of this machine is newer: value is the number of the
		// candidate, found the number that this machine holds.
		return errors.fail(error, -1, .Bad_Value, .Versions, 1, i64(sequence_number), 0, i64(mesh.machine_list.list.sequence_number))
	case .Refused_Without_Tpm:
		return errors.fail(error, -1, .No_Grant, .None, 1, 0, 0, found)
	case .Refused_Too_Many_Entries:
		return errors.fail(error, -1, .Too_Long, .Records, 1, 0, machine_mesh.MAX_MACHINE_LIST_ENTRIES)
	case .Refused_Buffer_Too_Small:
		return errors.fail(error, -1, .Too_Small, .Bytes, 1)
	case .Refused_Nil_Input, .Refused_Zero_Root_Key, .Refused_Zero_Sequence_Number, .Refused_Empty_List,
	     .Refused_Bad_Entry_State, .Refused_Zero_Key, .Refused_Duplicate_Machine_Id, .Refused_Duplicate_Signing_Key,
	     .Refused_Duplicate_Transport_Key, .Refused_Bad_Uses, .Refused_Bad_Timestamps, .Refused_Malformed_Wire:
		return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, found)
	}
	return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, found)
}

@(private = "file")
mesh_grant_fail :: proc "contextless" (error: ^errors.Error_Record, status: machine_mesh.Grant_Check_Status, grant: ^machine_mesh.Signed_Grant, now_ms: u64) -> i64 {
	found := i64(status)
	switch status {
	case .Accepted:
		return 0
	case .Refused_Expired:
		return errors.fail(error, -1, .Over_Limit, .Milliseconds, 1, i64(now_ms), i64(grant.expires_at_ms))
	case .Refused_Invalid_Signature, .Refused_Wrong_Grantor, .Refused_Grantor_Key_Not_Active, .Refused_Bad_Revocation_List:
		return errors.fail(error, -1, .Not_Authentic, .None, 1, 0, 0, found)
	case .Refused_Revoked, .Refused_Long_Grant_Without_Revocation, .Refused_Stale_Revocation_List, .Refused_Wrong_Grantee,
	     .Refused_Wrong_Serving_Machine, .Refused_Serving_Machine_Not_Active, .Refused_Not_Yet_Valid:
		return errors.fail(error, -1, .No_Grant, .Grants, 1, 0, 0, found)
	case .Refused_Buffer_Too_Small:
		return errors.fail(error, -1, .Too_Small, .Bytes, 1)
	case .Refused_Nil_Input, .Refused_Zero_Serial, .Refused_Zero_Key, .Refused_Zero_Target_Hash, .Refused_Bad_Target_Kind,
	     .Refused_Bad_Rights, .Refused_Bad_Lifetime, .Refused_Malformed_Wire:
		return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, found)
	}
	return errors.fail(error, -1, .Bad_Value, .None, 1, 0, 0, found)
}
