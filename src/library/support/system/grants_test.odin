#+build !freestanding
package system

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/start_grant"
import "core:testing"

// A slot of the context takes one handle. The slots that the edges name
// are refused first: -1, one past the last handle, the largest slot, and
// the slot of the budget, which the loader writes; then a second write to
// a slot that is taken, for each pair of roles that share a slot of the
// table. Each refusal writes no handle, and its record names the first
// refused slot. The roles of the grants Terminal and Store, which shared
// the slot 7, then take their slots together, last.
@(test)
grant_put_refuses_a_slot_that_is_taken :: proc(t: ^testing.T) {
	first := Grant{handle = 1, rights = {.Read}}
	second := Grant{handle = 2, rights = {.Read, .Write}}
	outside := [?]int{-1, op.CONTEXT_HANDLES, op.CONTEXT_HANDLES + 1, max(int), min(int), op.CONTEXT_BUDGET, op.CONTEXT_WIRING_RING, op.CONTEXT_LOG_OUTPUT, op.CONTEXT_LOG_OUTPUT_END}
	empty: Context_Grants
	for slot in outside {
		context_grants: Context_Grants
		testing.expectf(t, !grant_put(&context_grants, slot, first), "the slot %d is taken", slot)
		testing.expect_value(t, context_grants.grants, empty.grants)
		testing.expect_value(t, context_grants.taken, empty.taken)
		testing.expect_value(t, context_grants.refusal, Context_Refusal{refused = true, place = slot})
	}
	// The first refusal stays: a second one names another slot.
	kept: Context_Grants
	grant_put(&kept, -1, first)
	grant_put(&kept, op.CONTEXT_HANDLES, first)
	testing.expect_value(t, kept.refusal, Context_Refusal{refused = true, place = -1})
	shared := [?][2]int {
		{GRANT_ROOT, GRANT_TERMINAL_PROCESS},
		{GRANT_LOG_RECORDS, GRANT_TERMINAL_TEXT},
		{GRANT_TERMINAL_RING, GRANT_DEVICE_RING},
		{GRANT_DEVICE_RING, GRANT_DATE_PAGE},
		{GRANT_STORAGE_RING, GRANT_DATE_PORTS},
		{GRANT_DATAGRAM_RING, GRANT_TPM_RING},
		{GRANT_NETWORK_CONTROL, GRANT_SETTINGS_PAGE},
		{GRANT_TPM_SERVICE, GRANT_CLIENT_TABLE},
		{GRANT_DATAGRAM_REGION, GRANT_TPM_REGION},
		{GRANT_REPLACEMENTS, GRANT_DEVICE_SERVICE},
		{op.CONTEXT_LOG, op.CONTEXT_LOG},
	}
	for pair in shared {
		testing.expect_value(t, pair[0], pair[1])
		one: Context_Grants
		testing.expect(t, grant_put(&one, pair[0], first))
		before := one
		testing.expectf(t, !grant_put(&one, pair[1], second), "the slot %d takes a second handle", pair[1])
		testing.expect_value(t, one.grants, before.grants)
		testing.expect_value(t, one.taken, before.taken)
		testing.expect_value(t, one.refusal, Context_Refusal{refused = true, place = pair[1]})
		testing.expect_value(t, one.grants[pair[0]], first)
	}
	// The terminal and the private store: each slot holds its own handle.
	terminal_and_store := [?]int{GRANT_TERMINAL_RING, GRANT_TERMINAL_TEXT, GRANT_STORAGE_RING, GRANT_STORAGE_REGION, GRANT_STORAGE_SERVICE}
	both: Context_Grants
	for slot, index in terminal_and_store {
		testing.expectf(t, grant_put(&both, slot, Grant{handle = Handle(index + 1)}), "the slot %d is refused", slot)
	}
	for slot, index in terminal_and_store {
		testing.expect_value(t, both.grants[slot].handle, Handle(index + 1))
	}
	testing.expect_value(t, both.grants[GRANT_STORAGE_RING].handle, Handle(3))
	testing.expect(t, !both.refusal.refused)
	// The slot after those of a wiring list, which no role takes yet, and
	// the last slot below the budget: a starter writes each of them.
	edges: Context_Grants
	for slot in ([?]int{op.CONTEXT_LOG_OUTPUT_END + 1, op.CONTEXT_BUDGET - 1}) {
		testing.expectf(t, op.CONTEXT_LOG_OUTPUT_END + 1 < op.CONTEXT_HANDLES && grant_put(&edges, slot, first), "the slot %d is refused", slot)
	}
}

