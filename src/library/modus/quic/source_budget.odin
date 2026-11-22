package quic

// Per-source-range admission budgets for new QUIC connections.
//
// A flood of Initial packets from one IPv4 /24 range must spend only that
// range's budget, leaving other ranges free to connect without delay.
// Each /24 prefix has a continuous token bucket (burst and per-second refill)
// and an active handshake cap, stored in a fixed-capacity table with zero
// heap allocations and LRU eviction when full.

// The number of distinct IPv4 /24 prefixes tracked at once.
SOURCE_BUDGET_CAPACITY :: 64

// The mask that maps an IPv4 address to its /24 source range prefix.
SOURCE_RANGE_MASK :: u32(0xFFFF_FF00)

// The admission limits for one IPv4 /24 source range.
Source_Budget_Limits :: struct {
	attempts_per_second:     int, // Continuous token refill rate per second for one /24 range.
	burst:                   int, // Maximum burst of new-connection Initial attempts for one /24 range.
	active_handshakes_limit: int, // Maximum concurrent connections in the handshake for one /24 range.
}

// One slot of the per-source-range budget table.
Source_Budget_Entry :: struct {
	used:              bool,        // false: the slot is empty.
	prefix:            u32,         // The IPv4 /24 prefix (address & SOURCE_RANGE_MASK).
	bucket:            Work_Bucket, // Token bucket for this /24 prefix.
	last_seen:         u64,         // Monotonic timestamp in microseconds of the last attempt for LRU eviction.
	active_handshakes: int,         // Count of active handshakes tracked for standalone callers.
}

// Fixed-capacity, zero-allocation table of per-/24 source-range budgets.
Source_Budget_Table :: struct {
	entries:   [SOURCE_BUDGET_CAPACITY]Source_Budget_Entry,
	has_time:  bool, // true after the first accepted timestamp.
	last_time: u64,  // Highest monotonic timestamp observed, in microseconds.
	evictions: u64,  // Count of occupied slots evicted when the table was full.
}

// Outcome of one per-source-range admission check.
Source_Budget_Result :: enum u8 {
	Admitted             = 0, // The attempt passed the active handshake cap and spent one unit from its /24 bucket.
	Over_Rate_Budget     = 1, // The /24 bucket held less than one unit; the attempt is dropped.
	Over_Handshake_Limit = 2, // The /24 range already holds its maximum concurrent handshakes.
	Backwards_Time       = 3, // The timestamp moved backwards relative to the table clock; nothing changed.
	Invalid_Limits       = 4, // The supplied limits are outside their valid bounds; nothing changed.
}

// source_range_prefix returns the IPv4 /24 prefix of an address.
source_range_prefix :: proc "contextless" (address: u32) -> u32 {
	return address & SOURCE_RANGE_MASK
}

// source_budget_table_init clears a source-budget table to its empty state.
source_budget_table_init :: proc "contextless" (table: ^Source_Budget_Table) {
	if table == nil {
		return
	}
	table^ = {}
}

// source_budget_limits_valid reports whether limits hold valid non-negative
// refill rate and positive burst and active-handshake bounds.
source_budget_limits_valid :: proc "contextless" (limits: Source_Budget_Limits) -> bool {
	return limits.burst > 0 && limits.attempts_per_second >= 0 && limits.active_handshakes_limit > 0
}

// source_budget_find returns the index of prefix in table, or -1 if absent.
@(private)
source_budget_find :: proc "contextless" (table: ^Source_Budget_Table, prefix: u32) -> int {
	for &entry, index in table.entries {
		if entry.used && entry.prefix == prefix {
			return index
		}
	}
	return -1
}

