// Pure state machine for the delegated disk_processes service
// (src/md/api/root_service_split.md).
//
// Maintains a read-only catalog of module_files entries, validates transitive
// import graphs with an iterative 3-color DFS (refusing missing imports,
// cycles, and excessive depth), answers debug-object lookups by module hash,
// and prepares border-validated Start_From_Bytes_Request records for the root
// service core.
//
// Allocates no memory and calls no kernel operation.
package disk_processes_core

import "modus:contract/blake3"
import rd "modus:contract/root_delegation"

// Fixed capacities of the catalog and import graph traversal.
CATALOG_CAPACITY :: 64
ENTRY_NAME_CAPACITY :: 64
DIRECT_IMPORTS_CAPACITY :: 16
MAX_IMPORT_DEPTH :: 16
DEBUG_OBJECT_BYTES_LIMIT :: 8 << 20

// Three-color DFS visitation marks for iterative cycle detection.
Import_Color :: enum u8 {
	White = 0,
	Gray  = 1,
	Black = 2,
}

// Why registering a catalog entry was refused.
Catalog_Refusal :: enum u8 {
	None                    = 0,
	Invalid_Name            = 1,
	Zero_Module_Hash        = 2,
	Empty_Module            = 3,
	Module_Too_Large        = 4,
	Too_Many_Direct_Imports = 5,
	Zero_Import_Hash        = 6,
	Self_Import             = 7,
	Duplicate_Import        = 8,
	Invalid_Debug_Object    = 9,
	Duplicate_Module_Hash   = 10,
	Catalog_Full            = 11,
}

// Why iterative import graph validation failed.
Import_Validation_Refusal :: enum u8 {
	None                  = 0,
	Zero_Module_Hash      = 1,
	Module_Not_Found      = 2,
	Missing_Import        = 3,
	Import_Cycle          = 4,
	Import_Depth_Exceeded = 5,
	Too_Many_Imports      = 6,
}

// Why preparing a Start_From_Bytes_Request failed.
Prepare_Start_Refusal :: enum u8 {
	None                  = 0,
	Module_Not_Found      = 1,
	Size_Mismatch         = 2,
	Hash_Mismatch         = 3,
	Import_Validation     = 4,
	Border_Validation     = 5,
	Too_Many_Grant_Words  = 6,
}

// Read-only catalog entry representing one module stored in module_files.
Catalog_Entry :: struct {
	active:              bool,
	name:                [ENTRY_NAME_CAPACITY]u8,
	name_length:         u8,
	module_hash:         blake3.Hash,
	byte_size:           u64,
	direct_imports:      [DIRECT_IMPORTS_CAPACITY]blake3.Hash,
	direct_import_count: u32,
	has_debug_object:    bool,
	debug_object_hash:   blake3.Hash,
	debug_object_size:   u64,
}

// Result of iterative 3-color DFS import graph validation.
Import_Validation_Result :: struct {
	refusal:         Import_Validation_Refusal,
	resolved_hashes: [rd.IMPORT_HASH_CAPACITY]blake3.Hash,
	resolved_count:  u32,
	max_depth_seen:  u32,
	offending_hash:  blake3.Hash,
}

// Metadata returned for a disk module's debug object lookup.
Debug_Object_Info :: struct {
	module_hash:       blake3.Hash,
	debug_object_hash: blake3.Hash,
	debug_object_size: u64,
}

// Input parameters for prepare_start_from_bytes.
Prepare_Start_Input :: struct {
	principal:             u64,
	nickname:              [rd.NICKNAME_CAPACITY]u8,
	nickname_length:       u8,
	module_hash:           blake3.Hash,
	requested_grant_words: [rd.GRANT_REQUEST_CAPACITY]u64,
	requested_grant_count: u32,
	budget_pages:          u64,
}

// Operational counters exposed through the service status export.
Disk_Processes_Counters :: struct {
	catalog_entries:    u64,
	import_validations: u64,
	debug_lookups:      u64,
	starts_prepared:    u64,
	total_refusals:     u64,
}

// Fixed-capacity state of the delegated disk_processes service.
Disk_Processes_State :: struct {
	initialized: bool,
	entries:     [CATALOG_CAPACITY]Catalog_Entry,
	entry_count: u32,
	counters:    Disk_Processes_Counters,
}

@(private = "file")
Dfs_Frame :: struct {
	catalog_index: int,
	next_child:    u32,
	depth:         u32,
}

// state_init resets and marks a Disk_Processes_State ready for use.
state_init :: proc "contextless" (state: ^Disk_Processes_State) {
	if state == nil {
		return
	}
	state^ = {}
	state.initialized = true
}

