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
// - Any Plan_Difference with any_grant_added == true, any unverified
//   plans.apply call, or any sensitive action gated by
//   wide_grants.act_requires_principal_proof ALWAYS stops with
//   Bridge_Status.Awaiting_Principal_Approval and never self-approves.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package agent_bridge

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/plans_recipes"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/text_encoding"
import "modus:contract/wide_grants"

// Wire magic and version identifying version 1 of the Agent Bridge binary
// frame format.
BRIDGE_WIRE_MAGIC :: [6]u8{'M', 'O', 'D', 'A', 'B', '1'}
BRIDGE_WIRE_VERSION :: u16(1)

// Exact binary header sizes for command and response frames.
// Command:  magic(6) + version(2) + command(4) + request_id(8) +
//           principal_id(8) + grant_serial(8) + target_window_id(8) +
//           client_key_hash(32) + payload_length(4) + reserved(4) = 84 bytes.
// Response: magic(6) + version(2) + status(4) + refusal(4) + request_id(8) +
//           act_sequence(8) + act_hash(32) + payload_length(4) + reserved(4)
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

// Closed set of outcome statuses returned by the Agent Bridge.
// Zero means unset and is refused at the border.
Bridge_Status :: enum u32 {
	None                        = 0,
	Ok                          = 1,
	Awaiting_Principal_Approval = 2,
	Refused                     = 3,
	Transport_Error             = 4,
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
	Unknown_Status              = 6,
	Invalid_Permissions         = 7,
	Permission_Denied           = 8,
	Client_Key_Missing          = 9,
	Wide_Grant_Required         = 10,
	Wide_Grant_Not_Active       = 11,
	Wide_Grant_Expired          = 12,
	Window_Not_In_Scope         = 13,
	Principal_Approval_Required = 14,
	Sensitive_Action_Blocked    = 15,
	Invalid_Field               = 16,
	Payload_Too_Large           = 17,
	Act_Log_Required            = 18,
	Invalid_Text                = 19,
}

// Closed set of picture encodings requested through Read_Screen.
Screen_Picture_Format :: enum u8 {
	None     = 0,
	Png      = 1,
	Raw_Bgrx = 2,
}

// Closed set of typed value kinds returned by Eval_Lex.
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

