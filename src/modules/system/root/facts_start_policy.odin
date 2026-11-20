package root

import "modus:contract/value_kinds"

// The log facts of the start policy and of its choice by principal 0
// (src/md/features/log_facts.md). Each fact template is the sentence that
// the line wrote before it was a fact; the Integer and Bytes fields come
// first and the Text fields last. A bound is a time in milliseconds, which
// the line wrote as the number and " ms".

// unlock gave no machine key within its bound: the choice is not read.
@(log_fact = "root: unlock gave no machine key within the hang bound of {bound}: the choice of principal 0 is not read, and unlock is stopped")
Unlock_Machine_Key_Late :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// unlock did not stop within its bound after its stop was asked.
@(log_fact = "root: unlock did not stop within the hang bound of {bound} after its stop was asked: the start policy starts, and its row unlock does not start while it runs")
Unlock_Stop_Late :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// The read of the disk grant table of principal 0 did not end within its
// bound.
@(log_fact = "root: the read of the disk grant table of principal 0 did not end within the hang bound of {bound}: the choice of principal 0 is not read")
Machine_Table_Read_Late :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// The chosen start policy has a name that the root service gives a grant
// or that a module of the boot image has: the rescue starts.
@(log_fact = "root: the chosen start policy \"{nickname}\" is not read: the root service gives this name a grant, or a module of the boot image has it: the rescue start policy starts")
Chosen_Start_Policy_Name_Reserved :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// The chosen start policy is not read: another load from the disk runs.
@(log_fact = "root: the chosen start policy \"{nickname}\" is not read: another load from the disk runs: the rescue start policy starts")
Chosen_Start_Policy_Load_Busy :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// The chosen start policy is not read: the call ring and the call region of
// the storage service do not map.
@(log_fact = "root: the chosen start policy \"{nickname}\" is not read: the call ring and the call region of the storage service do not map: the rescue start policy starts")
Chosen_Start_Policy_Not_Mapped :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// This service reads the chosen start policy from the store of the module
// files of principal 0.
@(log_fact = "root: reads the chosen start policy \"{nickname}\", the file {hash}, from the store module_files of principal 0")
Chosen_Start_Policy_Read :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

// The chosen start policy cannot be measured: it does not run unmeasured.
@(log_fact = "root: the chosen start policy \"{nickname}\" does not run unmeasured: it is not started")
Chosen_Start_Policy_Unmeasured :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A choice of a start policy refused: the caller acts for another principal
// than principal 0.
@(log_fact = "root: refused a choice of a start policy: the caller acts for principal {principal}, and only principal 0 chooses the start policy of the machine")
Start_Policy_Choice_Refused_Principal :: struct {
	principal: u64,
}

// A start policy refused: its nickname is a name that the root service
// gives a grant or that a module of the boot image has.
@(log_fact = "root: refused the start policy {nickname}: the root service gives this name a grant, or a module of the boot image has it, and the start policy runs under its nickname")
Start_Policy_Refused_Reserved_Name :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A start policy refused: its nickname has no row.
@(log_fact = "root: refused the start policy {nickname}: the nickname names no module, as it has no row in the disk grant table of principal 0; name the hash of its file")
Start_Policy_Refused_No_Row :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A start policy refused: its nickname names another file than the
// command.
@(log_fact = "root: refused the start policy {nickname}: the nickname names the file {named_hash}, and the command names the file {hash}")
Start_Policy_Refused_Other_File :: struct {
	named_hash: value_kinds.Hash_Field,
	hash:       value_kinds.Hash_Field,
	nickname:   value_kinds.Module_Name_Field,
}

// A start policy refused: its row holds the grant store.
@(log_fact = "root: refused the start policy {nickname}: its row holds the grant store, and a start policy holds the grant Start_Policy and nothing else")
Start_Policy_Refused_Holds_Store :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// Principal 0 chose a start policy for the next start of the machine.
@(log_fact = "root: principal 0 chose the start policy {nickname}, the file {hash}: it runs at the next start of the machine, with the grant Start_Policy only; the machine key keeps the choice on the disk")
Start_Policy_Chosen :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

// The boot record names a start request that the border refuses: the
// rescue starts.
@(log_fact = "root: the boot record names the start request {start_request} with the source {start_request_source}, which the border refuses: the rescue start policy starts")
Start_Request_Refused :: struct {
	start_request:        u64,
	start_request_source: u64,
}

// No start policy at all: the cause is a sentence of a closed set of this
// service.
@(log_fact = "root: no start policy at all: {failure_cause}; this service serves the root ring of each process that runs, and starts nothing more")
No_Start_Policy :: struct {
	failure_cause: [72]u8,
}

// Processes of the failed start policy did not stop within the bound: the
// rescue starts beside them.
@(log_fact = "root: {left_processes} processes of the failed start policy did not stop within the hang bound of {bound}: the rescue start policy starts beside them")
Start_Policy_Processes_Late :: struct {
	left_processes: u64,
	bound:          value_kinds.Time_In_Milliseconds,
}

// A start asked by the start policy from the disk refused: past its
// restarts, or past the names that this service counts.
@(log_fact = "root: refused a start of {refused_process} by the start policy from the disk: past its {restart_limit} restarts, or past the {counted_names} names whose starts the root service counts, it stays stopped")
Start_Policy_Restart_Refused :: struct {
	restart_limit:   u64,
	counted_names:   u64,
	refused_process: value_kinds.Module_Name_Field,
}
