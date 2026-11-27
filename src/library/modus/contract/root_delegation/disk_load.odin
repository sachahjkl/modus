// The contract between the root service core and the delegated service
// disk_processes for the load of a disk process
// (src/md/api/root_service_split.md, "The disk processes").
//
// The core is the one commander of the ring. It sends Load with a
// connection to the store module_files that reads only, and answers each
// event of the service with one command: the service sends one event, then
// waits for the next command. So the transfer region has one writer at a
// time, and a hostile service cannot flood the core.
//
// The bytes of each file travel in memory that the core makes and lends
// to the service with Read and Write. When the service says that a file is
// whole, the core revokes the loan, then computes the hash on its own
// mapping: no byte changes after that check.
//
// This is a contract package: it imports base and contract packages only,
// allocates no memory, and calls no kernel operation.
package root_delegation

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import module "modus:contract/module"
import "modus:contract/store"
import op "modus:contract/operation"

// The context of the service disk_processes.
DISK_PROCESSES_RING_SLOT :: 10 // Memory (Read, Write): the ring from the core, opened with Receive_Handles.
DISK_PROCESSES_REGION_SLOT :: 11 // Memory (Read, Write): the transfer region.
DISK_PROCESSES_IMAGE_SLOT :: 12 // Memory (Read): the boot image, for the imports that it holds and the file of the storage service.
DISK_PROCESSES_VALUE_IMAGE_SIZE :: 0 // The context value with the bytes of the boot image.

// The most bytes of the module file of a disk process, and of each file
// of the store that the import scan keeps: 64 MiB.
MODULE_BYTES_LIMIT :: 64 << 20

// What a load reads (Load_Request.kind). Zero is refused at the border.
Load_Kind :: enum u8 {
	None               = 0,
	// The module file of a disk process, from the store module_files, with
	// the import scan, then Ready.
	Module             = 1,
	// The script font set (modus:contract/font_outlines), from its store
	// of the machine: one object, with no scan. The core ends the load
	// after Module_Filled, once it checked the bytes, and keeps them.
	Script_Fonts       = 2,
	// The script font set (or its Script_Font_Pack_Manifest) fetched by its
	// BLAKE3 hash from a configured QUIC object cache over UDP (pinned
	// cache_server_key). The core checks the full BLAKE3 hash after loan end.
	Script_Fonts_Cache = 3,
	// Persist an already-verified script font set (lent read-only from root)
	// into the machine's script_fonts store on the local data disk.
	Script_Fonts_Store = 4,
}

// load_kind_of_word gives the kind of a word, refusing None and each word
// that names no member.
load_kind_of_word :: proc "contextless" (word: u8) -> (kind: Load_Kind, ok: bool) {
	member := enum_word.member_of_word(Load_Kind, u64(word)) or_return
	return member, member != .None
}

// load_bytes_limit gives the most bytes of the file that a load of a kind
// reads: the core lends memory of that size at most.
load_bytes_limit :: proc "contextless" (kind: Load_Kind) -> u64 {
	switch kind {
	case .None:
		return 0
	case .Module:
		return MODULE_BYTES_LIMIT
	case .Script_Fonts, .Script_Fonts_Cache, .Script_Fonts_Store:
		return font_outlines.SCRIPT_FONTS_BYTES_LIMIT
	}
	return 0
}

// The most files of the store that one load keeps for its imports: each
// module record of a process can be a file of the store.
LOAD_IMPORT_CAPACITY :: op.PROCESS_MODULE_CAPACITY

// The most entries of the root tree that the import scan of one load reads
// (disk_process.SCAN_ENTRY_CAPACITY).
LOAD_SCAN_ENTRY_CAPACITY :: 256

// The most bytes of the name of an entry of the store module_files: the
// most bytes of the name of any entry of a store.
LOAD_FILE_NAME_CAPACITY :: store.ENTRY_NAME_CAPACITY

// The most loans of an entry of the scan in one load: each entry one
// time, and two reads more for each wanted hash, as the scan reads
// (disk_process.SCAN_READ_LIMIT).
LOAD_CANDIDATE_LOAN_LIMIT :: LOAD_SCAN_ENTRY_CAPACITY + 2 * LOAD_IMPORT_CAPACITY

// The most replacements of the machine: the capacity of the replacement
// table.
LOAD_REPLACEMENT_CAPACITY :: 32

// The layout of the transfer region: two pages. The core writes the
// Load_Request in the first; the service writes each Event_Report in the
// second.
DISK_PROCESSES_REGION_PAGES :: 2
LOAD_REQUEST_OFFSET :: 0
EVENT_REPORT_OFFSET :: 4096

