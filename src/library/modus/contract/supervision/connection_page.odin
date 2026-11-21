// Connection page: fixed-layout shared page written by the root service and
// mapped read-only by the client and the role holder so a connection survives
// holder restarts without a new grant (src/md/features/supervision.md).
package supervision

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:contract/role_contract"

// Fixed-layout shared memory record placed at offset 0 of a connection page.
// The root service is the sole writer; clients and holders map it read-only
// and take a consistent snapshot through connection_page_read.
Connection_Page :: struct {
	magic:                         u64, // CONNECTION_PAGE_MAGIC.
	version:                       u32, // CONNECTION_PAGE_VERSION.
	change_count:                  u32, // Even when stable, odd while a write is in progress.
	connection_serial:             u64, // Unique non-zero serial assigned to this connection.
	holder_generation:             u64, // Monotonically increasing process serial or generation of the active holder.
	role_word:                     u64, // Transport word of role_contract.Role.
	state_word:                    u32, // Transport word of Connection_State.
	stop_cause_word:               u32, // Transport word of op.Stop_Cause; zero while active.
	stop_outcome_word:             u32, // Transport word of op.Stop_Outcome; zero unless stop_cause is Itself.
	pending_call_count:            u32, // Number of calls currently in flight on this connection.
	last_committed_request_serial: u64, // Last request serial committed by the holder for this connection.
	reserved:                      [8]u64, // Must be zero.
}
#assert(size_of(Connection_Page) == 128)
#assert(size_of(Connection_Page) <= CONNECTION_PAGE_SIZE)

// Validated snapshot read across the connection page border. Every choice
// field holds its closed enum member rather than a raw transport word.
Connection_Snapshot :: struct {
	connection_serial:             u64,
	holder_generation:             u64,
	role:                          role_contract.Role,
	state:                         Connection_State,
	stop_cause:                    op.Stop_Cause,
	stop_outcome:                  op.Stop_Outcome,
	pending_call_count:            u32,
	last_committed_request_serial: u64,
}

// Why reading or updating a connection page was refused. Any refusal leaves
// the connection page unchanged.
Connection_Page_Refusal :: enum u8 {
	None                          = 0,
	Null_Page                     = 1,
	Bad_Magic                     = 2,
	Bad_Version                   = 3,
	Reserved_Not_Zero             = 4,
	Zero_Connection_Serial        = 5,
	Zero_Holder_Generation        = 6,
	Invalid_Role                  = 7,
	Invalid_State                 = 8,
	Invalid_Stop_Words            = 9,
	Stop_Words_While_Active       = 10,
	Invalid_Transition            = 11,
	Holder_Generation_Not_Advanced = 12,
	Request_Serial_Regressed      = 13,
	Concurrent_Write_In_Progress  = 14,
}

// connection_state_transition_allowed reports whether a connection page may
// move directly from one validated Connection_State to another. Closed is
// terminal and never reopens.
connection_state_transition_allowed :: proc "contextless" (from: Connection_State, to: Connection_State) -> bool {
	switch from {
	case .None:
		return false
	case .Connected:
		switch to {
		case .Holder_Stopped, .Closed:
			return true
		case .None, .Connected, .Reconnecting:
			return false
		}
	case .Holder_Stopped:
		switch to {
		case .Reconnecting, .Connected, .Closed:
			return true
		case .None, .Holder_Stopped:
			return false
		}
	case .Reconnecting:
		switch to {
		case .Connected, .Holder_Stopped, .Closed:
			return true
		case .None, .Reconnecting:
			return false
		}
	case .Closed:
		return false
	}
	return false
}

