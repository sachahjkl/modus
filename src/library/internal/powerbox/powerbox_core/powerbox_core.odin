// Pure powerbox policy and state machine (src/md/features/powerbox.md).
//
// Enforces all runtime consent bounds without wall-clock sleeps or heap
// allocation:
// - requesting process must own a visible window;
// - per-session pending dialog queue cap (MAX_PENDING_DIALOGS);
// - anti-clickjacking minimum display arm time (250 ms), per-process request
//   rate limit (500 ms), dialog expiry (60 s), quiet time after whole refusal
//   (60 s), and per-run refusal cap (3 whole refusals);
// - already-held shortcut (Held without prompting the principal) for start
//   grants, active grants, and Always rows bound to module BLAKE3 hash;
// - boot-image modules strictly refused Always grants;
// - store picker isolation: candidate lists go to the trusted Display holder
//   only, and accepted picks mint one attenuated single-store handle;
// - Plan_Difference dialogs apply whole or refuse whole with no per-item ticks
//   and no duration choice.
package powerbox_core

import "modus:contract/blake3"
import "modus:contract/powerbox"

// Maximum concurrent pending dialogs queued for a single session.
MAX_PENDING_DIALOGS :: 3

// Maximum simultaneous sessions tracked by the powerbox state machine.
MAX_SESSIONS :: 8

// Total pending dialog slots across all sessions.
MAX_TOTAL_PENDING_DIALOGS :: MAX_SESSIONS * MAX_PENDING_DIALOGS

// Maximum distinct asking processes tracked for frequency and refusal bounds.
MAX_ASKERS :: 32

// Maximum powerbox-requested grants held concurrently by one process.
MAX_REQUESTED_GRANTS_PER_PROCESS :: 32

// Maximum persisted Always grant rows tracked across disk modules.
MAX_ALWAYS_ROWS :: 64

// Maximum Always rows kept for a single disk module hash.
MAX_ALWAYS_ROWS_PER_MODULE :: 8

// Anti-clickjacking minimum time a dialog must be whole on screen before any
// deliberate press or answer is accepted.
MIN_DISPLAY_ARM_MILLISECONDS :: u64(250)

// Minimum monotonic spacing between requests from one asking process.
RATE_LIMIT_MILLISECONDS :: u64(500)

// Time after which an unanswered pending dialog expires with no grants issued.
DIALOG_EXPIRY_MILLISECONDS :: u64(60_000)

// Quiet time after a whole-dialog refusal during which further requests from
// that process are refused without opening a dialog.
QUIET_TIME_AFTER_REFUSAL_MILLISECONDS :: u64(60_000)

// Maximum whole-dialog refusals for one process in a single run before no more
// dialogs are opened for that run.
MAX_WHOLE_REFUSALS_PER_RUN :: u32(3)

// Explicit lifecycle state of a pending dialog slot.
Pending_Dialog_State :: enum u8 {
	Empty     = 0,
	Queued    = 1,
	Shown     = 2,
	Resolved  = 3,
	Expired   = 4,
	Withdrawn = 5,
}

// One store owned by a principal session, eligible for Store_Share pickers of
// that principal only.
Session_Store :: struct {
	active:    bool,
	principal: u64,
	candidate: powerbox.Picker_Candidate,
}

// One active capability handle held by a process (from its start grant set or
// granted through the powerbox).
Held_Grant :: struct {
	active:               bool,
	handle_id:            u64,
	process_slot:         u32,
	principal:            u64,
	module_hash:          blake3.Hash,
	from_start_grant_set: bool,
	kind:                 powerbox.Request_Item_Kind,
	duration:             powerbox.Grant_Duration,
	target_item:          powerbox.Request_Item,
	network_rights:       powerbox.Network_Endpoint_Rights,
	store_id:             u64,
	store_access:         powerbox.Store_Access_Mode,
}

// One persisted Always grant row for a disk module, bound strictly to the
// module's BLAKE3 hash and principal, never to its nickname.
Always_Grant_Row :: struct {
	active:         bool,
	principal:      u64,
	module_hash:    blake3.Hash,
	kind:           powerbox.Request_Item_Kind,
	target_item:    powerbox.Request_Item,
	network_rights: powerbox.Network_Endpoint_Rights,
	store_id:       u64,
	store_access:   powerbox.Store_Access_Mode,
}

// Per-process rate-limit, refusal, and accounting state.
Asker_Record :: struct {
	active:                          bool,
	process_slot:                    u32,
	principal:                       u64,
	has_last_request:                bool,
	last_request_ms:                 u64,
	quiet_until_ms:                  u64,
	whole_refusals:                  u32,
	never_ask_kinds:                 bit_set[powerbox.Request_Item_Kind;u8],
	requests_total:                  u64,
	dialogs_shown:                   u64,
	items_granted:                   u64,
	items_refused:                   u64,
	requests_refused_without_dialog: u64,
}

// One pending dialog slot tracked by the powerbox state machine.
Pending_Dialog :: struct {
	state:                    Pending_Dialog_State,
	created_ms:               u64,
	shown_ms:                 u64,
	dialog:                   powerbox.Dialog_Record,
	original_item_count:      u32,
	original_item_held:       [powerbox.MAX_REQUEST_ITEMS]bool,
	original_item_held_handle: [powerbox.MAX_REQUEST_ITEMS]u64,
	dialog_to_original_index: [powerbox.MAX_REQUEST_ITEMS]u32,
}

// Per-item outcome returned to the asking process. Never exposes picker
// candidate lists or other store names.
Asker_Item_Resolution :: struct {
	decision:          powerbox.Item_Decision,
	duration:          powerbox.Grant_Duration,
	granted_handle_id: u64,
	store_access:      powerbox.Store_Access_Mode,
}

// Outcome returned to the asking process after submit_batch or resolve_answer.
Batch_Resolution :: struct {
	request_serial: u64,
	refusal:        powerbox.Powerbox_Refusal,
	dialog_queued:  bool,
	dialog_serial:  u64,
	all_held:       bool,
	item_count:     u32,
	items:          [powerbox.MAX_REQUEST_ITEMS]Asker_Item_Resolution,
}

