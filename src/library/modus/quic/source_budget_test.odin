#+build !freestanding
package quic

import "core:testing"

// Adversarial unit tests for invalid limits, nil table, and backwards
// timestamps: every refusal must leave table state completely unchanged.
@(test)
source_budget_refuses_invalid_limits_and_backwards_time_without_mutation :: proc(t: ^testing.T) {
	valid_limits := Source_Budget_Limits{attempts_per_second = 10, burst = 4, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH}
	testing.expect_value(t, source_budget_take(nil, 0x0A00_0101, valid_limits, 1_000_000), Source_Budget_Result.Invalid_Limits)
	testing.expect(t, !source_budget_handshake_end(nil, 0x0A00_0101))
	testing.expect_value(t, source_budget_active_handshakes(nil, 0x0A00_0101), 0)

	table: Source_Budget_Table
	source_budget_table_init(&table)
	invalid_cases := [?]Source_Budget_Limits {
		{attempts_per_second = 10, burst = 0, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH},
		{attempts_per_second = 10, burst = -1, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH},
		{attempts_per_second = -1, burst = 4, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH},
		{attempts_per_second = 10, burst = 4, active_handshakes_limit = 0},
		{attempts_per_second = 10, burst = 4, active_handshakes_limit = -5},
		{attempts_per_second = 10, burst = 4, active_handshakes_limit = 2, prefix_length = 0},
		{attempts_per_second = 10, burst = 4, active_handshakes_limit = 2, prefix_length = 33},
		{attempts_per_second = 10, burst = 4, active_handshakes_limit = 2, prefix_length = 255},
	}
	for bad in invalid_cases {
		before := table
		testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, bad, 1_000_000), Source_Budget_Result.Invalid_Limits)
		testing.expect(t, table == before)
	}

	// Admit one attempt at t = 1_000_000, then refuse backwards timestamps
	// without mutating any slot, bucket level, eviction count, or watermark.
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, valid_limits, 1_000_000), Source_Budget_Result.Admitted)
	snapshot := table
	backwards_times := [?]u64{0, 1, 999_999}
	for past in backwards_times {
		testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, valid_limits, past), Source_Budget_Result.Backwards_Time)
		testing.expect(t, table == snapshot)
		testing.expect_value(t, source_budget_take(&table, 0x0A00_0205, valid_limits, past), Source_Budget_Result.Backwards_Time)
		testing.expect(t, table == snapshot)
	}
}

