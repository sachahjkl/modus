package root

// The roles of the plan of principal 0, which the holder of Plans gives
// with the command Plan_Roles (modus:contract/root_ring;
// src/md/features/declarations.md, "Apply, the difference and the
// rollback").
//
// The core makes the roles page once and lends it to the holder of Plans.
// The holder writes there the whole set of the overrides of the generation
// that the principal accepted, or of the generation that a rollback goes
// back to. The core copies the set once, checks it whole, and replaces its
// overrides in one step (role_policy.holder_overrides_replace): the core
// never runs with a part of a plan. A holder that started before the
// change keeps running; a new start or a new connection reaches the new
// holder.

import "base:intrinsics"
import "internal:root/role_policy"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:system"

// The bytes behind the overrides of role_holder_names.
role_override_names: role_policy.Override_Names

// The roles page: the handle of the core, and its mapping.
plan_roles_memory: system.Handle
plan_roles_page: ^rd.Plan_Roles_Set

// The copy of the set that the core checks: the holder can write the page
// meanwhile.
plan_roles_copy: rd.Plan_Roles_Set

// plan_roles_command runs Plan_Roles for its one sender, the process with
// the start grant Plans.
plan_roles_command :: proc "contextless" (item: ^Started, values: [7]u64, answer: ^[7]u64) -> system.Status {
	step, step_known := rd.plan_roles_step_of_word(values[0])
	if !step_known {
		answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Bad_Value, .None, 1, i64(min(values[0], u64(max(i64)))), i64(max(rd.Plan_Roles_Step)))
		return .Bad_Operation
	}
	// values[1] of Loaded is its outcome; each other word is 0.
	first_zero := step == .Loaded ? 2 : 1
	for index in first_zero ..< len(values) {
		if values[index] != 0 {
			answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Bad_Value, .None, i64(index + 1), i64(min(values[index], u64(max(i64)))), 0)
			return .Bad_Operation
		}
	}
	switch step {
	case .None, .Committed:
		// plan_roles_step_of_word refuses None; Committed is a step of
		// Plan_Values only: a set of roles is in force from its answer.
		answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Bad_Value, .None, 1, i64(step), i64(rd.Plan_Roles_Step.Loaded))
		return .Bad_Operation
	case .Page:
		status := plan_roles_page_give(item, answer)
		if status != .Ok {
			answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Refused, .None, 0, 0, 0, i64(status))
		}
		return status
	case .Loaded:
		outcome, outcome_known := rd.plan_roles_load_outcome_of_word(values[1])
		if !outcome_known {
			answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Bad_Value, .None, 2, i64(min(values[1], u64(max(i64)))), i64(max(rd.Plan_Roles_Load_Outcome)))
			return .Bad_Operation
		}
		plan_at_start_loaded(outcome)
		answer^ = {0 = role_override_names.serial, 1 = role_override_names.generation}
		return .Ok
	case .Apply, .Rollback:
	}
	if plan_roles_page == nil {
		answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .State, .Requests)
		return .Bad_State
	}
	intrinsics.mem_copy_non_overlapping(&plan_roles_copy, plan_roles_page, size_of(rd.Plan_Roles_Set))
	// The grant of each connection before the change: the roles of its two
	// sides give its amount (grant_for).
	plan_roles_saved = role_override_names
	grants_change_begin()
	resolver := role_policy.Holder_Resolver {
		name_of_hash = plan_role_module_of_hash,
		fills        = plan_role_module_fills,
	}
	refusal, index := role_policy.holder_overrides_replace(&role_holder_names, &role_override_names, &plan_roles_copy, step, resolver)
	if refusal != .None {
		system.log_fact(.Warning, Plan_Roles_Refused{refusal_code = u64(refusal), override_index = u64(index), generation = plan_roles_copy.generation, serial = role_override_names.serial})
		answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Refused, .Records, i64(index + 1), 0, 0, i64(refusal))
		return .Bad_State
	}
	// Each grant that the change changed is written again, and only when
	// each service ring has room for its grants: else the change is undone
	// whole, and no connection keeps the trust of a role that its caller
	// lost (role_policy.grants_room_short).
	if !grants_change_room() {
		role_policy.holder_overrides_restore(&role_holder_names, &role_override_names, &plan_roles_saved)
		system.log_fact(.Warning, Plan_Roles_Refused{refusal_code = u64(rd.Plan_Roles_Refusal.Grants_Busy), override_index = 0, generation = plan_roles_copy.generation, serial = role_override_names.serial})
		answer^ = errors.ring_fail(u32(root_ring.Root_Command.Plan_Roles), .Refused, .Records, 0, 0, 0, i64(rd.Plan_Roles_Refusal.Grants_Busy))
		return .Bad_State
	}
	grants_change_send()
	system.log_fact(.Info, Plan_Roles_Replaced{generation = role_override_names.generation, serial = role_override_names.serial, overrides = plan_roles_copy.override_count, rollback = step == .Rollback ? 1 : 0})
	answer^ = {0 = role_override_names.serial, 1 = role_override_names.generation}
	return .Ok
}

// The overrides before a change of the roles.
plan_roles_saved: role_policy.Override_Names

// The grant of each connection before a change of the roles or of the plan
// values, by the place of the connection.
grants_change_before: [CONNECTION_CAPACITY]u64

// The services whose ring takes a grant of the change, and the count of
// their grants: at most one service for each connection.
grants_change_services: [CONNECTION_CAPACITY]^Started
grants_change_counts: [CONNECTION_CAPACITY]u32
grants_change_rooms: [CONNECTION_CAPACITY]u32