// Aggregate counters for status inspection.
Powerbox_Counters :: struct {
	pending_dialogs:        u64,
	total_requests:         u64,
	total_dialogs_shown:    u64,
	total_items_granted:    u64,
	total_items_refused:    u64,
	total_refused_requests: u64,
	total_expired_dialogs:  u64,
}

// The tables of the powerbox that grow with the principal: its stores and
// the grants that processes hold. They are memory of the caller, which sizes
// them from its budget (docs/PROPERTIES.md, "14. Memory is supplied by the
// caller"); a full table is a refusal, a value.
Powerbox_Tables :: struct {
	stores:      []Session_Store,
	held_grants: []Held_Grant,
}

// The state of the powerbox policy engine.
Powerbox_State :: struct {
	trusted_display_slot: u32,
	next_dialog_serial:   u64,
	next_handle_id:       u64,
	picker_change_count:  u64,
	stores:               []Session_Store,
	pending:              [MAX_TOTAL_PENDING_DIALOGS]Pending_Dialog,
	askers:               [MAX_ASKERS]Asker_Record,
	held_grants:          []Held_Grant,
	always_rows:          [MAX_ALWAYS_ROWS]Always_Grant_Row,
	counters:             Powerbox_Counters,
}

// state_init resets a Powerbox_State, binds its tables to memory of the
// caller, and binds the trusted Display role holder slot. Only answers
// originating from this slot can resolve dialogs.
state_init :: proc "contextless" (state: ^Powerbox_State, trusted_display_slot: u32, tables: Powerbox_Tables) {
	state^ = {}
	for &store in tables.stores {
		store = {}
	}
	for &grant in tables.held_grants {
		grant = {}
	}
	state.stores = tables.stores
	state.held_grants = tables.held_grants
	state.trusted_display_slot = trusted_display_slot
	state.next_dialog_serial = 1
	state.next_handle_id = 1
	state.picker_change_count = 1
}

// register_session_store adds a principal-owned store to the picker candidate
// catalog. Candidates are strictly scoped to their principal.
register_session_store :: proc "contextless" (state: ^Powerbox_State, principal: u64, name: string, store_id: u64) -> bool {
	candidate, ok := powerbox.picker_candidate_make(name, store_id)
	if !ok {
		return false
	}
	for &existing in state.stores {
		if existing.active && existing.principal == principal {
			if existing.candidate.store_id == store_id || existing.candidate.name_hash == candidate.name_hash {
				return false
			}
		}
	}
	for &slot in state.stores {
		if !slot.active {
			slot = {active = true, principal = principal, candidate = candidate}
			state.picker_change_count += 1
			return true
		}
	}
	return false
}

// register_start_grant records an already-held capability from a process's
// start grant set so matching powerbox requests resolve immediately as Held.
register_start_grant :: proc "contextless" (
	state: ^Powerbox_State,
	process_slot: u32,
	principal: u64,
	module_hash: blake3.Hash,
	item: ^powerbox.Request_Item,
	store_id: u64 = 0,
) -> (handle_id: u64, ok: bool) {
	if process_slot == 0 || module_hash == (blake3.Hash{}) {
		return 0, false
	}
	kind, kind_ok := powerbox.request_item_kind_from_word(item.kind_word)
	if !kind_ok || kind == .Plan_Difference {
		return 0, false
	}
	net_rights: powerbox.Network_Endpoint_Rights
	store_mode: powerbox.Store_Access_Mode
	switch kind {
	case .None, .Plan_Difference:
		return 0, false
	case .Network_Endpoint:
		rights, rights_ok := powerbox.network_endpoint_rights_from_word(item.network_rights_word)
		if !rights_ok {
			return 0, false
		}
		net_rights = rights
	case .Store_Share:
		mode, mode_ok := powerbox.store_access_mode_from_word(item.store_access_word)
		if !mode_ok || store_id == 0 {
			return 0, false
		}
		store_mode = mode
	case .Service_Connection:
		if int(item.service_name_length) > powerbox.MAX_NAME_BYTES || !powerbox.service_name_is_requestable(item.service_name_bytes[:item.service_name_length]) {
			return 0, false
		}
	}
	for &slot in state.held_grants {
		if !slot.active {
			id := state.next_handle_id
			state.next_handle_id += 1
			slot = {
				active               = true,
				handle_id            = id,
				process_slot         = process_slot,
				principal            = principal,
				module_hash          = module_hash,
				from_start_grant_set = true,
				kind                 = kind,
				duration             = .This_Run,
				target_item          = item^,
				network_rights       = net_rights,
				store_id             = store_id,
				store_access         = store_mode,
			}
			return id, true
		}
	}
	return 0, false
}

// register_always_grant records a persisted Always grant row bound strictly to
// (principal, module_hash). Boot modules must never call this.
register_always_grant :: proc "contextless" (
	state: ^Powerbox_State,
	principal: u64,
	module_hash: blake3.Hash,
	item: ^powerbox.Request_Item,
	store_id: u64 = 0,
) -> bool {
	if module_hash == (blake3.Hash{}) {
		return false
	}
	kind, kind_ok := powerbox.request_item_kind_from_word(item.kind_word)
	if !kind_ok || kind == .Plan_Difference {
		return false
	}
	net_rights: powerbox.Network_Endpoint_Rights
	store_mode: powerbox.Store_Access_Mode
	switch kind {
	case .None, .Plan_Difference:
		return false
	case .Network_Endpoint:
		rights, rights_ok := powerbox.network_endpoint_rights_from_word(item.network_rights_word)
		if !rights_ok {
			return false
		}
		net_rights = rights
	case .Store_Share:
		mode, mode_ok := powerbox.store_access_mode_from_word(item.store_access_word)
		if !mode_ok || store_id == 0 {
			return false
		}
		store_mode = mode
	case .Service_Connection:
		if int(item.service_name_length) > powerbox.MAX_NAME_BYTES || !powerbox.service_name_is_requestable(item.service_name_bytes[:item.service_name_length]) {
			return false
		}
	}

	module_rows := 0
	for &existing in state.always_rows {
		if existing.active && existing.principal == principal && existing.module_hash == module_hash {
			module_rows += 1
		}
	}
	if module_rows >= MAX_ALWAYS_ROWS_PER_MODULE {
		return false
	}
	for &slot in state.always_rows {
		if !slot.active {
			slot = {
				active         = true,
				principal      = principal,
				module_hash    = module_hash,
				kind           = kind,
				target_item    = item^,
				network_rights = net_rights,
				store_id       = store_id,
				store_access   = store_mode,
			}
			return true
		}
	}
	return false
}