// connection_page_validate_copy validates a local copy of Connection_Page at
// the border, turning every transport word into its closed enum and refusing
// any inconsistent pair of state and stop words.
connection_page_validate_copy :: proc "contextless" (copied: Connection_Page) -> (snapshot: Connection_Snapshot, refusal: Connection_Page_Refusal) {
	if copied.magic != CONNECTION_PAGE_MAGIC {
		return {}, .Bad_Magic
	}
	if copied.version != CONNECTION_PAGE_VERSION {
		return {}, .Bad_Version
	}
	if copied.reserved != ([8]u64{}) {
		return {}, .Reserved_Not_Zero
	}
	if copied.connection_serial == 0 {
		return {}, .Zero_Connection_Serial
	}
	if copied.holder_generation == 0 {
		return {}, .Zero_Holder_Generation
	}
	role, role_ok := role_contract.role_from_word(copied.role_word)
	if !role_ok {
		return {}, .Invalid_Role
	}
	state, state_ok := connection_state_from_word(u64(copied.state_word))
	if !state_ok {
		return {}, .Invalid_State
	}

	stop_cause := op.Stop_Cause.None
	stop_outcome := op.Stop_Outcome.None
	switch state {
	case .None:
		return {}, .Invalid_State
	case .Connected, .Reconnecting:
		if copied.stop_cause_word != 0 || copied.stop_outcome_word != 0 {
			return {}, .Stop_Words_While_Active
		}
	case .Holder_Stopped:
		_, parsed_cause, parsed_outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), u64(copied.stop_cause_word), u64(copied.stop_outcome_word))
		if !stop_ok {
			return {}, .Invalid_Stop_Words
		}
		stop_cause = parsed_cause
		stop_outcome = parsed_outcome
	case .Closed:
		if copied.stop_cause_word != 0 || copied.stop_outcome_word != 0 {
			_, parsed_cause, parsed_outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), u64(copied.stop_cause_word), u64(copied.stop_outcome_word))
			if !stop_ok {
				return {}, .Invalid_Stop_Words
			}
			stop_cause = parsed_cause
			stop_outcome = parsed_outcome
		}
	}

	return Connection_Snapshot{
		connection_serial             = copied.connection_serial,
		holder_generation             = copied.holder_generation,
		role                          = role,
		state                         = state,
		stop_cause                    = stop_cause,
		stop_outcome                  = stop_outcome,
		pending_call_count            = copied.pending_call_count,
		last_committed_request_serial = copied.last_committed_request_serial,
	}, .None
}

// connection_page_read takes a consistent atomic snapshot of a connection page
// under its seqlock and validates every word through the border.
connection_page_read :: proc "contextless" (page: ^Connection_Page) -> (snapshot: Connection_Snapshot, refusal: Connection_Page_Refusal) {
	if page == nil {
		return {}, .Null_Page
	}
	for _ in 0 ..< CONNECTION_PAGE_READ_ATTEMPTS {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if (before & 1) != 0 {
			continue
		}
		copied: Connection_Page
		copied.magic = intrinsics.atomic_load_explicit(&page.magic, .Relaxed)
		copied.version = intrinsics.atomic_load_explicit(&page.version, .Relaxed)
		copied.change_count = before
		copied.connection_serial = intrinsics.atomic_load_explicit(&page.connection_serial, .Relaxed)
		copied.holder_generation = intrinsics.atomic_load_explicit(&page.holder_generation, .Relaxed)
		copied.role_word = intrinsics.atomic_load_explicit(&page.role_word, .Relaxed)
		copied.state_word = intrinsics.atomic_load_explicit(&page.state_word, .Acquire)
		copied.stop_cause_word = intrinsics.atomic_load_explicit(&page.stop_cause_word, .Relaxed)
		copied.stop_outcome_word = intrinsics.atomic_load_explicit(&page.stop_outcome_word, .Relaxed)
		copied.pending_call_count = intrinsics.atomic_load_explicit(&page.pending_call_count, .Relaxed)
		copied.last_committed_request_serial = intrinsics.atomic_load_explicit(&page.last_committed_request_serial, .Relaxed)
		for index in 0 ..< len(copied.reserved) {
			copied.reserved[index] = intrinsics.atomic_load_explicit(&page.reserved[index], .Relaxed)
		}
		intrinsics.atomic_thread_fence(.Acquire)
		after := intrinsics.atomic_load_explicit(&page.change_count, .Relaxed)
		if before == after {
			return connection_page_validate_copy(copied)
		}
	}
	return {}, .Concurrent_Write_In_Progress
}

