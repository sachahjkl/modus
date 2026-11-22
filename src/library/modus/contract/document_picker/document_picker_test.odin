#+build !freestanding
package document_picker

import "core:testing"

@(test)
document_picker_grants_and_drop_only_drag_and_drop :: proc(t: ^testing.T) {
	_, bad := drag_state_of_word(99)
	testing.expect(t, !bad)

	svc: Document_Service
	document_service_init(&svc)
	doc_id, r := document_register(&svc, 1, "notes.txt")
	testing.expect_value(t, r, Picker_Refusal.None)
	_, r_dup := document_register(&svc, 1, "notes.txt")
	testing.expect_value(t, r_dup, Picker_Refusal.Duplicate_Doc)

	// Start drag from window 10, hover over window 20 (process slot 5):
	// process 5 MUST NOT hold any grant during hover!
	drag: Drag_Session
	testing.expect_value(t, drag_begin(&drag, 10, doc_id, {.Read}), Picker_Refusal.None)
	testing.expect_value(t, drag_hover(&drag, 20), Picker_Refusal.None)
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Read}))

	// Explicit drop onto window 20 mints Read-only grant to process 5 and resets drag.
	gid, r_drop := drag_drop(&drag, &svc, 20, 5)
	testing.expect_value(t, r_drop, Picker_Refusal.None)
	testing.expect(t, document_process_has_grant(&svc, doc_id, 5, {.Read}))
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Write}))
	testing.expect_value(t, drag.state, Drag_State.Idle)

	// Second drop refused because drag ended.
	_, r_again := drag_drop(&drag, &svc, 20, 5)
	testing.expect_value(t, r_again, Picker_Refusal.Drop_Not_Active)

	// Principal revokes grant cleanly.
	testing.expect_value(t, document_grant_revoke(&svc, gid), Picker_Refusal.None)
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Read}))
}
