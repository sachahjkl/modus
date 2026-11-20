package module_files

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
@(log_fact = "module_files: the file {file_name}, {size}, has no hash: its bytes did not come, or pass the 4194304 bytes of a module file")
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

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
#assert(size_of(File_Not_Hashed) == 8 + FILE_NAME_FIELD_BYTES)
#assert(size_of(Serving) == 16 + ADDRESS_FIELD_BYTES)