@(private = "file")
connection_page_write_fields :: proc "contextless" (
	page: ^Connection_Page,
	holder_generation: u64,
	state: Connection_State,
	stop_cause: op.Stop_Cause,
	stop_outcome: op.Stop_Outcome,
	pending_call_count: u32,
	last_committed_request_serial: u64,
) {
	before := intrinsics.atomic_load_explicit(&page.change_count, .Relaxed)
	intrinsics.atomic_store_explicit(&page.change_count, before + 1, .Release)
	intrinsics.atomic_store_explicit(&page.holder_generation, holder_generation, .Relaxed)
	intrinsics.atomic_store_explicit(&page.stop_cause_word, u32(stop_cause), .Relaxed)
	intrinsics.atomic_store_explicit(&page.stop_outcome_word, u32(stop_outcome), .Relaxed)
	intrinsics.atomic_store_explicit(&page.pending_call_count, pending_call_count, .Relaxed)
	intrinsics.atomic_store_explicit(&page.last_committed_request_serial, last_committed_request_serial, .Relaxed)
	intrinsics.atomic_store_explicit(&page.state_word, u32(state), .Release)
	intrinsics.atomic_store_explicit(&page.change_count, before + 2, .Release)
}

// connection_page_initialize initializes a connection page in the Connected
// state for a newly opened role connection. Any refusal leaves page untouched.
connection_page_initialize :: proc "contextless" (
	page: ^Connection_Page,
	connection_serial: u64,
	role: role_contract.Role,
	initial_holder_generation: u64,
) -> Connection_Page_Refusal {
	if page == nil {
		return .Null_Page
	}
	if connection_serial == 0 {
		return .Zero_Connection_Serial
	}
	if initial_holder_generation == 0 {
		return .Zero_Holder_Generation
	}
	valid_role, role_ok := role_contract.role_from_word(u64(role))
	if !role_ok {
		return .Invalid_Role
	}

	intrinsics.atomic_store_explicit(&page.change_count, 1, .Release)
	intrinsics.atomic_store_explicit(&page.magic, CONNECTION_PAGE_MAGIC, .Relaxed)
	intrinsics.atomic_store_explicit(&page.version, CONNECTION_PAGE_VERSION, .Relaxed)
	intrinsics.atomic_store_explicit(&page.connection_serial, connection_serial, .Relaxed)
	intrinsics.atomic_store_explicit(&page.holder_generation, initial_holder_generation, .Relaxed)
	intrinsics.atomic_store_explicit(&page.role_word, u64(valid_role), .Relaxed)
	intrinsics.atomic_store_explicit(&page.stop_cause_word, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&page.stop_outcome_word, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&page.pending_call_count, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&page.last_committed_request_serial, 0, .Relaxed)
	for index in 0 ..< len(page.reserved) {
		intrinsics.atomic_store_explicit(&page.reserved[index], 0, .Relaxed)
	}
	intrinsics.atomic_store_explicit(&page.state_word, u32(Connection_State.Connected), .Release)
	intrinsics.atomic_store_explicit(&page.change_count, 2, .Release)
	return .None
}

// connection_page_mark_holder_stopped records a holder stop on the connection
// page so clients wake up and wait for a new holder without losing the grant.
connection_page_mark_holder_stopped :: proc "contextless" (
	page: ^Connection_Page,
	stop_cause: op.Stop_Cause,
	stop_outcome: op.Stop_Outcome,
) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if !connection_state_transition_allowed(current.state, .Holder_Stopped) {
		return .Invalid_Transition
	}
	_, valid_cause, valid_outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), u64(stop_cause), u64(stop_outcome))
	if !stop_ok {
		return .Invalid_Stop_Words
	}
	connection_page_write_fields(
		page,
		current.holder_generation,
		.Holder_Stopped,
		valid_cause,
		valid_outcome,
		current.pending_call_count,
		current.last_committed_request_serial,
	)
	return .None
}

