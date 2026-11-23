// Host-side typed Agent Bridge adapter and stdio JSON-RPC server
// (src/md/features/agent_bridge.md).
//
// Parses line-delimited JSON-RPC 2.0 requests (and raw "MODAB1" wire frames),
// enforces client-key permissions, remote key uses, active wide-grant window
// scopes, append-only BLAKE3 collector act recording, and the principal
// approval invariant before delegating to a pluggable Machine_Transport.
package host_agent_bridge

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import contract "modus:contract/agent_bridge"
import "modus:contract/blake3"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/wide_grants"
import "modustool:foundation"
import "modustool:machine"

// Default bounded capacity of the host-side append-only BLAKE3 act log.
DEFAULT_BRIDGE_ACT_CAPACITY :: 1024

// Closed set of JSON-RPC 2.0 and bridge-specific error codes.
Json_Rpc_Error_Code :: enum i64 {
	Parse_Error                 = -32700,
	Invalid_Request             = -32600,
	Method_Not_Found            = -32601,
	Invalid_Params              = -32602,
	Awaiting_Principal_Approval = -32001,
	Refused                     = -32002,
	Transport_Error             = -32003,
}

// Closed set of JSON-RPC request method names served by the bridge.
Bridge_Json_Method :: enum u8 {
	None           = 0,
	Eval_Lex       = 1,
	Read_Screen    = 2,
	Send_Key       = 3,
	Send_Pointer   = 4,
	Read_Log_Facts = 5,
	Wire_Command   = 6,
	// The ask of a wide grant for the key of the bridge: the trusted display
	// of the machine shows its screen, and the principal answers there.
	Ask_Wide_Grant = 7,
}

// Structured typed result returned by Eval_Lex (never scraped terminal text).
Lex_Eval_Result :: struct {
	value_kind:    contract.Lex_Value_Kind,
	integer_value: i64,
	bool_value:    bool,
	text_value:    string,
	record_name:   string,
	columns:       []string,
	column_kinds:  []contract.Lex_Column_Kind, // How each column is written and aligned; none: each column is a text.
	column_units:  []i64, // The unit word of each column (contract.lex_column_unit_valid).
	rows:          [][]string, // The text of each cell.
	row_integers:  [][]i64, // The value of each cell of a number column, 0 in a text column; none: no number column.
	total_rows:    i64,
}

// Request parameters passed to Machine_Transport.read_screen.
Screen_Snapshot_Request :: struct {
	format:          contract.Screen_Picture_Format,
	max_width:       u32,
	max_height:      u32,
	wait_settled_ms: u32,
}

// Structured screen snapshot returned by Machine_Transport.read_screen.
Screen_Snapshot_Result :: struct {
	format:       contract.Screen_Picture_Format,
	width:        u32,
	height:       u32,
	frame_serial: u64,
	bytes:        []u8,
	content_hash: blake3.Hash,
}

// Query filters passed to Machine_Transport.read_log_facts.
Log_Facts_Query :: struct {
	module_filter:    string,
	fact_name_filter: string,
	sequence_start:   u64,
	sequence_end:     u64,
	max_records:      u32,
}

// One typed field of a structured log fact.
Log_Fact_Field :: struct {
	name:  string,
	value: string,
}

// One structured log fact returned by Machine_Transport.read_log_facts.
Structured_Log_Fact :: struct {
	sequence:     u64,
	timestamp_ms: u64,
	module_name:  string,
	fact_name:    string,
	level:        string,
	fields:       []Log_Fact_Field,
}

// Pluggable machine transport backing the host bridge. Wired to the real
// remote QUIC call transport for live machines and to an in-memory fake in
// host tests.
Machine_Transport :: struct {
	user_data:      rawptr,
	eval_lex:       proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: Lex_Eval_Result, err: string, ok: bool),
	read_screen:    proc(user_data: rawptr, request: Screen_Snapshot_Request, allocator: mem.Allocator) -> (snapshot: Screen_Snapshot_Result, err: string, ok: bool),
	send_key:       proc(user_data: rawptr, window_id: u64, key: remote_display.Key_Body) -> (err: string, ok: bool),
	send_pointer:   proc(user_data: rawptr, window_id: u64, pointer: remote_display.Pointer_Body) -> (err: string, ok: bool),
	read_log_facts: proc(user_data: rawptr, query: Log_Facts_Query, allocator: mem.Allocator) -> (facts: []Structured_Log_Fact, err: string, ok: bool),
	ask_wide_grant: proc(user_data: rawptr, authorities: wide_grants.Wide_Authorities, duration_ms: u64) -> (screen: u64, err: string, ok: bool),
}

// Bounded append-only host-side BLAKE3 hash-chained act log using the exact
// "modus act record v1" chain defined by modus:contract/wide_grants.
Bridge_Act_Log :: struct {
	initialized:       bool,
	capacity:          u32,
	next_sequence:     u64,
	last_timestamp_ms: u64,
	head_hash:         blake3.Hash,
	records:           [dynamic]wide_grants.Act_Record,
}

// Host Agent Bridge instance pairing a client policy, append-only act log,
// clock source, and pluggable Machine_Transport.
Agent_Bridge :: struct {
	policy:          contract.Bridge_Client_Policy,
	transport:       Machine_Transport,
	act_log:         Bridge_Act_Log,
	clock_ms_proc:   proc(user_data: rawptr) -> u64,
	clock_user_data: rawptr,
	next_request_id: u64,
	// The folder that the operator named with --snapshot-dir, or empty: then
	// read_screen writes no file. An agent never names a path of the host.
	snapshot_directory:     string,
	next_snapshot_sequence: u64,
}

// bridge_act_log_init initializes a bounded append-only BLAKE3 act log.
bridge_act_log_init :: proc(log: ^Bridge_Act_Log, capacity: u32 = DEFAULT_BRIDGE_ACT_CAPACITY, allocator := context.allocator) -> bool {
	if log == nil || capacity == 0 {
		return false
	}
	log^ = Bridge_Act_Log {
		initialized = true,
		capacity    = capacity,
		head_hash   = wide_grants.GENESIS_PREVIOUS_HASH,
		records     = make([dynamic]wide_grants.Act_Record, 0, min(capacity, 64), allocator),
	}
	return true
}

// bridge_act_log_destroy frees the host slice backing the act log.
bridge_act_log_destroy :: proc(log: ^Bridge_Act_Log) {
	if log == nil {
		return
	}
	delete(log.records)
	log^ = {}
}

// bridge_act_log_has_room reports whether at least one act record can still
// be appended without hitting capacity.
bridge_act_log_has_room :: proc(log: ^Bridge_Act_Log) -> bool {
	if log == nil || !log.initialized {
		return false
	}
	return u32(len(log.records)) < log.capacity
}

