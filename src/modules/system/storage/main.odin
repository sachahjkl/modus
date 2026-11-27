// The storage service: it keeps the store of each process on the data disk, through a block service: a tree of entries, each an object or a tree inside it (docs/STORAGE.md). No process sees a shared tree of names.
//
// The root service decides who has a store: it names the store of each connection, and its limit of blocks. A connection reaches the tree of its store and what is under it: each export takes a place (0 is the root of the connection) and a name of one step under it, never a path, and never the name of a store. A connection that [share](storage.share) makes reaches a tree of the store of its maker only, and **can read only**; [unshare](storage.unshare) revokes it.
//
// **A change is one commit**, on the disk when the call returns: the system has no save action. The state of an object before a change is a version: a process reads, compares, restores and clones versions with no code of its own, and [erase_versions](storage.erase_versions) ends them and writes zeros over their blocks. The disk always has the state of the last commit, or of the one before: a stop of the machine during a commit never shows a part of it. The checks of the blocks show each change that the service did not make.
//
// A process that acts for a principal (the console, remote for the host) sees the stores of that principal with [stores](storage.stores), and opens a place on one of them with [open_store](storage.open_store).
//
// **Grants**, as the root service gives them:
//
// - **Serve**: each process with the grant **Store** reaches its private store through a connection.
// - **Data_Disk**: the block service of the data disk, with the right Read, and its block ring. The storage service is
//   the one client of that disk: no other process reads its blocks.
//
// **Start**: no line starts it. The root service starts it when a process asks for a connection to `storage`, or
// before a process with a private store. From the console: `connect("storage")`, then for example
// `storage.write(0, "greeting", "kept on the disk")` and `storage.read(0, "greeting")`.
//
// **What it proves**: a process keeps its state across a stop of the machine with no file system, no path and no
// save action, and it reaches no store but its own. Stores of named principals are encrypted under keys derived
// from the unlock key of the principal and authenticated on every block read; stores of principal 0 stay in clear.
//
// The design: `docs/STORAGE.md`; the large objects: [read_range](storage.read_range) and the exports after it.
package storage_service

import "modus:contract/block"
import "modus:contract/date"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "internal:storage/service_state"
import "internal:storage/share_quota"
import "internal:storage/storage_retention"
import format "modus:contract/store"
import answers "modus:storage"
import "base:intrinsics"
import block_tree "internal:storage/storage_object"
import tree "internal:storage/storage_tree"
import "modus:random"
import "modus:system"

// The pages of the tables of the blocks for a disk of 16 GiB (below).
STATE_PAGES_OF_16_GIB :: 10704

// Its fixed tables are data of its module, so the tool counts them with the
// module. The block transfer region (REGION_BLOCKS) and the tables of the
// blocks for a disk of 16 GiB (STATE_PAGES_OF_16_GIB, which exceeds the
// largest count-tree cache of 8 326 pages used for larger disks;
// src/md/data/storage_capacity.md) are created before ready.
MODULE_START_OBJECTS :: [?]system.Start_Object{REGION_BLOCKS, STATE_PAGES_OF_16_GIB}
// On the machine of the machine tests (50 000 pages per process), the start
// objects and the fixed static tables of the module (under 10 240 pages, 40
// MiB) stay below the largest budget so no test boot writes Budget_Part_Limited.
// On the smallest machine (16 384 pages), the static tables and transfer
// region leave memory for storage_mount.open_with_forms, which halves its
// disk tables and count-tree cache when the budget refuses.
STORAGE_MODULE_PAGES_BOUND :: 10240
#assert(REGION_BLOCKS + STATE_PAGES_OF_16_GIB + STORAGE_MODULE_PAGES_BOUND <= module.TEST_MACHINE_LARGEST_BUDGET_PAGES)
#assert(REGION_BLOCKS + STORAGE_MODULE_PAGES_BOUND <= module.LARGEST_BUDGET_LEAST_PAGES)

