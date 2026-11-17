#+build !freestanding
package system

import op "modus:contract/operation"
import "modus:contract/start_grant"
import "core:testing"

// A slot of the context takes one handle. The slots that the edges name
// are refused first: -1, one past the last handle, the largest slot; then a
// second write to a slot that is taken, for each pair of roles that share
// a slot of the table. Each refusal changes nothing. The roles of the
// grants Terminal and Store, which shared the slot 7, then take their slots
// together, last.
@(test)
grant_put_refuses_a_slot_that_is_taken :: proc(t: ^testing.T) {
	first := Grant{handle = 1, rights = {.Read}}
	second := Grant{handle = 2, rights = {.Read, .Write}}
	context_grants: Context_Grants
	outside := [?]int{-1, op.CONTEXT_HANDLES, op.CONTEXT_HANDLES + 1, max(int), min(int)}
	for slot in outside {
		testing.expectf(t, !grant_put(&context_grants, slot, first), "the slot %d is taken", slot)
		testing.expect_value(t, context_grants, Context_Grants{})
	}
	shared := [?][2]int {
		{GRANT_ROOT, GRANT_TERMINAL_PROGRAM},
		{GRANT_LOG_RECORDS, GRANT_TERMINAL_TEXT},
		{GRANT_TERMINAL_RING, GRANT_DEVICE_RING},
		{GRANT_DEVICE_RING, GRANT_DATE_PAGE},
		{GRANT_STORAGE_RING, GRANT_DATE_PORTS},
		{GRANT_DATAGRAM_RING, GRANT_TPM_RING},
		{GRANT_NETWORK_CONTROL, GRANT_SETTINGS_PAGE},
		{GRANT_TPM_SERVICE, GRANT_CLIENT_TABLE},
		{GRANT_DATAGRAM_REGION, GRANT_TPM_REGION},
		{op.CONTEXT_LOG, op.CONTEXT_LOG},
	}
	for pair in shared {
		testing.expect_value(t, pair[0], pair[1])
		one: Context_Grants
		testing.expect(t, grant_put(&one, pair[0], first))
		before := one
		testing.expectf(t, !grant_put(&one, pair[1], second), "the slot %d takes a second handle", pair[1])
		testing.expect_value(t, one, before)
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
		{{.Network, .Tpm}, GRANT_DATAGRAM_RING},
		{{.Settings, .Remote_Clients}, GRANT_SETTINGS_PAGE},
		{{.Terminal, .Log_Records}, GRANT_LOG_RECORDS},
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