// bridge_act_log_append seals and appends one hash-chained Act_Record before
// an input act is delivered. Fails closed when full or on backward timestamps.
bridge_act_log_append :: proc(
	log: ^Bridge_Act_Log,
	grant_serial: u64,
	timestamp_ms: u64,
	act_kind: wide_grants.Act_Kind,
	target_window_id: u64,
	detail_word_0: u64,
	detail_word_1: u64,
) -> (record: wide_grants.Act_Record, refusal: wide_grants.Wide_Grant_Refusal) {
	if log == nil || !log.initialized {
		return {}, .Act_Log_Full
	}
	if u32(len(log.records)) >= log.capacity {
		return {}, .Act_Log_Full
	}
	if len(log.records) > 0 && timestamp_ms < log.last_timestamp_ms {
		return {}, .Chain_Tampered
	}
	candidate := wide_grants.Act_Record {
		sequence_number  = log.next_sequence,
		grant_serial     = grant_serial,
		timestamp_ms     = timestamp_ms,
		act_kind_word    = u64(act_kind),
		target_window_id = target_window_id,
		detail_word_0    = detail_word_0,
		detail_word_1    = detail_word_1,
		previous_hash    = log.head_hash,
	}
	if seal_refusal := wide_grants.act_record_seal(&candidate); seal_refusal != .None {
		return {}, seal_refusal
	}
	append(&log.records, candidate)
	log.next_sequence += 1
	log.last_timestamp_ms = timestamp_ms
	log.head_hash = candidate.record_hash
	return candidate, .None
}

// bridge_act_log_verify verifies the entire append-only act chain against the
// recorded count and head digest.
bridge_act_log_verify :: proc(log: ^Bridge_Act_Log) -> (refusal: wide_grants.Wide_Grant_Refusal, failing_index: u64) {
	if log == nil || !log.initialized {
		return .Chain_Tampered, 0
	}
	return wide_grants.act_chain_verify_with_head(log.records[:], u64(len(log.records)), log.head_hash)
}

// bridge_init initializes an Agent_Bridge with a client policy, transport,
// and bounded collector act log.
bridge_init :: proc(
	bridge: ^Agent_Bridge,
	policy: contract.Bridge_Client_Policy,
	transport: Machine_Transport,
	act_capacity: u32 = DEFAULT_BRIDGE_ACT_CAPACITY,
	allocator := context.allocator,
) -> bool {
	if bridge == nil {
		return false
	}
	bridge^ = Agent_Bridge {
		policy          = policy,
		transport       = transport,
		next_request_id = 1,
	}
	return bridge_act_log_init(&bridge.act_log, act_capacity, allocator)
}

// bridge_destroy releases resources owned by bridge.
bridge_destroy :: proc(bridge: ^Agent_Bridge) {
	if bridge == nil {
		return
	}
	bridge_act_log_destroy(&bridge.act_log)
}

// snapshot_directory_check gives the absolute path of the folder that the
// operator named for the snapshots, or a problem: the path must name an
// existing folder, and not a symbolic link, which can move the files of the
// bridge to another place after the check.
snapshot_directory_check :: proc(path: string, allocator := context.allocator) -> (absolute: string, problem: string) {
	if path == "" || strings.contains_rune(path, 0) {
		return "", "the snapshot folder has no valid path"
	}
	// The absolute path resolves the links, so the path as given is checked first.
	given_info, given_error := os.lstat(path, context.temp_allocator)
	if given_error != nil {
		return "", fmt.tprintf("the snapshot folder %s does not exist", path)
	}
	if given_info.type != .Directory {
		return "", fmt.tprintf("the snapshot folder %s is not a folder; a symbolic link is refused", path)
	}
	resolved, absolute_error := os.get_absolute_path(path, allocator)
	if absolute_error != nil {
		return "", fmt.tprintf("cannot resolve the snapshot folder %s", path)
	}
	info, stat_error := os.lstat(resolved, context.temp_allocator)
	if stat_error != nil {
		delete(resolved, allocator)
		return "", fmt.tprintf("the snapshot folder %s does not exist", path)
	}
	if info.type != .Directory {
		delete(resolved, allocator)
		return "", fmt.tprintf("the snapshot folder %s is not a folder; a symbolic link is refused", path)
	}
	return resolved, ""
}

