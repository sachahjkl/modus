// Host Agent Bridge contract: closed enums, canonical "MODAB1" binary wire
// framing, typed command payload validation, Lex sensitive-action detection,
// and pure authorization rules (src/md/features/agent_bridge.md).
//
// Enforces the core bridge invariants:
// - Four explicit capabilities (Eval_Lex, Read_Screen, Send_Input,
//   Read_Log_Facts) gated by both Bridge_Permissions and remote.Client_Uses.
// - Synthetic input (Send_Key, Send_Pointer) requires an active, non-expired
//   wide_grants.Wide_Grant_Terms bound to the client key and covering the
//   non-zero target window, plus an available collector hash chain.
// - An Eval_Lex line runs at once only when it is one call of an export on
//   the read-only list (READ_ONLY_EXPORTS). Each other call, plans.apply and
//   plans.rollback among them, stops in the state
//   Bridge_Request_State.Awaiting_Principal_Approval. A line that is not one call
//   (a comment, a second line, a pipe, a nested call) is refused. The bridge
//   reads no flag of the caller to decide this.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package agent_bridge

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"

// Wire magic and version of the Agent Bridge binary frame format. Version 2
// gives the state of a request and the outcome of an ended request.
BRIDGE_WIRE_MAGIC :: [6]u8{'M', 'O', 'D', 'A', 'B', '1'}
BRIDGE_WIRE_VERSION :: u16(2)

// Exact binary header sizes for command and response frames.
// Command:  magic(6) + version(2) + command(4) + request_id(8) +
//           principal_id(8) + grant_serial(8) + target_window_id(8) +
//           client_key_hash(32) + payload_length(4) + reserved(4) = 84 bytes.
// Response: magic(6) + version(2) + state(4) + refusal(4) + request_id(8) +
//           act_sequence(8) + act_hash(32) + payload_length(4) + outcome(4)
//           = 72 bytes.
COMMAND_HEADER_SIZE :: 84
RESPONSE_HEADER_SIZE :: 72

// Structural bounds for bridge payloads and typed command fields.
MAX_BRIDGE_PAYLOAD_BYTES :: 65536
MAX_LEX_LINE_BYTES :: 4096
MAX_FILTER_NAME_BYTES :: 64
MAX_LOG_FACT_QUERY_LIMIT :: 256
MAX_WAIT_SETTLED_MS :: u32(30_000)

// Exact binary payload sizes for fixed-size typed command payloads.
READ_SCREEN_PAYLOAD_SIZE :: 16 // format(1) + pad(3) + max_width(4) + max_height(4) + wait_settled_ms(4)
SEND_KEY_PAYLOAD_SIZE :: 16 // code(4) + character(4) + pressed(4) + modifiers(4)
SEND_POINTER_PAYLOAD_SIZE :: 16 // x(4) + y(4) + buttons(4) + wheel(4)
READ_LOG_FACTS_BASE_SIZE :: 24 // module_len(1) + fact_len(1) + pad(2) + max_records(4) + seq_start(8) + seq_end(8)

// Closed set of commands accepted by the Agent Bridge.
// Zero means unset and is refused at the border.
Bridge_Command_Kind :: enum u32 {
	None           = 0,
	Eval_Lex       = 1,
	Read_Screen    = 2,
	Send_Key       = 3,
	Send_Pointer   = 4,
	Read_Log_Facts = 5,
}

// The state of a request of the Agent Bridge (src/md/api/call_outcome.md,
// "The agent bridge"): it ended, with the outcome of the call, or it waits
// for the approval of the principal, which an agent cannot give. Waiting is
// no outcome: only an ended request has one. Zero means unset and is
// refused at the border.
Bridge_Request_State :: enum u32 {
	None                        = 0,
	Ended                       = 1,
	Awaiting_Principal_Approval = 2,
}

// Closed set of explicit capability bits granted to an agent client key.
// Bit 0 is unused so word 0 always names no permission.
Bridge_Permission :: enum u64 {
	Eval_Lex       = 1,
	Read_Screen    = 2,
	Send_Input     = 3,
	Read_Log_Facts = 4,
}

// Bit set of granted Bridge_Permission flags.
Bridge_Permissions :: bit_set[Bridge_Permission; u64]

// Bit mask of all defined Bridge_Permission bits.
BRIDGE_PERMISSION_KNOWN_MASK :: (u64(1) << u64(Bridge_Permission.Eval_Lex)) |
	(u64(1) << u64(Bridge_Permission.Read_Screen)) |
	(u64(1) << u64(Bridge_Permission.Send_Input)) |
	(u64(1) << u64(Bridge_Permission.Read_Log_Facts))

// Closed set of refusal causes returned by bridge framing, payload checks,
// and authorization rules.
Bridge_Refusal :: enum u32 {
	None                        = 0,
	Bad_Header                  = 1,
	Truncated                   = 2,
	Trailing_Bytes              = 3,
	Buffer_Too_Small            = 4,
	Unknown_Command             = 5,
	Unknown_State               = 6,
	Invalid_Permissions         = 7,
	Permission_Denied           = 8,
	Client_Key_Missing          = 9,
	Wide_Grant_Required         = 10,
	Wide_Grant_Not_Active       = 11,
	Wide_Grant_Expired          = 12,
	Window_Not_In_Scope         = 13,
	Principal_Approval_Required = 14,
	Invalid_Field               = 15,
	Payload_Too_Large           = 16,
	Act_Log_Required            = 17,
	Invalid_Text                = 18,
}

// Closed set of picture encodings requested through Read_Screen.
Screen_Picture_Format :: enum u8 {
	None     = 0,
	Png      = 1,
	Raw_Bgrx = 2,
}

// Closed set of typed value kinds returned by Eval_Lex.
// How a column of a table or a record result is written and aligned, as
// the drawers of the console write it (modus:console_results): a text at
// the left, a number at the right, a size or a time at the right with its
// unit in the head, a hexadecimal number at the right in two digits for
// each byte. The values cross the border of the JSON of the bridge: None
// names no kind.
Lex_Column_Kind :: enum u8 {
	None        = 0,
	Text        = 1, // A text, a status name, a hash or any other form: the cell is its text.
	Integer     = 2, // A signed number with no unit.
	Size        = 3, // A size: the unit word is a value_kinds.Size_Unit.
	Time        = 4, // A time: the unit word is a value_kinds.Duration_Unit.
	Hexadecimal = 5, // A number in hexadecimal: the unit word is its bytes, 1 to 8.
}

@(rodata)
LEX_COLUMN_KIND_NAMES := [Lex_Column_Kind]string {
	.None        = "none",
	.Text        = "text",
	.Integer     = "integer",
	.Size        = "size",
	.Time        = "time",
	.Hexadecimal = "hexadecimal",
}