// refuse writes the error record of a refusal and gives its call outcome:
// the last result of a procedure of this service that gives the outcome of
// its step, and no value (src/md/api/call_outcome.md).
refuse :: proc "contextless" (error: ^errors.Error_Record, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> call_outcome.Call_Outcome {
	if error != nil {
		error^ = errors.error_make(kind, unit, argument, value, limit, found)
	}
	return outcome
}

// ---------------------------------------------------------------------
// Connections, places and shares.

PLACE_CAPACITY :: 512 // The places of all the connections.
SHARE_CAPACITY :: 16 // The connections that the service made with share.

// A place: a tree of a store, by the names of its path from the root of
// the store, held by one connection. The store is the store of the
// connection, or another store that open_store opened for a caller that may
// name it.
Place :: struct {
	holder:     system.Handle, // The call ring of the connection that holds it. 0: free.
	generation: u32, // Changes at each free: an old number of the place names nothing.
	store:      system.Name, // The name of its store.
	depth:      int,
	path:       [NESTING_LIMIT]Entry_Name,
}
places: [PLACE_CAPACITY]Place

// A connection that the service made for the caller of share: its root is
// a tree of the store of its maker.
Share :: struct {
	connection:  system.Connection, // calls.head nil: the place is free.
	maker:       system.Handle, // The call ring of the connection that made it.
	read_only:   bool,
	depth:       int,
	path:        [NESTING_LIMIT]Entry_Name,
	block_limit: u64, // 0: inherits store limit; >0: per-share block quota.
}
shares: [SHARE_CAPACITY]Share

// The caller of the export that runs.
Caller :: struct {
	connection: ^system.Connection,
	store:      Store_Of,
	acts_for_principal: bool, // The root service granted it to act for its principal.
	principal:  u64, // The principal of the session of the caller (isolated.caller_principal).
	read_only:  bool,
	erases_versions: bool, // The root service gave it the grant Versions_Erase (isolated.CALLER_ERASES_VERSIONS).
	recounts:   bool, // The root service gave it the grant Recount (isolated.CALLER_RECOUNTS).
	depth:      int,
	path:       [NESTING_LIMIT]Entry_Name, // The root of the connection.
}

share_of :: proc "contextless" (connection: ^system.Connection) -> ^Share {
	for &item in shares {
		if item.connection.calls.head != nil && &item.connection == connection {
			return &item
		}
	}
	return nil
}

// connection_store gives the store and the limit that a connection
// reaches: the grant of the root service, or the store of the maker of a
// share, while the maker has its grant.
connection_store :: proc "contextless" (ring_memory: system.Handle, steps: int) -> (store: Store_Of, root_service: bool, found: bool) {
	if steps > SHARE_CAPACITY || ring_memory == 0 {
		return {}, false, false
	}
	for &connection in service.connections {
		if connection.calls.head != nil && connection.ring_memory == ring_memory {
			return {name = system.name_of(connection.caller[:]), limit = connection.grant & isolated.CALLER_AMOUNT_MASK}, true, true
		}
	}
	for &item in shares {
		if item.connection.calls.head != nil && item.connection.ring_memory == ring_memory {
			store, _, found = connection_store(item.maker, steps + 1)
			return store, false, found
		}
	}
	return {}, false, false
}

// caller_of fills caller with the caller of the export that runs. A share
// whose maker lost its grant, or left, ends here. Written through a pointer
// so Caller (over 8 KiB) is never copied or scalarized by value.
caller_of :: proc "contextless" (caller: ^Caller) {
	caller.connection = nil
	caller.store = {}
	caller.acts_for_principal = false
	caller.principal = 0
	caller.read_only = false
	caller.erases_versions = false
	caller.recounts = false
	caller.depth = 0
	connection := system.service_caller()
	if connection == nil {
		return
	}
	caller.connection = connection
	item := share_of(connection)
	if item == nil {
		caller.store = {name = system.name_of(connection.caller[:]), limit = connection.grant & isolated.CALLER_AMOUNT_MASK}
		caller.acts_for_principal = connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
		caller.principal = isolated.caller_principal(connection.grant)
		// The root service gives a connection that reads only, for the
		// debug object of a disk process: each change is refused on it, as
		// on a share that reads only.
		caller.read_only = connection.grant & isolated.CALLER_READS_ONLY != 0
		// A share never has it: the field stays false below.
		caller.erases_versions = connection.grant & isolated.CALLER_ERASES_VERSIONS != 0
		caller.recounts = connection.grant & isolated.CALLER_RECOUNTS != 0
		return
	}
	store, _, found := connection_store(item.maker, 0)
	if !found || store.limit == 0 {
		share_end(item)
		caller.connection = nil
		return
	}
	caller.store = {name = store.name, limit = store.limit, share_limit = item.block_limit}
	caller.principal = owned_slot(store.name)
	caller.read_only = item.read_only
	caller.depth = item.depth
	copy(caller.path[:item.depth], item.path[:item.depth])
}

// reaches_whole_store says if the root of the connection of a caller is the
// root of its store: the connection of the process of the store, or a
// share of the whole store. Only such a caller finds an object by its hash
// (docs/STORAGE.md, "4.7 The same object one time"): a share of one tree
// must not learn from its count of blocks what the rest of the store holds.
reaches_whole_store :: proc "contextless" (caller: ^Caller) -> bool {
	return caller.depth == 0
}

// writable_tree_share_open says if a store has a share open that can write
// and whose root is a tree inside the store, not its root. While it is
// open, no commit of the store looks up a hash, and a new root of the
// store is never a candidate: its holder writes bytes and reads the count
// of blocks of the whole store, so either way it would learn what bytes the
// rest of the store holds (docs/STORAGE.md, "4.7 The same object one
// time").
writable_tree_share_open :: proc "contextless" (store_name: string) -> bool {
	for &item in shares {
		if item.connection.calls.head == nil || item.read_only || item.depth == 0 {
			continue
		}
		if store, _, found := connection_store(item.maker, 0); found && store.name == store_name {
			return true
		}
	}
	return false
}

// A path of a call: the store and the root of a place, and one more name.
Path :: struct {
	store: Store_Of,
	own:   bool, // The store of the connection: the only store that write, add, remove, rename and share change.
	names: [NESTING_LIMIT + 1]Entry_Name,
	depth: int,
}

path_names :: proc "contextless" (path: ^Path) -> []Entry_Name {
	return path.names[:path.depth]
}

// place_path fills path with the path of a place of the caller. It refuses
// a number that is not a place of this connection. Written through a
// pointer so Path (over 8 KiB) is never returned by value.
place_path :: proc "contextless" (caller: ^Caller, place: i64, path: ^Path, error: ^errors.Error_Record, argument: i64) -> bool {
	path.store = {}
	path.own = false
	path.depth = 0
	if place == 0 {
		path.store = caller.store
		path.own = true
		path.depth = caller.depth
		copy(path.names[:], caller.path[:caller.depth])
		return true
	}
	index := int(place & 0xFFFF_FFFF) - 1
	generation := u32(u64(place) >> 32)
	if place < 0 || index < 0 || index >= PLACE_CAPACITY || places[index].holder == 0 || places[index].holder != caller.connection.ring_memory || places[index].generation != generation {
		refuse(error, .Argument_Refused, .Absent, .Places, argument, place)
		return false
	}
	item := &places[index]
	name := system.name_of(item.store[:])
	path.own = name == caller.store.name
	if path.own {
		path.store = caller.store
	} else {
		// Another store: its limit is the one of its last grant.
		store_index := store_find(name)
		if store_index < 0 {
			refuse(error, .Argument_Refused, .Absent, .Places, argument, place)
			return false
		}
		path.store = {name = name, limit = store_cell(store_index).limit}
	}
	path.depth = item.depth
	copy(path.names[:], item.path[:path.depth])
	return true
}

// may_name_store says if a caller may open a place on a store that is not
// the store of its connection, and if stores() shows it to the caller: the
// one rule of the service for it (docs/STORAGE.md, "No way up"). A caller
// that acts for principal N names the stores of principal N only: the
// principal of a store is in its name (principals.store_name_principal).
// Principal 0, the machine, names no store of a named principal. A caller
// that does not act for a principal names its own store only. A share names
// no store: its root is a tree that its maker chose, and a place on the
// root of its own store would reach, and change, the whole store.
may_name_store :: proc "contextless" (caller: ^Caller, store_name: string) -> bool {
	return service_state.caller_may_name_store(
		caller.connection != nil,
		caller.connection != nil && share_of(caller.connection) != nil,
		caller.acts_for_principal,
		caller.principal,
		caller.store.name,
		caller.store.limit,
		store_name,
	)
}

// connection_ended frees what the service keeps for a connection that
// ends: any shares whose maker (directly or transitively) was this connection,
// its read-only tree grants, its pending changes and their memory, and its
// places. A later connection whose ring has the same handle starts with none
// of them.
connection_ended :: proc "contextless" (_: ^system.Service, connection: ^system.Connection) {
	holder := connection.ring_memory
	ended_handles: [SHARE_CAPACITY + 1]system.Handle
	ended_handles[0] = holder
	ended_count := 1
	for pass := 0; pass < ended_count; pass += 1 {
		dead := ended_handles[pass]
		for &item in shares {
			if item.connection.calls.head != nil && item.maker == dead {
				share_ring := item.connection.ring_memory
				share_end(&item)
				if ended_count < len(ended_handles) {
					ended_handles[ended_count] = share_ring
					ended_count += 1
				}
			}
		}
	}
	connection_tree_grants_clear(holder)
	pending_drop_of(holder)
	for &item in places {
		if item.holder == holder {
			item.holder = 0
			item.generation += 1
		}
	}
}

// places_sweep frees the places of connections that ended.
places_sweep :: proc "contextless" () {
	for &item in places {
		if item.holder == 0 {
			continue
		}
		_, _, found := connection_store(item.holder, 0)
		if !found {
			item.holder = 0
			item.generation += 1
		}
	}
}

place_new :: proc "contextless" (caller: ^Caller, path: ^Path) -> (place: i64, ok: bool) {
	for attempt in 0 ..< 2 {
		for &item, index in places {
			if item.holder != 0 {
				continue
			}
			item.holder = caller.connection.ring_memory
			item.store = system.name_unpack(system.name_pack(path.store.name))
			item.depth = path.depth
			copy(item.path[:], path.names[:path.depth])
			return i64(index + 1) | i64(item.generation) << 32, true
		}
		if attempt == 0 {
			places_sweep()
		}
	}
	return 0, false
}

// The refusals that each export of a change makes first.
change_refusal :: proc "contextless" (caller: ^Caller, error: ^errors.Error_Record) -> (refused: bool, result: call_outcome.Call_Outcome) {
	if unopened, refusal := disk_unopened_refusal(error); unopened {
		return true, refusal
	}
	if caller.connection == nil || caller.store.limit == 0 {
		return true, refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if caller.read_only {
		return true, refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Changes)
	}
	return false, .Succeeded
}

// The beginning of each export with a place and a name: the caller, the
// path of the place, the name kept.
Named :: struct {
	caller: Caller,
	path:   Path,
	name:   Kept_Name,
}

named_of :: proc "contextless" (place: i64, name: string, named: ^Named, error: ^errors.Error_Record, place_argument: i64, change: bool) -> call_outcome.Call_Outcome {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal
	}
	caller_of(&named.caller)
	if change {
		if refused, refusal := change_refusal(&named.caller, error); refused {
			return refusal
		}
	} else if named.caller.connection == nil {
		return refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if !place_path(&named.caller, place, &named.path, error, place_argument) {
		return .Argument_Refused
	}
	group_flush_if_conflict(named.path.store.name)
	if named.path.own && named.path.store.limit == 0 {
		return refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	if change && !named.path.own {
		return refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Store, place_argument)
	}
	ok: bool
	if named.name, ok = name_keep(name, error, place_argument + 1); !ok {
		return .Argument_Refused
	}
	return .Succeeded
}

// ---------------------------------------------------------------------
// The exports of objects.

// write makes the object `name` under a place the bytes of data, in one commit on the disk: a cut or an extension to the size of data, and a change of each of its blocks, as a commit of ranges does; a block that keeps its bytes keeps its block. A new name is a new object. The state before becomes a version. At the limit of the store, the oldest versions of the store are thinned in the same commit. The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, the caller has no store; Grant_Or_Right_Missing, unit Changes, the connection reads only);
// - `Absent` (Argument_Refused, unit Places: the place is not a place of this connection; Nothing_Has_That_Name, unit Places: its tree was removed or renamed; Nothing_Has_That_Name, unit Objects: the name is a tree);
// - `Over_Limit` (Budget_Or_Capacity_Exhausted, the current objects with the change need more blocks than the limit, with no earlier version kept);
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, the name has 1 to 255 bytes, no zero byte, no byte '/', and is not "." or "..");
// - `Too_Long` (Argument_Refused, the data has more bytes than the call region holds: write a larger object by ranges);
// - `Full` (Budget_Or_Capacity_Exhausted, no place for one more store, or no free block; with the unit Commit_Blocks, the commit changes more blocks than one commit can);
// - `Device` (Callee_Unavailable; unit Dropped_Writes: the read back after the commit found blocks with other bytes, found their count: the disk did not keep the commit, and the object keeps its state before);
// - `Damaged` (Data_Damaged, unit Stores: a node of a tree of the store has a wrong check; unit Counts: the counts of the store are not trusted after a fault of the service).
@(export, link_name = "write")
write :: proc "c" (place: i64, name: ^string, data: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, true); refused != .Succeeded {
		return refused, 0
	}
	value, outcome = object_change(named.caller.store, path_names(&named.path), named.name, .Write, transmute([]u8)data^, {}, reaches_whole_store(&named.caller), error, 2)
	return
}

