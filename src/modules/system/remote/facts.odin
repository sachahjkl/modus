package remote_service

import "modus:contract/value_kinds"
import "modus:support/quic"

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
@(log_fact = "remote: {peer}: the grant of the client key {client_key} ended during the handshake: the connection ends with the code Revoked, before any call")
Client_Key_Grant_Ended_In_Handshake :: struct {
	client_key: [24]u8,
	peer:       [32]u8,
}

// A host proved a client key that a principal allowed: the connection is
// taken, and its calls act for that principal.
@(log_fact = "remote: {peer} proved the client key {client_key}: its calls act for principal {principal}")
Client_Key_Proved :: struct {
	principal:  u64,
	client_key: [24]u8,
	peer:       [32]u8,
}

// A second principal allowed the client key of an open connection: the
// connection ends.
@(log_fact = "remote: the client key {client_key} of principal {principal} is contested: principal {other_principal} allowed it too, and it acts for neither; the connection from {peer} ends with the code Revoked")
Client_Key_Contested :: struct {
	principal:       u64,
	other_principal: u64,
	client_key:      [24]u8,
	peer:            [32]u8,
}

// The grant of the client key of an open connection ended: the connection
// ends.
@(log_fact = "remote: the grant of the client key {client_key} of principal {principal} ended (a revocation, or a lock of its session): the connection from {peer} ends with the code Revoked")
Client_Key_Grant_Ended :: struct {
	principal:  u64,
	client_key: [24]u8,
	peer:       [32]u8,
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
@(log_fact = "remote: {peer}, the stream {stream}: a request of more than {limit}: reset with the code Too_Large, and no call")
Request_Too_Large :: struct {
	stream: u64,
	limit:  value_kinds.Size_In_Bytes,
	peer:   [32]u8,
}

// A request was not whole by its bound: its stream is reset. The service
// resets it only when the time of the machine since its start reached the
// bound, so the bound held: a test reads the words, and the time is a
// field.
@(log_fact = "remote: {peer}, the stream {stream}: no whole request in {limit} ({received} came): reset with the code Timeout after {elapsed} of the machine; the bound of a request held")
Request_Timeout :: struct {
	stream:   u64,
	limit:    value_kinds.Time_In_Milliseconds,
	received: value_kinds.Size_In_Bytes,
	elapsed:  value_kinds.Time_In_Milliseconds,
	peer:     [32]u8,
}

// The host did not take an answer by its bound: its stream is reset, as a
// request past its bound is.
@(log_fact = "remote: {peer}, the stream {stream}: the host did not take the answer in {limit} ({written} of {answer_length} in the stream): reset with the code Timeout after {elapsed} of the machine; the bound of an answer held")
Answer_Timeout :: struct {
	stream:        u64,
	limit:         value_kinds.Time_In_Milliseconds,
	written:       u64,
	answer_length: value_kinds.Size_In_Bytes,
	elapsed:       value_kinds.Time_In_Milliseconds,
	peer:          [32]u8,
}

// The host did not end a stream after its reset: the connection ends.
@(log_fact = "remote: {peer}, the stream {stream}: the host did not end it {limit} after its reset: the connection ends with the code Timeout after {elapsed} of the machine")
Stream_Not_Ended_After_Reset :: struct {
	stream:  u64,
	limit:   value_kinds.Time_In_Milliseconds,
	elapsed: value_kinds.Time_In_Milliseconds,
	peer:    [32]u8,
}

// The grants of connections to services ended: their slots are free.
@(log_fact = "remote: the grants of {ended} connections to services ended (a revocation, or a lock or an unlock of a session): their slots are free; {in_use} of {capacity} slots in use")
Service_Connections_Ended :: struct {
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
#assert(size_of(Client_Key_Grant_Ended_In_Handshake) == KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)
#assert(size_of(Connection_Arrived) == PEER_FIELD_BYTES)

// key_field gives the Text field of a whole client key, in the digits of
// the line before the fact.
key_field :: proc "contextless" (key: [32]u8) -> [KEY_FIELD_BYTES]u8 {
	bytes := key
	text: [64]u8
	return value_kinds.text_field(hex_text(text[:], bytes[:]), KEY_FIELD_BYTES)
}

// key_head_field gives the Text field of the head of a client key: its
// first 8 bytes.
key_head_field :: proc "contextless" (key: [32]u8) -> [KEY_HEAD_FIELD_BYTES]u8 {
	bytes := key
	text: [16]u8
	return value_kinds.text_field(hex_text(text[:], bytes[:8]), KEY_HEAD_FIELD_BYTES)
}

// peer_field gives the Text field of the address and the port of a host.
peer_field :: proc "contextless" (peer: quic.Remote) -> [PEER_FIELD_BYTES]u8 {
	text: [40]u8
	return value_kinds.text_field(address_text(text[:], peer), PEER_FIELD_BYTES)
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
