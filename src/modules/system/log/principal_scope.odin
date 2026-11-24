package log

import "base:intrinsics"
import "internal:log/scope_rules"
import module "modus:contract/module"
import "modus:contract/log_scope"
import op "modus:contract/operation"
import "modus:principals"
import "modus:system"

// The principal of each record of the whole log, and its number in the
// scope of that principal (src/md/features/log_reader_scope.md, "The scope
// of a principal").
//
// One pass in the order of the ring settles each record: its principal
// from the session table (log_scope.settle_decision), or none, and for a
// record of a principal its scope number, the count of the records of that
// principal before it. A reader of a principal receives scope numbers
// only, so no number tells it how many records the others wrote. A record
// whose row can still come stops the pass, with the records after it, up
// to log_scope.ROW_WAIT_MICROSECONDS: the numbers follow the order of the
// ring, and no record is numbered before the one before it.
//
// A line of the root service about a session is a record of that session:
// a fact of the root service with an Integer field "principal" names the
// principal whose session it is about. The root service is the one writer
// of the session table, so its word is trusted as the table is.

// The session table, with Read. nil: the root service gave none, and no
// record reaches a reader of a principal.
session_table: ^log_scope.SESSION_TABLE

// The principal of the window of this service: the principal of its
// process, which the root service gives at its start.
window_principal: u64

// The output follow counts the rings of each principal apart.
#assert(system.SCOPED_PRINCIPALS_MOST >= principals.PRINCIPAL_CAPACITY)

// What the pass knows of the record at one place of the ring: a place
// names the record of its number only.
Record_Principal :: struct {
	number:       u64,
	settled:      bool,
	known:        bool,
	principal:    u64,
	scope_number: u64, // Known: the number of the record among the records of its principal.
}
record_principals: [op.LOG_RECORD_CAPACITY]Record_Principal

// The first record that the pass has not settled.
settled_next: u64
// The records that the kernel wrote over before the pass settled them: no
// reader learns whose they were.
settle_lost: u64
// The next scope number of each principal.
scope_counts: [principals.PRINCIPAL_CAPACITY]u64
// The fact of the root service whose parts the pass reads now: the
// principal of its first part, its key, and the part that comes next. A
// part that does not follow it, or a loss in the pass, closes it: the parts
// after a lost one name no principal.
root_fact: scope_rules.Root_Fact

// session_table_open maps the session table, and reads the principal of
// the window.
session_table_open :: proc "contextless" (ctx: ^system.Context) {
	window_principal = ctx.values[system.GRANT_VALUE_SERVICE_PRINCIPAL]
	handle := ctx.handles[system.GRANT_SESSION_TABLE]
	if handle == 0 {
		return
	}
	if address, status := system.memory_map(handle, {}); status == .Ok {
		session_table = (^log_scope.SESSION_TABLE)(address)
	}
	// The records before this service started: the pass starts at the
	// first record that the ring keeps.
	settled_next, _ = op.log_first_kept(0, intrinsics.atomic_load(&reader_head.written))
}

// principals_settle settles the records in the order of the ring, until
// the last one or the first one whose row can still come. It gives the
// time at which a waiting record settles, or WAIT_FOREVER.
principals_settle :: proc "contextless" () -> (deadline: u64) {
	written := intrinsics.atomic_load(&reader_head.written)
	next, lost := op.log_first_kept(settled_next, written)
	settle_lost += lost
	if lost != 0 {
		scope_rules.root_fact_reset(&root_fact)
	}
	for ; next < written; next += 1 {
		record, whole := record_copy(next)
		if !whole {
			settle_lost += 1
			scope_rules.root_fact_reset(&root_fact)
			continue
		}
		principal, decision := record_settle(&record)
		switch decision {
		case .Wait:
			settled_next = next
			// record.time is in microseconds, the wait in milliseconds.
			return (record.time + log_scope.ROW_WAIT_MICROSECONDS) / 1000 + 1
		case .No_Principal:
			record_principals[next % op.LOG_RECORD_CAPACITY] = {number = next, settled = true}
		case .Known:
			place := &record_principals[next % op.LOG_RECORD_CAPACITY]
			if principal >= principals.PRINCIPAL_CAPACITY {
				place^ = {number = next, settled = true}
				continue
			}
			place^ = {number = next, settled = true, known = true, principal = principal, scope_number = scope_counts[principal]}
			scope_counts[principal] += 1
		}
	}
	settled_next = next
	return system.WAIT_FOREVER
}

// record_settle decides the principal of one record.
@(private = "file")
record_settle :: proc "contextless" (record: ^op.Log_Record) -> (principal: u64, decision: log_scope.Settle_Decision) {
	if session_table == nil {
		return 0, .No_Principal
	}
	if u64(record.process) == log_scope.ROOT_SERVICE_SLOT && u64(record.process_serial) == log_scope.ROOT_SERVICE_SERIAL {
		return root_record_principal(record)
	}
	now := u64(system.time()) * 1000
	age := now > record.time ? now - record.time : 0
	return log_scope.settle_decision(session_table, u64(record.process), u64(record.process_serial), age)
}

