package wiring

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the wiring service (src/md/features/log_facts.md): each
// line, as a record of fields. Each fact template is the sentence that the
// line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before; a status that the line wrote as its number
// is now the name of its member. A template has no condition, so a line
// that wrote "its asker " for one kind of reader is two fact types. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// The service ring of the core does not open.
@(log_fact = "wiring: no service ring")
No_Service_Ring :: struct {}

// The stops ring of the core does not open.
@(log_fact = "wiring: no stops ring")
No_Stops_Ring :: struct {}

// The context holds no read-only view of the boot image.
@(log_fact = "wiring: no read-only boot image")
No_Boot_Image :: struct {}

// The map of the boot image failed.
@(log_fact = "wiring: cannot map boot image")
Boot_Image_Not_Mapped :: struct {}

// The transfer region has fewer pages than the service needs.
@(log_fact = "wiring: transfer region too small")
Transfer_Region_Too_Small :: struct {}

// The map of the transfer region failed.
@(log_fact = "wiring: cannot map transfer region")
Transfer_Region_Not_Mapped :: struct {}

// The end page of a wiring slot does not map, so its end words are not
// written.
@(log_fact = "wiring: cannot map end page of slot {wiring_slot}: status {status}")
End_Page_Not_Mapped :: struct {
	wiring_slot: u64,
	status:      call_outcome.Call_Outcome_Word,
}

// The record output log of a process is wired to its asker.
@(log_fact = "wiring: wired the record output log of {writer_module} to its asker {reader_module}, wiring {wiring_number}")
Log_Wired_To_Asker :: struct {
	wiring_number: u64,
	writer_module: value_kinds.Module_Name_Field,
	reader_module: value_kinds.Module_Name_Field,
}

// The record output log of a process is wired to a reader that is not its
// asker.
@(log_fact = "wiring: wired the record output log of {writer_module} to {reader_module}, wiring {wiring_number}")
Log_Wired :: struct {
	wiring_number: u64,
	writer_module: value_kinds.Module_Name_Field,
	reader_module: value_kinds.Module_Name_Field,
}

// A record output of a process is wired to its asker.
@(log_fact = "wiring: wired the record output {writer_output} of {writer_module} to its asker {reader_module}, wiring {wiring_number}")
Output_Wired_To_Asker :: struct {
	writer_output: u64,
	wiring_number: u64,
	writer_module: value_kinds.Module_Name_Field,
	reader_module: value_kinds.Module_Name_Field,
}

// A record output of a process is wired to a reader that is not its asker.
@(log_fact = "wiring: wired the record output {writer_output} of {writer_module} to {reader_module}, wiring {wiring_number}")
Output_Wired :: struct {
	writer_output: u64,
	wiring_number: u64,
	writer_module: value_kinds.Module_Name_Field,
	reader_module: value_kinds.Module_Name_Field,
}

// A record of the stops ring is no stop notice.
@(log_fact = "wiring: refused malformed stop notice on stops ring, kind {notice_kind}")
Stop_Notice_Refused :: struct {
	notice_kind: u64,
}

// A process refused its end of a wiring.
@(log_fact = "wiring: {process_module} refused its end of the wiring {wiring_number}")
Wiring_End_Refused :: struct {
	wiring_number:  u64,
	process_module: value_kinds.Module_Name_Field,
}

// A process wrote a word of its wiring ring that names no wiring of it:
// the first such word, since each later one is only counted.
@(log_fact = "wiring: {process_module} wrote a word of its wiring ring that names no wiring of it: it is dropped, and each later one is counted until its stop")
Unknown_Wiring_Word :: struct {
	process_module: value_kinds.Module_Name_Field,
}

// A process wrote a word of its wiring ring for a wiring after its answer.
@(log_fact = "wiring: {process_module} wrote a word of its wiring ring for the wiring {wiring_number} after its answer: dropped")
Wiring_Word_Dropped :: struct {
	wiring_number:  u64,
	process_module: value_kinds.Module_Name_Field,
}

// The service runs, with the read-only view of the boot image.
@(log_fact = "wiring: ready, read-only boot image {image_bytes} bytes")
Ready :: struct {
	image_bytes: u64,
}

// A wiring of the pace Always_Holds_Writer whose reader stalled past the
// bound is revoked.
@(log_fact = "wiring: revoked stalled Always_Holds_Writer wiring {wiring_number}")
Stalled_Wiring_Revoked :: struct {
	wiring_number: u64,
}
