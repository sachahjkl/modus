// The words of the path of a wide grant between the root service and the
// trusted display (src/md/features/wide_grants.md, "The path of a grant, end
// to end"): the screen that the root service asks for, the answer of the
// principal, and the mark of a grant that holds. Each record crosses the
// control ring of the compositor in its seven values; this file is the one
// writer and the one border of each.
package wide_grants

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/remote"

// The windows that one screen offers, and that one answer names: two words
// of two ids of 32 bits.
SCREEN_WINDOWS_MOST :: 4
SCREEN_WINDOW_IDS_PER_WORD :: 2
#assert(SCREEN_WINDOWS_MOST <= MAX_TARGET_WINDOWS)
#assert(SCREEN_WINDOWS_MOST == 2 * SCREEN_WINDOW_IDS_PER_WORD)

// The largest id of a window that an answer carries. An id is the serial
// that the trusted display gave the window when it opened: it never names
// another window in one run, so a window that closes leaves no id that a
// new window takes. The display gives no id past this one.
SCREEN_WINDOW_ID_MOST :: u64(0xFFFF_FFFF)

// The two durations that the screen offers: one hour, and until the lock,
// which the bound of the contract caps at one day.
SCREEN_DURATION_ONE_HOUR :: DEFAULT_WIDE_GRANT_DURATION_MS
SCREEN_DURATION_UNTIL_LOCK :: MAX_WIDE_GRANT_DURATION_MS

// The scopes that the screen of this layer draws, one line each. An ask, a
// screen and an answer that name another scope are refused: the screen
// would give a scope that the principal never saw.
SCREEN_AUTHORITIES :: Wide_Authorities{.View_Screen, .Send_Input}

// screen_authorities_of_word is the border of a word of the scopes of an
// ask, a screen and an answer: one scope at least, each a scope of
// SCREEN_AUTHORITIES, and Send_Input only with View_Screen.
screen_authorities_of_word :: proc "contextless" (word: u64) -> (authorities: Wide_Authorities, ok: bool) {
	read := wide_authorities_from_word(word) or_return
	if read - SCREEN_AUTHORITIES != {} || (.Send_Input in read && .View_Screen not_in read) {
		return {}, false
	}
	return read, true
}

// The ask of a wide grant of an agent, on a stream of `remote` whose kind
// word is remote.Request_Kind.Wide_Grant_Ask (src/md/features/wide_grants.md,
// "The ask of an agent"). It names no key and no principal: `remote` gives
// the root service the key that the client proved in its handshake, and the
// root service takes the principal from the row of that key.
Wide_Grant_Ask_Request :: struct {
	kind:        u32, // remote.Request_Kind.Wide_Grant_Ask.
	reserved:    u32, // 0.
	authorities: u64, // The word of the scopes that the agent proposes.
	duration_ms: u64, // The longest duration that the screen offers.
}
#assert(size_of(Wide_Grant_Ask_Request) == 24)

// The names of the fields of a Wide_Grant_Ask_Request, for the sentence of
// a refusal: the argument of the error record is the index, from 1.
@(rodata)
WIDE_GRANT_ASK_FIELD_NAMES := [?]string{"kind", "reserved", "authorities", "duration_ms"}
WIDE_GRANT_ASK_FIELD_KIND :: 1
WIDE_GRANT_ASK_FIELD_RESERVED :: 2
WIDE_GRANT_ASK_FIELD_AUTHORITIES :: 3
WIDE_GRANT_ASK_FIELD_DURATION :: 4

// wide_grant_ask_write writes an ask in bytes, and gives the part written,
// or false when bytes has no room.
wide_grant_ask_write :: proc "contextless" (bytes: []u8, authorities: Wide_Authorities, duration_ms: u64) -> (written: []u8, ok: bool) {
	if len(bytes) < size_of(Wide_Grant_Ask_Request) {
		return nil, false
	}
	byte_order.write_u32_little_endian(bytes, 0, u32(remote.Request_Kind.Wide_Grant_Ask))
	byte_order.write_u32_little_endian(bytes, 4, 0)
	byte_order.write_u64_little_endian(bytes, 8, wide_authorities_to_word(authorities))
	byte_order.write_u64_little_endian(bytes, 16, duration_ms)
	return bytes[:size_of(Wide_Grant_Ask_Request)], true
}