// bridge_write_snapshot writes the bytes of a snapshot to a new file
// snapshot_<sequence>.<format> of the snapshot folder and gives its path.
// The name comes from the bridge only. The file is created new: an existing
// file or a symbolic link at the name is refused, never followed or
// overwritten. The folder is checked again at each write.
bridge_write_snapshot :: proc(bridge: ^Agent_Bridge, snap: Screen_Snapshot_Result) -> (path: string, problem: string) {
	if bridge.snapshot_directory == "" {
		return "", "no snapshot folder"
	}
	info, stat_error := os.lstat(bridge.snapshot_directory, context.temp_allocator)
	if stat_error != nil || info.type != .Directory {
		return "", "the snapshot folder is no longer a folder"
	}
	extension := ""
	switch snap.format {
	case .None:
		return "", "the snapshot has no format"
	case .Png:
		extension = "png"
	case .Raw_Bgrx:
		extension = "bgrx"
	}
	bridge.next_snapshot_sequence += 1
	name := fmt.tprintf("snapshot_%d.%s", bridge.next_snapshot_sequence, extension)
	joined, join_error := os.join_path({bridge.snapshot_directory, name}, context.temp_allocator)
	if join_error != nil {
		return "", "cannot name the snapshot file"
	}
	file, open_error := os.open(joined, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if open_error != nil {
		return "", fmt.tprintf("cannot create the snapshot file %s", name)
	}
	defer os.close(file)
	written, write_error := os.write(file, snap.bytes)
	if write_error != nil || written != len(snap.bytes) {
		return "", fmt.tprintf("cannot write the snapshot file %s", name)
	}
	return joined, ""
}

@(private = "file")
bridge_now_ms :: proc(bridge: ^Agent_Bridge) -> u64 {
	if bridge.clock_ms_proc != nil {
		return bridge.clock_ms_proc(bridge.clock_user_data)
	}
	now_ns := time.time_to_unix_nano(time.now())
	if now_ns < 0 {
		return 0
	}
	return u64(now_ns) / 1_000_000
}

@(private = "file")
hex_encode_bytes :: proc(data: []u8, allocator := context.temp_allocator) -> string {
	encoded := hex.encode(data, allocator)
	return string(encoded)
}

@(private = "file")
bridge_method_from_string :: proc(name: string) -> Bridge_Json_Method {
	switch name {
	case "eval_lex":
		return .Eval_Lex
	case "read_screen":
		return .Read_Screen
	case "send_key":
		return .Send_Key
	case "send_pointer":
		return .Send_Pointer
	case "read_log_facts":
		return .Read_Log_Facts
	case "wire_command":
		return .Wire_Command
	case "ask_wide_grant":
		return .Ask_Wide_Grant
	}
	return .None
}

// JSON formatting helpers.

@(private = "file")
json_write_escaped_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index in 0 ..< len(text) {
		ch := text[index]
		switch ch {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\b':
			strings.write_string(builder, `\b`)
		case '\f':
			strings.write_string(builder, `\f`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\r':
			strings.write_string(builder, `\r`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(builder, `\u%04x`, ch)
			} else {
				strings.write_byte(builder, ch)
			}
		}
	}
	strings.write_byte(builder, '"')
}

@(private = "file")
json_write_id :: proc(builder: ^strings.Builder, id_value: json.Value, has_id: bool) {
	if !has_id {
		strings.write_string(builder, "null")
		return
	}
	switch v in id_value {
	case json.Integer:
		fmt.sbprintf(builder, "%d", v)
	case json.String:
		json_write_escaped_string(builder, v)
	case json.Null, json.Float, json.Boolean, json.Array, json.Object:
		strings.write_string(builder, "null")
	}
}

@(private = "file")
json_error_response :: proc(
	id_value: json.Value,
	has_id: bool,
	code: Json_Rpc_Error_Code,
	status: contract.Bridge_Status,
	refusal: contract.Bridge_Refusal,
	message: string,
	allocator := context.temp_allocator,
) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"error":{"code":`)
	fmt.sbprintf(&builder, "%d", i64(code))
	strings.write_string(&builder, `,"status":`)
	json_write_escaped_string(&builder, contract.bridge_status_name(status))
	strings.write_string(&builder, `,"refusal":`)
	json_write_escaped_string(&builder, contract.bridge_refusal_name(refusal))
	strings.write_string(&builder, `,"message":`)
	json_write_escaped_string(&builder, message)
	strings.write_string(&builder, `}}`)
	return strings.to_string(builder)
}

@(private = "file")
json_decision_error :: proc(
	id_value: json.Value,
	has_id: bool,
	decision: contract.Bridge_Authorization_Decision,
	allocator := context.temp_allocator,
) -> string {
	if decision.status == .Awaiting_Principal_Approval {
		return json_error_response(
			id_value,
			has_id,
			.Awaiting_Principal_Approval,
			.Awaiting_Principal_Approval,
			decision.refusal,
			"operation requires explicit principal approval and cannot self-approve through the agent bridge",
			allocator,
		)
	}
	return json_error_response(
		id_value,
		has_id,
		.Refused,
		decision.status,
		decision.refusal,
		fmt.tprintf("agent bridge refused command: %s", contract.bridge_refusal_name(decision.refusal)),
		allocator,
	)
}

// Strict JSON field extractors.

@(private = "file")
json_get_string :: proc(obj: json.Object, key: string) -> (value: string, present: bool, valid: bool) {
	raw, found := obj[key]
	if !found {
		return "", false, true
	}
	text, is_str := raw.(json.String)
	if !is_str {
		return "", true, false
	}
	return text, true, true
}

@(private = "file")
json_get_bool :: proc(obj: json.Object, key: string) -> (value: bool, present: bool, valid: bool) {
	raw, found := obj[key]
	if !found {
		return false, false, true
	}
	flag, is_bool := raw.(json.Boolean)
	if !is_bool {
		return false, true, false
	}
	return flag, true, true
}

@(private = "file")
json_get_i64 :: proc(obj: json.Object, key: string) -> (value: i64, present: bool, valid: bool) {
	raw, found := obj[key]
	if !found {
		return 0, false, true
	}
	int_val, is_int := raw.(json.Integer)
	if !is_int {
		return 0, true, false
	}
	return int_val, true, true
}

@(private = "file")
json_get_u64 :: proc(obj: json.Object, key: string) -> (value: u64, present: bool, valid: bool) {
	signed, found, ok := json_get_i64(obj, key)
	if !ok || !found {
		return 0, found, ok
	}
	if signed < 0 {
		return 0, true, false
	}
	return u64(signed), true, true
}

@(private = "file")
json_get_u32 :: proc(obj: json.Object, key: string) -> (value: u32, present: bool, valid: bool) {
	unsigned, found, ok := json_get_u64(obj, key)
	if !ok || !found {
		return 0, found, ok
	}
	if unsigned > u64(max(u32)) {
		return 0, true, false
	}
	return u32(unsigned), true, true
}

// bridge_handle_wire_frame decodes one binary "MODAB1" command frame,
// enforces all authorization and audit gates, invokes the transport, and
// encodes a canonical "MODAB1" response frame into response_buffer.
bridge_handle_wire_frame :: proc(
	bridge: ^Agent_Bridge,
	raw_frame: []u8,
	response_buffer: []u8,
) -> (written: int, status: contract.Bridge_Status, refusal: contract.Bridge_Refusal) {
	encode_result :: proc(
		request_id: u64,
		res_status: contract.Bridge_Status,
		res_refusal: contract.Bridge_Refusal,
		act_seq: u64,
		act_hash: blake3.Hash,
		payload: []u8,
		out_buf: []u8,
	) -> (int, contract.Bridge_Status, contract.Bridge_Refusal) {
		resp := contract.Bridge_Response_Frame {
			status              = res_status,
			refusal             = res_refusal,
			request_id          = request_id == 0 ? 1 : request_id,
			act_sequence_number = act_seq,
			act_record_hash     = act_hash,
			payload             = payload,
		}
		n, enc_refusal := contract.encode_response_frame(&resp, out_buf)
		if enc_refusal != .None {
			return 0, .Refused, enc_refusal
		}
		return n, res_status, res_refusal
	}

	if bridge == nil {
		return encode_result(1, .Refused, .Invalid_Field, 0, {}, nil, response_buffer)
	}
	cmd_frame, decode_refusal := contract.decode_command_frame(raw_frame)
	if decode_refusal != .None {
		return encode_result(1, .Refused, decode_refusal, 0, {}, nil, response_buffer)
	}

	// Verify the frame's client key hash matches the bridge's policy key.
	policy_key := bridge.policy.client_key_public
	expected_key_hash := blake3.hash(policy_key[:])
	if cmd_frame.client_key_hash != expected_key_hash || cmd_frame.principal_id != bridge.policy.principal_id {
		return encode_result(cmd_frame.request_id, .Refused, .Permission_Denied, 0, {}, nil, response_buffer)
	}

	now_ms := bridge_now_ms(bridge)
	bridge.policy.collector_available = bridge_act_log_has_room(&bridge.act_log)

	switch cmd_frame.command {
	case .None:
		return encode_result(cmd_frame.request_id, .Refused, .Unknown_Command, 0, {}, nil, response_buffer)

	case .Eval_Lex:
		auth_req := contract.Bridge_Authorization_Request {
			command  = .Eval_Lex,
			now_ms   = now_ms,
			lex_line = cmd_frame.payload,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return encode_result(cmd_frame.request_id, decision.status, decision.refusal, 0, {}, nil, response_buffer)
		}
		if bridge.transport.eval_lex == nil {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		res, _, ok := bridge.transport.eval_lex(bridge.transport.user_data, string(cmd_frame.payload), context.temp_allocator)
		if !ok {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		summary := fmt.tprintf("%s:%s", contract.lex_value_kind_name(res.value_kind), res.text_value)
		return encode_result(cmd_frame.request_id, .Ok, .None, 0, {}, transmute([]u8)summary, response_buffer)

	case .Read_Screen:
		screen_req, screen_refusal := contract.decode_read_screen_payload(cmd_frame.payload)
		if screen_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, screen_refusal, 0, {}, nil, response_buffer)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command = .Read_Screen,
			now_ms  = now_ms,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return encode_result(cmd_frame.request_id, decision.status, decision.refusal, 0, {}, nil, response_buffer)
		}
		if bridge.transport.read_screen == nil {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		snap, _, ok := bridge.transport.read_screen(
			bridge.transport.user_data,
			Screen_Snapshot_Request {
				format          = screen_req.format,
				max_width       = screen_req.max_width,
				max_height      = screen_req.max_height,
				wait_settled_ms = screen_req.wait_settled_ms,
			},
			context.temp_allocator,
		)
		if !ok {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		return encode_result(cmd_frame.request_id, .Ok, .None, 0, {}, snap.bytes, response_buffer)

	case .Send_Key:
		key_payload, key_refusal := contract.decode_send_key_payload(cmd_frame.payload)
		if key_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, key_refusal, 0, {}, nil, response_buffer)
		}
		if cmd_frame.grant_serial != bridge.policy.wide_grant_serial {
			return encode_result(cmd_frame.request_id, .Refused, .Wide_Grant_Not_Active, 0, {}, nil, response_buffer)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command          = .Send_Key,
			now_ms           = now_ms,
			target_window_id = cmd_frame.target_window_id,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return encode_result(cmd_frame.request_id, decision.status, decision.refusal, 0, {}, nil, response_buffer)
		}
		act_rec, act_refusal := bridge_act_log_append(
			&bridge.act_log,
			bridge.policy.wide_grant_serial,
			now_ms,
			decision.required_act_kind,
			cmd_frame.target_window_id,
			u64(key_payload.key.code),
			u64(key_payload.key.character),
		)
		if act_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, .Act_Log_Required, 0, {}, nil, response_buffer)
		}
		if bridge.transport.send_key == nil {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)
		}
		if _, ok := bridge.transport.send_key(bridge.transport.user_data, cmd_frame.target_window_id, key_payload.key); !ok {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)
		}
		return encode_result(cmd_frame.request_id, .Ok, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)

	case .Send_Pointer:
		ptr_payload, ptr_refusal := contract.decode_send_pointer_payload(cmd_frame.payload)
		if ptr_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, ptr_refusal, 0, {}, nil, response_buffer)
		}
		if cmd_frame.grant_serial != bridge.policy.wide_grant_serial {
			return encode_result(cmd_frame.request_id, .Refused, .Wide_Grant_Not_Active, 0, {}, nil, response_buffer)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command           = .Send_Pointer,
			now_ms            = now_ms,
			target_window_id  = cmd_frame.target_window_id,
			pointer_has_click = ptr_payload.pointer.buttons != 0,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return encode_result(cmd_frame.request_id, decision.status, decision.refusal, 0, {}, nil, response_buffer)
		}
		act_rec, act_refusal := bridge_act_log_append(
			&bridge.act_log,
			bridge.policy.wide_grant_serial,
			now_ms,
			decision.required_act_kind,
			cmd_frame.target_window_id,
			(u64(ptr_payload.pointer.x) << 32) | u64(ptr_payload.pointer.y),
			u64(ptr_payload.pointer.buttons),
		)
		if act_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, .Act_Log_Required, 0, {}, nil, response_buffer)
		}
		if bridge.transport.send_pointer == nil {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)
		}
		if _, ok := bridge.transport.send_pointer(bridge.transport.user_data, cmd_frame.target_window_id, ptr_payload.pointer); !ok {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)
		}
		return encode_result(cmd_frame.request_id, .Ok, .None, act_rec.sequence_number, act_rec.record_hash, nil, response_buffer)

	case .Read_Log_Facts:
		facts_payload, facts_refusal := contract.decode_read_log_facts_payload(cmd_frame.payload)
		if facts_refusal != .None {
			return encode_result(cmd_frame.request_id, .Refused, facts_refusal, 0, {}, nil, response_buffer)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command = .Read_Log_Facts,
			now_ms  = now_ms,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return encode_result(cmd_frame.request_id, decision.status, decision.refusal, 0, {}, nil, response_buffer)
		}
		if bridge.transport.read_log_facts == nil {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		query := Log_Facts_Query {
			module_filter    = string(facts_payload.module_filter_bytes[:facts_payload.module_filter_length]),
			fact_name_filter = string(facts_payload.fact_name_filter_bytes[:facts_payload.fact_name_filter_length]),
			sequence_start   = facts_payload.sequence_start,
			sequence_end     = facts_payload.sequence_end,
			max_records      = facts_payload.max_records,
		}
		facts, _, ok := bridge.transport.read_log_facts(bridge.transport.user_data, query, context.temp_allocator)
		if !ok {
			return encode_result(cmd_frame.request_id, .Transport_Error, .None, 0, {}, nil, response_buffer)
		}
		count_text := fmt.tprintf("%d", len(facts))
		return encode_result(cmd_frame.request_id, .Ok, .None, 0, {}, transmute([]u8)count_text, response_buffer)
	}

	return encode_result(cmd_frame.request_id, .Refused, .Unknown_Command, 0, {}, nil, response_buffer)
}

// bridge_handle_json_line parses one JSON-RPC 2.0 request line, enforces all
// contract authorization and safety gates, executes through bridge.transport,
// and returns one JSON-RPC 2.0 response line.
bridge_handle_json_line :: proc(
	bridge: ^Agent_Bridge,
	line: string,
	allocator := context.temp_allocator,
) -> string {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 {
		return json_error_response(nil, false, .Parse_Error, .Refused, .Bad_Header, "empty request line", allocator)
	}
	parsed, parse_err := json.parse_string(trimmed, .JSON, true, context.temp_allocator)
	if parse_err != .None {
		return json_error_response(nil, false, .Parse_Error, .Refused, .Bad_Header, "malformed JSON request", allocator)
	}
	root, is_object := parsed.(json.Object)
	if !is_object {
		return json_error_response(nil, false, .Invalid_Request, .Refused, .Bad_Header, "JSON-RPC request must be an object", allocator)
	}

	id_value, has_id := root["id"]
	if has_id {
		_, is_int := id_value.(json.Integer)
		_, is_str := id_value.(json.String)
		_, is_null := id_value.(json.Null)
		if !is_int && !is_str && !is_null {
			return json_error_response(nil, false, .Invalid_Request, .Refused, .Invalid_Field, "id must be an integer, string, or null", allocator)
		}
	}

	version_text, has_version, version_ok := json_get_string(root, "jsonrpc")
	if !version_ok || !has_version || version_text != "2.0" {
		return json_error_response(id_value, has_id, .Invalid_Request, .Refused, .Bad_Header, `jsonrpc must be "2.0"`, allocator)
	}

	method_name, has_method, method_ok := json_get_string(root, "method")
	if !method_ok || !has_method {
		return json_error_response(id_value, has_id, .Invalid_Request, .Refused, .Unknown_Command, "method must be a string", allocator)
	}

	method := bridge_method_from_string(method_name)
	if method == .None {
		return json_error_response(id_value, has_id, .Method_Not_Found, .Refused, .Unknown_Command, fmt.tprintf("unknown bridge method: %s", method_name), allocator)
	}

	params: json.Object
	if raw_params, has_params := root["params"]; has_params {
		obj, is_obj := raw_params.(json.Object)
		if !is_obj {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "params must be a JSON object", allocator)
		}
		params = obj
	}

	if bridge == nil {
		return json_error_response(id_value, has_id, .Refused, .Refused, .Invalid_Field, "bridge is not initialized", allocator)
	}

	now_ms := bridge_now_ms(bridge)
	bridge.policy.collector_available = bridge_act_log_has_room(&bridge.act_log)

	switch method {
	case .None:
		return json_error_response(id_value, has_id, .Method_Not_Found, .Refused, .Unknown_Command, "unknown method", allocator)

	case .Eval_Lex:
		lex_line, has_line, line_ok := json_get_string(params, "line")
		if !line_ok || !has_line {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "eval_lex requires string parameter line", allocator)
		}
		// The bridge classifies the line itself: no field of the request
		// that says the call is safe is read.
		auth_req := contract.Bridge_Authorization_Request {
			command  = .Eval_Lex,
			now_ms   = now_ms,
			lex_line = transmute([]u8)lex_line,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return json_decision_error(id_value, has_id, decision, allocator)
		}
		if bridge.transport.eval_lex == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "eval_lex transport is not configured", allocator)
		}
		res, err_text, ok := bridge.transport.eval_lex(bridge.transport.user_data, lex_line, context.temp_allocator)
		if !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote eval_lex failed", allocator)
		}
		return format_eval_lex_json(id_value, has_id, res, allocator)

	case .Read_Screen:
		format_name, has_format, format_ok := json_get_string(params, "format")
		if !format_ok {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "format must be a string", allocator)
		}
		picture_format := contract.Screen_Picture_Format.Png
		if has_format {
			switch format_name {
			case "png":
				picture_format = .Png
			case "raw_bgrx":
				picture_format = .Raw_Bgrx
			case:
				return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "format must be png or raw_bgrx", allocator)
			}
		}
		max_width, _, mw_ok := json_get_u32(params, "max_width")
		max_height, _, mh_ok := json_get_u32(params, "max_height")
		wait_settled_ms, _, ws_ok := json_get_u32(params, "wait_settled_ms")
		if !mw_ok || !mh_ok || !ws_ok {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "invalid read_screen parameter type", allocator)
		}
		payload := contract.Read_Screen_Payload {
			format          = picture_format,
			max_width       = max_width,
			max_height      = max_height,
			wait_settled_ms = wait_settled_ms,
		}
		if check := contract.validate_read_screen_payload(&payload); check != .None {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, check, "read_screen parameters out of bounds", allocator)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command = .Read_Screen,
			now_ms  = now_ms,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return json_decision_error(id_value, has_id, decision, allocator)
		}
		if bridge.transport.read_screen == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "read_screen transport is not configured", allocator)
		}
		snap, err_text, ok := bridge.transport.read_screen(
			bridge.transport.user_data,
			Screen_Snapshot_Request {
				format          = payload.format,
				max_width       = payload.max_width,
				max_height      = payload.max_height,
				wait_settled_ms = payload.wait_settled_ms,
			},
			context.temp_allocator,
		)
		if !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote read_screen failed", allocator)
		}
		// The snapshot goes to a file only in the folder of the operator, under
		// a name of the bridge: a request names no path.
		saved_path := ""
		if bridge.snapshot_directory != "" {
			path, problem := bridge_write_snapshot(bridge, snap)
			if problem != "" {
				return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, problem, allocator)
			}
			saved_path = path
		}
		return format_read_screen_json(id_value, has_id, snap, saved_path, allocator)

	case .Send_Key:
		window_id, has_window, win_ok := json_get_u64(params, "window_id")
		code, has_code, code_ok := json_get_u32(params, "code")
		character, _, char_ok := json_get_u32(params, "character")
		pressed, has_pressed, pressed_ok := json_get_bool(params, "pressed")
		modifiers, _, mod_ok := json_get_u32(params, "modifiers")
		if !win_ok || !has_window || !code_ok || !has_code || !char_ok || !pressed_ok || !has_pressed || !mod_ok {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "send_key requires integer window_id, integer code, and boolean pressed", allocator)
		}
		key_payload := contract.Send_Key_Payload {
			key = remote_display.Key_Body {
				code      = code,
				character = character,
				pressed   = pressed ? 1 : 0,
				modifiers = modifiers,
			},
		}
		if check := contract.validate_send_key_payload(&key_payload); check != .None {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, check, "send_key fields out of bounds", allocator)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command          = .Send_Key,
			now_ms           = now_ms,
			target_window_id = window_id,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return json_decision_error(id_value, has_id, decision, allocator)
		}
		act_rec, act_refusal := bridge_act_log_append(
			&bridge.act_log,
			bridge.policy.wide_grant_serial,
			now_ms,
			decision.required_act_kind,
			window_id,
			u64(key_payload.key.code),
			u64(key_payload.key.character),
		)
		if act_refusal != .None {
			return json_error_response(id_value, has_id, .Refused, .Refused, .Act_Log_Required, "collector act log refused input record", allocator)
		}
		if bridge.transport.send_key == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "send_key transport is not configured", allocator)
		}
		if err_text, ok := bridge.transport.send_key(bridge.transport.user_data, window_id, key_payload.key); !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote send_key failed", allocator)
		}
		return format_input_delivered_json(id_value, has_id, window_id, act_rec, allocator)

	case .Send_Pointer:
		window_id, has_window, win_ok := json_get_u64(params, "window_id")
		x, has_x, x_ok := json_get_u32(params, "x")
		y, has_y, y_ok := json_get_u32(params, "y")
		buttons, _, btn_ok := json_get_u32(params, "buttons")
		wheel_i64, _, wheel_ok := json_get_i64(params, "wheel")
		if !win_ok || !has_window || !x_ok || !has_x || !y_ok || !has_y || !btn_ok || !wheel_ok || wheel_i64 < i64(min(i32)) || wheel_i64 > i64(max(i32)) {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "send_pointer requires integer window_id, x, and y", allocator)
		}
		ptr_payload := contract.Send_Pointer_Payload {
			pointer = remote_display.Pointer_Body {
				x       = x,
				y       = y,
				buttons = buttons,
				wheel   = i32(wheel_i64),
			},
		}
		if check := contract.validate_send_pointer_payload(&ptr_payload); check != .None {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, check, "send_pointer fields out of bounds", allocator)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command           = .Send_Pointer,
			now_ms            = now_ms,
			target_window_id  = window_id,
			pointer_has_click = buttons != 0,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return json_decision_error(id_value, has_id, decision, allocator)
		}
		act_rec, act_refusal := bridge_act_log_append(
			&bridge.act_log,
			bridge.policy.wide_grant_serial,
			now_ms,
			decision.required_act_kind,
			window_id,
			(u64(x) << 32) | u64(y),
			u64(buttons),
		)
		if act_refusal != .None {
			return json_error_response(id_value, has_id, .Refused, .Refused, .Act_Log_Required, "collector act log refused input record", allocator)
		}
		if bridge.transport.send_pointer == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "send_pointer transport is not configured", allocator)
		}
		if err_text, ok := bridge.transport.send_pointer(bridge.transport.user_data, window_id, ptr_payload.pointer); !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote send_pointer failed", allocator)
		}
		return format_input_delivered_json(id_value, has_id, window_id, act_rec, allocator)

	case .Read_Log_Facts:
		module_filter, _, mod_ok := json_get_string(params, "module")
		fact_name_filter, _, fact_ok := json_get_string(params, "fact_name")
		sequence_start, _, start_ok := json_get_u64(params, "sequence_start")
		sequence_end, _, end_ok := json_get_u64(params, "sequence_end")
		max_records, has_max, max_ok := json_get_u32(params, "max_records")
		if !mod_ok || !fact_ok || !start_ok || !end_ok || !max_ok {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "invalid read_log_facts parameter type", allocator)
		}
		if !has_max {
			max_records = 64
		}
		if len(module_filter) > contract.MAX_FILTER_NAME_BYTES || len(fact_name_filter) > contract.MAX_FILTER_NAME_BYTES {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Text, "filter name exceeds bound", allocator)
		}
		payload := contract.Read_Log_Facts_Payload {
			module_filter_length    = u8(len(module_filter)),
			fact_name_filter_length = u8(len(fact_name_filter)),
			sequence_start          = sequence_start,
			sequence_end            = sequence_end,
			max_records             = max_records,
		}
		copy(payload.module_filter_bytes[:len(module_filter)], module_filter)
		copy(payload.fact_name_filter_bytes[:len(fact_name_filter)], fact_name_filter)
		if check := contract.validate_read_log_facts_payload(&payload); check != .None {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, check, "read_log_facts parameters invalid", allocator)
		}
		auth_req := contract.Bridge_Authorization_Request {
			command = .Read_Log_Facts,
			now_ms  = now_ms,
		}
		decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
		if decision.status != .Ok {
			return json_decision_error(id_value, has_id, decision, allocator)
		}
		if bridge.transport.read_log_facts == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "read_log_facts transport is not configured", allocator)
		}
		query := Log_Facts_Query {
			module_filter    = module_filter,
			fact_name_filter = fact_name_filter,
			sequence_start   = sequence_start,
			sequence_end     = sequence_end,
			max_records      = max_records,
		}
		facts, err_text, ok := bridge.transport.read_log_facts(bridge.transport.user_data, query, context.temp_allocator)
		if !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote read_log_facts failed", allocator)
		}
		return format_log_facts_json(id_value, has_id, facts, allocator)

	case .Ask_Wide_Grant:
		// The ask needs no permission of the bridge: it gives nothing. The
		// principal answers the screen on the machine, and the root service
		// takes the key from the handshake, never from this request
		// (src/md/features/wide_grants.md, "The ask of an agent").
		scopes_text, has_scopes, scopes_ok := json_get_string(params, "scopes")
		minutes, has_minutes, minutes_ok := json_get_u64(params, "minutes")
		if !scopes_ok || !has_scopes || !minutes_ok || !has_minutes {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "ask_wide_grant requires string parameter scopes and integer parameter minutes", allocator)
		}
		authorities: wide_grants.Wide_Authorities
		switch scopes_text {
		case "view":
			authorities = {.View_Screen}
		case "view_and_input":
			authorities = {.View_Screen, .Send_Input}
		case:
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, "scopes must be view or view_and_input", allocator)
		}
		most := wide_grants.MAX_WIDE_GRANT_DURATION_MS / 60_000
		if minutes < 1 || minutes > most {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Invalid_Field, fmt.tprintf("minutes must be 1 to %d", most), allocator)
		}
		if bridge.transport.ask_wide_grant == nil {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, "ask_wide_grant transport is not configured", allocator)
		}
		screen, err_text, ok := bridge.transport.ask_wide_grant(bridge.transport.user_data, authorities, minutes * 60_000)
		if !ok {
			return json_error_response(id_value, has_id, .Transport_Error, .Transport_Error, .None, err_text != "" ? err_text : "remote ask_wide_grant failed", allocator)
		}
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
		json_write_id(&builder, id_value, has_id)
		strings.write_string(&builder, `,"result":{"status":"Ok","screen":`)
		fmt.sbprintf(&builder, "%d", screen)
		strings.write_string(&builder, `}}`)
		return strings.to_string(builder)

	case .Wire_Command:
		frame_hex, has_hex, hex_ok := json_get_string(params, "frame_hex")
		if !hex_ok || !has_hex {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Bad_Header, "wire_command requires string parameter frame_hex", allocator)
		}
		raw_bytes, decoded_ok := hex.decode(transmute([]u8)frame_hex, context.temp_allocator)
		if !decoded_ok {
			return json_error_response(id_value, has_id, .Invalid_Params, .Refused, .Bad_Header, "frame_hex is not valid hexadecimal", allocator)
		}
		resp_buf := make([]u8, contract.RESPONSE_HEADER_SIZE + contract.MAX_BRIDGE_PAYLOAD_BYTES, context.temp_allocator)
		written, status, refusal := bridge_handle_wire_frame(bridge, raw_bytes, resp_buf)
		if status == .Awaiting_Principal_Approval {
			return json_error_response(id_value, has_id, .Awaiting_Principal_Approval, status, refusal, "wire command requires explicit principal approval", allocator)
		}
		if status != .Ok {
			code := status == .Transport_Error ? Json_Rpc_Error_Code.Transport_Error : Json_Rpc_Error_Code.Refused
			return json_error_response(id_value, has_id, code, status, refusal, fmt.tprintf("wire command failed: %s", contract.bridge_refusal_name(refusal)), allocator)
		}
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
		json_write_id(&builder, id_value, has_id)
		strings.write_string(&builder, `,"result":{"status":"Ok","response_frame_hex":`)
		json_write_escaped_string(&builder, hex_encode_bytes(resp_buf[:written], context.temp_allocator))
		strings.write_string(&builder, `}}`)
		return strings.to_string(builder)
	}

	return json_error_response(id_value, has_id, .Method_Not_Found, .Refused, .Unknown_Command, "unknown bridge method", allocator)
}

@(private = "file")
format_eval_lex_json :: proc(
	id_value: json.Value,
	has_id: bool,
	res: Lex_Eval_Result,
	allocator := context.temp_allocator,
) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"result":{"status":"Ok","value_kind":`)
	json_write_escaped_string(&builder, contract.lex_value_kind_name(res.value_kind))
	switch res.value_kind {
	case .None:
	case .Integer:
		fmt.sbprintf(&builder, `,"value":%d`, res.integer_value)
	case .Boolean:
		fmt.sbprintf(&builder, `,"value":%s`, res.bool_value ? "true" : "false")
	case .Text, .Enum_Member:
		strings.write_string(&builder, `,"value":`)
		json_write_escaped_string(&builder, res.text_value)
	case .Table, .Record:
		strings.write_string(&builder, `,"record_name":`)
		json_write_escaped_string(&builder, res.record_name)
		strings.write_string(&builder, `,"columns":[`)
		for col, idx in res.columns {
			if idx > 0 {
				strings.write_byte(&builder, ',')
			}
			json_write_escaped_string(&builder, col)
		}
		// The kind and the unit of each column, and the value of each cell
		// of a number column: a reader aligns and formats a number as the
		// console does, and never reads it back from its text.
		strings.write_string(&builder, `],"column_kinds":[`)
		for _, idx in res.columns {
			if idx > 0 {
				strings.write_byte(&builder, ',')
			}
			kind := idx < len(res.column_kinds) ? res.column_kinds[idx] : contract.Lex_Column_Kind.Text
			json_write_escaped_string(&builder, contract.lex_column_kind_name(kind))
		}
		strings.write_string(&builder, `],"column_units":[`)
		for _, idx in res.columns {
			if idx > 0 {
				strings.write_byte(&builder, ',')
			}
			strings.write_i64(&builder, idx < len(res.column_units) ? res.column_units[idx] : 0)
		}
		strings.write_string(&builder, `],"row_integers":[`)
		for row, r_idx in res.rows {
			if r_idx > 0 {
				strings.write_byte(&builder, ',')
			}
			strings.write_byte(&builder, '[')
			for _, c_idx in row {
				if c_idx > 0 {
					strings.write_byte(&builder, ',')
				}
				value: i64
				if r_idx < len(res.row_integers) && c_idx < len(res.row_integers[r_idx]) {
					value = res.row_integers[r_idx][c_idx]
				}
				strings.write_i64(&builder, value)
			}
			strings.write_byte(&builder, ']')
		}
		strings.write_string(&builder, `],"rows":[`)
		for row, r_idx in res.rows {
			if r_idx > 0 {
				strings.write_byte(&builder, ',')
			}
			strings.write_byte(&builder, '[')
			for cell, c_idx in row {
				if c_idx > 0 {
					strings.write_byte(&builder, ',')
				}
				json_write_escaped_string(&builder, cell)
			}
			strings.write_byte(&builder, ']')
		}
		fmt.sbprintf(&builder, `],"total_rows":%d`, res.total_rows)
	}
	strings.write_string(&builder, `}}`)
	return strings.to_string(builder)
}

