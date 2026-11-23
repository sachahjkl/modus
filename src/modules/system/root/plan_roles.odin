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
import module "modus:contract/module"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
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
	case .None:
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
	system.log_fact(.Info, Plan_Roles_Replaced{generation = role_override_names.generation, serial = role_override_names.serial, overrides = plan_roles_copy.override_count, rollback = step == .Rollback ? 1 : 0})
	answer^ = {0 = role_override_names.serial, 1 = role_override_names.generation}
	return .Ok
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
	file := image_file_checked(module_name)
	if module.validate(file) != .None {
		return false
	}
	contract, known := rd.role_contract_by_role(role)
	hash, hashed := rd.role_contract_hash_by_role(role)
	if !known || !hashed {
		return false
	}
	ring_faces: [PLAN_ROLE_RING_FACE_CAPACITY]role_contract.Required_Ring_Face
	ring_face_count := 0
	for &face in contract.faces {
		if face.kind != .Ring {
			continue
		}
		if ring_face_count == len(ring_faces) {
			return false
		}
		ring_faces[ring_face_count] = face.ring_face
		ring_face_count += 1
	}
	hashes := [1]role_contract.Contract_Hash{hash}
	declaration := role_contract.Module_Role_Declaration{contract_hashes = hashes[:], ring_faces = ring_faces[:ring_face_count]}
	return role_contract.module_fills_contract(file, declaration, contract).refusal == .None
}
