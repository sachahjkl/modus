#+build !freestanding
package collector_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/wide_grants"

// chain_of_four fills a collector of capacity 8 with four valid records.
@(private = "file")
chain_of_four :: proc(t: ^testing.T, collector: ^Act_Collector) {
	testing.expect(t, collector_init(collector, 8))
	_, first := collector_append(collector, 1, 100, .Grant_Started, 0, 1, 2)
	_, second := collector_append(collector, 1, 110, .Frame_Read, 10)
	_, third := collector_append(collector, 2, 120, .Key_Injected, 20, 'a', 0)
	_, fourth := collector_append(collector, 2, 130, .Pointer_Clicked, 20)
	testing.expect(t, first == .None && second == .None && third == .None && fourth == .None, "four valid records append")
	refusal, _ := collector_verify(collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.None)
}

@(test)
test_collector_verify_finds_a_resealed_record_by_its_successor :: proc(t: ^testing.T) {
	collector: Act_Collector
	chain_of_four(t, &collector)

	// A changed record with a fresh hash of its own: the record is whole, and
	// the next record names the old hash, so the break is at the next index.
	collector.records[1].detail_word_0 = 0xBAD
	testing.expect_value(t, wide_grants.act_record_seal(&collector.records[1]), wide_grants.Wide_Grant_Refusal.None)
	refusal, index := collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(2))
}

@(test)
test_collector_verify_finds_a_resealed_last_record_by_the_head :: proc(t: ^testing.T) {
	collector: Act_Collector
	chain_of_four(t, &collector)

	// The last record has no successor: the head hash is the one witness.
	collector.records[3].target_window_id = 21
	testing.expect_value(t, wide_grants.act_record_seal(&collector.records[3]), wide_grants.Wide_Grant_Refusal.None)
	refusal, index := collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(3))
}

@(test)
test_collector_verify_finds_dropped_swapped_and_reordered_records :: proc(t: ^testing.T) {
	collector: Act_Collector

	// The last record dropped from the count only: the sequence counter differs.
	chain_of_four(t, &collector)
	collector.count = 3
	refusal, index := collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(3))

	// The last record dropped from the count and the sequence counter: the
	// head hash names the dropped record.
	chain_of_four(t, &collector)
	collector.count = 3
	collector.next_sequence = 3
	refusal, index = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(2))

	// Two records swapped.
	chain_of_four(t, &collector)
	collector.records[1], collector.records[2] = collector.records[2], collector.records[1]
	refusal, index = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(1))

	// A record moved back in time and resealed: the timestamps go backwards.
	chain_of_four(t, &collector)
	collector.records[2].timestamp_ms = 50
	_ = wide_grants.act_record_seal(&collector.records[2])
	refusal, index = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(2))

	// A first record that does not start from the genesis hash.
	chain_of_four(t, &collector)
	collector.records[0].previous_hash = blake3.hash(transmute([]u8)string("not genesis"))
	refusal, index = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(0))
}

@(test)
test_collector_verify_refuses_counts_past_their_bounds :: proc(t: ^testing.T) {
	collector: Act_Collector

	// A count past the capacity, and a capacity past the bound of the table.
	chain_of_four(t, &collector)
	collector.count = collector.capacity + 1
	refusal, index := collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(collector.capacity + 1))

	chain_of_four(t, &collector)
	collector.capacity = COLLECTOR_ACT_CAPACITY + 1
	refusal, _ = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	// An empty collector whose head hash is not the genesis hash.
	testing.expect(t, collector_init(&collector, 8))
	collector.head_hash = blake3.hash(transmute([]u8)string("forged head"))
	refusal, index = collector_verify(&collector)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(0))
}

@(test)
test_manager_verify_chain_fails_closed_and_counts_each_call :: proc(t: ^testing.T) {
	manager := new(Wide_Grant_Manager)
	defer free(manager)

	// A manager that was never initialized verifies nothing.
	refusal, _ := manager_verify_chain(manager)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	authority_key := blake3.hash(transmute([]u8)string("unlock-authority-key"))
	testing.expect(t, !manager_init(manager, 1, authority_key, {}, 0), "a collector of capacity 0 is refused")
	testing.expect(t, !manager_init(manager, 1, {}, {}, 8), "the all-zero authority key is refused")
	refusal, _ = manager_verify_chain(manager)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	testing.expect(t, manager_init(manager, 1, authority_key, {}, 8))
	refusal, _ = manager_verify_chain(manager)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, manager.collector.verify_calls, u64(1))

	_, appended := collector_append(&manager.collector, 1, 100, .Grant_Started, 0)
	testing.expect_value(t, appended, wide_grants.Wide_Grant_Refusal.None)
	manager.collector.records[0].detail_word_1 ~= 1
	index: u64
	refusal, index = manager_verify_chain(manager)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, index, u64(0))
	testing.expect_value(t, manager.collector.verify_calls, u64(2))
}
