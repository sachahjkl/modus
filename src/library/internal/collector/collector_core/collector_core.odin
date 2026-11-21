// Pure collector and wide-grant manager engine
// (src/md/features/module_outputs.md; src/md/features/wide_grants.md).
//
// Provides:
// - Act_Collector: bounded, append-only, domain-separated BLAKE3 hash-chained
//   act store with full-chain verification and indexed queries by grant or
//   window;
// - Wide_Grant_Manager: proof-gated wide grant creation, monotonic expiry,
//   one-press instant revocation, duplicate-connection suspension, sensitive
//   action blocking, window-scope enforcement, and fail-closed act recording
//   (no unrecorded act ever runs when the act chain is full).
//
// Pure internal package: imports contract packages only, calls no kernel
// operation, and allocates no memory.
package collector_core

import "modus:contract/blake3"
import "modus:contract/wide_grants"

// Maximum act records stored in one collector instance.
COLLECTOR_ACT_CAPACITY :: 1024

// Maximum wide grant slots tracked simultaneously by one manager.
MAX_WIDE_GRANTS :: 16

// Append-only hash-chained act record store for one principal. Never evicts
// records: when full, writes fail closed with Act_Log_Full and increment
// refused_full_count.
Act_Collector :: struct {
	initialized:        bool,
	space_kind:         wide_grants.Collector_Space_Kind,
	capacity:           u32,
	count:              u32,
	next_sequence:      u64,
	last_timestamp_ms:  u64,
	head_hash:          blake3.Hash,
	refused_full_count: u64,
	verify_calls:       u64,
	records:            [COLLECTOR_ACT_CAPACITY]wide_grants.Act_Record,
}

// One managed wide grant tracked in memory for the current run only.
Managed_Wide_Grant :: struct {
	occupied:                           bool,
	grant_serial:                       u64,
	state:                              wide_grants.Wide_Grant_State,
	terms:                              wide_grants.Wide_Grant_Terms,
	authorities:                        wide_grants.Wide_Authorities,
	proof_kind:                         wide_grants.Proof_Kind,
	created_ms:                         u64,
	expires_ms:                         u64,
	revoked_ms:                         u64,
	act_count:                          u64,
	blocked_act_count:                  u64,
	suspended_for_duplicate_connection: bool,
}

// Aggregate counters for status reporting and testing.
Manager_Counters :: struct {
	active_grants:        u64,
	total_grants_created: u64,
	total_grants_revoked: u64,
	total_grants_expired: u64,
	total_acts_permitted: u64,
	total_acts_blocked:   u64,
}

// Pure wide grant lifecycle manager paired with its append-only Act_Collector.
Wide_Grant_Manager :: struct {
	initialized:            bool,
	principal_id:           u64,
	host_principal_key:     blake3.Hash,
	next_grant_serial:      u64,
	last_clock_ms:          u64,
	grants:                 [MAX_WIDE_GRANTS]Managed_Wide_Grant,
	collector:              Act_Collector,
	counters:               Manager_Counters,
}

// collector_init initializes an append-only Audit Act_Collector with a bounded
// capacity in 1 ..= COLLECTOR_ACT_CAPACITY. Refuses 0 or values past the bound.
collector_init :: proc "contextless" (collector: ^Act_Collector, capacity: u32 = COLLECTOR_ACT_CAPACITY) -> bool {
	if capacity == 0 || capacity > COLLECTOR_ACT_CAPACITY {
		return false
	}
	collector^ = Act_Collector {
		initialized = true,
		space_kind  = .Audit,
		capacity    = capacity,
		head_hash   = wide_grants.GENESIS_PREVIOUS_HASH,
	}
	return true
}

// collector_remaining_capacity returns the number of free record slots left.
collector_remaining_capacity :: proc "contextless" (collector: ^Act_Collector) -> u32 {
	if !collector.initialized || collector.count >= collector.capacity {
		return 0
	}
	return collector.capacity - collector.count
}

