package root

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The log facts of the disk processes, of the disk grant tables and of the
// client keys of remote (src/md/features/log_facts.md). Each fact template
// is the sentence that the line wrote before it was a fact; the Integer
// and Bytes fields come first and the Text fields last. The name of the
// store of the module files is a word of each template:
// disk_process.STORE_NAME, which a host test compares.

// This service reads a disk process from the store of the module files.
@(log_fact = "root: reads {loaded_process} from the store module_files of the storage service, for principal {principal}")
Disk_Load_Started :: struct {
	principal:      u64,
	loaded_process: value_kinds.Module_Name_Field,
}

// A grant that no command gives to a disk process.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: no command gives it to a disk process, as it reaches the whole machine or the principal")
Disk_Grant_Refused_Never :: struct {
	nickname: value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// A grant that a command could give to a disk process, and does not yet.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: a command gives a disk process the grant Store only")
Disk_Grant_Refused_Not_Built :: struct {
	nickname: value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// A grant refused to a nickname with a character that a nickname with a
// grant does not take.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: a nickname with a grant has letters, digits, '-' and '_' only")
Disk_Grant_Refused_Nickname_Characters :: struct {
	nickname: value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// A grant refused to a nickname that the store of the module files keeps.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: the store of the module files keeps this name for itself")
Disk_Grant_Refused_Reserved_Name :: struct {
	nickname: value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// A grant refused to a nickname that names no row and no running disk
// process.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: it has no row in the disk grant table of principal {principal}, and no disk process of that nickname runs; start it by its hash first")
Disk_Grant_Refused_No_Row :: struct {
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

// The grant store refused: the name of the store would pass 31 bytes.
@(log_fact = "root: refused the grant store to the nickname {nickname}: the name of its store for principal {principal} has more than 31 bytes")
Disk_Grant_Refused_Store_Name :: struct {
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
}

// A grant refused to the chosen start policy, which holds its one grant.
@(log_fact = "root: refused the grant {grant} to the nickname {nickname}: it names the chosen start policy, which holds the grant Start_Policy and nothing else")
Disk_Grant_Refused_Start_Policy :: struct {
	nickname: value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// A move of a nickname refused: it has no row.
@(log_fact = "root: refused the move of the nickname {nickname}: it has no row in the disk grant table of principal {principal}")
Nickname_Move_Refused_No_Row :: struct {
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
}

// A move of a nickname refused: it names the chosen start policy.
@(log_fact = "root: refused the move of the nickname {nickname}: it names the chosen start policy; start_policy_choose names another file")
Nickname_Move_Refused_Start_Policy :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A file gets the data of a nickname: the line before the move.
@(log_fact = "root: the file {hash} will get the data of {nickname}")
Nickname_Move_Announced :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

// A setting of persistence refused: the nickname names the chosen start
// policy.
@(log_fact = "root: refused the setting of persistence of the nickname {nickname}: it names the chosen start policy, which persists until start_policy_default ends the choice")
Persistence_Refused_Start_Policy :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A setting of persistence refused: the nickname has no row.
@(log_fact = "root: refused the setting of persistence of the nickname {nickname}: it has no row in the disk grant table of principal {principal}")
Persistence_Refused_No_Row :: struct {
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
}

// An unlock refused: its key comes as the key of a new principal, and the
// record of the principal was not made in this run.
@(log_fact = "root: refused the unlock of principal {principal}: its key comes as the key of a new principal, and its record was not created since the machine started")
Unlock_Refused_New_Key :: struct {
	principal: u64,
}

// An unlock refused: its key is not the key of the first unlock of this
// run.
@(log_fact = "root: refused the unlock of principal {principal}: the key of its disk grant table differs from the key of its first unlock since the machine started")
Unlock_Refused_Other_Key :: struct {
	principal: u64,
}

// A change of a disk grant table refused: the session of its principal is
// locked.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: its session is locked")
Table_Change_Refused_Session_Locked :: struct {
	principal: u64,
}

// A change of a disk grant table refused: unlock gave no key for it.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: unlock gave no key for it")
Table_Change_Refused_No_Key :: struct {
	principal: u64,
}

// A change of a disk grant table refused: its read runs.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: its read from the store module_files runs")
Table_Change_Refused_Reading :: struct {
	principal: u64,
}

// A change of a disk grant table refused: its read gave nothing.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: the store module_files did not give it, so a write could lose it")
Table_Change_Refused_Unread :: struct {
	principal: u64,
}

// A change of a disk grant table refused: the table on the disk has a
// format that this system does not read.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: the table on the disk has a format that this system does not read, and it is kept; do not restore a version of it, as no version has a format that this system reads")
Table_Change_Refused_Format :: struct {
	principal: u64,
}

// A change of a disk grant table refused: the table on the disk does not
// verify under the key of its principal.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: the table on the disk does not verify under {table_key}, and it is kept; restore a version of it that verifies, then start the machine again")
Table_Change_Refused_Not_Verified :: struct {
	principal: u64,
	table_key: [32]u8,
}

// A change of a disk grant table refused: its last change is not on the
// disk.
@(log_fact = "root: refused a change of the disk grant table of principal {principal}: its last change is not on the disk; start the machine again")
Table_Change_Refused_Unwritten :: struct {
	principal: u64,
}

// A revocation of a client key starts the writes of a disk grant table
// again.
@(log_fact = "root: a revocation of a client key of remote starts the writes of the disk grant table of principal {principal} again")
Table_Writes_Restarted_By_Revocation :: struct {
	principal: u64,
}

// A revocation of a client key that the disk grant table cannot take now.
@(log_fact = "root: the revocation of the client key {client_key} of remote is not written in the disk grant table of principal {principal}, which takes no change now: the key can come back at the next start of the machine")
Client_Key_Revocation_Not_Written :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// The store of the module files holds no disk grant table of principal 0:
// the table of this machine is written there.
@(log_fact = "root: the store module_files holds no disk grant table of principal {principal}: the table of this machine is written there")
Table_Absent_Written :: struct {
	principal: u64,
}

// A disk grant table read, which replaces the rows made before its key
// came.
@(log_fact = "root: read the disk grant table of principal {principal} from the store module_files: {rows} rows, with the tag of {table_key}; {client_keys} client keys of remote; it replaces {replaced_rows} rows made before the key came")
Table_Read_Replacing :: struct {
	principal:     u64,
	rows:          u64,
	client_keys:   u64,
	replaced_rows: u64,
	table_key:     [32]u8,
}

// A disk grant table read.
@(log_fact = "root: read the disk grant table of principal {principal} from the store module_files: {rows} rows, with the tag of {table_key}; {client_keys} client keys of remote")
Table_Read :: struct {
	principal:   u64,
	rows:        u64,
	client_keys: u64,
	table_key:   [32]u8,
}

// A disk grant table held client keys revoked before its read: they stay
// revoked.
@(log_fact = "root: the disk grant table of principal {principal} held {revoked_keys} client keys of remote revoked before its read: they stay revoked, and the table is written again")
Table_Revoked_Keys_Kept :: struct {
	principal:    u64,
	revoked_keys: u64,
}

// A disk grant table written.
@(log_fact = "root: the disk grant table of principal {principal} is written in the store module_files: {rows} rows, with the tag of {table_key}; {client_keys} client keys of remote")
Table_Written :: struct {
	principal:   u64,
	rows:        u64,
	client_keys: u64,
	table_key:   [32]u8,
}

// A principal gave a client key of remote more uses. The uses are a word
// of a closed set (client_uses_text).
@(log_fact = "root: principal {principal} gave the client key {client_key} more uses: {uses}")
Client_Key_Uses_Added :: struct {
	principal:  u64,
	client_key: [24]u8,
	uses:       [24]u8,
}

// A principal allowed a client key for the remote display only.
@(log_fact = "root: principal {principal} allowed the client key {client_key} for the remote display: {uses}")
Client_Key_Allowed_For_Display :: struct {
	principal:  u64,
	client_key: [24]u8,
	uses:       [24]u8,
}

// A client key of the remote display holds again for a principal, from its
// disk grant table, with its persisted uses.
@(log_fact = "root: the client key {client_key} of the remote display holds again for principal {principal}, from its disk grant table: {uses}")
Client_Key_Restored_For_Display :: struct {
	principal:  u64,
	client_key: [24]u8,
	uses:       [24]u8,
}

// A principal revoked a client key that was contested.
@(log_fact = "root: principal {principal} revoked the client key {client_key} of remote, which was contested: connections to services ended: 0")
Client_Key_Revoked_Contested :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// A principal revoked a client key, with the uses that it had.
@(log_fact = "root: principal {principal} revoked the client key {client_key} ({uses}): connections to services ended: {connections_ended}")
Client_Key_Revoked :: struct {
	principal:         u64,
	connections_ended: u64,
	client_key:        [24]u8,
	uses:              [24]u8,
}

// A client key holds again for a principal, from its disk grant table.
@(log_fact = "root: the client key {client_key} of remote holds again for principal {principal}, from its disk grant table: each call of that client acts for it")
Client_Key_Restored :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// The client table of remote has no free row: a fault that is said.
@(log_fact = "root: the client table of remote has no free row for the client key {client_key} of principal {principal}: the key holds for no principal")
Client_Table_Full :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// A contest of a client key ended by the revocation of one principal.
@(log_fact = "root: the client key {client_key} of remote holds again for principal {principal}: principal {revoking_principal} revoked it, so it is no longer contested")
Client_Key_Contest_Ended :: struct {
	principal:          u64,
	revoking_principal: u64,
	client_key:         [24]u8,
}

// A client key allowed before the read of the disk grant table, which the
// table does not hold: its grant ends.
@(log_fact = "root: the client key {client_key} of remote, which principal {principal} allowed before its disk grant table was read, is not in that table: its grant ends; connections to services ended: {connections_ended}")
Client_Key_Not_In_Table :: struct {
	principal:         u64,
	connections_ended: u64,
	client_key:        [24]u8,
}

// A client key loses the view and the input while the session of another
// principal is in front.
@(log_fact = "root: the client key {client_key} of principal {principal} loses the view and the input while the session of principal {front_principal} is in front; connections to services ended: {connections_ended}")
Client_Key_View_Paused :: struct {
	principal:         u64,
	front_principal:   u64,
	connections_ended: u64,
	client_key:        [24]u8,
}

// A client key has the view again: the session of its principal is in
// front.
@(log_fact = "root: the client key {client_key} of principal {principal} has the view again: the session of its principal is in front")
Client_Key_View_Back :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// A client key allowed by a principal in this run is in the disk grant
// table of another principal: it acts for neither.
@(log_fact = "root: the client key {client_key} of remote is contested: principal {principal} allowed it since the machine started, and the disk grant table of principal {other_principal} holds it; it acts for neither until one of them revokes it; connections to services ended: {connections_ended}")
Client_Key_Contested :: struct {
	principal:         u64,
	other_principal:   u64,
	connections_ended: u64,
	client_key:        [24]u8,
}

// A principal allowed a client key of Calls: one fact type for each case of
// how long the key lasts.

@(log_fact = "root: principal {principal} allowed the client key {client_key} of remote: each call of that client acts for it; principal 0 has no passphrase, so the key lasts until the machine stops")
Client_Key_Allowed_Until_Stop :: struct {
	principal:  u64,
	client_key: [24]u8,
}

@(log_fact = "root: principal {principal} allowed the client key {client_key} of remote: each call of that client acts for it; the disk grant table of the principal keeps nothing across a restart (disk_persistence), so the key lasts until the machine stops")
Client_Key_Allowed_Until_Stop_Forgotten :: struct {
	principal:  u64,
	client_key: [24]u8,
}

@(log_fact = "root: principal {principal} allowed the client key {client_key} of remote: each call of that client acts for it; the disk grant table of the principal keeps the key across a restart")
Client_Key_Allowed_Kept :: struct {
	principal:  u64,
	client_key: [24]u8,
}

// The disk grant table of a principal is not read: the cause is a sentence
// of a closed set of this service (the cause of a call that the storage
// service refused is the fact Table_Call_Refused before it). The principal
// comes twice in the sentence, and a template names a field once.
@(log_fact = "root: the disk grant table of principal {principal} is not read: {call_failure}; the disk grants of principal {absent_grants_principal} stay absent until the machine starts again")
Table_Not_Read :: struct {
	principal:               u64,
	absent_grants_principal: u64,
	call_failure:            [72]u8,
}

// A write of the disk grant table failed: this service tries again.
@(log_fact = "root: the disk grant table of principal {principal} is not written: {call_failure}; try {try_number} of {try_limit}")
Table_Write_Tried_Again :: struct {
	principal:    u64,
	try_number:   u64,
	try_limit:    u64,
	call_failure: [72]u8,
}

// The writes of the disk grant table failed at each try.
@(log_fact = "root: the disk grant table of principal {principal} is not written after {try_limit} tries: {call_failure}; the disk keeps an older table, so a grant taken since can come back at the next start, and no change is taken")
Table_Write_Given_Up :: struct {
	principal:    u64,
	try_limit:    u64,
	call_failure: [72]u8,
}

// The storage service refused the read or the write of a disk grant table:
// the fields of its error record.
@(log_fact = "root: the storage service refused the call of a disk grant table: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Table_Call_Refused :: distinct errors.Error_Record_Fact_Fields

// A table on the disk that this service refuses and writes over. The
// sentence of the problem is a Text field when it fits beside the other
// fields; each longer sentence has a fact type of its own.
@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: {table_problem}; it gives no grant, and the table of {new_record} is written over it")
Table_Refused_Written_Over :: struct {
	principal:     u64,
	new_record:    [32]u8,
	table_problem: [104]u8,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: the table has 1008 bytes: it has the format 1 of an older system, which this system does not read; no version of it can be restored to verify; it gives no grant, and the table of {new_record} is written over it")
Table_Refused_Older_Format_Written_Over :: struct {
	principal:  u64,
	new_record: [32]u8,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: a row has a nickname that no grant names, a hash of zero bytes, an unknown grant or persistence, the grant start_policy with another grant, or a byte that must be zero; it gives no grant, and the table of {new_record} is written over it")
Table_Refused_Bad_Row_Written_Over :: struct {
	principal:  u64,
	new_record: [32]u8,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: the client keys of remote in the table are more than 4, or one is zero bytes, or one comes two times, or a byte after the last key is not zero; it gives no grant, and the table of {new_record} is written over it")
Table_Refused_Bad_Client_Keys_Written_Over :: struct {
	principal:  u64,
	new_record: [32]u8,
}

// A table on the disk that this service refuses and keeps.
@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: {table_problem}; it gives no grant, and it is kept: no change is written over it")
Table_Refused_Kept :: struct {
	principal:     u64,
	table_problem: [104]u8,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: the table has 1008 bytes: it has the format 1 of an older system, which this system does not read; no version of it can be restored to verify; it gives no grant, and it is kept: no change is written over it")
Table_Refused_Older_Format_Kept :: struct {
	principal: u64,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: a row has a nickname that no grant names, a hash of zero bytes, an unknown grant or persistence, the grant start_policy with another grant, or a byte that must be zero; it gives no grant, and it is kept: no change is written over it")
Table_Refused_Bad_Row_Kept :: struct {
	principal: u64,
}

@(log_fact = "root: refused the disk grant table of principal {principal} from the store module_files: the client keys of remote in the table are more than 4, or one is zero bytes, or one comes two times, or a byte after the last key is not zero; it gives no grant, and it is kept: no change is written over it")
Table_Refused_Bad_Client_Keys_Kept :: struct {
	principal: u64,
}

// The changes of a disk grant table: one fact type for each case of how
// long the table lasts (Table_Lasting).

@(log_fact = "root: the nickname {nickname}, the file {hash}, lost the grant {grant} for principal {principal}, from its next start; its store stays on the disk; principal 0 has no passphrase, so its disk grant table lasts until the machine stops")
Grant_Lost_Until_Stop :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname}, the file {hash}, lost the grant {grant} for principal {principal}, from its next start; its store stays on the disk; the machine passphrase keeps the disk grant table of principal 0 on the disk")
Grant_Lost_Kept_By_Machine_Passphrase :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname}, the file {hash}, lost the grant {grant} for principal {principal}, from its next start; its store stays on the disk; the passphrase of the principal keeps its disk grant table on the disk")
Grant_Lost_Kept_By_Passphrase :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname}, the file {hash}, has the grant {grant} for principal {principal}, from its next start; principal 0 has no passphrase, so its disk grant table lasts until the machine stops")
Grant_Given_Until_Stop :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname}, the file {hash}, has the grant {grant} for principal {principal}, from its next start; the machine passphrase keeps the disk grant table of principal 0 on the disk")
Grant_Given_Kept_By_Machine_Passphrase :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname}, the file {hash}, has the grant {grant} for principal {principal}, from its next start; the passphrase of the principal keeps its disk grant table on the disk")
Grant_Given_Kept_By_Passphrase :: struct {
	hash:      value_kinds.Hash_Field,
	principal: u64,
	nickname:  value_kinds.Module_Name_Field,
	grant:     [24]u8,
}

@(log_fact = "root: the nickname {nickname} names the file {hash}, with its grants and its store; principal 0 has no passphrase, so its disk grant table lasts until the machine stops")
Nickname_Moved_Until_Stop :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

@(log_fact = "root: the nickname {nickname} names the file {hash}, with its grants and its store; the machine passphrase keeps the disk grant table of principal 0 on the disk")
Nickname_Moved_Kept_By_Machine_Passphrase :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

@(log_fact = "root: the nickname {nickname} names the file {hash}, with its grants and its store; the passphrase of the principal keeps its disk grant table on the disk")
Nickname_Moved_Kept_By_Passphrase :: struct {
	hash:     value_kinds.Hash_Field,
	nickname: value_kinds.Module_Name_Field,
}

// The global setting of persistence of a table: the words of a closed set
// (persistence_words).

@(log_fact = "root: each row of the disk grant table of principal {principal} with no exception will {persistence}; principal 0 has no passphrase, so its disk grant table lasts until the machine stops")
Table_Persistence_Set_Until_Stop :: struct {
	principal:   u64,
	persistence: [32]u8,
}

@(log_fact = "root: each row of the disk grant table of principal {principal} with no exception will {persistence}; the machine passphrase keeps the disk grant table of principal 0 on the disk")
Table_Persistence_Set_Kept_By_Machine_Passphrase :: struct {
	principal:   u64,
	persistence: [32]u8,
}

@(log_fact = "root: each row of the disk grant table of principal {principal} with no exception will {persistence}; the passphrase of the principal keeps its disk grant table on the disk")
Table_Persistence_Set_Kept_By_Passphrase :: struct {
	principal:   u64,
	persistence: [32]u8,
}

@(log_fact = "root: the row of the nickname {nickname} in the disk grant table of principal {principal} has the setting: {persistence}; principal 0 has no passphrase, so its disk grant table lasts until the machine stops")
Row_Persistence_Set_Until_Stop :: struct {
	principal:   u64,
	nickname:    value_kinds.Module_Name_Field,
	persistence: [32]u8,
}

@(log_fact = "root: the row of the nickname {nickname} in the disk grant table of principal {principal} has the setting: {persistence}; the machine passphrase keeps the disk grant table of principal 0 on the disk")
Row_Persistence_Set_Kept_By_Machine_Passphrase :: struct {
	principal:   u64,
	nickname:    value_kinds.Module_Name_Field,
	persistence: [32]u8,
}

@(log_fact = "root: the row of the nickname {nickname} in the disk grant table of principal {principal} has the setting: {persistence}; the passphrase of the principal keeps its disk grant table on the disk")
Row_Persistence_Set_Kept_By_Passphrase :: struct {
	principal:   u64,
	nickname:    value_kinds.Module_Name_Field,
	persistence: [32]u8,
}

// A connection of remote refused for a contested client key.
@(log_fact = "root: refused a connection of remote for the client key {client_key}: it is contested between principal {principal} and principal {other_principal}, and acts for neither")
Remote_Connection_Refused_Contested :: struct {
	principal:       u64,
	other_principal: u64,
	client_key:      [24]u8,
}
