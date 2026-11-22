// Agent screen capture interface, settle state machine, browser display tokens,
// and shared WebTransport/WebSocket gateway binary framing
// (src/md/features/remote_display.md).
//
// Pure freestanding zero-allocation contract code: imports only base: and
// modus:contract/*. Ed25519 signature verification runs through a caller-
// supplied callback so this contract stays independent of support packages.
package remote_display

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// ============================================================================
// 1. Agent screen capture and settle state machine
// ============================================================================

// Upper bounds for agent screen wait requests so no wait can stay unbounded.
AGENT_HANG_BOUND_MAX_MS :: u64(3_600_000)   // 1 hour maximum wait bound.
AGENT_SETTLE_WINDOW_MAX_MS :: u64(60_000)   // 60 seconds maximum quiet settle window.

// Closed capture mode for an agent screen request. Value 0 is refused.
Agent_Capture_Mode :: enum u8 {
	Capture_Now  = 1, // Return the current compositor generation immediately.
	Wait_Settled = 2, // Wait until pending surfaces reach zero and remain quiet for settle_ms.
	Wait_Changed = 3, // Wait until compositor damage generation advances past since_generation.
}

// Closed outcome returned by settle tracker and agent screen evaluation.
Agent_Screen_Status :: enum u8 {
	Ready                         = 1,  // Immediate capture succeeded, or Wait_Changed observed a new generation.
	Settled                       = 2,  // Wait_Settled met the quiet settle window with zero pending surfaces.
	Changing                      = 3,  // Hang bound expired while still changing (or before any change arrived).
	Waiting                       = 4,  // Condition not yet satisfied and hang bound has not expired.
	Refused_Nil_Tracker           = 5,
	Refused_Uninitialized_Tracker = 6,
	Refused_Invalid_Mode          = 7,
	Refused_Zero_Bound            = 8,
	Refused_Bound_Too_Large       = 9,
	Refused_Invalid_Settle_Window = 10,
	Refused_Timestamp_Backwards   = 11,
	Refused_Generation_Backwards  = 12,
	Refused_Invalid_Screen        = 13,
}

// Border converters for agent capture enums.

agent_capture_mode_of_word :: proc "contextless" (word: u64) -> (mode: Agent_Capture_Mode, ok: bool) {
	return enum_word.member_of_word(Agent_Capture_Mode, word)
}

agent_screen_status_of_word :: proc "contextless" (word: u64) -> (status: Agent_Screen_Status, ok: bool) {
	return enum_word.member_of_word(Agent_Screen_Status, word)
}

// One agent screen capture or wait request.
Agent_Screen_Request :: struct {
	mode:             Agent_Capture_Mode,
	since_generation: u64, // Used by Wait_Changed: wait until damage_generation > since_generation.
	settle_ms:        u64, // Used by Wait_Settled: required quiet window in milliseconds (> 0).
	hang_bound_ms:    u64, // Maximum wait duration in milliseconds (> 0 for wait modes).
	started_at_ms:    u64, // Monotonic clock reading when the request began.
}

// One agent screen evaluation response.
Agent_Screen_Response :: struct {
	status:            Agent_Screen_Status,
	mode:              Agent_Capture_Mode,
	damage_generation: u64,
	screen:            Screen,
	observed_at_ms:    u64,
	quiet_elapsed_ms:  u64,
}

// Tracks monotonic compositor damage generations, pending surface counts, and
// quiet time since the last damage or pending surface.
Settle_Tracker :: struct {
	initialized:        bool,
	damage_generation:  u64,
	last_damage_at_ms:  u64,
	last_observed_at_ms: u64,
	surfaces_pending:   u32,
	screen:             Screen,
}

// settle_tracker_init initializes tracker with a valid screen size, initial
// damage generation, and monotonic timestamp. Refuses nil tracker or invalid
// screen size with zero mutation.
settle_tracker_init :: proc "contextless" (
	tracker: ^Settle_Tracker,
	screen: Screen,
	initial_generation: u64,
	now_ms: u64,
) -> Agent_Screen_Status {
	if tracker == nil {
		return .Refused_Nil_Tracker
	}
	if screen_problem(screen) != .None {
		return .Refused_Invalid_Screen
	}
	tracker^ = {
		initialized         = true,
		damage_generation   = initial_generation,
		last_damage_at_ms   = now_ms,
		last_observed_at_ms = now_ms,
		surfaces_pending    = 0,
		screen              = screen,
	}
	return .Ready
}