// collector_append seals and appends one hash-chained Act_Record to the audit
// store. Fails closed with Act_Log_Full when the store is full and refuses
// backward timestamps with Chain_Tampered.
collector_append :: proc "contextless" (
	collector: ^Act_Collector,
	grant_serial: u64,
	timestamp_ms: u64,
	act_kind: wide_grants.Act_Kind,
	target_window_id: u64,
	detail_word_0: u64 = 0,
	detail_word_1: u64 = 0,
) -> (record: wide_grants.Act_Record, refusal: wide_grants.Wide_Grant_Refusal) {
	if !collector.initialized || collector.space_kind != .Audit {
		return {}, .Act_Log_Full
	}
	if collector.count >= collector.capacity {
		collector.refused_full_count += 1
		return {}, .Act_Log_Full
	}
	if grant_serial == 0 || act_kind == .None {
		return {}, .Chain_Tampered
	}
	if collector.count > 0 && timestamp_ms < collector.last_timestamp_ms {
		return {}, .Chain_Tampered
	}
	candidate := wide_grants.Act_Record {
		sequence_number  = collector.next_sequence,
		grant_serial     = grant_serial,
		timestamp_ms     = timestamp_ms,
		act_kind_word    = u64(act_kind),
		target_window_id = target_window_id,
		detail_word_0    = detail_word_0,
		detail_word_1    = detail_word_1,
		previous_hash    = collector.head_hash,
	}
	seal_refusal := wide_grants.act_record_seal(&candidate)
	if seal_refusal != .None {
		return {}, seal_refusal
	}
	collector.records[collector.count] = candidate
	collector.count += 1
	collector.next_sequence += 1
	collector.last_timestamp_ms = timestamp_ms
	collector.head_hash = candidate.record_hash
	return candidate, .None
}

// collector_append_prebuilt validates and appends an externally constructed
// Act_Record, checking sequence continuity, previous_hash linkage, monotonic
// timestamp, and record_hash integrity before storing.
collector_append_prebuilt :: proc "contextless" (collector: ^Act_Collector, record: ^wide_grants.Act_Record) -> wide_grants.Wide_Grant_Refusal {
	if !collector.initialized || collector.space_kind != .Audit {
		return .Act_Log_Full
	}
	if collector.count >= collector.capacity {
		collector.refused_full_count += 1
		return .Act_Log_Full
	}
	if record.sequence_number != collector.next_sequence {
		return .Chain_Tampered
	}
	if record.previous_hash != collector.head_hash {
		return .Chain_Tampered
	}
	if collector.count > 0 && record.timestamp_ms < collector.last_timestamp_ms {
		return .Chain_Tampered
	}
	validate_refusal := wide_grants.act_record_validate(record)
	if validate_refusal != .None {
		return validate_refusal
	}
	collector.records[collector.count] = record^
	collector.count += 1
	collector.next_sequence += 1
	collector.last_timestamp_ms = record.timestamp_ms
	collector.head_hash = record.record_hash
	return .None
}

// collector_verify walks every stored record in the collector and verifies
// hash-chain integrity, sequential numbering, monotonic timestamps, and head
// hash consistency.
collector_verify :: proc "contextless" (collector: ^Act_Collector) -> (refusal: wide_grants.Wide_Grant_Refusal, failing_index: u64) {
	if !collector.initialized || collector.space_kind != .Audit {
		return .Chain_Tampered, 0
	}
	collector.verify_calls += 1
	if collector.count > collector.capacity || collector.capacity > COLLECTOR_ACT_CAPACITY {
		return .Chain_Tampered, u64(collector.count)
	}
	if collector.next_sequence != u64(collector.count) {
		return .Chain_Tampered, u64(collector.count)
	}
	return wide_grants.act_chain_verify_with_head(
		collector.records[:collector.count],
		u64(collector.count),
		collector.head_hash,
	)
}

// collector_query_by_grant copies act records matching grant_serial into out
// in sequence order. Returns the number copied and the total matches found.
collector_query_by_grant :: proc "contextless" (
	collector: ^Act_Collector,
	grant_serial: u64,
	out: []wide_grants.Act_Record,
) -> (copied_count: u32, total_matches: u32) {
	if !collector.initialized || grant_serial == 0 {
		return 0, 0
	}
	for index in u32(0) ..< collector.count {
		entry := &collector.records[index]
		if entry.grant_serial != grant_serial {
			continue
		}
		if int(copied_count) < len(out) {
			out[copied_count] = entry^
			copied_count += 1
		}
		total_matches += 1
	}
	return copied_count, total_matches
}

