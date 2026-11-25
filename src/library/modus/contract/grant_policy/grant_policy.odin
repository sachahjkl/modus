// Shared contract for timed ordinary grants, per-grant service budgets, and
// machine-level grant and signer policy locks
// (src/md/features/grant_policy.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation. Owning services enforce per-grant quotas on their own
// data paths, and the root service enforces timed expiry and machine policy
// locks without adding data-plane accounting to the kernel.
package grant_policy

import "modus:contract/enum_word"

// Format property: an Ed25519 public signing key is 32 bytes.
SIGNER_KEY_BYTES :: 32

// Plan value: default capacity of 32 enrolled object-cache Ed25519 signer keys
// in a machine grant policy, covering organization release keys, key rotation
// overlap, and approved third-party publishers within a compact fixed table.
ALLOWED_SIGNER_CAPACITY :: 32

// Ed25519 public key identifying an object-cache or realisation signer.
Signer_Key :: [SIGNER_KEY_BYTES]u8

// Closed set of outcomes returned by grant policy, timed grant, quota, and
// expiry table checks. Values cross process borders explicitly.
Grant_Policy_Refusal :: enum u8 {
	None               = 0,
	Expired            = 1,
	Duration_Past_Cap  = 2,
	Quota_Exceeded     = 3,
	Signer_Not_Allowed = 4,
	Grant_Class_Locked = 5,
	Bad_Value          = 6,
	Capacity_Full      = 7,
	Not_Found          = 8,
}

// Closed set of ordinary grant classes subject to machine-level duration caps
// and administrative class locks.
Grant_Class :: enum u8 {
	Store      = 0,
	Network    = 1,
	Device     = 2,
	Wide_Agent = 3,
}

// Bitset of grant classes locked off by machine policy.
Grant_Class_Set :: bit_set[Grant_Class; u8]

// Monotonic millisecond lifetime of an ordinary grant.
// expires_at_ms == 0 represents a permanent grant that never expires.
// Any non-zero expires_at_ms expires once now_ms >= expires_at_ms.
Timed_Grant_Term :: struct {
	granted_at_ms: u64,
	expires_at_ms: u64,
}

// Optional per-grant resource budget enforced inside an owning service
// (for example storage bytes on a share, network bytes on an endpoint grant,
// or agent operation count on a wide grant).
// limit == 0 means no separate per-grant cap is active.
Grant_Quota :: struct {
	limit: u64,
	used:  u64,
}

// Principal 0 machine-level policy locking allowed object-cache signer keys,
// capping ordinary grant durations per class, and locking off grant classes.
Machine_Grant_Policy :: struct {
	signer_lock_active:   bool,
	allowed_signer_count: u8,
	allowed_signers:      [ALLOWED_SIGNER_CAPACITY]Signer_Key,
	max_duration_ms:      [Grant_Class]u64,
	locked_classes:       Grant_Class_Set,
}

// grant_class_of_word converts a transport word into a Grant_Class at a border,
// refusing any word that does not name a member.
grant_class_of_word :: proc "contextless" (word: u64) -> (class: Grant_Class, ok: bool) {
	return enum_word.member_of_word(Grant_Class, word)
}

// grant_policy_refusal_of_word converts a transport word into a
// Grant_Policy_Refusal at a border, refusing any word that does not name a
// member.
grant_policy_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Grant_Policy_Refusal, ok: bool) {
	return enum_word.member_of_word(Grant_Policy_Refusal, word)
}

// signer_key_is_zero reports whether key consists exclusively of zero bytes.
signer_key_is_zero :: proc "contextless" (key: Signer_Key) -> bool {
	accum: u8
	for b in key {
		accum |= b
	}
	return accum == 0
}

// grant_is_expired reports whether term has reached or passed its monotonic
// expiration timestamp at now_ms. Permanent grants (expires_at_ms == 0) never
// expire.
grant_is_expired :: proc "contextless" (term: Timed_Grant_Term, now_ms: u64) -> bool {
	return term.expires_at_ms != 0 && now_ms >= term.expires_at_ms
}

// grant_remaining_ms returns the monotonic milliseconds remaining until term
// expires at now_ms: max(u64) for a permanent grant (expires_at_ms == 0), 0
// once expired (now_ms >= expires_at_ms), and expires_at_ms - now_ms otherwise.
grant_remaining_ms :: proc "contextless" (term: Timed_Grant_Term, now_ms: u64) -> u64 {
	if term.expires_at_ms == 0 {
		return max(u64)
	}
	if now_ms >= term.expires_at_ms {
		return 0
	}
	return term.expires_at_ms - now_ms
}