// An index of the values takes one value. The edges come first: -1, one
// past the last value, the largest index; then each index that the
// system writes (the seed, its strength, the fixed ranges); then a second
// write to an index that is taken. Each refusal writes no value and names
// its index. A value at the first and at the last free index is written,
// last.
@(test)
value_put_refuses_an_index_that_is_taken :: proc(t: ^testing.T) {
	refused := make([dynamic]int, context.temp_allocator)
	append(&refused, -1, op.CONTEXT_VALUES, op.CONTEXT_VALUES + 1, max(int), min(int), op.CONTEXT_VALUE_SEED_STRENGTH, op.CONTEXT_VALUE_FIXED_RANGES_MAPPED)
	for index in op.CONTEXT_VALUE_SEED ..< op.CONTEXT_VALUE_SEED + op.CONTEXT_VALUE_SEED_COUNT {
		append(&refused, index)
	}
	empty: Context_Values
	for index in refused {
		context_values: Context_Values
		testing.expectf(t, !value_put(&context_values, index, max(u64)), "the index %d takes a value", index)
		testing.expect_value(t, context_values.values, empty.values)
		testing.expect_value(t, context_values.taken, empty.taken)
		testing.expect_value(t, context_values.refusal, Context_Refusal{refused = true, place = index})
	}
	// The unlock mode and the rows of a terminal share the index 5: one
	// process never holds both, and a start that wrote both loses none.
	testing.expect_value(t, GRANT_VALUE_UNLOCK_MODE, GRANT_VALUE_TERMINAL_ROWS)
	twice: Context_Values
	testing.expect(t, value_put(&twice, GRANT_VALUE_UNLOCK_MODE, 1))
	testing.expect(t, !value_put(&twice, GRANT_VALUE_TERMINAL_ROWS, 2))
	testing.expect_value(t, twice.values[GRANT_VALUE_UNLOCK_MODE], u64(1))
	testing.expect_value(t, twice.refusal, Context_Refusal{refused = true, place = GRANT_VALUE_TERMINAL_ROWS})
	edges: Context_Values
	testing.expect(t, value_put(&edges, 0, 0))
	testing.expect(t, value_put(&edges, op.CONTEXT_VALUES - 1, max(u64)))
	testing.expect_value(t, edges.values[op.CONTEXT_VALUES - 1], max(u64))
	testing.expect(t, !edges.refusal.refused)
}

// A value of several words is written whole or not at all. The edges come
// first: no word, a first index of -1 and one past the values, words that
// run one past the last value, words over the seed, words over a taken
// index; each refusal writes no word. A name of four words at the index of
// the name of a terminal is written, last.
@(test)
values_put_writes_all_the_words_or_none :: proc(t: ^testing.T) {
	words := [4]u64{1, 2, 3, max(u64)}
	Refused_Write :: struct {
		first: int,
		count: int,
		place: int,
	}
	refused := [?]Refused_Write {
		{first = 0, count = 0, place = 0},
		{first = -1, count = 1, place = -1},
		{first = op.CONTEXT_VALUES, count = 1, place = op.CONTEXT_VALUES},
		{first = max(int), count = 1, place = max(int)},
		{first = op.CONTEXT_VALUES - 3, count = 4, place = op.CONTEXT_VALUES},
		{first = op.CONTEXT_VALUE_SEED - 1, count = 2, place = op.CONTEXT_VALUE_SEED},
	}
	empty: Context_Values
	for write in refused {
		context_values: Context_Values
		testing.expectf(t, !values_put(&context_values, write.first, words[:write.count]), "the write of %d words at %d is taken", write.count, write.first)
		testing.expect_value(t, context_values.values, empty.values)
		testing.expect_value(t, context_values.taken, empty.taken)
		testing.expect_value(t, context_values.refusal, Context_Refusal{refused = true, place = write.place})
	}
	over_a_taken: Context_Values
	testing.expect(t, value_put(&over_a_taken, 2, 7))
	testing.expect(t, !values_put(&over_a_taken, 0, words[:]))
	testing.expect_value(t, over_a_taken.values[0], u64(0))
	testing.expect_value(t, over_a_taken.values[2], u64(7))
	testing.expect_value(t, over_a_taken.refusal, Context_Refusal{refused = true, place = 2})
	name: Context_Values
	testing.expect(t, values_put(&name, GRANT_VALUE_TERMINAL_NAME, words[:]))
	testing.expect_value(t, name.values[GRANT_VALUE_TERMINAL_NAME + 3], max(u64))
	testing.expect(t, !value_put(&name, GRANT_VALUE_TERMINAL_NAME + 3, 0))
}

