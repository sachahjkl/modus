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

// No boot program checked the files: the starter of the machine gave the
// hash of the system description, nothing verified its signature, and this
// service hashed each file at its start.
@(log_fact = "root: no boot program verified the system description: its hash is the one of the boot record, and nothing verified its signature; this service checked its {checked_entries} modules and resources at its start, in {check_time}")
Image_Checked_At_Start :: struct {
	checked_entries: u64,
	check_time:      value_kinds.Time_In_Microseconds,
}

// No boot program checked the files: this service checked the table of
// the boot image and its own module at its start, and hashes each other
// file at its first use.
@(log_fact = "root: no boot program verified the system description: its hash is the one of the boot record, and nothing verified its signature; this service checked the table of its {checked_entries} modules and resources and its own module in {check_time}, and hashes each other file at its first use")
Image_Checked_At_Load :: struct {
	checked_entries: u64,
	check_time:      value_kinds.Time_In_Microseconds,
}

// A file of the boot image whose bytes do not have the hash of its entry,
// at its first use: it is not used.
@(log_fact = "root: the file {file} of the boot image does not have the hash of its entry: it is not used")
Image_File_Hash_Wrong :: struct {
	file: value_kinds.Module_Name_Field,
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

// The TPM service started, with the address of the registers of the TPM in
// 16 digits with no "0x", as system.Hex wrote it.
@(log_fact = "root: started tpm for the TPM at {registers}: unlock seals keys to the measure of the system with it")
Tpm_Service_Started :: struct {
	registers: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused the measure of the system description: its response, a
// word of the TPM in 16 digits.
@(log_fact = "root: the TPM refused the measure of the system description: status {measure_status}, after {measure_tries} tries: PCR {measure_register} does not hold it")
Description_Measure_Refused :: struct {
	measure_status:   value_kinds.Hexadecimal_Sixteen_Digits,
	measure_tries:    u64,
	measure_register: u64,
}

// The system description is measured, and the read of the register back
// failed.
@(log_fact = "root: the system description is measured, but the read of PCR {measure_register} failed: status {measure_status}")
Description_Register_Unread :: struct {
	measure_register: u64,
	measure_status:   value_kinds.Hexadecimal_Sixteen_Digits,
}

// The boot program could not read a floor of the TPM.
@(log_fact = "root: the boot program could not read a TPM floor: status {floor_status}; it took it as 0")
Tpm_Floor_Unread :: struct {
	floor_status: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The check of the boot image against the system description failed: one
// fact type for each fault, as the sentence of each fault differs. The
// entry is empty for a fault of the whole image; the two hashes are those
// that the check compared, zero for a fault with no hash.

@(log_fact = "root: {checked_entry}: the system description does not follow its format: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Not_Valid :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: the boot image has no whole tables, or its two last resources are not the system description and its signature: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Image_Not_Valid :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: the boot image has another count of entries than the system description: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Count_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: the entry of the boot image at this place has another name: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Name_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: the entry of the boot image at this place is of another kind: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Kind_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: does not have the size of the system description: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Size_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: does not have the hash of the system description: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Hash_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: states in the boot image another hash than the system description: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Stated_Hash_Differs :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}

@(log_fact = "root: {checked_entry}: points outside the boot image: expected {expected_hash}, found {found_hash}")
Image_Check_Failed_Outside_Image :: struct {
	expected_hash: value_kinds.Hash_Field,
	found_hash:    value_kinds.Hash_Field,
	checked_entry: value_kinds.Module_Name_Field,
}