@(private = "file")
store_mode_covers :: proc "contextless" (held, asked: powerbox.Store_Access_Mode) -> bool {
	if held == .Read_Write {
		return asked == .Read_Only || asked == .Read_Write
	}
	return held == .Read_Only && asked == .Read_Only
}

@(private = "file")
grant_covers_item :: proc "contextless" (grant: ^Held_Grant, item: ^powerbox.Request_Item) -> bool {
	kind, kind_ok := powerbox.request_item_kind_from_word(item.kind_word)
	if !kind_ok || grant.kind != kind {
		return false
	}
	switch kind {
	case .None, .Plan_Difference:
		return false
	case .Network_Endpoint:
		if !powerbox.request_item_same_target(&grant.target_item, item) {
			return false
		}
		asked_rights, rights_ok := powerbox.network_endpoint_rights_from_word(item.network_rights_word)
		if !rights_ok {
			return false
		}
		return asked_rights <= grant.network_rights
	case .Store_Share:
		if item.former_grant_serial == 0 || item.former_grant_serial != grant.handle_id {
			return false
		}
		asked_mode, mode_ok := powerbox.store_access_mode_from_word(item.store_access_word)
		if !mode_ok {
			return false
		}
		return store_mode_covers(grant.store_access, asked_mode)
	case .Service_Connection:
		return powerbox.request_item_same_target(&grant.target_item, item)
	}
	return false
}

@(private = "file")
always_row_covers_item :: proc "contextless" (row: ^Always_Grant_Row, item: ^powerbox.Request_Item) -> bool {
	kind, kind_ok := powerbox.request_item_kind_from_word(item.kind_word)
	if !kind_ok || row.kind != kind {
		return false
	}
	switch kind {
	case .None, .Plan_Difference:
		return false
	case .Network_Endpoint:
		if !powerbox.request_item_same_target(&row.target_item, item) {
			return false
		}
		asked_rights, rights_ok := powerbox.network_endpoint_rights_from_word(item.network_rights_word)
		if !rights_ok {
			return false
		}
		return asked_rights <= row.network_rights
	case .Store_Share:
		// Store_Share requires the principal to pick a store unless a matching
		// Always row already bound a concrete store_id and covering mode.
		if row.store_id == 0 {
			return false
		}
		asked_mode, mode_ok := powerbox.store_access_mode_from_word(item.store_access_word)
		if !mode_ok {
			return false
		}
		return store_mode_covers(row.store_access, asked_mode)
	case .Service_Connection:
		return powerbox.request_item_same_target(&row.target_item, item)
	}
	return false
}

@(private = "file")
find_or_create_asker :: proc "contextless" (state: ^Powerbox_State, process_slot: u32, principal: u64) -> ^Asker_Record {
	for &asker in state.askers {
		if asker.active && asker.process_slot == process_slot && asker.principal == principal {
			return &asker
		}
	}
	for &asker in state.askers {
		if !asker.active {
			asker = {active = true, process_slot = process_slot, principal = principal}
			return &asker
		}
	}
	return nil
}

@(private = "file")
find_asker :: proc "contextless" (state: ^Powerbox_State, process_slot: u32, principal: u64) -> ^Asker_Record {
	for &asker in state.askers {
		if asker.active && asker.process_slot == process_slot && asker.principal == principal {
			return &asker
		}
	}
	return nil
}

@(private = "file")
find_held_grant_for_item :: proc "contextless" (
	state: ^Powerbox_State,
	process_slot: u32,
	principal: u64,
	item: ^powerbox.Request_Item,
) -> (handle_id: u64, found: bool) {
	for &grant in state.held_grants {
		if !grant.active || grant.process_slot != process_slot || grant.principal != principal {
			continue
		}
		if grant_covers_item(&grant, item) {
			return grant.handle_id, true
		}
	}
	return 0, false
}

@(private = "file")
find_always_row_for_item :: proc "contextless" (
	state: ^Powerbox_State,
	principal: u64,
	module_hash: blake3.Hash,
	item: ^powerbox.Request_Item,
) -> (row: ^Always_Grant_Row, found: bool) {
	for &candidate in state.always_rows {
		if !candidate.active || candidate.principal != principal || candidate.module_hash != module_hash {
			continue
		}
		if always_row_covers_item(&candidate, item) {
			return &candidate, true
		}
	}
	return nil, false
}

@(private = "file")
mint_held_grant :: proc "contextless" (
	state: ^Powerbox_State,
	process_slot: u32,
	principal: u64,
	module_hash: blake3.Hash,
	kind: powerbox.Request_Item_Kind,
	duration: powerbox.Grant_Duration,
	item: ^powerbox.Request_Item,
	net_rights: powerbox.Network_Endpoint_Rights,
	store_id: u64,
	store_access: powerbox.Store_Access_Mode,
) -> (handle_id: u64, ok: bool) {
	for &slot in state.held_grants {
		if !slot.active {
			id := state.next_handle_id
			state.next_handle_id += 1
			slot = {
				active               = true,
				handle_id            = id,
				process_slot         = process_slot,
				principal            = principal,
				module_hash          = module_hash,
				from_start_grant_set = false,
				kind                 = kind,
				duration             = duration,
				target_item          = item^,
				network_rights       = net_rights,
				store_id             = store_id,
				store_access         = store_access,
			}
			return id, true
		}
	}
	return 0, false
}

@(private = "file")
count_requested_grants_of_process :: proc "contextless" (state: ^Powerbox_State, process_slot: u32) -> int {
	count := 0
	for &grant in state.held_grants {
		if grant.active && grant.process_slot == process_slot && !grant.from_start_grant_set {
			count += 1
		}
	}
	return count
}

