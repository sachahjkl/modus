#+build !freestanding
package grant_policy

import "core:testing"

@(private = "file")
make_signer_key :: proc(seed: u8) -> Signer_Key {
	key: Signer_Key
	for i in 0 ..< SIGNER_KEY_BYTES {
		key[i] = seed + u8(i) + 1
	}
	return key
}

@(test)
enum_word_borders_refuse_unknown_members :: proc(t: ^testing.T) {
	class, ok := grant_class_of_word(u64(Grant_Class.Store))
	testing.expect(t, ok)
	testing.expect_value(t, class, Grant_Class.Store)

	class, ok = grant_class_of_word(u64(Grant_Class.Wide_Agent))
	testing.expect(t, ok)
	testing.expect_value(t, class, Grant_Class.Wide_Agent)

	_, bad_class_high := grant_class_of_word(u64(Grant_Class.Wide_Agent) + 1)
	testing.expect(t, !bad_class_high)
	_, bad_class_max := grant_class_of_word(max(u64))
	testing.expect(t, !bad_class_max)

	refusal, r_ok := grant_policy_refusal_of_word(u64(Grant_Policy_Refusal.Not_Found))
	testing.expect(t, r_ok)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Not_Found)

	_, bad_ref_high := grant_policy_refusal_of_word(u64(Grant_Policy_Refusal.Not_Found) + 1)
	testing.expect(t, !bad_ref_high)
	_, bad_ref_max := grant_policy_refusal_of_word(max(u64))
	testing.expect(t, !bad_ref_max)
}

@(test)
timed_grant_boundaries_caps_and_overflow :: proc(t: ^testing.T) {
	// Overflow wrap is refused on every edge.
	term, refusal := timed_grant_create(max(u64), 1, 0)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, term, Timed_Grant_Term{})

	term, refusal = timed_grant_create(1, max(u64), 0)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, term, Timed_Grant_Term{})

	term, refusal = timed_grant_create(max(u64) - 5, 6, 0)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, term, Timed_Grant_Term{})

	// Exact max(u64) sum without overflow succeeds.
	term, refusal = timed_grant_create(max(u64) - 5, 5, 0)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.None)
	testing.expect_value(t, term.granted_at_ms, max(u64) - 5)
	testing.expect_value(t, term.expires_at_ms, max(u64))
	testing.expect(t, !grant_is_expired(term, max(u64) - 1))
	testing.expect_value(t, grant_remaining_ms(term, max(u64) - 1), u64(1))
	testing.expect(t, grant_is_expired(term, max(u64)))
	testing.expect_value(t, grant_remaining_ms(term, max(u64)), u64(0))

	// Permanent grant refused when a cap is active, allowed when uncapped.
	term, refusal = timed_grant_create(100, 0, 1)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Duration_Past_Cap)
	testing.expect_value(t, term, Timed_Grant_Term{})

	term, refusal = timed_grant_create(100, 0, 0)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.None)
	testing.expect_value(t, term.granted_at_ms, u64(100))
	testing.expect_value(t, term.expires_at_ms, u64(0))
	testing.expect(t, !grant_is_expired(term, 0))
	testing.expect(t, !grant_is_expired(term, max(u64)))
	testing.expect_value(t, grant_remaining_ms(term, 0), max(u64))
	testing.expect_value(t, grant_remaining_ms(term, max(u64)), max(u64))

	// Exact cap accepted; one past cap refused.
	term, refusal = timed_grant_create(500, 1000, 1000)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.None)
	testing.expect_value(t, term.expires_at_ms, u64(1500))
	testing.expect(t, !grant_is_expired(term, 1499))
	testing.expect_value(t, grant_remaining_ms(term, 1499), u64(1))
	testing.expect(t, grant_is_expired(term, 1500))
	testing.expect_value(t, grant_remaining_ms(term, 1500), u64(0))
	testing.expect(t, grant_is_expired(term, 1501))
	testing.expect_value(t, grant_remaining_ms(term, 1501), u64(0))

	_, refusal = timed_grant_create(500, 1001, 1000)
	testing.expect_value(t, refusal, Grant_Policy_Refusal.Duration_Past_Cap)
}

