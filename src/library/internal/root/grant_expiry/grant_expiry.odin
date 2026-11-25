// Monotonic expiration tracking for ordinary grants in the root service
// (src/md/features/grant_policy.md).
//
// Pure freestanding internal part of root: tracks active timed grants in a
// fixed-capacity table, computes the earliest upcoming deadline for the root
// wait loop (with no background timer thread), and sweeps expired grants into
// caller-supplied storage without dropping entries when the output slice fills.
package grant_expiry

import "modus:contract/enum_word"
import "modus:contract/grant_policy"

// Plan value: default tracking table of 256 concurrent timed ordinary grants
// across all principals and grant classes in the root service, sized to cover
// active store, network, device, and agent grants without dynamic allocation.
GRANT_EXPIRY_CAPACITY :: 256

// One tracked timed grant entry.
Grant_Expiry_Entry :: struct {
	active:    bool,
	grant_id:  u64,
	principal: u64,
	class:     grant_policy.Grant_Class,
	term:      grant_policy.Timed_Grant_Term,
}

// Fixed-capacity monotonic expiration table owned by the root service.
Grant_Expiry_Table :: struct {
	entries: [GRANT_EXPIRY_CAPACITY]Grant_Expiry_Entry,
	count:   int,
}

// grant_expiry_register records or updates the expiration term for grant_id.
// Refuses nil table, grant_id == 0, unknown class, or a malformed non-zero
// term (expires_at_ms <= granted_at_ms) with Bad_Value. Updating an existing
// grant_id succeeds in place even when the table is at capacity; inserting a
// new grant_id into a full table returns Capacity_Full without mutation.
grant_expiry_register :: proc "contextless" (
	table: ^Grant_Expiry_Table,
	grant_id: u64,
	principal: u64,
	class: grant_policy.Grant_Class,
	term: grant_policy.Timed_Grant_Term,
) -> grant_policy.Grant_Policy_Refusal {
	if table == nil || grant_id == 0 {
		return .Bad_Value
	}
	checked_class, ok := enum_word.member_of_argument(class)
	if !ok {
		return .Bad_Value
	}
	if term.expires_at_ms != 0 && term.expires_at_ms <= term.granted_at_ms {
		return .Bad_Value
	}

	free_slot := -1
	for &entry, i in table.entries {
		if entry.active {
			if entry.grant_id == grant_id {
				entry.principal = principal
				entry.class = checked_class
				entry.term = term
				return .None
			}
		} else if free_slot < 0 {
			free_slot = i
		}
	}

	if free_slot < 0 {
		return .Capacity_Full
	}
	table.entries[free_slot] = Grant_Expiry_Entry {
		active    = true,
		grant_id  = grant_id,
		principal = principal,
		class     = checked_class,
		term      = term,
	}
	table.count += 1
	return .None
}

// grant_expiry_remove deletes grant_id from table, returning Not_Found when
// absent and Bad_Value for a nil table or zero grant_id.
grant_expiry_remove :: proc "contextless" (table: ^Grant_Expiry_Table, grant_id: u64) -> grant_policy.Grant_Policy_Refusal {
	if table == nil || grant_id == 0 {
		return .Bad_Value
	}
	for &entry in table.entries {
		if entry.active && entry.grant_id == grant_id {
			entry = {}
			if table.count > 0 {
				table.count -= 1
			}
			return .None
		}
	}
	return .Not_Found
}

// grant_expiry_is_active reports whether grant_id is registered in table and
// has not expired at now_ms.
grant_expiry_is_active :: proc "contextless" (table: ^Grant_Expiry_Table, grant_id: u64, now_ms: u64) -> (active: bool, refusal: grant_policy.Grant_Policy_Refusal) {
	if table == nil || grant_id == 0 {
		return false, .Bad_Value
	}
	for entry in table.entries {
		if entry.active && entry.grant_id == grant_id {
			if grant_policy.grant_is_expired(entry.term, now_ms) {
				return false, .Expired
			}
			return true, .None
		}
	}
	return false, .Not_Found
}

// grant_expiry_next_deadline_ms returns the earliest non-zero expiration
// timestamp among all active entries, so the root wait loop can wake on the
// next expiry without polling or a background timer thread.
grant_expiry_next_deadline_ms :: proc "contextless" (table: ^Grant_Expiry_Table) -> (deadline_ms: u64, has_deadline: bool) {
	if table == nil {
		return 0, false
	}
	for entry in table.entries {
		if !entry.active || entry.term.expires_at_ms == 0 {
			continue
		}
		if !has_deadline || entry.term.expires_at_ms < deadline_ms {
			deadline_ms = entry.term.expires_at_ms
			has_deadline = true
		}
	}
	return deadline_ms, has_deadline
}

// grant_expiry_sweep removes active grants whose term has expired at now_ms
// and writes them into expired_out. Permanent grants (expires_at_ms == 0) are
// never swept. If more entries are expired than len(expired_out) holds, the
// remaining expired entries stay in table and more_expired is true so no
// revocation is dropped in silence.
grant_expiry_sweep :: proc "contextless" (
	table: ^Grant_Expiry_Table,
	now_ms: u64,
	expired_out: []Grant_Expiry_Entry,
) -> (swept_count: int, more_expired: bool) {
	if table == nil {
		return 0, false
	}
	for &entry in table.entries {
		if !entry.active {
			continue
		}
		if !grant_policy.grant_is_expired(entry.term, now_ms) {
			continue
		}
		if swept_count < len(expired_out) {
			expired_out[swept_count] = entry
			swept_count += 1
			entry = {}
			if table.count > 0 {
				table.count -= 1
			}
		} else {
			more_expired = true
		}
	}
	return swept_count, more_expired
}
