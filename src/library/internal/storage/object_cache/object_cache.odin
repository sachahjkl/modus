// Pure read-only mapped-object cache and durable pin-accounting engine for the
// storage service (src/md/features/objects_by_hash.md).
//
// Design invariants:
// - Split pools: Public_System entries and Private_Principal entries live in
//   separate fixed-capacity tables with separate page budgets. Unprivileged or
//   private callers can never exhaust public slots or evict public entries.
// - Strict isolation: Private_Principal entries are keyed by
//   (principal_id, store_index, hash). Identical hashes in two principals or
//   two stores of one principal never deduplicate into one cache entry.
// - Non-crashing eviction: evict_candidate inspects kernel holdings through a
//   caller-supplied query callback and selects only private entries whose
//   holdings == 1 (only storage holds the handle; no reader maps it). An entry
//   with holdings > 1 is never evicted under cache pressure.
// - Security revocation: reclaim_principal drains every private entry owned by
//   principal_id regardless of holdings so storage volatile-zeroes, revokes,
//   unmaps, and frees all plaintext of a locked or reclaimed principal.
// - Explicit durable pins: keyed by (principal_id, store_index, hash) with a
//   per-principal quota and per-entry count bound. is_pinned protects pinned
//   objects during collect_garbage and erase_versions.
//
// Every routine is pure, contextless, and allocates no memory.
package storage_object_cache

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/enum_word"

// Format property: page size of the machine (4096 bytes), matching kernel pages
// and store disk blocks.
PAGE_SIZE :: u64(4096)

// Plan value: dedicated slot capacity for Public_System objects (image-tree
// assets and machine-wide public trees). Sized to hold all boot-image assets
// and system packs without contending with private principal slots.
PUBLIC_CACHE_CAPACITY :: 128

// Plan value: slot capacity for Private_Principal read-only cached objects
// across all active principals. Each entry retains two kernel handles (its
// stripped read-only handle and its internal writable wipe handle), so 256
// slots cap private handle consumption at 512, well within HANDLE_TABLE_CAPACITY.
PRIVATE_CACHE_CAPACITY :: 256

// Plan value: slot capacity for durable pins across all principals.
PIN_CAPACITY :: 512

// Plan value: default dedicated page budget for Public_System objects (16 MiB),
// covering font outlines, pointer themes, and manual link pages.
DEFAULT_MACHINE_BUDGET_PAGES :: u64(4096)

// Plan value: default machine-wide ceiling for Private_Principal cached pages
// (32 MiB).
DEFAULT_GLOBAL_PRIVATE_PAGES :: u64(8192)

// Plan value: default per-principal page quota for Private_Principal cached
// objects (8 MiB).
DEFAULT_PRINCIPAL_PRIVATE_PAGES :: u64(2048)

// Plan value: default maximum distinct durably pinned objects per principal.
DEFAULT_PRINCIPAL_PIN_QUOTA :: u32(64)

// Plan value: maximum nested durable pin references on a single
// (principal_id, store_index, hash) entry, preventing u32 saturation wrap.
PIN_COUNT_LIMIT :: u32(1024)

// Closed set of cache ownership classes. Explicit wire values allow safe border
// conversion through cache_class_of_word.
Cache_Class :: enum u8 {
	Public_System     = 0, // Image-tree and machine-wide public system objects.
	Private_Principal = 1, // Per-principal private disk objects.
}

// cache_class_of_word converts a transport word into a Cache_Class member,
// refusing any word that names no member.
cache_class_of_word :: proc "contextless" (word: u64) -> (class: Cache_Class, ok: bool) {
	return enum_word.member_of_word(Cache_Class, word)
}

// Closed set of eviction scopes for Private_Principal cache pressure.
Evict_Scope :: enum u8 {
	Same_Principal = 0, // Only idle private entries owned by the requesting principal.
	Any_Private    = 1, // Any idle private entry across principals (for global private ceiling).
}