@(private = "file")
format_read_screen_json :: proc(
	id_value: json.Value,
	has_id: bool,
	snap: Screen_Snapshot_Result,
	saved_path: string,
	allocator := context.temp_allocator,
) -> string {
	digest := snap.content_hash
	if digest == (blake3.Hash{}) && len(snap.bytes) > 0 {
		digest = blake3.hash(snap.bytes)
	}
	encoded_b64 := base64.encode(snap.bytes, allocator = context.temp_allocator)

	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"result":{"status":"Ok","format":`)
	json_write_escaped_string(&builder, contract.screen_picture_format_name(snap.format))
	fmt.sbprintf(&builder, `,"width":%d,"height":%d,"frame_serial":%d,"byte_count":%d,"blake3":`, snap.width, snap.height, snap.frame_serial, len(snap.bytes))
	json_write_escaped_string(&builder, hex_encode_bytes(digest[:], context.temp_allocator))
	strings.write_string(&builder, `,"data_base64":`)
	json_write_escaped_string(&builder, encoded_b64)
	if len(saved_path) > 0 {
		strings.write_string(&builder, `,"saved_path":`)
		json_write_escaped_string(&builder, saved_path)
	}
	strings.write_string(&builder, `}}`)
	return strings.to_string(builder)
}

@(private = "file")
format_input_delivered_json :: proc(
	id_value: json.Value,
	has_id: bool,
	window_id: u64,
	act_record: wide_grants.Act_Record,
	allocator := context.temp_allocator,
) -> string {
	record_hash := act_record.record_hash
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"result":{"status":"Ok","delivered":true,"window_id":`)
	fmt.sbprintf(&builder, `%d,"act_sequence":%d,"act_record_hash":`, window_id, act_record.sequence_number)
	json_write_escaped_string(&builder, hex_encode_bytes(record_hash[:], context.temp_allocator))
	strings.write_string(&builder, `}}`)
	return strings.to_string(builder)
}