@(private = "file")
count_free_held_grant_slots :: proc "contextless" (state: ^Powerbox_State) -> int {
	free := 0
	for &grant in state.held_grants {
		if !grant.active {
			free += 1
		}
	}
	return free
}

@(private = "file")
saturating_add_u64 :: proc "contextless" (base, delta: u64) -> u64 {
	if max(u64) - base < delta {
		return max(u64)
	}
	return base + delta
}

// pending_count_for_session returns the number of active pending dialogs
// (Queued or Shown) for the given session principal.
pending_count_for_session :: proc "contextless" (state: ^Powerbox_State, principal: u64) -> u32 {
	count: u32 = 0
	for &entry in state.pending {
		if (entry.state == .Queued || entry.state == .Shown) && entry.dialog.session_principal == principal {
			count += 1
		}
	}
	return count
}

// expire_dialogs marks any Queued or Shown dialog whose age reached
// DIALOG_EXPIRY_MILLISECONDS as Expired, freeing its session queue slot with
// zero grants issued.
expire_dialogs :: proc "contextless" (state: ^Powerbox_State, now_ms: u64) -> (expired_count: u32) {
	for &entry in state.pending {
		if entry.state != .Queued && entry.state != .Shown {
			continue
		}
		if now_ms >= entry.created_ms && (now_ms - entry.created_ms) >= DIALOG_EXPIRY_MILLISECONDS {
			entry.state = .Expired
			if state.counters.pending_dialogs > 0 {
				state.counters.pending_dialogs -= 1
			}
			state.counters.total_expired_dialogs += 1
			expired_count += 1
		}
	}
	return expired_count
}

// submit_batch validates a grouped consent request batch, checks already-held
// grants, enforces frequency and queue bounds, and when needed builds a sealed
// Dialog_Record for the trusted Display holder.
//
// Picker candidate lists are populated ONLY into dialog_out for the Display
// holder and never appear in resolution returned to the asking process.
submit_batch :: proc "contextless" (
	state: ^Powerbox_State,
	batch: ^powerbox.Request_Batch,
	now_ms: u64,
) -> (resolution: Batch_Resolution, dialog_out: powerbox.Dialog_Record, has_dialog: bool) {
	resolution.request_serial = batch.request_serial

	// Step 1: border validation runs first; refused batches never consume rate
	// limit or mutate state.
	border_refusal, _ := powerbox.request_batch_validate(batch)
	if border_refusal != .None {
		resolution.refusal = border_refusal
		return resolution, {}, false
	}

	// Step 2: expire stale dialogs before checking queue capacity.
	expire_dialogs(state, now_ms)

	origin, _ := powerbox.module_origin_from_word(batch.asker_module_origin)

	// Step 3: check already-held grants and hash-bound Always rows (for disk
	// modules only). If every item is already held, answer immediately with no
	// dialog and no principal interruption.
	item_held: [powerbox.MAX_REQUEST_ITEMS]bool
	item_held_handle: [powerbox.MAX_REQUEST_ITEMS]u64
	item_held_mode: [powerbox.MAX_REQUEST_ITEMS]powerbox.Store_Access_Mode
	unheld_count: u32 = 0
	need_picker := false
	is_plan_difference := false

	for index in u32(0) ..< batch.item_count {
		item := &batch.items[index]
		kind, _ := powerbox.request_item_kind_from_word(item.kind_word)
		if kind == .Plan_Difference {
			is_plan_difference = true
		}

		if existing_handle, found := find_held_grant_for_item(state, batch.asker_process_slot, batch.asker_principal, item); found {
			item_held[index] = true
			item_held_handle[index] = existing_handle
			if grant, gok := lookup_issued_grant(state, existing_handle); gok {
				item_held_mode[index] = grant.store_access
			}
			continue
		}

		if origin == .Disk_Module {
			if row, found := find_always_row_for_item(state, batch.asker_principal, batch.asker_module_hash, item); found {
				if count_requested_grants_of_process(state, batch.asker_process_slot) < MAX_REQUESTED_GRANTS_PER_PROCESS {
					if materialized, minted := mint_held_grant(
						state,
						batch.asker_process_slot,
						batch.asker_principal,
						batch.asker_module_hash,
						row.kind,
						.Always,
						&row.target_item,
						row.network_rights,
						row.store_id,
						row.store_access,
					); minted {
						item_held[index] = true
						item_held_handle[index] = materialized
						item_held_mode[index] = row.store_access
						continue
					}
				}
			}
		}

		unheld_count += 1
		if kind == .Store_Share {
			need_picker = true
		}
	}

	if unheld_count == 0 {
		state.counters.total_requests += 1
		if asker := find_or_create_asker(state, batch.asker_process_slot, batch.asker_principal); asker != nil {
			asker.requests_total += 1
		}
		resolution.all_held = true
		resolution.item_count = batch.item_count
		for index in u32(0) ..< batch.item_count {
			resolution.items[index] = {
				decision          = .Held,
				duration          = .This_Run,
				granted_handle_id = item_held_handle[index],
				store_access      = item_held_mode[index],
			}
		}
		return resolution, {}, false
	}

	// Step 4: frequency, quiet-time, never-ask-again, and run-refusal bounds.
	asker := find_or_create_asker(state, batch.asker_process_slot, batch.asker_principal)
	if asker == nil {
		resolution.refusal = .Dialog_Queue_Full
		state.counters.total_refused_requests += 1
		return resolution, {}, false
	}

	if asker.whole_refusals >= MAX_WHOLE_REFUSALS_PER_RUN {
		asker.requests_refused_without_dialog += 1
		state.counters.total_refused_requests += 1
		resolution.refusal = .Rate_Limited
		return resolution, {}, false
	}
	if now_ms < asker.quiet_until_ms {
		asker.requests_refused_without_dialog += 1
		state.counters.total_refused_requests += 1
		resolution.refusal = .Rate_Limited
		return resolution, {}, false
	}
	if asker.has_last_request {
		if now_ms < asker.last_request_ms || (now_ms - asker.last_request_ms) < RATE_LIMIT_MILLISECONDS {
			asker.requests_refused_without_dialog += 1
			state.counters.total_refused_requests += 1
			resolution.refusal = .Rate_Limited
			return resolution, {}, false
		}
	}
	for index in u32(0) ..< batch.item_count {
		if item_held[index] {
			continue
		}
		kind, _ := powerbox.request_item_kind_from_word(batch.items[index].kind_word)
		if kind in asker.never_ask_kinds {
			asker.requests_refused_without_dialog += 1
			state.counters.total_refused_requests += 1
			resolution.refusal = .Rate_Limited
			return resolution, {}, false
		}
	}

	// Step 5: enforce per-session queue bound (MAX_PENDING_DIALOGS).
	if pending_count_for_session(state, batch.asker_principal) >= MAX_PENDING_DIALOGS {
		asker.requests_refused_without_dialog += 1
		state.counters.total_refused_requests += 1
		resolution.refusal = .Dialog_Queue_Full
		return resolution, {}, false
	}

	pending_index := -1
	for &slot, idx in state.pending {
		if slot.state == .Empty || slot.state == .Resolved || slot.state == .Expired || slot.state == .Withdrawn {
			pending_index = idx
			break
		}
	}
	if pending_index < 0 {
		asker.requests_refused_without_dialog += 1
		state.counters.total_refused_requests += 1
		resolution.refusal = .Dialog_Queue_Full
		return resolution, {}, false
	}

	// Step 6: build sealed Dialog_Record for the trusted Display holder.
	dialog_serial := state.next_dialog_serial
	dialog := powerbox.Dialog_Record {
		action_word           = is_plan_difference ? u64(powerbox.Dialog_Action.Show_Plan_Difference) : u64(powerbox.Dialog_Action.Show_Grant_Dialog),
		dialog_serial         = dialog_serial,
		request_serial        = batch.request_serial,
		session_principal     = batch.asker_principal,
		asker_process_slot    = batch.asker_process_slot,
		asker_module_origin   = batch.asker_module_origin,
		asker_module_hash     = batch.asker_module_hash,
		asker_label_bytes     = batch.asker_label_bytes,
		asker_label_length    = batch.asker_label_length,
		allow_per_item_ticks  = !is_plan_difference,
		allow_duration_choice = !is_plan_difference,
		allow_always_duration = !is_plan_difference && origin == .Disk_Module,
		item_count            = unheld_count,
	}

	dialog_to_orig: [powerbox.MAX_REQUEST_ITEMS]u32
	out_idx: u32 = 0
	for index in u32(0) ..< batch.item_count {
		if item_held[index] {
			continue
		}
		dialog.items[out_idx] = batch.items[index]
		dialog_to_orig[out_idx] = index
		out_idx += 1
	}

	if need_picker {
		// The dialog carries the first page and the count of the whole
		// list; the trusted display reads the other pages (picker_page_take).
		dialog.picker_change_count = state.picker_change_count
		cand_count: u32 = 0
		total: u32 = 0
		for &store in state.stores {
			if !store.active || store.principal != batch.asker_principal {
				continue
			}
			if cand_count < powerbox.PICKER_PAGE_CANDIDATES {
				dialog.picker_candidates[cand_count] = store.candidate
				dialog.picker_candidates[cand_count].list_index = total
				cand_count += 1
			}
			total += 1
		}
		dialog.picker_candidate_total = total
		dialog.picker_candidate_count = cand_count
	}

	seal_refusal := powerbox.dialog_record_seal(&dialog)
	if seal_refusal != .None {
		resolution.refusal = seal_refusal
		state.counters.total_refused_requests += 1
		return resolution, {}, false
	}

	// Step 7: commit pending dialog slot and rate-limit state.
	state.next_dialog_serial += 1
	state.pending[pending_index] = {
		state                     = .Queued,
		created_ms                = now_ms,
		shown_ms                  = 0,
		dialog                    = dialog,
		original_item_count       = batch.item_count,
		original_item_held        = item_held,
		original_item_held_handle = item_held_handle,
		dialog_to_original_index  = dialog_to_orig,
	}
	asker.has_last_request = true
	asker.last_request_ms = now_ms
	asker.requests_total += 1
	state.counters.total_requests += 1
	state.counters.pending_dialogs += 1

	resolution.dialog_queued = true
	resolution.dialog_serial = dialog_serial
	resolution.item_count = batch.item_count
	for index in u32(0) ..< batch.item_count {
		if item_held[index] {
			resolution.items[index] = {
				decision          = .Held,
				duration          = .This_Run,
				granted_handle_id = item_held_handle[index],
				store_access      = item_held_mode[index],
			}
		}
	}
	return resolution, dialog, true
}

