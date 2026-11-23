// The act records of `remote` under a wide grant
// (src/md/features/wide_grants.md, "The record of each act").
//
// Each call of a key whose row of the client table holds a wide grant
// writes a Call_Made record onto `acts` without blocking, before the call
// runs. Each status but Ok refuses the call: a full ring, and also a ring
// with no reader, whose record no one keeps (wide_grants.act_emit).
package remote_service

import "modus:contract/wide_grants"
import "modus:system"

// The act records of the calls of a key while a wide grant of that key
// holds.
acts: system.Record_Output(wide_grants.Act_Stream_Record)

// act_write is the write of wide_grants.act_emit: the status of the output
// becomes its member of Act_Write_Status, at this border.
@(private = "file")
act_write :: proc "contextless" (user: rawptr, record: wide_grants.Act_Stream_Record) -> wide_grants.Act_Write_Status {
	switch system.output_write(&acts, record, wait = false) {
	case .Ok:
		return .Ok
	case .Full:
		return .Full
	case .No_Reader:
		return .No_Reader
	case .No_Writer:
		return .No_Writer
	case .Ended:
		return .Ended
	case .Bad_Record:
		return .Bad_Record
	case .No_Record:
		return .No_Record
	}
	return .Bad_Record
}

// call_act_record writes the record of one call under the grant of a row:
// the head of the hash of the service, and the bytes of the request. It
// says if the call may run.
call_act_record :: proc "contextless" (grant_serial: u64, principal_id: u64, service_hash: [32]u8, request_bytes: u64) -> (outcome: wide_grants.Act_Emit_Outcome, status: wide_grants.Act_Write_Status) {
	record := wide_grants.call_made_record(grant_serial, principal_id, service_hash, request_bytes, system.time())
	return wide_grants.act_emit(act_write, nil, record)
}