// collector_query_by_window copies act records matching target_window_id into
// out in sequence order. Returns the number copied and the total matches found.
collector_query_by_window :: proc "contextless" (
	collector: ^Act_Collector,
	target_window_id: u64,
	out: []wide_grants.Act_Record,
) -> (copied_count: u32, total_matches: u32) {
	if !collector.initialized || target_window_id == 0 {
		return 0, 0
	}
	for index in u32(0) ..< collector.count {
		entry := &collector.records[index]
		if entry.target_window_id != target_window_id {
			continue
		}
		if int(copied_count) < len(out) {
			out[copied_count] = entry^
			copied_count += 1
		}
		total_matches += 1
	}
	return copied_count, total_matches
}

// manager_init initializes a Wide_Grant_Manager and its embedded append-only
// Act_Collector for one principal.
manager_init :: proc "contextless" (
	manager: ^Wide_Grant_Manager,
	principal_id: u64,
	host_principal_key: blake3.Hash = {},
	collector_capacity: u32 = COLLECTOR_ACT_CAPACITY,
) -> bool {
	manager^ = Wide_Grant_Manager{}
	if !collector_init(&manager.collector, collector_capacity) {
		return false
	}
	manager.initialized = true
	manager.principal_id = principal_id
	manager.host_principal_key = host_principal_key
	manager.next_grant_serial = 1
	return true
}

@(private = "file")
find_grant_slot_by_serial :: proc "contextless" (manager: ^Wide_Grant_Manager, grant_serial: u64) -> (slot_index: int, found: bool) {
	if grant_serial == 0 {
		return -1, false
	}
	for index in 0 ..< MAX_WIDE_GRANTS {
		slot := &manager.grants[index]
		if slot.occupied && slot.grant_serial == grant_serial {
			return index, true
		}
	}
	return -1, false
}

@(private = "file")
find_active_grant_for_grantee :: proc "contextless" (manager: ^Wide_Grant_Manager, grantee_hash: blake3.Hash) -> (slot_index: int, found: bool) {
	for index in 0 ..< MAX_WIDE_GRANTS {
		slot := &manager.grants[index]
		if slot.occupied && slot.state == .Active && slot.terms.grantee_identity_hash == grantee_hash {
			return index, true
		}
	}
	return -1, false
}

@(private = "file")
find_grant_allocation_slot :: proc "contextless" (manager: ^Wide_Grant_Manager) -> (slot_index: int, found: bool) {
	// Prefer a completely empty slot first.
	for index in 0 ..< MAX_WIDE_GRANTS {
		if !manager.grants[index].occupied {
			return index, true
		}
	}
	// Otherwise reclaim the oldest inactive (Revoked or Expired) slot.
	oldest_inactive := -1
	oldest_serial := max(u64)
	for index in 0 ..< MAX_WIDE_GRANTS {
		slot := &manager.grants[index]
		if slot.state != .Active && slot.grant_serial < oldest_serial {
			oldest_serial = slot.grant_serial
			oldest_inactive = index
		}
	}
	if oldest_inactive >= 0 {
		return oldest_inactive, true
	}
	return -1, false
}

@(private = "file")
saturating_add_u64 :: proc "contextless" (a, b: u64) -> u64 {
	if b > max(u64) - a {
		return max(u64)
	}
	return a + b
}

@(private = "file")
required_authority_for_act :: proc "contextless" (kind: wide_grants.Act_Kind) -> (authority: wide_grants.Wide_Authority, valid: bool) {
	switch kind {
	case .Frame_Read:
		return .View_Screen, true
	case .Key_Injected, .Pointer_Moved, .Pointer_Clicked:
		return .Send_Input, true
	case .Action_Invoked:
		return .Read_Semantic_Tree, true
	case .None, .Grant_Started, .Grant_Revoked, .Grant_Expired, .Forbidden_Act_Blocked:
		return .View_Screen, false
	}
	return .View_Screen, false
}