// mark_dialog_shown records the monotonic timestamp at which the trusted
// Display role holder rendered the dialog whole on screen. Only the Display
// holder may report Shown, and a dialog must be Shown before any answer counts.
mark_dialog_shown :: proc "contextless" (
	state: ^Powerbox_State,
	dialog_serial: u64,
	display_holder_slot: u32,
	now_ms: u64,
) -> powerbox.Powerbox_Refusal {
	if state.trusted_display_slot == 0 || display_holder_slot != state.trusted_display_slot {
		return .Untrusted_Answer
	}
	if dialog_serial == 0 {
		return .Untrusted_Answer
	}
	expire_dialogs(state, now_ms)

	for &entry in state.pending {
		if entry.state == .Queued && entry.dialog.dialog_serial == dialog_serial {
			if now_ms < entry.created_ms {
				return .Untrusted_Answer
			}
			entry.state = .Shown
			entry.shown_ms = now_ms
			state.counters.total_dialogs_shown += 1
			if asker := find_asker(state, entry.dialog.asker_process_slot, entry.dialog.session_principal); asker != nil {
				asker.dialogs_shown += 1
			}
			return .None
		}
	}
	return .Untrusted_Answer
}

// resolve_answer validates a Grant_Answer from the trusted Display holder,
// enforces anti-clickjacking focus delay (250 ms) and expiry (60 s), and
// atomically mints attenuated grants only when every check succeeds. On any
// refusal, zero grants are issued.
resolve_answer :: proc "contextless" (
	state: ^Powerbox_State,
	answer: ^powerbox.Grant_Answer,
	now_ms: u64,
) -> (resolution: Batch_Resolution) {
	resolution.request_serial = answer.request_serial
	resolution.dialog_serial = answer.dialog_serial

	if state.trusted_display_slot == 0 || answer.display_holder_slot != state.trusted_display_slot {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}
	if answer.dialog_serial == 0 {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}

	// Locate the active pending dialog by serial.
	entry: ^Pending_Dialog = nil
	for &candidate in state.pending {
		if (candidate.state == .Queued || candidate.state == .Shown) && candidate.dialog.dialog_serial == answer.dialog_serial {
			entry = &candidate
			break
		}
	}
	if entry == nil {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}

	// Check expiry before validating answer: an expired dialog resolves as
	// Expired with zero grants issued.
	if now_ms >= entry.created_ms && (now_ms - entry.created_ms) >= DIALOG_EXPIRY_MILLISECONDS {
		entry.state = .Expired
		if state.counters.pending_dialogs > 0 {
			state.counters.pending_dialogs -= 1
		}
		state.counters.total_expired_dialogs += 1
		resolution.request_serial = entry.dialog.request_serial
		resolution.item_count = entry.original_item_count
		for index in u32(0) ..< entry.original_item_count {
			if entry.original_item_held[index] {
				resolution.items[index] = {
					decision          = .Held,
					duration          = .This_Run,
					granted_handle_id = entry.original_item_held_handle[index],
				}
			} else {
				resolution.items[index] = {decision = .Expired}
			}
		}
		return resolution
	}

	// A dialog must have been marked Shown before an answer can be accepted.
	if entry.state != .Shown {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}

	// Contract border validation: checks trusted display slot, Local_Machine
	// input origin, serials, canonical dialog_record_hash, whole-or-nothing
	// Plan_Difference rule, boot-module Always prohibition, and picker bounds.
	border_refusal, _ := powerbox.answer_record_validate(&entry.dialog, answer, state.trusted_display_slot)
	if border_refusal != .None {
		resolution.refusal = border_refusal
		return resolution
	}

	// Anti-clickjacking monotonic delay check: dialog must have been visible on
	// screen for at least MIN_DISPLAY_ARM_MILLISECONDS (250 ms) before both the
	// press start and the answer commit. Subtraction is guarded against u64
	// underflow and addition overflow.
	if answer.shown_timestamp_ms != entry.shown_ms {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}
	if now_ms < entry.shown_ms || (now_ms - entry.shown_ms) < MIN_DISPLAY_ARM_MILLISECONDS {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}
	if answer.input_press_timestamp_ms < entry.shown_ms || (answer.input_press_timestamp_ms - entry.shown_ms) < MIN_DISPLAY_ARM_MILLISECONDS {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}
	if answer.answer_timestamp_ms < answer.input_press_timestamp_ms || answer.answer_timestamp_ms > now_ms {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}
	if (answer.answer_timestamp_ms - entry.shown_ms) < MIN_DISPLAY_ARM_MILLISECONDS {
		resolution.refusal = .Untrusted_Answer
		return resolution
	}

	// Two-phase commit pre-check: ensure capacity for every granted item, and
	// find each store that a pick names in the whole list, before minting any
	// handle so a refusal never leaks partial grants.
	grants_needed := 0
	picked_stores: [powerbox.MAX_REQUEST_ITEMS]u64
	for index in u32(0) ..< answer.item_count {
		dec, _ := powerbox.item_decision_from_word(answer.items[index].decision_word)
		if dec != .Granted {
			continue
		}
		grants_needed += 1
		kind, _ := powerbox.request_item_kind_from_word(entry.dialog.items[index].kind_word)
		if kind != .Store_Share {
			continue
		}
		// The list changed since the dialog: its places name other stores.
		if state.picker_change_count != entry.dialog.picker_change_count {
			resolution.refusal = .Picker_Selection_Invalid
			return resolution
		}
		picked := principal_store_at(state, entry.dialog.session_principal, answer.items[index].picker_index)
		if picked == nil || picked.candidate.name_hash != answer.items[index].picker_name_hash {
			resolution.refusal = .Picker_Selection_Invalid
			return resolution
		}
		picked_stores[index] = picked.candidate.store_id
	}
	if grants_needed > 0 {
		existing_count := count_requested_grants_of_process(state, entry.dialog.asker_process_slot)
		if existing_count + grants_needed > MAX_REQUESTED_GRANTS_PER_PROCESS || count_free_held_grant_slots(state) < grants_needed {
			resolution.refusal = .Dialog_Queue_Full
			return resolution
		}
	}

	// Commit phase: every check passed; mint attenuated handles and record outcomes.
	resolution.request_serial = entry.dialog.request_serial
	resolution.item_count = entry.original_item_count
	for index in u32(0) ..< entry.original_item_count {
		if entry.original_item_held[index] {
			resolution.items[index] = {
				decision          = .Held,
				duration          = .This_Run,
				granted_handle_id = entry.original_item_held_handle[index],
			}
		}
	}

	origin, _ := powerbox.module_origin_from_word(entry.dialog.asker_module_origin)
	asker := find_asker(state, entry.dialog.asker_process_slot, entry.dialog.session_principal)
	granted_in_dialog: u32 = 0
	refused_in_dialog: u32 = 0

	for dialog_idx in u32(0) ..< answer.item_count {
		orig_idx := entry.dialog_to_original_index[dialog_idx]
		req_item := &entry.dialog.items[dialog_idx]
		item_ans := &answer.items[dialog_idx]
		kind, _ := powerbox.request_item_kind_from_word(req_item.kind_word)
		decision, _ := powerbox.item_decision_from_word(item_ans.decision_word)

		switch decision {
		case .None, .Held, .Invalid:
			// Already prevented by answer_record_validate.
			resolution.items[orig_idx] = {decision = .Invalid}
		case .Refused, .Expired:
			refused_in_dialog += 1
			state.counters.total_items_refused += 1
			if asker != nil {
				asker.items_refused += 1
			}
			resolution.items[orig_idx] = {decision = decision}
		case .Granted:
			duration := powerbox.Grant_Duration.None
			if kind != .Plan_Difference {
				duration, _ = powerbox.grant_duration_from_word(item_ans.duration_word)
			}
			net_rights: powerbox.Network_Endpoint_Rights
			store_id: u64 = 0
			store_access := powerbox.Store_Access_Mode.None

			switch kind {
			case .None:
			case .Network_Endpoint:
				net_rights, _ = powerbox.network_endpoint_rights_from_word(req_item.network_rights_word)
			case .Store_Share:
				// Picker isolation: mint an attenuated handle for ONLY the
				// single store chosen by the principal.
				store_id = picked_stores[dialog_idx]
				store_access, _ = powerbox.store_access_mode_from_word(req_item.store_access_word)
			case .Service_Connection:
			case .Plan_Difference:
			}

			effective_duration := duration
			if duration == .Always && origin == .Disk_Module && kind != .Plan_Difference {
				if !register_always_grant(state, entry.dialog.session_principal, entry.dialog.asker_module_hash, req_item, store_id) {
					effective_duration = .This_Run
				}
			}

			handle_id, _ := mint_held_grant(
				state,
				entry.dialog.asker_process_slot,
				entry.dialog.session_principal,
				entry.dialog.asker_module_hash,
				kind,
				effective_duration,
				req_item,
				net_rights,
				store_id,
				store_access,
			)
			granted_in_dialog += 1
			state.counters.total_items_granted += 1
			if asker != nil {
				asker.items_granted += 1
			}
			resolution.items[orig_idx] = {
				decision          = .Granted,
				duration          = effective_duration,
				granted_handle_id = handle_id,
				store_access      = store_access,
			}
		}
	}

	// Whole-dialog refusal tracking: quiet time + run cap + optional never-ask-again.
	if granted_in_dialog == 0 && refused_in_dialog > 0 && asker != nil {
		asker.whole_refusals += 1
		asker.quiet_until_ms = saturating_add_u64(now_ms, QUIET_TIME_AFTER_REFUSAL_MILLISECONDS)
		if answer.never_ask_again {
			for dialog_idx in u32(0) ..< entry.dialog.item_count {
				kind, kind_ok := powerbox.request_item_kind_from_word(entry.dialog.items[dialog_idx].kind_word)
				if kind_ok {
					asker.never_ask_kinds += {kind}
				}
			}
		}
	}

	entry.state = .Resolved
	if state.counters.pending_dialogs > 0 {
		state.counters.pending_dialogs -= 1
	}
	return resolution
}