// Canonical decoded response frame.
Bridge_Response_Frame :: struct {
	status:              Bridge_Status,
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
// call runs.
Bridge_Authorization_Request :: struct {
	command:               Bridge_Command_Kind,
	now_ms:                u64,
	target_window_id:      u64,
	sensitive_action_word: u64,
	has_plan_difference:   bool,
	plan_difference:       ^plans_recipes.Plan_Difference,
	lex_line:              []u8,
	pointer_has_click:     bool,
}

// Pure decision returned by bridge_authorize_command.
Bridge_Authorization_Decision :: struct {
	status:            Bridge_Status,
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
BRIDGE_STATUS_NAMES := [Bridge_Status]string {
	.None                        = "None",
	.Ok                          = "Ok",
	.Awaiting_Principal_Approval = "Awaiting_Principal_Approval",
	.Refused                     = "Refused",
	.Transport_Error             = "Transport_Error",
}

@(rodata)
BRIDGE_REFUSAL_NAMES := [Bridge_Refusal]string {
	.None                        = "None",
	.Bad_Header                  = "Bad_Header",
	.Truncated                   = "Truncated",
	.Trailing_Bytes              = "Trailing_Bytes",
	.Buffer_Too_Small            = "Buffer_Too_Small",
	.Unknown_Command             = "Unknown_Command",
	.Unknown_Status              = "Unknown_Status",
	.Invalid_Permissions         = "Invalid_Permissions",
	.Permission_Denied           = "Permission_Denied",
	.Client_Key_Missing          = "Client_Key_Missing",
	.Wide_Grant_Required         = "Wide_Grant_Required",
	.Wide_Grant_Not_Active       = "Wide_Grant_Not_Active",
	.Wide_Grant_Expired          = "Wide_Grant_Expired",
	.Window_Not_In_Scope         = "Window_Not_In_Scope",
	.Principal_Approval_Required = "Principal_Approval_Required",
	.Sensitive_Action_Blocked    = "Sensitive_Action_Blocked",
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

bridge_status_from_word :: proc "contextless" (word: u32) -> (status: Bridge_Status, ok: bool) {
	member := enum_word.member_of_word(Bridge_Status, u64(word)) or_return
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

bridge_status_name :: proc "contextless" (status: Bridge_Status) -> string {
	return BRIDGE_STATUS_NAMES[status]
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
	if frame == nil || frame.status == .None {
		return 0, .Unknown_Status
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
	byte_order.write_u32_little_endian(output, 8, u32(frame.status))
	byte_order.write_u32_little_endian(output, 12, u32(frame.refusal))
	byte_order.write_u64_little_endian(output, 16, frame.request_id)
	byte_order.write_u64_little_endian(output, 24, frame.act_sequence_number)
	for index in 0 ..< blake3.HASH_SIZE {
		output[32 + index] = frame.act_record_hash[index]
	}
	byte_order.write_u32_little_endian(output, 64, u32(len(frame.payload)))
	byte_order.write_u32_little_endian(output, 68, 0)
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
	status_word := byte_order.read_u32_little_endian(input, 8)
	status, status_ok := bridge_status_from_word(status_word)
	if !status_ok {
		return {}, .Unknown_Status
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
	reserved := byte_order.read_u32_little_endian(input, 68)
	if reserved != 0 {
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
		status              = status,
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

// Lex line scanner for sensitive and grant-escalating calls.

@(private = "file")
is_lex_identifier_byte :: proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
}

@(private = "file")
is_lex_space :: proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
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

// lex_line_classify_sensitive_action scans a Lex line outside string literals
// and comments to detect plans.apply and sensitive grant/principal/replace
// calls. Fails closed if a string literal is unclosed.
lex_line_classify_sensitive_action :: proc "contextless" (line: []u8) -> (action: wide_grants.Sensitive_Action, is_plans_apply: bool) {
	index := 0
	for index < len(line) {
		ch := line[index]
		// Skip double-quoted string literals; unclosed string fails closed.
		if ch == '"' {
			index += 1
			closed := false
			for index < len(line) {
				if line[index] == '\\' && index + 1 < len(line) {
					index += 2
					continue
				}
				if line[index] == '"' {
					closed = true
					index += 1
					break
				}
				index += 1
			}
			if !closed {
				return .None, false
			}
			continue
		}
		// Comments extend to end of line.
		if ch == '#' || (ch == '-' && index + 1 < len(line) && line[index + 1] == '-') || (ch == '/' && index + 1 < len(line) && line[index + 1] == '/') {
			break
		}
		if !is_lex_identifier_byte(ch) {
			index += 1
			continue
		}
		start := index
		for index < len(line) && is_lex_identifier_byte(line[index]) {
			index += 1
		}
		first_token := line[start:index]

		// Peek past optional spaces for a dotted qualifier (for example
		// `plans.apply` or `debugger.attach`).
		probe := index
		for probe < len(line) && is_lex_space(line[probe]) {
			probe += 1
		}
		has_member := false
		second_token: []u8
		if probe < len(line) && line[probe] == '.' {
			member_pos := probe + 1
			for member_pos < len(line) && is_lex_space(line[member_pos]) {
				member_pos += 1
			}
			member_start := member_pos
			for member_pos < len(line) && is_lex_identifier_byte(line[member_pos]) {
				member_pos += 1
			}
			if member_pos > member_start {
				has_member = true
				second_token = line[member_start:member_pos]
				index = member_pos
			}
		}

		if has_member {
			if bytes_equal_literal(first_token, "plans") && bytes_equal_literal(second_token, "apply") {
				return .Plans_Apply_Adding_Grant, true
			}
			if bytes_equal_literal(first_token, "debugger") && bytes_equal_literal(second_token, "attach") {
				return .Module_Replace_Or_Debug, false
			}
			continue
		}

		if bytes_equal_literal(first_token, "allow") ||
			bytes_equal_literal(first_token, "disallow") ||
			bytes_equal_literal(first_token, "remote_allow") ||
			bytes_equal_literal(first_token, "remote_disallow") ||
			bytes_equal_literal(first_token, "remote_display_allow") ||
			bytes_equal_literal(first_token, "remote_display_disallow") ||
			bytes_equal_literal(first_token, "remote_token") ||
			bytes_equal_literal(first_token, "agent_allow") ||
			bytes_equal_literal(first_token, "agent_disallow") {
			return .Disk_Grant_Change, false
		}
		if bytes_equal_literal(first_token, "machine_passphrase") ||
			bytes_equal_literal(first_token, "principal_create") ||
			bytes_equal_literal(first_token, "lock") ||
			bytes_equal_literal(first_token, "unlock") {
			return .Principal_Management, false
		}
		if bytes_equal_literal(first_token, "replace") || bytes_equal_literal(first_token, "debug") {
			return .Module_Replace_Or_Debug, false
		}
	}
	return .Normal_Semantic_Read, false
}

// bridge_authorize_command evaluates every capability, scope, wide grant,
// collector availability, and principal-approval invariant for one command.
// Pure and contextless: allocates nothing and performs no I/O.
bridge_authorize_command :: proc "contextless" (
	policy: ^Bridge_Client_Policy,
	request: ^Bridge_Authorization_Request,
) -> Bridge_Authorization_Decision {
	if policy == nil || request == nil {
		return {status = .Refused, refusal = .Invalid_Field}
	}
	if request.command == .None {
		return {status = .Refused, refusal = .Unknown_Command}
	}
	client_key := policy.client_key_public
	if bytes_all_zero(client_key[:]) {
		return {status = .Refused, refusal = .Client_Key_Missing}
	}
	permissions, perm_ok := bridge_permissions_from_word(policy.permissions_word)
	if !perm_ok {
		return {status = .Refused, refusal = .Invalid_Permissions}
	}
	remote_uses, uses_ok := remote.client_uses_of_word(policy.remote_uses_word)
	if !uses_ok {
		return {status = .Refused, refusal = .Invalid_Permissions}
	}

	// Gate 1: Explicit client permissions and remote client key uses.
	switch request.command {
	case .None:
		return {status = .Refused, refusal = .Unknown_Command}
	case .Eval_Lex:
		if .Eval_Lex not_in permissions || .Calls not_in remote_uses {
			return {status = .Refused, refusal = .Permission_Denied}
		}
	case .Read_Screen:
		if .Read_Screen not_in permissions || .View not_in remote_uses {
			return {status = .Refused, refusal = .Permission_Denied}
		}
	case .Send_Key, .Send_Pointer:
		if .Send_Input not_in permissions || .View not_in remote_uses || .Input not_in remote_uses {
			return {status = .Refused, refusal = .Permission_Denied}
		}
	case .Read_Log_Facts:
		if .Read_Log_Facts not_in permissions || .Calls not_in remote_uses {
			return {status = .Refused, refusal = .Permission_Denied}
		}
	}

	// Gate 2: Sensitive action proof gate (fails closed on unknown words).
	if request.sensitive_action_word != 0 {
		action, action_ok := wide_grants.sensitive_action_from_word(request.sensitive_action_word)
		if !action_ok {
			return {status = .Awaiting_Principal_Approval, refusal = .Sensitive_Action_Blocked}
		}
		if wide_grants.act_requires_principal_proof(action) {
			return {status = .Awaiting_Principal_Approval, refusal = .Principal_Approval_Required}
		}
	}

	// Gate 3: Plan_Difference invariant. Any plan difference that adds a grant
	// ALWAYS stops with Awaiting_Principal_Approval and never self-approves.
	if request.has_plan_difference {
		if request.plan_difference == nil || request.plan_difference.any_grant_added {
			return {status = .Awaiting_Principal_Approval, refusal = .Principal_Approval_Required}
		}
	}

	// Gate 4: Command-specific structural and wide grant checks.
	switch request.command {
	case .None:
		return {status = .Refused, refusal = .Unknown_Command}
	case .Eval_Lex:
		if text_refusal := validate_lex_line(request.lex_line); text_refusal != .None {
			return {status = .Refused, refusal = text_refusal}
		}
		classified, is_plans_apply := lex_line_classify_sensitive_action(request.lex_line)
		if is_plans_apply {
			// plans.apply is permitted through the bridge ONLY when accompanied
			// by a verified Plan_Difference with any_grant_added == false.
			if !request.has_plan_difference || request.plan_difference == nil || request.plan_difference.any_grant_added {
				return {status = .Awaiting_Principal_Approval, refusal = .Principal_Approval_Required}
			}
		} else if wide_grants.act_requires_principal_proof(classified) {
			return {status = .Awaiting_Principal_Approval, refusal = .Principal_Approval_Required}
		}
		return {status = .Ok, refusal = .None, required_act_kind = .Action_Invoked}

	case .Read_Screen:
		return {status = .Ok, refusal = .None, required_act_kind = .Frame_Read}

	case .Send_Key, .Send_Pointer:
		if !policy.has_wide_grant || policy.wide_grant_serial == 0 {
			return {status = .Refused, refusal = .Wide_Grant_Required}
		}
		grant_state, state_ok := wide_grants.wide_grant_state_from_word(policy.wide_grant_state_word)
		if !state_ok {
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		}
		switch grant_state {
		case .None, .Pending, .Revoked:
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		case .Expired:
			return {status = .Refused, refusal = .Wide_Grant_Expired}
		case .Active:
		}
		terms := policy.wide_grant_terms
		if wide_grants.wide_grant_terms_validate(&terms) != .None {
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		}
		if terms.principal_id != policy.principal_id {
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		}
		expected_grantee := blake3.hash(client_key[:])
		if terms.grantee_identity_hash != expected_grantee {
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		}
		authorities, auth_ok := wide_grants.wide_authorities_from_word(terms.authorities_word)
		if !auth_ok || .View_Screen not_in authorities || .Send_Input not_in authorities {
			return {status = .Refused, refusal = .Permission_Denied}
		}
		if policy.wide_grant_expires_ms <= policy.wide_grant_created_ms {
			return {status = .Refused, refusal = .Wide_Grant_Expired}
		}
		if policy.wide_grant_expires_ms - policy.wide_grant_created_ms > terms.duration_ms {
			return {status = .Refused, refusal = .Wide_Grant_Not_Active}
		}
		if request.now_ms < policy.wide_grant_created_ms || request.now_ms >= policy.wide_grant_expires_ms {
			return {status = .Refused, refusal = .Wide_Grant_Expired}
		}
		if request.target_window_id == 0 || !wide_grants.wide_grant_terms_contains_window(&terms, request.target_window_id) {
			return {status = .Refused, refusal = .Window_Not_In_Scope}
		}
		if !policy.collector_available {
			return {status = .Refused, refusal = .Act_Log_Required}
		}
		act_kind := wide_grants.Act_Kind.Key_Injected
		if request.command == .Send_Pointer {
			act_kind = request.pointer_has_click ? .Pointer_Clicked : .Pointer_Moved
		}
		return {status = .Ok, refusal = .None, required_act_kind = act_kind}

	case .Read_Log_Facts:
		return {status = .Ok, refusal = .None, required_act_kind = .None}
	}

	return {status = .Refused, refusal = .Unknown_Command}
}