@(private = "file")
format_log_facts_json :: proc(
	id_value: json.Value,
	has_id: bool,
	facts: []Structured_Log_Fact,
	allocator := context.temp_allocator,
) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"result":{"status":"Ok","count":`)
	fmt.sbprintf(&builder, `%d,"facts":[`, len(facts))
	for fact, f_idx in facts {
		if f_idx > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_string(&builder, `{"sequence":`)
		fmt.sbprintf(&builder, `%d,"timestamp_ms":%d,"module":`, fact.sequence, fact.timestamp_ms)
		json_write_escaped_string(&builder, fact.module_name)
		strings.write_string(&builder, `,"fact_name":`)
		json_write_escaped_string(&builder, fact.fact_name)
		strings.write_string(&builder, `,"level":`)
		json_write_escaped_string(&builder, fact.level)
		strings.write_string(&builder, `,"fields":{`)
		for field, idx in fact.fields {
			if idx > 0 {
				strings.write_byte(&builder, ',')
			}
			json_write_escaped_string(&builder, field.name)
			strings.write_byte(&builder, ':')
			json_write_escaped_string(&builder, field.value)
		}
		strings.write_string(&builder, `}}`)
	}
	strings.write_string(&builder, `]}}`)
	return strings.to_string(builder)
}

// bridge_serve_stdio reads line-delimited JSON-RPC 2.0 requests from stdin
// and writes structured JSON-RPC 2.0 responses to stdout until EOF.
bridge_serve_stdio :: proc(bridge: ^Agent_Bridge) -> int {
	if bridge == nil {
		return foundation.EXIT_FAILURE
	}
	line_buffer := make([dynamic]u8, 0, 4096)
	defer delete(line_buffer)
	chunk: [4096]u8

	for {
		n, read_err := os.read(os.stdin, chunk[:])
		if n > 0 {
			for index in 0 ..< n {
				ch := chunk[index]
				if ch == '\n' {
					line_text := strings.trim_right(string(line_buffer[:]), "\r")
					if len(strings.trim_space(line_text)) > 0 {
						response := bridge_handle_json_line(bridge, line_text, context.temp_allocator)
						_, _ = os.write(os.stdout, transmute([]u8)response)
						_, _ = os.write(os.stdout, []u8{'\n'})
					}
					clear(&line_buffer)
					free_all(context.temp_allocator)
				} else if len(line_buffer) < contract.MAX_BRIDGE_PAYLOAD_BYTES * 2 {
					append(&line_buffer, ch)
				}
			}
		}
		if read_err != nil || n == 0 {
			if len(line_buffer) > 0 {
				line_text := strings.trim_right(string(line_buffer[:]), "\r")
				if len(strings.trim_space(line_text)) > 0 {
					response := bridge_handle_json_line(bridge, line_text, context.temp_allocator)
					_, _ = os.write(os.stdout, transmute([]u8)response)
					_, _ = os.write(os.stdout, []u8{'\n'})
				}
				clear(&line_buffer)
				free_all(context.temp_allocator)
			}
			break
		}
	}
	return 0
}

// parse_hex_32 decodes an exact 64-hex-character key. The agent runner of
// the assistant reads its keys with it too.
parse_hex_32 :: proc(text: string) -> (key: [32]u8, ok: bool) {
	if len(text) != 64 {
		return {}, false
	}
	raw, decoded_ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	if !decoded_ok || len(raw) != 32 {
		return {}, false
	}
	copy(key[:], raw)
	return key, true
}

@(private = "file")
parse_permissions_csv :: proc(text: string) -> (perms: contract.Bridge_Permissions, uses: remote.Client_Uses, ok: bool) {
	rest := text
	for part in strings.split_iterator(&rest, ",") {
		item := strings.trim_space(part)
		switch item {
		case "eval_lex":
			perms += {.Eval_Lex}
			uses += {.Calls}
		case "read_screen":
			perms += {.Read_Screen}
			uses += {.View}
		case "send_input":
			perms += {.Send_Input}
			uses += {.View, .Input}
		case "read_log_facts":
			perms += {.Read_Log_Facts}
			uses += {.Calls}
		case:
			return {}, {}, false
		}
	}
	return perms, uses, perms != {}
}

// run_agent_bridge is the CLI entry point for `modustool agent-bridge`.
run_agent_bridge :: proc(args: []string) -> int {
	usage_text :: "modustool: agent-bridge --remote-key <64-hex> --client-key <64-hex> [--socket <path>] [--principal <id>] [--permissions <eval_lex,read_screen,send_input,read_log_facts>] [--snapshot-dir <folder>] [--wide-grant-serial <u64> --wide-grant-windows <id,id,...> [--wide-grant-duration-ms <u64>]]"

	remote_key_text := ""
	client_key_text := ""
	socket_override := ""
	principal_id: u64 = 0
	permissions_text := "eval_lex,read_log_facts"
	wide_grant_serial: u64 = 0
	wide_grant_windows_text := ""
	wide_grant_duration_ms := wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS
	snapshot_directory_text := ""

	for index := 0; index < len(args); index += 1 {
		switch args[index] {
		case "--remote-key":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			remote_key_text = args[index]
		case "--client-key":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			client_key_text = args[index]
		case "--socket":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			socket_override = args[index]
		case "--principal":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			val, ok := strconv.parse_u64(args[index])
			if !ok {
				fmt.eprintln("modustool: agent-bridge: --principal must be a non-negative integer")
				return foundation.EXIT_USAGE
			}
			principal_id = val
		case "--snapshot-dir":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			snapshot_directory_text = args[index]
		case "--permissions":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			permissions_text = args[index]
		case "--wide-grant-serial":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			val, ok := strconv.parse_u64(args[index])
			if !ok || val == 0 {
				fmt.eprintln("modustool: agent-bridge: --wide-grant-serial must be a positive integer")
				return foundation.EXIT_USAGE
			}
			wide_grant_serial = val
		case "--wide-grant-windows":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			wide_grant_windows_text = args[index]
		case "--wide-grant-duration-ms":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			val, ok := strconv.parse_u64(args[index])
			if !ok || val == 0 || val > wide_grants.MAX_WIDE_GRANT_DURATION_MS {
				fmt.eprintln("modustool: agent-bridge: --wide-grant-duration-ms out of range")
				return foundation.EXIT_USAGE
			}
			wide_grant_duration_ms = val
		case:
			fmt.eprintfln("modustool: agent-bridge: unknown option %s", args[index])
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
	}

	remote_key, rk_ok := parse_hex_32(remote_key_text)
	client_key, ck_ok := parse_hex_32(client_key_text)
	if !rk_ok || !ck_ok {
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}
	perms, uses, perm_ok := parse_permissions_csv(permissions_text)
	if !perm_ok {
		fmt.eprintln("modustool: agent-bridge: --permissions must list one or more of eval_lex,read_screen,send_input,read_log_facts")
		return foundation.EXIT_USAGE
	}

	socket_path := socket_override
	if socket_path == "" {
		resolved, problem := machine.call_socket_path(machine.CALL_SOCKET_RUN_NAME)
		if problem != "" {
			fmt.eprintfln("modustool: agent-bridge: %s", problem)
			return foundation.EXIT_FAILURE
		}
		socket_path = resolved
	}

	policy := contract.Bridge_Client_Policy {
		client_key_public   = client_key,
		principal_id        = principal_id,
		permissions_word    = contract.bridge_permissions_to_word(perms),
		remote_uses_word    = remote.client_uses_word(uses),
		collector_available = true,
	}

	if wide_grant_serial != 0 {
		terms := wide_grants.Wide_Grant_Terms {
			principal_id          = principal_id,
			grantee_identity_hash = blake3.hash(client_key[:]),
			authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
			duration_ms           = wide_grant_duration_ms,
			survives_restart      = false,
		}
		rest := wide_grant_windows_text
		for part in strings.split_iterator(&rest, ",") {
			trimmed := strings.trim_space(part)
			if trimmed == "" {
				continue
			}
			win_id, win_ok := strconv.parse_u64(trimmed)
			if !win_ok || win_id == 0 || terms.target_window_count >= wide_grants.MAX_TARGET_WINDOWS {
				fmt.eprintln("modustool: agent-bridge: invalid --wide-grant-windows list")
				return foundation.EXIT_USAGE
			}
			terms.target_window_ids[terms.target_window_count] = win_id
			terms.target_window_count += 1
		}
		if seal_refusal := wide_grants.wide_grant_terms_seal(&terms); seal_refusal != .None {
			fmt.eprintfln("modustool: agent-bridge: invalid wide grant terms: %v", seal_refusal)
			return foundation.EXIT_USAGE
		}
		now_ns := time.time_to_unix_nano(time.now())
		now_ms := now_ns > 0 ? u64(now_ns) / 1_000_000 : 1
		policy.has_wide_grant = true
		policy.wide_grant_serial = wide_grant_serial
		policy.wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Active)
		policy.wide_grant_terms = terms
		policy.wide_grant_created_ms = now_ms
		policy.wide_grant_expires_ms = now_ms + wide_grant_duration_ms
	}

	snapshot_directory := ""
	if snapshot_directory_text != "" {
		checked, problem := snapshot_directory_check(snapshot_directory_text)
		if problem != "" {
			fmt.eprintfln("modustool: agent-bridge: %s", problem)
			return foundation.EXIT_USAGE
		}
		snapshot_directory = checked
	}
	defer delete(snapshot_directory)

	remote_transport: Remote_Machine_Transport
	if !remote_transport_open(&remote_transport, socket_path, remote_key) {
		fmt.eprintln("modustool: agent-bridge: cannot open remote QUIC call transport")
		return foundation.EXIT_FAILURE
	}
	defer remote_transport_close(&remote_transport)

	bridge: Agent_Bridge
	if !bridge_init(&bridge, policy, remote_transport_interface(&remote_transport)) {
		fmt.eprintln("modustool: agent-bridge: cannot initialize agent bridge")
		return foundation.EXIT_FAILURE
	}
	defer bridge_destroy(&bridge)
	bridge.snapshot_directory = snapshot_directory

	return bridge_serve_stdio(&bridge)
}