// lookup_issued_grant returns the active Held_Grant for handle_id.
lookup_issued_grant :: proc "contextless" (state: ^Powerbox_State, handle_id: u64) -> (grant: Held_Grant, found: bool) {
	if handle_id == 0 {
		return {}, false
	}
	for &candidate in state.held_grants {
		if candidate.active && candidate.handle_id == handle_id {
			return candidate, true
		}
	}
	return {}, false
}

// revoke_grant revokes one powerbox-issued handle by handle_id. Start grants
// are not revoked by this path.
revoke_grant :: proc "contextless" (state: ^Powerbox_State, handle_id: u64) -> bool {
	if handle_id == 0 {
		return false
	}
	for &candidate in state.held_grants {
		if candidate.active && candidate.handle_id == handle_id && !candidate.from_start_grant_set {
			candidate = {}
			return true
		}
	}
	return false
}

// withdraw_for_process withdraws every pending dialog of process_slot and ends
// its active grants when the process stops. Persisted Always rows remain intact.
withdraw_for_process :: proc "contextless" (state: ^Powerbox_State, process_slot: u32) -> (withdrawn_dialogs: u32, revoked_grants: u32) {
	if process_slot == 0 {
		return 0, 0
	}
	for &entry in state.pending {
		if (entry.state == .Queued || entry.state == .Shown) && entry.dialog.asker_process_slot == process_slot {
			entry.state = .Withdrawn
			if state.counters.pending_dialogs > 0 {
				state.counters.pending_dialogs -= 1
			}
			withdrawn_dialogs += 1
		}
	}
	for &grant in state.held_grants {
		if grant.active && grant.process_slot == process_slot {
			grant = {}
			revoked_grants += 1
		}
	}
	return withdrawn_dialogs, revoked_grants
}