// manager_create_grant verifies terms and principal proof, replaces any active
// grant for the same grantee whole, records Grant_Started into the hash chain,
// and activates the grant. Fails closed with nothing changed if validation
// fails or the collector has insufficient room.
manager_create_grant :: proc "contextless" (
	manager: ^Wide_Grant_Manager,
	terms: ^wide_grants.Wide_Grant_Terms,
	proof: ^wide_grants.Wide_Grant_Proof,
	now_ms: u64,
) -> (grant_serial: u64, refusal: wide_grants.Wide_Grant_Refusal) {
	if !manager.initialized {
		return 0, .Act_Log_Full
	}
	if terms.principal_id != manager.principal_id {
		return 0, .Invalid_Proof
	}
	proof_refusal := wide_grants.wide_grant_proof_validate(terms, proof, manager.host_principal_key)
	if proof_refusal != .None {
		return 0, proof_refusal
	}
	if now_ms < manager.last_clock_ms {
		return 0, .Chain_Tampered
	}

	existing_slot, has_existing := find_active_grant_for_grantee(manager, terms.grantee_identity_hash)
	needed_records: u32 = has_existing ? 2 : 1
	if collector_remaining_capacity(&manager.collector) < needed_records {
		manager.collector.refused_full_count += 1
		return 0, .Act_Log_Full
	}

	target_slot, has_slot := find_grant_allocation_slot(manager)
	if !has_slot && !has_existing {
		return 0, .Act_Log_Full
	}

	authorities, auth_ok := wide_grants.wide_authorities_from_word(terms.authorities_word)
	if !auth_ok {
		return 0, .Invalid_Authority
	}
	proof_kind, proof_kind_ok := wide_grants.proof_kind_from_word(proof.proof_kind_word)
	if !proof_kind_ok {
		return 0, .Invalid_Proof
	}

	// Replace any existing active grant for the same grantee whole.
	if has_existing {
		old_grant := &manager.grants[existing_slot]
		old_grant.state = .Revoked
		old_grant.revoked_ms = now_ms
		if manager.counters.active_grants > 0 {
			manager.counters.active_grants -= 1
		}
		manager.counters.total_grants_revoked += 1
		_, revoke_log_refusal := collector_append(
			&manager.collector,
			old_grant.grant_serial,
			now_ms,
			.Grant_Revoked,
			0,
			1, // Replaced by a newer grant for the same holder.
			0,
		)
		if revoke_log_refusal != .None {
			return 0, revoke_log_refusal
		}
		if !has_slot {
			target_slot = existing_slot
		}
	}

	serial := manager.next_grant_serial
	_, start_log_refusal := collector_append(
		&manager.collector,
		serial,
		now_ms,
		.Grant_Started,
		0,
		terms.authorities_word,
		terms.duration_ms,
	)
	if start_log_refusal != .None {
		return 0, start_log_refusal
	}

	manager.next_grant_serial += 1
	manager.last_clock_ms = now_ms
	manager.grants[target_slot] = Managed_Wide_Grant {
		occupied     = true,
		grant_serial = serial,
		state        = .Active,
		terms        = terms^,
		authorities  = authorities,
		proof_kind   = proof_kind,
		created_ms   = now_ms,
		expires_ms   = saturating_add_u64(now_ms, terms.duration_ms),
	}
	manager.counters.active_grants += 1
	manager.counters.total_grants_created += 1
	return serial, .None
}

// manager_revoke_grant immediately ends an active grant (one-press revocation
// mark or console revoke). Revocation always takes effect even if the act log
// is full so an agent cannot block revocation by exhausting log capacity.
manager_revoke_grant :: proc "contextless" (
	manager: ^Wide_Grant_Manager,
	grant_serial: u64,
	now_ms: u64,
	reason_word: u64 = 0,
) -> wide_grants.Wide_Grant_Refusal {
	if !manager.initialized {
		return .Grant_Revoked
	}
	slot_index, found := find_grant_slot_by_serial(manager, grant_serial)
	if !found {
		return .Grant_Revoked
	}
	grant := &manager.grants[slot_index]
	switch grant.state {
	case .None, .Pending, .Revoked:
		return .Grant_Revoked
	case .Expired:
		return .Grant_Expired
	case .Active:
		if now_ms < manager.last_clock_ms {
			return .Chain_Tampered
		}
		grant.state = .Revoked
		grant.revoked_ms = now_ms
		if manager.counters.active_grants > 0 {
			manager.counters.active_grants -= 1
		}
		manager.counters.total_grants_revoked += 1
		manager.last_clock_ms = now_ms
		_, _ = collector_append(&manager.collector, grant.grant_serial, now_ms, .Grant_Revoked, 0, reason_word, 0)
		return .None
	}
	return .Grant_Revoked
}

