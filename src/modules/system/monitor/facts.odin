package monitor

import "modus:contract/errors"
import "modus:contract/value_kinds"
import process_page "modus:contract/disk_process_page"

// The log facts of the monitor (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. A Text field
// is the last field and holds its longest text and a zero byte: the serial
// line of a fact stops at its last byte that is not zero.

// The bytes of the Text field of a nickname: the longest nickname and a
// zero byte.
NICKNAME_FIELD_BYTES :: process_page.NICKNAME_LIMIT + 1
// The bytes of the Text field of a hash prefix: its digits, a zero byte,
// and the bytes that end the record on 8 bytes.
HASH_PREFIX_FIELD_BYTES :: 24
#assert(HASH_PREFIX_FIELD_BYTES > process_page.HASH_PREFIX_DIGITS)

// A disk process that the monitor shows for the first time: its nickname,
// its hash prefix and the whole hash of its file, as the root service wrote
// them in the disk process page.
@(log_fact = "monitor: the disk process {nickname}, hash prefix {hash_prefix}, the file {file_hash}, from the root service")
Disk_Process_Shown :: struct {
	file_hash:   value_kinds.Hash_Field,
	hash_prefix: [24]u8,
	nickname:    [24]u8,
}
#assert(size_of(Disk_Process_Shown) == value_kinds.HASH_FIELD_BYTES + HASH_PREFIX_FIELD_BYTES + NICKNAME_FIELD_BYTES)

// The monitor has no grant to inspect the machine: it shows nothing of it.
@(log_fact = "monitor: no grant to inspect the machine")
No_Inspect_Grant :: struct {}

// The first picture of the monitor is drawn.
@(log_fact = "monitor: ok")
Window_Ready :: struct {}

// The bytes of the Text field of a problem of the kept record: the longest
// of chosen_values.RECORD_PROBLEM_NAMES, and a zero byte.
SETTINGS_PROBLEM_FIELD_BYTES :: size_of(Settings_Unreadable{}.problem)

@(log_fact = "monitor: no private store: the settings hold for this run only")
Settings_Not_Kept :: struct {}

@(log_fact = "monitor: the store did not give the kept settings, so the defaults hold and the record stays as it is: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Settings_Not_Read :: distinct errors.Error_Record_Fact_Fields

@(log_fact = "monitor: the kept settings are a record that this release cannot read ({problem}): the defaults hold, and the record stays as it is until the principal changes a setting")
Settings_Unreadable :: struct {
	problem: [24]u8, // N written out: the tool reads the size of a Text field from the source.
}

@(log_fact = "monitor: the store did not keep a setting, which holds for this run only: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Settings_Write_Refused :: distinct errors.Error_Record_Fact_Fields
