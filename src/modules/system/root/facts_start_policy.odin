package root

import op "modus:contract/operation"
import "modus:contract/call_outcome"
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

// The holder of Plans runs, and the start policy waits for its read of the
// plan of principal 0.
@(log_fact = "root: the plans service reads the plan of principal 0 before the start policy, within the hang bound of {bound}")
Plan_At_Start_Waiting :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// The holder of Plans did not say Loaded within its bound.
@(log_fact = "root: the plans service did not read the plan of principal 0 within the hang bound of {bound}: the start policy starts with the roles in force")
Plan_At_Start_Late :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// The holder of Plans did not start before the start policy.
@(log_fact = "root: the plans service did not start to read the plan of principal 0: outcome {outcome}; the roles of the boot image hold")
Plan_At_Start_Start_Failed :: struct {
	outcome: call_outcome.Call_Outcome,
}

// The roles of the current plan of principal 0 hold from the start.
@(log_fact = "root: the roles of generation {generation} of the plan of principal 0 hold from the start: {overrides} overrides, serial {serial}")
Plan_At_Start_Applied :: struct {
	generation: u64,
	serial:     u64,
	overrides:  u64,
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

// The chosen start policy is not read: the service disk_processes does not
// run.
@(log_fact = "root: the chosen start policy \"{nickname}\" is not read: the disk processes service does not run: the rescue start policy starts")
Chosen_Start_Policy_No_Service :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// The chosen start policy is not read: the call ring and the call region of
// the storage service do not reach the service disk_processes.
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

// The start policy names itself by the head of its hash, the first 4
// bytes and "…": a field of the kind Hash_Head, which holds the whole hash
// so that a reader compares each byte.

// The rescue starts in place of the start policy: the key R was held.
@(log_fact = "root: the key R was held at the start: the rescue start policy starts in place of the start policy {replaced_hash}")
Rescue_By_Key :: struct {
	replaced_hash: value_kinds.Hash_Head_Field,
}

// The rescue starts by the key R, and the boot image has no module of the
// start policy that it replaces.
@(log_fact = "root: the key R was held at the start: the rescue start policy starts in place of the start policy of no module")
Rescue_By_Key_Of_No_Module :: struct {}

// The rescue starts in place of the start policy: the boot entry of the
// rescue started the machine.
@(log_fact = "root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy {replaced_hash}")
Rescue_By_Boot_Entry :: struct {
	replaced_hash: value_kinds.Hash_Head_Field,
}

@(log_fact = "root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy of no module")
Rescue_By_Boot_Entry_Of_No_Module :: struct {}

// The rescue starts in place of the start policy: the boot record asks for
// it with words that the border refuses.
@(log_fact = "root: the rescue start policy starts in place of the start policy {replaced_hash}: the boot record asks for it with words that the border refuses")
Rescue_By_Refused_Record :: struct {
	replaced_hash: value_kinds.Hash_Head_Field,
}

@(log_fact = "root: the rescue start policy starts in place of the start policy of no module: the boot record asks for it with words that the border refuses")
Rescue_By_Refused_Record_Of_No_Module :: struct {}

// The start policy of the boot image did not start: the rescue starts.
@(log_fact = "root: the start policy {start_policy_hash} did not start, with the outcome {outcome}: the rescue start policy starts")
Start_Policy_Not_Started :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	outcome:           call_outcome.Call_Outcome_Word,
}

// The start policy did not start, and the boot image has no module of it.
@(log_fact = "root: the start policy of no module did not start, with the outcome {outcome}: the rescue start policy starts")
Start_Policy_Not_Started_Of_No_Module :: struct {
	outcome: call_outcome.Call_Outcome,
}

// The rescue stopped itself before the machine was usable: no start policy
// is left.
@(log_fact = "root: the rescue start policy {start_policy_hash} stopped before the machine was usable: {cause}, {outcome}")
Rescue_Stopped_Before_Usable :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
	outcome:           op.Stop_Outcome,
}

// The rescue stopped for another cause than itself before the machine was
// usable.
@(log_fact = "root: the rescue start policy {start_policy_hash} stopped before the machine was usable: {cause}")
Rescue_Stopped_Before_Usable_Without_Outcome :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
}

// The start policy stopped itself before the machine was usable: the rescue
// starts.
@(log_fact = "root: the start policy {start_policy_hash} stopped before the machine was usable: {cause}, {outcome}; the rescue start policy starts")
Start_Policy_Stopped_Before_Usable :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
	outcome:           op.Stop_Outcome,
}

@(log_fact = "root: the start policy {start_policy_hash} stopped before the machine was usable: {cause}; the rescue start policy starts")
Start_Policy_Stopped_Before_Usable_Without_Outcome :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
}

