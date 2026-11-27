package disk_process

// Machine grants: rows of principal 0's disk grant table, tagged with the
// machine key, conferring scoped authority over the machine to named
// principals (src/md/features/several_principals.md, "The authority over the
// machine").
//
// Two scopes reflect two levels of trust:
// - Principals: admit a principal, remove a principal, set session budgets.
// - System: principal 0's plan, start policy, trusted path holders, device
//   grants, machine passphrase, and system updates.
//
// Invariants enforced here without mutating on refusal:
// - Machine grant rows exist only in principal 0's disk grant table.
// - Creating the first named principal bootstraps both scopes for it.
// - The last holder of System is never removed while another named principal
//   exists.
// - Machine recovery key restores both scopes to an existing named principal
//   on the chooser.

import "modus:contract/enum_word"

// Plan value: maximum machine grant rows in principal 0's disk grant table,
// holding every admitted principal with room past PRINCIPAL_CAPACITY - 1.
MACHINE_GRANT_CAPACITY :: 16

// Format property: byte length of a persistent 256-bit principal identifier.
MACHINE_GRANT_IDENTIFIER_SIZE :: 32

// Format property: wire size of one persisted machine grant row (32-byte
// principal identifier, 1-byte Machine_Scopes mask, 7 reserved zero bytes).
MACHINE_GRANT_ROW_OFFSET_IDENTIFIER :: 0
MACHINE_GRANT_ROW_OFFSET_SCOPES :: MACHINE_GRANT_IDENTIFIER_SIZE
MACHINE_GRANT_ROW_SIZE :: MACHINE_GRANT_IDENTIFIER_SIZE + 8
#assert(MACHINE_GRANT_ROW_SIZE == 40)

// Closed set of machine authority scopes carried in a Machine_Grant_Row.
Machine_Scope :: enum u8 {
	Principals = 0, // Admit a principal, remove a principal, set session budgets.
	System     = 1, // Principal 0's plan, start policy, trusted path, device grants, machine passphrase, updates.
}

// Bit set of machine authority scopes.
Machine_Scopes :: bit_set[Machine_Scope; u8]

// Complete set of defined machine scopes.
ALL_MACHINE_SCOPES :: Machine_Scopes{.Principals, .System}

// One persisted machine grant row in principal 0's disk grant table.
Machine_Grant_Row :: struct {
	principal_identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8,
	scopes:               Machine_Scopes,
}

// machine_scopes_to_word returns the canonical u64 transport word of scopes.
machine_scopes_to_word :: proc "contextless" (scopes: Machine_Scopes) -> u64 {
	return u64(transmute(u8)scopes)
}

// machine_scopes_from_word converts a transport word into Machine_Scopes at the
// border, refusing 0 and any bit outside ALL_MACHINE_SCOPES.
machine_scopes_from_word :: proc "contextless" (word: u64) -> (scopes: Machine_Scopes, ok: bool) {
	all := ALL_MACHINE_SCOPES
	allowed := u64(transmute(u8)all)
	if word == 0 || (word & ~allowed) != 0 {
		return {}, false
	}
	return transmute(Machine_Scopes)u8(word), true
}

// machine_scope_of_word converts a transport word into a single Machine_Scope.
machine_scope_of_word :: proc "contextless" (word: u64) -> (scope: Machine_Scope, ok: bool) {
	return enum_word.member_of_word(Machine_Scope, word)
}

@(private = "file")
machine_identifier_is_zero :: proc "contextless" (id: [MACHINE_GRANT_IDENTIFIER_SIZE]u8) -> bool {
	acc: u8
	for b in id {
		acc |= b
	}
	return acc == 0
}

// table_machine_grant_find returns the row index of principal_identifier in
// table.machine_grants, or -1 if absent.
table_machine_grant_find :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8) -> int {
	if table == nil || machine_identifier_is_zero(identifier) {
		return -1
	}
	count := clamp(table.machine_grant_count, 0, MACHINE_GRANT_CAPACITY)
	for place in 0 ..< count {
		if table.machine_grants[place].principal_identifier == identifier {
			return place
		}
	}
	return -1
}

// table_machine_grant_holds reports whether identifier currently holds scope
// in table.
table_machine_grant_holds :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8, scope: Machine_Scope) -> bool {
	place := table_machine_grant_find(table, identifier)
	if place < 0 {
		return false
	}
	return scope in table.machine_grants[place].scopes
}

// table_machine_grant_count_scope counts rows in table holding scope.
table_machine_grant_count_scope :: proc "contextless" (table: ^Grant_Table, scope: Machine_Scope) -> int {
	if table == nil {
		return 0
	}
	count := clamp(table.machine_grant_count, 0, MACHINE_GRANT_CAPACITY)
	holders := 0
	for place in 0 ..< count {
		if scope in table.machine_grants[place].scopes {
			holders += 1
		}
	}
	return holders
}