// read gives the bytes of the object `name` under a place: the range from 0 to its end, as read_range gives it, with the pending changes of this connection. The result is the count of bytes; the size when they do not fit in the result; or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant`;
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: the place; Nothing_Has_That_Name: the tree has no such object);
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, the name);
// - `Device`;
// - `Damaged` (Data_Damaged: a block of the object or a node of a tree of the store has a wrong check: the service does not give its bytes).
@(export, link_name = "read")
read_export :: proc "c" (place: i64, name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, false); refused != .Succeeded {
		return refused, 0
	}
	size := ranged_size(&ranged)
	if size > u64(len(result)) {
		return .Succeeded, i64(size) // A text that does not fit: the caller sees it.
	}
	value, outcome = ranged_read(&ranged, 0, result^[:size], error)
	return
}

// size gives the count of bytes of the object `name` under a place, with the pending changes of this connection, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of [read](storage.read), but `Device` and `Damaged` for a block of the object: size reads the tree only.
@(export, link_name = "size")
size :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ranged: Ranged
	if refused := ranged_of(place, name^, &ranged, error, false); refused != .Succeeded {
		return refused, 0
	}
	return .Succeeded, i64(ranged_size(&ranged))
}

// remove removes the entry `name` under a place, in one commit: an object with all its versions, or a tree with all that is under it. The name is gone at the commit; the blocks of a tree are freed after it, in steps of 64 entries, one commit each, while no call waits (usage gives the trees that wait). The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of [write](storage.write), and `Absent` (Nothing_Has_That_Name, the tree has no entry with this name).
@(export, link_name = "remove")
remove :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, true); refused != .Succeeded {
		return refused, 0
	}
	value, outcome = entry_remove(named.caller.store, path_names(&named.path), named.name, error)
	return
}

// One entry that add makes: its name, as an offset and a count of bytes in the argument names, and its kind (1: an empty object, 2: an empty tree).
Add_Row_Export :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}
#assert(size_of(Add_Row_Export) == size_of(Add_Row))

// add makes up to 256 entries under a place in one commit, each an empty object or an empty tree: all of them, or none. The names are bytes of the argument names, each named by a row. The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of [write](storage.write);
// - `Too_Long` (Argument_Refused, more than 256 rows);
// - `Bad_Value` (Argument_Refused, a kind that is not 1 or 2);
// - `Out_Of_Range` (Argument_Refused, a row names bytes past the names);
// - `Exists` (Name_Already_Taken, a name exists, or two rows have one name: found is the row).
@(export, link_name = "add")
add :: proc "c" (place: i64, rows: ^system.Table_To_Read(Add_Row_Export), names: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller: Caller
	caller_of(&caller)
	if refused, result := change_refusal(&caller, error); refused {
		return result, 0
	}
	path: Path
	if !place_path(&caller, place, &path, error, 1) {
		return .Argument_Refused, 0
	}
	group_flush_if_conflict(path.store.name)
	if !path.own {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 1)
	}
	records := system.table_records(rows)
	given := ([^]Add_Row)(raw_data(records))[:len(records)]
	value, outcome = entries_add(path.store, path_names(&path), given, names.bytes[:names.count], error)
	return
}

// open gives the place of the tree `name` under a place: a number for the calls of this connection only. The tree and what is under it are what the place reaches; no name under it reaches above it.
//
// **Error kinds**
//
// - `No_Grant`;
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: the place; Nothing_Has_That_Name, unit Trees: no tree has this name);
// - the errors of a name (Argument_Refused);
// - `Too_Long` (Argument_Refused, unit Trees: the place would be more than 32 trees deep);
// - `Full` (Budget_Or_Capacity_Exhausted, unit Places: no free place);
// - `Damaged`;
// - `Device`.
@(export, link_name = "open")
open :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	if named.path.depth >= NESTING_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Trees, 1, NESTING_LIMIT + 1, NESTING_LIMIT)
	}
	store_index := store_find(named.path.store.name)
	if store_index < 0 {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Trees, 2)
	}
	if store_damaged[store_index] {
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
	}
	entry, lookup := entry_of(store_index, path_names(&named.path), named.name.key)
	if lookup == .Device || lookup == .Wrong {
		return lookup_refusal(lookup, error, 2), 0
	}
	if lookup != .Found || entry.kind != u64(format.Entry_Kind.Tree) {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Trees, 2)
	}
	named.path.names[named.path.depth] = named.name.key
	named.path.depth += 1
	opened_place, ok := place_new(&named.caller, &named.path)
	if !ok {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Places, 0, 0, PLACE_CAPACITY)
	}
	return .Succeeded, opened_place
}

// close frees a place of this connection. The result is 0, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `Absent` (Argument_Refused, unit Places).
@(export, link_name = "close")
close :: proc "c" (place: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || place == 0 {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Places, 1, place)
	}
	ignored: Path
	if !place_path(&caller, place, &ignored, error, 1) {
		return .Argument_Refused, 0
	}
	item := &places[int(place & 0xFFFF_FFFF) - 1]
	item.holder = 0
	item.generation += 1
	return .Succeeded, 0
}

// One entry of list: its name, as an offset and a count of bytes in the argument names; its kind (1 an object, 2 a tree); its size (the bytes of an object, the entries of a tree); the generation of its last change.
Listed :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
	size:        i64,
	generation:  i64,
}

// list gives a page of the entries of the tree of a place, in the order of the bytes of their names, from the first name after `after` (from the first entry when it is empty): as many as the rows and the names hold. A tree of any size is read in pages; the next page starts after the last name of this one. The result is the count of the rows of the page (0: no more entries), or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant`;
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: the place);
// - `Too_Long` or `Bad_Byte` (Argument_Refused, after);
// - `Damaged`;
// - `Device`.
@(export, link_name = "list")
list :: proc "c" (place: i64, after: ^string, rows: ^system.Table_To_Append(Listed), names: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, result := disk_unopened_refusal(error); refused {
		return result, 0
	}
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || caller.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	path: Path
	if !place_path(&caller, place, &path, error, 1) {
		return .Argument_Refused, 0
	}
	cursor: Entry_Name
	from_after := len(after^) != 0
	if from_after {
		kept, kept_ok := name_keep(after^, error, 2)
		if !kept_ok {
			return .Argument_Refused, 0
		}
		cursor = kept.key
	}
	store_index := store_find(path.store.name)
	if store_index < 0 {
		return .Succeeded, 0 // A store with no commit has no entry.
	}
	if store_damaged[store_index] {
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
	}
	scope, crypto_read := store_crypto_enter(store_index)
	if crypto_read != .Good {
		if crypto_read == .Device {
			return call_outcome.fail(error, .Callee_Unavailable, .Device)
		}
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
	}
	defer store_crypto_leave(&scope)
	root_node, lookup := tree_of(store_index, path_names(&path))
	if lookup != .Found {
		if lookup == .Absent {
			return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Places, 1)
		}
		return lookup_refusal(lookup, error, 1), 0
	}
	work := tree.Work{pool = &reading_pool, source = &node_source, shape = tree.TREE_SHAPE, root = root_node}
	initial_rows := rows.count
	initial_names := names.count
	written: i64
	for rows.count < rows.capacity {
		key: Entry_Name
		value: Entry
		if !tree.first_from(&work, cursor[:], from_after, key[:], entry_bytes(&value)) {
			if reading_pool.failure != .None {
				// Restore counts so the client does not receive partial rows on refusal.
				rows.count = initial_rows
				names.count = initial_names
				return lookup_refusal(reading_outcome(store_index), error, 1), 0
			}
			break
		}
		name := format.name_of(&key)
		if names.count + u64(len(name)) > names.capacity {
			break // The names hold no more: the next page starts here.
		}
		offset := system.bytes_append(names, transmute([]u8)name)
		system.table_append(rows, Listed{name_offset = i64(offset), name_count = i64(len(name)), kind = i64(value.kind), size = i64(value.size), generation = i64(value.generation)})
		written += 1
		cursor = key
		from_after = true
	}
	return .Succeeded, written
}