// evict_scope_of_word converts a transport word into an Evict_Scope member.
evict_scope_of_word :: proc "contextless" (word: u64) -> (scope: Evict_Scope, ok: bool) {
	return enum_word.member_of_word(Evict_Scope, word)
}

// Closed set of outcomes from inserting a read-only object into the cache.
Insert_Result :: enum u8 {
	Inserted         = 0,
	Already_Present  = 1,
	Quota_Exceeded   = 2,
	Table_Full       = 3,
	Invalid_Argument = 4,
}

// Closed set of admission requirements before allocating or reading a
// Private_Principal object from disk. Separates per-principal quota pressure
// (which may evict only Same_Principal) from global private ceiling or table
// pressure (which may evict Any_Private once principal quota fits).
Private_Admit_Need :: enum u8 {
	Ready                = 0,
	Need_Principal_Pages = 1,
	Need_Global_Or_Slot  = 2,
	Impossible           = 3,
}

// Closed set of outcomes from selecting a non-crashing eviction candidate.
Evict_Result :: enum u8 {
	Found            = 0,
	None_Eligible    = 1,
	Invalid_Argument = 2,
}

// Closed set of outcomes from durable pin mutations.
Pin_Result :: enum u8 {
	Ok               = 0,
	Quota_Exceeded   = 1,
	Table_Full       = 2,
	Count_Limit      = 3,
	Not_Found        = 4,
	Invalid_Argument = 5,
}

// Plan-configured budgets and quotas for the read-only object cache.
Cache_Config :: struct {
	machine_budget_pages:    u64, // Dedicated ceiling for Public_System entries.
	global_private_pages:    u64, // Machine ceiling for all Private_Principal entries.
	principal_private_pages: u64, // Per-principal ceiling for Private_Principal entries.
}

// default_cache_config returns the default plan budgets.
default_cache_config :: proc "contextless" () -> Cache_Config {
	return {
		machine_budget_pages    = DEFAULT_MACHINE_BUDGET_PAGES,
		global_private_pages    = DEFAULT_GLOBAL_PRIVATE_PAGES,
		principal_private_pages = DEFAULT_PRINCIPAL_PRIVATE_PAGES,
	}
}

// One cached read-only memory object tracked by storage.
Cache_Entry :: struct {
	occupied:       bool,
	class:          Cache_Class,
	principal_id:   u64, // Always 0 for Public_System.
	store_index:    u32, // Always 0 for Public_System.
	memory_handle:  u64, // Kernel handle retained by storage.
	byte_size:      u64, // Exact object byte length.
	pages:          u64, // Kernel pages charged to the entry's budget.
	hash:           blake3.Hash,
	last_used_tick: u64, // Monotonic counter for deterministic LRU selection.
}

// Description of a candidate or reclaimed cache entry returned to storage.
Evicted_Entry :: struct {
	slot_index:    int,
	class:         Cache_Class,
	principal_id:  u64,
	store_index:   u32,
	memory_handle: u64,
	byte_size:     u64,
	pages:         u64,
	hash:          blake3.Hash,
}

// Callback queried during eviction to read kernel Handle_State.holdings without
// coupling this pure package to kernel operations.
Holdings_Query :: #type proc "contextless" (memory_handle: u64, user_data: rawptr) -> (holdings: u64, ok: bool)

// Split read-only mapped-object cache with zero heap allocation.
Cache :: struct {
	config:             Cache_Config,
	tick:               u64,
	public_count:       int,
	public_pages_used:  u64,
	private_count:      int,
	private_pages_used: u64,
	public_entries:     [PUBLIC_CACHE_CAPACITY]Cache_Entry,
	private_entries:    [PRIVATE_CACHE_CAPACITY]Cache_Entry,
}

// One durable pin entry keyed by (principal_id, store_index, hash).
Pin_Entry :: struct {
	occupied:     bool,
	principal_id: u64,
	store_index:  u32,
	pin_count:    u32,
	hash:         blake3.Hash,
}

// Snapshot of one durable pin entry returned by pins_list.
Pin_Info :: struct {
	principal_id: u64,
	store_index:  u32,
	pin_count:    u32,
	hash:         blake3.Hash,
}

