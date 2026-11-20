package disk_start_policy

import "modus:contract/value_kinds"

// The log facts of the start policy from the disk
// (src/md/features/log_facts.md): the lines with a value, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. A line that writes a status as its number stays text: a field of
// a status writes the name of its member. No field has the name of a
// column of the head of facts(): number, time, process, level.

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