// manager_suspend_for_duplicate_connection immediately revokes and marks a
// wide grant when a second simultaneous connection uses the same holder key.
manager_suspend_for_duplicate_connection :: proc "contextless" (
	manager: ^Wide_Grant_Manager,
	grant_serial: u64,
	now_ms: u64,
) -> wide_grants.Wide_Grant_Refusal {
	if !manager.initialized {
		return .Grant_Revoked
	}
	slot_index, found := find_grant_slot_by_serial(manager, grant_serial)
	if !found {
		return .Grant_Revoked
	}
	grant := &manager.grants[slot_index]
	if grant.state != .Active {
		return grant.state == .Expired ? .Grant_Expired : .Grant_Revoked
	}
	if now_ms < manager.last_clock_ms {
		return .Chain_Tampered
	}
	grant.suspended_for_duplicate_connection = true
	return manager_revoke_grant(manager, grant_serial, now_ms, 2)
}

// manager_expire_grants monotonically expires every active grant whose
// expires_ms has been reached at now_ms. Returns the count expired.
manager_expire_grants :: proc "contextless" (manager: ^Wide_Grant_Manager, now_ms: u64) -> u32 {
	if !manager.initialized || now_ms < manager.last_clock_ms {
		return 0
	}
	manager.last_clock_ms = now_ms
	expired_count: u32 = 0
	for index in 0 ..< MAX_WIDE_GRANTS {
		grant := &manager.grants[index]
		if !grant.occupied || grant.state != .Active {
			continue
		}
		if now_ms >= grant.expires_ms {
			grant.state = .Expired
			if manager.counters.active_grants > 0 {
				manager.counters.active_grants -= 1
			}
			manager.counters.total_grants_expired += 1
			expired_count += 1
			_, _ = collector_append(&manager.collector, grant.grant_serial, now_ms, .Grant_Expired, 0, grant.expires_ms, 0)
		}
	}
	return expired_count
}

