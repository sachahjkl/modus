// Read-only boot-image tree serving, split object cache, durable pin exports,
// and principal-lock/reclaim eviction for the storage service
// (src/md/features/objects_by_hash.md).
package storage_service

import "base:intrinsics"
import object_cache "internal:storage/object_cache"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/image_tree"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/storage_object"
import format "modus:contract/store"
import "modus:system"

// Format property: kernel handle table places reserved for non-cache handles
// (context handles, wait set, DMA region, disk tables, and transient creation
// handles) so private cache entries cannot exhaust the handle table.
STORAGE_BASE_HANDLES :: 32
#assert(
	STORAGE_BASE_HANDLES +
	isolated.SERVICE_CONNECTION_CAPACITY * 2 +
	SHARE_CAPACITY * 2 +
	object_cache.PUBLIC_CACHE_CAPACITY +
	object_cache.PRIVATE_CACHE_CAPACITY * 2 <= op.HANDLE_TABLE_CAPACITY - 1,
)

// Plan value: maximum read-only image-tree subtrees attached to one storage
// connection, matching root.READ_ONLY_TREE_LIMIT.
CONNECTION_TREE_GRANT_LIMIT :: 4

// Format property: maximum byte length of a serialized Map_Object_Request
// (60-byte header + OBJECT_PATH_LIMIT path bytes).
MAP_REQUEST_BUFFER_SIZE :: storage_object.MAP_OBJECT_REQUEST_HEADER_SIZE + format.OBJECT_PATH_LIMIT

// Plan value: static wire scratch for one call-region Ambiguity_Table reply
// (fits inside half of the 64 KiB isolated call region).
AMBIGUITY_WIRE_BUFFER_SIZE :: 32768

// Format property: exact maximum byte length of a List_Pins_Answer
// (24-byte header + LIST_PINS_LIMIT * 48-byte pin records).
LIST_PINS_WIRE_BUFFER_SIZE :: storage_object.LIST_PINS_HEADER_SIZE + storage_object.LIST_PINS_LIMIT * storage_object.PIN_RECORD_SIZE

// Connection-level read-only image-tree subtree grants configured by root via
// Service_Command.Tree_Grant. Never consumes SHARE_CAPACITY.
Connection_Tree_Grants :: struct {
	count:     int,
	paths:     [CONNECTION_TREE_GRANT_LIMIT][isolated.TREE_GRANT_PATH_STORAGE]u8,
	path_lens: [CONNECTION_TREE_GRANT_LIMIT]int,
	nodes:     [CONNECTION_TREE_GRANT_LIMIT]u32,
}

storage_object_cache: object_cache.Cache
storage_object_pins: object_cache.Pin_Table

// Dedicated internal writable wipe handles for Private_Principal cache entries,
// indexed identically to storage_object_cache.private_entries. Clients receive
// Read-only handles derived from the entry's stripped ro_handle (stored in
// Cache_Entry.memory_handle), never from these handles. Retaining the writable
// parent handle lets storage volatile-zero plaintext pages on Principal_Locked,
// Principal_Reclaim, store reclamation, and non-crashing eviction while keeping
// handle_holdings(ro_handle) == 0 whenever no client maps the object.
private_wipe_handles: [object_cache.PRIVATE_CACHE_CAPACITY]system.Handle

// Validated read-only boot-image view owned by storage (never given to clients).
storage_image_memory: system.Handle
storage_image: []u8
storage_image_tree: []u8
storage_image_tree_header: image_tree.Header
storage_image_file_check: info.File_Check = .Root_Service_At_Load

// Per-resource lazy BLAKE3 verification flags for File_Check.Root_Service_At_Load.
// Format property: bounded by system.IMAGE_CHECK_CAPACITY.
image_resource_verified: [system.IMAGE_CHECK_CAPACITY]bool

// Parallel table indexed identically to service.connections.
connection_tree_grants: [isolated.SERVICE_CONNECTION_CAPACITY]Connection_Tree_Grants

// Static scratch buffers so large wire structures never live on the stack.
map_request_scratch: [MAP_REQUEST_BUFFER_SIZE]u8
ambiguity_wire_scratch: [AMBIGUITY_WIRE_BUFFER_SIZE]u8
ambiguity_matches_scratch: [storage_object.AMBIGUITY_RECORD_LIMIT]image_tree.Ambiguity_Match
ambiguity_entries_scratch: [storage_object.AMBIGUITY_RECORD_LIMIT]storage_object.Ambiguity_Entry
list_pins_info_scratch: [storage_object.LIST_PINS_LIMIT]object_cache.Pin_Info
list_pins_records_scratch: [storage_object.LIST_PINS_LIMIT]storage_object.Pin_Record
list_pins_wire_scratch: [LIST_PINS_WIRE_BUFFER_SIZE]u8
private_lookup_path_scratch: [NESTING_LIMIT + 1]Entry_Name

// storage_object_cache_init initializes the split read-only object cache and
// durable pin table with plan defaults.
storage_object_cache_init :: proc "contextless" () {
	object_cache.cache_init(&storage_object_cache, object_cache.default_cache_config())
	object_cache.pin_table_init(&storage_object_pins)
	private_wipe_handles = {}
}

// storage_object_is_pinned reports whether any principal holds a durable pin on
// (store_index, hash), blocking collect_garbage and erase_versions.
storage_object_is_pinned :: proc "contextless" (store_index: u32, hash: blake3.Hash) -> bool {
	return object_cache.is_pinned(&storage_object_pins, store_index, hash)
}

// storage_object_store_has_pins reports whether any durable pin exists in
// store_index, allowing erase_versions to skip version hashing on unpinned stores.
storage_object_store_has_pins :: proc "contextless" (store_index: u32) -> bool {
	if storage_object_pins.entry_count == 0 {
		return false
	}
	for &entry in storage_object_pins.entries {
		if entry.occupied && entry.store_index == store_index && entry.pin_count > 0 {
			return true
		}
	}
	return false
}