// wide_grant_ask_check is the border of the ask of an agent, in `remote`:
// the bytes of the whole stream are one Wide_Grant_Ask_Request, whose words
// each name their member or their checked number. The error record names
// the field (WIDE_GRANT_ASK_FIELD_NAMES).
wide_grant_ask_check :: proc "contextless" (bytes: []u8) -> (authorities: Wide_Authorities, duration_ms: u64, error: errors.Error_Record, ok: bool) {
	size := size_of(Wide_Grant_Ask_Request)
	if len(bytes) < size {
		return {}, 0, errors.error_make(.Too_Small, .Bytes, 0, i64(len(bytes)), i64(size)), false
	}
	if len(bytes) > size {
		return {}, 0, errors.error_make(.Too_Long, .Bytes, 0, i64(len(bytes)), i64(size)), false
	}
	kind_word := byte_order.read_u32_little_endian(bytes, 0)
	if kind, kind_ok := remote.request_kind_of_word(kind_word); !kind_ok || kind != .Wide_Grant_Ask {
		return {}, 0, errors.error_make(.Bad_Value, .None, WIDE_GRANT_ASK_FIELD_KIND, i64(kind_word), i64(remote.Request_Kind.Wide_Grant_Ask)), false
	}
	if reserved := byte_order.read_u32_little_endian(bytes, 4); reserved != 0 {
		return {}, 0, errors.error_make(.Bad_Value, .None, WIDE_GRANT_ASK_FIELD_RESERVED, i64(reserved), 0), false
	}
	authorities_word := byte_order.read_u64_little_endian(bytes, 8)
	read_authorities, authorities_ok := screen_authorities_of_word(authorities_word)
	if !authorities_ok {
		return {}, 0, errors.error_make(.Bad_Value, .None, WIDE_GRANT_ASK_FIELD_AUTHORITIES, i64(min(authorities_word, u64(max(i64)))), i64(wide_authorities_to_word(SCREEN_AUTHORITIES))), false
	}
	duration := byte_order.read_u64_little_endian(bytes, 16)
	if duration == 0 || duration > MAX_WIDE_GRANT_DURATION_MS {
		return {}, 0, errors.error_make(.Out_Of_Range, .Milliseconds, WIDE_GRANT_ASK_FIELD_DURATION, i64(min(duration, u64(max(i64)))), i64(MAX_WIDE_GRANT_DURATION_MS)), false
	}
	return read_authorities, duration, {}, true
}

// What the principal pressed on the screen. The values cross the control
// ring.
Screen_Decision :: enum u64 {
	None   = 0, // Refused at the border.
	Give   = 1,
	Refuse = 2,
}

// The screen that the root service asks the trusted display to show.
Screen_Show :: struct {
	flow_serial:       u64, // Names this screen: the answer carries it back.
	principal_id:      u64,
	authorities:       Wide_Authorities, // The scopes that the ask proposed.
	duration_ms:       u64, // The duration that the ask proposed.
	client_key_head:   u64, // The first 8 bytes of the client key, for the words of the screen.
}

// The answer of the principal, after its border.
Screen_Answer :: struct {
	flow_serial:  u64,
	decision:     Screen_Decision,
	authorities:  Wide_Authorities, // Give only.
	duration_ms:  u64, // Give only.
	window_count: u32, // Give only: 1 to SCREEN_WINDOWS_MOST.
	window_ids:   [SCREEN_WINDOWS_MOST]u64,
}

// Why the border of an answer refused it.
Screen_Answer_Refusal :: enum u8 {
	None             = 0,
	No_Flow          = 1, // A flow serial of 0.
	Bad_Decision     = 2, // A word that names no decision, or None.
	Bad_Authorities  = 3, // A word of scopes that names no scope, none, or Send_Input without View_Screen.
	Bad_Duration     = 4, // 0, or past MAX_WIDE_GRANT_DURATION_MS.
	Bad_Window_Count = 5, // 0, or past SCREEN_WINDOWS_MOST.
	Bad_Window       = 6, // An id of 0 within the count, an id twice, or an id past the count.
	Words_After_Refuse = 7, // A refusal that carries scopes, a duration or windows.
}

// The mark of a grant that holds, as the root service gives it to the
// trusted display. A grant serial of 0 clears the mark.
Mark :: struct {
	grant_serial: u64,
	principal_id: u64,
	authorities:  Wide_Authorities,
	ends_at_ms:   u64, // The time of the system at which the grant ends.
	flow_serial:  u64, // The screen whose windows bound the input of the grant.
}

screen_show_values :: proc "contextless" (show: Screen_Show) -> (values: [7]u64) {
	return {show.flow_serial, show.principal_id, wide_authorities_to_word(show.authorities), show.duration_ms, show.client_key_head, 0, 0}
}

// screen_show_of_values is the border of the record of a screen, in the
// compositor: a flow serial of 0, a word of scopes that names no scope, a
// duration out of its bound and a word past the record are refused.
screen_show_of_values :: proc "contextless" (values: [7]u64) -> (show: Screen_Show, ok: bool) {
	if values[0] == 0 || values[5] != 0 || values[6] != 0 {
		return {}, false
	}
	authorities := screen_authorities_of_word(values[2]) or_return
	if values[3] == 0 || values[3] > MAX_WIDE_GRANT_DURATION_MS {
		return {}, false
	}
	return {flow_serial = values[0], principal_id = values[1], authorities = authorities, duration_ms = values[3], client_key_head = values[4]}, true
}