// rename moves the entry `name` under a place to the name `to_name` under the place `to_place`, in one commit: an object with its versions, or a tree with all under it. Both places are of this connection, so of one store. The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of [write](storage.write);
// - `Absent` (Nothing_Has_That_Name, no entry `name`);
// - `Exists` (Name_Already_Taken, `to_name` exists);
// - `Bad_Value` (Argument_Refused, unit Trees: `to_place` is inside the tree that moves).
@(export, link_name = "rename")
rename :: proc "c" (place: i64, name: ^string, to_place: i64, to_name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, true); refused != .Succeeded {
		return refused, 0
	}
	to_path: Path
	if !place_path(&named.caller, to_place, &to_path, error, 3) {
		return .Argument_Refused, 0
	}
	if !to_path.own {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 3)
	}
	to, to_ok := name_keep(to_name^, error, 4)
	if !to_ok {
		return .Argument_Refused, 0
	}
	value, outcome = entry_rename(named.caller.store, path_names(&named.path), named.name, path_names(&to_path), to, error)
	return
}

// The two handles of a share, as the caller names them, and the number of the share for unshare.
Shared :: struct {
	share:  i64,
	ring:   i64, // Memory: the call ring.
	region: i64, // Memory: the call region.
}

// share makes a new connection to this service whose root is the tree of a place, and gives its call ring and its call region to the caller, which can give them to another process. With read_only 1 the connection changes nothing. A connection that reads only makes shares that read only. With block_limit > 0 a writable share gets a block quota of its own (at most the limit of the maker's store) that refuses writes past it without thinning versions of the parent store; 0 inherits the store limit. The share ends when the caller calls unshare, or when the connection that made it loses its store. The result is one row, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant`;
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: the place);
// - `Bad_Value` or `Out_Of_Range` (Argument_Refused, unit Blocks: negative block_limit, non-zero block_limit on a read-only share, or block_limit above the store limit);
// - `Full` (Budget_Or_Capacity_Exhausted, unit Connections: no free share);
// - `Refused` (Callee_Unavailable: the kernel refused a memory object or a give).
@(export, link_name = "share")
share :: proc "c" (place: i64, read_only: i64, block_limit: i64, result: ^[]Shared, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || caller.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	// A share makes no share: its holder is a process that its maker chose,
	// and it could hold each share of the service (docs/STORAGE.md, "4.3
	// Read only, and revocation").
	if share_of(caller.connection) != nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Connections)
	}
	effective_read_only := read_only != 0 || caller.read_only
	checked_limit, limit_refusal := share_quota.effective_share_limit(block_limit, effective_read_only, caller.store.limit)
	switch limit_refusal {
	case .None:
	case .Negative, .Read_Only_Has_Limit:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Blocks, 3, block_limit)
	case .Exceeds_Store_Limit:
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Blocks, 3, block_limit, i64(caller.store.limit))
	}
	path: Path
	if !place_path(&caller, place, &path, error, 1) {
		return .Argument_Refused, 0
	}
	group_flush_if_conflict(path.store.name)
	if !path.own {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 1)
	}
	free: ^Share
	for &item in shares {
		if item.connection.calls.head == nil {
			free = &item
			break
		}
	}
	if free == nil {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Connections, 0, 0, SHARE_CAPACITY)
	}
	ring_memory, ring_status := system.memory_create(ring.PAGE_COUNT)
	if ring_status != .Succeeded {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0, 0, 0, i64(ring_status))
	}
	region_memory, region_status := system.memory_create(isolated.REGION_PAGES)
	if region_status != .Succeeded {
		system.close(ring_memory)
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0, 0, 0, i64(region_status))
	}
	connection, connection_ok := system.connection_make(ring_memory, region_memory, system.name_unpack(system.name_pack(caller.store.name)))
	if !connection_ok {
		system.close(ring_memory)
		system.close(region_memory)
		return call_outcome.fail(error, .Callee_Unavailable, .Refused)
	}
	// The caller makes a share to give it to another process (docs/STORAGE.md,
	// "4.3 Read only, and revocation"): the two
	// handles carry Give. The revocation of unshare ends each copy, in each
	// process that has one.
	given_ring, give_status := system.give(caller.connection.ring_memory, ring_memory, {.Give, .Read, .Write})
	given_region: system.Handle
	if give_status == .Succeeded {
		given_region, give_status = system.give(caller.connection.ring_memory, region_memory, {.Give, .Read, .Write})
	}
	if give_status != .Succeeded {
		system.handle_revoke(ring_memory)
		system.connection_end(&connection)
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0, 0, 0, i64(give_status))
	}
	free^ = {connection = connection, maker = caller.connection.ring_memory, read_only = effective_read_only, depth = path.depth, block_limit = checked_limit}
	copy(free.path[:], path.names[:path.depth])
	number := i64(intrinsics.ptr_sub(free, &shares[0])) + 1
	if len(result) > 0 {
		result[0] = {share = number, ring = i64(given_ring), region = i64(given_region)}
	}
	if free.read_only {
		system.log_fact(.Info, Read_Only_Share_Made{share = u64(number), store = store_field(caller.store.name)})
	} else {
		system.log_fact(.Info, Share_Made{share = u64(number), store = store_field(caller.store.name)})
	}
	return .Succeeded, 1
}

// share_end revokes the handles of a share in each process that has them,
// and frees it and its places.
share_end :: proc "contextless" (item: ^Share) {
	system.handle_revoke(item.connection.ring_memory)
	system.handle_revoke(item.connection.region_memory)
	holder := item.connection.ring_memory
	for &place in places {
		if place.holder == holder {
			place.holder = 0
			place.generation += 1
		}
	}
	pending_drop_of(holder)
	system.connection_end(&item.connection)
	item^ = {}
	// Each share that this share made ends with it: a holder that stopped
	// never calls again, so no later call would end them. share refuses a
	// share of a share, so this finds one only after a change of that rule.
	for &child in shares {
		if child.connection.calls.head != nil && child.maker == holder {
			share_end(&child)
		}
	}
}

// unshare ends a share that this connection made: the kernel ends its handles in each process that has them, and its places end. The result is 0, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `Absent` (Nothing_Has_That_Name, unit Connections: no share of this connection has this number).
@(export, link_name = "unshare")
unshare :: proc "c" (number: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || number < 1 || number > SHARE_CAPACITY {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connections, 1, number)
	}
	item := &shares[number - 1]
	if item.connection.calls.head == nil || item.maker != caller.connection.ring_memory {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Connections, 1, number)
	}
	share_end(item)
	system.log_fact(.Info, Share_Ended{share = u64(number)})
	return .Succeeded, 0
}

// The counts of the store of a connection, or of the tree of a share of a
// tree.
Usage :: struct {
	objects:  i64, // With the objects of the trees that wait to be freed. A share of a tree: the objects under its tree.
	trees:    i64,
	versions: i64,
	blocks:   i64, // The distinct blocks of the store. A share of a tree: the blocks of its tree (tree_usage), or USAGE_NOT_COUNTED.
	limit:    i64,
	removing: i64, // The trees that a remove took out, and whose blocks are not free yet. A share of a tree: 0.
}

USAGE_NOT_COUNTED :: answers.USAGE_NOT_COUNTED

// usage gives the counts of the store of the caller, in one row. Through a share of a tree, it gives the counts of that tree only: the objects, the trees and the versions under it, and its blocks (the nodes of its trees, the blocks of the current state of each object, the index and the leaves of their versions), with the limit of the store and no removal; a tree that needs more reads to count than SHARE_USAGE_READ_LIMIT, or that has a wrong block, gives USAGE_NOT_COUNTED in objects, trees, versions and blocks. A share never sees a count of the whole store: it would tell the holder what the rest of the store holds.
@(export, link_name = "usage")
usage :: proc "c" (result: ^[]Usage) -> i64 {
	caller: Caller
	caller_of(&caller)
	row: Usage
	if !service_state.caller_may_read_usage(caller.connection != nil, caller.store.name, caller.store.limit) {
		if len(result) > 0 {
			result[0] = row
		}
		return 1
	}
	if !disk_opened {
		// A disk that went silent before the open: no count is known.
		row.limit = i64(share_quota.effective_usage_limit(caller.store.share_limit, caller.store.limit))
		row.objects, row.trees, row.versions, row.blocks = USAGE_NOT_COUNTED, USAGE_NOT_COUNTED, USAGE_NOT_COUNTED, USAGE_NOT_COUNTED
	} else if caller.connection != nil && caller.depth > 0 {
		row.limit = i64(share_quota.effective_usage_limit(caller.store.share_limit, caller.store.limit))
		if index := store_find(caller.store.name); index >= 0 && !store_damaged[index] {
			counts, outcome := tree_usage(index, caller.path[:caller.depth])
			if outcome != .Found || counts.over_bound || counts.failed {
				row.objects, row.trees, row.versions, row.blocks = USAGE_NOT_COUNTED, USAGE_NOT_COUNTED, USAGE_NOT_COUNTED, USAGE_NOT_COUNTED
			} else {
				row.objects, row.trees, row.versions, row.blocks = i64(counts.objects), i64(counts.trees), i64(counts.versions), i64(counts.blocks)
			}
		}
	} else if caller.connection != nil {
		row.limit = i64(share_quota.effective_usage_limit(caller.store.share_limit, caller.store.limit))
		if index := store_find(caller.store.name); index >= 0 {
			row.objects = i64(store_blocks[index].objects)
			row.trees = i64(store_blocks[index].trees)
			row.versions = i64(opened.store_versions[index])
			row.blocks = i64(store_cell(index).used)
			row.removing = i64(store_blocks[index].removing)
		}
	}
	if len(result) > 0 {
		result[0] = row
	}
	return 1
}