// lock_session withdraws all pending dialogs and ends all active session grants
// for principal while keeping persisted Always rows intact.
lock_session :: proc "contextless" (state: ^Powerbox_State, principal: u64) -> (withdrawn_dialogs: u32, revoked_grants: u32) {
	for &entry in state.pending {
		if (entry.state == .Queued || entry.state == .Shown) && entry.dialog.session_principal == principal {
			entry.state = .Withdrawn
			if state.counters.pending_dialogs > 0 {
				state.counters.pending_dialogs -= 1
			}
			withdrawn_dialogs += 1
		}
	}
	for &grant in state.held_grants {
		if grant.active && grant.principal == principal {
			grant = {}
			revoked_grants += 1
		}
	}
	return withdrawn_dialogs, revoked_grants
}

// active_grant_count counts all currently active Held_Grant records.
active_grant_count :: proc "contextless" (state: ^Powerbox_State) -> u32 {
	count: u32 = 0
	for &grant in state.held_grants {
		if grant.active {
			count += 1
		}
	}
	return count
}

// principal_store_at gives the store at a place of the list of a principal,
// in the order of the table, or nil past its end.
principal_store_at :: proc "contextless" (state: ^Powerbox_State, principal: u64, list_index: u32) -> ^Session_Store {
	place: u32 = 0
	for &store in state.stores {
		if !store.active || store.principal != principal {
			continue
		}
		if place == list_index {
			return &store
		}
		place += 1
	}
	return nil
}