// Durable pin table with per-principal quota accounting and zero heap allocation.
Pin_Table :: struct {
	principal_pin_quota: u32,
	entry_count:         int,
	entries:             [PIN_CAPACITY]Pin_Entry,
}

// pages_for_bytes computes the kernel page count required to back an object of
// byte_size bytes. A 0-byte object requires 1 page for a read-only mapping.
// Returns ok = false if byte_size would overflow page rounding.
pages_for_bytes :: proc "contextless" (byte_size: u64) -> (pages: u64, ok: bool) {
	if byte_size == 0 {
		return 1, true
	}
	if byte_size > max(u64) - (PAGE_SIZE - 1) {
		return 0, false
	}
	return (byte_size + PAGE_SIZE - 1) / PAGE_SIZE, true
}

// cache_init resets cache and applies config. Zero-initialized Cache can also
// be configured by calling cache_init with default_cache_config().
cache_init :: proc "contextless" (cache: ^Cache, config: Cache_Config) {
	if cache == nil {
		return
	}
	intrinsics.mem_zero_volatile(cache, size_of(Cache))
	cache.config = config
}

// pin_table_init resets table and configures its per-principal pin quota.
pin_table_init :: proc "contextless" (table: ^Pin_Table, principal_pin_quota: u32 = DEFAULT_PRINCIPAL_PIN_QUOTA) {
	if table == nil {
		return
	}
	intrinsics.mem_zero_volatile(table, size_of(Pin_Table))
	table.principal_pin_quota = principal_pin_quota
}

@(private = "file")
next_tick :: proc "contextless" (cache: ^Cache) -> u64 {
	if cache.tick < max(u64) {
		cache.tick += 1
	}
	return cache.tick
}

// principal_private_pages_used returns the total private cached pages currently
// charged to principal_id.
principal_private_pages_used :: proc "contextless" (cache: ^Cache, principal_id: u64) -> u64 {
	if cache == nil {
		return 0
	}
	total: u64 = 0
	for &entry in cache.private_entries {
		if entry.occupied && entry.principal_id == principal_id {
			total += entry.pages
		}
	}
	return total
}

// private_admit_need reports whether a Private_Principal object of pages fits
// immediately, requires Same_Principal eviction for per-principal quota, or
// requires Same_Principal/Any_Private eviction for global ceiling or table
// capacity.
private_admit_need :: proc "contextless" (cache: ^Cache, principal_id: u64, pages: u64) -> Private_Admit_Need {
	if cache == nil || pages == 0 || pages > cache.config.principal_private_pages || pages > cache.config.global_private_pages {
		return .Impossible
	}
	principal_used := principal_private_pages_used(cache, principal_id)
	if principal_used > cache.config.principal_private_pages - pages {
		return .Need_Principal_Pages
	}
	if cache.private_pages_used > cache.config.global_private_pages - pages || cache.private_count >= PRIVATE_CACHE_CAPACITY {
		return .Need_Global_Or_Slot
	}
	return .Ready
}

// lookup_public finds a cached Public_System entry by hash and updates its LRU
// tick on hit.
lookup_public :: proc "contextless" (cache: ^Cache, hash: blake3.Hash) -> (entry: ^Cache_Entry, slot_index: int, found: bool) {
	if cache == nil {
		return nil, -1, false
	}
	for &candidate, index in cache.public_entries {
		if candidate.occupied && candidate.hash == hash {
			candidate.last_used_tick = next_tick(cache)
			return &candidate, index, true
		}
	}
	return nil, -1, false
}

// lookup_private finds a cached Private_Principal entry by exact
// (principal_id, store_index, hash) triple and updates its LRU tick on hit.
// Never matches across principals or across distinct stores of one principal.
lookup_private :: proc "contextless" (cache: ^Cache, principal_id: u64, store_index: u32, hash: blake3.Hash) -> (entry: ^Cache_Entry, slot_index: int, found: bool) {
	if cache == nil {
		return nil, -1, false
	}
	for &candidate, index in cache.private_entries {
		if candidate.occupied && candidate.principal_id == principal_id && candidate.store_index == store_index && candidate.hash == hash {
			candidate.last_used_tick = next_tick(cache)
			return &candidate, index, true
		}
	}
	return nil, -1, false
}