// manager_authorize_and_record_act enforces every wide-grant boundary and
// records EVERY permitted and blocked act into the hash-chained collector.
// Fails closed with Act_Log_Full when the collector has no remaining capacity
// so no unrecorded act can ever execute.
manager_authorize_and_record_act :: proc "contextless" (
	manager: ^Wide_Grant_Manager,
	grant_serial: u64,
	now_ms: u64,
	act_kind: wide_grants.Act_Kind,
	target_window_id: u64,
	sensitive_action: wide_grants.Sensitive_Action,
	detail_word_0: u64 = 0,
	detail_word_1: u64 = 0,
) -> (record: wide_grants.Act_Record, refusal: wide_grants.Wide_Grant_Refusal) {
	if !manager.initialized {
		return {}, .Act_Log_Full
	}
	if now_ms < manager.last_clock_ms {
		return {}, .Chain_Tampered
	}

	slot_index, found := find_grant_slot_by_serial(manager, grant_serial)
	if !found {
		return {}, .Grant_Revoked
	}
	grant := &manager.grants[slot_index]

	switch grant.state {
	case .None, .Pending, .Revoked:
		return {}, .Grant_Revoked
	case .Expired:
		return {}, .Grant_Expired
	case .Active:
		// Enforce monotonic expiry before checking any permission.
		if now_ms >= grant.expires_ms {
			grant.state = .Expired
			if manager.counters.active_grants > 0 {
				manager.counters.active_grants -= 1
			}
			manager.counters.total_grants_expired += 1
			manager.last_clock_ms = now_ms
			_, _ = collector_append(&manager.collector, grant.grant_serial, now_ms, .Grant_Expired, 0, grant.expires_ms, 0)
			return {}, .Grant_Expired
		}
	}

	// Fail closed if the append-only act log has no space left: no act may run
	// without being recorded in the hash chain first.
	if collector_remaining_capacity(&manager.collector) == 0 {
		manager.collector.refused_full_count += 1
		grant.blocked_act_count += 1
		manager.counters.total_acts_blocked += 1
		return {}, .Act_Log_Full
	}

	// Sensitive operations still require fresh principal proof even while a
	// wide grant is active. Record the blocked attempt into the hash chain.
	if wide_grants.act_requires_principal_proof(sensitive_action) {
		blocked_rec, append_refusal := collector_append(
			&manager.collector,
			grant.grant_serial,
			now_ms,
			.Forbidden_Act_Blocked,
			target_window_id,
			u64(wide_grants.Wide_Grant_Refusal.Act_Still_Requires_Principal),
			u64(sensitive_action),
		)
		if append_refusal != .None {
			return {}, append_refusal
		}
		grant.blocked_act_count += 1
		manager.counters.total_acts_blocked += 1
		manager.last_clock_ms = now_ms
		return blocked_rec, .Act_Still_Requires_Principal
	}

	// Only agent-invocable act kinds may be executed under a grant.
	if !wide_grants.act_kind_is_agent_invocable(act_kind) {
		blocked_rec, append_refusal := collector_append(
			&manager.collector,
			grant.grant_serial,
			now_ms,
			.Forbidden_Act_Blocked,
			target_window_id,
			u64(wide_grants.Wide_Grant_Refusal.Invalid_Authority),
			u64(act_kind),
		)
		if append_refusal != .None {
			return {}, append_refusal
		}
		grant.blocked_act_count += 1
		manager.counters.total_acts_blocked += 1
		manager.last_clock_ms = now_ms
		return blocked_rec, .Invalid_Authority
	}

	// Check required Wide_Authority bit.
	required_auth, auth_valid := required_authority_for_act(act_kind)
	if !auth_valid || required_auth not_in grant.authorities {
		blocked_rec, append_refusal := collector_append(
			&manager.collector,
			grant.grant_serial,
			now_ms,
			.Forbidden_Act_Blocked,
			target_window_id,
			u64(wide_grants.Wide_Grant_Refusal.Invalid_Authority),
			u64(act_kind),
		)
		if append_refusal != .None {
			return {}, append_refusal
		}
		grant.blocked_act_count += 1
		manager.counters.total_acts_blocked += 1
		manager.last_clock_ms = now_ms
		return blocked_rec, .Invalid_Authority
	}

	// Check window scope: window-targeted acts require an explicit window id in
	// terms; Frame_Read allows window 0 (whole screen) or a window in terms.
	window_allowed := false
	if wide_grants.act_kind_requires_target_window(act_kind) {
		window_allowed = wide_grants.wide_grant_terms_contains_window(&grant.terms, target_window_id)
	} else {
		window_allowed = target_window_id == 0 || wide_grants.wide_grant_terms_contains_window(&grant.terms, target_window_id)
	}
	if !window_allowed {
		blocked_rec, append_refusal := collector_append(
			&manager.collector,
			grant.grant_serial,
			now_ms,
			.Forbidden_Act_Blocked,
			target_window_id,
			u64(wide_grants.Wide_Grant_Refusal.Window_Not_In_Scope),
			u64(act_kind),
		)
		if append_refusal != .None {
			return {}, append_refusal
		}
		grant.blocked_act_count += 1
		manager.counters.total_acts_blocked += 1
		manager.last_clock_ms = now_ms
		return blocked_rec, .Window_Not_In_Scope
	}

	// Record the permitted act before returning authorization.
	permitted_rec, append_refusal := collector_append(
		&manager.collector,
		grant.grant_serial,
		now_ms,
		act_kind,
		target_window_id,
		detail_word_0,
		detail_word_1,
	)
	if append_refusal != .None {
		return {}, append_refusal
	}
	grant.act_count += 1
	manager.counters.total_acts_permitted += 1
	manager.last_clock_ms = now_ms
	return permitted_rec, .None
}

// manager_get_grant looks up a managed wide grant by serial for inspection.
manager_get_grant :: proc "contextless" (manager: ^Wide_Grant_Manager, grant_serial: u64) -> (grant: Managed_Wide_Grant, ok: bool) {
	if !manager.initialized {
		return {}, false
	}
	slot_index, found := find_grant_slot_by_serial(manager, grant_serial)
	if !found {
		return {}, false
	}
	return manager.grants[slot_index], true
}

// manager_verify_chain verifies the full hash-chained act log held by manager.
manager_verify_chain :: proc "contextless" (manager: ^Wide_Grant_Manager) -> (refusal: wide_grants.Wide_Grant_Refusal, failing_index: u64) {
	if !manager.initialized {
		return .Chain_Tampered, 0
	}
	return collector_verify(&manager.collector)
}