// storage_object_holdings_query reads kernel Handle_State.holdings and converts
// the 0-based count of external holdings into object_cache's 1-based total
// holding count (1 means only storage holds the handle).
storage_object_holdings_query :: proc "contextless" (memory_handle: u64, _: rawptr) -> (holdings: u64, ok: bool) {
	if memory_handle == 0 {
		return 0, false
	}
	return system.handle_holdings(system.Handle(memory_handle)) + 1, true
}

// storage_image_tree_init maps the read-only boot image, verifies and validates
// the canonical IMGTREE1 manifest against the boot-image resource table, and
// sets readiness.image_tree_ready before storage touches any data disk.
storage_image_tree_init :: proc "contextless" (ctx: ^system.Context) {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	image_size := ctx.values[system.GRANT_VALUE_IMAGE_SIZE]
	if image_handle == 0 || image_size == 0 {
		system.log_fact(.Warning, Image_Tree_Unavailable{problem = u64(image_tree.Problem.Truncated)})
		return
	}
	// Fail closed to on-demand BLAKE3 hashing unless root explicitly reports
	// Boot_Program verification.
	file_check, fc_ok := info.file_check_of_word(ctx.values[system.GRANT_VALUE_IMAGE_FILE_CHECK])
	if !fc_ok || file_check == .None {
		file_check = .Root_Service_At_Load
	}
	storage_image_file_check = file_check

	address, map_status := system.memory_map(image_handle, {})
	if map_status != .Succeeded || address == nil {
		system.log_fact(.Warning, Image_Tree_Unavailable{problem = u64(image_tree.Problem.Truncated)})
		return
	}
	storage_image_memory = image_handle
	storage_image = ([^]u8)(address)[:image_size]

	manifest_entry := system.image_resource_find(storage_image, image_tree.RESOURCE_NAME)
	if manifest_entry == nil || manifest_entry.offset > image_size || manifest_entry.size > image_size - manifest_entry.offset {
		system.log_fact(.Warning, Image_Tree_Unavailable{problem = u64(image_tree.Problem.Truncated)})
		return
	}
	manifest_bytes := storage_image[manifest_entry.offset:][:manifest_entry.size]
	if storage_image_file_check != .Boot_Program {
		if blake3.hash(manifest_bytes) != manifest_entry.hash {
			system.log_fact(.Warning, Image_Tree_Unavailable{problem = u64(image_tree.Problem.Resource_Mismatch)})
			return
		}
	}
	resources := system.image_resources(storage_image)
	header, problem := image_tree.validate_against_resources(manifest_bytes, resources)
	if problem != .None {
		system.log_fact(.Warning, Image_Tree_Unavailable{problem = u64(problem)})
		return
	}
	storage_image_tree = manifest_bytes
	storage_image_tree_header = header
	readiness.image_tree_ready = true
	system.log_fact(.Info, Image_Tree_Ready{nodes = u64(header.node_count), entries = u64(header.entry_count)})
}

// connection_index_of finds the index of ring_memory in service.connections, or -1.
@(private = "file")
connection_index_of :: proc "contextless" (svc: ^system.Service, ring_memory: system.Handle) -> int {
	if ring_memory == 0 {
		return -1
	}
	for &conn, index in svc.connections {
		if conn.calls.head != nil && conn.ring_memory == ring_memory {
			return index
		}
	}
	return -1
}

// storage_tree_grant handles Service_Command.Tree_Grant from root, attaching
// one validated read-only image-tree subtree root to the named connection.
storage_tree_grant :: proc "contextless" (svc: ^system.Service, ring_memory: system.Handle, values: ^[7]u64) {
	conn_index := connection_index_of(svc, ring_memory)
	if conn_index < 0 || !readiness.image_tree_ready {
		return
	}
	path_buf: [isolated.TREE_GRANT_PATH_STORAGE]u8
	path_len := isolated.tree_grant_unpack(values, &path_buf)
	if path_len == 0 {
		return
	}
	path := string(path_buf[:path_len])
	node_index, problem, _ := image_tree.subtree_resolve(storage_image_tree, path)
	if problem != .None {
		return
	}
	grants := &connection_tree_grants[conn_index]
	for existing in 0 ..< grants.count {
		if grants.nodes[existing] == node_index {
			return
		}
	}
	if grants.count >= CONNECTION_TREE_GRANT_LIMIT {
		return
	}
	slot := grants.count
	grants.paths[slot] = path_buf
	grants.path_lens[slot] = path_len
	grants.nodes[slot] = node_index
	grants.count += 1
}

// connection_tree_grants_clear removes all read-only image-tree subtree grants
// attached to ring_memory when its connection disconnects.
connection_tree_grants_clear :: proc "contextless" (ring_memory: system.Handle) {
	conn_index := connection_index_of(&service, ring_memory)
	if conn_index >= 0 {
		connection_tree_grants[conn_index] = {}
	}
}

// caller_tree_grants fills out with the active read-only image-tree subtree
// grants for caller. Shares never inherit image-tree grants.
@(private = "file")
caller_tree_grants :: proc "contextless" (caller: ^Caller, out: ^[CONNECTION_TREE_GRANT_LIMIT]image_tree.Subtree_Grant) -> []image_tree.Subtree_Grant {
	if caller.connection == nil || share_of(caller.connection) != nil {
		return nil
	}
	conn_index := connection_index_of(&service, caller.connection.ring_memory)
	if conn_index < 0 {
		return nil
	}
	grants := &connection_tree_grants[conn_index]
	for i in 0 ..< grants.count {
		out[i] = {
			tree_name = string(grants.paths[i][:grants.path_lens[i]]),
			root_node = grants.nodes[i],
		}
	}
	return out[:grants.count]
}