// Per-/24 isolation, refill after monotonic time advance, and active handshake
// bounds: flooding 10.0.1.x exhausts only 10.0.1.0/24 while 10.0.2.5 and
// 192.168.1.10 stay completely unaffected.
@(test)
source_budget_isolates_flooding_range_and_refills_monotonically :: proc(t: ^testing.T) {
	table: Source_Budget_Table
	source_budget_table_init(&table)
	limits := Source_Budget_Limits{attempts_per_second = 2, burst = 5, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH}
	now: u64 = 10_000_000

	// Prefix masking checks: edges 0, 1, 255, and max u32.
	testing.expect_value(t, source_range_prefix(0x0A00_0100, SOURCE_RANGE_PREFIX_LENGTH), u32(0x0A00_0100))
	testing.expect_value(t, source_range_prefix(0x0A00_0101, SOURCE_RANGE_PREFIX_LENGTH), u32(0x0A00_0100))
	testing.expect_value(t, source_range_prefix(0x0A00_01FF, SOURCE_RANGE_PREFIX_LENGTH), u32(0x0A00_0100))
	testing.expect_value(t, source_range_prefix(max(u32), SOURCE_RANGE_PREFIX_LENGTH), u32(0xFFFF_FF00))

	// Five attempts from distinct hosts in 10.0.1.0/24 spend the burst.
	for host in 1 ..= 5 {
		testing.expect_value(t, source_budget_take(&table, u32(0x0A00_0100 + host), limits, now), Source_Budget_Result.Admitted)
	}
	// The 6th through 120th attempts from 10.0.1.0/24 are all dropped.
	for host in 6 ..= 120 {
		testing.expect_value(t, source_budget_take(&table, u32(0x0A00_0100 + host), limits, now), Source_Budget_Result.Over_Rate_Budget)
	}

	// Legitimate clients from other /24 ranges are immediately admitted.
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0205, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0xC0A8_010A, limits, now), Source_Budget_Result.Admitted)

	// Advancing monotonic time by 1 second refills 2 units (rate = 2/s).
	now += 1_000_000
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0102, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0103, limits, now), Source_Budget_Result.Over_Rate_Budget)

	// Active handshake cap: 2 concurrent handshakes for 10.0.2.0/24 succeed,
	// the 3rd is refused with Over_Handshake_Limit, and ending one restores admission.
	now += 5_000_000
	testing.expect_value(t, source_budget_handshake_begin(&table, 0x0A00_0201, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_handshake_begin(&table, 0x0A00_0202, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_active_handshakes(&table, 0x0A00_0299), 2)
	testing.expect_value(t, source_budget_handshake_begin(&table, 0x0A00_0203, limits, now), Source_Budget_Result.Over_Handshake_Limit)
	testing.expect(t, source_budget_handshake_end(&table, 0x0A00_0201))
	testing.expect_value(t, source_budget_active_handshakes(&table, 0x0A00_0201), 1)
	testing.expect_value(t, source_budget_handshake_begin(&table, 0x0A00_0203, limits, now), Source_Budget_Result.Admitted)
	testing.expect(t, source_budget_handshake_end(&table, 0x0A00_0202))
	testing.expect(t, source_budget_handshake_end(&table, 0x0A00_0203))
	testing.expect(t, !source_budget_handshake_end(&table, 0x0A00_0203))
	testing.expect(t, !source_budget_handshake_end(&table, 0x0A00_9901))
}

// Filling all 64 buckets and inserting a 65th+ distinct /24 range evicts the
// oldest idle bucket cleanly without panic, corruption, or losing an actively
// flooding hot /24 range.
@(test)
source_budget_full_table_evicts_oldest_cleanly :: proc(t: ^testing.T) {
	table: Source_Budget_Table
	source_budget_table_init(&table)
	limits := Source_Budget_Limits{attempts_per_second = 1, burst = 2, active_handshakes_limit = 2, prefix_length = SOURCE_RANGE_PREFIX_LENGTH}
	now: u64 = 1_000_000

	// Exhaust 10.0.1.0/24 so it is actively throttled.
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0102, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0103, limits, now), Source_Budget_Result.Over_Rate_Budget)

	// Fill the remaining 63 slots with distinct /24 ranges at increasing times,
	// while keeping 10.0.1.0/24 hot.
	for range_index in 1 ..< SOURCE_BUDGET_CAPACITY {
		now += 100
		address := u32(0x0B00_0001) + (u32(range_index) << 8)
		testing.expect_value(t, source_budget_take(&table, address, limits, now), Source_Budget_Result.Admitted)
	}
	testing.expect_value(t, table.evictions, u64(0))

	// Touch 10.0.1.0/24 so it is the most recently seen entry.
	now += 100
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0104, limits, now), Source_Budget_Result.Over_Rate_Budget)

	// While all 64 slots hold non-full buckets, a 65th /24 is refused with
	// Table_Full instead of evicting throttled ranges.
	now += 100
	testing.expect_value(t, source_budget_take(&table, 0x0C00_0001, limits, now), Source_Budget_Result.Table_Full)
	testing.expect_value(t, table.evictions, u64(0))

	// Advance past refill (2 s > 2/1 s burst) so idle entries refill to full,
	// while draining 10.0.1.0/24 so it stays throttled and un-evictable.
	now += 2_000_000
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0101, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0102, limits, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A00_0103, limits, now), Source_Budget_Result.Over_Rate_Budget)

	// Now insert 32 more distinct /24 ranges: each evicts a full idle slot
	// cleanly while keeping 10.0.1.0/24 throttled.
	for extra in 0 ..< 32 {
		now += 100
		address := u32(0x0C00_0001) + (u32(extra) << 8)
		testing.expect_value(t, source_budget_take(&table, address, limits, now), Source_Budget_Result.Admitted)
		testing.expect_value(t, source_budget_take(&table, 0x0A00_0105, limits, now), Source_Budget_Result.Over_Rate_Budget)
	}
	testing.expect_value(t, table.evictions, u64(32))

	// No duplicate /24 prefixes exist in the table after evictions.
	for first in 0 ..< SOURCE_BUDGET_CAPACITY {
		testing.expect(t, table.entries[first].used)
		for second in first + 1 ..< SOURCE_BUDGET_CAPACITY {
			testing.expect(t, table.entries[first].prefix != table.entries[second].prefix)
		}
	}
}

// End-to-end QUIC Server flood test: 150 new Initial packets from 10.0.1.x
// exhaust 10.0.1.0/24's per-range budget and drop excess attempts, while
// legitimate clients from 10.0.2.5 and 192.168.1.10 connect and echo
// immediately with zero shared-budget exhaustion.
@(test)
server_source_range_flood_drops_flooder_while_other_ranges_connect :: proc(t: ^testing.T) {
	harness := harness_make(2)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))

	// Place the two legitimate clients on distinct /24 subnets outside 10.0.1.0/24.
	harness.client_remotes[0] = {0x0A00_0205, 51_000} // 10.0.2.5
	harness.client_remotes[1] = {0xC0A8_010A, 51_001} // 192.168.1.10

	// Flood 150 Initial packets from 150 distinct hosts in 10.0.1.0/24 at one instant.
	state: u64 = 0x5155_4943_464C_4F44
	for host in 1 ..= 150 {
		forged := forged_initial(&state)
		remote := Remote{u32(0x0A00_0100 + host), u16(40_000 + host)}
		outcome := harness_server_receive(harness, remote, forged[:])
		testing.expect(t, outcome.record < 0 && outcome.release_remote)
	}

	burst := u64(SERVER_LIMITS_DEFAULT.source_range_burst)
	testing.expect_value(t, harness.server.counters.retries, burst)
	testing.expect_value(t, harness.server.counters.over_source_budget, u64(150) - burst)
	testing.expect_value(t, harness.server.counters.over_budget, u64(0))
	testing.expect_value(t, harness.server.counters.authenticity_checks, u64(0))

	// Both legitimate clients on 10.0.2.5 and 192.168.1.10 connect immediately
	// and complete their echo while 10.0.1.0/24 is still exhausted.
	start := harness.now
	ended := harness_run(t, harness, 4096, 10_000_000)
	testing.expectf(t, ended == 2, "%d clients ended their echo, not 2; %s", ended, harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 2, "%s", harness_describe(harness))
	testing.expectf(t, harness.now - start < 1_000_000, "legitimate clients took %d us; %s", harness.now - start, harness_describe(harness))
}

