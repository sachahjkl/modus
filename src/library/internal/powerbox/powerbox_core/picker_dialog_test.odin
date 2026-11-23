#+build !freestanding
package powerbox_core

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
		testing.expect(t, register_session_store(state, 3, name, u64(index + 1)))
	}
	// A store of another principal is no candidate of principal 3.
	testing.expect(t, register_session_store(state, 4, "secret", 1))
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