// picker_page_take writes one page of the candidates of a pending dialog
// for the trusted display: the stores of the principal of the dialog from
// the place request.first on, whose names hold the search text of the
// request. Only the trusted display reads a page, and the asking process
// never sees one. A list that changed since the dialog is refused: its
// places name other stores, and the principal asks again.
picker_page_take :: proc "contextless" (state: ^Powerbox_State, display_holder_slot: u32, request: ^powerbox.Picker_Page_Request, page: ^powerbox.Picker_Page) -> powerbox.Powerbox_Refusal {
	page^ = {}
	if state.trusted_display_slot == 0 || display_holder_slot != state.trusted_display_slot {
		return .Untrusted_Answer
	}
	if refusal := powerbox.picker_page_request_validate(request); refusal != .None {
		return refusal
	}
	entry: ^Pending_Dialog
	for &candidate in state.pending {
		if (candidate.state == .Queued || candidate.state == .Shown) && candidate.dialog.dialog_serial == request.dialog_serial {
			entry = &candidate
			break
		}
	}
	// A dialog of an asker with no picker has no page; the picker of the
	// display has its page, empty for a principal with no store.
	picker_of_the_display := entry != nil && entry.dialog.asker_process_slot == 0 && entry.dialog.items[0].kind_word == u64(powerbox.Request_Item_Kind.Store_Share)
	if entry == nil || (entry.dialog.picker_candidate_total == 0 && !picker_of_the_display) {
		return .Untrusted_Answer
	}
	if state.picker_change_count != entry.dialog.picker_change_count {
		return .Picker_Selection_Invalid
	}
	query := request.query_bytes[:request.query_length]
	page.dialog_serial = request.dialog_serial
	page.change_count = entry.dialog.picker_change_count
	page.first = min(request.first, entry.dialog.picker_candidate_total)
	page.total = entry.dialog.picker_candidate_total
	page.next = page.total
	place: u32 = 0
	for &store in state.stores {
		if !store.active || store.principal != entry.dialog.session_principal {
			continue
		}
		defer place += 1
		if place < page.first || !powerbox.picker_name_matches(store.candidate.name_bytes[:store.candidate.name_length], query) {
			continue
		}
		if page.candidate_count == powerbox.PICKER_PAGE_CANDIDATES {
			page.next = place
			page.more = true
			break
		}
		page.candidates[page.candidate_count] = store.candidate
		page.candidates[page.candidate_count].list_index = place
		page.candidate_count += 1
	}
	return .None
}
// stores_replace_begin ends each store of principal in the table: the list
// that follows replaces it. The change count moves, so a dialog that showed
// the old list refuses each page and each pick.
stores_replace_begin :: proc "contextless" (state: ^Powerbox_State, principal: u64) {
	for &store in state.stores {
		if store.active && store.principal == principal {
			store = {}
		}
	}
	state.picker_change_count += 1
}

// The picker of the trusted display for a caller that acts for its
// principal: a pending dialog with no asking process (its asker slot is
// 0), whose candidates are the stores of the principal. It expires as each
// dialog does, and its pages and its pick are checked against the copy of
// the list, as the pages and the pick of the dialog of an asker are.
picker_dialog_open :: proc "contextless" (state: ^Powerbox_State, principal: u64, now_ms: u64) -> (dialog_serial: u64, refusal: powerbox.Powerbox_Refusal) {
	free: ^Pending_Dialog
	for &entry in state.pending {
		if entry.state != .Queued && entry.state != .Shown {
			free = &entry
			break
		}
	}
	if free == nil {
		return 0, .Dialog_Queue_Full
	}
	total: u32 = 0
	for &store in state.stores {
		if store.active && store.principal == principal {
			total += 1
		}
	}
	dialog_serial = state.next_dialog_serial
	state.next_dialog_serial += 1
	free^ = {state = .Shown, created_ms = now_ms, shown_ms = now_ms}
	free.dialog.action_word = u64(powerbox.Dialog_Action.Show_Grant_Dialog)
	free.dialog.dialog_serial = dialog_serial
	free.dialog.session_principal = principal
	free.dialog.item_count = 1
	free.dialog.items[0].kind_word = u64(powerbox.Request_Item_Kind.Store_Share)
	free.dialog.picker_change_count = state.picker_change_count
	free.dialog.picker_candidate_total = total
	state.counters.pending_dialogs += 1
	return dialog_serial, .None
}

// picker_dialog_find gives the picker dialog of a serial that still shows.
@(private = "file")
picker_dialog_find :: proc "contextless" (state: ^Powerbox_State, dialog_serial: u64) -> ^Pending_Dialog {
	for &entry in state.pending {
		if (entry.state == .Queued || entry.state == .Shown) && entry.dialog.dialog_serial == dialog_serial && entry.dialog.asker_process_slot == 0 && entry.dialog.items[0].kind_word == u64(powerbox.Request_Item_Kind.Store_Share) {
			return &entry
		}
	}
	return nil
}

@(private = "file")
picker_dialog_end :: proc "contextless" (state: ^Powerbox_State, entry: ^Pending_Dialog) {
	entry.state = .Resolved
	if state.counters.pending_dialogs > 0 {
		state.counters.pending_dialogs -= 1
	}
}

// picker_dialog_pick checks the pick of the trusted display against the
// copy of the list: the dialog, the change count, the place in the whole
// list and the hash of the name. It ends the dialog, picked or refused.
picker_dialog_pick :: proc "contextless" (state: ^Powerbox_State, display_holder_slot: u32, dialog_serial: u64, list_index: u32, change_count: u64, name_hash: blake3.Hash) -> (picked: Session_Store, refusal: powerbox.Powerbox_Refusal) {
	if state.trusted_display_slot == 0 || display_holder_slot != state.trusted_display_slot {
		return {}, .Untrusted_Answer
	}
	entry := picker_dialog_find(state, dialog_serial)
	if entry == nil {
		return {}, .Untrusted_Answer
	}
	defer picker_dialog_end(state, entry)
	if change_count != entry.dialog.picker_change_count || state.picker_change_count != change_count {
		return {}, .Picker_Selection_Invalid
	}
	store := principal_store_at(state, entry.dialog.session_principal, list_index)
	if store == nil || store.candidate.name_hash != name_hash {
		return {}, .Picker_Selection_Invalid
	}
	return store^, .None
}

// picker_dialog_close ends a picker dialog with no pick.
picker_dialog_close :: proc "contextless" (state: ^Powerbox_State, display_holder_slot: u32, dialog_serial: u64) -> powerbox.Powerbox_Refusal {
	if state.trusted_display_slot == 0 || display_holder_slot != state.trusted_display_slot {
		return .Untrusted_Answer
	}
	entry := picker_dialog_find(state, dialog_serial)
	if entry == nil {
		return .Untrusted_Answer
	}
	picker_dialog_end(state, entry)
	return .None
}