// insert_public inserts a Public_System object paid from the dedicated machine
// object budget. Private usage can never block or evict this call.
insert_public :: proc "contextless" (
	cache: ^Cache,
	hash: blake3.Hash,
	memory_handle: u64,
	byte_size: u64,
	pages: u64,
) -> (slot_index: int, result: Insert_Result) {
	if cache == nil || memory_handle == 0 || pages == 0 {
		return -1, .Invalid_Argument
	}
	min_pages, size_ok := pages_for_bytes(byte_size)
	if !size_ok || pages < min_pages {
		return -1, .Invalid_Argument
	}
	free_slot := -1
	for &candidate, index in cache.public_entries {
		if candidate.occupied {
			if candidate.hash == hash {
				candidate.last_used_tick = next_tick(cache)
				return index, .Already_Present
			}
		} else if free_slot < 0 {
			free_slot = index
		}
	}
	if free_slot < 0 {
		return -1, .Table_Full
	}
	if pages > cache.config.machine_budget_pages || cache.public_pages_used > cache.config.machine_budget_pages - pages {
		return -1, .Quota_Exceeded
	}
	cache.public_entries[free_slot] = {
		occupied       = true,
		class          = .Public_System,
		principal_id   = 0,
		store_index    = 0,
		memory_handle  = memory_handle,
		byte_size      = byte_size,
		pages          = pages,
		hash           = hash,
		last_used_tick = next_tick(cache),
	}
	cache.public_count += 1
	cache.public_pages_used += pages
	return free_slot, .Inserted
}

// insert_private inserts a Private_Principal object keyed strictly by
// (principal_id, store_index, hash). Enforces both the per-principal page quota
// and the machine-wide private page ceiling.
insert_private :: proc "contextless" (
	cache: ^Cache,
	principal_id: u64,
	store_index: u32,
	hash: blake3.Hash,
	memory_handle: u64,
	byte_size: u64,
	pages: u64,
) -> (slot_index: int, result: Insert_Result) {
	if cache == nil || memory_handle == 0 || pages == 0 {
		return -1, .Invalid_Argument
	}
	min_pages, size_ok := pages_for_bytes(byte_size)
	if !size_ok || pages < min_pages {
		return -1, .Invalid_Argument
	}
	free_slot := -1
	principal_used: u64 = 0
	for &candidate, index in cache.private_entries {
		if candidate.occupied {
			if candidate.principal_id == principal_id {
				principal_used += candidate.pages
				if candidate.store_index == store_index && candidate.hash == hash {
					candidate.last_used_tick = next_tick(cache)
					return index, .Already_Present
				}
			}
		} else if free_slot < 0 {
			free_slot = index
		}
	}
	if free_slot < 0 {
		return -1, .Table_Full
	}
	if pages > cache.config.principal_private_pages || principal_used > cache.config.principal_private_pages - pages {
		return -1, .Quota_Exceeded
	}
	if pages > cache.config.global_private_pages || cache.private_pages_used > cache.config.global_private_pages - pages {
		return -1, .Quota_Exceeded
	}
	cache.private_entries[free_slot] = {
		occupied       = true,
		class          = .Private_Principal,
		principal_id   = principal_id,
		store_index    = store_index,
		memory_handle  = memory_handle,
		byte_size      = byte_size,
		pages          = pages,
		hash           = hash,
		last_used_tick = next_tick(cache),
	}
	cache.private_count += 1
	cache.private_pages_used += pages
	return free_slot, .Inserted
}