// memory_handle_volatile_zero maps a writable memory handle, scrubs every page
// with volatile zeros, and unmaps it.
@(private = "file")
memory_handle_volatile_zero :: proc "contextless" (handle: system.Handle, pages: u64) {
	if handle == 0 || pages == 0 {
		return
	}
	if addr, map_status := system.memory_map(handle, {.Write}); map_status == .Succeeded && addr != nil {
		intrinsics.mem_zero_volatile(addr, int(pages * object_cache.PAGE_SIZE))
		system.memory_unmap(addr)
	}
}

// storage_object_purge_entry revokes every derived reader handle/mapping,
// volatile-zeroes every page of a Private_Principal entry through its retained
// writable wipe handle, and closes both handles.
@(private = "file")
storage_object_purge_entry :: proc "contextless" (entry: object_cache.Evicted_Entry) {
	if entry.memory_handle == 0 {
		return
	}
	ro_handle := system.Handle(entry.memory_handle)
	// Revoke all reader handles and mappings immediately so no reader observes
	// locked or reclaimed plaintext.
	_, _ = system.handle_revoke(ro_handle)
	wipe_handle: system.Handle
	if entry.class == .Private_Principal && entry.slot_index >= 0 && entry.slot_index < len(private_wipe_handles) {
		wipe_handle = private_wipe_handles[entry.slot_index]
		private_wipe_handles[entry.slot_index] = 0
	}
	if wipe_handle != 0 {
		memory_handle_volatile_zero(wipe_handle, entry.pages)
		system.close(wipe_handle)
	} else {
		memory_handle_volatile_zero(ro_handle, entry.pages)
	}
	system.close(ro_handle)
}

// storage_object_purge_principal revokes and frees every cached private object
// owned by principal_id, and optionally removes all durable pins of that
// principal (on Principal_Reclaim). Public_System entries are never touched.
storage_object_purge_principal :: proc "contextless" (principal_id: u64, clear_pins: bool) {
	batch: [16]object_cache.Evicted_Entry
	for {
		written, remaining := object_cache.reclaim_principal(&storage_object_cache, principal_id, batch[:])
		for i in 0 ..< written {
			storage_object_purge_entry(batch[i])
		}
		if remaining == 0 || written == 0 {
			break
		}
	}
	if clear_pins {
		_, _ = object_cache.reclaim_principal_pins(&storage_object_pins, principal_id)
	}
}

// storage_object_purge_store revokes and frees every cached private object
// belonging to store_index when that store enters or leaves reclamation.
storage_object_purge_store :: proc "contextless" (store_index: u32) {
	batch: [16]object_cache.Evicted_Entry
	for {
		written, remaining := object_cache.reclaim_store(&storage_object_cache, store_index, batch[:])
		for i in 0 ..< written {
			storage_object_purge_entry(batch[i])
		}
		if remaining == 0 || written == 0 {
			break
		}
	}
}

// image_object_cached_handle returns a cached read-only kernel memory handle
// for one resolved image-tree object, copying bytes once on first demand into
// a freshly created Memory object paid from storage's machine-object budget and
// stripping Write and Execute rights from storage's retained handle.
// Never hands out image_memory directly.
@(private = "file")
image_object_cached_handle :: proc "contextless" (resolved: image_tree.Resolved_Object) -> (handle: system.Handle, result: storage_object.Map_Object_Result) {
	if existing, _, hit := object_cache.lookup_public(&storage_object_cache, resolved.hash); hit {
		return system.Handle(existing.memory_handle), .Mapped
	}

	resources := system.image_resources(storage_image)
	if u64(resolved.image_entry_index) >= u64(len(resources)) {
		return 0, .Damaged
	}
	resource := &resources[resolved.image_entry_index]
	if resource.offset > u64(len(storage_image)) || resource.size > u64(len(storage_image)) - resource.offset || resource.size != resolved.size {
		return 0, .Damaged
	}
	resource_bytes := storage_image[resource.offset:][:resource.size]

	// Under Root_Service_At_Load, verify BLAKE3 on first demand before copying
	// into a shared read-only memory object.
	if storage_image_file_check != .Boot_Program {
		idx := int(resolved.image_entry_index)
		already_checked := idx < len(image_resource_verified) && image_resource_verified[idx]
		if !already_checked {
			if blake3.hash(resource_bytes) != resolved.hash {
				system.log_fact(.Warning, Image_Object_Hash_Failed{index = u64(resolved.image_entry_index)})
				return 0, .Damaged
			}
			if idx < len(image_resource_verified) {
				image_resource_verified[idx] = true
			}
		}
	}

	pages, pages_ok := object_cache.pages_for_bytes(resolved.size)
	if !pages_ok {
		return 0, .Quota_Full
	}

	rw_handle, create_status := system.memory_create(pages)
	for _ in 0 ..< object_cache.PRIVATE_CACHE_CAPACITY {
		if create_status == .Succeeded {
			break
		}
		if !private_cache_evict_one(0, .Any_Private) {
			break
		}
		rw_handle, create_status = system.memory_create(pages)
	}
	if create_status != .Succeeded {
		return 0, .Quota_Full
	}
	rw_addr, map_status := system.memory_map(rw_handle, {.Write})
	if map_status != .Succeeded || rw_addr == nil {
		system.close(rw_handle)
		return 0, .Quota_Full
	}
	total_bytes := int(pages * object_cache.PAGE_SIZE)
	dst := ([^]u8)(rw_addr)[:total_bytes]
	if len(resource_bytes) > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(dst), raw_data(resource_bytes), len(resource_bytes))
	}
	if total_bytes > len(resource_bytes) {
		intrinsics.mem_zero(raw_data(dst[len(resource_bytes):]), total_bytes - len(resource_bytes))
	}
	system.memory_unmap(rw_addr)

	// Strip Write and Execute from storage's retained handle; keep Give and Read
	// so storage can grant Read-only handles to every future caller.
	ro_handle, ro_status := system.give(0, rw_handle, {.Give, .Read})
	for _ in 0 ..< object_cache.PRIVATE_CACHE_CAPACITY {
		if ro_status == .Succeeded && ro_handle != 0 {
			break
		}
		if !private_cache_evict_one(0, .Any_Private) {
			break
		}
		ro_handle, ro_status = system.give(0, rw_handle, {.Give, .Read})
	}
	system.close(rw_handle)
	if ro_status != .Succeeded || ro_handle == 0 {
		return 0, .Quota_Full
	}

	_, insert_res := object_cache.insert_public(&storage_object_cache, resolved.hash, u64(ro_handle), resolved.size, pages)
	switch insert_res {
	case .Inserted:
		return ro_handle, .Mapped
	case .Already_Present:
		system.close(ro_handle)
		if existing, _, hit := object_cache.lookup_public(&storage_object_cache, resolved.hash); hit {
			return system.Handle(existing.memory_handle), .Mapped
		}
		return 0, .Quota_Full
	case .Quota_Exceeded, .Table_Full, .Invalid_Argument:
		system.close(ro_handle)
		return 0, .Quota_Full
	}
	system.close(ro_handle)
	return 0, .Quota_Full
}

