#+build !freestanding
package powerbox_core

import "base:runtime"
import "core:fmt"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/powerbox"

@(private = "file")
picker_state :: proc(rows: int) -> ^Powerbox_State {
	state := new(Powerbox_State, context.temp_allocator)
	state_init(state, TRUSTED_DISPLAY_SLOT, {stores = make([]Session_Store, rows, context.temp_allocator), held_grants = make([]Held_Grant, 4, context.temp_allocator)})
	return state
}

// The picker of the display: an empty list gives an empty first page; a
// list of 100 stores (past the 4 of the stand-in) pages, a pick of the
// 70th store is taken only with its place, its change count and its hash;
// a list that changed, a slot that is not the display, a closed dialog and
// a serial of no dialog are refused.
@(test)
picker_dialog_pages_and_picks_against_its_copy :: proc(t: ^testing.T) {
	state := picker_state(256)
	serial, refusal := picker_dialog_open(state, 3, 0)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.None)
	page: powerbox.Picker_Page
	request := powerbox.Picker_Page_Request{dialog_serial = serial}
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.None)
	testing.expect(t, page.total == 0 && page.candidate_count == 0 && !page.more)
	testing.expect_value(t, picker_dialog_close(state, TRUSTED_DISPLAY_SLOT, serial), powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, picker_dialog_close(state, TRUSTED_DISPLAY_SLOT, serial), powerbox.Powerbox_Refusal.Untrusted_Answer)

	stores_replace_begin(state, 3)
	for index in 0 ..< 100 {
		name := fmt.tprintf("store_%03d", index)
		testing.expect_value(t, register_session_store(state, 3, name, u64(index + 1)), powerbox.Picker_Store_Refusal.None)
	}
	// A store of another principal is no candidate of principal 3.
	testing.expect_value(t, register_session_store(state, 4, "secret", 1), powerbox.Picker_Store_Refusal.None)
	serial, refusal = picker_dialog_open(state, 3, 0)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.None)
	request = {dialog_serial = serial, first = 64}
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.None)
	testing.expect(t, page.total == 100 && page.candidate_count == powerbox.PICKER_PAGE_CANDIDATES && page.candidates[5].list_index == 69)
	chosen := page.candidates[5]
	// Each part of the pick is checked: a wrong hash, a wrong place, a
	// wrong slot end nothing but the dialog that they name.
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT + 1, serial, 69, page.change_count, chosen.name_hash)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial + 99, 69, page.change_count, chosen.name_hash)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	picked, pick_refusal := picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial, 69, page.change_count, chosen.name_hash)
	testing.expect_value(t, pick_refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, string(picked.candidate.name_bytes[:picked.candidate.name_length]), "store_069")
	// The dialog ended with its pick.
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial, 69, page.change_count, chosen.name_hash)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)

	// A wrong hash or place refuses and ends the dialog.
	serial, _ = picker_dialog_open(state, 3, 0)
	wrong: blake3.Hash
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial, 69, state.picker_change_count, wrong)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	serial, _ = picker_dialog_open(state, 3, 0)
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial, 100, state.picker_change_count, chosen.name_hash)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)

	// A list that changed after the open refuses its pages and its pick.
	serial, _ = picker_dialog_open(state, 3, 0)
	before := state.picker_change_count
	stores_replace_begin(state, 3)
	request = {dialog_serial = serial}
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	_, refusal = picker_dialog_pick(state, TRUSTED_DISPLAY_SLOT, serial, 0, before, chosen.name_hash)
	testing.expect_value(t, refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	// The store of principal 4 stays.
	testing.expect(t, principal_store_at(state, 4, 0) != nil && principal_store_at(state, 3, 0) == nil)
}

// A budget of the tests for the store table: rows in place in a large
// reservation, a new index each growth, until the rows that it pays end.
@(private = "file")
Test_Store_Budget :: struct {
	rows_left: int,
	reserved:  []Session_Store,
	growths:   int,
}