// evict_candidate selects the least-recently-used Private_Principal entry whose
// kernel holdings == 1 (only storage holds a handle; no reader maps it).
// Public_System entries are never eligible for private eviction, and any entry
// with holdings != 1 (or failed query) is skipped so active readers never fault.
evict_candidate :: proc "contextless" (
	cache: ^Cache,
	principal_id: u64,
	scope: Evict_Scope,
	query: Holdings_Query,
	user_data: rawptr,
) -> (candidate: Evicted_Entry, result: Evict_Result) {
	if cache == nil || query == nil {
		return {}, .Invalid_Argument
	}
	validated_scope, scope_ok := evict_scope_of_word(u64(scope))
	if !scope_ok {
		return {}, .Invalid_Argument
	}

	best_index := -1
	best_tick: u64 = max(u64)

	for &entry, index in cache.private_entries {
		if !entry.occupied {
			continue
		}
		switch validated_scope {
		case .Same_Principal:
			if entry.principal_id != principal_id {
				continue
			}
		case .Any_Private:
		}
		holdings, ok := query(entry.memory_handle, user_data)
		if !ok || holdings != 1 {
			continue
		}
		if best_index < 0 || entry.last_used_tick < best_tick {
			best_index = index
			best_tick = entry.last_used_tick
		}
	}
	if best_index < 0 {
		return {}, .None_Eligible
	}
	chosen := &cache.private_entries[best_index]
	return {
		slot_index    = best_index,
		class         = chosen.class,
		principal_id  = chosen.principal_id,
		store_index   = chosen.store_index,
		memory_handle = chosen.memory_handle,
		byte_size     = chosen.byte_size,
		pages         = chosen.pages,
		hash          = chosen.hash,
	}, .Found
}

// remove_private_slot removes an occupied Private_Principal entry at slot_index
// and updates page accounting. Returns the removed entry so storage can close
// its handle.
remove_private_slot :: proc "contextless" (cache: ^Cache, slot_index: int) -> (removed: Evicted_Entry, ok: bool) {
	if cache == nil || slot_index < 0 || slot_index >= PRIVATE_CACHE_CAPACITY {
		return {}, false
	}
	entry := &cache.private_entries[slot_index]
	if !entry.occupied {
		return {}, false
	}
	removed = {
		slot_index    = slot_index,
		class         = entry.class,
		principal_id  = entry.principal_id,
		store_index   = entry.store_index,
		memory_handle = entry.memory_handle,
		byte_size     = entry.byte_size,
		pages         = entry.pages,
		hash          = entry.hash,
	}
	cache.private_count -= 1
	cache.private_pages_used -= entry.pages
	intrinsics.mem_zero_volatile(entry, size_of(Cache_Entry))
	return removed, true
}

// remove_public_slot removes an occupied Public_System entry at slot_index.
// Intended only for service teardown or explicit system image reload, never for
// unprivileged cache eviction.
remove_public_slot :: proc "contextless" (cache: ^Cache, slot_index: int) -> (removed: Evicted_Entry, ok: bool) {
	if cache == nil || slot_index < 0 || slot_index >= PUBLIC_CACHE_CAPACITY {
		return {}, false
	}
	entry := &cache.public_entries[slot_index]
	if !entry.occupied {
		return {}, false
	}
	removed = {
		slot_index    = slot_index,
		class         = entry.class,
		principal_id  = entry.principal_id,
		store_index   = entry.store_index,
		memory_handle = entry.memory_handle,
		byte_size     = entry.byte_size,
		pages         = entry.pages,
		hash          = entry.hash,
	}
	cache.public_count -= 1
	cache.public_pages_used -= entry.pages
	intrinsics.mem_zero_volatile(entry, size_of(Cache_Entry))
	return removed, true
}