// table_holds_machine_grants reports whether table holds at least one machine
// grant row. Named principals' tables must never hold machine grant rows.
table_holds_machine_grants :: proc "contextless" (table: ^Grant_Table) -> bool {
	return table != nil && table.machine_grant_count > 0
}

// table_machine_grant_set adds or merges scopes onto identifier's machine grant
// row in principal 0's disk grant table. Refuses zero identifiers, empty or
// unknown scopes, or a full table without mutating table.
table_machine_grant_set :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8, scopes: Machine_Scopes) -> Table_Problem {
	if table == nil || machine_identifier_is_zero(identifier) {
		return .Zero_Identifier
	}
	valid_scopes, scopes_ok := machine_scopes_from_word(machine_scopes_to_word(scopes))
	if !scopes_ok {
		return .Bad_Machine_Scopes
	}
	if place := table_machine_grant_find(table, identifier); place >= 0 {
		table.machine_grants[place].scopes += valid_scopes
		return .None
	}
	if table.machine_grant_count >= MACHINE_GRANT_CAPACITY {
		return .Full
	}
	table.machine_grants[table.machine_grant_count] = {
		principal_identifier = identifier,
		scopes               = valid_scopes,
	}
	table.machine_grant_count += 1
	return .None
}

// table_machine_grant_revoke removes scopes from identifier's machine grant
// row. Always refuses removing the last System scope across the whole table
// (.Last_System_Grant) so no machine can lose all System authority. When a
// row's scopes become empty, compacts and zeroes the vacated slot.
table_machine_grant_revoke :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8, scopes: Machine_Scopes) -> Table_Problem {
	if table == nil || machine_identifier_is_zero(identifier) {
		return .Zero_Identifier
	}
	valid_scopes, scopes_ok := machine_scopes_from_word(machine_scopes_to_word(scopes))
	if !scopes_ok {
		return .Bad_Machine_Scopes
	}
	place := table_machine_grant_find(table, identifier)
	if place < 0 {
		return .Absent
	}
	held := table.machine_grants[place].scopes
	if (held & valid_scopes) == {} {
		return .Not_Held
	}
	if .System in valid_scopes && .System in held && table_machine_grant_count_scope(table, .System) <= 1 {
		return .Last_System_Grant
	}
	remaining := held - valid_scopes
	if remaining != {} {
		table.machine_grants[place].scopes = remaining
		return .None
	}
	count := clamp(table.machine_grant_count, 0, MACHINE_GRANT_CAPACITY)
	for index in place ..< count - 1 {
		table.machine_grants[index] = table.machine_grants[index + 1]
	}
	table.machine_grants[count - 1] = {}
	table.machine_grant_count = count - 1
	return .None
}

// table_machine_grant_bootstrap_first_principal grants both Principals and
// System scopes to the first named principal created on a machine that holds
// no machine grant rows yet.
table_machine_grant_bootstrap_first_principal :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8) -> Table_Problem {
	if table == nil || machine_identifier_is_zero(identifier) {
		return .Zero_Identifier
	}
	if table.machine_grant_count != 0 {
		return .Not_Held
	}
	return table_machine_grant_set(table, identifier, ALL_MACHINE_SCOPES)
}

// table_machine_grant_recovery_restore restores both Principals and System
// scopes to an existing named principal after the machine recovery key is
// proved on the chooser.
table_machine_grant_recovery_restore :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8) -> Table_Problem {
	return table_machine_grant_set(table, identifier, ALL_MACHINE_SCOPES)
}

// table_machine_grant_remove_principal removes identifier's machine grant row
// when that principal is removed. While any other named principal remains
// (!last_named_principal), refuses removing the last System holder with
// Last_System_Grant; when removing the last remaining named principal, clears
// the row cleanly as the machine returns to principal 0 alone.
table_machine_grant_remove_principal :: proc "contextless" (table: ^Grant_Table, identifier: [MACHINE_GRANT_IDENTIFIER_SIZE]u8, last_named_principal: bool) -> Table_Problem {
	if table == nil || machine_identifier_is_zero(identifier) {
		return .Zero_Identifier
	}
	place := table_machine_grant_find(table, identifier)
	if place < 0 {
		return .None
	}
	if !last_named_principal && .System in table.machine_grants[place].scopes && table_machine_grant_count_scope(table, .System) <= 1 {
		return .Last_System_Grant
	}
	count := clamp(table.machine_grant_count, 0, MACHINE_GRANT_CAPACITY)
	for index in place ..< count - 1 {
		table.machine_grants[index] = table.machine_grants[index + 1]
	}
	table.machine_grants[count - 1] = {}
	table.machine_grant_count = count - 1
	return .None
}