// A command of the core on the ring. Zero is refused at the border.
Disk_Load_Command :: enum u32 {
	None        = 0,
	// A new load. values 0, 1 and 2: the storage service, the call ring and
	// the call region of the connection, given through the ring. The
	// Load_Request is at LOAD_REQUEST_OFFSET.
	Load        = 1,
	// values 0: the memory lent for the file that Memory_Wanted named.
	Memory_Lent = 2,
	// The core took the last event: the load goes on.
	Continue    = 3,
	// The core ended the load: the service gives back what it holds for it
	// (the lent memory and the storage connection), then sends Cancelled.
	Cancel      = 4,
}

// An event of the service on the ring: the kind of a completion with the
// tag of the load. The Event_Report is at EVENT_REPORT_OFFSET.
Disk_Load_Event :: enum u32 {
	None              = 0,
	// The service asks for memory for one file: place and byte_count, and
	// file_name for a candidate.
	Memory_Wanted     = 1,
	// The module file is whole in the lent memory.
	Module_Filled     = 2,
	// The module imports hashes that the boot image does not hold: import_count.
	Scan_Started      = 3,
	// The lent file of the scan has a wanted hash: hash, file_name and importer_name.
	Import_Found      = 4,
	// The lent file of the scan has no wanted hash.
	Candidate_Dropped = 5,
	// Start_From_Bytes: start.
	Ready             = 6,
	// The load ends: refusal, and the fields of its cause.
	Refused           = 7,
	// The service refused a command of the core.
	Command_Refused   = 8,
	// The answer to Cancel: the service holds no memory of the load any
	// more, and the core can end each loan with no fault in the service.
	Cancelled         = 9,
}

// The file that a Memory_Wanted names.
File_Place :: enum u32 {
	None      = 0,
	Module    = 1, // The module file of the disk process.
	Candidate = 2, // An entry of the store that the import scan reads.
}

// Why the service ended a load.
Disk_Load_Refusal :: enum u32 {
	None                      = 0,
	Not_Mapped                = 1, // The call ring and the call region of the storage service do not map.
	Call_Not_Taken            = 2,
	Storage_Stopped           = 3,
	No_Object                 = 4, // The store has no object with the nickname.
	Read_Refused              = 5, // read_error, damaged, failed_value.
	Answer_Not_Allowed        = 6,
	Object_Empty              = 7,
	Object_Too_Large          = 8, // byte_count.
	No_Byte_At                = 9, // received_bytes, byte_count.
	Too_Many_Bytes            = 10, // received_bytes (given), left_bytes.
	Import_Entry_Name_Outside = 11,
	Import_Entry_Kind_Unknown = 12,
	Import_No_Byte_At         = 13, // received_bytes, byte_count, file_name.
	Import_Too_Many_Bytes     = 14, // received_bytes (given), left_bytes, file_name.
	Import_Missing            = 15, // hash, scan_reads, entries_left_out, importer_name.
	Import_Bounds             = 16,
	Cache_Not_Configured      = 17, // The datagram endpoint did not open or has no cache grant.
	Cache_Bad_Server_Key      = 18, // The object cache TLS handshake failed server key pinning.
	Cache_Network_Failed      = 19, // The object cache handshake, stream, or network transfer failed or timed out.
	Cache_Not_Found           = 20, // The object cache does not hold the requested BLAKE3 hash.
	Cache_Bad_Response        = 21, // The object cache sent a malformed, truncated, or out-of-contract frame.
	Cache_Hash_Mismatch       = 22, // A frame from the object cache failed Bao inclusion proof verification.
	Store_Write_Failed        = 23, // Persisting the verified script font set to the local store failed.
}

// What the core asks the service to load. The core writes it before Load.
Load_Request :: struct {
	kind:                  u8, // A Load_Kind word.
	principal:             u64,
	module_hash:           blake3.Hash,
	nickname:              [NICKNAME_CAPACITY]u8,
	nickname_length:       u8,
	storage_module:        [NICKNAME_CAPACITY]u8, // The module of the holder of Storage in the boot image: its file describes the exports.
	storage_module_length: u8,
	replacement_count:     u32,
	replacements:          [LOAD_REPLACEMENT_CAPACITY]module.Replacement,
	cache_server_key:      [32]u8, // Pinned Ed25519 public key of the QUIC object cache (Script_Fonts_Cache only).
	store_byte_count:      u64, // Exact verified byte count to persist (Script_Fonts_Store only).
}