@(private = "file")
test_stores_grow :: proc "contextless" (user: rawptr, state: ^Powerbox_State, rows_least: int) -> bool {
	context = runtime.default_context()
	budget := (^Test_Store_Budget)(user)
	more := rows_least - len(state.stores)
	if more > budget.rows_left || rows_least > len(budget.reserved) {
		return false
	}
	budget.rows_left -= max(more, 0)
	budget.growths += 1
	state.stores = budget.reserved[:max(rows_least, len(state.stores))]
	index := 1
	for index < 4 * len(state.stores) {
		index *= 2
	}
	state.store_index = make([]u32, index, context.temp_allocator)
	return true
}

// The table of the stores starts empty and grows: 1000 stores of one
// principal, past any table of a fixed size; a name or an id that the
// principal holds is refused, the same name for another principal is
// not; a budget that pays no more refuses the next store visibly; a
// replace frees the rows of its principal only.
@(test)
store_table_grows_and_refuses_repeats_by_its_index :: proc(t: ^testing.T) {
	budget := Test_Store_Budget{rows_left = 1100, reserved = make([]Session_Store, 4096, context.temp_allocator)}
	state := new(Powerbox_State, context.temp_allocator)
	state_init(state, TRUSTED_DISPLAY_SLOT, {stores_grow = test_stores_grow, stores_grow_user = &budget, held_grants = make([]Held_Grant, 4, context.temp_allocator)})
	for index in 0 ..< 1000 {
		testing.expectf(t, register_session_store(state, 1, fmt.tprintf("store_%04d", index), u64(index + 1)) == .None, "store %d", index)
	}
	testing.expect_value(t, state.store_count, 1000)
	testing.expect_value(t, register_session_store(state, 1, "store_0500", 5000), powerbox.Picker_Store_Refusal.Repeated)
	testing.expect_value(t, register_session_store(state, 1, "other", 501), powerbox.Picker_Store_Refusal.Repeated)
	// A name that no row can show, and a store id 0: left out, the table
	// unchanged.
	testing.expect_value(t, register_session_store(state, 1, "", 7000), powerbox.Picker_Store_Refusal.Not_Display_Text)
	testing.expect_value(t, register_session_store(state, 1, "line\nbreak", 7001), powerbox.Picker_Store_Refusal.Not_Display_Text)
	testing.expect_value(t, register_session_store(state, 1, "\xffa", 7002), powerbox.Picker_Store_Refusal.Not_Display_Text)
	testing.expect_value(t, register_session_store(state, 1, "unnumbered", 0), powerbox.Picker_Store_Refusal.Not_Display_Text)
	long: [powerbox.MAX_NAME_BYTES + 1]u8
	for &byte in long {
		byte = 'a'
	}
	testing.expect_value(t, register_session_store(state, 1, string(long[:]), 7003), powerbox.Picker_Store_Refusal.Not_Display_Text)
	testing.expect_value(t, register_session_store(state, 1, string(long[:powerbox.MAX_NAME_BYTES]), 7004), powerbox.Picker_Store_Refusal.None)
	testing.expect_value(t, state.store_count, 1001)
	testing.expect_value(t, register_session_store(state, 2, "store_0500", 501), powerbox.Picker_Store_Refusal.None)
	store := principal_store_at(state, 1, 999)
	testing.expect(t, store != nil && string(store.candidate.name_bytes[:store.candidate.name_length]) == "store_0999")
	// The budget ends: each new store past the rows is refused.
	budget.rows_left = 0
	added := 0
	for index in 0 ..< 2000 {
		if refusal := register_session_store(state, 3, fmt.tprintf("more_%04d", index), u64(index + 1)); refusal != .None {
			testing.expect_value(t, refusal, powerbox.Picker_Store_Refusal.Table_Full)
			break
		}
		added += 1
	}
	testing.expect(t, added < 2000 && state.store_count == 1002 + added)
	// A replace of principal 1 frees its rows, and its names are new again.
	stores_replace_begin(state, 1)
	testing.expect_value(t, state.store_count, 1 + added)
	testing.expect_value(t, register_session_store(state, 1, "store_0500", 1), powerbox.Picker_Store_Refusal.None)
	testing.expect(t, principal_store_at(state, 2, 0) != nil)
}