// lex_column_kind_name gives the name of a kind in the JSON of the bridge.
lex_column_kind_name :: proc "contextless" (kind: Lex_Column_Kind) -> string {
	return LEX_COLUMN_KIND_NAMES[kind]
}

// lex_column_kind_of_name is the border of a kind of the JSON: false for a
// name of no kind, None too.
lex_column_kind_of_name :: proc "contextless" (name: string) -> (kind: Lex_Column_Kind, ok: bool) {
	for candidate in Lex_Column_Kind {
		if candidate != .None && LEX_COLUMN_KIND_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return .None, false
}

// lex_column_kind_of_word is the border of the word of a kind: false for a
// word that names no kind, None too.
lex_column_kind_of_word :: proc "contextless" (word: i64) -> (kind: Lex_Column_Kind, ok: bool) {
	if word < 0 {
		return .None, false
	}
	member := enum_word.member_of_word(Lex_Column_Kind, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// lex_column_unit_valid says if a unit word fits a kind: 0 for a text and
// a plain number, a member of value_kinds.Size_Unit for a size and of
// value_kinds.Duration_Unit for a time, 1 to 8 bytes for a hexadecimal
// number.
lex_column_unit_valid :: proc "contextless" (kind: Lex_Column_Kind, unit: i64) -> bool {
	switch kind {
	case .Text, .Integer:
		return unit == 0
	case .Size:
		return unit >= 0 && unit <= i64(max(value_kinds.Size_Unit))
	case .Time:
		return unit >= 0 && unit <= i64(max(value_kinds.Duration_Unit))
	case .Hexadecimal:
		return unit >= 1 && unit <= 8
	case .None:
	}
	return false
}

Lex_Value_Kind :: enum u8 {
	None        = 0,
	Integer     = 1,
	Text        = 2,
	Boolean     = 3,
	Table       = 4,
	Record      = 5,
	Enum_Member = 6,
}

// Canonical decoded command frame.
Bridge_Command_Frame :: struct {
	command:          Bridge_Command_Kind,
	request_id:       u64,
	principal_id:     u64,
	grant_serial:     u64,
	target_window_id: u64,
	client_key_hash:  blake3.Hash,
	payload:          []u8,
}

// Canonical decoded response frame. The outcome is Succeeded for a request
// that waits.
Bridge_Response_Frame :: struct {
	state:               Bridge_Request_State,
	outcome:             call_outcome.Call_Outcome,
	refusal:             Bridge_Refusal,
	request_id:          u64,
	act_sequence_number: u64,
	act_record_hash:     blake3.Hash,
	payload:             []u8,
}

// Typed payload for Read_Screen.
Read_Screen_Payload :: struct {
	format:          Screen_Picture_Format,
	max_width:       u32,
	max_height:      u32,
	wait_settled_ms: u32,
}

// Typed payload for Send_Key.
Send_Key_Payload :: struct {
	key: remote_display.Key_Body,
}

// Typed payload for Send_Pointer.
Send_Pointer_Payload :: struct {
	pointer: remote_display.Pointer_Body,
}

// Typed payload for Read_Log_Facts.
Read_Log_Facts_Payload :: struct {
	module_filter_length:    u8,
	module_filter_bytes:     [MAX_FILTER_NAME_BYTES]u8,
	fact_name_filter_length: u8,
	fact_name_filter_bytes:  [MAX_FILTER_NAME_BYTES]u8,
	sequence_start:          u64,
	sequence_end:            u64,
	max_records:             u32,
}

// Principal-approved client key policy evaluated by bridge_authorize_command.
Bridge_Client_Policy :: struct {
	client_key_public:     [32]u8,
	principal_id:          u64,
	permissions_word:      u64,
	remote_uses_word:      u64,
	has_wide_grant:        bool,
	wide_grant_serial:     u64,
	wide_grant_state_word: u64,
	wide_grant_terms:      wide_grants.Wide_Grant_Terms,
	wide_grant_created_ms: u64,
	wide_grant_expires_ms: u64,
	collector_available:   bool,
}

// Command context evaluated by bridge_authorize_command before any transport
// call runs. It holds no flag of the caller about the sensitivity of the
// command: the bridge classifies each command itself.
Bridge_Authorization_Request :: struct {
	command:           Bridge_Command_Kind,
	now_ms:            u64,
	target_window_id:  u64,
	lex_line:          []u8,
	pointer_has_click: bool,
}

// Closed set of the classes of an Eval_Lex line (lex_line_classify).
// Zero means unset and is refused.
Lex_Line_Class :: enum u8 {
	None                        = 0,
	Malformed                   = 1, // Not exactly one call with literal arguments: refused.
	Read_Only                   = 2, // One call of an export of READ_ONLY_EXPORTS: runs at once.
	Requires_Principal_Approval = 3, // One call of any other export: waits for the principal.
}

// One export that reads and changes nothing, and gives no secret of the
// principal, so that an agent can call it with no approval.
Read_Only_Export :: struct {
	service: string,
	export:  string,
}

// The read-only list of Eval_Lex: each call outside it waits for the
// principal. A new entry must read only: no export that writes, applies,
// rolls back, attaches, sets, clears, asks a dialog or reads the act
// records or the memory of another process.
@(rodata)
READ_ONLY_EXPORTS := [?]Read_Only_Export {
	{"log", "records"},
	{"log", "process_records"},
	{"log", "value_runs"},
	{"log", "process_value_runs"},
	{"log", "fact_records"},
	{"plans", "status"},
	{"plans", "current_generation"},
	{"plans", "diff_count"},
	{"plans", "difference"},
	{"plans", "generations"},
	{"recipes", "status"},
	{"recipes", "build_count"},
	{"recipes", "cache_hits"},
	{"recipes", "builds"},
	{"recipes", "realisations"},
	{"projects", "status"},
	{"projects", "active_console_count"},
	{"projects", "pin_count"},
	{"projects", "pins"},
	{"monitor", "processes"},
	{"monitor", "counts"},
	{"monitor", "count"},
	{"monitor", "counts_named"},
	{"monitor", "served"},
	{"compositor", "pointer"},
	{"compositor", "windows"},
	{"compositor", "screen"},
	{"compositor", "gpu_info"},
	{"manual", "modules"},
	{"manual", "exports"},
	{"manual", "signature"},
}

// Pure decision returned by bridge_authorize_command: the request may run
// (Ended with Succeeded), it waits for the principal, or the bridge refused
// it (Ended with the outcome of its refusal).
Bridge_Authorization_Decision :: struct {
	state:             Bridge_Request_State,
	outcome:           call_outcome.Call_Outcome,
	refusal:           Bridge_Refusal,
	required_act_kind: wide_grants.Act_Kind,
}

// Name tables for diagnostics and structured host JSON responses.
@(rodata)
BRIDGE_COMMAND_KIND_NAMES := [Bridge_Command_Kind]string {
	.None           = "None",
	.Eval_Lex       = "Eval_Lex",
	.Read_Screen    = "Read_Screen",
	.Send_Key       = "Send_Key",
	.Send_Pointer   = "Send_Pointer",
	.Read_Log_Facts = "Read_Log_Facts",
}

@(rodata)
BRIDGE_REQUEST_STATE_NAMES := [Bridge_Request_State]string {
	.None                        = "None",
	.Ended                       = "Ended",
	.Awaiting_Principal_Approval = "Awaiting_Principal_Approval",
}

@(rodata)
BRIDGE_REFUSAL_NAMES := [Bridge_Refusal]string {
	.None                        = "None",
	.Bad_Header                  = "Bad_Header",
	.Truncated                   = "Truncated",
	.Trailing_Bytes              = "Trailing_Bytes",
	.Buffer_Too_Small            = "Buffer_Too_Small",
	.Unknown_Command             = "Unknown_Command",
	.Unknown_State               = "Unknown_State",
	.Invalid_Permissions         = "Invalid_Permissions",
	.Permission_Denied           = "Permission_Denied",
	.Client_Key_Missing          = "Client_Key_Missing",
	.Wide_Grant_Required         = "Wide_Grant_Required",
	.Wide_Grant_Not_Active       = "Wide_Grant_Not_Active",
	.Wide_Grant_Expired          = "Wide_Grant_Expired",
	.Window_Not_In_Scope         = "Window_Not_In_Scope",
	.Principal_Approval_Required = "Principal_Approval_Required",
	.Invalid_Field               = "Invalid_Field",
	.Payload_Too_Large           = "Payload_Too_Large",
	.Act_Log_Required            = "Act_Log_Required",
	.Invalid_Text                = "Invalid_Text",
}

@(rodata)
SCREEN_PICTURE_FORMAT_NAMES := [Screen_Picture_Format]string {
	.None     = "None",
	.Png      = "png",
	.Raw_Bgrx = "raw_bgrx",
}

@(rodata)
LEX_VALUE_KIND_NAMES := [Lex_Value_Kind]string {
	.None        = "none",
	.Integer     = "integer",
	.Text        = "text",
	.Boolean     = "boolean",
	.Table       = "table",
	.Record      = "record",
	.Enum_Member = "enum",
}

// Single borders converting raw transport words into closed enums.

bridge_command_kind_from_word :: proc "contextless" (word: u32) -> (kind: Bridge_Command_Kind, ok: bool) {
	member := enum_word.member_of_word(Bridge_Command_Kind, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

bridge_request_state_from_word :: proc "contextless" (word: u32) -> (state: Bridge_Request_State, ok: bool) {
	member := enum_word.member_of_word(Bridge_Request_State, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

bridge_refusal_from_word :: proc "contextless" (word: u32) -> (refusal: Bridge_Refusal, ok: bool) {
	return enum_word.member_of_word(Bridge_Refusal, u64(word))
}

bridge_permission_from_word :: proc "contextless" (word: u64) -> (permission: Bridge_Permission, ok: bool) {
	return enum_word.member_of_word(Bridge_Permission, word)
}

bridge_permissions_to_word :: proc "contextless" (permissions: Bridge_Permissions) -> u64 {
	word: u64 = 0
	if .Eval_Lex in permissions {
		word |= u64(1) << u64(Bridge_Permission.Eval_Lex)
	}
	if .Read_Screen in permissions {
		word |= u64(1) << u64(Bridge_Permission.Read_Screen)
	}
	if .Send_Input in permissions {
		word |= u64(1) << u64(Bridge_Permission.Send_Input)
	}
	if .Read_Log_Facts in permissions {
		word |= u64(1) << u64(Bridge_Permission.Read_Log_Facts)
	}
	return word
}

bridge_permissions_from_word :: proc "contextless" (word: u64) -> (permissions: Bridge_Permissions, ok: bool) {
	if word == 0 || word & ~BRIDGE_PERMISSION_KNOWN_MASK != 0 {
		return {}, false
	}
	decoded: Bridge_Permissions
	if word & (u64(1) << u64(Bridge_Permission.Eval_Lex)) != 0 {
		decoded += {.Eval_Lex}
	}
	if word & (u64(1) << u64(Bridge_Permission.Read_Screen)) != 0 {
		decoded += {.Read_Screen}
	}
	if word & (u64(1) << u64(Bridge_Permission.Send_Input)) != 0 {
		decoded += {.Send_Input}
	}
	if word & (u64(1) << u64(Bridge_Permission.Read_Log_Facts)) != 0 {
		decoded += {.Read_Log_Facts}
	}
	return decoded, true
}

screen_picture_format_from_word :: proc "contextless" (word: u8) -> (format: Screen_Picture_Format, ok: bool) {
	member := enum_word.member_of_word(Screen_Picture_Format, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

lex_value_kind_from_word :: proc "contextless" (word: u8) -> (kind: Lex_Value_Kind, ok: bool) {
	member := enum_word.member_of_word(Lex_Value_Kind, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

bridge_command_kind_name :: proc "contextless" (kind: Bridge_Command_Kind) -> string {
	return BRIDGE_COMMAND_KIND_NAMES[kind]
}

bridge_request_state_name :: proc "contextless" (state: Bridge_Request_State) -> string {
	return BRIDGE_REQUEST_STATE_NAMES[state]
}

// bridge_refusal_outcome gives the call outcome of a refusal of the bridge:
// the one place of this map. A permission, a grant or a scope that the
// client lacks, and permissions that the policy of the client does not
// allow, are Grant_Or_Right_Missing; a request that breaks a rule is
// Argument_Refused; an act log that the bridge needs and cannot write is
// Callee_Unavailable.
bridge_refusal_outcome :: proc "contextless" (refusal: Bridge_Refusal) -> call_outcome.Call_Outcome {
	switch refusal {
	case .None:
		return .Succeeded
	case .Permission_Denied, .Client_Key_Missing, .Wide_Grant_Required, .Wide_Grant_Not_Active, .Wide_Grant_Expired, .Window_Not_In_Scope, .Principal_Approval_Required, .Invalid_Permissions:
		return .Grant_Or_Right_Missing
	case .Act_Log_Required:
		return .Callee_Unavailable
	case .Bad_Header, .Truncated, .Trailing_Bytes, .Buffer_Too_Small, .Unknown_Command, .Unknown_State, .Invalid_Field, .Payload_Too_Large, .Invalid_Text:
		return .Argument_Refused
	}
	return .Argument_Refused
}

// bridge_refused gives the decision of a request that the bridge refused.
bridge_refused :: proc "contextless" (refusal: Bridge_Refusal) -> Bridge_Authorization_Decision {
	return {state = .Ended, outcome = bridge_refusal_outcome(refusal), refusal = refusal}
}

bridge_refusal_name :: proc "contextless" (refusal: Bridge_Refusal) -> string {
	return BRIDGE_REFUSAL_NAMES[refusal]
}

screen_picture_format_name :: proc "contextless" (format: Screen_Picture_Format) -> string {
	return SCREEN_PICTURE_FORMAT_NAMES[format]
}

lex_value_kind_name :: proc "contextless" (kind: Lex_Value_Kind) -> string {
	return LEX_VALUE_KIND_NAMES[kind]
}

// Helper reporting whether a fixed 32-byte key or digest is all zero.
@(private = "file")
bytes_all_zero :: proc "contextless" (data: []u8) -> bool {
	accumulated: u8 = 0
	for item in data {
		accumulated |= item
	}
	return accumulated == 0
}

// encode_command_frame serializes a validated Bridge_Command_Frame in canonical
// little-endian "MODAB1" format. Refused calls leave output untouched.
encode_command_frame :: proc "contextless" (frame: ^Bridge_Command_Frame, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if frame == nil || frame.command == .None {
		return 0, .Unknown_Command
	}
	if frame.request_id == 0 {
		return 0, .Invalid_Field
	}
	client_hash := frame.client_key_hash
	if bytes_all_zero(client_hash[:]) {
		return 0, .Client_Key_Missing
	}
	if len(frame.payload) > MAX_BRIDGE_PAYLOAD_BYTES {
		return 0, .Payload_Too_Large
	}
	total := COMMAND_HEADER_SIZE + len(frame.payload)
	if len(output) < total {
		return 0, .Buffer_Too_Small
	}
	magic := BRIDGE_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		output[index] = magic[index]
	}
	byte_order.write_u16_little_endian(output, 6, BRIDGE_WIRE_VERSION)
	byte_order.write_u32_little_endian(output, 8, u32(frame.command))
	byte_order.write_u64_little_endian(output, 12, frame.request_id)
	byte_order.write_u64_little_endian(output, 20, frame.principal_id)
	byte_order.write_u64_little_endian(output, 28, frame.grant_serial)
	byte_order.write_u64_little_endian(output, 36, frame.target_window_id)
	for index in 0 ..< blake3.HASH_SIZE {
		output[44 + index] = frame.client_key_hash[index]
	}
	byte_order.write_u32_little_endian(output, 76, u32(len(frame.payload)))
	byte_order.write_u32_little_endian(output, 80, 0)
	for index in 0 ..< len(frame.payload) {
		output[COMMAND_HEADER_SIZE + index] = frame.payload[index]
	}
	return total, .None
}

// decode_command_frame strictly validates and decodes one "MODAB1" command
// frame from input. Refuses bad magic/version, non-zero reserved bytes,
// unknown command words, zero request_id or client_key_hash, oversized
// payloads, truncation, and trailing bytes.
decode_command_frame :: proc "contextless" (input: []u8) -> (frame: Bridge_Command_Frame, refusal: Bridge_Refusal) {
	if len(input) < COMMAND_HEADER_SIZE {
		return {}, .Truncated
	}
	magic := BRIDGE_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	if byte_order.read_u16_little_endian(input, 6) != BRIDGE_WIRE_VERSION {
		return {}, .Bad_Header
	}
	command_word := byte_order.read_u32_little_endian(input, 8)
	command, command_ok := bridge_command_kind_from_word(command_word)
	if !command_ok {
		return {}, .Unknown_Command
	}
	request_id := byte_order.read_u64_little_endian(input, 12)
	if request_id == 0 {
		return {}, .Invalid_Field
	}
	principal_id := byte_order.read_u64_little_endian(input, 20)
	grant_serial := byte_order.read_u64_little_endian(input, 28)
	target_window_id := byte_order.read_u64_little_endian(input, 36)
	client_key_hash: blake3.Hash
	for index in 0 ..< blake3.HASH_SIZE {
		client_key_hash[index] = input[44 + index]
	}
	if bytes_all_zero(client_key_hash[:]) {
		return {}, .Client_Key_Missing
	}
	payload_length := byte_order.read_u32_little_endian(input, 76)
	reserved := byte_order.read_u32_little_endian(input, 80)
	if reserved != 0 {
		return {}, .Bad_Header
	}
	if u64(payload_length) > MAX_BRIDGE_PAYLOAD_BYTES {
		return {}, .Payload_Too_Large
	}
	rest := u64(len(input) - COMMAND_HEADER_SIZE)
	if rest < u64(payload_length) {
		return {}, .Truncated
	}
	if rest > u64(payload_length) {
		return {}, .Trailing_Bytes
	}
	return Bridge_Command_Frame {
		command          = command,
		request_id       = request_id,
		principal_id     = principal_id,
		grant_serial     = grant_serial,
		target_window_id = target_window_id,
		client_key_hash  = client_key_hash,
		payload          = input[COMMAND_HEADER_SIZE:],
	}, .None
}

// encode_response_frame serializes a validated Bridge_Response_Frame in
// canonical little-endian "MODAB1" format. Refused calls leave output
// untouched.
encode_response_frame :: proc "contextless" (frame: ^Bridge_Response_Frame, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if frame == nil || frame.state == .None {
		return 0, .Unknown_State
	}
	// Only an ended request has an outcome, and a request that the bridge
	// refused did not succeed.
	if frame.state == .Awaiting_Principal_Approval && frame.outcome != .Succeeded {
		return 0, .Invalid_Field
	}
	if frame.state == .Ended && frame.outcome == .Succeeded && frame.refusal != .None {
		return 0, .Invalid_Field
	}
	if frame.request_id == 0 {
		return 0, .Invalid_Field
	}
	if len(frame.payload) > MAX_BRIDGE_PAYLOAD_BYTES {
		return 0, .Payload_Too_Large
	}
	total := RESPONSE_HEADER_SIZE + len(frame.payload)
	if len(output) < total {
		return 0, .Buffer_Too_Small
	}
	magic := BRIDGE_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		output[index] = magic[index]
	}
	byte_order.write_u16_little_endian(output, 6, BRIDGE_WIRE_VERSION)
	byte_order.write_u32_little_endian(output, 8, u32(frame.state))
	byte_order.write_u32_little_endian(output, 12, u32(frame.refusal))
	byte_order.write_u64_little_endian(output, 16, frame.request_id)
	byte_order.write_u64_little_endian(output, 24, frame.act_sequence_number)
	for index in 0 ..< blake3.HASH_SIZE {
		output[32 + index] = frame.act_record_hash[index]
	}
	byte_order.write_u32_little_endian(output, 64, u32(len(frame.payload)))
	byte_order.write_u32_little_endian(output, 68, u32(frame.outcome))
	for index in 0 ..< len(frame.payload) {
		output[RESPONSE_HEADER_SIZE + index] = frame.payload[index]
	}
	return total, .None
}

// decode_response_frame strictly validates and decodes one "MODAB1" response
// frame from input.
decode_response_frame :: proc "contextless" (input: []u8) -> (frame: Bridge_Response_Frame, refusal: Bridge_Refusal) {
	if len(input) < RESPONSE_HEADER_SIZE {
		return {}, .Truncated
	}
	magic := BRIDGE_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	if byte_order.read_u16_little_endian(input, 6) != BRIDGE_WIRE_VERSION {
		return {}, .Bad_Header
	}
	state_word := byte_order.read_u32_little_endian(input, 8)
	state, state_ok := bridge_request_state_from_word(state_word)
	if !state_ok {
		return {}, .Unknown_State
	}
	refusal_word := byte_order.read_u32_little_endian(input, 12)
	decoded_refusal, refusal_ok := bridge_refusal_from_word(refusal_word)
	if !refusal_ok {
		return {}, .Bad_Header
	}
	request_id := byte_order.read_u64_little_endian(input, 16)
	if request_id == 0 {
		return {}, .Invalid_Field
	}
	act_sequence := byte_order.read_u64_little_endian(input, 24)
	act_hash: blake3.Hash
	for index in 0 ..< blake3.HASH_SIZE {
		act_hash[index] = input[32 + index]
	}
	payload_length := byte_order.read_u32_little_endian(input, 64)
	// The outcome word crosses its border: a word that names no outcome, and
	// an outcome of a request that waits, are refused.
	outcome, unreadable := call_outcome.outcome_of_word(u64(byte_order.read_u32_little_endian(input, 68)))
	if unreadable.kind != 0 || state == .Awaiting_Principal_Approval && outcome != .Succeeded {
		return {}, .Bad_Header
	}
	if state == .Ended && outcome == .Succeeded && decoded_refusal != .None {
		return {}, .Bad_Header
	}
	if u64(payload_length) > MAX_BRIDGE_PAYLOAD_BYTES {
		return {}, .Payload_Too_Large
	}
	rest := u64(len(input) - RESPONSE_HEADER_SIZE)
	if rest < u64(payload_length) {
		return {}, .Truncated
	}
	if rest > u64(payload_length) {
		return {}, .Trailing_Bytes
	}
	return Bridge_Response_Frame {
		state               = state,
		outcome             = outcome,
		refusal             = decoded_refusal,
		request_id          = request_id,
		act_sequence_number = act_sequence,
		act_record_hash     = act_hash,
		payload             = input[RESPONSE_HEADER_SIZE:],
	}, .None
}

// Payload validation and canonical binary codecs for each bridge command.

validate_lex_line :: proc "contextless" (line: []u8) -> Bridge_Refusal {
	if len(line) == 0 {
		return .Invalid_Text
	}
	if len(line) > MAX_LEX_LINE_BYTES {
		return .Payload_Too_Large
	}
	if !text_encoding.text_valid(line) {
		return .Invalid_Text
	}
	return .None
}

validate_read_screen_payload :: proc "contextless" (payload: ^Read_Screen_Payload) -> Bridge_Refusal {
	if payload == nil || payload.format == .None {
		return .Invalid_Field
	}
	if payload.max_width > remote_display.SCREEN_WIDTH_LIMIT || payload.max_height > remote_display.SCREEN_HEIGHT_LIMIT {
		return .Invalid_Field
	}
	if payload.wait_settled_ms > MAX_WAIT_SETTLED_MS {
		return .Invalid_Field
	}
	return .None
}

encode_read_screen_payload :: proc "contextless" (payload: ^Read_Screen_Payload, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if check := validate_read_screen_payload(payload); check != .None {
		return 0, check
	}
	if len(output) < READ_SCREEN_PAYLOAD_SIZE {
		return 0, .Buffer_Too_Small
	}
	output[0] = u8(payload.format)
	output[1] = 0
	output[2] = 0
	output[3] = 0
	byte_order.write_u32_little_endian(output, 4, payload.max_width)
	byte_order.write_u32_little_endian(output, 8, payload.max_height)
	byte_order.write_u32_little_endian(output, 12, payload.wait_settled_ms)
	return READ_SCREEN_PAYLOAD_SIZE, .None
}

decode_read_screen_payload :: proc "contextless" (input: []u8) -> (payload: Read_Screen_Payload, refusal: Bridge_Refusal) {
	if len(input) < READ_SCREEN_PAYLOAD_SIZE {
		return {}, .Truncated
	}
	if len(input) > READ_SCREEN_PAYLOAD_SIZE {
		return {}, .Trailing_Bytes
	}
	format, format_ok := screen_picture_format_from_word(input[0])
	if !format_ok {
		return {}, .Invalid_Field
	}
	if input[1] != 0 || input[2] != 0 || input[3] != 0 {
		return {}, .Bad_Header
	}
	candidate := Read_Screen_Payload {
		format          = format,
		max_width       = byte_order.read_u32_little_endian(input, 4),
		max_height      = byte_order.read_u32_little_endian(input, 8),
		wait_settled_ms = byte_order.read_u32_little_endian(input, 12),
	}
	if check := validate_read_screen_payload(&candidate); check != .None {
		return {}, check
	}
	return candidate, .None
}

validate_send_key_payload :: proc "contextless" (payload: ^Send_Key_Payload) -> Bridge_Refusal {
	if payload == nil {
		return .Invalid_Field
	}
	key := payload.key
	if key.code == 0 || key.code > remote_display.KEY_CODE_LIMIT || key.code & remote_display.KEY_RELEASE_BIT != 0 {
		return .Invalid_Field
	}
	if key.character > remote_display.CHARACTER_LIMIT || (key.character >= 0xD800 && key.character <= 0xDFFF) {
		return .Invalid_Field
	}
	if key.pressed > 1 || key.modifiers & ~u32(remote_display.KEY_MODIFIERS) != 0 {
		return .Invalid_Field
	}
	return .None
}

encode_send_key_payload :: proc "contextless" (payload: ^Send_Key_Payload, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if check := validate_send_key_payload(payload); check != .None {
		return 0, check
	}
	if len(output) < SEND_KEY_PAYLOAD_SIZE {
		return 0, .Buffer_Too_Small
	}
	byte_order.write_u32_little_endian(output, 0, payload.key.code)
	byte_order.write_u32_little_endian(output, 4, payload.key.character)
	byte_order.write_u32_little_endian(output, 8, payload.key.pressed)
	byte_order.write_u32_little_endian(output, 12, payload.key.modifiers)
	return SEND_KEY_PAYLOAD_SIZE, .None
}

decode_send_key_payload :: proc "contextless" (input: []u8) -> (payload: Send_Key_Payload, refusal: Bridge_Refusal) {
	if len(input) < SEND_KEY_PAYLOAD_SIZE {
		return {}, .Truncated
	}
	if len(input) > SEND_KEY_PAYLOAD_SIZE {
		return {}, .Trailing_Bytes
	}
	candidate := Send_Key_Payload {
		key = remote_display.Key_Body {
			code      = byte_order.read_u32_little_endian(input, 0),
			character = byte_order.read_u32_little_endian(input, 4),
			pressed   = byte_order.read_u32_little_endian(input, 8),
			modifiers = byte_order.read_u32_little_endian(input, 12),
		},
	}
	if check := validate_send_key_payload(&candidate); check != .None {
		return {}, check
	}
	return candidate, .None
}

validate_send_pointer_payload :: proc "contextless" (payload: ^Send_Pointer_Payload) -> Bridge_Refusal {
	if payload == nil {
		return .Invalid_Field
	}
	pointer := payload.pointer
	if pointer.x >= remote_display.SCREEN_WIDTH_LIMIT || pointer.y >= remote_display.SCREEN_HEIGHT_LIMIT {
		return .Invalid_Field
	}
	if pointer.buttons & ~u32(remote_display.POINTER_BUTTONS) != 0 {
		return .Invalid_Field
	}
	if pointer.wheel > remote_display.WHEEL_NOTCHES_LIMIT || pointer.wheel < -remote_display.WHEEL_NOTCHES_LIMIT {
		return .Invalid_Field
	}
	return .None
}

encode_send_pointer_payload :: proc "contextless" (payload: ^Send_Pointer_Payload, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if check := validate_send_pointer_payload(payload); check != .None {
		return 0, check
	}
	if len(output) < SEND_POINTER_PAYLOAD_SIZE {
		return 0, .Buffer_Too_Small
	}
	byte_order.write_u32_little_endian(output, 0, payload.pointer.x)
	byte_order.write_u32_little_endian(output, 4, payload.pointer.y)
	byte_order.write_u32_little_endian(output, 8, payload.pointer.buttons)
	byte_order.write_u32_little_endian(output, 12, u32(payload.pointer.wheel))
	return SEND_POINTER_PAYLOAD_SIZE, .None
}

decode_send_pointer_payload :: proc "contextless" (input: []u8) -> (payload: Send_Pointer_Payload, refusal: Bridge_Refusal) {
	if len(input) < SEND_POINTER_PAYLOAD_SIZE {
		return {}, .Truncated
	}
	if len(input) > SEND_POINTER_PAYLOAD_SIZE {
		return {}, .Trailing_Bytes
	}
	wheel_word := byte_order.read_u32_little_endian(input, 12)
	candidate := Send_Pointer_Payload {
		pointer = remote_display.Pointer_Body {
			x       = byte_order.read_u32_little_endian(input, 0),
			y       = byte_order.read_u32_little_endian(input, 4),
			buttons = byte_order.read_u32_little_endian(input, 8),
			wheel   = i32(wheel_word),
		},
	}
	if check := validate_send_pointer_payload(&candidate); check != .None {
		return {}, check
	}
	return candidate, .None
}

@(private = "file")
optional_filter_name_valid :: proc "contextless" (bytes: []u8, length: u8) -> bool {
	size := int(length)
	if size > len(bytes) {
		return false
	}
	if size > 0 {
		if !text_encoding.identifier_valid(bytes[:size]) {
			return false
		}
	}
	for pad in bytes[size:] {
		if pad != 0 {
			return false
		}
	}
	return true
}

validate_read_log_facts_payload :: proc "contextless" (payload: ^Read_Log_Facts_Payload) -> Bridge_Refusal {
	if payload == nil {
		return .Invalid_Field
	}
	if !optional_filter_name_valid(payload.module_filter_bytes[:], payload.module_filter_length) {
		return .Invalid_Text
	}
	if !optional_filter_name_valid(payload.fact_name_filter_bytes[:], payload.fact_name_filter_length) {
		return .Invalid_Text
	}
	if payload.sequence_end != 0 && payload.sequence_end < payload.sequence_start {
		return .Invalid_Field
	}
	if payload.max_records == 0 || payload.max_records > MAX_LOG_FACT_QUERY_LIMIT {
		return .Invalid_Field
	}
	return .None
}

encode_read_log_facts_payload :: proc "contextless" (payload: ^Read_Log_Facts_Payload, output: []u8) -> (written: int, refusal: Bridge_Refusal) {
	if check := validate_read_log_facts_payload(payload); check != .None {
		return 0, check
	}
	total := READ_LOG_FACTS_BASE_SIZE + int(payload.module_filter_length) + int(payload.fact_name_filter_length)
	if len(output) < total {
		return 0, .Buffer_Too_Small
	}
	output[0] = payload.module_filter_length
	output[1] = payload.fact_name_filter_length
	output[2] = 0
	output[3] = 0
	byte_order.write_u32_little_endian(output, 4, payload.max_records)
	byte_order.write_u64_little_endian(output, 8, payload.sequence_start)
	byte_order.write_u64_little_endian(output, 16, payload.sequence_end)
	position := READ_LOG_FACTS_BASE_SIZE
	for index in 0 ..< int(payload.module_filter_length) {
		output[position + index] = payload.module_filter_bytes[index]
	}
	position += int(payload.module_filter_length)
	for index in 0 ..< int(payload.fact_name_filter_length) {
		output[position + index] = payload.fact_name_filter_bytes[index]
	}
	return total, .None
}

decode_read_log_facts_payload :: proc "contextless" (input: []u8) -> (payload: Read_Log_Facts_Payload, refusal: Bridge_Refusal) {
	if len(input) < READ_LOG_FACTS_BASE_SIZE {
		return {}, .Truncated
	}
	module_len := input[0]
	fact_len := input[1]
	if input[2] != 0 || input[3] != 0 {
		return {}, .Bad_Header
	}
	if int(module_len) > MAX_FILTER_NAME_BYTES || int(fact_len) > MAX_FILTER_NAME_BYTES {
		return {}, .Invalid_Field
	}
	expected := READ_LOG_FACTS_BASE_SIZE + int(module_len) + int(fact_len)
	if len(input) < expected {
		return {}, .Truncated
	}
	if len(input) > expected {
		return {}, .Trailing_Bytes
	}
	candidate := Read_Log_Facts_Payload {
		module_filter_length    = module_len,
		fact_name_filter_length = fact_len,
		max_records             = byte_order.read_u32_little_endian(input, 4),
		sequence_start          = byte_order.read_u64_little_endian(input, 8),
		sequence_end            = byte_order.read_u64_little_endian(input, 16),
	}
	position := READ_LOG_FACTS_BASE_SIZE
	for index in 0 ..< int(module_len) {
		candidate.module_filter_bytes[index] = input[position + index]
	}
	position += int(module_len)
	for index in 0 ..< int(fact_len) {
		candidate.fact_name_filter_bytes[index] = input[position + index]
	}
	if check := validate_read_log_facts_payload(&candidate); check != .None {
		return {}, check
	}
	return candidate, .None
}

// The strict parser of one Eval_Lex call. It accepts only the form
//
//     service.export
//     service.export(argument, ...)
//
// where each argument is a literal, or a name, an operator and a literal:
// an integer, true or false, a text, a hash blake3:<hex>, or a member .name.
// Everything else is Malformed: a second line, a control byte, a comment, a
// pipe, a nested call, a bare name (which can name a command), a list, a
// record, a function, a let. A text of Lex has no escape: it ends at the
// next quote, as the parser of Lex reads it.

@(private = "file")
Lex_Call_Parser :: struct {
	line:     []u8,
	position: int,
}

@(private = "file")
is_lex_name_start :: proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

@(private = "file")
is_lex_name_byte :: proc "contextless" (ch: u8) -> bool {
	return is_lex_name_start(ch) || (ch >= '0' && ch <= '9')
}

@(private = "file")
is_lower_hex_digit :: proc "contextless" (ch: u8) -> bool {
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
}

@(private = "file")
bytes_equal_literal :: proc "contextless" (slice_bytes: []u8, literal: string) -> bool {
	if len(slice_bytes) != len(literal) {
		return false
	}
	raw := transmute([]u8)literal
	for index in 0 ..< len(raw) {
		if slice_bytes[index] != raw[index] {
			return false
		}
	}
	return true
}

@(private = "file")
parser_at_end :: proc "contextless" (parser: ^Lex_Call_Parser) -> bool {
	return parser.position >= len(parser.line)
}

@(private = "file")
parser_peek :: proc "contextless" (parser: ^Lex_Call_Parser, offset := 0) -> u8 {
	at := parser.position + offset
	if at >= len(parser.line) {
		return 0
	}
	return parser.line[at]
}

@(private = "file")
parser_skip_spaces :: proc "contextless" (parser: ^Lex_Call_Parser) {
	for !parser_at_end(parser) && (parser.line[parser.position] == ' ' || parser.line[parser.position] == '\t') {
		parser.position += 1
	}
}

// parser_name reads one name with no dot: a letter or _, then letters,
// digits and _.
@(private = "file")
parser_name :: proc "contextless" (parser: ^Lex_Call_Parser) -> (name: []u8, ok: bool) {
	if !is_lex_name_start(parser_peek(parser)) {
		return nil, false
	}
	start := parser.position
	for !parser_at_end(parser) && is_lex_name_byte(parser.line[parser.position]) {
		parser.position += 1
	}
	return parser.line[start:parser.position], true
}

// parser_literal reads one literal value.
@(private = "file")
parser_literal :: proc "contextless" (parser: ^Lex_Call_Parser) -> bool {
	ch := parser_peek(parser)
	switch {
	case ch == '"':
		parser.position += 1
		for !parser_at_end(parser) && parser.line[parser.position] != '"' {
			parser.position += 1
		}
		if parser_at_end(parser) {
			return false
		}
		parser.position += 1
		return true
	case ch == '-' || (ch >= '0' && ch <= '9'):
		if ch == '-' {
			parser.position += 1
		}
		digits := 0
		for !parser_at_end(parser) && parser.line[parser.position] >= '0' && parser.line[parser.position] <= '9' {
			parser.position += 1
			digits += 1
		}
		// A digit run that goes on with a letter is no integer of Lex.
		return digits > 0 && !is_lex_name_byte(parser_peek(parser))
	case ch == '.':
		parser.position += 1
		_, member_ok := parser_name(parser)
		return member_ok && parser_peek(parser) != '.'
	case is_lex_name_start(ch):
		word, _ := parser_name(parser)
		if bytes_equal_literal(word, "true") || bytes_equal_literal(word, "false") {
			return true
		}
		if bytes_equal_literal(word, "blake3") && parser_peek(parser) == ':' {
			parser.position += 1
			digits := 0
			for !parser_at_end(parser) && is_lower_hex_digit(parser.line[parser.position]) {
				parser.position += 1
				digits += 1
			}
			return digits == 2 * blake3.HASH_SIZE && !is_lex_name_byte(parser_peek(parser))
		}
		// A bare name can name a command or an export: it is no literal.
		return false
	}
	return false
}

// parser_comparison reads the operator of a named argument or of a condition.
@(private = "file")
parser_comparison :: proc "contextless" (parser: ^Lex_Call_Parser) -> bool {
	first := parser_peek(parser)
	second := parser_peek(parser, 1)
	switch first {
	case '=':
		if second == '=' {
			return false
		}
		parser.position += 1
		return true
	case '!':
		if second != '=' {
			return false
		}
		parser.position += 2
		return true
	case '<', '>':
		parser.position += second == '=' ? 2 : 1
		return true
	}
	return false
}

// parser_argument reads one argument: a literal, or a name, an operator and
// a literal.
@(private = "file")
parser_argument :: proc "contextless" (parser: ^Lex_Call_Parser) -> bool {
	ch := parser_peek(parser)
	if is_lex_name_start(ch) {
		saved := parser.position
		word, _ := parser_name(parser)
		is_literal_word := bytes_equal_literal(word, "true") || bytes_equal_literal(word, "false") || (bytes_equal_literal(word, "blake3") && parser_peek(parser) == ':')
		if is_literal_word {
			parser.position = saved
			return parser_literal(parser)
		}
		parser_skip_spaces(parser)
		if !parser_comparison(parser) {
			return false
		}
		parser_skip_spaces(parser)
		return parser_literal(parser)
	}
	return parser_literal(parser)
}

// lex_line_single_call parses line as exactly one call and gives the names of
// its service and its export.
lex_line_single_call :: proc "contextless" (line: []u8) -> (service: []u8, export: []u8, ok: bool) {
	for value in line {
		// A line end starts a second call, and a control byte hides text from
		// the principal who reads the line: only the tab is kept.
		if (value < 0x20 && value != '\t') || value == 0x7F {
			return nil, nil, false
		}
	}
	parser := Lex_Call_Parser{line = line}
	parser_skip_spaces(&parser)
	service = parser_name(&parser) or_return
	if parser_peek(&parser) != '.' {
		return nil, nil, false
	}
	parser.position += 1
	export = parser_name(&parser) or_return
	if parser_peek(&parser) == '.' {
		return nil, nil, false
	}
	parser_skip_spaces(&parser)
	if parser_at_end(&parser) {
		return service, export, true
	}
	if parser_peek(&parser) != '(' {
		return nil, nil, false
	}
	parser.position += 1
	parser_skip_spaces(&parser)
	if parser_peek(&parser) == ')' {
		parser.position += 1
	} else {
		for {
			parser_skip_spaces(&parser)
			if !parser_argument(&parser) {
				return nil, nil, false
			}
			parser_skip_spaces(&parser)
			next := parser_peek(&parser)
			if next == ',' {
				parser.position += 1
				continue
			}
			if next == ')' {
				parser.position += 1
				break
			}
			return nil, nil, false
		}
	}
	parser_skip_spaces(&parser)
	if !parser_at_end(&parser) {
		return nil, nil, false
	}
	return service, export, true
}

// lex_export_is_read_only reports whether service.export is on READ_ONLY_EXPORTS.
lex_export_is_read_only :: proc "contextless" (service: []u8, export: []u8) -> bool {
	for entry in READ_ONLY_EXPORTS {
		if bytes_equal_literal(service, entry.service) && bytes_equal_literal(export, entry.export) {
			return true
		}
	}
	return false
}

// lex_line_classify classifies an Eval_Lex line. It fails closed: a line
// that is not one call is Malformed, and a call of an export outside the
// read-only list requires the approval of the principal.
lex_line_classify :: proc "contextless" (line: []u8) -> Lex_Line_Class {
	service, export, ok := lex_line_single_call(line)
	if !ok {
		return .Malformed
	}
	if lex_export_is_read_only(service, export) {
		return .Read_Only
	}
	return .Requires_Principal_Approval
}

// bridge_authorize_command evaluates every capability, scope, wide grant,
// collector availability, and principal-approval invariant for one command.
// Pure and contextless: allocates nothing and performs no I/O.
bridge_authorize_command :: proc "contextless" (
	policy: ^Bridge_Client_Policy,
	request: ^Bridge_Authorization_Request,
) -> Bridge_Authorization_Decision {
	if policy == nil || request == nil {
		return bridge_refused(.Invalid_Field)
	}
	if request.command == .None {
		return bridge_refused(.Unknown_Command)
	}
	client_key := policy.client_key_public
	if bytes_all_zero(client_key[:]) {
		return bridge_refused(.Client_Key_Missing)
	}
	permissions, perm_ok := bridge_permissions_from_word(policy.permissions_word)
	if !perm_ok {
		return bridge_refused(.Invalid_Permissions)
	}
	remote_uses, uses_ok := remote.client_uses_of_word(policy.remote_uses_word)
	if !uses_ok {
		return bridge_refused(.Invalid_Permissions)
	}

	// Gate 1: Explicit client permissions and remote client key uses.
	switch request.command {
	case .None:
		return bridge_refused(.Unknown_Command)
	case .Eval_Lex:
		if .Eval_Lex not_in permissions || .Calls not_in remote_uses {
			return bridge_refused(.Permission_Denied)
		}
	case .Read_Screen:
		if .Read_Screen not_in permissions || .View not_in remote_uses {
			return bridge_refused(.Permission_Denied)
		}
	case .Send_Key, .Send_Pointer:
		if .Send_Input not_in permissions || .View not_in remote_uses || .Input not_in remote_uses {
			return bridge_refused(.Permission_Denied)
		}
	case .Read_Log_Facts:
		if .Read_Log_Facts not_in permissions || .Calls not_in remote_uses {
			return bridge_refused(.Permission_Denied)
		}
	}

	// Gate 2: Command-specific structural and wide grant checks.
	switch request.command {
	case .None:
		return bridge_refused(.Unknown_Command)
	case .Eval_Lex:
		if text_refusal := validate_lex_line(request.lex_line); text_refusal != .None {
			return bridge_refused(text_refusal)
		}
		switch lex_line_classify(request.lex_line) {
		case .None, .Malformed:
			return bridge_refused(.Invalid_Text)
		case .Requires_Principal_Approval:
			// plans.apply and plans.rollback are here: the bridge never
			// approves a change of the plan, whatever the caller says of it.
			return {state = .Awaiting_Principal_Approval, refusal = .Principal_Approval_Required}
		case .Read_Only:
		}
		return {state = .Ended, outcome = .Succeeded, refusal = .None, required_act_kind = .Action_Invoked}

	case .Read_Screen:
		return {state = .Ended, outcome = .Succeeded, refusal = .None, required_act_kind = .Frame_Read}

	case .Send_Key, .Send_Pointer:
		if !policy.has_wide_grant || policy.wide_grant_serial == 0 {
			return bridge_refused(.Wide_Grant_Required)
		}
		grant_state, state_ok := wide_grants.wide_grant_state_from_word(policy.wide_grant_state_word)
		if !state_ok {
			return bridge_refused(.Wide_Grant_Not_Active)
		}
		switch grant_state {
		case .None, .Pending, .Revoked:
			return bridge_refused(.Wide_Grant_Not_Active)
		case .Expired:
			return bridge_refused(.Wide_Grant_Expired)
		case .Active:
		}
		terms := policy.wide_grant_terms
		if wide_grants.wide_grant_terms_validate(&terms) != .None {
			return bridge_refused(.Wide_Grant_Not_Active)
		}
		if terms.principal_id != policy.principal_id {
			return bridge_refused(.Wide_Grant_Not_Active)
		}
		expected_grantee := blake3.hash(client_key[:])
		if terms.grantee_identity_hash != expected_grantee {
			return bridge_refused(.Wide_Grant_Not_Active)
		}
		authorities, auth_ok := wide_grants.wide_authorities_from_word(terms.authorities_word)
		if !auth_ok || .View_Screen not_in authorities || .Send_Input not_in authorities {
			return bridge_refused(.Permission_Denied)
		}
		if policy.wide_grant_expires_ms <= policy.wide_grant_created_ms {
			return bridge_refused(.Wide_Grant_Expired)
		}
		if policy.wide_grant_expires_ms - policy.wide_grant_created_ms > terms.duration_ms {
			return bridge_refused(.Wide_Grant_Not_Active)
		}
		if request.now_ms < policy.wide_grant_created_ms || request.now_ms >= policy.wide_grant_expires_ms {
			return bridge_refused(.Wide_Grant_Expired)
		}
		if request.target_window_id == 0 || !wide_grants.wide_grant_terms_contains_window(&terms, request.target_window_id) {
			return bridge_refused(.Window_Not_In_Scope)
		}
		if !policy.collector_available {
			return bridge_refused(.Act_Log_Required)
		}
		act_kind := wide_grants.Act_Kind.Key_Injected
		if request.command == .Send_Pointer {
			act_kind = request.pointer_has_click ? .Pointer_Clicked : .Pointer_Moved
		}
		return {state = .Ended, outcome = .Succeeded, refusal = .None, required_act_kind = act_kind}

	case .Read_Log_Facts:
		return {state = .Ended, outcome = .Succeeded, refusal = .None, required_act_kind = .None}
	}

	return bridge_refused(.Unknown_Command)
}