// settle_tracker_observe records a new compositor damage generation and
// pending surface count at monotonic time now_ms. Refuses backwards timestamps
// or backwards generations with zero mutation of tracker.
settle_tracker_observe :: proc "contextless" (
	tracker: ^Settle_Tracker,
	damage_generation: u64,
	surfaces_pending: u32,
	now_ms: u64,
) -> Agent_Screen_Status {
	if tracker == nil {
		return .Refused_Nil_Tracker
	}
	if !tracker.initialized {
		return .Refused_Uninitialized_Tracker
	}
	if now_ms < tracker.last_observed_at_ms {
		return .Refused_Timestamp_Backwards
	}
	if damage_generation < tracker.damage_generation {
		return .Refused_Generation_Backwards
	}
	if damage_generation > tracker.damage_generation || surfaces_pending > 0 || tracker.surfaces_pending > 0 {
		tracker.last_damage_at_ms = now_ms
	}
	tracker.damage_generation = damage_generation
	tracker.surfaces_pending = surfaces_pending
	tracker.last_observed_at_ms = now_ms
	return .Ready
}

// agent_screen_evaluate evaluates one Agent_Screen_Request against tracker at
// monotonic time now_ms without mutating tracker. Enforces closed mode border,
// monotonic timestamps, positive bounded hang_bound_ms, and valid settle_ms.
agent_screen_evaluate :: proc "contextless" (
	tracker: ^Settle_Tracker,
	request: Agent_Screen_Request,
	now_ms: u64,
) -> Agent_Screen_Response {
	if tracker == nil {
		return {status = .Refused_Nil_Tracker}
	}
	if !tracker.initialized {
		return {status = .Refused_Uninitialized_Tracker}
	}
	if screen_problem(tracker.screen) != .None {
		return {status = .Refused_Invalid_Screen}
	}
	mode, mode_ok := agent_capture_mode_of_word(u64(request.mode))
	if !mode_ok {
		return {status = .Refused_Invalid_Mode}
	}
	if now_ms < tracker.last_observed_at_ms || now_ms < tracker.last_damage_at_ms || now_ms < request.started_at_ms {
		return {status = .Refused_Timestamp_Backwards, mode = mode}
	}

	quiet_ms: u64 = 0
	if tracker.surfaces_pending == 0 && now_ms >= tracker.last_damage_at_ms {
		quiet_ms = now_ms - tracker.last_damage_at_ms
	}

	base := Agent_Screen_Response{
		mode              = mode,
		damage_generation = tracker.damage_generation,
		screen            = tracker.screen,
		observed_at_ms    = now_ms,
		quiet_elapsed_ms  = quiet_ms,
	}

	switch mode {
	case .Capture_Now:
		base.status = .Ready
		return base

	case .Wait_Settled:
		if request.hang_bound_ms == 0 {
			return {status = .Refused_Zero_Bound, mode = mode}
		}
		if request.hang_bound_ms > AGENT_HANG_BOUND_MAX_MS {
			return {status = .Refused_Bound_Too_Large, mode = mode}
		}
		if request.settle_ms == 0 || request.settle_ms > request.hang_bound_ms || request.settle_ms > AGENT_SETTLE_WINDOW_MAX_MS {
			return {status = .Refused_Invalid_Settle_Window, mode = mode}
		}
		if tracker.surfaces_pending == 0 && quiet_ms >= request.settle_ms {
			base.status = .Settled
			return base
		}
		if now_ms - request.started_at_ms >= request.hang_bound_ms {
			base.status = .Changing
			return base
		}
		base.status = .Waiting
		return base

	case .Wait_Changed:
		if request.hang_bound_ms == 0 {
			return {status = .Refused_Zero_Bound, mode = mode}
		}
		if request.hang_bound_ms > AGENT_HANG_BOUND_MAX_MS {
			return {status = .Refused_Bound_Too_Large, mode = mode}
		}
		if tracker.damage_generation > request.since_generation {
			base.status = .Ready
			return base
		}
		if now_ms - request.started_at_ms >= request.hang_bound_ms {
			base.status = .Changing
			return base
		}
		base.status = .Waiting
		return base
	}

	return {status = .Refused_Invalid_Mode}
}