@(private = "file")
append_remaining :: proc "contextless" (out: ^system.Bytes_To_Append) -> int {
	if out == nil || out.bytes == nil || out.count >= out.capacity {
		return 0
	}
	return int(min(out.capacity - out.count, u64(max(int))))
}

@(private = "file")
map_object_answer_write :: proc "contextless" (out: ^system.Bytes_To_Append, ans: storage_object.Map_Object_Answer) {
	if append_remaining(out) < storage_object.MAP_OBJECT_ANSWER_SIZE {
		return
	}
	encoded: [storage_object.MAP_OBJECT_ANSWER_SIZE]u8
	written, problem := storage_object.map_object_answer_encode(ans, encoded[:])
	if problem == .None && written > 0 {
		_ = system.bytes_append(out, encoded[:written])
	}
}

@(private = "file")
map_object_fail :: proc "contextless" (
	answer_out: ^system.Bytes_To_Append,
	error: ^errors.Error_Record,
	ans: storage_object.Map_Object_Answer,
	unit: errors.Unit = .Objects,
	argument: i64 = 1,
	found: i64 = 0,
) -> (call_outcome.Call_Outcome, i64) {
	map_object_answer_write(answer_out, ans)
	outcome, kind := storage_object.map_object_result_outcome(ans.result)
	return refuse(error, outcome, kind, unit, argument, 0, 0, found), 0
}

// Outcome of looking up an exact '/' object path in a caller's private store.
@(private = "file")
Private_Lookup_Status :: enum u8 {
	Not_Found   = 0,
	Found       = 1,
	Unavailable = 2,
	Damaged     = 3,
}

// private_store_lookup resolves a validated exact '/' path in caller's private
// store (confined to caller.path[:caller.depth] for shares). Naming a subtree
// instead of an object returns Not_Found.
@(private = "file")
private_store_lookup :: proc "contextless" (caller: ^Caller, object_path: string) -> (store_index: int, entry: Entry, status: Private_Lookup_Status) {
	if caller.store.limit == 0 {
		return -1, {}, .Not_Found
	}
	if !disk_opened || broken {
		return -1, {}, .Unavailable
	}
	// Prepend share prefix so a share can never escape above its granted subtree.
	depth := caller.depth
	if depth > NESTING_LIMIT {
		return -1, {}, .Not_Found
	}
	for i in 0 ..< depth {
		private_lookup_path_scratch[i] = caller.path[i]
	}
	// Split validated '/' path into Entry_Name segments.
	seg_start := 0
	for i in 0 ..= len(object_path) {
		if i < len(object_path) && object_path[i] != '/' {
			continue
		}
		seg := object_path[seg_start:i]
		if len(seg) == 0 || len(seg) > format.ENTRY_NAME_CAPACITY || depth >= len(private_lookup_path_scratch) {
			return -1, {}, .Not_Found
		}
		private_lookup_path_scratch[depth] = {}
		copy(private_lookup_path_scratch[depth][:], seg)
		depth += 1
		seg_start = i + 1
	}
	if depth <= caller.depth {
		return -1, {}, .Not_Found
	}
	group_flush_if_conflict(caller.store.name)
	store_index = store_find(caller.store.name)
	if store_index < 0 {
		return -1, {}, .Not_Found
	}
	if store_damaged[store_index] {
		return -1, {}, .Damaged
	}
	parent_depth := depth - 1
	leaf_key := private_lookup_path_scratch[parent_depth]
	found_entry, lookup := entry_of(store_index, private_lookup_path_scratch[:parent_depth], leaf_key)
	switch lookup {
	case .Device:
		return -1, {}, .Unavailable
	case .Wrong:
		return -1, {}, .Damaged
	case .Absent:
		return -1, {}, .Not_Found
	case .Found:
		if found_entry.kind != u64(format.Entry_Kind.Object) {
			return -1, {}, .Not_Found
		}
		return store_index, found_entry, .Found
	}
	return -1, {}, .Not_Found
}

// private_cache_evict_one evicts one idle (holdings == 1) Private_Principal
// entry under scope and scrubs its pages. Never touches active mappings or
// Public_System entries.
@(private = "file")
private_cache_evict_one :: proc "contextless" (principal_id: u64, scope: object_cache.Evict_Scope) -> bool {
	candidate, evict_res := object_cache.evict_candidate(&storage_object_cache, principal_id, scope, storage_object_holdings_query, nil)
	if evict_res != .Found {
		return false
	}
	if removed, ok := object_cache.remove_private_slot(&storage_object_cache, candidate.slot_index); ok {
		storage_object_purge_entry(removed)
		return true
	}
	return false
}