// grants_change_begin keeps the grant of each connection before a change:
// the roles of its two sides and the quota of a store give its amount
// (grant_for).
grants_change_begin :: proc "contextless" () {
	for &connection, index in connections {
		grants_change_before[index] = connection.caller == nil ? 0 : connection_grant(&connection)
	}
}

// grants_change_room counts, for each service ring, the grants that the
// change changed, and says if each ring has room for them.
grants_change_room :: proc "contextless" () -> bool {
	service_count := 0
	for &connection, index in connections {
		if connection.caller == nil || connection_grant(&connection) == grants_change_before[index] {
			continue
		}
		place := 0
		for place < service_count && grants_change_services[place] != connection.service {
			place += 1
		}
		if place == service_count {
			commands := &connection.service.service.commands
			grants_change_services[place] = connection.service
			grants_change_counts[place] = 0
			grants_change_rooms[place] = ring.capacity(commands) - ring.count(commands)
			service_count += 1
		}
		grants_change_counts[place] += 1
	}
	short, _ := role_policy.grants_room_short(grants_change_counts[:service_count], grants_change_rooms[:service_count])
	return !short
}

// grants_change_send writes again each grant that the change changed: the
// amount of a connection to the holder of Storage or of Display whose side
// moved, the connections of a module that lost or took the role Plans, and
// the quota of a store that the plan values changed. The room was checked,
// and this service is the one writer of a service ring.
grants_change_send :: proc "contextless" () {
	for &connection, index in connections {
		if connection.caller == nil {
			continue
		}
		grant := connection_grant(&connection)
		if grant == grants_change_before[index] {
			continue
		}
		_ = system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = grant}})
	}
}

// plan_roles_page_give makes the roles page at its first use, and gives
// the sender a handle of it with Read and Write. The core keeps its own
// handle: a revocation by the sender does not reach it.
@(private = "file")
plan_roles_page_give :: proc "contextless" (item: ^Started, answer: ^[7]u64) -> system.Status {
	if plan_roles_memory == 0 {
		memory, status := system.memory_create(1)
		if status != .Ok {
			return status
		}
		address, map_status := system.memory_map(memory, {.Write})
		if map_status != .Ok {
			system.close(memory)
			return map_status
		}
		plan_roles_memory = memory
		plan_roles_page = (^rd.Plan_Roles_Set)(address)
	}
	given, status := system.give(item.requests_memory, plan_roles_memory, {.Read, .Write})
	if status != .Ok {
		return status
	}
	answer^ = {0 = u64(given), 1 = role_override_names.serial, 2 = role_override_names.generation}
	return .Ok
}

// plan_role_module_of_hash gives the name of the module of the boot image
// with a hash. A plan names a holder by its hash: a name gives nothing.
@(private = "file")
plan_role_module_of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool) {
	entry := system.image_entry_of(image, hash)
	if entry == nil {
		return "", false
	}
	return system.name_of(entry.name[:]), true
}

// role_contract_hashes_log writes one hash of the role contracts once, at
// the start: a contract that this process reads in another form than the
// host (data that a machine does not initialize as the host does) gives
// another digest, and the check of the tool sees it before a plan names a
// holder.
role_contract_hashes_log :: proc "contextless" () {
	digest, contracts, encoded := rd.role_contracts_digest()
	system.log_fact(.Info, Role_Contracts_Digest{contracts = contracts, encoded = encoded, digest = value_kinds.Hash_Field(digest)})
}

// The most ring faces of one role contract that the check below names.
PLAN_ROLE_RING_FACE_CAPACITY :: 8

// plan_role_module_fills says if a module of the boot image fills the
// contract of a role, as far as its file shows: each export and each record
// stream that the contract requires, with its signature. A file declares no
// contract and no ring: the declaration names the contract and the ring
// faces of the contract, and the conformance suite of the role checks the
// protocol of each ring.
@(private = "file")
plan_role_module_fills :: proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool {
	// The file comes through the table of the checked entries of the image;
	// module_fills_contract validates it first: a file that does not pass
	// gives Malformed_Module, with its line below.
	file := image_file_checked(module_name)
	contract, known := rd.role_contract_by_role(role)
	hash, hashed := rd.role_contract_hash_by_role(role)
	if !known || !hashed {
		system.log_fact(.Warning, Plan_Role_Contract_Not_Filled{role_code = u64(role), refusal_code = u64(role_contract.Contract_Check_Refusal.Malformed_Contract), holder = module_name_field(module_name)})
		return false
	}
	ring_faces: [PLAN_ROLE_RING_FACE_CAPACITY]role_contract.Required_Ring_Face
	ring_face_count := 0
	for &face in contract.faces {
		if face.kind != .Ring {
			continue
		}
		if ring_face_count == len(ring_faces) {
			system.log_fact(.Warning, Plan_Role_Contract_Not_Filled{role_code = u64(role), refusal_code = u64(role_contract.Contract_Check_Refusal.Malformed_Contract), holder = module_name_field(module_name)})
			return false
		}
		ring_faces[ring_face_count] = face.ring_face
		ring_face_count += 1
	}
	hashes := [1]role_contract.Contract_Hash{hash}
	declaration := role_contract.Module_Role_Declaration{contract_hashes = hashes[:], ring_faces = ring_faces[:ring_face_count]}
	result := role_contract.module_fills_contract(file, declaration, contract)
	if result.refusal != .None {
		system.log_fact(.Warning, Plan_Role_Contract_Not_Filled{role_code = u64(role), refusal_code = u64(result.refusal), difference_code = u64(result.difference), face = u64(result.face_index), export = u64(result.export_index), parameter = u64(result.parameter), holder = module_name_field(module_name)})
	}
	return result.refusal == .None
}