// root_record_principal gives the principal of a record of the root
// service: the field "principal" of its fact, else principal 0.
@(private = "file")
root_record_principal :: proc "contextless" (record: ^op.Log_Record) -> (principal: u64, decision: log_scope.Settle_Decision) {
	form, form_known := op.log_record_form(record)
	if !form_known || form != .Fact {
		return scope_rules.root_fact_step(&root_fact, false, 0, 0, 0, principals.MACHINE)
	}
	fact := op.log_record_fact(record)
	first_principal := fact.part == 0 ? fact_principal_field(fact) : principals.MACHINE
	return scope_rules.root_fact_step(&root_fact, true, fact.key, fact.part, fact.part_count, first_principal)
}

// fact_principal_field reads the Integer field "principal" of the first
// record of a fact, from the description of its module. A fact with no such
// field, of a module that the image does not hold, or a value past the
// principals, is of principal 0.
@(private = "file")
fact_principal_field :: proc "contextless" (fact: ^op.Log_Fact) -> u64 {
	file := fact_module_of_hash(fact.module_hash)
	if len(file) == 0 {
		return principals.MACHINE
	}
	_, _, description, found := module.fact_find(file, fact.key)
	if !found {
		return principals.MACHINE
	}
	for number in u32(0) ..< description.field_count {
		field, field_ok := module.field(file, description, number)
		if !field_ok || module.string_at(file, field.name_offset, field.name_count) != "principal" {
			continue
		}
		if field.type != u8(module.Type.Integer) || (field.detail != 0 && field.detail != 8) || u64(field.offset) + 8 > u64(fact.value_count) {
			return principals.MACHINE
		}
		value := (^u64)(&fact.values[field.offset])^
		if value >= principals.PRINCIPAL_CAPACITY {
			return principals.MACHINE
		}
		return value
	}
	return principals.MACHINE
}

// record_settled gives what the pass knows of the record of a number: ok
// is false for a record that it did not settle, or whose place holds
// another record now.
record_settled :: proc "contextless" (number: u64) -> (place: Record_Principal, ok: bool) {
	place = record_principals[number % op.LOG_RECORD_CAPACITY]
	return place, place.number == number && place.settled
}

// Scope_Walk walks the records of the ring that a scope receives, from
// the number after on, in the order of the ring: their whole-log number,
// and the number that the reader sees (the scope number for a reader of a
// principal).
Scope_Walk :: struct {
	scope:    log_scope.Scope,
	after:    u64,
	next:     u64,
	end:      u64,
	lost:     u64, // The records of the scope from after on that the ring no longer keeps.
	first:    bool,
}

// scope_walk_begin starts a walk. A reader of a principal walks the
// settled records only: the others have no scope number yet.
scope_walk_begin :: proc "contextless" (scope: log_scope.Scope, after: i64) -> (walk: Scope_Walk) {
	walk.scope = scope
	walk.after = u64(max(after, 0))
	walk.first = true
	written := intrinsics.atomic_load(&reader_head.written)
	if scope.kind == .Whole_Log {
		walk.next, walk.lost = op.log_first_kept(walk.after, written)
		walk.end = written
		return
	}
	walk.next, _ = op.log_first_kept(0, written)
	walk.end = settled_next
	return
}

// scope_walk_next gives the next record of the walk, or ok false at its
// end.
scope_walk_next :: proc "contextless" (walk: ^Scope_Walk) -> (record: op.Log_Record, row_number: u64, ok: bool) {
	for ; walk.next < walk.end; walk.next += 1 {
		number := walk.next
		copied, whole := record_copy(number)
		if walk.scope.kind == .Whole_Log {
			if !whole {
				walk.lost += 1
				continue
			}
			walk.next += 1
			return copied, number, true
		}
		place, settled := record_settled(number)
		if !whole || !settled || !log_scope.record_in_scope(walk.scope, place.principal, place.known) || place.scope_number < walk.after {
			continue
		}
		if walk.first {
			walk.first = false
			walk.lost = place.scope_number - walk.after
		}
		walk.next += 1
		return copied, place.scope_number, true
	}
	// A reader whose records from after on are all gone learns that they
	// are gone, as many as its own count says.
	if walk.first && walk.scope.kind == .Principal_Records && walk.scope.principal < principals.PRINCIPAL_CAPACITY {
		walk.first = false
		count := scope_counts[walk.scope.principal]
		walk.lost = count > walk.after ? count - walk.after : 0
	}
	return {}, 0, false
}
