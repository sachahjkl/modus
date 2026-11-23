package remote_service

import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:quic"
import "modus:quic_server"

// The log facts of the remote service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the keys of the
// clients that the handshake refuses or takes, the connections, the
// streams that a bound resets, and the connections to services, as
// records of fields. Each fact template is the sentence that the line wrote
// before it was a fact, so a wait of a machine test on that sentence reads
// it as before. A line whose sentence differs by its case is one fact type
// for each case: the template has no condition. No field has the name of a
// column of the head of facts(): number, time, process, level.
//
// A key and the address of a host are Text fields, and the last fields:
// the serial line of a fact stops at its last byte that is not zero. A
// Text field is [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of a whole client key: 64 hexadecimal digits
// and a zero byte, on 8 bytes.
KEY_FIELD_BYTES :: 72
// The bytes of the Text field of the head of a client key: its first 8
// bytes in 16 hexadecimal digits, as the root service writes it, and a
// zero byte, on 8 bytes.
KEY_HEAD_FIELD_BYTES :: 24
// The bytes of the Text field of the address of a host: the longest,
// "255.255.255.255 port 65535", has 26 bytes, and a zero byte.
PEER_FIELD_BYTES :: 32

// The handshake refused a client key that two principals allowed.
@(log_fact = "remote: refused the client key {client_key}: it is contested: principal {principal} and principal {other_principal} both allowed it, and it acts for neither until one of them revokes it; the handshake ends before any call")
Client_Key_Refused_Contested :: struct {
	principal:       u64,
	other_principal: u64,
	client_key:      [72]u8,
}

// The handshake refused a client key that its principal allowed for the
// remote display only.
@(log_fact = "remote: refused the client key {client_key}: principal {principal} allowed it for the remote display, and not for calls; the handshake ends before any call")
Client_Key_Refused_For_Display_Only :: struct {
	principal:  u64,
	client_key: [72]u8,
}

// The handshake refused a client key whose principal locked its session.
@(log_fact = "remote: refused the client key {client_key}: the session of its principal {principal} is locked; the handshake ends before any call")
Client_Key_Refused_Session_Locked :: struct {
	principal:  u64,
	client_key: [72]u8,
}

// The handshake refused a client key that no principal allowed.
@(log_fact = "remote: refused the client key {client_key}: no principal allowed it; the handshake ends before any call")
Client_Key_Refused :: struct {
	client_key: [72]u8,
}

