package quic

// Per-source-range admission budgets for new QUIC connections.
//
// A flood of Initial packets from one source range (an IPv4 prefix of
// prefix_length bits, /24 by default) must spend only that range's budget,
// leaving other ranges free to connect without delay. Each range has a
// continuous token bucket (burst and per-second refill) and an active
// handshake cap, stored in a bounded table with zero heap allocations: a
// new range takes a free slot or the least recently seen slot whose bucket
// refilled and that holds no handshake, so the table follows the ranges
// that are active and forgets the others. The stack of the system carries
// IPv4 only (quic.Remote holds a 32-bit address); an IPv6 source would
// group by its /64 with the same table.

// The ranges tracked at once: a busy server sees clients from many
// networks, and a range that the table forgot gets a fresh bucket, which is
// the state of a new range anyway. A slot is 48 bytes, so the table is 48
// KiB in the server record.
SOURCE_BUDGET_CAPACITY :: 1024

// The prefix length of a source range by default: the /24 of an IPv4
// network, the range of one site or one provider block.
SOURCE_RANGE_PREFIX_LENGTH :: 24

// The admission limits for one source range.
Source_Budget_Limits :: struct {
	attempts_per_second:     int, // Continuous token refill rate per second for one source range.
	burst:                   int, // Maximum burst of new-connection Initial attempts for one source range.
	active_handshakes_limit: int, // Maximum concurrent connections in the handshake for one source range.
	prefix_length:           u8, // The bits of the address that name a source range: 1 to 32.
}

// One slot of the per-source-range budget table.
Source_Budget_Entry :: struct {
	used:              bool,        // false: the slot is empty.
	prefix:            u32,         // The prefix of the range: the address with its bits past prefix_length cleared.
	bucket:            Work_Bucket, // Token bucket for this range.
	last_seen:         u64,         // Monotonic timestamp in microseconds of the last attempt for LRU eviction.
	active_handshakes: int,         // Count of active handshakes tracked for standalone callers.
}

// Bounded, zero-allocation table of the budgets of the source ranges.
Source_Budget_Table :: struct {
	entries:   [SOURCE_BUDGET_CAPACITY]Source_Budget_Entry,
	has_time:  bool, // true after the first accepted timestamp.
	last_time: u64,  // Highest monotonic timestamp observed, in microseconds.
	evictions: u64,  // Count of occupied slots evicted when the table was full.
}

// Outcome of one per-source-range admission check.
Source_Budget_Result :: enum u8 {
	Admitted             = 0, // The attempt passed the active handshake cap and spent one unit from the bucket of its range.
	Over_Rate_Budget     = 1, // The bucket of the range held less than one unit; the attempt is dropped.
	Over_Handshake_Limit = 2, // The range already holds its maximum concurrent handshakes.
	Backwards_Time       = 3, // The timestamp moved backwards relative to the table clock; nothing changed.
	Invalid_Limits       = 4, // The supplied limits are outside their valid bounds; nothing changed.
	Table_Full           = 5, // Each slot holds active handshakes or a non-full bucket; new prefix refused.
}

// source_range_prefix returns the prefix of the source range of an address:
// its first prefix_length bits. A length of 0 or past 32 gives the address
// whole; source_budget_limits_valid refuses such limits first.
source_range_prefix :: proc "contextless" (address: u32, prefix_length: u8) -> u32 {
	if prefix_length == 0 || prefix_length >= 32 {
		return address
	}
	return address & (~u32(0) << (32 - u32(prefix_length)))
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
// Largest burst whose token capacity cannot overflow u64 addition during refill.
SOURCE_BUDGET_BURST_MOST :: int(max(u64) / (2 * WORK_UNIT))

source_budget_limits_valid :: proc "contextless" (limits: Source_Budget_Limits) -> bool {
	return limits.burst > 0 && limits.burst <= SOURCE_BUDGET_BURST_MOST && limits.attempts_per_second >= 0 && limits.active_handshakes_limit > 0 && limits.prefix_length >= 1 && limits.prefix_length <= 32
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

// source_budget_evict_slot selects an empty slot or the oldest full idle slot
// (active_handshakes == 0 and refilled to burst). Never evicts an active or
// non-full throttled bucket, returning -1 so a spoofing attacker cannot reset
// throttled ranges or corrupt active-handshake counts.
@(private)
source_budget_evict_slot :: proc "contextless" (table: ^Source_Budget_Table, limits: Source_Budget_Limits, now: u64) -> int {
	full_idle_slot := -1
	for &entry, index in table.entries {
		if !entry.used {
			return index
		}
		if entry.active_handshakes == 0 && work_bucket_is_full(&entry.bucket, limits.attempts_per_second, limits.burst, now) {
			if full_idle_slot < 0 || entry.last_seen < table.entries[full_idle_slot].last_seen {
				full_idle_slot = index
			}
		}
	}
	return full_idle_slot
}

// source_budget_take admits or refuses one new-connection Initial attempt from
// address under the token bucket and the active handshake limit of its range.
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
	prefix := source_range_prefix(address, limits.prefix_length)
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
	if slot < 0 {
		table.has_time = true
		table.last_time = now
		return .Table_Full
	}
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

// source_budget_handshake_begin checks the budget of the range and the active handshake
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
	place := source_budget_find(table, source_range_prefix(address, limits.prefix_length))
	if place >= 0 {
		table.entries[place].active_handshakes += 1
	}
	return .Admitted
}

// source_budget_handshake_end releases one active handshake for the source
// range of address. Returns false if the range is absent or already at zero.
source_budget_handshake_end :: proc "contextless" (table: ^Source_Budget_Table, address: u32, prefix_length: u8 = SOURCE_RANGE_PREFIX_LENGTH) -> bool {
	if table == nil {
		return false
	}
	place := source_budget_find(table, source_range_prefix(address, prefix_length))
	if place < 0 || table.entries[place].active_handshakes <= 0 {
		return false
	}
	table.entries[place].active_handshakes -= 1
	return true
}

// source_budget_active_handshakes returns the tracked active handshake count
// for the source range of address, or 0 if not present.
source_budget_active_handshakes :: proc "contextless" (table: ^Source_Budget_Table, address: u32, prefix_length: u8 = SOURCE_RANGE_PREFIX_LENGTH) -> int {
	if table == nil {
		return 0
	}
	place := source_budget_find(table, source_range_prefix(address, prefix_length))
	if place < 0 {
		return 0
	}
	return table.entries[place].active_handshakes
}
