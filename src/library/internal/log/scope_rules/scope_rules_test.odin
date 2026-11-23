#+build !freestanding
package scope_rules

import "core:testing"
import "modus:contract/log_scope"
import "modus:principals"

@(test)
root_fact_resets_when_first_part_is_lost_or_mismatched :: proc(t: ^testing.T) {
	state: Root_Fact

	// Refusal first: continuation part with no open first part gives No_Principal.
	p, d := root_fact_step(&state, true, 0x1111, 1, 2, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect_value(t, p, u64(0))
	testing.expect(t, !state.open)

	// Edge: continuation part 255 with part_count 0 or 255 while closed.
	_, d = root_fact_step(&state, true, 0x1111, 255, 0, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	_, d = root_fact_step(&state, true, 0x1111, 255, 255, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)

	// Open a 3-part fact for principal 1, then lose a record before part 1:
	// root_fact_reset closes the fact so the remaining parts get No_Principal.
	p, d = root_fact_step(&state, true, 0xAAAA, 0, 3, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, state.open)

	root_fact_reset(&state)
	testing.expect(t, !state.open)

	p, d = root_fact_step(&state, true, 0xAAAA, 1, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect_value(t, p, u64(0))
	p, d = root_fact_step(&state, true, 0xAAAA, 2, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect_value(t, p, u64(0))

	// A non-fact record between parts resets the open fact.
	p, d = root_fact_step(&state, true, 0xBBBB, 0, 2, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	p, d = root_fact_step(&state, false, 0, 0, 0, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, principals.MACHINE)
	testing.expect(t, !state.open)
	_, d = root_fact_step(&state, true, 0xBBBB, 1, 2, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)

	// Mismatched key, skipped part, or mismatched part_count resets and refuses.
	_, _ = root_fact_step(&state, true, 0xCCCC, 0, 3, 1)
	_, d = root_fact_step(&state, true, 0xDDDD, 1, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect(t, !state.open)

	_, _ = root_fact_step(&state, true, 0xCCCC, 0, 3, 1)
	_, d = root_fact_step(&state, true, 0xCCCC, 2, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect(t, !state.open)

	_, _ = root_fact_step(&state, true, 0xCCCC, 0, 3, 1)
	_, d = root_fact_step(&state, true, 0xCCCC, 1, 4, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
	testing.expect(t, !state.open)

	// Out-of-range principal on part 0 falls back to Machine.
	p, d = root_fact_step(&state, true, 0xEEEE, 0, 2, principals.PRINCIPAL_CAPACITY)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, principals.MACHINE)
	p, d = root_fact_step(&state, true, 0xEEEE, 1, 2, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, principals.MACHINE)
	testing.expect(t, !state.open)

	// Single-part and zero-part-count facts do not stay open.
	p, d = root_fact_step(&state, true, 0x1234, 0, 1, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, !state.open)
	p, d = root_fact_step(&state, true, 0x1235, 0, 0, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, !state.open)

	// Valid 3-part fact settles all 3 parts to principal 1 and closes after part 2.
	p, d = root_fact_step(&state, true, 0x5678, 0, 3, 1)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, state.open)
	p, d = root_fact_step(&state, true, 0x5678, 1, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, state.open)
	p, d = root_fact_step(&state, true, 0x5678, 2, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.Known)
	testing.expect_value(t, p, u64(1))
	testing.expect(t, !state.open)
	// Extra part 3 after close is refused.
	_, d = root_fact_step(&state, true, 0x5678, 3, 3, 0)
	testing.expect_value(t, d, log_scope.Settle_Decision.No_Principal)
}

@(test)
follow_gap_routes_only_to_its_own_principal :: proc(t: ^testing.T) {
	// Unsettled, unknown, and out-of-range records emit no gap and write nothing.
	action, target := follow_record_decide(false, true, 1, false, false)
	testing.expect_value(t, action, Follow_Action.Skip)
	testing.expect_value(t, target, u64(0))

	action, target = follow_record_decide(true, false, 1, false, false)
	testing.expect_value(t, action, Follow_Action.Skip)

	action, target = follow_record_decide(true, true, principals.PRINCIPAL_CAPACITY, false, false)
	testing.expect_value(t, action, Follow_Action.Skip)

	action, target = follow_record_decide(true, true, max(u64), true, true)
	testing.expect_value(t, action, Follow_Action.Skip)

	// Overwritten record (!whole) emits gap only to its settled principal.
	action, target = follow_record_decide(true, true, 1, false, true)
	testing.expect_value(t, action, Follow_Action.Emit_Gap)
	testing.expect_value(t, target, u64(1))

	action, target = follow_record_decide(true, true, 0, false, true)
	testing.expect_value(t, action, Follow_Action.Emit_Gap)
	testing.expect_value(t, target, u64(0))

	// Border-refused record (!row_ok) emits gap only to its settled principal.
	action, target = follow_record_decide(true, true, 1, true, false)
	testing.expect_value(t, action, Follow_Action.Emit_Gap)
	testing.expect_value(t, target, u64(1))

	// Intact record writes only to its settled principal.
	action, target = follow_record_decide(true, true, 1, true, true)
	testing.expect_value(t, action, Follow_Action.Write)
	testing.expect_value(t, target, u64(1))

	// Write outcomes: Full and Ended hold position; others advance.
	testing.expect(t, !follow_after_write(.Full))
	testing.expect(t, !follow_after_write(.Ended))
	testing.expect(t, follow_after_write(.Ok))
	testing.expect(t, follow_after_write(.No_Reader))
	testing.expect(t, follow_after_write(.No_Writer))
	testing.expect(t, follow_after_write(.Bad_Record))
	testing.expect(t, follow_after_write(.No_Record))
}