// The grant of a client key ended between the check of the handshake and
// the binding of its connection.
@(log_fact = "remote: {peer}: the grant of the client key {client_key_head} ended during the handshake: the connection ends with the code Revoked, before any call")
Client_Key_Grant_Ended_In_Handshake :: struct {
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// A host proved a client key that a principal allowed: the connection is
// taken, and its calls act for that principal.
@(log_fact = "remote: {peer} proved the client key {client_key_head}: its calls act for principal {principal}")
Client_Key_Proved :: struct {
	principal:       u64,
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// A host proved the identity key of a paired machine, or of the machine of
// an open pairing: its streams carry mesh frames only.
@(log_fact = "remote: {peer} proved the machine identity key {client_key_head}: a paired machine, whose streams carry mesh frames only")
Mesh_Peer_Proved :: struct {
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// The handshake of an outbound link proved the identity key that the link
// pins: its requests leave.
@(log_fact = "remote: the outbound link to the machine identity key {client_key_head} at {peer} is up: the handshake proved the pinned key")
Mesh_Link_Up :: struct {
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// An outbound link ended: each request in flight ended in doubt when the
// link was up, or as unreachable when it never came up.
@(log_fact = "remote: the outbound link to the machine identity key {client_key_head} at {peer} ended: {in_doubt} requests in doubt, {unreachable} requests that never left")
Mesh_Link_Ended :: struct {
	in_doubt:        u64,
	unreachable:     u64,
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// The row of a paired machine ended while its connection was open: a newer
// machine list removed it, or its pairing ended.
@(log_fact = "remote: the machine identity key {client_key_head} is no longer paired: the connection from {peer} ends with the code Revoked")
Mesh_Peer_Ended :: struct {
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// A second principal allowed the client key of an open connection: the
// connection ends.
@(log_fact = "remote: the client key {client_key_head} of principal {principal} is contested: principal {other_principal} allowed it too, and it acts for neither; the connection from {peer} ends with the code Revoked")
Client_Key_Contested :: struct {
	principal:       u64,
	other_principal: u64,
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// The grant of the client key of an open connection ended: the connection
// ends.
@(log_fact = "remote: the grant of the client key {client_key_head} of principal {principal} ended (a revocation, or a lock of its session): the connection from {peer} ends with the code Revoked")
Client_Key_Grant_Ended :: struct {
	principal:       u64,
	client_key_head: [24]u8,
	peer:            [32]u8,
}

// A host opened a connection, before its handshake.
@(log_fact = "remote: a connection from {peer}")
Connection_Arrived :: struct {
	peer: [32]u8,
}

// A connection ended by its idle timeout, and its silence held the bound.
@(log_fact = "remote: {peer}: the idle end held its bound: {silence} with no packet of the host, the idle timeout {idle_timeout}, the bound {bound}, {after_bound} after the bound")
Idle_End_Held :: struct {
	silence:      value_kinds.Time_In_Milliseconds,
	idle_timeout: value_kinds.Time_In_Milliseconds,
	bound:        value_kinds.Time_In_Milliseconds,
	after_bound:  value_kinds.Time_In_Milliseconds,
	peer:         [32]u8,
}

// A connection ended by its idle timeout before its silence reached the
// idle timeout: a fault of the bound.
@(log_fact = "remote: {peer}: the idle end did NOT hold its bound: {silence} with no packet of the host, the idle timeout {idle_timeout}, the bound {bound}, {after_bound} after the bound")
Idle_End_Not_Held :: struct {
	silence:      value_kinds.Time_In_Milliseconds,
	idle_timeout: value_kinds.Time_In_Milliseconds,
	bound:        value_kinds.Time_In_Milliseconds,
	after_bound:  value_kinds.Time_In_Milliseconds,
	peer:         [32]u8,
}

// A request passed the limit of a request: its stream is reset, and no
// call runs.
@(log_fact = "remote: {peer}, the stream {stream_identifier}: a request of more than {request_limit}: reset with the code Too_Large, and no call")
Request_Too_Large :: struct {
	stream_identifier: u64,
	request_limit:     value_kinds.Size_In_Bytes,
	peer:              [32]u8,
}

// A request was not whole by its bound: its stream is reset. The service
// resets it only when the time of the machine since its start reached the
// bound, so the bound held: a test reads the words, and the time is a
// field.
@(log_fact = "remote: {peer}, the stream {stream_identifier}: no whole request in {bound} ({bytes_received} came): reset with the code Timeout after {elapsed} of the machine; the bound of a request held")
Request_Timeout :: struct {
	stream_identifier: u64,
	bound:             value_kinds.Time_In_Milliseconds,
	bytes_received:    value_kinds.Size_In_Bytes,
	elapsed:           value_kinds.Time_In_Milliseconds,
	peer:              [32]u8,
}

// The host did not take an answer by its bound: its stream is reset, as a
// request past its bound is.
@(log_fact = "remote: {peer}, the stream {stream_identifier}: the host did not take the answer in {bound} ({bytes_written} of {answer_length} in the stream): reset with the code Timeout after {elapsed} of the machine; the bound of an answer held")
Answer_Timeout :: struct {
	stream_identifier: u64,
	bound:             value_kinds.Time_In_Milliseconds,
	bytes_written:     u64,
	answer_length:     value_kinds.Size_In_Bytes,
	elapsed:           value_kinds.Time_In_Milliseconds,
	peer:              [32]u8,
}

// The host did not end a stream after its reset: the connection ends.
@(log_fact = "remote: {peer}, the stream {stream_identifier}: the host did not end it {bound} after its reset: the connection ends with the code Timeout after {elapsed} of the machine")
Stream_Not_Ended_After_Reset :: struct {
	stream_identifier: u64,
	bound:             value_kinds.Time_In_Milliseconds,
	elapsed:           value_kinds.Time_In_Milliseconds,
	peer:              [32]u8,
}

// The grants of connections to services ended: their slots are free.
@(log_fact = "remote: the grants of {ended} connections to services ended (a revocation, or a lock or an unlock of a session): their slots are free; {in_use} of {capacity} slots in use")
Service_Connections_Ended :: struct {
	ended:    u64,
	in_use:   u64,
	capacity: u64,
}

// Connections to services that no client uses ended: the last client of
// their key left, or no call went through them for the idle bound. This
// process told the root service, which frees its place and the place of
// the service.
@(log_fact = "remote: ended {ended} connections to services that no client uses (the last client of their key left, or no call for 60 s): their slots are free; {in_use} of {capacity} slots in use")
Unused_Service_Connections_Ended :: struct {
	ended:    u64,
	in_use:   u64,
	capacity: u64,
}

// The root service connected this service to a service, for the principal
// of a row of the client table.
@(log_fact = "remote: connected to the service {service}, for principal {principal}")
Service_Connected :: struct {
	principal: u64,
	service:   value_kinds.Module_Name_Field,
}

// A service stopped during a call: its connection ends.
@(log_fact = "remote: the service {service} stopped during a call")
Service_Stopped_During_Call :: struct {
	service: value_kinds.Module_Name_Field,
}

// A service did not answer a call by its bound: its connection ends.
@(log_fact = "remote: the service {service} did not answer in {bound}: the connection ends")
Service_Silent :: struct {
	bound:   value_kinds.Time_In_Milliseconds,
	service: value_kinds.Module_Name_Field,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Client_Key_Refused) == KEY_FIELD_BYTES)
#assert(size_of(Public_Key_Made) == KEY_FIELD_BYTES)
#assert(size_of(Connection_Ended) == 24 + PEER_FIELD_BYTES + END_REASON_FIELD_BYTES)
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "remote: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The public key of the service, which a client checks.
@(log_fact = "remote: the public key of this service: {public_key}")
Public_Key_Made :: struct {
	public_key: [72]u8,
}

// The service listens for the calls of the host.
@(log_fact = "remote: listening on the UDP port {listen_port}, for the host 10.0.2.2 only, and for the client keys that a principal allowed: {connection_capacity} connections, each with {calls_per_connection} calls at one time")
Listening :: struct {
	listen_port:          u64,
	connection_capacity:  u64,
	calls_per_connection: u64,
}

// The bytes of the Text field of why a connection ended: the longest,
// "closed by this service", has 22 bytes.
END_REASON_FIELD_BYTES :: 32

// A connection ended, with a transport code of its close.
@(log_fact = "remote: {peer} ended ({end_reason}, the code {close_code}): in {bytes_in}, out {bytes_out}")
Connection_Ended :: struct {
	close_code: value_kinds.Hexadecimal_Sixteen_Digits,
	bytes_in:   value_kinds.Size_In_Bytes,
	bytes_out:  value_kinds.Size_In_Bytes,
	peer:       [32]u8,
	end_reason: [32]u8,
}

// A connection ended, with a code of the application.
@(log_fact = "remote: {peer} ended ({end_reason}, the code {close_code} of the application): in {bytes_in}, out {bytes_out}")
Connection_Ended_By_Application :: struct {
	close_code: value_kinds.Hexadecimal_Sixteen_Digits,
	bytes_in:   value_kinds.Size_In_Bytes,
	bytes_out:  value_kinds.Size_In_Bytes,
	peer:       [32]u8,
	end_reason: [32]u8,
}

// A request refused, with the values of its error record.
@(log_fact = "remote: refused a request: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Request_Refused :: distinct errors.Error_Record_Fact_Fields

// The last refused request that the log takes: the service counts the
// next ones only. The words of the error record end each such template,
// so the words of the count come before them.
@(log_fact = "remote: refused a request, and counts the next refusals only: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Request_Refused_Last_Logged :: distinct errors.Error_Record_Fact_Fields

// The seed of the process is too weak for a key.
@(log_fact = "remote: the random seed of this process is weak: it makes no key, and listens on nothing")
Seed_Weak :: struct {}

// A measure: the time of one picture of the window, taken once.
@(log_fact = "remote: the window drew one picture in {picture_time}")
Window_Drawn :: struct {
	picture_time: value_kinds.Time_In_Microseconds,
}

// A measure: the work of the interface for that picture.
@(log_fact = "remote: the interface: {records} records, {damage_rectangles} damage rectangles; build {build_time}, difference {difference_time}, draw {draw_time}")
Interface_Measured :: struct {
	records:           u64,
	damage_rectangles: u64,
	build_time:        value_kinds.Time_In_Microseconds,
	difference_time:   value_kinds.Time_In_Microseconds,
	draw_time:         value_kinds.Time_In_Microseconds,
}
#assert(size_of(Client_Key_Grant_Ended_In_Handshake) == KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)
#assert(size_of(Connection_Arrived) == PEER_FIELD_BYTES)
#assert(size_of(Mesh_Link_Up) == KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)
#assert(size_of(Mesh_Link_Ended) == 16 + KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)

// key_field gives the Text field of a whole client key, in the digits of
// the line before the fact.
key_field :: proc "contextless" (key: [32]u8) -> [KEY_FIELD_BYTES]u8 {
	bytes := key
	text: [64]u8
	return value_kinds.text_field(quic_server.hex_text(text[:], bytes[:]), KEY_FIELD_BYTES)
}

// key_head_field gives the Text field of the head of a client key: its
// first 8 bytes.
key_head_field :: proc "contextless" (key: [32]u8) -> [KEY_HEAD_FIELD_BYTES]u8 {
	bytes := key
	text: [16]u8
	return value_kinds.text_field(quic_server.hex_text(text[:], bytes[:8]), KEY_HEAD_FIELD_BYTES)
}

// peer_field gives the Text field of the address and the port of a host.
peer_field :: proc "contextless" (peer: quic.Remote) -> [PEER_FIELD_BYTES]u8 {
	text: [40]u8
	return value_kinds.text_field(quic_server.address_text(text[:], peer), PEER_FIELD_BYTES)
}

// milliseconds_field gives a time in milliseconds as a field with its
// unit. A time of this service is far below the largest i64.
milliseconds_field :: proc "contextless" (milliseconds: u64) -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(milliseconds)
}

// bytes_field gives a count of bytes as a field with its unit.
bytes_field :: proc "contextless" (count: u64) -> value_kinds.Size_In_Bytes {
	return value_kinds.Size_In_Bytes(count)
}