// private_cache_make_room checks whether a private object of pages can enter
// the cache for principal_id, evicting only idle (holdings == 1) entries.
// Per-principal quota pressure evicts ONLY Same_Principal so one principal at
// its quota can never flush another principal's cache; Any_Private eviction
// runs only after principal_used + pages fits principal_private_pages.
@(private = "file")
private_cache_make_room :: proc "contextless" (principal_id: u64, pages: u64) -> bool {
	for _ in 0 ..= object_cache.PRIVATE_CACHE_CAPACITY {
		switch object_cache.private_admit_need(&storage_object_cache, principal_id, pages) {
		case .Ready:
			return true
		case .Impossible:
			return false
		case .Need_Principal_Pages:
			if !private_cache_evict_one(principal_id, .Same_Principal) {
				return false
			}
		case .Need_Global_Or_Slot:
			if !private_cache_evict_one(principal_id, .Same_Principal) && !private_cache_evict_one(principal_id, .Any_Private) {
				return false
			}
		}
	}
	return object_cache.private_admit_need(&storage_object_cache, principal_id, pages) == .Ready
}

// private_object_cached_handle returns a cached read-only kernel memory handle
// for one disk-backed Private_Principal object keyed strictly by
// (principal_id, store_index, expected_hash). On miss, enforces per-principal
// and global admission BEFORE allocating or reading disk blocks, reads verified
// plaintext once into a new Memory object, checks its BLAKE3 hash, derives a
// stripped {.Give, .Read} handle for clients, retains the writable handle in
// private_wipe_handles for secure zeroing, and evicts only idle (holdings == 1)
// private entries under cache pressure.
@(private = "file")
private_object_cached_handle :: proc "contextless" (
	principal_id: u64,
	store_index: u32,
	state: State_Of_Object,
	expected_hash: blake3.Hash,
) -> (handle: system.Handle, result: storage_object.Map_Object_Result) {
	if existing, _, hit := object_cache.lookup_private(&storage_object_cache, principal_id, store_index, expected_hash); hit {
		return system.Handle(existing.memory_handle), .Mapped
	}
	if state.size > format.OBJECT_SIZE_LIMIT {
		return 0, .Quota_Full
	}
	pages, pages_ok := object_cache.pages_for_bytes(state.size)
	if !pages_ok {
		return 0, .Quota_Full
	}
	// Pre-check and evict before memory_create, state_read, and blake3.hash so
	// a caller at its active quota never forces disk reads or flushes another
	// principal's idle entries.
	if !private_cache_make_room(principal_id, pages) {
		return 0, .Quota_Full
	}

	rw_handle, create_status := system.memory_create(pages)
	for _ in 0 ..< object_cache.PRIVATE_CACHE_CAPACITY {
		if create_status == .Succeeded {
			break
		}
		if !private_cache_evict_one(principal_id, .Same_Principal) && !private_cache_evict_one(principal_id, .Any_Private) {
			break
		}
		rw_handle, create_status = system.memory_create(pages)
	}
	if create_status != .Succeeded {
		return 0, .Quota_Full
	}
	rw_addr, map_status := system.memory_map(rw_handle, {.Write})
	if map_status != .Succeeded || rw_addr == nil {
		system.close(rw_handle)
		return 0, .Quota_Full
	}
	total_bytes := int(pages * object_cache.PAGE_SIZE)
	dst := ([^]u8)(rw_addr)[:total_bytes]
	if state.size > 0 {
		read_err: errors.Error_Record
		read_count, read_outcome := state_read(int(store_index), state, 0, dst[:state.size], &read_err, 1)
		if read_outcome != .Succeeded || u64(read_count) != state.size {
			intrinsics.mem_zero_volatile(rw_addr, total_bytes)
			system.memory_unmap(rw_addr)
			system.close(rw_handle)
			return 0, read_outcome == .Callee_Unavailable ? .Unavailable : .Damaged
		}
	}
	if total_bytes > int(state.size) {
		intrinsics.mem_zero(raw_data(dst[state.size:]), total_bytes - int(state.size))
	}
	actual_hash := state.size == 0 ? blake3.hash(nil) : blake3.hash(dst[:state.size])
	if actual_hash != expected_hash {
		intrinsics.mem_zero_volatile(rw_addr, total_bytes)
		system.memory_unmap(rw_addr)
		system.close(rw_handle)
		return 0, .Damaged
	}
	system.memory_unmap(rw_addr)

	// Clients receive Read-only handles derived from ro_handle, never from
	// rw_handle. rw_handle stays in private_wipe_handles for volatile-zeroing.
	ro_handle, ro_status := system.give(0, rw_handle, {.Give, .Read})
	for _ in 0 ..< object_cache.PRIVATE_CACHE_CAPACITY {
		if ro_status == .Succeeded && ro_handle != 0 {
			break
		}
		if !private_cache_evict_one(principal_id, .Same_Principal) && !private_cache_evict_one(principal_id, .Any_Private) {
			break
		}
		ro_handle, ro_status = system.give(0, rw_handle, {.Give, .Read})
	}
	if ro_status != .Succeeded || ro_handle == 0 {
		memory_handle_volatile_zero(rw_handle, pages)
		system.close(rw_handle)
		return 0, .Quota_Full
	}

	for _ in 0 ..= object_cache.PRIVATE_CACHE_CAPACITY {
		slot_index, insert_res := object_cache.insert_private(&storage_object_cache, principal_id, store_index, expected_hash, u64(ro_handle), state.size, pages)
		switch insert_res {
		case .Inserted:
			private_wipe_handles[slot_index] = rw_handle
			return ro_handle, .Mapped
		case .Already_Present:
			memory_handle_volatile_zero(rw_handle, pages)
			system.close(ro_handle)
			system.close(rw_handle)
			if existing, _, hit := object_cache.lookup_private(&storage_object_cache, principal_id, store_index, expected_hash); hit {
				return system.Handle(existing.memory_handle), .Mapped
			}
			return 0, .Quota_Full
		case .Quota_Exceeded, .Table_Full:
			if !private_cache_make_room(principal_id, pages) {
				memory_handle_volatile_zero(rw_handle, pages)
				system.close(ro_handle)
				system.close(rw_handle)
				return 0, .Quota_Full
			}
		case .Invalid_Argument:
			memory_handle_volatile_zero(rw_handle, pages)
			system.close(ro_handle)
			system.close(rw_handle)
			return 0, .Quota_Full
		}
	}
	memory_handle_volatile_zero(rw_handle, pages)
	system.close(ro_handle)
	system.close(rw_handle)
	return 0, .Quota_Full
}