// source_budget_evict_slot selects a slot for a new /24 prefix: first an
// empty slot, then the oldest full idle slot, then the oldest idle slot, then
// the oldest slot overall.
@(private)
source_budget_evict_slot :: proc "contextless" (table: ^Source_Budget_Table, limits: Source_Budget_Limits, now: u64) -> int {
	full_idle_slot := -1
	idle_slot := -1
	oldest_slot := 0
	for &entry, index in table.entries {
		if !entry.used {
			return index
		}
		if entry.last_seen < table.entries[oldest_slot].last_seen {
			oldest_slot = index
		}
		if entry.active_handshakes == 0 {
			if idle_slot < 0 || entry.last_seen < table.entries[idle_slot].last_seen {
				idle_slot = index
			}
			if work_bucket_is_full(&entry.bucket, limits.attempts_per_second, limits.burst, now) {
				if full_idle_slot < 0 || entry.last_seen < table.entries[full_idle_slot].last_seen {
					full_idle_slot = index
				}
			}
		}
	}
	if full_idle_slot >= 0 {
		return full_idle_slot
	}
	if idle_slot >= 0 {
		return idle_slot
	}
	return oldest_slot
}

// source_budget_take admits or refuses one new-connection Initial attempt from
// address under the per-/24 token bucket and active handshake limit.
//
// Pass active_handshakes >= 0 when the caller tracks exact live handshakes
// externally (such as Server.records), or -1 to use the entry's tracked count.
// Backwards timestamps and invalid limits are refused without mutating table.
source_budget_take :: proc "contextless" (
	table: ^Source_Budget_Table,
	address: u32,
	limits: Source_Budget_Limits,
	now: u64,
	active_handshakes: int = -1,
) -> Source_Budget_Result {
	if table == nil || !source_budget_limits_valid(limits) {
		return .Invalid_Limits
	}
	if table.has_time && now < table.last_time {
		return .Backwards_Time
	}
	prefix := source_range_prefix(address)
	place := source_budget_find(table, prefix)
	if place >= 0 {
		entry := &table.entries[place]
		current_handshakes := active_handshakes >= 0 ? active_handshakes : entry.active_handshakes
		entry.last_seen = now
		table.has_time = true
		table.last_time = now
		if current_handshakes >= limits.active_handshakes_limit {
			return .Over_Handshake_Limit
		}
		if !work_bucket_take(&entry.bucket, limits.attempts_per_second, limits.burst, now) {
			return .Over_Rate_Budget
		}
		return .Admitted
	}
	if active_handshakes >= limits.active_handshakes_limit {
		table.has_time = true
		table.last_time = now
		return .Over_Handshake_Limit
	}
	slot := source_budget_evict_slot(table, limits, now)
	if table.entries[slot].used {
		table.evictions += 1
	}
	table.entries[slot] = {used = true, prefix = prefix, last_seen = now}
	table.has_time = true
	table.last_time = now
	if !work_bucket_take(&table.entries[slot].bucket, limits.attempts_per_second, limits.burst, now) {
		return .Over_Rate_Budget
	}
	return .Admitted
}

// source_budget_handshake_begin checks the per-/24 budget and active handshake
// limit, and on admission increments the range's active handshake count.
source_budget_handshake_begin :: proc "contextless" (
	table: ^Source_Budget_Table,
	address: u32,
	limits: Source_Budget_Limits,
	now: u64,
) -> Source_Budget_Result {
	result := source_budget_take(table, address, limits, now)
	if result != .Admitted {
		return result
	}
	place := source_budget_find(table, source_range_prefix(address))
	if place >= 0 {
		table.entries[place].active_handshakes += 1
	}
	return .Admitted
}

// source_budget_handshake_end releases one active handshake for the /24 range
// of address. Returns false if the range is absent or already at zero.
source_budget_handshake_end :: proc "contextless" (table: ^Source_Budget_Table, address: u32) -> bool {
	if table == nil {
		return false
	}
	place := source_budget_find(table, source_range_prefix(address))
	if place < 0 || table.entries[place].active_handshakes <= 0 {
		return false
	}
	table.entries[place].active_handshakes -= 1
	return true
}

// source_budget_active_handshakes returns the tracked active handshake count
// for the /24 range of address, or 0 if not present.
source_budget_active_handshakes :: proc "contextless" (table: ^Source_Budget_Table, address: u32) -> int {
	if table == nil {
		return 0
	}
	place := source_budget_find(table, source_range_prefix(address))
	if place < 0 {
		return 0
	}
	return table.entries[place].active_handshakes
}