// reclaim_principal drains private entries owned by principal_id into out,
// removing them from the cache regardless of kernel holdings so storage can
// volatile-zero, Handle_Revoke, unmap, and close every locked or reclaimed
// plaintext object. Public_System entries are never touched.
//
// If principal_id owns more entries than len(out), written == len(out) and
// remaining reports how many entries still remain for the caller's next pass.
reclaim_principal :: proc "contextless" (cache: ^Cache, principal_id: u64, out: []Evicted_Entry) -> (written: int, remaining: int) {
	if cache == nil {
		return 0, 0
	}
	for &entry, index in cache.private_entries {
		if !entry.occupied || entry.principal_id != principal_id {
			continue
		}
		if written < len(out) {
			out[written] = {
				slot_index    = index,
				class         = entry.class,
				principal_id  = entry.principal_id,
				store_index   = entry.store_index,
				memory_handle = entry.memory_handle,
				byte_size     = entry.byte_size,
				pages         = entry.pages,
				hash          = entry.hash,
			}
			written += 1
			cache.private_count -= 1
			cache.private_pages_used -= entry.pages
			intrinsics.mem_zero_volatile(&entry, size_of(Cache_Entry))
		} else {
			remaining += 1
		}
	}
	return written, remaining
}

// reclaim_store drains private entries belonging to store_index (for example
// when a store transitions to reclamation) regardless of holdings.
reclaim_store :: proc "contextless" (cache: ^Cache, store_index: u32, out: []Evicted_Entry) -> (written: int, remaining: int) {
	if cache == nil {
		return 0, 0
	}
	for &entry, index in cache.private_entries {
		if !entry.occupied || entry.store_index != store_index {
			continue
		}
		if written < len(out) {
			out[written] = {
				slot_index    = index,
				class         = entry.class,
				principal_id  = entry.principal_id,
				store_index   = entry.store_index,
				memory_handle = entry.memory_handle,
				byte_size     = entry.byte_size,
				pages         = entry.pages,
				hash          = entry.hash,
			}
			written += 1
			cache.private_count -= 1
			cache.private_pages_used -= entry.pages
			intrinsics.mem_zero_volatile(&entry, size_of(Cache_Entry))
		} else {
			remaining += 1
		}
	}
	return written, remaining
}

// -----------------------------------------------------------------------------
// Durable pin accounting
// -----------------------------------------------------------------------------

// principal_pin_count returns the number of distinct durable pin entries held
// by principal_id.
principal_pin_count :: proc "contextless" (table: ^Pin_Table, principal_id: u64) -> u32 {
	if table == nil {
		return 0
	}
	count: u32 = 0
	for &entry in table.entries {
		if entry.occupied && entry.principal_id == principal_id {
			count += 1
		}
	}
	return count
}

// pin_add increments the durable pin count for (principal_id, store_index, hash).
// Creating a new pin entry checks the per-principal pin quota and table capacity.
// Incrementing an existing entry enforces PIN_COUNT_LIMIT without wrap.
pin_add :: proc "contextless" (table: ^Pin_Table, principal_id: u64, store_index: u32, hash: blake3.Hash) -> (new_count: u32, result: Pin_Result) {
	if table == nil {
		return 0, .Invalid_Argument
	}
	free_slot := -1
	owned_entries: u32 = 0
	for &entry, index in table.entries {
		if entry.occupied {
			if entry.principal_id == principal_id {
				owned_entries += 1
				if entry.store_index == store_index && entry.hash == hash {
					if entry.pin_count >= PIN_COUNT_LIMIT {
						return entry.pin_count, .Count_Limit
					}
					entry.pin_count += 1
					return entry.pin_count, .Ok
				}
			}
		} else if free_slot < 0 {
			free_slot = index
		}
	}
	if owned_entries >= table.principal_pin_quota {
		return 0, .Quota_Exceeded
	}
	if free_slot < 0 {
		return 0, .Table_Full
	}
	table.entries[free_slot] = {
		occupied     = true,
		principal_id = principal_id,
		store_index  = store_index,
		pin_count    = 1,
		hash         = hash,
	}
	table.entry_count += 1
	return 1, .Ok
}

