// Role start ranks and context-ring restart groups
// (src/md/features/supervision.md, "Start ranks" and "Restart groups").
//
// Validates that a role start-rank table is acyclic and that every role depends
// only on holders at strictly lower ranks. Computes the exact transitive
// restart group of processes that hold a context ring of a stopped holder,
// ordered ascending by start rank for restart by the root service.
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory.
package supervision

import "modus:contract/enum_word"
import "modus:contract/role_contract"

// Format property: covers all closed members of role_contract.Role inside one
// fixed stack table without heap allocation.
MAX_ROLE_RANK_ENTRIES :: 32

// Plan value: upper bound on discrete start ranks; the default boot plan uses
// ranks 1 through 6.
MAX_START_RANK :: u32(64)

// Plan value: upper bound on supervised processes evaluated in one restart
// group computation without heap allocation.
MAX_PROCESS_RING_DEPS :: 128

// Closed set of refusal reasons returned by start-rank table validation and
// restart-group collection. Zero means accepted.
Restart_Rank_Refusal :: enum u8 {
	None                      = 0,
	Empty_Table               = 1,
	Too_Many_Entries          = 2,
	Unknown_Role              = 3,
	Duplicate_Role            = 4,
	Zero_Rank                 = 5,
	Rank_Past_Bound           = 6,
	Unknown_Dependency_Bit    = 7,
	Self_Dependency           = 8,
	Missing_Dependency_Role   = 9,
	Cycle_Detected            = 10,
	Dependency_Rank_Not_Lower = 11,
	Bad_Process_Slot          = 12,
	Duplicate_Process_Slot    = 13,
	Output_Too_Small          = 14,
}

// One role entry in a start-rank table. Bit u64(r) set in dependency_mask means
// this role depends on role_contract.Role(r).
Role_Rank_Entry :: struct {
	role_word:       u64,
	rank:            u32,
	dependency_mask: u64,
}

// Context-ring dependency snapshot for one running process. role_word is 0 for
// an ordinary non-role process or a valid role_contract.Role word for a role
// holder. Bit u64(r) set in context_ring_roles means this process holds a
// context ring connected to the holder of role_contract.Role(r).
Process_Ring_Dependency :: struct {
	process_slot:       u32,
	role_word:          u64,
	rank:               u32,
	context_ring_roles: u64,
}

// One process included in a restart group, returned in strict ascending start
// rank order.
Restart_Group_Member :: struct {
	process_slot: u32,
	role:         role_contract.Role,
	rank:         u32,
}

// restart_rank_refusal_from_word converts a raw transport word into a
// Restart_Rank_Refusal, refusing every unknown word.
restart_rank_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Restart_Rank_Refusal, ok: bool) {
	return enum_word.member_of_word(Restart_Rank_Refusal, word)
}

// role_rank_bit returns the bit position of a non-None Role inside a 64-bit
// role dependency mask, or 0 for None.
role_rank_bit :: proc "contextless" (role: role_contract.Role) -> u64 {
	if role == .None {
		return 0
	}
	return u64(1) << u64(role)
}

// known_role_bits returns the bitmask of every closed non-None Role member.
@(private = "file")
known_role_bits :: proc "contextless" () -> u64 {
	mask: u64 = 0
	for member in role_contract.Role {
		if member != .None {
			mask |= u64(1) << u64(member)
		}
	}
	return mask
}

// role_rank_entry_index finds the index of a Role inside entries, or -1 if
// absent.
@(private = "file")
role_rank_entry_index :: proc "contextless" (roles: []role_contract.Role, target: role_contract.Role) -> int {
	for member, index in roles {
		if member == target {
			return index
		}
	}
	return -1
}

