// The step of a writer of act records (src/md/features/wide_grants.md, "No
// act without its record"): `remote` and the trusted display write each
// record through act_emit, and run the act only when the record left. The
// trusted display joins its input into one record for each change of the
// window that takes it (Input_Target).
package wide_grants

// What the write of a record on the ring `acts` gave, as the writer reads
// it from its output. The module maps its status to this set at its border.
Act_Write_Status :: enum u8 {
	Ok         = 0,
	Full       = 1, // The ring has no room now.
	No_Reader  = 2, // The output has no wiring: the collector does not read it yet, or no more.
	No_Writer  = 3,
	Ended      = 4, // The wiring ended.
	Bad_Record = 5,
	No_Record  = 6,
}

// What act_emit says of the act.
Act_Emit_Outcome :: enum u8 {
	No_Grant = 0, // No grant holds: the act runs as without a grant, with no record.
	Recorded = 1, // The record left: the act runs.
	Refused  = 2, // A grant holds and its record did not leave: the act does not run.
}

// The write of one record, by the module.
Act_Write :: #type proc "contextless" (user: rawptr, record: Act_Stream_Record) -> Act_Write_Status

// act_emit writes the record of an act while a grant holds. Each status but
// Ok refuses the act: a full ring, and also a ring with no reader, whose
// record no one keeps. A grant serial of 0 is no grant.
act_emit :: proc "contextless" (write: Act_Write, user: rawptr, record: Act_Stream_Record) -> (outcome: Act_Emit_Outcome, status: Act_Write_Status) {
	if record.grant_serial == 0 {
		return .No_Grant, .Ok
	}
	status = write(user, record)
	switch status {
	case .Ok:
		return .Recorded, status
	case .Full, .No_Reader, .No_Writer, .Ended, .Bad_Record, .No_Record:
		return .Refused, status
	}
	return .Refused, status
}

// call_made_record gives the record of one call of `remote` under a grant:
// the first 8 bytes of the hash of the module of the service, little-endian,
// and the bytes of the request.
call_made_record :: proc "contextless" (grant_serial: u64, principal_id: u64, service_hash: [32]u8, request_bytes: u64, time_ms: u64) -> Act_Stream_Record {
	head: u64
	for index in 0 ..< 8 {
		head |= u64(service_hash[index]) << (8 * u64(index))
	}
	return {
		grant_serial  = grant_serial,
		principal_id  = principal_id,
		timestamp_ms  = time_ms,
		producer_word = u64(Act_Producer.Remote_Service),
		act_kind_word = u64(Act_Kind.Call_Made),
		detail_word_0 = head,
		detail_word_1 = request_bytes,
	}
}

// The window that takes the input of a viewer under a grant, as its last
// record names it, and what it took since.
Input_Target :: struct {
	window:  u64, // 0: no record names a window yet.
	keys:    u64,
	presses: u64,
}

// What a viewer gives a window.
Input_Act :: enum u8 {
	Key   = 0,
	Move  = 1, // A move of the pointer with no press: no act, but the window is its target.
	Press = 2,
}

// input_target_record gives the record that must leave before an act on
// window, or false when the last record names that window already.
input_target_record :: proc "contextless" (target: ^Input_Target, grant_serial: u64, principal_id: u64, window: u64, time_ms: u64) -> (record: Act_Stream_Record, needed: bool) {
	if window == target.window {
		return {}, false
	}
	return {
		grant_serial     = grant_serial,
		principal_id     = principal_id,
		timestamp_ms     = time_ms,
		producer_word    = u64(Act_Producer.Trusted_Display),
		act_kind_word    = u64(Act_Kind.Target_Window_Changed),
		target_window_id = window,
		detail_word_0    = target.keys,
		detail_word_1    = target.presses,
	}, true
}

// input_target_taken says that the record of window left: the counts start
// again for it.
input_target_taken :: proc "contextless" (target: ^Input_Target, window: u64) {
	target^ = {window = window}
}

// input_target_count counts an act that ran on the window of the target.
input_target_count :: proc "contextless" (target: ^Input_Target, act: Input_Act) {
	switch act {
	case .Key:
		target.keys += 1
	case .Press:
		target.presses += 1
	case .Move:
	}
}