// The decision of a starter before its start: a refused handle comes
// first, then a refused value, each with its place, the first refusal of
// its part; a context with no refusal starts, last.
@(test)
a_context_with_a_refused_write_does_not_start :: proc(t: ^testing.T) {
	both_grants: Context_Grants
	both_values: Context_Values
	grant_put(&both_grants, GRANT_DISPLAY, {handle = 1})
	grant_put(&both_grants, GRANT_DISPLAY, {handle = 2})
	value_put(&both_values, op.CONTEXT_VALUE_SEED, 1)
	part, place, refused := context_refusal_of(&both_grants, &both_values)
	testing.expect(t, refused)
	testing.expect_value(t, part, Context_Part.Handle)
	testing.expect_value(t, place, GRANT_DISPLAY)
	no_grants: Context_Grants
	part, place, refused = context_refusal_of(&no_grants, &both_values)
	testing.expect(t, refused)
	testing.expect_value(t, part, Context_Part.Value)
	testing.expect_value(t, place, op.CONTEXT_VALUE_SEED)
	edges: Context_Grants
	grant_put(&edges, max(int), {handle = 1})
	grant_put(&edges, -1, {handle = 1})
	no_values: Context_Values
	part, place, refused = context_refusal_of(&edges, &no_values)
	testing.expect(t, refused)
	testing.expect_value(t, place, max(int))
	good_grants: Context_Grants
	good_values: Context_Values
	testing.expect(t, grant_put(&good_grants, op.CONTEXT_LOG, {handle = 1}))
	testing.expect(t, value_put(&good_values, GRANT_VALUE_IMAGE_SIZE, 4096))
	_, _, refused = context_refusal_of(&good_grants, &good_values)
	testing.expect(t, !refused)
}

// A fixed range is stated once: a second statement is two mappings at one
// address, and is refused with the index of the fixed ranges and no change.
// Each range, then all of them, is stated last.
@(test)
range_mapped_put_refuses_a_range_twice :: proc(t: ^testing.T) {
	for range in fixed_addresses.Fixed_Range {
		context_values: Context_Values
		testing.expect(t, range_mapped_put(&context_values, range))
		before := context_values.values
		testing.expectf(t, !range_mapped_put(&context_values, range), "the range %v is stated twice", range)
		testing.expect_value(t, context_values.values, before)
		testing.expect_value(t, context_values.refusal, Context_Refusal{refused = true, place = op.CONTEXT_VALUE_FIXED_RANGES_MAPPED})
	}
	all: Context_Values
	for range in fixed_addresses.Fixed_Range {
		testing.expect(t, range_mapped_put(&all, range))
	}
	for range in fixed_addresses.Fixed_Range {
		testing.expect(t, range in fixed_addresses.ranges_mapped(&all.values))
	}
	testing.expect(t, !all.refusal.refused)
}

// A role whose handles meet in one context slot is found before its start.
// The roles that would meet are tried first, each with the slot that it
// shares; then the roles whose grants never meet, last: Terminal with Store,
// the roles of the console and of remote, and no grant.
@(test)
a_role_whose_handles_meet_is_refused :: proc(t: ^testing.T) {
	meeting := [?]struct {
		role: bit_set[start_grant.Grant],
		slot: int,
	} {
		{{.Clock, .Store}, GRANT_STORAGE_RING},
		{{.Clock, .Data_Disk}, GRANT_DEVICE_RING},
		{{.Terminal, .Network_Device}, GRANT_TERMINAL_RING},
		{{.Terminal, .Sound_Device}, GRANT_TERMINAL_RING},
		{{.Network, .Tpm}, GRANT_DATAGRAM_RING},
		{{.Settings, .Remote_Clients}, GRANT_SETTINGS_PAGE},
		{{.Terminal, .Log_Records}, GRANT_LOG_RECORDS},
		{{.Replacements, .Data_Disk}, GRANT_DEVICE_SERVICE},
		{{.Replacements, .Network_Device}, GRANT_DEVICE_SERVICE},
	}
	for case_of in meeting {
		slot, twice := role_slot_taken_twice(case_of.role)
		testing.expectf(t, twice, "the role %v starts with two handles in one slot", case_of.role)
		testing.expect_value(t, slot, case_of.slot)
	}
	apart := [?]bit_set[start_grant.Grant] {
		{.Terminal, .Store},
		{.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store, .Acts_For_Principal, .Replacements, .Replace, .History_Store, .Debug_Image, .Palette},
		{.Connect, .Network, .Acts_For_Principal, .Remote_Clients},
		{.Data_Disk, .Scratch_Disk, .Network_Device},
		{},
	}
	for role in apart {
		_, twice := role_slot_taken_twice(role)
		testing.expectf(t, !twice, "the role %v has two handles in one slot", role)
	}
}