// pin_remove decrements the durable pin count for (principal_id, store_index, hash)
// and frees the slot when the count reaches 0. Refuses underflow with .Not_Found.
pin_remove :: proc "contextless" (table: ^Pin_Table, principal_id: u64, store_index: u32, hash: blake3.Hash) -> (remaining_count: u32, result: Pin_Result) {
	if table == nil {
		return 0, .Invalid_Argument
	}
	for &entry in table.entries {
		if entry.occupied && entry.principal_id == principal_id && entry.store_index == store_index && entry.hash == hash {
			if entry.pin_count <= 1 {
				intrinsics.mem_zero_volatile(&entry, size_of(Pin_Entry))
				table.entry_count -= 1
				return 0, .Ok
			}
			entry.pin_count -= 1
			return entry.pin_count, .Ok
		}
	}
	return 0, .Not_Found
}

// is_pinned reports whether any principal holds at least one durable pin on
// (store_index, hash). Used by collect_garbage and erase_versions to block
// reclamation of pinned objects.
is_pinned :: proc "contextless" (table: ^Pin_Table, store_index: u32, hash: blake3.Hash) -> bool {
	if table == nil {
		return false
	}
	for &entry in table.entries {
		if entry.occupied && entry.store_index == store_index && entry.hash == hash && entry.pin_count > 0 {
			return true
		}
	}
	return false
}

// pin_count_of returns the durable pin count held by principal_id on
// (store_index, hash), or 0 when not pinned.
pin_count_of :: proc "contextless" (table: ^Pin_Table, principal_id: u64, store_index: u32, hash: blake3.Hash) -> u32 {
	if table == nil {
		return 0
	}
	for &entry in table.entries {
		if entry.occupied && entry.principal_id == principal_id && entry.store_index == store_index && entry.hash == hash {
			return entry.pin_count
		}
	}
	return 0
}

// reclaim_principal_pins removes every durable pin owned by principal_id so
// Principal_Reclaim releases all GC blocks held by a removed principal.
reclaim_principal_pins :: proc "contextless" (table: ^Pin_Table, principal_id: u64) -> (removed_entries: int, removed_pins: u64) {
	if table == nil {
		return 0, 0
	}
	for &entry in table.entries {
		if entry.occupied && entry.principal_id == principal_id {
			removed_entries += 1
			removed_pins += u64(entry.pin_count)
			intrinsics.mem_zero_volatile(&entry, size_of(Pin_Entry))
			table.entry_count -= 1
		}
	}
	return removed_entries, removed_pins
}

// pins_list_scoped copies active durable pin records owned by principal_id
// into out. Always filters strictly to principal_id; when filter_store is true,
// also filters strictly to store_index so a non-principal process sees only
// pins of its own store. Always returns the true total matching entry count.
pins_list_scoped :: proc "contextless" (
	table: ^Pin_Table,
	principal_id: u64,
	filter_store: bool,
	store_index: u32,
	out: []Pin_Info,
) -> (written: int, total: int) {
	if table == nil {
		return 0, 0
	}
	for &entry in table.entries {
		if !entry.occupied || entry.principal_id != principal_id {
			continue
		}
		if filter_store && entry.store_index != store_index {
			continue
		}
		if written < len(out) {
			out[written] = {
				principal_id = entry.principal_id,
				store_index  = entry.store_index,
				pin_count    = entry.pin_count,
				hash         = entry.hash,
			}
			written += 1
		}
		total += 1
	}
	return written, total
}

// pins_list copies active durable pin records into out. When filter_principal
// is true, only pins owned by principal_id are included. Always returns the
// true total matching entry count alongside written.
pins_list :: proc "contextless" (
	table: ^Pin_Table,
	principal_id: u64,
	filter_principal: bool,
	out: []Pin_Info,
) -> (written: int, total: int) {
	if table == nil {
		return 0, 0
	}
	for &entry in table.entries {
		if !entry.occupied {
			continue
		}
		if filter_principal && entry.principal_id != principal_id {
			continue
		}
		if written < len(out) {
			out[written] = {
				principal_id = entry.principal_id,
				store_index  = entry.store_index,
				pin_count    = entry.pin_count,
				hash         = entry.hash,
			}
			written += 1
		}
		total += 1
	}
	return written, total
}