// connection_page_begin_reconnect moves a stopped connection into Reconnecting
// while the root service hands the existing call ring and region to the new
// holder.
connection_page_begin_reconnect :: proc "contextless" (page: ^Connection_Page) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if !connection_state_transition_allowed(current.state, .Reconnecting) {
		return .Invalid_Transition
	}
	connection_page_write_fields(
		page,
		current.holder_generation,
		.Reconnecting,
		.None,
		.None,
		current.pending_call_count,
		current.last_committed_request_serial,
	)
	return .None
}

// connection_page_complete_reconnect publishes the new strictly greater holder
// generation and moves the connection back to Connected so clients replay any
// eligible calls in doubt transparently.
connection_page_complete_reconnect :: proc "contextless" (
	page: ^Connection_Page,
	new_holder_generation: u64,
) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if !connection_state_transition_allowed(current.state, .Connected) {
		return .Invalid_Transition
	}
	if new_holder_generation <= current.holder_generation {
		return .Holder_Generation_Not_Advanced
	}
	connection_page_write_fields(
		page,
		new_holder_generation,
		.Connected,
		.None,
		.None,
		current.pending_call_count,
		current.last_committed_request_serial,
	)
	return .None
}

// connection_page_close permanently ends the connection (for example after the
// holder exceeded its restart bound or on client disconnect). Once Closed, no
// further transition is allowed.
connection_page_close :: proc "contextless" (
	page: ^Connection_Page,
	stop_cause: op.Stop_Cause = .None,
	stop_outcome: op.Stop_Outcome = .None,
) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if !connection_state_transition_allowed(current.state, .Closed) {
		return .Invalid_Transition
	}
	valid_cause := op.Stop_Cause.None
	valid_outcome := op.Stop_Outcome.None
	if stop_cause != .None || stop_outcome != .None {
		_, parsed_cause, parsed_outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), u64(stop_cause), u64(stop_outcome))
		if !stop_ok {
			return .Invalid_Stop_Words
		}
		valid_cause = parsed_cause
		valid_outcome = parsed_outcome
	}
	connection_page_write_fields(
		page,
		current.holder_generation,
		.Closed,
		valid_cause,
		valid_outcome,
		0,
		current.last_committed_request_serial,
	)
	return .None
}

// connection_page_record_commit advances last_committed_request_serial and
// updates pending_call_count while the connection is Connected. Serials never
// regress.
connection_page_record_commit :: proc "contextless" (
	page: ^Connection_Page,
	committed_request_serial: u64,
	pending_call_count: u32,
) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if current.state != .Connected {
		return .Invalid_Transition
	}
	if committed_request_serial < current.last_committed_request_serial {
		return .Request_Serial_Regressed
	}
	connection_page_write_fields(
		page,
		current.holder_generation,
		.Connected,
		.None,
		.None,
		pending_call_count,
		committed_request_serial,
	)
	return .None
}

// connection_page_set_pending_calls updates pending_call_count while the
// connection is not Closed.
connection_page_set_pending_calls :: proc "contextless" (
	page: ^Connection_Page,
	pending_call_count: u32,
) -> Connection_Page_Refusal {
	current, refusal := connection_page_read(page)
	if refusal != .None {
		return refusal
	}
	if current.state == .Closed {
		return .Invalid_Transition
	}
	connection_page_write_fields(
		page,
		current.holder_generation,
		current.state,
		current.stop_cause,
		current.stop_outcome,
		pending_call_count,
		current.last_committed_request_serial,
	)
	return .None
}