// The request of a start from bytes: what the service read and kept. The
// core starts the module with the grants of the row of its nickname, never
// with a grant that the service names.
Start_From_Bytes_Request :: struct {
	principal:         u64,
	module_hash:       blake3.Hash,
	module_byte_count: u64,
	nickname:          [NICKNAME_CAPACITY]u8,
	nickname_length:   u8,
	import_count:      u32,
	import_hashes:     [LOAD_IMPORT_CAPACITY]blake3.Hash, // The hash of each kept file, in the order of its Import_Found.
}

// The fields of one event. Each event reads only the fields that its
// comment names; the others are zero.
Event_Report :: struct {
	place:                u32, // A File_Place word.
	refusal:              u32, // A Disk_Load_Refusal word.
	byte_count:           u64,
	received_bytes:       u64,
	left_bytes:           u64,
	import_count:         u64,
	scan_reads:           u64,
	entries_left_out:     u32, // 0 or 1.
	damaged:              u32, // 0 or 1: the storage service named the object damaged.
	failed_value:         i64, // The result of the refused read.
	hash:                 blake3.Hash,
	read_error:           errors.Error_Record,
	file_name:            [LOAD_FILE_NAME_CAPACITY]u8,
	file_name_length:     u32,
	importer_name_length: u32, // 0: the disk process itself imports the hash.
	importer_name:        [LOAD_FILE_NAME_CAPACITY]u8,
	start:                Start_From_Bytes_Request,
}

#assert(size_of(Load_Request) <= EVENT_REPORT_OFFSET)
#assert(size_of(Event_Report) <= DISK_PROCESSES_REGION_PAGES * 4096 - EVENT_REPORT_OFFSET)

// Where the core stands in a load: which event it takes next.
Disk_Load_Step :: enum u8 {
	Idle,
	Module_Asked, // Load was sent.
	Module_Lent, // The memory of the module file was lent.
	Module_Checked, // The hash of the module file was checked, and Continue was sent.
	Scan, // Continue after Scan_Started, Import_Found or Candidate_Dropped.
	Candidate_Lent, // The memory of an entry of the scan was lent.
}

// Why start_from_bytes_check refused a Start_From_Bytes_Request.
Start_From_Bytes_Refusal :: enum u8 {
	None                    = 0,
	Other_Principal         = 1,
	Other_Nickname          = 2,
	Trailing_Nickname_Bytes = 3,
	Other_Module_Hash       = 4,
	Other_Byte_Count        = 5,
	Too_Many_Imports        = 6,
	Other_Import_Count      = 7,
	Other_Import_Hash       = 8,
}

// disk_load_command_of_word gives the command of a word, refusing zero and
// each word that names no member.
disk_load_command_of_word :: proc "contextless" (word: u32) -> (command: Disk_Load_Command, ok: bool) {
	member := enum_word.member_of_word(Disk_Load_Command, u64(word)) or_return
	return member, member != .None
}

// disk_load_event_of_word gives the event of a word, refusing zero and
// each word that names no member.
disk_load_event_of_word :: proc "contextless" (word: u32) -> (event: Disk_Load_Event, ok: bool) {
	member := enum_word.member_of_word(Disk_Load_Event, u64(word)) or_return
	return member, member != .None
}

// file_place_of_word gives the place of a word, refusing zero and each
// word that names no member.
file_place_of_word :: proc "contextless" (word: u32) -> (place: File_Place, ok: bool) {
	member := enum_word.member_of_word(File_Place, u64(word)) or_return
	return member, member != .None
}

// disk_load_refusal_of_word gives the refusal of a word, refusing zero and
// each word that names no member.
disk_load_refusal_of_word :: proc "contextless" (word: u32) -> (refusal: Disk_Load_Refusal, ok: bool) {
	member := enum_word.member_of_word(Disk_Load_Refusal, u64(word)) or_return
	return member, member != .None
}

// packed_name gives the name of a field of a nickname, refusing a length
// out of its bounds and a byte after it that is not zero.
@(private = "file")
packed_name :: proc "contextless" (bytes: ^[NICKNAME_CAPACITY]u8, length: u8) -> (name: string, ok: bool) {
	if length == 0 || int(length) > NICKNAME_CAPACITY {
		return "", false
	}
	for index in int(length) ..< NICKNAME_CAPACITY {
		if bytes[index] != 0 {
			return "", false
		}
	}
	return string(bytes[:length]), true
}

// packed_empty says if a nickname field has zero length and all zero bytes.
@(private = "file")
packed_empty :: proc "contextless" (bytes: ^[NICKNAME_CAPACITY]u8, length: u8) -> bool {
	if length != 0 {
		return false
	}
	for value in bytes {
		if value != 0 {
			return false
		}
	}
	return true
}

