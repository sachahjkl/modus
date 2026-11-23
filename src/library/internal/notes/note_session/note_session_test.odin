#+build !freestanding
package note_session

import "core:testing"
import "internal:notes/store_work"

@(private = "file")
listed_session :: proc() -> Session {
	session: Session
	listed_now(&session, .Done)
	return session
}

// Before the list: a new note, a deletion, a typed key and a commit
// would act on a note that the list then replaces.
@(test)
no_key_changes_a_note_or_the_list_before_the_list_comes :: proc(t: ^testing.T) {
	session: Session
	testing.expect(t, !text_keys_act(&session))
	testing.expect(t, !list_keys_act(&session))
	testing.expect(t, !commit_allowed(&session))
	testing.expect(t, !delete_asked(&session))
	testing.expect_value(t, session.mode, Mode.Notes)
	testing.expect(t, result_taken(&session, .List, 1))
	listed_now(&session, .Done)
	testing.expect(t, text_keys_act(&session) && list_keys_act(&session) && commit_allowed(&session))
	// A second List result is not taken.
	testing.expect(t, !result_taken(&session, .List, 1))
}

@(test)
a_list_with_no_store_keeps_nothing_and_still_takes_the_keys :: proc(t: ^testing.T) {
	session: Session
	listed_now(&session, .No_Store)
	testing.expect(t, text_keys_act(&session))
	testing.expect(t, !commit_allowed(&session))
	testing.expect_value(t, show_room(&session, true, true), 0)
}

// A deletion needs room for its removal and for the load of the note
// shown after it, before it starts.
@(test)
a_deletion_counts_the_room_of_its_removal_and_of_the_next_load :: proc(t: ^testing.T) {
	session := listed_session()
	testing.expect_value(t, delete_room(&session, true, true), 2)
	testing.expect_value(t, delete_room(&session, true, false), 1)
	testing.expect_value(t, delete_room(&session, false, true), 1)
	testing.expect_value(t, delete_room(&session, false, false), 0)
	testing.expect_value(t, show_room(&session, true, true), 2)
	testing.expect_value(t, show_room(&session, false, true), 1)
	// A change of a locked note is never written: no room for its commit.
	session.locked = true
	testing.expect_value(t, show_room(&session, true, false), 0)
}

// A restore makes current the version whose bytes came, and the window
// loads the note from the store after it.
@(test)
a_restore_needs_the_bytes_of_its_version_and_holds_the_keys_until_its_result :: proc(t: ^testing.T) {
	session := listed_session()
	versions_asked_now(&session, 5)
	testing.expect(t, !text_keys_act(&session))
	testing.expect(t, versions_done(&session, .Done, 3))
	version_asked(&session, 6)
	// Enter before the bytes of the version came.
	testing.expect(t, !restore_allowed(&session, false))
	version_done(&session, .Refused)
	testing.expect(t, !restore_allowed(&session, false))
	// Down: another version; its result is not there yet.
	version_asked(&session, 7)
	testing.expect(t, !result_taken(&session, .Version, 6))
	testing.expect(t, result_taken(&session, .Version, 7))
	version_done(&session, .Done)
	testing.expect(t, !restore_allowed(&session, true))
	testing.expect(t, restore_allowed(&session, false))
	restore_asked_now(&session, 8)
	// While the restore waits: no key chooses, restores, goes back or types.
	testing.expect(t, !versions_keys_act(&session))
	testing.expect(t, !restore_allowed(&session, false))
	testing.expect(t, !text_keys_act(&session))
	versions_closed(&session)
	testing.expect_value(t, session.mode, Mode.Versions)
	testing.expect(t, !result_taken(&session, .Restore, 7))
	testing.expect(t, result_taken(&session, .Restore, 8))
	testing.expect(t, restore_done(&session, .Done))
	testing.expect_value(t, session.mode, Mode.Notes)
	load_asked(&session, 9)
	testing.expect(t, !text_keys_act(&session))
	testing.expect_value(t, load_done(&session, .Done), Load_Outcome.Text)
	testing.expect(t, text_keys_act(&session))
}

@(test)
a_refused_restore_stays_in_the_versions :: proc(t: ^testing.T) {
	session := listed_session()
	versions_asked_now(&session, 1)
	versions_done(&session, .Done, 2)
	version_asked(&session, 2)
	version_done(&session, .Done)
	restore_asked_now(&session, 3)
	testing.expect(t, !restore_done(&session, .Refused))
	testing.expect_value(t, session.mode, Mode.Versions)
	testing.expect(t, versions_keys_act(&session))
}

// The versions open only from the list, for the request that the window
// waits for.
@(test)
a_result_of_the_versions_opens_no_pane_over_the_question_or_after_another_request :: proc(t: ^testing.T) {
	session := listed_session()
	versions_asked_now(&session, 4)
	// The keys wait for the result: no typed key, no question.
	testing.expect(t, !text_keys_act(&session))
	testing.expect(t, !delete_asked(&session))
	testing.expect(t, !result_taken(&session, .Versions, 3))
	testing.expect(t, result_taken(&session, .Versions, 4))
	session.mode = .Delete
	testing.expect(t, !versions_done(&session, .Done, 3))
	testing.expect_value(t, session.mode, Mode.Delete)
	testing.expect(t, !session.versions_asked)
	// No version, or a refusal: no pane.
	session.mode = .Notes
	versions_asked_now(&session, 5)
	testing.expect(t, !versions_done(&session, .Done, 0))
	versions_asked_now(&session, 6)
	testing.expect(t, !versions_done(&session, .Refused, 4))
	testing.expect_value(t, session.mode, Mode.Notes)
	// A result that came after the window took one is not taken.
	testing.expect(t, !result_taken(&session, .Versions, 6))
}

// A note that cannot be read is shown locked and never written.
@(test)
a_note_that_cannot_be_read_is_locked_until_another_note_is_shown :: proc(t: ^testing.T) {
	for status in ([?]store_work_status{.Too_Long, .Refused, .Unanswered, .No_Store}) {
		session := listed_session()
		load_asked(&session, 1)
		testing.expect(t, !commit_allowed(&session))
		testing.expect_value(t, load_done(&session, status), Load_Outcome.Unreadable)
		testing.expect(t, session.locked)
		testing.expect(t, !commit_allowed(&session))
		testing.expect(t, !text_keys_act(&session))
		// The list keys still act: the principal goes to another note.
		testing.expect(t, list_keys_act(&session))
		load_asked(&session, 2)
		testing.expect(t, !session.locked)
	}
	session := listed_session()
	load_asked(&session, 1)
	testing.expect_value(t, load_done(&session, .Damaged), Load_Outcome.Empty)
	testing.expect(t, commit_allowed(&session))
	load_asked(&session, 2)
	testing.expect(t, !result_taken(&session, .Load, 1))
	testing.expect_value(t, load_done(&session, .Absent), Load_Outcome.Empty)
	testing.expect(t, !result_taken(&session, .Load, 2))
}

@(test)
only_a_call_with_no_answer_ends_the_keeping :: proc(t: ^testing.T) {
	session := listed_session()
	for status in ([?]store_work_status{.Done, .Absent, .Damaged, .Too_Long, .Refused, .No_Store}) {
		unanswered(&session, status)
		testing.expect(t, session.keeping)
	}
	unanswered(&session, .Unanswered)
	testing.expect(t, !session.keeping)
}

@(private = "file")
store_work_status :: store_work.Result_Status