// stores gives the generation of the disk, its blocks in use, and the commits, the commits that a read back refused, the commits whose root write or read back failed on the device (not taken: the next open decides), the blocks written (those of refused commits too), the blocks read back with the time of those reads, the grouped commits and their member changes, and the block requests sent for transferred blocks since the start of the service, then the stores that the caller may name, one line for each, with its objects, its trees, its versions, its blocks (a shared block counted one time), the blocks that two names share, its limit, the count of connections that hold its grant now, and its damage. Only a caller that acts for a principal sees them: the stores of that principal. The result is the count of bytes of the text, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, unit Acts_For_Principal: the caller does not act for a principal);
// - `Device` (Callee_Unavailable: the disk went silent before the open, and the service knows no store).
@(export, link_name = "stores")
stores :: proc "c" (result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if !caller.acts_for_principal {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	writer := system.Writer{buffer = result^}
	parts := [?]system.Part{"generation ", root.generation, ", ", blocks_in_use(), " of ", root.disk_blocks, " blocks in use, ", commits, " commits, ", commits_refused, " commits refused, ", commits_undecided, " commits for the next open to decide, ", blocks_written, " blocks written and ", blocks_read_back, " blocks read back in ", read_back_nanoseconds / 1000, " microseconds, ", group_commit_batches, " grouped commits (", group_commit_members, " changes), ", block_requests_sent, " block requests for ", blocks_transferred, " blocks since the start"}
	for part in parts {
		system.write_part(&writer, part)
	}
	for index in 0 ..< store_numbers() {
		// The one rule of the stores that a caller may name: here, the
		// stores that it sees. The name of a store of a principal opens
		// with the keys of that principal only.
		if !store_listed(index) || reclaiming_cell(index) {
			continue
		}
		name_buffer: [format.OWNER_FIELD_SIZE]u8
		store_name := owned_cell(index) ? owned_name_into(index, caller.principal, &name_buffer) : store_name_of(index)
		if store_name == "" || !may_name_store(&caller, store_name) {
			continue
		}
		store := store_cell(index)
		holders: u64
		for &connection in service.connections {
			if connection.calls.head != nil && system.name_of(connection.caller[:]) == store_name && connection.grant & isolated.CALLER_AMOUNT_MASK != 0 {
				holders += 1
			}
		}
		counts := &store_blocks[index]
		line := [?]system.Part{"\n", store_name, ": ", counts.objects, " objects, ", counts.trees, " trees, ", opened.store_versions[index], " versions, ", store.used, " of ", store.limit, " blocks, ", opened.store_shared[index], " shared, ", holders, holders == 1 ? string(" connection") : string(" connections")}
		for part in line {
			system.write_part(&writer, part)
		}
		if counts.removing != 0 {
			tail := [?]system.Part{", ", counts.removing, " trees to free"}
			for part in tail {
				system.write_part(&writer, part)
			}
		}
		if store_damaged[index] {
			system.write_part(&writer, ", a node of its trees has a wrong check")
		} else if opened.store_damaged_objects[index] != 0 {
			tail := [?]system.Part{", ", opened.store_damaged_objects[index], " damaged"}
			for part in tail {
				system.write_part(&writer, part)
			}
		}
	}
	return .Succeeded, i64(writer.count + writer.dropped)
}

// recount asks for a recount of the count tree of the disk: a release or a dropped version that met a wrong block left names that no state holds, and their blocks stay in use until the service counts each name of their leaves again. With no request, the recount starts when the free blocks of the disk fall under a sixteenth of it. It starts when no call and no removal waits, and when the disk has a free block for each page of its tally (one for each leaf in use): after a recount that found no room, none starts until the free blocks grow. It walks each store: during the walk the service serves reads, and refuses each change with Busy, unit Count_Recount, with the stores walked and the stores in all. Only a process with the start grant Recount may ask, as a recount refuses the changes of every caller. A request that a failure of the recount ends is not made again. The result is the leaves of the count tree that wait for a recount: 0 when none waits, and nothing starts (a disk whose tables of each block fit in the memory of the service counts each name at its open).
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, unit Count_Recount: the caller has no start grant Recount);
// - `Device` (Callee_Unavailable: the disk went silent before the open).
@(export, link_name = "recount")
recount :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if !caller.recounts {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Count_Recount)
	}
	return .Succeeded, i64(recount_ask())
}

// ---------------------------------------------------------------------
// The exports of versions.

// open_store gives a place on the root of another store, for the exports that read it and for restore and clone: a caller that acts for principal N names the stores of principal N; another caller names its own store only; a share names no store, not even the store of its maker (may_name_store). write, add, remove, rename and share refuse a place of another store. The result is the place, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, unit Acts_For_Principal: the caller may not name this store);
// - `Absent` (Nothing_Has_That_Name, unit Stores: no such store);
// - `Full` (Budget_Or_Capacity_Exhausted, unit Places: no free place).
@(export, link_name = "open_store")
open_store :: proc "c" (store: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller: Caller
	caller_of(&caller)
	if caller.connection == nil || (!caller.acts_for_principal && !service_state.caller_has_own_store(caller.store.name, caller.store.limit)) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	// The name is copied one time: the caller can change the call region.
	copied: system.Name
	count := copy(copied[:len(copied) - 1], store^)
	name := string(copied[:count])
	if !may_name_store(&caller, name) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	index := store_find(name)
	if index < 0 || len(store^) >= len(copied) {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Stores, 1)
	}
	// The name that the caller gave: a store of a principal keeps only its
	// name tag in its cell.
	path := Path{store = {name = name, limit = store_cell(index).limit}}
	opened_place, ok := place_new(&caller, &path)
	if !ok {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Places, 0, 0, PLACE_CAPACITY)
	}
	return .Succeeded, opened_place
}

// One row of versions(): one state of an object.
Version :: struct {
	generation: i64, // The commit that made this state.
	time:       i64, // Milliseconds since the format of the disk, at that commit (the time that a machine ran).
	date:       i64, // Seconds since 1970 (UTC) at that commit. 0: the system had no date.
	bytes:      i64,
	own_blocks: i64, // The blocks that only this state holds: what thinning it frees.
	current:    i64, // 1: the current version, the last row.
}

// One row of compare(): bytes that differ between two states.
Byte_Range :: struct {
	first: i64, // The offset of the first byte that differs.
	count: i64,
}

// versions gives the states of the object `name` under a place, the oldest first, and its current version last: the generation, the time since the format of the disk, the date, the bytes, and the blocks that only this state holds. The place can be a place of another store (open_store). The result is the count of the rows, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, the caller has no store);
// - `Absent` (Argument_Refused: the place);
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, the name);
// - `Absent` (Nothing_Has_That_Name, no such object);
// - `Damaged` (Data_Damaged, the version index of the object has a wrong check);
// - `Device`.
@(export, link_name = "versions")
versions :: proc "c" (place: i64, name: ^string, result: ^[]Version, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	store_index, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located != .Succeeded {
		return located, 0
	}
	if _, listed_outcome := versions_list(store_index, &object, error); listed_outcome != .Succeeded {
		return listed_outcome, 0
	}
	rows := listed_count + 1
	// The blocks that only one state holds: the walk of each state goes
	// down the nodes that only it names.
	for row in 0 ..< min(rows, len(result)) {
		entry := row < listed_count ? listed[row] : Version_Entry{generation = object.generation, size = object.size, time = object.time, date = object.date, root = object.pointer, data_check = object.data_check}
		result[row] = {generation = i64(entry.generation), time = i64(entry.time), date = i64(entry.date), bytes = i64(entry.size), own_blocks = i64(own_blocks(store_index, entry.root, entry.size)), current = i64(row == listed_count)}
	}
	return .Succeeded, i64(rows)
}