// load_request_check reads a Load_Request at the border of the service.
// It refuses a request of no kind, one that names no nickname, no hash,
// missing or unexpected storage module, cache key, store size, or more
// replacements than the table holds.
load_request_check :: proc "contextless" (request: ^Load_Request) -> (kind: Load_Kind, nickname: string, storage_module: string, ok: bool) {
	kind = load_kind_of_word(request.kind) or_return
	nickname = packed_name(&request.nickname, request.nickname_length) or_return
	if request.module_hash == (blake3.Hash{}) || request.replacement_count > LOAD_REPLACEMENT_CAPACITY {
		return .None, "", "", false
	}
	switch kind {
	case .None:
		return .None, "", "", false
	case .Module, .Script_Fonts:
		storage_module = packed_name(&request.storage_module, request.storage_module_length) or_return
		if request.cache_server_key != {} || request.store_byte_count != 0 {
			return .None, "", "", false
		}
	case .Script_Fonts_Cache:
		if !packed_empty(&request.storage_module, request.storage_module_length) {
			return .None, "", "", false
		}
		if request.cache_server_key == {} || request.store_byte_count != 0 || request.replacement_count != 0 {
			return .None, "", "", false
		}
	case .Script_Fonts_Store:
		storage_module = packed_name(&request.storage_module, request.storage_module_length) or_return
		if request.cache_server_key != {} || request.replacement_count != 0 {
			return .None, "", "", false
		}
		if request.store_byte_count == 0 || request.store_byte_count > load_bytes_limit(.Script_Fonts_Store) {
			return .None, "", "", false
		}
	}
	return kind, nickname, storage_module, true
}

// refusal_allowed_at says if the service can end a load with a refusal at
// a step for a load kind: a refusal of the module file before its check,
// a refusal of the scan after it, a cache refusal only on Script_Fonts_Cache,
// and a store write refusal only on Script_Fonts_Store.
@(private = "file")
refusal_allowed_at :: proc "contextless" (kind: Load_Kind, step: Disk_Load_Step, refusal: Disk_Load_Refusal) -> bool {
	switch refusal {
	case .None:
		return false
	case .Call_Not_Taken, .Storage_Stopped, .Read_Refused, .Answer_Not_Allowed:
		return step != .Idle && kind != .Script_Fonts_Cache
	case .Not_Mapped:
		return step == .Module_Asked || (kind == .Script_Fonts_Store && step == .Module_Lent)
	case .Object_Empty, .Object_Too_Large:
		return step == .Module_Asked && kind != .Script_Fonts_Store
	case .No_Object:
		// The object can leave the store during its read, and the list of
		// the root tree can find no tree.
		return kind != .Script_Fonts_Cache && kind != .Script_Fonts_Store && (step == .Module_Asked || step == .Module_Lent || step == .Scan)
	case .No_Byte_At, .Too_Many_Bytes:
		return step == .Module_Lent && (kind == .Module || kind == .Script_Fonts)
	case .Import_Bounds:
		// The imports of the module file, or of a file that the scan kept.
		return kind == .Module && (step == .Module_Checked || step == .Scan)
	case .Import_Entry_Name_Outside, .Import_Entry_Kind_Unknown, .Import_Missing:
		return kind == .Module && step == .Scan
	case .Import_No_Byte_At, .Import_Too_Many_Bytes:
		return kind == .Module && step == .Candidate_Lent
	case .Cache_Not_Configured, .Cache_Bad_Server_Key, .Cache_Network_Failed, .Cache_Not_Found, .Cache_Bad_Response, .Cache_Hash_Mismatch:
		return kind == .Script_Fonts_Cache && (step == .Module_Asked || step == .Module_Lent)
	case .Store_Write_Failed:
		return kind == .Script_Fonts_Store && step == .Module_Lent
	}
	return false
}

// name_length_valid says if the length of a name of the report fits its
// field, and the bytes after it are zero.
@(private = "file")
name_length_valid :: proc "contextless" (bytes: ^[LOAD_FILE_NAME_CAPACITY]u8, length: u32, least: u32) -> bool {
	if length < least || length > LOAD_FILE_NAME_CAPACITY {
		return false
	}
	for index in int(length) ..< LOAD_FILE_NAME_CAPACITY {
		if bytes[index] != 0 {
			return false
		}
	}
	return true
}