@(test)
quota_charge_refuses_overflow_and_over_limit_without_mutation :: proc(t: ^testing.T) {
	// Nil pointer refused.
	testing.expect_value(t, quota_charge(nil, 1), Grant_Policy_Refusal.Bad_Value)

	// Bounded quota: 0, partial, exact limit, and limit+1.
	q := Grant_Quota{limit = 100, used = 0}
	testing.expect_value(t, quota_remaining(q), u64(100))
	testing.expect_value(t, quota_charge(&q, 0), Grant_Policy_Refusal.None)
	testing.expect_value(t, q.used, u64(0))

	testing.expect_value(t, quota_charge(&q, 101), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, q.used, u64(0))

	testing.expect_value(t, quota_charge(&q, max(u64)), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, q.used, u64(0))

	testing.expect_value(t, quota_charge(&q, 60), Grant_Policy_Refusal.None)
	testing.expect_value(t, q.used, u64(60))
	testing.expect_value(t, quota_remaining(q), u64(40))

	testing.expect_value(t, quota_charge(&q, 41), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, q.used, u64(60))

	testing.expect_value(t, quota_charge(&q, 40), Grant_Policy_Refusal.None)
	testing.expect_value(t, q.used, u64(100))
	testing.expect_value(t, quota_remaining(q), u64(0))

	testing.expect_value(t, quota_charge(&q, 1), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, q.used, u64(100))

	// Zero charge at exact limit succeeds; corrupted used > limit refuses even zero.
	testing.expect_value(t, quota_charge(&q, 0), Grant_Policy_Refusal.None)
	over := Grant_Quota{limit = 10, used = 15}
	testing.expect_value(t, quota_remaining(over), u64(0))
	testing.expect_value(t, quota_charge(&over, 0), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, over.used, u64(15))

	// Uncapped quota (limit == 0) still refuses u64 wrap without mutating used.
	uncapped := Grant_Quota{limit = 0, used = max(u64) - 10}
	testing.expect_value(t, quota_remaining(uncapped), max(u64))
	testing.expect_value(t, quota_charge(&uncapped, 11), Grant_Policy_Refusal.Quota_Exceeded)
	testing.expect_value(t, uncapped.used, max(u64) - 10)
	testing.expect_value(t, quota_charge(&uncapped, 10), Grant_Policy_Refusal.None)
	testing.expect_value(t, uncapped.used, max(u64))
}