// End-to-end QUIC Server active handshake cap per /24: four distinct hosts in
// 10.0.1.0/24 holding half-open handshakes fill 10.0.1.0/24's per-range
// handshake limit and block a 5th host in 10.0.1.0/24, while 10.0.2.5 still
// connects immediately.
@(test)
server_source_range_handshake_cap_blocks_same_range_and_admits_other_range :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	harness.client_remotes[0] = {0x0A00_0205, 52_000} // 10.0.2.5

	cap := SERVER_LIMITS_DEFAULT.handshakes_per_source_range
	for index in 0 ..< cap {
		remote := Remote{u32(0x0A00_0101 + index), u16(41_000 + index)}
		identifier := [CONNECTION_ID_SIZE]u8{0xA1, u8(index), 0x10, 0x20, 0x30, 0x40, 0x50, 0x60}
		token, retry_source, has_retry := retry_of(harness, remote, identifier)
		if !testing.expectf(t, has_retry, "no retry for %d; %s", index, harness_describe(harness)) {
			return
		}
		initial := authentic_initial(&harness.cryptography, retry_source, token[:])
		answer: [MAX_DATAGRAM_SIZE]u8
		outcome := server_datagram_receive(&harness.server, initial[:], remote, answer[:], harness.now)
		testing.expectf(t, outcome.record >= 0, "handshake %d not admitted; %s", index, harness_describe(harness))
	}

	// A 5th distinct host in 10.0.1.0/24 is refused by the per-range handshake cap.
	fifth := Remote{u32(0x0A00_0101 + cap), 41_100}
	fifth_initial := authentic_initial(&harness.cryptography, {0xA2, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07})
	answer: [MAX_DATAGRAM_SIZE]u8
	refused := server_datagram_receive(&harness.server, fifth_initial[:], fifth, answer[:], harness.now)
	testing.expect(t, refused.record < 0 && refused.answer_length == 0)
	testing.expect(t, harness.server.counters.refused_source_handshake_limit > 0)

	// Meanwhile 10.0.2.5 connects and completes its echo immediately.
	ended := harness_run(t, harness, 4096, 10_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
}

// The prefix length names the range: on a /16, two /24 of one /16 share one
// bucket, and an address of another /16 has its own; on a /32, each address
// is its own range. The table holds at least 1024 ranges.
@(test)
source_ranges_follow_their_prefix_length :: proc(t: ^testing.T) {
	testing.expect(t, SOURCE_BUDGET_CAPACITY >= 1024)
	testing.expect_value(t, source_range_prefix(0x0A01_0203, 16), u32(0x0A01_0000))
	testing.expect_value(t, source_range_prefix(0x0A01_0203, 32), u32(0x0A01_0203))
	testing.expect_value(t, source_range_prefix(0x0A01_0203, 1), u32(0x0000_0000))
	testing.expect_value(t, source_range_prefix(0x8A01_0203, 1), u32(0x8000_0000))
	table: Source_Budget_Table
	source_budget_table_init(&table)
	wide := Source_Budget_Limits{attempts_per_second = 1, burst = 2, active_handshakes_limit = 4, prefix_length = 16}
	now := u64(1_000_000)
	testing.expect_value(t, source_budget_take(&table, 0x0A01_0101, wide, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A01_0201, wide, now), Source_Budget_Result.Admitted)
	testing.expect_value(t, source_budget_take(&table, 0x0A01_0301, wide, now), Source_Budget_Result.Over_Rate_Budget)
	testing.expect_value(t, source_budget_take(&table, 0x0A02_0101, wide, now), Source_Budget_Result.Admitted)
	narrow := wide
	narrow.prefix_length = 32
	narrow_table: Source_Budget_Table
	source_budget_table_init(&narrow_table)
	for host in u32(0) ..< 3 {
		testing.expect_value(t, source_budget_take(&narrow_table, 0x0A01_0100 + host, narrow, now), Source_Budget_Result.Admitted)
		testing.expect_value(t, source_budget_take(&narrow_table, 0x0A01_0100 + host, narrow, now), Source_Budget_Result.Admitted)
		testing.expect_value(t, source_budget_take(&narrow_table, 0x0A01_0100 + host, narrow, now), Source_Budget_Result.Over_Rate_Budget)
	}
}