// event_report_check reads one event of the service at the border of the
// core, after the copy of its report: the event must be one that the step
// takes, and each field that it reads must be in its bounds. kept_count is
// the count of the files that the core keeps for the imports;
// candidate_loans is the count of the loans of entries of the scan that
// the load made. Cancelled is never an event of a load that runs: the core
// reads it apart, with the tag of a load that it ended. kind is the kind of
// the load: its file is at most load_bytes_limit(kind) bytes, and a load of
// the script font set has no scan.
event_report_check :: proc "contextless" (kind: Load_Kind, step: Disk_Load_Step, event: Disk_Load_Event, report: ^Event_Report, kept_count: int, candidate_loans: int) -> bool {
	if kind == .None {
		return false
	}
	switch event {
	case .None, .Cancelled:
		return false
	case .Memory_Wanted:
		place, known := enum_word.member_of_word(File_Place, u64(report.place))
		limit := place == .Module ? load_bytes_limit(kind) : MODULE_BYTES_LIMIT
		if !known || report.byte_count == 0 || report.byte_count > limit {
			return false
		}
		if kind == .Script_Fonts_Store {
			return false
		}
		if place == .Candidate && kind != .Module {
			return false
		}
		switch place {
		case .None:
			return false
		case .Module:
			return step == .Module_Asked
		case .Candidate:
			return step == .Scan && kept_count < LOAD_IMPORT_CAPACITY && candidate_loans < LOAD_CANDIDATE_LOAN_LIMIT && name_length_valid(&report.file_name, report.file_name_length, 1)
		}
		return false
	case .Module_Filled:
		return step == .Module_Lent && kind != .Script_Fonts_Store
	case .Scan_Started:
		return kind == .Module && step == .Module_Checked && report.import_count >= 1 && report.import_count <= LOAD_IMPORT_CAPACITY
	case .Import_Found:
		return kind == .Module && step == .Candidate_Lent && kept_count < LOAD_IMPORT_CAPACITY && name_length_valid(&report.file_name, report.file_name_length, 1) && name_length_valid(&report.importer_name, report.importer_name_length, 0)
	case .Candidate_Dropped:
		return kind == .Module && step == .Candidate_Lent
	case .Ready:
		if kind == .Script_Fonts_Store {
			return step == .Module_Lent
		}
		return kind == .Module && (step == .Module_Checked || step == .Scan)
	case .Refused:
		refusal, known := enum_word.member_of_word(Disk_Load_Refusal, u64(report.refusal))
		// Each name is bounded for each cause: a length past its field is
		// refused before any line reads it.
		if !known || !refusal_allowed_at(kind, step, refusal) || report.entries_left_out > 1 || report.damaged > 1 {
			return false
		}
		if !name_length_valid(&report.file_name, report.file_name_length, 0) || !name_length_valid(&report.importer_name, report.importer_name_length, 0) {
			return false
		}
		#partial switch refusal {
		case .Import_No_Byte_At, .Import_Too_Many_Bytes:
			return name_length_valid(&report.file_name, report.file_name_length, 1)
		case .Import_Missing:
			return report.hash != (blake3.Hash{}) && name_length_valid(&report.importer_name, report.importer_name_length, 0)
		}
		return true
	case .Command_Refused:
		return step != .Idle
	}
	return false
}

// start_from_bytes_check reads a Start_From_Bytes_Request at the border of
// the core. The core gives what it knows on its own: the principal and the
// nickname of the load, the hash that the command named, the byte count of
// the module file that it lent, and the hash that it computed on each kept
// file after the end of its loan. The request must name each of them, and
// nothing else.
start_from_bytes_check :: proc "contextless" (request: ^Start_From_Bytes_Request, principal: u64, nickname: string, module_hash: blake3.Hash, module_byte_count: u64, kept_hashes: []blake3.Hash) -> Start_From_Bytes_Refusal {
	if request.principal != principal {
		return .Other_Principal
	}
	name, name_ok := packed_name(&request.nickname, request.nickname_length)
	if !name_ok {
		return .Trailing_Nickname_Bytes
	}
	if name != nickname {
		return .Other_Nickname
	}
	if request.module_hash != module_hash {
		return .Other_Module_Hash
	}
	if request.module_byte_count != module_byte_count {
		return .Other_Byte_Count
	}
	if request.import_count > LOAD_IMPORT_CAPACITY {
		return .Too_Many_Imports
	}
	if int(request.import_count) != len(kept_hashes) {
		return .Other_Import_Count
	}
	for hash, index in kept_hashes {
		if request.import_hashes[index] != hash {
			return .Other_Import_Hash
		}
	}
	for index in int(request.import_count) ..< LOAD_IMPORT_CAPACITY {
		if request.import_hashes[index] != (blake3.Hash{}) {
			return .Other_Import_Hash
		}
	}
	return .None
}
