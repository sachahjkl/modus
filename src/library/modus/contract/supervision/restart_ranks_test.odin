#+build !freestanding
#+build !modus
package supervision

import "core:testing"
import "modus:contract/role_contract"

@(test)
test_restart_rank_refusal_border_parser :: proc(t: ^testing.T) {
	if _, ok := restart_rank_refusal_from_word(u64(max(Restart_Rank_Refusal)) + 1); ok {
		testing.fail_now(t, "restart_rank_refusal_from_word accepted one past last member")
	}
	if _, ok := restart_rank_refusal_from_word(max(u64)); ok {
		testing.fail_now(t, "restart_rank_refusal_from_word accepted max(u64)")
	}
	for expected in Restart_Rank_Refusal {
		parsed, ok := restart_rank_refusal_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}
}

@(test)
test_role_rank_table_validate_refuses_every_bad_edge :: proc(t: ^testing.T) {
	// Empty table refused.
	{
		empty: []Role_Rank_Entry = nil
		refusal, _ := role_rank_table_validate(empty)
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Empty_Table)
	}

	// Over-capacity table refused.
	{
		too_many: [MAX_ROLE_RANK_ENTRIES + 1]Role_Rank_Entry
		refusal, bad_idx := role_rank_table_validate(too_many[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Too_Many_Entries)
		testing.expect_value(t, bad_idx, u32(MAX_ROLE_RANK_ENTRIES))
	}

	// Zero and unknown role words refused.
	{
		zero_role := [?]Role_Rank_Entry{{role_word = 0, rank = 1, dependency_mask = 0}}
		refusal, bad_idx := role_rank_table_validate(zero_role[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Role)
		testing.expect_value(t, bad_idx, u32(0))

		unknown_role := [?]Role_Rank_Entry{{role_word = u64(max(role_contract.Role)) + 1, rank = 1, dependency_mask = 0}}
		refusal, bad_idx = role_rank_table_validate(unknown_role[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Role)
		testing.expect_value(t, bad_idx, u32(0))

		max_role := [?]Role_Rank_Entry{{role_word = max(u64), rank = 1, dependency_mask = 0}}
		refusal, _ = role_rank_table_validate(max_role[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Role)
	}

	// Duplicate role refused.
	{
		dup := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Block_Device), rank = 1, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Block_Device), rank = 2, dependency_mask = 0},
		}
		refusal, bad_idx := role_rank_table_validate(dup[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Duplicate_Role)
		testing.expect_value(t, bad_idx, u32(1))
	}

	// Zero rank and rank past bound refused.
	{
		zero_rank := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Block_Device), rank = 0, dependency_mask = 0}}
		refusal, _ := role_rank_table_validate(zero_rank[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Zero_Rank)

		past_rank := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Block_Device), rank = MAX_START_RANK + 1, dependency_mask = 0}}
		refusal, _ = role_rank_table_validate(past_rank[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Rank_Past_Bound)
	}

	// Unknown dependency bit (bit 0 or bit past max Role) refused.
	{
		bit_zero := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = 1}}
		refusal, _ := role_rank_table_validate(bit_zero[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Dependency_Bit)

		high_bit := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = u64(1) << 63}}
		refusal, _ = role_rank_table_validate(high_bit[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Dependency_Bit)
	}

	// Self-dependency refused.
	{
		self_dep := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Storage)}}
		refusal, _ := role_rank_table_validate(self_dep[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Self_Dependency)
	}

	// Dependency on role absent from table refused.
	{
		missing_dep := [?]Role_Rank_Entry{{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Block_Device)}}
		refusal, _ := role_rank_table_validate(missing_dep[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Missing_Dependency_Role)
	}

	// Two-node cycle and three-node cycle refused.
	{
		two_cycle := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Plans)},
			{role_word = u64(role_contract.Role.Plans), rank = 3, dependency_mask = role_rank_bit(.Storage)},
		}
		refusal, _ := role_rank_table_validate(two_cycle[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Cycle_Detected)

		three_cycle := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Block_Device), rank = 1, dependency_mask = role_rank_bit(.Plans)},
			{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Block_Device)},
			{role_word = u64(role_contract.Role.Plans), rank = 3, dependency_mask = role_rank_bit(.Storage)},
		}
		refusal, _ = role_rank_table_validate(three_cycle[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Cycle_Detected)
	}

	// Equal-rank dependency and later-rank dependency refused.
	{
		equal_rank := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Block_Device), rank = 2, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Block_Device)},
		}
		refusal, bad_idx := role_rank_table_validate(equal_rank[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Dependency_Rank_Not_Lower)
		testing.expect_value(t, bad_idx, u32(1))

		higher_rank := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Block_Device), rank = 3, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Block_Device)},
		}
		refusal, bad_idx = role_rank_table_validate(higher_rank[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Dependency_Rank_Not_Lower)
		testing.expect_value(t, bad_idx, u32(1))
	}

	// Accepted six-rank system table.
	{
		table := [?]Role_Rank_Entry {
			{role_word = u64(role_contract.Role.Block_Device), rank = 1, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Network_Device), rank = 1, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Storage), rank = 2, dependency_mask = role_rank_bit(.Block_Device)},
			{role_word = u64(role_contract.Role.Network), rank = 2, dependency_mask = role_rank_bit(.Network_Device)},
			{role_word = u64(role_contract.Role.Plans), rank = 3, dependency_mask = role_rank_bit(.Storage)},
			{role_word = u64(role_contract.Role.Display), rank = 4, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Input), rank = 4, dependency_mask = 0},
			{role_word = u64(role_contract.Role.Powerbox), rank = 5, dependency_mask = role_rank_bit(.Display) | role_rank_bit(.Storage)},
			{role_word = u64(role_contract.Role.Console), rank = 6, dependency_mask = role_rank_bit(.Display) | role_rank_bit(.Powerbox)},
		}
		refusal, bad_idx := role_rank_table_validate(table[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.None)
		testing.expect_value(t, bad_idx, u32(0))
	}
}