// version copies the bytes of the object `name` under a place at a generation (one of its versions, or its current version) from `offset` into result, up to the end of the state or of the call region. A caller reads a version larger than the call region in pieces: a generation names one state, which no commit changes. The place: as for versions. The result is the count of bytes (0 at the end), or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of versions;
// - `Absent` (Nothing_Has_That_Name, the object has no version of this generation);
// - `Bad_Value` (Argument_Refused, offset is negative);
// - `Out_Of_Range` (Argument_Refused, offset is past the end of the state);
// - `Damaged` (Data_Damaged, a block of this version has a wrong check).
@(export, link_name = "version")
version :: proc "c" (place: i64, name: ^string, generation: i64, offset: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	store_index, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located != .Succeeded {
		return located, 0
	}
	state, state_refused := state_at(store_index, &object, generation, 3, error)
	if state_refused != .Succeeded {
		return state_refused, 0
	}
	if offset < 0 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 4, offset)
	}
	if u64(offset) > state.size {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Bytes, 4, offset, i64(state.size))
	}
	count := min(u64(len(result)), state.size - u64(offset))
	if count == 0 {
		return .Succeeded, 0
	}
	value, outcome = state_read(store_index, state, u64(offset), result^[:count], error, 2)
	return
}

// restore makes a version of the object `name` under a place its current version again, in one commit: the current version before it becomes a version, so nothing is lost. No block of data is written: the object names the blocks of the version. The place: as for versions. The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of version, and those of write.
@(export, link_name = "restore")
restore :: proc "c" (place: i64, name: ^string, generation: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	if named.caller.read_only {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Changes)
	}
	store_index, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located != .Succeeded {
		return located, 0
	}
	if generation == i64(object.generation) && state_damaged(object.pointer) {
		// The current version is damaged: a restore of it would keep the
		// damage, and say that the object is whole.
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Objects, 2)
	}
	state, state_refused := state_at(store_index, &object, generation, 3, error)
	if state_refused != .Succeeded {
		return state_refused, 0
	}
	value, outcome = object_change(named.path.store, path_names(&named.path), named.name, .Restore, nil, state, reaches_whole_store(&named.caller), error, 2)
	return
}

// clone makes the object `new_name` under a place a copy of the object `name` under the same place: the two name the same blocks until one of them changes. A state of new_name before becomes a version. The place: as for versions. The result is the generation of the commit, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of restore;
// - new_name is argument 3.
@(export, link_name = "clone")
clone :: proc "c" (place: i64, name: ^string, new_name: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	if named.caller.read_only {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Changes)
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located != .Succeeded {
		return located, 0
	}
	if state_damaged(object.pointer) {
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Objects, 2)
	}
	target, target_ok := name_keep(new_name^, error, 3)
	if !target_ok {
		return .Argument_Refused, 0
	}
	value, outcome = object_change(named.path.store, path_names(&named.path), target, .Clone, nil, current_state(&object), reaches_whole_store(&named.caller), error, 3)
	return
}

// compare gives the ranges of bytes that differ between two states of the object `name` under a place (two generations: a version or the current version). Two blocks that the two states both name are equal bytes and are not read. The place: as for versions. The result is the count of the ranges, or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - those of version;
// - first and second are arguments 3 and 4.
@(export, link_name = "compare")
compare :: proc "c" (place: i64, name: ^string, first: i64, second: i64, result: ^[]Byte_Range, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, false); refused != .Succeeded {
		return refused, 0
	}
	store_index, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located != .Succeeded {
		return located, 0
	}
	scope, crypto_read := store_crypto_enter(store_index)
	if crypto_read != .Good {
		if crypto_read == .Device {
			return call_outcome.fail(error, .Callee_Unavailable, .Device)
		}
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
	}
	defer store_crypto_leave(&scope)
	states: [2]State_Of_Object
	for generation, index in ([2]i64{first, second}) {
		state, state_refused := state_at(store_index, &object, generation, 3 + i64(index), error)
		if state_refused != .Succeeded {
			return state_refused, 0
		}
		states[index] = state
	}
	for state, index in states {
		if state.size > format.OBJECT_SIZE_LIMIT || state_damaged(state.root) {
			return call_outcome.fail(error, .Data_Damaged, .Damaged, .Objects, 3 + i64(index))
		}
	}
	ranges: i64
	open_first: i64 = -1
	sizes := [2]i64{i64(states[0].size), i64(states[1].size)}
	low, high := min(sizes[0], sizes[1]), max(sizes[0], sizes[1])
	trees := [2]block_tree.State{tree_state(states[0]), tree_state(states[1])}
	// The blocks that one of the two states holds, in their order: a hole in
	// both, and a block that both name, are equal bytes and are not read.
	end_blocks := max(blocks_of(states[0].size), blocks_of(states[1].size))
	for at: u64 = 0; at < end_blocks; {
		found_at: [2]u64
		found_pointer: [2]Pointer
		next := end_blocks
		for side in 0 ..< 2 {
			found_at[side] = end_blocks
			index, pointer, found, block_outcome := block_tree.next_block(&object_source, trees[side], at, &object_nodes)
			if block_outcome != .Good {
				return call_outcome.fail(error, block_outcome == .Device ? .Callee_Unavailable : .Data_Damaged, block_outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(side))
			}
			if found {
				found_at[side], found_pointer[side] = index, pointer
				next = min(next, index)
			}
		}
		compare_span(result^, &ranges, &open_first, i64(at * BLOCK_SIZE), i64(next * BLOCK_SIZE), low, high)
		if next >= end_blocks {
			break
		}
		here: [2]Pointer
		for side in 0 ..< 2 {
			if found_at[side] == next {
				here[side] = found_pointer[side]
			}
		}
		base := i64(next * BLOCK_SIZE)
		if here[0] == here[1] {
			compare_span(result^, &ranges, &open_first, base, base + BLOCK_SIZE, low, high)
		} else {
			for side in 0 ..< 2 {
				compare_blocks[side] = {}
				if here[side].block == 0 {
					continue
				}
				if block_outcome := block_tree.block_read(&object_source, trees[side], next, &compare_blocks[side], &object_node); block_outcome != .Good {
					return call_outcome.fail(error, block_outcome == .Device ? .Callee_Unavailable : .Data_Damaged, block_outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(side))
				}
			}
			for offset in 0 ..< i64(BLOCK_SIZE) {
				at_byte := base + offset
				if at_byte >= high {
					break
				}
				inside := [2]bool{at_byte < sizes[0], at_byte < sizes[1]}
				differs := inside[0] != inside[1] || compare_blocks[0][offset] != compare_blocks[1][offset]
				if differs && open_first < 0 {
					open_first = at_byte
				} else if !differs {
					compare_close(result^, &ranges, &open_first, at_byte)
				}
			}
		}
		at = next + 1
	}
	compare_close(result^, &ranges, &open_first, high)
	return .Succeeded, ranges
}

compare_blocks: [2]Block // The two blocks of data that compare reads.

// One row of erase_versions: what the erase did.
Erase_Measure :: struct {
	generation: i64, // The generation of the root that the erase wrote last; 0 when the object had no version.
	versions:   i64, // The versions that the erase ended.
	zeroed:     i64, // The blocks that the end of the versions freed and that read back as zero bytes after their write.
	kept:       i64, // The blocks of the versions that another state still names: they keep their bytes.
	damaged:    i64, // The version indexes, leaves and states with a wrong block that the erase ended without zeros over their bytes.
}

