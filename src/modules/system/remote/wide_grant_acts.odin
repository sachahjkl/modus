// Wide-grant act record output of the remote service
// (src/md/features/wide_grants.md, "The record of each act").
//
// Each call of a key whose row of the client table holds a wide grant emits
// a Call_Made record onto `acts` without blocking. When the audit ring is
// full, the caller refuses the call with Busy so no call runs unrecorded.
package remote_service

import "modus:contract/wide_grants"
import "modus:system"

// Wide-grant act records emitted by remote for the calls of a key while a
// wide grant of that key holds.
acts: system.Record_Output(wide_grants.Act_Stream_Record)

// remote_wide_grant_act_emit writes one remote-service act record onto `acts`
// without blocking. Returns busy == true when an audit ring is full so the
// caller refuses the call rather than running it unrecorded.
remote_wide_grant_act_emit :: proc "contextless" (
	grant_serial: u64,
	principal_id: u64,
	kind: wide_grants.Act_Kind,
	target_window_id: u64 = 0,
	detail_word_0: u64 = 0,
	detail_word_1: u64 = 0,
) -> (recorded: bool, busy: bool) {
	if grant_serial == 0 || kind == .None {
		return false, false
	}
	record := wide_grants.Act_Stream_Record {
		grant_serial     = grant_serial,
		principal_id     = principal_id,
		timestamp_ms     = system.time(),
		producer_word    = u64(wide_grants.Act_Producer.Remote_Service),
		act_kind_word    = u64(kind),
		target_window_id = target_window_id,
		detail_word_0    = detail_word_0,
		detail_word_1    = detail_word_1,
	}
	switch system.output_write(&acts, record, wait = false) {
	case .Ok:
		return true, false
	case .Full:
		return false, true
	case .No_Reader, .No_Writer, .Ended, .Bad_Record, .No_Record:
		return false, false
	}
	return false, false
}
