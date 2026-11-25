// Companion state and helpers for timed ordinary grants and machine grant
// policy in the root service (src/md/features/grant_policy.md).
package root

import "internal:root/grant_expiry"
import "modus:contract/grant_policy"

root_grant_expiry_table: grant_expiry.Grant_Expiry_Table
root_machine_grant_policy: grant_policy.Machine_Grant_Policy

root_grant_policy_check :: proc "contextless" (
	class: grant_policy.Grant_Class,
	now_ms: u64,
	duration_ms: u64,
) -> (term: grant_policy.Timed_Grant_Term, refusal: grant_policy.Grant_Policy_Refusal) {
	return grant_policy.policy_grant_allowed(&root_machine_grant_policy, class, now_ms, duration_ms)
}

root_grant_expiry_register :: proc "contextless" (
	grant_id: u64,
	principal: u64,
	class: grant_policy.Grant_Class,
	term: grant_policy.Timed_Grant_Term,
) -> grant_policy.Grant_Policy_Refusal {
	return grant_expiry.grant_expiry_register(&root_grant_expiry_table, grant_id, principal, class, term)
}

root_grant_expiry_remove :: proc "contextless" (grant_id: u64) -> grant_policy.Grant_Policy_Refusal {
	return grant_expiry.grant_expiry_remove(&root_grant_expiry_table, grant_id)
}

root_grant_expiry_sweep :: proc "contextless" (
	now_ms: u64,
	expired_out: []grant_expiry.Grant_Expiry_Entry,
) -> (swept: int, more_expired: bool) {
	return grant_expiry.grant_expiry_sweep(&root_grant_expiry_table, now_ms, expired_out)
}

root_grant_expiry_next_deadline_ms :: proc "contextless" () -> (deadline_ms: u64, has_deadline: bool) {
	return grant_expiry.grant_expiry_next_deadline_ms(&root_grant_expiry_table)
}