// map_object resolves an exact '/' object path across the caller's granted
// read-only image-tree subtrees and private store (refusing ambiguity if more
// than one tree matches), enforces optional hash pinning, caches a copy-once
// read-only Memory object on first demand (in the Public_System pool for
// image-tree objects or the Private_Principal pool for disk objects), and
// grants the caller a Read-only handle returned as value.
//
// Image-tree calls work independently of the data disk lifecycle (even when
// the disk is absent, unusable, or silent).
@(export, link_name = "map_object")
map_object :: proc "c" (
	request: ^system.Bytes_To_Read,
	answer: ^system.Bytes_To_Append,
	ambiguity: ^system.Bytes_To_Append,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if request == nil || request.bytes == nil || request.count == 0 || request.count > u64(len(map_request_scratch)) {
		req_count := request != nil ? i64(request.count) : 0
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1, req_count, len(map_request_scratch)), 0
	}
	req_bytes := request.bytes[:request.count]
	// Copy request out of the shared call region once before validating.
	copy(map_request_scratch[:len(req_bytes)], req_bytes)
	req, req_problem := storage_object.map_object_request_decode(map_request_scratch[:len(req_bytes)])
	if req_problem != .None {
		if req_problem == .Invalid_Path && len(req_bytes) >= storage_object.MAP_OBJECT_REQUEST_HEADER_SIZE {
			path_bytes := map_request_scratch[storage_object.MAP_OBJECT_REQUEST_HEADER_SIZE:len(req_bytes)]
			_, p_problem, _, _ := format.object_path_validate(string(path_bytes))
			if p_problem != .None {
				return map_object_fail(answer, error, {result = .Path_Refused, path_problem = p_problem}, .Bytes, 1)
			}
		}
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1), 0
	}

	grants_buf: [CONNECTION_TREE_GRANT_LIMIT]image_tree.Subtree_Grant
	grants := caller_tree_grants(&caller, &grants_buf)
	has_store := caller.store.limit > 0

	if len(grants) == 0 && !has_store {
		return map_object_fail(answer, error, {result = .Not_Found}, .Objects, 1)
	}

	amb_cap := min(int(req.ambiguity_capacity), storage_object.AMBIGUITY_RECORD_LIMIT)

	image_resolved: image_tree.Resolved_Object
	image_match_count := 0
	image_problem := image_tree.Lookup_Problem.Not_Found
	image_path_problem := format.Object_Path_Problem.None
	if len(grants) > 0 {
		if !readiness.image_tree_ready {
			if !has_store {
				return map_object_fail(answer, error, {result = .Unavailable}, .Objects, 1)
			}
		} else {
			image_resolved, image_match_count, image_problem, image_path_problem = image_tree.lookup_in_grants(
				storage_image_tree,
				grants,
				req.path,
				req.has_expected_hash,
				req.expected_hash,
				ambiguity_matches_scratch[:amb_cap],
			)
			switch image_problem {
			case .Bad_Path:
				return map_object_fail(answer, error, {result = .Path_Refused, path_problem = image_path_problem}, .Bytes, 1)
			case .Manifest_Invalid, .Bad_Grant:
				return map_object_fail(answer, error, {result = .Damaged}, .Objects, 1)
			case .None, .Not_Found, .Is_Subtree, .Ambiguous, .Hash_Mismatch:
			}
		}
	}

	priv_store_index := -1
	priv_entry: Entry
	priv_status := Private_Lookup_Status.Not_Found
	if has_store {
		priv_store_index, priv_entry, priv_status = private_store_lookup(&caller, req.path)
		if priv_status == .Damaged {
			return map_object_fail(answer, error, {result = .Damaged}, .Stores, 1)
		}
	}

	image_matched := image_problem == .None || image_problem == .Hash_Mismatch
	image_total := image_problem == .Ambiguous ? image_match_count : (image_matched ? 1 : 0)
	priv_matched := priv_status == .Found
	total_matches := image_total + (priv_matched ? 1 : 0)

	if total_matches == 0 {
		if (len(grants) > 0 && !readiness.image_tree_ready) || (has_store && priv_status == .Unavailable) {
			return map_object_fail(answer, error, {result = .Unavailable}, .Objects, 1)
		}
		return map_object_fail(answer, error, {result = .Not_Found}, .Objects, 1)
	}

	if total_matches > 1 {
		// Combine image-tree matches and any private-store match into the
		// caller-supplied ambiguity table without choosing on the caller's behalf.
		entry_count := 0
		if image_problem == .Ambiguous {
			img_records := min(amb_cap, image_match_count)
			for i in 0 ..< img_records {
				m := ambiguity_matches_scratch[i]
				ambiguity_entries_scratch[entry_count] = {
					grant_index = u32(m.grant_index),
					tree_name   = m.tree_name,
					path        = req.path,
					size        = m.size,
					hash        = m.hash,
				}
				entry_count += 1
			}
		} else if image_matched && entry_count < amb_cap {
			tree_name := image_resolved.grant_index >= 0 && image_resolved.grant_index < len(grants) ? grants[image_resolved.grant_index].tree_name : ""
			ambiguity_entries_scratch[entry_count] = {
				grant_index = u32(max(image_resolved.grant_index, 0)),
				tree_name   = tree_name,
				path        = req.path,
				size        = image_resolved.size,
				hash        = image_resolved.hash,
			}
			entry_count += 1
		}
		if priv_matched && entry_count < amb_cap {
			ambiguity_entries_scratch[entry_count] = {
				grant_index = u32(len(grants)),
				tree_name   = caller.store.name,
				path        = req.path,
				size        = priv_entry.size,
				hash        = blake3.Hash(priv_entry.hash),
			}
			entry_count += 1
		}
		amb_rem := min(append_remaining(ambiguity), len(ambiguity_wire_scratch))
		if amb_rem >= storage_object.AMBIGUITY_TABLE_HEADER_SIZE {
			// Fit only as many ambiguity entries as the caller's remaining
			// append buffer holds while keeping total_matches accurate so the
			// encoded table never truncates on bytes_append.
			running_bytes := storage_object.AMBIGUITY_TABLE_HEADER_SIZE
			fit_count := 0
			for i in 0 ..< entry_count {
				e := ambiguity_entries_scratch[i]
				entry_bytes := storage_object.AMBIGUITY_ENTRY_HEADER_SIZE + len(e.tree_name) + len(e.path)
				if running_bytes + entry_bytes > amb_rem {
					break
				}
				running_bytes += entry_bytes
				fit_count += 1
			}
			amb_written, amb_problem := storage_object.ambiguity_table_encode(
				u32(total_matches),
				ambiguity_entries_scratch[:fit_count],
				ambiguity_wire_scratch[:amb_rem],
			)
			if amb_problem == .None && amb_written > 0 {
				_ = system.bytes_append(ambiguity, ambiguity_wire_scratch[:amb_written])
			}
		}
		return map_object_fail(answer, error, {result = .Ambiguous, ambiguity_total = u32(total_matches)}, .Objects, 1, i64(total_matches))
	}

	// Single exact match: either image tree or private disk store.
	if image_matched {
		if image_problem == .Hash_Mismatch {
			return map_object_fail(answer, error, {
				result = .Hash_Mismatch,
				size   = image_resolved.size,
				hash   = image_resolved.hash,
			}, .Objects, 1)
		}
		// Verify answer buffer capacity BEFORE granting any kernel handle so a
		// too-small answer buffer never leaks a granted handle.
		ans_rem := append_remaining(answer)
		if ans_rem < storage_object.MAP_OBJECT_ANSWER_SIZE {
			return refuse(error, .Argument_Refused, .Too_Small, .Bytes, 2, i64(ans_rem), storage_object.MAP_OBJECT_ANSWER_SIZE), 0
		}
		ro_handle, cache_result := image_object_cached_handle(image_resolved)
		if cache_result != .Mapped {
			unit := cache_result == .Quota_Full ? errors.Unit.Pages : errors.Unit.Objects
			return map_object_fail(answer, error, {result = cache_result}, unit, 1)
		}
		given, give_status := system.give(caller.connection.ring_memory, ro_handle, {.Read})
		if give_status != .Succeeded || given == 0 {
			return map_object_fail(answer, error, {result = .Quota_Full}, .Pages, 1)
		}
		map_object_answer_write(answer, {
			result = .Mapped,
			size   = image_resolved.size,
			hash   = image_resolved.hash,
		})
		return .Succeeded, i64(given)
	}

	// Private disk-store match.
	priv_hash := blake3.Hash(priv_entry.hash)
	if req.has_expected_hash && priv_hash != req.expected_hash {
		return map_object_fail(answer, error, {
			result = .Hash_Mismatch,
			size   = priv_entry.size,
			hash   = priv_hash,
		}, .Objects, 1)
	}
	ans_rem := append_remaining(answer)
	if ans_rem < storage_object.MAP_OBJECT_ANSWER_SIZE {
		return refuse(error, .Argument_Refused, .Too_Small, .Bytes, 2, i64(ans_rem), storage_object.MAP_OBJECT_ANSWER_SIZE), 0
	}
	// Tag private cached plaintext with the store's owning principal (falling
	// back to caller.principal only for machine-owned stores) so share-mapped
	// plaintext of a named principal is always purged on Principal_Locked and
	// Principal_Reclaim.
	store_principal := owned_slot(caller.store.name)
	if store_principal == 0 {
		store_principal = caller.principal
	}
	ro_handle, cache_result := private_object_cached_handle(store_principal, u32(priv_store_index), current_state(&priv_entry), priv_hash)
	if cache_result != .Mapped {
		unit := cache_result == .Quota_Full ? errors.Unit.Pages : errors.Unit.Objects
		return map_object_fail(answer, error, {result = cache_result}, unit, 1)
	}
	given, give_status := system.give(caller.connection.ring_memory, ro_handle, {.Read})
	if give_status != .Succeeded || given == 0 {
		return map_object_fail(answer, error, {result = .Quota_Full}, .Pages, 1)
	}
	map_object_answer_write(answer, {
		result = .Mapped,
		size   = priv_entry.size,
		hash   = priv_hash,
	})
	return .Succeeded, i64(given)
}

