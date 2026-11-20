package root

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of a start from the disk that this service refuses
// (src/md/features/log_facts.md): one fact type for each cause, each with
// the name that the command asked for. The name has at most 24 bytes: the
// three words of the command. The name of the store of the module files is
// a word of the templates, disk_process.STORE_NAME, which a host test
// compares.

@(log_fact = "root: refused {refused_process} from the disk: the name has no byte")
Disk_Load_Refused_Name_Empty :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the name has more than {name_limit} bytes")
Disk_Load_Refused_Name_Too_Long :: struct {
	name_limit:      u64,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the name is no name of a process: visible characters of ASCII, no \"/\", not \".\" or \"..\"")
Disk_Load_Refused_Name_Not_A_Process_Name :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the name is the name of the store of the module files")
Disk_Load_Refused_Name_Of_Module_Store :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the name is the name of the object of the disk grant table")
Disk_Load_Refused_Name_Of_Grant_Table :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the grant table of the root service names it, and a disk process takes no grant by its name")
Disk_Load_Refused_Name_In_Grant_Table :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: a module of the boot image has this name")
Disk_Load_Refused_Name_In_Boot_Image :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the asker has no principal with a record")
Disk_Load_Refused_Asker_Without_Principal :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the nickname has no row in the disk grant table of principal {principal}: name the hash of its file")
Disk_Load_Refused_Nickname_Without_Row :: struct {
	principal:       u64,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the nickname names the file {named_hash}, and the command names the file {hash}; nickname_move points it to another file")
Disk_Load_Refused_Nickname_Other_File :: struct {
	named_hash:      value_kinds.Hash_Field,
	hash:            value_kinds.Hash_Field,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: another load from the disk runs")
Disk_Load_Refused_Load_Busy :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: no connection to the storage service: status {status}")
Disk_Load_Refused_No_Connection :: struct {
	status:          op.Status,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the call ring and the call region of the storage service do not map")
Disk_Load_Refused_Not_Mapped :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service took no call")
Disk_Load_Refused_Call_Not_Taken :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the process that asked for it stopped")
Disk_Load_Refused_Asker_Stopped :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service stopped")
Disk_Load_Refused_Storage_Stopped :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave no answer in {bound}")
Disk_Load_Refused_No_Answer :: struct {
	bound:           value_kinds.Time_In_Milliseconds,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the store module_files has no object with this name")
Disk_Load_Refused_No_Object :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

// The storage service refused the read: the fact Disk_Load_Read_Refused
// after it holds the fields of its error record.
@(log_fact = "root: refused {refused_process} from the disk: the storage service refused the read")
Disk_Load_Refused_Read_Refused :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: the storage service refused the read of a disk process: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Disk_Load_Read_Refused :: distinct errors.Error_Record_Fact_Fields

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave no answer that the description of its export allows")
Disk_Load_Refused_Answer_Not_Allowed :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the object has no byte")
Disk_Load_Refused_Object_Empty :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the object has {object_bytes} bytes, and the module file of a disk process has at most {file_bytes_limit}")
Disk_Load_Refused_Object_Too_Large :: struct {
	object_bytes:     u64,
	file_bytes_limit: u64,
	refused_process:  value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: no memory for its {object_bytes} bytes: status {status}")
Disk_Load_Refused_No_Memory :: struct {
	object_bytes:    u64,
	status:          op.Status_Word,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave no byte at the byte {received_bytes} of {object_bytes}")
Disk_Load_Refused_No_Byte_At :: struct {
	received_bytes:  u64,
	object_bytes:    u64,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave {given_bytes} bytes where the file has {left_bytes} left")
Disk_Load_Refused_Too_Many_Bytes :: struct {
	given_bytes:     u64,
	left_bytes:      u64,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: its bytes have the hash {found_hash}, and the hash asked is {hash}")
Disk_Load_Refused_Hash_Differs :: struct {
	found_hash:      value_kinds.Hash_Field,
	hash:            value_kinds.Hash_Field,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: it does not start: status {status}")
Disk_Load_Refused_Not_Started :: struct {
	status:          op.Status,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: its principal has no record")
Disk_Load_Refused_Principal_Without_Record :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the nickname names the file {named_hash} since the command, and the bytes have the hash {found_hash}")
Disk_Load_Refused_Nickname_Moved :: struct {
	named_hash:      value_kinds.Hash_Field,
	found_hash:      value_kinds.Hash_Field,
	refused_process: value_kinds.Module_Name_Field,
}

// The refusals of the import scan of a disk process.

@(log_fact = "root: refused {refused_process} from the disk: the storage service listed an entry whose name is out of its page")
Disk_Load_Refused_Import_Entry_Name_Outside :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service listed an entry whose kind names no kind")
Disk_Load_Refused_Import_Entry_Kind_Unknown :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: no memory in the budget of the disk processes for the {object_bytes} bytes of the file {file} of the store module_files: status {status}")
Disk_Load_Refused_Import_No_Memory :: struct {
	object_bytes:    u64,
	status:          op.Status_Word,
	refused_process: value_kinds.Module_Name_Field,
	file:            [24]u8,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave no byte at the byte {received_bytes} of {object_bytes} of the file {file}")
Disk_Load_Refused_Import_No_Byte_At :: struct {
	received_bytes:  u64,
	object_bytes:    u64,
	refused_process: value_kinds.Module_Name_Field,
	file:            [24]u8,
}

@(log_fact = "root: refused {refused_process} from the disk: the storage service gave {given_bytes} bytes where the file {file} has {left_bytes} left")
Disk_Load_Refused_Import_Too_Many_Bytes :: struct {
	given_bytes:     u64,
	left_bytes:      u64,
	refused_process: value_kinds.Module_Name_Field,
	file:            [24]u8,
}

@(log_fact = "root: refused {refused_process} from the disk: {importer} imports {hash}, and no file of the boot image or of the store module_files has bytes with this hash; the import scan read {scan_reads} files")
Disk_Load_Refused_Import_Missing :: struct {
	hash:            value_kinds.Hash_Field,
	scan_reads:      u64,
	refused_process: value_kinds.Module_Name_Field,
	importer:        value_kinds.Module_Name_Field,
}

// The import is missing, and the store had more entries than the scan
// notes.
@(log_fact = "root: refused {refused_process} from the disk: {importer} imports {hash}, and no file of the boot image or of the store module_files has bytes with this hash; the import scan read {scan_reads} files; the store has more entries than the 64 that the scan notes")
Disk_Load_Refused_Import_Missing_Entries_Left_Out :: struct {
	hash:            value_kinds.Hash_Field,
	scan_reads:      u64,
	refused_process: value_kinds.Module_Name_Field,
	importer:        value_kinds.Module_Name_Field,
}

@(log_fact = "root: refused {refused_process} from the disk: its imports outside the boot image pass the bounds of the import scan: {wanted_capacity} modules of the store, {depth_limit} levels")
Disk_Load_Refused_Import_Bounds :: struct {
	wanted_capacity: u64,
	depth_limit:     u64,
	refused_process: value_kinds.Module_Name_Field,
}
