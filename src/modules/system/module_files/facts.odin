package module_files

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The log facts of the module file service (src/md/features/log_facts.md):
// the files of the store that it lists with their hash, the listing that
// does not end, the store that it serves and the failure that stops it,
// as records of fields. Each fact template is the sentence that the line
// wrote before it was a fact, so a wait of a machine test on that sentence
// reads it as before. A line whose sentence differs by its case is one
// fact type for each case: the template has no condition. No field has
// the name of a column of the head of facts(): number, time, process,
// level.
//
// A name of an object of the store and an address are Text fields, and
// the last fields. A Text field is [N]u8 with N written out, as the tool
// reads it.

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96
// The bytes of the Text field of the name of an object of the store: an
// object name has at most 64 bytes, and a zero byte, on 8 bytes.
FILE_NAME_FIELD_BYTES :: 72
// The bytes of the Text field of an IPv4 address: the longest,
// "255.255.255.255", has 15 bytes, and a zero byte.
ADDRESS_FIELD_BYTES :: 16

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "module_files: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The listing of the store ended, with its count of module files.
@(log_fact = "module_files: listed {files} module files of the store module_files, each hash computed on its bytes")
Files_Listed :: struct {
	files: u64,
}

// A file of the store, with the hash of its bytes.
@(log_fact = "module_files: the file {file_name}, {size}, the BLAKE3 hash of its bytes {file_hash}")
File_Hashed :: struct {
	size:      value_kinds.Size_In_Bytes,
	file_hash: value_kinds.Hash_Field,
	file_name: [72]u8,
}

// A file of the store whose bytes did not come, or are too many for a
// module file.
@(log_fact = "module_files: the file {file_name}, {size}, has no hash: its bytes did not come, or pass the 67108864 bytes of a module file")
File_Not_Hashed :: struct {
	size:      value_kinds.Size_In_Bytes,
	file_name: [72]u8,
}

// The listing did not end after its most pages: a page here is a page of
// the listing, not a page of memory.
@(log_fact = "module_files: the listing of the store module_files did not end after {listing_pages} pages")
Listing_Not_Ended :: struct {
	listing_pages: u64,
}

// The service serves the store of its principal, and the web server where
// it reads the files.
@(log_fact = "module_files: serves the store module_files of principal {principal}: a file from the web server {remote_address} port {remote_port}, and the list of the files with the hash of their bytes")
Serving :: struct {
	principal:      u64,
	remote_port:    u64,
	remote_address: [16]u8,
}

// What the storage service refused, or what this service refused in an
// answer of the storage service: each is its own sentence, so its own fact
// types.
Store_Subject :: enum u8 {
	File               = 0, // A write, a size or a commit of the file of a nickname.
	Listing            = 1, // The listing of the root tree.
	Listing_Entry_Name = 2, // An entry of the listing has a name out of its page.
	Listing_Entry_Kind = 3, // An entry of the listing has a kind that names no kind.
}

// The storage service refused a change of a file: the values of its error
// record, after the name of the file.
@(log_fact = "module_files: the store module_files refused the file {nickname}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
File_Store_Refused :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	nickname: value_kinds.Module_Name_Field,
}

// The storage service gave an answer to a change of a file that its
// export does not allow.
@(log_fact = "module_files: the store module_files refused the file {nickname}: the storage service gave no answer that its export allows")
File_Store_Answer_Refused :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// The storage service refused the listing: the values of its error record.
@(log_fact = "module_files: the store module_files refused the listing of its root tree: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Listing_Store_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service gave an answer to the listing that its export does
// not allow.
@(log_fact = "module_files: the store module_files refused the listing of its root tree: the storage service gave no answer that its export allows")
Listing_Store_Answer_Refused :: struct {}

// An entry of the listing has a name out of its page.
@(log_fact = "module_files: the store module_files refused the listing of its root tree: an entry has a name out of its page: the storage service gave no answer that its export allows")
Listing_Entry_Name_Refused :: struct {}

// An entry of the listing has a kind that names no kind.
@(log_fact = "module_files: the store module_files refused the listing of its root tree: an entry has a kind that names no kind: the storage service gave no answer that its export allows")
Listing_Entry_Kind_Refused :: struct {}

// The bytes of the Text field of the problem of a GET: the longest, "the
// answer has no Content-Length of 1 byte to 64 MiB", has 52 bytes, and a
// zero byte.
GET_PROBLEM_FIELD_BYTES :: 64

// A GET of a module file failed, and nothing is stored. The path of the
// request has up to PATH_LIMIT bytes: a text view, the last field.
@(log_fact = "module_files: GET {path}: {problem}: nothing is stored")
Get_Failed :: struct {
	problem: [64]u8,
	path:    value_kinds.Text_View,
}

// A module file that a caller gave in memory, stored under its nickname,
// with the hash of its bytes.
@(log_fact = "module_files: put {nickname}: {size}, the BLAKE3 hash of its bytes {file_hash}")
File_Put :: struct {
	size:      value_kinds.Size_In_Bytes,
	file_hash: value_kinds.Hash_Field,
	nickname:  value_kinds.Module_Name_Field,
}

// A module file fetched whole and stored under its nickname, with the hash
// of its bytes. The path of the request is a text view, the last field.
@(log_fact = "module_files: stored {nickname} from {request_path}: {size}, the BLAKE3 hash of its bytes {file_hash}")
File_Stored :: struct {
	size:         value_kinds.Size_In_Bytes,
	file_hash:    value_kinds.Hash_Field,
	nickname:     value_kinds.Module_Name_Field,
	request_path: value_kinds.Text_View,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Get_Failed) == GET_PROBLEM_FIELD_BYTES + value_kinds.TEXT_VIEW_BYTES)
#assert(size_of(File_Stored) == 8 + value_kinds.HASH_FIELD_BYTES + value_kinds.MODULE_NAME_FIELD_BYTES + value_kinds.TEXT_VIEW_BYTES)
#assert(size_of(File_Store_Refused) == size_of(errors.Error_Record_Fact_Fields) + value_kinds.MODULE_NAME_FIELD_BYTES)
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
#assert(size_of(File_Not_Hashed) == 8 + FILE_NAME_FIELD_BYTES)
#assert(size_of(Serving) == 16 + ADDRESS_FIELD_BYTES)

// A write that stopped could not drop the pending changes of its staging
// object: they stay held on the connection of the service until the next
// write of the nickname drops them.
@(log_fact = "module_files: the pending changes of the staging object of {nickname} were not dropped: the next write of the nickname drops them")
Staging_Pending_Kept :: struct {
	nickname: value_kinds.Module_Name_Field,
}

// A staging object that a stop or a refused remove left: the service
// removed it.
@(log_fact = "module_files: removed the staging object {file_name}, which a write that stopped left")
Staging_Removed :: struct {
	file_name: [72]u8,
}