// The start policy stopped itself after the machine was usable: the
// processes that it asked for stop, and the rescue starts.
@(log_fact = "root: the start policy {start_policy_hash} stopped: {cause}, {outcome}, after the machine was usable; the rescue start policy starts")
Start_Policy_Stopped_After_Usable :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
	outcome:           op.Stop_Outcome,
}

@(log_fact = "root: the start policy {start_policy_hash} stopped: {cause}, after the machine was usable; the rescue start policy starts")
Start_Policy_Stopped_After_Usable_Without_Outcome :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
}

// The rescue stopped itself after the machine was usable: no start policy
// is left.
@(log_fact = "root: the rescue start policy {start_policy_hash} stopped: {cause}, {outcome}, after the machine was usable")
Rescue_Stopped_After_Usable :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
	outcome:           op.Stop_Outcome,
}

@(log_fact = "root: the rescue start policy {start_policy_hash} stopped: {cause}, after the machine was usable")
Rescue_Stopped_After_Usable_Without_Outcome :: struct {
	start_policy_hash: value_kinds.Hash_Head_Field,
	cause:             op.Stop_Cause,
}

// The rescue sent no Machine_Usable within its bound.
@(log_fact = "root: the rescue start policy {start_policy_hash} sent no Machine_Usable within the hang bound of {bound}")
Rescue_Not_Usable_In_Time :: struct {
	bound:             value_kinds.Time_In_Milliseconds,
	start_policy_hash: value_kinds.Hash_Head_Field,
}

// The start policy sent no Machine_Usable within its bound: the rescue
// starts.
@(log_fact = "root: the start policy {start_policy_hash} sent no Machine_Usable within the hang bound of {bound}: the rescue start policy starts")
Start_Policy_Not_Usable_In_Time :: struct {
	bound:             value_kinds.Time_In_Milliseconds,
	start_policy_hash: value_kinds.Hash_Head_Field,
}

// The machine is usable: the start policy that said so, its list, and the
// free pages of the budget of this service now and at the lowest. The
// measure of the records of the start stops at this fact
// (tools/modustool/build/log_measures.odin).
@(log_fact = "root: the machine is usable, by the start policy {start_policy_hash} {start_policy_words}: the budget of this service holds {free_pages} free pages, {lowest_free_pages} at the lowest")
Machine_Usable :: struct {
	free_pages:         u64,
	lowest_free_pages:  u64,
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

// The words that name a start policy after its hash, in the lines of its
// measure: its list ("of the list start_list"), or its nickname of at most
// disk_process.NAME_LIMIT bytes in parentheses: at most 36 bytes.

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the TPM service stopped earlier in this run")
Start_Policy_Unmeasured_Tpm_Stopped_Earlier :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the system is not measured into a TPM")
Start_Policy_Unmeasured_No_Tpm :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the TPM service has no measure ring")
Start_Policy_Unmeasured_No_Measure_Ring :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the measure ring of the TPM service is full")
Start_Policy_Unmeasured_Measure_Ring_Full :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

// The TPM service answered with a word that names no status of its
// contract: the word of another party keeps its number.
@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the TPM service gave a completion that the root service cannot read, the outcome word {outcome_word}")
Start_Policy_Unmeasured_Unknown_Status :: struct {
	outcome_word:       u64,
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

// The extend of PCR 12 failed: the name of the call outcome of the TPM
// service, and the value found of its record: the response code, the step
// of the interface, or the count of the extends.
@(log_fact = "root: the measure of the start policy {start_policy_hash} {start_policy_words} into PCR 12 failed: the TPM service answered {tpm_status}, value {answer_value}")
Start_Policy_Measure_Failed :: struct {
	answer_value:       u64,
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
	tpm_status:         [64]u8,
}

// The start policy is measured into PCR 12, with the value of PCR 12 that
// the TPM gives back.
@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is measured into PCR 12: PCR 12 = {measure_value}")
Start_Policy_Measured :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	measure_value:      value_kinds.Hash_Field,
	start_policy_words: [40]u8,
}

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the TPM service stopped during the measure")
Start_Policy_Unmeasured_Tpm_Stopped_During :: struct {
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

@(log_fact = "root: the start policy {start_policy_hash} {start_policy_words} is not measured: the TPM service gave no answer within {bound}")
Start_Policy_Unmeasured_No_Answer :: struct {
	bound:              value_kinds.Time_In_Milliseconds,
	start_policy_hash:  value_kinds.Hash_Head_Field,
	start_policy_words: [40]u8,
}

// The parts of the machine that the machine parts page holds, one fact for
// each part: the start policy reads the page.
@(log_fact = "root: the machine parts page holds {machine_part}")
Machine_Part_Present :: struct {
	machine_part: [24]u8,
}