@(test)
test_restart_group_collect_refuses_bad_inputs_and_orders_transitive_group :: proc(t: ^testing.T) {
	// Unknown stopped role refused.
	{
		out: [4]Restart_Group_Member
		count, refusal := restart_group_collect(.None, nil, out[:])
		testing.expect_value(t, count, 0)
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Role)
	}

	// Zero process slot, duplicate slot, zero rank, unknown role, unknown bit, self-ring refused.
	{
		out: [4]Restart_Group_Member
		bad_slot := [?]Process_Ring_Dependency{{process_slot = 0, role_word = u64(role_contract.Role.Input), rank = 4}}
		_, refusal := restart_group_collect(.Input, bad_slot[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Bad_Process_Slot)

		dup_slot := [?]Process_Ring_Dependency {
			{process_slot = 5, role_word = u64(role_contract.Role.Input), rank = 4},
			{process_slot = 5, role_word = u64(role_contract.Role.Display), rank = 4},
		}
		_, refusal = restart_group_collect(.Input, dup_slot[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Duplicate_Process_Slot)

		zero_rank := [?]Process_Ring_Dependency{{process_slot = 5, role_word = u64(role_contract.Role.Input), rank = 0}}
		_, refusal = restart_group_collect(.Input, zero_rank[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Zero_Rank)

		bad_role := [?]Process_Ring_Dependency{{process_slot = 5, role_word = 999, rank = 4}}
		_, refusal = restart_group_collect(.Input, bad_role[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Role)

		bad_ring_bit := [?]Process_Ring_Dependency{{process_slot = 5, role_word = 0, rank = 6, context_ring_roles = 1}}
		_, refusal = restart_group_collect(.Input, bad_ring_bit[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Unknown_Dependency_Bit)

		self_ring := [?]Process_Ring_Dependency{{process_slot = 5, role_word = u64(role_contract.Role.Storage), rank = 2, context_ring_roles = role_rank_bit(.Storage)}}
		_, refusal = restart_group_collect(.Storage, self_ring[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Self_Dependency)
	}

	// Transitive closure over 3 hops: Block_Device -> Storage -> Plans -> ordinary client,
	// while unrelated Network_Device and Network stay outside the restart group.
	deps := [?]Process_Ring_Dependency {
		{process_slot = 50, role_word = 0, rank = 6, context_ring_roles = role_rank_bit(.Plans)},
		{process_slot = 40, role_word = u64(role_contract.Role.Plans), rank = 3, context_ring_roles = role_rank_bit(.Storage)},
		{process_slot = 30, role_word = u64(role_contract.Role.Network), rank = 2, context_ring_roles = role_rank_bit(.Network_Device)},
		{process_slot = 20, role_word = u64(role_contract.Role.Storage), rank = 2, context_ring_roles = role_rank_bit(.Block_Device)},
		{process_slot = 10, role_word = u64(role_contract.Role.Block_Device), rank = 1, context_ring_roles = 0},
		{process_slot = 11, role_word = u64(role_contract.Role.Network_Device), rank = 1, context_ring_roles = 0},
		{process_slot = 60, role_word = u64(role_contract.Role.Input), rank = 4, context_ring_roles = 0},
	}

	// Short output buffer refused without mutating sentinel element.
	{
		short_out: [3]Restart_Group_Member
		short_out[0].process_slot = 777
		count, refusal := restart_group_collect(.Block_Device, deps[:], short_out[:])
		testing.expect_value(t, count, 0)
		testing.expect_value(t, refusal, Restart_Rank_Refusal.Output_Too_Small)
		testing.expect_value(t, short_out[0].process_slot, u32(777))
	}

	// Full restart group sorted ascending by rank: Block_Device (1), Storage (2), Plans (3), client (6).
	{
		out: [8]Restart_Group_Member
		count, refusal := restart_group_collect(.Block_Device, deps[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.None)
		testing.expect_value(t, count, 4)
		testing.expect_value(t, out[0].process_slot, u32(10))
		testing.expect_value(t, out[0].role, role_contract.Role.Block_Device)
		testing.expect_value(t, out[0].rank, u32(1))
		testing.expect_value(t, out[1].process_slot, u32(20))
		testing.expect_value(t, out[1].role, role_contract.Role.Storage)
		testing.expect_value(t, out[1].rank, u32(2))
		testing.expect_value(t, out[2].process_slot, u32(40))
		testing.expect_value(t, out[2].role, role_contract.Role.Plans)
		testing.expect_value(t, out[2].rank, u32(3))
		testing.expect_value(t, out[3].process_slot, u32(50))
		testing.expect_value(t, out[3].role, role_contract.Role.None)
		testing.expect_value(t, out[3].rank, u32(6))
	}

	// Input stops alone when no other process holds its context ring.
	{
		out: [4]Restart_Group_Member
		count, refusal := restart_group_collect(.Input, deps[:], out[:])
		testing.expect_value(t, refusal, Restart_Rank_Refusal.None)
		testing.expect_value(t, count, 1)
		testing.expect_value(t, out[0].process_slot, u32(60))
		testing.expect_value(t, out[0].role, role_contract.Role.Input)
	}
}