// role_rank_has_cycle runs an iterative three-color depth-first search over the
// validated dependency graph so cycles are detected with bounded stack space
// and zero recursion.
@(private = "file")
role_rank_has_cycle :: proc "contextless" (
	count: int,
	roles: []role_contract.Role,
	masks: []u64,
) -> bool {
	// 0 = unvisited, 1 = on active path, 2 = completed.
	color: [MAX_ROLE_RANK_ENTRIES]u8
	stack_node: [MAX_ROLE_RANK_ENTRIES]int
	stack_next_role: [MAX_ROLE_RANK_ENTRIES]u64

	for start in 0 ..< count {
		if color[start] != 0 {
			continue
		}
		depth := 0
		stack_node[0] = start
		stack_next_role[0] = 1
		color[start] = 1
		depth = 1

		for depth > 0 {
			top := depth - 1
			node := stack_node[top]
			mask := masks[node]
			advanced := false

			for bit := stack_next_role[top]; bit < 64; bit += 1 {
				if (mask & (u64(1) << bit)) == 0 {
					continue
				}
				stack_next_role[top] = bit + 1
				dep_role, dep_ok := role_contract.role_from_word(bit)
				if !dep_ok {
					continue
				}
				dep_index := role_rank_entry_index(roles[:count], dep_role)
				if dep_index < 0 {
					continue
				}
				if color[dep_index] == 1 {
					return true
				}
				if color[dep_index] == 0 {
					color[dep_index] = 1
					stack_node[depth] = dep_index
					stack_next_role[depth] = 1
					depth += 1
					advanced = true
					break
				}
			}

			if !advanced {
				color[node] = 2
				depth -= 1
			}
		}
	}
	return false
}

// role_rank_table_validate checks a start-rank table at the border. It refuses
// empty or over-capacity tables, zero or unknown role words, duplicate roles,
// zero or out-of-bound ranks, unknown dependency bits, self-dependencies,
// dependencies on roles absent from the table, dependency cycles, and any
// dependency on a role with an equal or higher start rank.
role_rank_table_validate :: proc "contextless" (entries: []Role_Rank_Entry) -> (refusal: Restart_Rank_Refusal, bad_index: u32) {
	if len(entries) == 0 {
		return .Empty_Table, 0
	}
	if len(entries) > MAX_ROLE_RANK_ENTRIES {
		return .Too_Many_Entries, u32(MAX_ROLE_RANK_ENTRIES)
	}

	known_mask := known_role_bits()
	parsed_roles: [MAX_ROLE_RANK_ENTRIES]role_contract.Role
	parsed_masks: [MAX_ROLE_RANK_ENTRIES]u64
	present_mask: u64 = 0

	for entry, index in entries {
		role, role_ok := role_contract.role_from_word(entry.role_word)
		if !role_ok {
			return .Unknown_Role, u32(index)
		}
		bit := role_rank_bit(role)
		if (present_mask & bit) != 0 {
			return .Duplicate_Role, u32(index)
		}
		if entry.rank == 0 {
			return .Zero_Rank, u32(index)
		}
		if entry.rank > MAX_START_RANK {
			return .Rank_Past_Bound, u32(index)
		}
		if (entry.dependency_mask & ~known_mask) != 0 {
			return .Unknown_Dependency_Bit, u32(index)
		}
		if (entry.dependency_mask & bit) != 0 {
			return .Self_Dependency, u32(index)
		}
		present_mask |= bit
		parsed_roles[index] = role
		parsed_masks[index] = entry.dependency_mask
	}

	for entry, index in entries {
		if (entry.dependency_mask & ~present_mask) != 0 {
			return .Missing_Dependency_Role, u32(index)
		}
	}

	if role_rank_has_cycle(len(entries), parsed_roles[:], parsed_masks[:]) {
		return .Cycle_Detected, 0
	}

	for entry, index in entries {
		mask := entry.dependency_mask
		for dep_index in 0 ..< len(entries) {
			dep_bit := role_rank_bit(parsed_roles[dep_index])
			if (mask & dep_bit) == 0 {
				continue
			}
			if entries[dep_index].rank >= entry.rank {
				return .Dependency_Rank_Not_Lower, u32(index)
			}
		}
	}

	return .None, 0
}