// ============================================================================
// 2. Browser display token and revocation list
// ============================================================================

// Ed25519 key and signature byte lengths.
DISPLAY_TOKEN_PUBLIC_KEY_SIZE :: 32
DISPLAY_TOKEN_SIGNATURE_SIZE :: 64

// Validity window bounds, in seconds.
DISPLAY_TOKEN_MAX_WINDOW_SECONDS :: u64(86_400)         // 1 day per issue or renewal.
DISPLAY_TOKEN_DEFAULT_ABSOLUTE_SECONDS :: u64(7 * 86_400) // 7 days default absolute ceiling.
DISPLAY_TOKEN_MAX_ABSOLUTE_SECONDS :: u64(30 * 86_400)  // 30 days hard absolute ceiling.

// Domain separation prefix for Ed25519 signatures over browser display tokens.
DISPLAY_TOKEN_SIGNING_DOMAIN :: "modus display token v1"
DISPLAY_TOKEN_VERSION :: u8(1)

// Canonical signing payload size of a Display_Token:
//   [0..22]   "modus display token v1" (22 bytes)
//   [22]      0x00 domain separator
//   [23]      version (1)
//   [24]      transport (Gateway_Transport)
//   [25..32]  reserved zero bytes (7 bytes)
//   [32..40]  token_id (u64 LE)
//   [40..48]  principal_id (u64 LE)
//   [48..56]  rights word (u64 LE)
//   [56..64]  issued_at_unix (u64 LE)
//   [64..72]  expires_at_unix (u64 LE)
//   [72..80]  absolute_end_unix (u64 LE)
DISPLAY_TOKEN_SIGNING_BYTES_SIZE :: len(DISPLAY_TOKEN_SIGNING_DOMAIN) + 1 + 1 + 1 + 7 + 8 * 6
#assert(DISPLAY_TOKEN_SIGNING_BYTES_SIZE == 80)

// Wire size of one serialized Display_Token: canonical payload + 64-byte signature.
DISPLAY_TOKEN_WIRE_SIZE :: DISPLAY_TOKEN_SIGNING_BYTES_SIZE + DISPLAY_TOKEN_SIGNATURE_SIZE
#assert(DISPLAY_TOKEN_WIRE_SIZE == 144)

// Maximum revoked token IDs tracked in one Token_Revocation_List.
TOKEN_REVOCATION_CAPACITY :: 64

// Closed browser gateway transport protocol. Value 0 is refused.
Gateway_Transport :: enum u8 {
	WebTransport = 1, // HTTP/3 over QUIC bidirectional streams.
	WebSocket    = 2, // Binary WebSocket messages over TLS/HTTP.
}

// Closed display token rights. Input is never permitted without View.
Display_Token_Right :: enum u64 {
	View  = 0,
	Input = 1,
}

Display_Token_Rights :: bit_set[Display_Token_Right; u64]

// Closed verification and renewal status for browser display tokens.
Display_Token_Status :: enum u8 {
	Valid                             = 1,
	Renewed                           = 2,
	Refused_Nil_Input                 = 3,
	Refused_Zero_Token_Id             = 4,
	Refused_Zero_Public_Key           = 5,
	Refused_Unknown_Transport         = 6,
	Refused_Invalid_Rights            = 7,
	Refused_Invalid_Window            = 8,
	Refused_Absolute_End_Past_Limit   = 9,
	Refused_Not_Yet_Valid             = 10,
	Refused_Expired                   = 11,
	Refused_Revoked                   = 12,
	Refused_Invalid_Signature         = 13,
	Refused_Renewal_Past_Absolute_End = 14,
	Refused_Renewal_Window_Invalid    = 15,
	Refused_Revocation_List_Full      = 16,
	Refused_Buffer_Too_Small          = 17,
	Refused_Malformed_Wire            = 18,
}