@(private = "file")
catalog_name_valid :: proc "contextless" (name: ^[ENTRY_NAME_CAPACITY]u8, length: u8) -> bool {
	if length == 0 || int(length) > ENTRY_NAME_CAPACITY {
		return false
	}
	for index in 0 ..< int(length) {
		ch := name[index]
		if ch <= ' ' || ch > '~' || ch == '/' {
			return false
		}
	}
	for index in int(length) ..< ENTRY_NAME_CAPACITY {
		if name[index] != 0 {
			return false
		}
	}
	text := string(name[:length])
	return text != "." && text != ".."
}

@(private = "file")
catalog_find_index :: proc "contextless" (state: ^Disk_Processes_State, module_hash: blake3.Hash) -> int {
	if state == nil || module_hash == (blake3.Hash{}) {
		return -1
	}
	for index in 0 ..< int(state.entry_count) {
		if state.entries[index].active && state.entries[index].module_hash == module_hash {
			return index
		}
	}
	return -1
}

// catalog_register inserts a read-only module_files entry after validating its
// name, size bounds, direct import hashes, and optional debug object metadata.
catalog_register :: proc "contextless" (state: ^Disk_Processes_State, entry: Catalog_Entry) -> Catalog_Refusal {
	if state == nil || !state.initialized {
		return .Catalog_Full
	}
	stored := entry
	if !catalog_name_valid(&stored.name, stored.name_length) {
		state.counters.total_refusals += 1
		return .Invalid_Name
	}
	if entry.module_hash == (blake3.Hash{}) {
		state.counters.total_refusals += 1
		return .Zero_Module_Hash
	}
	if entry.byte_size == 0 {
		state.counters.total_refusals += 1
		return .Empty_Module
	}
	if entry.byte_size > rd.MODULE_BYTES_LIMIT {
		state.counters.total_refusals += 1
		return .Module_Too_Large
	}
	if entry.direct_import_count > DIRECT_IMPORTS_CAPACITY {
		state.counters.total_refusals += 1
		return .Too_Many_Direct_Imports
	}
	for i in u32(0) ..< entry.direct_import_count {
		imp := entry.direct_imports[i]
		if imp == (blake3.Hash{}) {
			state.counters.total_refusals += 1
			return .Zero_Import_Hash
		}
		if imp == entry.module_hash {
			state.counters.total_refusals += 1
			return .Self_Import
		}
		for earlier in u32(0) ..< i {
			if entry.direct_imports[earlier] == imp {
				state.counters.total_refusals += 1
				return .Duplicate_Import
			}
		}
	}
	if entry.has_debug_object {
		if entry.debug_object_hash == (blake3.Hash{}) || entry.debug_object_size == 0 || entry.debug_object_size > DEBUG_OBJECT_BYTES_LIMIT {
			state.counters.total_refusals += 1
			return .Invalid_Debug_Object
		}
	} else {
		if entry.debug_object_hash != (blake3.Hash{}) || entry.debug_object_size != 0 {
			state.counters.total_refusals += 1
			return .Invalid_Debug_Object
		}
	}
	if catalog_find_index(state, entry.module_hash) >= 0 {
		state.counters.total_refusals += 1
		return .Duplicate_Module_Hash
	}
	if state.entry_count >= CATALOG_CAPACITY {
		state.counters.total_refusals += 1
		return .Catalog_Full
	}

	stored.active = true
	state.entries[state.entry_count] = stored
	state.entry_count += 1
	state.counters.catalog_entries = u64(state.entry_count)
	return .None
}