@(test)
machine_policy_signer_allowlist_and_capacity :: proc(t: ^testing.T) {
	zero_key: Signer_Key
	k1 := make_signer_key(1)
	k2 := make_signer_key(50)

	// Nil policy and zero keys are always refused.
	testing.expect_value(t, policy_signer_allowed(nil, k1), Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, policy_add_allowed_signer(nil, k1), Grant_Policy_Refusal.Bad_Value)

	policy: Machine_Grant_Policy
	testing.expect_value(t, policy_signer_allowed(&policy, zero_key), Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, policy_add_allowed_signer(&policy, zero_key), Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, policy.allowed_signer_count, u8(0))
	testing.expect(t, !policy.signer_lock_active)

	// Unlocked empty policy allows any non-zero signer key.
	testing.expect_value(t, policy_signer_allowed(&policy, k1), Grant_Policy_Refusal.None)

	// Locked empty allowlist refuses every signer key.
	locked_empty := Machine_Grant_Policy{signer_lock_active = true}
	testing.expect_value(t, policy_signer_allowed(&locked_empty, k1), Grant_Policy_Refusal.Signer_Not_Allowed)

	// Enrolling k1 activates the lock and refuses k2.
	testing.expect_value(t, policy_add_allowed_signer(&policy, k1), Grant_Policy_Refusal.None)
	testing.expect(t, policy.signer_lock_active)
	testing.expect_value(t, policy.allowed_signer_count, u8(1))
	testing.expect_value(t, policy_signer_allowed(&policy, k1), Grant_Policy_Refusal.None)
	testing.expect_value(t, policy_signer_allowed(&policy, k2), Grant_Policy_Refusal.Signer_Not_Allowed)

	// Duplicate enrollment is idempotent and does not consume another slot.
	testing.expect_value(t, policy_add_allowed_signer(&policy, k1), Grant_Policy_Refusal.None)
	testing.expect_value(t, policy.allowed_signer_count, u8(1))

	// Fill up to ALLOWED_SIGNER_CAPACITY, then verify capacity+1 is refused without mutation.
	for i in 1 ..< ALLOWED_SIGNER_CAPACITY {
		key := make_signer_key(u8(i + 1))
		testing.expect_value(t, policy_add_allowed_signer(&policy, key), Grant_Policy_Refusal.None)
	}
	testing.expect_value(t, int(policy.allowed_signer_count), ALLOWED_SIGNER_CAPACITY)

	overflow_key := make_signer_key(200)
	testing.expect_value(t, policy_add_allowed_signer(&policy, overflow_key), Grant_Policy_Refusal.Capacity_Full)
	testing.expect_value(t, int(policy.allowed_signer_count), ALLOWED_SIGNER_CAPACITY)
	testing.expect_value(t, policy_signer_allowed(&policy, overflow_key), Grant_Policy_Refusal.Signer_Not_Allowed)

	// Corrupted allowed_signer_count past ALLOWED_SIGNER_CAPACITY is refused.
	corrupt := Machine_Grant_Policy{allowed_signer_count = ALLOWED_SIGNER_CAPACITY + 1}
	testing.expect_value(t, policy_signer_allowed(&corrupt, k1), Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, policy_add_allowed_signer(&corrupt, k1), Grant_Policy_Refusal.Bad_Value)
}

@(test)
machine_policy_grant_class_locks_and_duration_caps :: proc(t: ^testing.T) {
	_, nil_ref := policy_grant_allowed(nil, .Store, 10, 100)
	testing.expect_value(t, nil_ref, Grant_Policy_Refusal.Bad_Value)

	policy: Machine_Grant_Policy
	policy.locked_classes = {.Device}
	policy.max_duration_ms[.Network] = 30_000
	policy.max_duration_ms[.Wide_Agent] = 60_000

	// Unknown enum value at the border is refused without out-of-bounds indexing.
	_, bad_enum_ref := policy_grant_allowed(&policy, Grant_Class(99), 10, 100)
	testing.expect_value(t, bad_enum_ref, Grant_Policy_Refusal.Bad_Value)

	// Locked class refuses both permanent and finite durations.
	_, lock_ref := policy_grant_allowed(&policy, .Device, 10, 0)
	testing.expect_value(t, lock_ref, Grant_Policy_Refusal.Grant_Class_Locked)
	_, lock_ref = policy_grant_allowed(&policy, .Device, 10, 1)
	testing.expect_value(t, lock_ref, Grant_Policy_Refusal.Grant_Class_Locked)

	// Capped class refuses permanent and cap+1, accepts exact cap.
	_, cap_ref := policy_grant_allowed(&policy, .Network, 100, 0)
	testing.expect_value(t, cap_ref, Grant_Policy_Refusal.Duration_Past_Cap)
	_, cap_ref = policy_grant_allowed(&policy, .Network, 100, 30_001)
	testing.expect_value(t, cap_ref, Grant_Policy_Refusal.Duration_Past_Cap)

	net_term, net_ref := policy_grant_allowed(&policy, .Network, 100, 30_000)
	testing.expect_value(t, net_ref, Grant_Policy_Refusal.None)
	testing.expect_value(t, net_term.granted_at_ms, u64(100))
	testing.expect_value(t, net_term.expires_at_ms, u64(30_100))

	// Uncapped unlocked class allows permanent and finite durations.
	store_term, store_ref := policy_grant_allowed(&policy, .Store, 250, 0)
	testing.expect_value(t, store_ref, Grant_Policy_Refusal.None)
	testing.expect_value(t, store_term.expires_at_ms, u64(0))
}