// pin_store_authorized checks whether caller may add or remove a durable pin
// on store_index: caller's own store, or (with Acts_For_Principal) a store
// belonging to caller's principal.
@(private = "file")
pin_store_authorized :: proc "contextless" (caller: ^Caller, store_index: u32) -> bool {
	own_index := store_find(caller.store.name)
	if own_index >= 0 && u32(own_index) == store_index {
		return true
	}
	if !caller.acts_for_principal {
		return false
	}
	idx := int(store_index)
	if idx < 0 || idx >= store_numbers() || !store_listed(idx) {
		return false
	}
	if caller.principal == 0 {
		return !format.cell_uses_encrypted_layout(store_cell(idx).name)
	}
	if !owned_cell(idx) {
		return false
	}
	keys := principal_keys_held(caller.principal)
	if keys == nil {
		return false
	}
	sb: format.Store_Block
	if read_single_tagged(store_cell(idx).store, (^Block)(&sb), idx, 0) != .Good {
		return false
	}
	return sb.owner == keys.identifier
}

// pin_object records one durable pin on (store_index, hash) for the caller's
// principal so collect_garbage and erase_versions cannot reclaim it.
@(export, link_name = "pin_object")
pin_object :: proc "c" (request: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || caller.read_only || share_of(caller.connection) != nil || caller.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if request == nil || request.bytes == nil || request.count != storage_object.PIN_REQUEST_SIZE {
		req_count := request != nil ? i64(request.count) : 0
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1, req_count, storage_object.PIN_REQUEST_SIZE), 0
	}
	req_bytes := request.bytes[:request.count]
	copied: [storage_object.PIN_REQUEST_SIZE]u8
	copy(copied[:], req_bytes)
	req, problem := storage_object.pin_request_decode(copied[:])
	if problem != .None {
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1), 0
	}
	if !pin_store_authorized(&caller, req.store_index) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 1)
	}
	new_count, pin_res := object_cache.pin_add(&storage_object_pins, caller.principal, req.store_index, req.hash)
	switch pin_res {
	case .Ok:
		return .Succeeded, i64(new_count)
	case .Quota_Exceeded, .Table_Full, .Count_Limit:
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 1), 0
	case .Not_Found:
		return refuse(error, .Nothing_Has_That_Name, .Absent, .Objects, 1), 0
	case .Invalid_Argument:
		return refuse(error, .Argument_Refused, .Bad_Value, .Objects, 1), 0
	}
	return refuse(error, .Argument_Refused, .Bad_Value, .Objects, 1), 0
}