// validate_imports runs an iterative 3-color DFS over the read-only catalog
// starting at root_hash. It refuses missing imports, cycles, depth exceeding
// MAX_IMPORT_DEPTH, and transitive import sets larger than IMPORT_HASH_CAPACITY.
validate_imports :: proc "contextless" (state: ^Disk_Processes_State, root_hash: blake3.Hash) -> Import_Validation_Result {
	if state == nil || !state.initialized {
		return {refusal = .Module_Not_Found, offending_hash = root_hash}
	}
	state.counters.import_validations += 1
	if root_hash == (blake3.Hash{}) {
		state.counters.total_refusals += 1
		return {refusal = .Zero_Module_Hash}
	}
	root_index := catalog_find_index(state, root_hash)
	if root_index < 0 {
		state.counters.total_refusals += 1
		return {refusal = .Module_Not_Found, offending_hash = root_hash}
	}

	colors: [CATALOG_CAPACITY]Import_Color
	stack: [MAX_IMPORT_DEPTH + 2]Dfs_Frame
	stack_len := 0
	result: Import_Validation_Result

	colors[root_index] = .Gray
	stack[0] = {catalog_index = root_index, next_child = 0, depth = 0}
	stack_len = 1

	for stack_len > 0 {
		top := &stack[stack_len - 1]
		entry := &state.entries[top.catalog_index]

		if top.next_child < entry.direct_import_count {
			child_hash := entry.direct_imports[top.next_child]
			top.next_child += 1

			child_index := catalog_find_index(state, child_hash)
			if child_index < 0 {
				state.counters.total_refusals += 1
				return {refusal = .Missing_Import, offending_hash = child_hash}
			}

			switch colors[child_index] {
			case .Gray:
				state.counters.total_refusals += 1
				return {refusal = .Import_Cycle, offending_hash = child_hash}
			case .Black:
				// Already validated in an earlier branch of a diamond DAG.
			case .White:
				next_depth := top.depth + 1
				if next_depth > MAX_IMPORT_DEPTH {
					state.counters.total_refusals += 1
					return {refusal = .Import_Depth_Exceeded, offending_hash = child_hash}
				}
				if next_depth > result.max_depth_seen {
					result.max_depth_seen = next_depth
				}
				colors[child_index] = .Gray
				stack[stack_len] = {catalog_index = child_index, next_child = 0, depth = next_depth}
				stack_len += 1
			}
		} else {
			finished_index := top.catalog_index
			stack_len -= 1
			colors[finished_index] = .Black
			if finished_index != root_index {
				if result.resolved_count >= rd.IMPORT_HASH_CAPACITY {
					state.counters.total_refusals += 1
					return {refusal = .Too_Many_Imports, offending_hash = state.entries[finished_index].module_hash}
				}
				result.resolved_hashes[result.resolved_count] = state.entries[finished_index].module_hash
				result.resolved_count += 1
			}
		}
	}

	return result
}

// lookup_debug_object returns the debug object hash and size associated with
// module_hash in the read-only catalog, if present.
lookup_debug_object :: proc "contextless" (state: ^Disk_Processes_State, module_hash: blake3.Hash) -> (info: Debug_Object_Info, found: bool) {
	if state == nil || !state.initialized {
		return {}, false
	}
	state.counters.debug_lookups += 1
	index := catalog_find_index(state, module_hash)
	if index < 0 {
		return {}, false
	}
	entry := &state.entries[index]
	if !entry.has_debug_object {
		return {}, false
	}
	return {
		module_hash       = entry.module_hash,
		debug_object_hash = entry.debug_object_hash,
		debug_object_size = entry.debug_object_size,
	}, true
}

// prepare_start_from_bytes verifies module_bytes against the catalog, runs the
// iterative import validator, assembles a Start_From_Bytes_Request, and runs
// the root core border validator before returning the ready request.
prepare_start_from_bytes :: proc "contextless" (
	state: ^Disk_Processes_State,
	input: ^Prepare_Start_Input,
	module_bytes: []u8,
) -> (
	request: rd.Start_From_Bytes_Request,
	refusal: Prepare_Start_Refusal,
	import_refusal: Import_Validation_Refusal,
	border_refusal: rd.Start_From_Bytes_Refusal,
) {
	if state == nil || !state.initialized || input == nil {
		return {}, .Module_Not_Found, .None, .None
	}
	index := catalog_find_index(state, input.module_hash)
	if index < 0 {
		state.counters.total_refusals += 1
		return {}, .Module_Not_Found, .None, .None
	}
	entry := &state.entries[index]
	if u64(len(module_bytes)) != entry.byte_size {
		state.counters.total_refusals += 1
		return {}, .Size_Mismatch, .None, .None
	}
	if blake3.hash(module_bytes) != entry.module_hash {
		state.counters.total_refusals += 1
		return {}, .Hash_Mismatch, .None, .None
	}
	if input.requested_grant_count > rd.GRANT_REQUEST_CAPACITY {
		state.counters.total_refusals += 1
		return {}, .Too_Many_Grant_Words, .None, .None
	}

	import_res := validate_imports(state, input.module_hash)
	if import_res.refusal != .None {
		return {}, .Import_Validation, import_res.refusal, .None
	}

	request = rd.Start_From_Bytes_Request {
		principal             = input.principal,
		nickname              = input.nickname,
		nickname_length       = input.nickname_length,
		expected_module_hash  = entry.module_hash,
		module_byte_count     = entry.byte_size,
		import_hashes         = import_res.resolved_hashes,
		import_count          = import_res.resolved_count,
		requested_grant_words = input.requested_grant_words,
		requested_grant_count = input.requested_grant_count,
		budget_pages          = input.budget_pages,
	}

	validation := rd.validate_start_from_bytes_request(&request, module_bytes)
	if validation.refusal != .None {
		state.counters.total_refusals += 1
		return {}, .Border_Validation, .None, validation.refusal
	}

	state.counters.starts_prepared += 1
	return request, .None, .None, .None
}