// erase_versions ends each version of the object `name` under a place, in one commit, and then writes zero bytes over each block that no other state, version or entry names after that commit: the data and the object nodes of the versions, their index and their leaves, and the tree nodes that the commit replaced. The current version stays, with its generation. A block that another state still names keeps its bytes, and the row counts it. Before the zeros, the commit reads back its blocks and its root, past the cache of the service, then the service writes the root of the commit again with the next generation and reads it back, so that no root on the disk names a block of zeros; after the zeros it reads them back. A loss of power leaves the versions or none of them. The disk device can keep old copies of a block that the service does not see (src/md/features/version_erase.md). Only a process with the grant Versions_Erase may call it, on its own store: a process without it, a share, a place of another store and a connection that reads only are refused. An object with no version makes no commit. The result is one row: the generation of the last root, the versions ended, the blocks written with zeros, the blocks kept because another state names them, and the damaged parts of the versions that were ended without zeros; or a failure with its call outcome and an error record.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing, the caller has no store, or the place is of another store; Grant_Or_Right_Missing, unit Changes: a share, or a connection that reads only; Grant_Or_Right_Missing, unit Versions_Erase: the caller has no grant Versions_Erase);
// - `Absent` (Argument_Refused, unit Places: the place is not a place of this connection; Nothing_Has_That_Name, unit Places: its tree was removed or renamed; Nothing_Has_That_Name, unit Objects: no such object, or the name is a tree);
// - `Empty`, `Too_Long` or `Bad_Byte` (Argument_Refused, the name);
// - `Full` (Budget_Or_Capacity_Exhausted, unit Commit_Blocks: the versions free more blocks than one commit can);
// - `Device` (Callee_Unavailable: unit Dropped_Writes, the read back of the commit of the end found blocks with other bytes, and the versions stay; with no unit, a write or a read failed, or the read back of the second root found other bytes, and after the commit of the end the versions are gone and some blocks can hold their old bytes; the log says which). The row counts as zeroed only the blocks that read back as zeros; a block that the disk did not write with zeros keeps its old bytes, and the log says it;
// - `Damaged` (Data_Damaged, unit Stores or Counts, as for write).
@(export, link_name = "erase_versions")
erase_versions :: proc "c" (place: i64, name: ^string, result: ^[]Erase_Measure, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	named: Named
	if refused := named_of(place, name^, &named, error, 1, true); refused != .Succeeded {
		return refused, 0
	}
	// A share is lent for the bytes of one tree, and ends no history.
	if share_of(named.caller.connection) != nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Changes)
	}
	// The versions protect the principal against a fault of the process of
	// the store: only a process that the root service allows ends them, for
	// a secret that an earlier version must not keep (docs/PROPERTIES.md,
	// "Persistence: no save action, and versions for all processes").
	if !named.caller.erases_versions {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Versions_Erase)
	}
	measure, erased := versions_erase(named.caller.store, path_names(&named.path), named.name, error)
	if erased != .Succeeded {
		return erased, 0
	}
	if len(result) > 0 {
		result[0] = measure
	}
	return .Succeeded, 1
}

// compare_close ends the range that differs, at `end`.
compare_close :: proc "contextless" (result: []Byte_Range, ranges: ^i64, open_first: ^i64, end: i64) {
	if open_first^ < 0 {
		return
	}
	if ranges^ < i64(len(result)) {
		result[ranges^] = {first = open_first^, count = end - open_first^}
	}
	ranges^ += 1
	open_first^ = -1
}

// compare_span takes the bytes [from, to) that are equal in the two states
// where both have them: they differ only between the two sizes (low and
// high).
compare_span :: proc "contextless" (result: []Byte_Range, ranges: ^i64, open_first: ^i64, from: i64, to: i64, low: i64, high: i64) {
	if from < min(to, low) {
		compare_close(result, ranges, open_first, from)
	}
	if max(from, low) < min(to, high) && open_first^ < 0 {
		open_first^ = max(from, low)
	}
}

// ---------------------------------------------------------------------
// The service.

service: system.Service

// The entry of the storage service: it attaches to the block service of the data disk, opens the disk, then
// serves the calls of its connections for the life of the machine.
//
// The root service starts it on demand: at the first connection to `storage`, or before the first process with a
// private store. The entry, in order:
//
// 1. opens its service ring and the block ring; with no service ring, it writes "storage: no service ring" and
//    stops with `Refused`, as with no seed in its context; with no block ring, it writes "storage: no block
//    ring" and stops with `Failed`;
// 2. creates the data region, one contiguous memory object that the device reads and writes, and gives it to the
//    block service with the command `Attach`; a refusal stops it with `Failed`;
// 3. opens the disk (`mount`): it reads the two roots, takes the newest one with a good check, and checks each
//    block that a store names.
//
// The open ends in one of three ways:
//
// - **no valid root**: "storage: no valid root on the disk"; the service keeps the disk as it is, serves nothing,
//   and stops with `Failed`;
// - **a new disk**: it formats the disk and writes "storage: ok, a new disk: generation 1, N blocks";
// - **a disk with data**: "storage: ok, generation G: S stores, O objects, ...", with one warning line for each
//   kind of damage that it found. A damaged object gives `Damaged` to a read; the other objects are served.
//
// Then one loop runs for ever. It waits on the service ring and on each share, and runs the calls that wait. When
// no call waits, it frees one step of a tree that a removal left: a large removal never makes a caller wait.
//
// **A disk that stops to answer.** Each wait for the block service ends when that service stops, or after
// `system.ANSWER_BOUND_MILLISECONDS` with no completion; a completion with the record `No_Answer` of the device ends
// it too. The disk is then silent: the service writes "storage: the disk does not answer: <the cause>; the service
// reads and changes nothing on the disk until its next start, and refuses each call that needs the disk", sends no
// request to the block service again, and answers each call that needs a block with `Device`. A disk that goes silent
// before the open is done leaves the service running with no store known: it answers each call that names a store
// with `Device`, and `usage` gives no count. It does not stop: the root service would start it again, with a new
// block service and a reset of a device that still holds a request (src/md/features/missing_hardware.md).
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	date_page = date.page_of(ctx)
	retention_rule_read(ctx)
	// The key of the slots of the hash index: a new one at each start, so
	// that no party can choose hashes whose first slots make one long run.
	// The generator is local: it serves this one draw, and leaves no state
	// of the key in the data of the module.
	// The generator then serves the salts of new stores (owned_stores.odin):
	// a salt is public, and a generator that erases each key it served
	// keeps no state of the key of the slots.
	if !random.generator_from_context(&salt_generator, ctx) {
		system.log_fact(.Error, No_Seed{})
		system.stop(.Refused)
	}
	// The nonce of the scratch of a repair of the count tree comes from the
	// same draw: a page that a start before wrote is not taken for a page of
	// this start, with a date or with none.
	slot_key: [16]u8
	random.fill(&salt_generator, slot_key[:])
	opened.hash_index.slot_key = intrinsics.unaligned_load((^u64)(&slot_key[0]))
	repair_disk.nonce = intrinsics.unaligned_load((^u64)(&slot_key[8]))
	ok: bool
	if service, ok = system.service_open(ctx); !ok {
		system.log_fact(.Error, No_Service_Ring{})
		system.stop(.Refused)
	}
	group_exports_init(service.file)
	service.disconnected = connection_ended
	service.principal_keys = storage_principal_keys // principal_keys.odin
	service.principal_reclaim = storage_principal_reclaim // reclaim.odin
	service.tree_grant = storage_tree_grant // object_cache_wiring.odin
	service.public_object_publish = storage_public_object_publish // object_cache_wiring.odin
	// Initialize the read-only object cache, durable pin table, and boot-image
	// tree manifest BEFORE opening any data disk so image-tree objects serve
	// immediately even on diskless machines or with an unusable disk.
	storage_object_cache_init()
	storage_image_tree_init(ctx)
	ring_memory := ctx.handles[block.GRANT_RING]
	if ring_memory == 0 {
		// No data disk on this machine: readiness.disk_state stays .Absent.
		if !readiness.image_tree_ready {
			system.log_fact(.Error, No_Block_Ring{})
			system.stop(.Failed)
		}
		system.log_fact(.Info, Disk_Absent_Image_Tree_Serving{})
	} else {
		// Advance to .Opening as soon as a block ring handle is present so any
		// early setup failure transitions cleanly into .Unusable or .Silent.
		disk_state_advance(.Begin_Open)
		status: call_outcome.Call_Outcome
		if blocks, status = system.ring_open(ring_memory); status != .Succeeded {
			system.log_fact(.Error, No_Block_Ring{})
			if !readiness.image_tree_ready {
				system.stop(.Failed)
			}
			disk_state_advance(.Open_Unusable)
			broken = true
		} else {
			block_service = ctx.handles[block.GRANT_SERVICE]
			if kind, rights, _ := system.handle_state(block_service); kind != .Process || .Read not_in rights {
				system.log_fact(.Error, No_Block_Service_Handle{})
				if !readiness.image_tree_ready {
					system.stop(.Failed)
				}
				disk_state_advance(.Open_Unusable)
				broken = true
			} else {
				memory, memory_status := system.memory_create(REGION_BLOCKS, 0, {.Contiguous}) // The device reads and writes it.
				address: rawptr
				map_status := call_outcome.Call_Outcome.Argument_Refused
				if memory_status == .Succeeded {
					address, map_status = system.memory_map(memory, {.Write})
				}
				if memory_status != .Succeeded || map_status != .Succeeded {
					if memory_status == .Succeeded && memory != 0 {
						system.close(memory)
					}
					system.log_fact(.Error, No_Data_Region{})
					if !readiness.image_tree_ready {
						system.stop(.Failed)
					}
					disk_state_advance(.Open_Unusable)
					broken = true
				} else {
					region = ([^]u8)(address)
					// The block service maps the ring when it starts.
					given: system.Handle
					give_status := call_outcome.Call_Outcome.Argument_Refused
					for attempt := 0; attempt < 2000 && give_status != .Succeeded; attempt += 1 {
						if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Succeeded {
							system.sleep(system.time() + 1)
						}
					}
					// A block service that stopped before it mapped the ring: the disk is
					// silent, as at a stop during a wait.
					if give_status != .Succeeded {
						if state, _, _ := system.process_state(block_service); system.answer_wait_of(system.time(), system.WAIT_FOREVER, state) == .Stopped {
							disk_silence_note(.Block_Service_Stopped)
						}
					}
					// A silent disk wrote its own line: the block service stopped before it
					// served, or did not answer. The service then does not stop: it serves
					// image-tree calls and refuses disk-store calls via disk_unopened_refusal.
					attach_ok := give_status == .Succeeded && command(.Attach, {0 = u64(given)}).kind == u32(call_outcome.Call_Outcome.Succeeded)
					if !attach_ok {
						if !disk_silent {
							system.memory_unmap(address)
							system.close(memory)
							region = nil
							system.log_fact(.Error, Data_Region_Refused{})
							if !readiness.image_tree_ready {
								system.stop(.Failed)
							}
							disk_state_advance(.Open_Unusable)
							broken = true
						}
					} else if !disk_silent {
						disk_open()
					}
				}
			}
		}
	}
	// A removal that waits runs when no call waits, and a step of a repair
	// after each round of calls; a run of a recount starts when no call and
	// no removal waits; a service that makes no change runs none, and waits.
	for {
		if !disk_opened || broken || !removal_waits() && !reclaim_waits() && !repair_waits() && !recount_waits() {
			wait: system.Wait
			system.service_wait(&wait, &service)
			for &item in shares {
				if item.connection.calls.head != nil {
					system.wait_records(&wait, &item.connection.calls.commands)
				}
			}
			system.plan_values_wait(&wait, &ctx.values, &retention_plan_copy)
			system.wait_end(&wait)
		}
		if system.plan_values_changed(&ctx.values, &retention_plan_copy) {
			retention_rule_read(ctx)
		}
		calls := storage_serve_pass()
		if disk_opened && !broken {
			if calls > 0 {
				repair_call_came()
			}
			// A step of a repair runs after each round of calls, so a service
			// that is never idle still ends its repair; a removal or orphaned
			// store reclamation runs when no call waits, and a run of a recount
			// when none of those wait either.
			if repair_waits() {
				repair_step()
			} else if calls == 0 {
				if !removal_step() && !reclaim_step() && recount_waits() {
					repair_step()
				}
			}
		}
	}
}