// member_comes_before defines the strict deterministic restart order: ascending
// start rank, then ascending role word, then ascending process slot.
@(private = "file")
member_comes_before :: proc "contextless" (left, right: Restart_Group_Member) -> bool {
	if left.rank != right.rank {
		return left.rank < right.rank
	}
	if left.role != right.role {
		return u64(left.role) < u64(right.role)
	}
	return left.process_slot < right.process_slot
}

// restart_group_collect computes the exact transitive set of processes that
// hold a context ring of stopped_role (directly or through another affected
// role holder) and writes them into out_group in ascending start-rank order.
// Any refusal leaves out_group untouched.
restart_group_collect :: proc "contextless" (
	stopped_role: role_contract.Role,
	process_ring_deps: []Process_Ring_Dependency,
	out_group: []Restart_Group_Member,
) -> (count: int, refusal: Restart_Rank_Refusal) {
	valid_stopped, stopped_ok := role_contract.role_from_word(u64(stopped_role))
	if !stopped_ok {
		return 0, .Unknown_Role
	}
	if len(process_ring_deps) > MAX_PROCESS_RING_DEPS {
		return 0, .Too_Many_Entries
	}

	known_mask := known_role_bits()
	parsed_roles: [MAX_PROCESS_RING_DEPS]role_contract.Role

	for dep, index in process_ring_deps {
		if dep.process_slot == 0 {
			return 0, .Bad_Process_Slot
		}
		for earlier in 0 ..< index {
			if process_ring_deps[earlier].process_slot == dep.process_slot {
				return 0, .Duplicate_Process_Slot
			}
		}
		if dep.rank == 0 {
			return 0, .Zero_Rank
		}
		if dep.rank > MAX_START_RANK {
			return 0, .Rank_Past_Bound
		}
		if (dep.context_ring_roles & ~known_mask) != 0 {
			return 0, .Unknown_Dependency_Bit
		}
		if dep.role_word != 0 {
			parsed_role, role_ok := role_contract.role_from_word(dep.role_word)
			if !role_ok {
				return 0, .Unknown_Role
			}
			if (dep.context_ring_roles & role_rank_bit(parsed_role)) != 0 {
				return 0, .Self_Dependency
			}
			parsed_roles[index] = parsed_role
		} else {
			parsed_roles[index] = .None
		}
	}

	affected_roles := role_rank_bit(valid_stopped)
	included: [MAX_PROCESS_RING_DEPS]bool
	total := 0

	for _ in 0 ..= len(process_ring_deps) {
		changed := false
		for dep, index in process_ring_deps {
			if included[index] {
				continue
			}
			holds_affected_role := parsed_roles[index] != .None && (role_rank_bit(parsed_roles[index]) & affected_roles) != 0
			holds_affected_ring := (dep.context_ring_roles & affected_roles) != 0
			if holds_affected_role || holds_affected_ring {
				included[index] = true
				total += 1
				if parsed_roles[index] != .None {
					affected_roles |= role_rank_bit(parsed_roles[index])
				}
				changed = true
			}
		}
		if !changed {
			break
		}
	}

	if total > len(out_group) {
		return 0, .Output_Too_Small
	}

	written := 0
	for dep, index in process_ring_deps {
		if !included[index] {
			continue
		}
		out_group[written] = Restart_Group_Member {
			process_slot = dep.process_slot,
			role         = parsed_roles[index],
			rank         = dep.rank,
		}
		written += 1
	}

	for index in 1 ..< written {
		current := out_group[index]
		position := index
		for position > 0 && member_comes_before(current, out_group[position - 1]) {
			out_group[position] = out_group[position - 1]
			position -= 1
		}
		out_group[position] = current
	}

	return written, .None
}
