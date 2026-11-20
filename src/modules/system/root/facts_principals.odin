package root

import "modus:contract/value_kinds"

// The log facts of the principals, of their sessions and of the trust of
// the boot (src/md/features/log_facts.md). Each fact template is the
// sentence that the line wrote before it was a fact; the Integer and Bytes
// fields come first and the Text fields last.

// Principal 0 is the machine, and the system is measured: the register and
// its value in the SHA-256 bank.
@(log_fact = "root: principal 0 is the machine: the system is measured, PCR {measure_register} = {measure_value}; its key, the attestation key of the TPM, is not built")
Machine_Principal_Measured :: struct {
	measure_register: u64,
	measure_value:    value_kinds.Hash_Field,
}

// The creation of a named principal starts in the window of unlock.
@(log_fact = "root: the principal \"{principal_name}\" is created in the window of unlock")
Principal_Creation_Started :: struct {
	principal_name: [24]u8,
}

// A named principal is recorded with the head of its public key, 8 bytes in
// 16 hexadecimal digits, as a Text field: a Hash field holds the hash of a
// module.
@(log_fact = "root: principal 1 \"{principal_name}\" is recorded, its public key {public_key_head}...; its session is locked")
Principal_Recorded :: struct {
	principal_name:  [24]u8,
	public_key_head: [24]u8,
}

// The session of a named principal starts.
@(log_fact = "root: the session of principal {principal} \"{principal_name}\" starts: the desktop starts each process in it")
Session_Started :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The session of a named principal ends, with the count of its processes
// that stopped.
@(log_fact = "root: the session of principal {principal} \"{principal_name}\" ends: {stopped_processes} processes stopped")
Session_Ended :: struct {
	principal:         u64,
	stopped_processes: u64,
	principal_name:    [24]u8,
}

// The lock stops the window of unlock, which ran for another mode. The mode
// is a word of a closed set (principals.mode_words).
@(log_fact = "root: the lock stops the window of unlock, which ran for {unlock_mode}; unlock asks for the passphrase when it stopped")
Unlock_Stopped_By_Lock :: struct {
	unlock_mode: [40]u8,
}

// unlock stopped too many times while a principal is locked: it starts no
// more.
@(log_fact = "root: unlock stopped {restart_limit} times while a principal is locked, with no stop that the root service asked: it starts no more until the machine starts again")
Unlock_Restarts_Given_Up :: struct {
	restart_limit: u64,
}

// A change in the window of unlock ends, with the sentence of its end: a
// closed set (principals.change_end_sentences).
@(log_fact = "root: the change in the window of unlock ends: {change_end}")
Principal_Change_Ended :: struct {
	change_end: [64]u8,
}

// The completion ring of the asker of a change is full: the end of the
// change does not reach it.
@(log_fact = "root: the completion ring of {caller} is full: the end of the change does not reach it, and its line waits until Escape")
Change_End_Not_Delivered :: struct {
	caller: value_kinds.Module_Name_Field,
}

// The passphrase of a named principal changes in the window of unlock.
@(log_fact = "root: the passphrase of principal {principal} \"{principal_name}\" changes in the window of unlock")
Passphrase_Change_Started :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A new recovery key of a named principal is made in the window of unlock.
@(log_fact = "root: a new recovery key of principal {principal} \"{principal_name}\" is made in the window of unlock")
Recovery_Key_Change_Started :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The boot image agrees with the system description that the boot program
// verified: the entries that this service checked, and the time of the
// check.
@(log_fact = "root: the boot image agrees with the system description that the boot program verified: {checked_entries} modules and resources checked in {check_time}; the kernel was checked by the boot program only")
Boot_Image_Agrees :: struct {
	checked_entries: u64,
	check_time:      value_kinds.Time_In_Microseconds,
}

// The time of the check of the signature and of every hash by the boot
// program.
@(log_fact = "root: the boot program checked the signature and every hash in {check_time}")
Boot_Program_Check_Time :: struct {
	check_time: value_kinds.Time_In_Microseconds,
}

// The system description is measured into a register of the TPM.
@(log_fact = "root: measured: PCR {measure_register} = {measure_value}, at try {measure_tries}")
System_Description_Measured :: struct {
	measure_register: u64,
	measure_tries:    u64,
	measure_value:    value_kinds.Hash_Field,
}

// The floors of the TPM that the boot program compared at this start.
@(log_fact = "root: the TPM floors before this start: the key floor {key_floor} for the key number {key_number}, the version floor of that key number {version_floor} for the security version {security_version}")
Tpm_Floors :: struct {
	key_floor:        u64,
	key_number:       u64,
	version_floor:    u64,
	security_version: u64,
}

// The boot record names a floor state that names no state: it is said,
// never read as a state.
@(log_fact = "root: the boot record names the floor state {floor_state}, which names no state")
Floor_State_Unknown :: struct {
	floor_state: u64,
}