// The copy of the plan values page that the retention rule is read from.
retention_plan_copy: system.Plan_Values_Copy

// retention_rule_read reads the retention rule of the plan of principal 0
// from the plan values page: at the start, and at each change of the plan.
// Storage starts before the holder of Plans, which needs it, so the rule of
// the plan in force comes with that change, and not at the start
// (src/md/features/module_settings.md, "How the values reach their
// owner"). The next pass of the retention runs with the new rule.
retention_rule_read :: proc "contextless" (ctx: ^system.Context) {
	plan, planned := system.plan_values_of_process(&ctx.values, &retention_plan_copy)
	if !planned {
		return
	}
	rule, order_refused := storage_retention.rule_of(plan)
	// The line says a change: a plan with no rule at the start of storage,
	// and a change of the plan that leaves the rule, write nothing.
	if rule == retention_rule && !order_refused {
		return
	}
	retention_rule = rule
	system.log_fact(.Info, Retention_Rule_Of_The_Plan{keep_all = value_kinds.Time_In_Milliseconds(i64(rule.keep_all_milliseconds)), hours_end = value_kinds.Time_In_Milliseconds(i64(rule.hours_end_milliseconds)), order_refused = order_refused ? 1 : 0})
}

// disk_open opens the disk (mount) and writes its lines. A disk that goes
// silent during the open leaves the service with no open: its line is
// written, and each call is refused (disk_unopened_refusal).
disk_open :: proc "contextless" () {
	info := command(.Info)
	if disk_silent {
		return
	}
	max_blocks_per_request = info.values[1] == 0 ? 1 : min(info.values[1], REGION_BLOCKS)
	start := system.time()
	mounted := mount(info.values[0])
	elapsed := system.time() - start
	if disk_silent {
		return
	}
	switch {
	case mounted.failed && mounted.no_memory:
		disk_state_advance(.Open_Unusable)
		// The open said why: No_Table_Memory.
		if readiness.image_tree_ready {
			broken = true
			return
		}
		system.stop(.Failed)
	case mounted.failed && mounted.older_format:
		disk_state_advance(.Open_Unusable)
		system.log_fact(.Error, Disk_Of_An_Older_Format{})
		if readiness.image_tree_ready {
			broken = true
			return
		}
		system.stop(.Failed)
	case mounted.failed && mounted.larger_than_capacity:
		disk_state_advance(.Open_Unusable)
		system.log_fact(.Error, Root_Larger_Than_Tables{used_blocks = blocks_field(table_blocks_held)})
		if readiness.image_tree_ready {
			broken = true
			return
		}
		system.stop(.Failed)
	case mounted.failed:
		disk_state_advance(.Open_Unusable)
		system.log_fact(.Error, No_Valid_Root{})
		if readiness.image_tree_ready {
			broken = true
			return
		}
		system.stop(.Failed)
	case mounted.needs_format:
		if mounted.first_cut {
			system.log_fact(.Warning, First_Root_Cut{})
		}
		system.log_fact(.Info, New_Disk_Formatted{blocks = blocks_field(root.disk_blocks)})
	case:
		if mounted.cut != 0 {
			system.log_fact(.Warning, Cut_Root_Skipped{generation = mounted.cut})
		}
		if mounted.older {
			system.log_fact(.Warning, Newest_Root_Refused{})
		}
		if mounted.wrong != 0 {
			system.log_fact(.Warning, Blocks_Damaged{blocks = mounted.wrong, objects = mounted.damaged_objects, stores = mounted.damaged_stores})
		}
		if mounted.damaged_versions != 0 {
			system.log_fact(.Warning, Versions_Damaged{versions = mounted.damaged_versions})
		}
		if mounted.damaged_store_pages != 0 {
			system.log_fact(.Warning, Store_Pages_Damaged{pages = mounted.damaged_store_pages})
		}
		// A disk with no count tree yet (one that the tool wrote) has each of
		// its leaves to write: only a tree that differs is a fact.
		if mounted.count_tree_damaged {
			system.log_fact(.Warning, Count_Tree_Damaged{})
		} else if mounted.count_leaves_differ != 0 && opened.root.counts.block != 0 {
			system.log_fact(.Warning, Count_Leaves_Differ{leaves = mounted.count_leaves_differ})
		}
		if mounted.named_twice != 0 || mounted.named_by_two_stores != 0 || mounted.reference_overflow != 0 {
			faulty: u64
			for flag in opened.store_faulty {
				faulty += u64(flag)
			}
			// One store and several are two sentences: each one is a fact
			// type.
			if faulty == 1 {
				system.log_fact(.Error, Engine_Fault_In_One_Store{named_twice = u64(mounted.named_twice), named_by_two_stores = u64(mounted.named_by_two_stores), reference_overflow = u64(mounted.reference_overflow), faulty_stores = faulty})
			} else {
				system.log_fact(.Error, Engine_Fault{named_twice = u64(mounted.named_twice), named_by_two_stores = u64(mounted.named_by_two_stores), reference_overflow = u64(mounted.reference_overflow), faulty_stores = faulty})
			}
		}
		recount_waits_say()
		if mounted.stores_recounted != 0 || mounted.stores_with_wrong_count != 0 {
			system.log_fact(.Warning, Store_Counts_Differ{stores_recounted = mounted.stores_recounted, stores_with_wrong_count = mounted.stores_with_wrong_count})
		}
		system.log_fact(.Info, Disk_Opened{generation = mounted.generation, stores = mounted.stores, objects = mounted.objects, trees = mounted.trees, versions = mounted.versions, in_use = blocks_field(blocks_in_use()), shared = mounted.shared, checked = mounted.checked, wrong = mounted.wrong, elapsed = milliseconds_field(elapsed)})
		if mounted.removing != 0 {
			system.log_fact(.Info, Trees_Wait_To_Be_Freed{trees = mounted.removing})
		}
	}
	disk_state_advance(.Open_Succeeded)
}