// timed_grant_create constructs a Timed_Grant_Term from the current monotonic
// clock now_ms, requested duration_ms (0 for permanent), and optional cap
// max_duration_ms (0 for uncapped).
// Refuses permanent requests or durations exceeding max_duration_ms with
// Duration_Past_Cap, and refuses timestamp overflow with Bad_Value.
timed_grant_create :: proc "contextless" (now_ms: u64, duration_ms: u64, max_duration_ms: u64) -> (term: Timed_Grant_Term, refusal: Grant_Policy_Refusal) {
	if duration_ms == 0 {
		if max_duration_ms > 0 {
			return {}, .Duration_Past_Cap
		}
		return Timed_Grant_Term{granted_at_ms = now_ms, expires_at_ms = 0}, .None
	}
	if max_duration_ms > 0 && duration_ms > max_duration_ms {
		return {}, .Duration_Past_Cap
	}
	if now_ms > max(u64) - duration_ms {
		return {}, .Bad_Value
	}
	return Timed_Grant_Term{
		granted_at_ms = now_ms,
		expires_at_ms = now_ms + duration_ms,
	}, .None
}

// quota_charge attempts to charge amount against q without overflow.
// On any refusal, q is left completely unchanged.
quota_charge :: proc "contextless" (q: ^Grant_Quota, amount: u64) -> Grant_Policy_Refusal {
	if q == nil {
		return .Bad_Value
	}
	if q.limit == 0 {
		if q.used > max(u64) - amount {
			return .Quota_Exceeded
		}
		q.used += amount
		return .None
	}
	if q.used > q.limit || amount > q.limit - q.used {
		return .Quota_Exceeded
	}
	q.used += amount
	return .None
}

// quota_remaining returns the remaining headroom of q: max(u64) when no limit
// is set (limit == 0), 0 when used >= limit, and limit - used otherwise.
quota_remaining :: proc "contextless" (q: Grant_Quota) -> u64 {
	if q.limit == 0 {
		return max(u64)
	}
	if q.used >= q.limit {
		return 0
	}
	return q.limit - q.used
}

// policy_add_allowed_signer enrolls a non-zero Ed25519 signer public key into
// policy and activates the signer allowlist lock. Enrolling an already-present
// key is idempotent and consumes no additional slot. Refuses nil policy, zero
// keys, corrupted counts, or a full allowlist without mutating policy.
policy_add_allowed_signer :: proc "contextless" (policy: ^Machine_Grant_Policy, key: Signer_Key) -> Grant_Policy_Refusal {
	if policy == nil || signer_key_is_zero(key) {
		return .Bad_Value
	}
	count := int(policy.allowed_signer_count)
	if count > ALLOWED_SIGNER_CAPACITY {
		return .Bad_Value
	}
	for i in 0 ..< count {
		if policy.allowed_signers[i] == key {
			policy.signer_lock_active = true
			return .None
		}
	}
	if count >= ALLOWED_SIGNER_CAPACITY {
		return .Capacity_Full
	}
	policy.allowed_signers[count] = key
	policy.allowed_signer_count = u8(count + 1)
	policy.signer_lock_active = true
	return .None
}

// policy_signer_allowed checks whether key is permitted by policy.
// Always refuses a nil policy, an all-zero key, or a corrupted count with
// Bad_Value. When no signer lock is active and the allowlist is empty, every
// non-zero key is allowed; otherwise key must appear in the allowlist.
policy_signer_allowed :: proc "contextless" (policy: ^Machine_Grant_Policy, key: Signer_Key) -> Grant_Policy_Refusal {
	if policy == nil || signer_key_is_zero(key) {
		return .Bad_Value
	}
	count := int(policy.allowed_signer_count)
	if count > ALLOWED_SIGNER_CAPACITY {
		return .Bad_Value
	}
	if !policy.signer_lock_active && count == 0 {
		return .None
	}
	for i in 0 ..< count {
		if policy.allowed_signers[i] == key {
			return .None
		}
	}
	return .Signer_Not_Allowed
}

// policy_grant_allowed validates a requested ordinary grant of class and
// duration_ms at now_ms against policy's locked classes and per-class duration
// caps, returning the validated Timed_Grant_Term on success.
policy_grant_allowed :: proc "contextless" (policy: ^Machine_Grant_Policy, class: Grant_Class, now_ms: u64, duration_ms: u64) -> (term: Timed_Grant_Term, refusal: Grant_Policy_Refusal) {
	if policy == nil {
		return {}, .Bad_Value
	}
	checked_class, ok := enum_word.member_of_argument(class)
	if !ok {
		return {}, .Bad_Value
	}
	if checked_class in policy.locked_classes {
		return {}, .Grant_Class_Locked
	}
	return timed_grant_create(now_ms, duration_ms, policy.max_duration_ms[checked_class])
}
