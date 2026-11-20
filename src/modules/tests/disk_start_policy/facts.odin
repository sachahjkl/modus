package disk_start_policy

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the start policy from the disk
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before; a
// status that the line wrote as its number is now the name of its member.
// No field has the name of a column of the head of facts(): number, time,
// process, level.
//
// The name of a command of the root ring is a Text field: root_ring is no
// contract enum that a field can name. A Text field is the last field, and
// is [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of the name of a command of the root ring:
// the longest, "Disk_Grant_Persistence", has 22 bytes, and a zero byte;
// with the status of 4 bytes before it, the record ends on 4 bytes.
COMMAND_FIELD_BYTES :: 28

// The start policy from the disk runs.
@(log_fact = "disk_start_policy: ok, a start policy from the disk: its order is in its code")
Running :: struct {}

// The root ring does not open.
@(log_fact = "disk_start_policy: the root ring does not open: status {status}")
Root_Ring_Refused :: struct {
	status: op.Status,
}

// The context holds the log, the budget and the root ring only.
@(log_fact = "disk_start_policy: the context holds the log, the budget and the root ring, no other handle and no start list: as it must")
Context_Checked :: struct {}

// The machine parts page is refused: only the console starts.
@(log_fact = "disk_start_policy: the machine parts page is refused: it starts the console only")
Parts_Page_Refused :: struct {}

// The root service refused a start of the start policy of the boot image.
@(log_fact = "disk_start_policy: a start of the start policy of the boot image is refused with the status {status}: as it must")
Start_Policy_Start_Refused :: struct {
	status: op.Status,
}

// The root service took a start of the start policy of the boot image.
@(log_fact = "disk_start_policy: a start of the start policy of the boot image is taken: WRONG")
Wrong_Start_Policy_Start_Taken :: struct {}

// A command of the console was not refused with No_Right.
@(log_fact = "disk_start_policy: the command {command} gives the status {status}, not No_Right: WRONG")
Wrong_Command_Not_Refused :: struct {
	status:  op.Status,
	command: [28]u8,
}

// Each command of the console was refused with No_Right.
@(log_fact = "disk_start_policy: Start_Policy_Choice, Start_From_Disk, Disk_Grant and Connect are refused with No_Right: as it must")
Commands_Refused :: struct {}

// A process of its order did not start.
@(log_fact = "disk_start_policy: cannot start {started_process}: status {status}")
Start_Refused :: struct {
	status:          op.Status,
	started_process: value_kinds.Module_Name_Field,
}

// The root service refused Machine_Usable.
@(log_fact = "disk_start_policy: the root service refused Machine_Usable: status {status}")
Machine_Usable_Refused :: struct {
	status: op.Status,
}

// The console runs: the machine is usable.
@(log_fact = "disk_start_policy: the console runs: the machine is usable")
Machine_Is_Usable :: struct {}

#assert(size_of(Wrong_Command_Not_Refused) == size_of(op.Status) + COMMAND_FIELD_BYTES)

// command_field gives the Text field of the name of a command of the root
// ring.
command_field :: proc "contextless" (name: string) -> [COMMAND_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, COMMAND_FIELD_BYTES)
}

// The context holds a handle or a start list that a start policy from the
// disk must not receive.
@(log_fact = "disk_start_policy: the context holds {other_handles} other handles and a list of {list_bytes} bytes: WRONG")
Wrong_Context :: struct {
	other_handles: u64,
	list_bytes:    u64,
}

// A process of its order that needs a screen, on a machine with none.
@(log_fact = "disk_start_policy: {started_process} is not started: the machine has no screen")
Not_Started_Without_Screen :: struct {
	started_process: value_kinds.Module_Name_Field,
}

// A process of its order started.
@(log_fact = "disk_start_policy: started {started_process}")
Started :: struct {
	started_process: value_kinds.Module_Name_Field,
}