// screen_answer_values writes an answer. Ids past window_count are not
// written.
screen_answer_values :: proc "contextless" (answer: Screen_Answer) -> (values: [7]u64) {
	values[0] = answer.flow_serial
	values[1] = u64(answer.decision)
	if answer.decision != .Give {
		return values
	}
	values[2] = wide_authorities_to_word(answer.authorities)
	values[3] = answer.duration_ms
	values[4] = u64(answer.window_count)
	for index in 0 ..< min(int(answer.window_count), SCREEN_WINDOWS_MOST) {
		id := answer.window_ids[index] & SCREEN_WINDOW_ID_MOST
		values[5 + index / SCREEN_WINDOW_IDS_PER_WORD] |= id << (32 * u64(index % SCREEN_WINDOW_IDS_PER_WORD))
	}
	return values
}

// screen_answer_of_values is the border of an answer, in the root service.
// Each word becomes its member or its checked number, or the answer is
// refused whole with its refusal.
screen_answer_of_values :: proc "contextless" (values: [7]u64) -> (answer: Screen_Answer, refusal: Screen_Answer_Refusal) {
	if values[0] == 0 {
		return {}, .No_Flow
	}
	decision, decision_ok := enum_word.member_of_word(Screen_Decision, values[1])
	if !decision_ok || decision == .None {
		return {}, .Bad_Decision
	}
	if decision == .Refuse {
		if values[2] != 0 || values[3] != 0 || values[4] != 0 || values[5] != 0 || values[6] != 0 {
			return {}, .Words_After_Refuse
		}
		return {flow_serial = values[0], decision = .Refuse}, .None
	}
	authorities, authorities_ok := screen_authorities_of_word(values[2])
	if !authorities_ok {
		return {}, .Bad_Authorities
	}
	if values[3] == 0 || values[3] > MAX_WIDE_GRANT_DURATION_MS {
		return {}, .Bad_Duration
	}
	if values[4] == 0 || values[4] > SCREEN_WINDOWS_MOST {
		return {}, .Bad_Window_Count
	}
	count := int(values[4])
	answer = {flow_serial = values[0], decision = .Give, authorities = authorities, duration_ms = values[3], window_count = u32(count)}
	for index in 0 ..< SCREEN_WINDOWS_MOST {
		id := (values[5 + index / SCREEN_WINDOW_IDS_PER_WORD] >> (32 * u64(index % SCREEN_WINDOW_IDS_PER_WORD))) & SCREEN_WINDOW_ID_MOST
		if index >= count {
			if id != 0 {
				return {}, .Bad_Window
			}
			continue
		}
		if id == 0 {
			return {}, .Bad_Window
		}
		for earlier in 0 ..< index {
			if answer.window_ids[earlier] == id {
				return {}, .Bad_Window
			}
		}
		answer.window_ids[index] = id
	}
	return answer, .None
}

mark_values :: proc "contextless" (mark: Mark) -> (values: [7]u64) {
	return {mark.grant_serial, mark.principal_id, wide_authorities_to_word(mark.authorities), mark.ends_at_ms, mark.flow_serial, 0, 0}
}

// mark_of_values is the border of a mark, in the compositor: a serial of 0
// clears the mark and carries no other word; a mark that holds names its
// scopes, its end and its screen.
mark_of_values :: proc "contextless" (values: [7]u64) -> (mark: Mark, ok: bool) {
	if values[5] != 0 || values[6] != 0 {
		return {}, false
	}
	if values[0] == 0 {
		return {}, values[1] == 0 && values[2] == 0 && values[3] == 0 && values[4] == 0
	}
	authorities := screen_authorities_of_word(values[2]) or_return
	if values[3] == 0 || values[4] == 0 {
		return {}, false
	}
	return {grant_serial = values[0], principal_id = values[1], authorities = authorities, ends_at_ms = values[3], flow_serial = values[4]}, true
}

// window_leaves_bound removes the id of a window that closed from an
// answer. The answer keeps its other windows; with none left, the input of
// a viewer reaches no window.
window_leaves_bound :: proc "contextless" (answer: ^Screen_Answer, window_id: u64) {
	count := min(int(answer.window_count), SCREEN_WINDOWS_MOST)
	kept := 0
	for index in 0 ..< count {
		if answer.window_ids[index] != window_id {
			answer.window_ids[kept] = answer.window_ids[index]
			kept += 1
		}
	}
	for index in kept ..< SCREEN_WINDOWS_MOST {
		answer.window_ids[index] = 0
	}
	answer.window_count = u32(kept)
}

// window_in_bound says if a window id is among the ids of an answer: the
// one test of the input of a viewer while a grant holds.
window_in_bound :: proc "contextless" (answer: ^Screen_Answer, window_id: u64) -> bool {
	if window_id == 0 || answer.decision != .Give {
		return false
	}
	for index in 0 ..< min(int(answer.window_count), SCREEN_WINDOWS_MOST) {
		if answer.window_ids[index] == window_id {
			return true
		}
	}
	return false
}
