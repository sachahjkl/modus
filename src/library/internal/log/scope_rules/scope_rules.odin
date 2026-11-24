package scope_rules

import "modus:contract/log_scope"
import "modus:contract/output"
import "modus:principals"

// The fact of the root service whose parts the settle pass reads now: the
// principal of its first part, its key, and the part that comes next. A
// part that does not follow it, a non-fact record, or a loss in the pass
// closes it: the parts after a lost first part name no principal.
Root_Fact :: struct {
	open:      bool,
	principal: u64,
	key:       u64,
	next_part: u8,
	parts:     u8,
}

// root_fact_reset closes any open multi-part fact after a lost record or
// a break in the ring order.
root_fact_reset :: proc "contextless" (state: ^Root_Fact) {
	state.open = false
}

// root_fact_step settles one record of the root service and updates state.
// A non-fact record closes any open fact and belongs to the machine.
// Part 0 opens a multi-part fact when part_count > 1 and takes
// first_part_principal (falling back to the machine if out of range).
// A continuation part (part != 0) takes the principal of the open fact
// only when key, next_part, and part_count all match; otherwise it closes
// the open fact and gives No_Principal.
root_fact_step :: proc "contextless" (
	state: ^Root_Fact,
	is_fact: bool,
	key: u64,
	part: u8,
	part_count: u8,
	first_part_principal: u64,
) -> (
	principal: u64,
	decision: log_scope.Settle_Decision,
) {
	if !is_fact {
		state.open = false
		return principals.MACHINE, .Known
	}
	if part != 0 {
		if !state.open || key != state.key || part != state.next_part || part_count != state.parts {
			state.open = false
			return 0, .No_Principal
		}
		state.next_part += 1
		state.open = state.next_part < state.parts
		return state.principal, .Known
	}
	principal = first_part_principal < principals.PRINCIPAL_CAPACITY ? first_part_principal : principals.MACHINE
	state^ = {
		open      = part_count > 1,
		principal = principal,
		key       = key,
		next_part = 1,
		parts     = part_count,
	}
	return principal, .Known
}

// What the follow pump does with one settled log record.
Follow_Action :: enum u8 {
	Skip,     // Unsettled, unknown, or out-of-range principal: advance without writing or gapping.
	Emit_Gap, // Settled known record overwritten or damaged at border: emit gap to its principal only.
	Write,    // Settled known intact record: write to its principal's rings only.
}

// follow_record_decide chooses what log.follow does with one record at
// follow_next. A lost or border-refused record that was already settled to
// a known principal emits a gap to that principal alone, never to another
// principal.
follow_record_decide :: proc "contextless" (
	settled: bool,
	known: bool,
	principal: u64,
	whole: bool,
	row_ok: bool,
) -> (
	action: Follow_Action,
	target_principal: u64,
) {
	if !settled || !known || principal >= principals.PRINCIPAL_CAPACITY {
		return .Skip, 0
	}
	if !whole || !row_ok {
		return .Emit_Gap, principal
	}
	return .Write, principal
}

// follow_after_write says whether follow_next advances after a write to a
// principal's rings. Full and Ended hold the cursor for the next pass.
follow_after_write :: proc "contextless" (status: output.Stream_Status) -> bool {
	switch status {
	case .Ok, .No_Reader, .No_Writer, .Bad_Record, .No_Record:
		return true
	case .Full, .Ended:
		return false
	}
	return false
}