// unpin_object decrements one durable pin on (store_index, hash) for the
// caller's principal, freeing the entry when its count reaches zero.
@(export, link_name = "unpin_object")
unpin_object :: proc "c" (request: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || caller.read_only || share_of(caller.connection) != nil || caller.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if request == nil || request.bytes == nil || request.count != storage_object.UNPIN_REQUEST_SIZE {
		req_count := request != nil ? i64(request.count) : 0
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1, req_count, storage_object.UNPIN_REQUEST_SIZE), 0
	}
	req_bytes := request.bytes[:request.count]
	copied: [storage_object.UNPIN_REQUEST_SIZE]u8
	copy(copied[:], req_bytes)
	req, problem := storage_object.unpin_request_decode(copied[:])
	if problem != .None {
		return refuse(error, .Argument_Refused, .Bad_Value, .Bytes, 1), 0
	}
	if !pin_store_authorized(&caller, req.store_index) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 1)
	}
	remaining, pin_res := object_cache.pin_remove(&storage_object_pins, caller.principal, req.store_index, req.hash)
	switch pin_res {
	case .Ok:
		return .Succeeded, i64(remaining)
	case .Not_Found:
		return refuse(error, .Nothing_Has_That_Name, .Absent, .Objects, 1), 0
	case .Quota_Exceeded, .Table_Full, .Count_Limit:
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 1), 0
	case .Invalid_Argument:
		return refuse(error, .Argument_Refused, .Bad_Value, .Objects, 1), 0
	}
	return refuse(error, .Argument_Refused, .Bad_Value, .Objects, 1), 0
}

// list_pins writes a canonical List_Pins_Answer scoped strictly to the caller's
// principal (and to the caller's own store when !acts_for_principal), bounding
// encoded records to the caller's remaining append buffer capacity while
// returning the true total count of matching durable pins.
@(export, link_name = "list_pins")
list_pins :: proc "c" (answer: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || share_of(caller.connection) != nil || (caller.store.limit == 0 && !caller.acts_for_principal) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	ans_rem := min(append_remaining(answer), len(list_pins_wire_scratch))
	if ans_rem < storage_object.LIST_PINS_HEADER_SIZE {
		return refuse(error, .Argument_Refused, .Too_Small, .Bytes, 1, i64(ans_rem), storage_object.LIST_PINS_HEADER_SIZE), 0
	}
	max_fit := min(storage_object.LIST_PINS_LIMIT, (ans_rem - storage_object.LIST_PINS_HEADER_SIZE) / storage_object.PIN_RECORD_SIZE)

	written := 0
	total := 0
	if caller.acts_for_principal {
		// Always filter to caller.principal (including principal 0): a caller
		// acting for one principal never sees durable pins of another principal.
		written, total = object_cache.pins_list_scoped(&storage_object_pins, caller.principal, false, 0, list_pins_info_scratch[:max_fit])
	} else {
		// Without Acts_For_Principal, restrict strictly to the caller's own store.
		own_index := disk_opened ? store_find(caller.store.name) : -1
		if own_index >= 0 {
			written, total = object_cache.pins_list_scoped(&storage_object_pins, caller.principal, true, u32(own_index), list_pins_info_scratch[:max_fit])
		}
	}
	for i in 0 ..< written {
		info_row := list_pins_info_scratch[i]
		list_pins_records_scratch[i] = {
			principal_id = info_row.principal_id,
			store_index  = info_row.store_index,
			pin_count    = info_row.pin_count,
			hash         = info_row.hash,
		}
	}
	encoded_len, enc_problem := storage_object.list_pins_answer_encode(u32(total), list_pins_records_scratch[:written], list_pins_wire_scratch[:ans_rem])
	if enc_problem != .None {
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Records), 0
	}
	_ = system.bytes_append(answer, list_pins_wire_scratch[:encoded_len])
	return .Succeeded, i64(total)
}