// Border converters for browser gateway token enums and bit sets.

gateway_transport_of_word :: proc "contextless" (word: u64) -> (transport: Gateway_Transport, ok: bool) {
	return enum_word.member_of_word(Gateway_Transport, word)
}

display_token_status_of_word :: proc "contextless" (word: u64) -> (status: Display_Token_Status, ok: bool) {
	return enum_word.member_of_word(Display_Token_Status, word)
}

display_token_rights_word :: proc "contextless" (rights: Display_Token_Rights) -> u64 {
	return transmute(u64)rights
}

// display_token_rights_of_word converts a transport u64 word into a valid
// Display_Token_Rights set. Zero rights, unknown bits, and Input without View
// are refused.
display_token_rights_of_word :: proc "contextless" (word: u64) -> (rights: Display_Token_Rights, ok: bool) {
	known := display_token_rights_word({.View, .Input})
	if word == 0 || word & ~known != 0 {
		return {}, false
	}
	rights = transmute(Display_Token_Rights)word
	if .Input in rights && .View not_in rights {
		return {}, false
	}
	return rights, true
}

// Caller-supplied Ed25519 signature verification callback so this contract
// imports no support cryptography package.
Token_Signature_Verify_Proc :: #type proc "contextless" (
	public_key: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [DISPLAY_TOKEN_SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool

// Signed browser display token bound to one principal, transport, rights set,
// 1-day sliding validity window, and immutable absolute_end_unix ceiling.
Display_Token :: struct {
	token_id:          u64,
	principal_id:      u64,
	transport:         Gateway_Transport,
	rights:            Display_Token_Rights,
	issued_at_unix:    u64,
	expires_at_unix:   u64,
	absolute_end_unix: u64,
	signature:         [DISPLAY_TOKEN_SIGNATURE_SIZE]u8,
}

// Explicit bounded list of revoked display token IDs.
Token_Revocation_List :: struct {
	revoked_ids: [TOKEN_REVOCATION_CAPACITY]u64,
	count:       u32,
}

@(private = "file")
public_key_is_zero :: proc "contextless" (key: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8) -> bool {
	accumulated: u8 = 0
	for b in key {
		accumulated |= b
	}
	return accumulated == 0
}

// token_revocation_contains checks whether token_id is present in list without
// early exit across the active entries.
token_revocation_contains :: proc "contextless" (list: ^Token_Revocation_List, token_id: u64) -> bool {
	if list == nil || token_id == 0 {
		return false
	}
	limit := min(int(list.count), TOKEN_REVOCATION_CAPACITY)
	matched: u64 = 0
	for index in 0 ..< limit {
		diff := list.revoked_ids[index] ~ token_id
		is_equal := u64(diff == 0 ? 1 : 0)
		matched |= is_equal
	}
	return matched != 0
}

// token_revocation_add records a non-zero revoked token ID in list. Refuses
// nil list, zero token ID, or a full list with zero mutation. Adding an already
// revoked ID succeeds idempotently.
token_revocation_add :: proc "contextless" (list: ^Token_Revocation_List, token_id: u64) -> Display_Token_Status {
	if list == nil {
		return .Refused_Nil_Input
	}
	if token_id == 0 {
		return .Refused_Zero_Token_Id
	}
	if token_revocation_contains(list, token_id) {
		return .Valid
	}
	if int(list.count) >= TOKEN_REVOCATION_CAPACITY {
		return .Refused_Revocation_List_Full
	}
	list.revoked_ids[list.count] = token_id
	list.count += 1
	return .Valid
}

@(private = "file")
validate_display_token_structure :: proc "contextless" (token: ^Display_Token) -> (checked_transport: Gateway_Transport, checked_rights: Display_Token_Rights, status: Display_Token_Status) {
	if token == nil {
		return {}, {}, .Refused_Nil_Input
	}
	if token.token_id == 0 {
		return {}, {}, .Refused_Zero_Token_Id
	}
	transport, transport_ok := gateway_transport_of_word(u64(token.transport))
	if !transport_ok {
		return {}, {}, .Refused_Unknown_Transport
	}
	rights, rights_ok := display_token_rights_of_word(display_token_rights_word(token.rights))
	if !rights_ok {
		return {}, {}, .Refused_Invalid_Rights
	}
	if token.expires_at_unix <= token.issued_at_unix {
		return {}, {}, .Refused_Invalid_Window
	}
	if token.expires_at_unix - token.issued_at_unix > DISPLAY_TOKEN_MAX_WINDOW_SECONDS {
		return {}, {}, .Refused_Invalid_Window
	}
	if token.absolute_end_unix < token.expires_at_unix {
		return {}, {}, .Refused_Invalid_Window
	}
	if token.absolute_end_unix - token.issued_at_unix > DISPLAY_TOKEN_MAX_ABSOLUTE_SECONDS {
		return {}, {}, .Refused_Absolute_End_Past_Limit
	}
	return transport, rights, .Valid
}

// display_token_signing_bytes constructs the exact canonical 80-byte
// domain-separated byte sequence ("modus display token v1") covered by the
// Ed25519 signature of token.
display_token_signing_bytes :: proc "contextless" (
	token: ^Display_Token,
) -> (signing_bytes: [DISPLAY_TOKEN_SIGNING_BYTES_SIZE]u8, status: Display_Token_Status) {
	transport, rights, structure_status := validate_display_token_structure(token)
	if structure_status != .Valid {
		return {}, structure_status
	}
	domain := DISPLAY_TOKEN_SIGNING_DOMAIN
	copy(signing_bytes[0:len(domain)], domain)
	signing_bytes[22] = 0
	signing_bytes[23] = DISPLAY_TOKEN_VERSION
	signing_bytes[24] = u8(transport)
	for index in 25 ..< 32 {
		signing_bytes[index] = 0
	}
	byte_order.write_u64_little_endian(signing_bytes[:], 32, token.token_id)
	byte_order.write_u64_little_endian(signing_bytes[:], 40, token.principal_id)
	byte_order.write_u64_little_endian(signing_bytes[:], 48, display_token_rights_word(rights))
	byte_order.write_u64_little_endian(signing_bytes[:], 56, token.issued_at_unix)
	byte_order.write_u64_little_endian(signing_bytes[:], 64, token.expires_at_unix)
	byte_order.write_u64_little_endian(signing_bytes[:], 72, token.absolute_end_unix)
	return signing_bytes, .Valid
}

// display_token_wire_encode serializes token into out_bytes (144 bytes).
// Refuses invalid tokens or undersized buffers without writing to out_bytes.
display_token_wire_encode :: proc "contextless" (
	out_bytes: []u8,
	token: ^Display_Token,
) -> (written: int, status: Display_Token_Status) {
	signing_bytes, signing_status := display_token_signing_bytes(token)
	if signing_status != .Valid {
		return 0, signing_status
	}
	if len(out_bytes) < DISPLAY_TOKEN_WIRE_SIZE {
		return 0, .Refused_Buffer_Too_Small
	}
	copy(out_bytes[0:DISPLAY_TOKEN_SIGNING_BYTES_SIZE], signing_bytes[:])
	copy(out_bytes[DISPLAY_TOKEN_SIGNING_BYTES_SIZE:DISPLAY_TOKEN_WIRE_SIZE], token.signature[:])
	return DISPLAY_TOKEN_WIRE_SIZE, .Valid
}

// display_token_wire_decode parses one 144-byte serialized Display_Token,
// validating its domain header, version, reserved zeros, transport, rights,
// and window bounds at the border.
display_token_wire_decode :: proc "contextless" (
	wire_bytes: []u8,
) -> (token: Display_Token, status: Display_Token_Status) {
	if len(wire_bytes) != DISPLAY_TOKEN_WIRE_SIZE {
		return {}, .Refused_Malformed_Wire
	}
	domain := DISPLAY_TOKEN_SIGNING_DOMAIN
	for i in 0 ..< len(domain) {
		if wire_bytes[i] != domain[i] {
			return {}, .Refused_Malformed_Wire
		}
	}
	if wire_bytes[22] != 0 || wire_bytes[23] != DISPLAY_TOKEN_VERSION {
		return {}, .Refused_Malformed_Wire
	}
	for i in 25 ..< 32 {
		if wire_bytes[i] != 0 {
			return {}, .Refused_Malformed_Wire
		}
	}
	transport, transport_ok := gateway_transport_of_word(u64(wire_bytes[24]))
	if !transport_ok {
		return {}, .Refused_Unknown_Transport
	}
	rights_word := byte_order.read_u64_little_endian(wire_bytes, 48)
	rights, rights_ok := display_token_rights_of_word(rights_word)
	if !rights_ok {
		return {}, .Refused_Invalid_Rights
	}
	parsed := Display_Token{
		token_id          = byte_order.read_u64_little_endian(wire_bytes, 32),
		principal_id      = byte_order.read_u64_little_endian(wire_bytes, 40),
		transport         = transport,
		rights            = rights,
		issued_at_unix    = byte_order.read_u64_little_endian(wire_bytes, 56),
		expires_at_unix   = byte_order.read_u64_little_endian(wire_bytes, 64),
		absolute_end_unix = byte_order.read_u64_little_endian(wire_bytes, 72),
	}
	copy(parsed.signature[:], wire_bytes[DISPLAY_TOKEN_SIGNING_BYTES_SIZE:DISPLAY_TOKEN_WIRE_SIZE])
	if _, _, check_status := validate_display_token_structure(&parsed); check_status != .Valid {
		return {}, check_status
	}
	return parsed, .Valid
}

// display_token_verify_and_renew verifies token structurally, checks that its
// ID is not in revocations, verifies its Ed25519 signature over the canonical
// "modus display token v1" bytes using principal_pub_key, and checks validity
// at now_unix.
//
// - When requested_new_expiry == 0, performs verification only and returns
//   (token^, .Valid).
// - When requested_new_expiry > 0, checks that the requested expiry is strictly
//   after now_unix, at most DISPLAY_TOKEN_MAX_WINDOW_SECONDS past now_unix, and
//   never past token.absolute_end_unix. Returns the renewed token with its old
//   signature cleared (requiring fresh signing by the issuer) and status
//   .Renewed.
// - Never mutates token^ or revocations^.
display_token_verify_and_renew :: proc "contextless" (
	token: ^Display_Token,
	revocations: ^Token_Revocation_List,
	now_unix: u64,
	requested_new_expiry: u64,
	principal_pub_key: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8,
	verify_signature: Token_Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> (result_token: Display_Token, status: Display_Token_Status) {
	if token == nil || revocations == nil {
		return {}, .Refused_Nil_Input
	}
	if public_key_is_zero(principal_pub_key) {
		return {}, .Refused_Zero_Public_Key
	}
	signing_bytes, signing_status := display_token_signing_bytes(token)
	if signing_status != .Valid {
		return {}, signing_status
	}
	if verify_signature == nil {
		return {}, .Refused_Invalid_Signature
	}
	if !verify_signature(principal_pub_key, signing_bytes[:], token.signature, user_data) {
		return {}, .Refused_Invalid_Signature
	}
	if token_revocation_contains(revocations, token.token_id) {
		return {}, .Refused_Revoked
	}
	if now_unix < token.issued_at_unix {
		return {}, .Refused_Not_Yet_Valid
	}
	// A token ends at its expiry time or absolute ceiling: use at that instant is refused.
	if now_unix >= token.expires_at_unix || now_unix >= token.absolute_end_unix {
		return {}, .Refused_Expired
	}

	if requested_new_expiry == 0 {
		return token^, .Valid
	}
	if requested_new_expiry > token.absolute_end_unix {
		return {}, .Refused_Renewal_Past_Absolute_End
	}
	if requested_new_expiry <= now_unix || requested_new_expiry - now_unix > DISPLAY_TOKEN_MAX_WINDOW_SECONDS {
		return {}, .Refused_Renewal_Window_Invalid
	}

	renewed := token^
	renewed.issued_at_unix = now_unix
	renewed.expires_at_unix = requested_new_expiry
	renewed.signature = {}
	return renewed, .Renewed
}

// ============================================================================
// 3. Shared WebTransport / WebSocket binary gateway framing
// ============================================================================

// Wire header constants shared identically by WebTransport streams and
// WebSocket binary messages.
GATEWAY_FRAME_MAGIC_0 :: u8('M')
GATEWAY_FRAME_MAGIC_1 :: u8('G')
GATEWAY_FRAME_VERSION :: u8(1)
GATEWAY_FRAME_HEADER_SIZE :: 16

// Largest payload carried in one gateway frame: accommodates any valid
// remote_display wire record (Record_Header + SERVICE_BODY_LIMIT).
GATEWAY_FRAME_PAYLOAD_LIMIT :: u32(RECORD_HEADER_SIZE + SERVICE_BODY_LIMIT)

// Closed kind of a binary gateway frame. Value 0 is refused.
Gateway_Frame_Kind :: enum u8 {
	Auth_Token           = 1, // First frame of a browser session carrying a serialized Display_Token.
	Token_Renew_Request  = 2, // Browser requests a sliding renewal before expiry.
	Token_Renew_Response = 3, // Gateway returns a freshly signed renewed Display_Token.
	Display_Record       = 4, // Carries one remote_display Record_Header + body verbatim.
	Close                = 5, // Explicit session close with Display_Error word.
}

// Closed flag bits for a binary gateway frame.
Gateway_Frame_Flag :: enum u8 {
	End_Of_Message = 0,
}

Gateway_Frame_Flags :: bit_set[Gateway_Frame_Flag; u8]
GATEWAY_FRAME_FLAGS_VALID_MASK :: u8(1)

// Closed refusal reasons returned by gateway_frame_encode and gateway_frame_decode.
Gateway_Frame_Problem :: enum u8 {
	None                = 0,
	Truncated           = 1,
	Bad_Magic           = 2,
	Unsupported_Version = 3,
	Unknown_Transport   = 4,
	Unknown_Kind        = 5,
	Invalid_Flags       = 6,
	Non_Zero_Reserved   = 7,
	Payload_Too_Large   = 8,
	Trailing_Bytes      = 9,
	Buffer_Too_Small    = 10,
}

// Border converters for gateway frame enums and flags.

gateway_frame_kind_of_word :: proc "contextless" (word: u64) -> (kind: Gateway_Frame_Kind, ok: bool) {
	return enum_word.member_of_word(Gateway_Frame_Kind, word)
}

gateway_frame_flags_of_word :: proc "contextless" (word: u8) -> (flags: Gateway_Frame_Flags, ok: bool) {
	if word & ~GATEWAY_FRAME_FLAGS_VALID_MASK != 0 {
		return {}, false
	}
	return transmute(Gateway_Frame_Flags)word, true
}

gateway_frame_problem_of_word :: proc "contextless" (word: u64) -> (problem: Gateway_Frame_Problem, ok: bool) {
	return enum_word.member_of_word(Gateway_Frame_Problem, word)
}

// Decoded 16-byte gateway binary frame header.
// Wire layout (little-endian):
//   [0..2]   magic 'M', 'G'
//   [2]      version (1)
//   [3]      transport (Gateway_Transport)
//   [4]      kind (Gateway_Frame_Kind)
//   [5]      flags (Gateway_Frame_Flags)
//   [6..8]   reserved (u16 == 0)
//   [8..12]  sequence (u32 LE)
//   [12..16] payload_length (u32 LE)
Gateway_Frame_Header :: struct {
	transport:      Gateway_Transport,
	kind:           Gateway_Frame_Kind,
	flags:          Gateway_Frame_Flags,
	sequence:       u32,
	payload_length: u32,
}

// gateway_frame_encode writes one binary gateway frame (16-byte header +
// payload) into out_bytes using the identical layout for WebTransport streams
// and WebSocket binary messages. Refuses unknown transport/kind/flags,
// oversized payload, or undersized out_bytes without modifying out_bytes.
gateway_frame_encode :: proc "contextless" (
	out_bytes: []u8,
	header: Gateway_Frame_Header,
	payload: []u8,
) -> (written: int, problem: Gateway_Frame_Problem) {
	transport, transport_ok := gateway_transport_of_word(u64(header.transport))
	if !transport_ok {
		return 0, .Unknown_Transport
	}
	kind, kind_ok := gateway_frame_kind_of_word(u64(header.kind))
	if !kind_ok {
		return 0, .Unknown_Kind
	}
	flags_word := transmute(u8)header.flags
	if _, flags_ok := gateway_frame_flags_of_word(flags_word); !flags_ok {
		return 0, .Invalid_Flags
	}
	if u64(len(payload)) > u64(GATEWAY_FRAME_PAYLOAD_LIMIT) {
		return 0, .Payload_Too_Large
	}
	total := GATEWAY_FRAME_HEADER_SIZE + len(payload)
	if len(out_bytes) < total {
		return 0, .Buffer_Too_Small
	}

	out_bytes[0] = GATEWAY_FRAME_MAGIC_0
	out_bytes[1] = GATEWAY_FRAME_MAGIC_1
	out_bytes[2] = GATEWAY_FRAME_VERSION
	out_bytes[3] = u8(transport)
	out_bytes[4] = u8(kind)
	out_bytes[5] = flags_word
	byte_order.write_u16_little_endian(out_bytes, 6, 0)
	byte_order.write_u32_little_endian(out_bytes, 8, header.sequence)
	byte_order.write_u32_little_endian(out_bytes, 12, u32(len(payload)))
	if len(payload) > 0 {
		copy(out_bytes[GATEWAY_FRAME_HEADER_SIZE:], payload)
	}
	return total, .None
}

// gateway_frame_decode validates and decodes one complete binary gateway frame
// from frame_bytes, enforcing magic, version, closed transport/kind/flags,
// zero reserved bytes, payload length bound, and exact frame length with no
// trailing bytes.
gateway_frame_decode :: proc "contextless" (
	frame_bytes: []u8,
) -> (header: Gateway_Frame_Header, payload: []u8, problem: Gateway_Frame_Problem) {
	if len(frame_bytes) < GATEWAY_FRAME_HEADER_SIZE {
		return {}, nil, .Truncated
	}
	if frame_bytes[0] != GATEWAY_FRAME_MAGIC_0 || frame_bytes[1] != GATEWAY_FRAME_MAGIC_1 {
		return {}, nil, .Bad_Magic
	}
	if frame_bytes[2] != GATEWAY_FRAME_VERSION {
		return {}, nil, .Unsupported_Version
	}
	transport, transport_ok := gateway_transport_of_word(u64(frame_bytes[3]))
	if !transport_ok {
		return {}, nil, .Unknown_Transport
	}
	kind, kind_ok := gateway_frame_kind_of_word(u64(frame_bytes[4]))
	if !kind_ok {
		return {}, nil, .Unknown_Kind
	}
	flags, flags_ok := gateway_frame_flags_of_word(frame_bytes[5])
	if !flags_ok {
		return {}, nil, .Invalid_Flags
	}
	reserved := byte_order.read_u16_little_endian(frame_bytes, 6)
	if reserved != 0 {
		return {}, nil, .Non_Zero_Reserved
	}
	sequence := byte_order.read_u32_little_endian(frame_bytes, 8)
	payload_length := byte_order.read_u32_little_endian(frame_bytes, 12)
	if payload_length > GATEWAY_FRAME_PAYLOAD_LIMIT {
		return {}, nil, .Payload_Too_Large
	}
	expected_total := u64(GATEWAY_FRAME_HEADER_SIZE) + u64(payload_length)
	if u64(len(frame_bytes)) < expected_total {
		return {}, nil, .Truncated
	}
	if u64(len(frame_bytes)) > expected_total {
		return {}, nil, .Trailing_Bytes
	}

	header = Gateway_Frame_Header{
		transport      = transport,
		kind           = kind,
		flags          = flags,
		sequence       = sequence,
		payload_length = payload_length,
	}
	return header, frame_bytes[GATEWAY_FRAME_HEADER_SIZE:], .None
}
