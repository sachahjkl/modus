package server

import "modus:contract/value_kinds"
import "modus:support/web"

// The log facts of server (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// The access record of a request is no log fact: the record output
// `requests` holds it (requests.odin). The row of the window that shows the
// last requests is Access_Row.
//
// The body of /sink writes its hash in 16 hexadecimal digits, as
// system.Hex wrote it.

// The body that a POST to /sink sent: its bytes, its FNV-1a hash and its
// rate in megabytes in one second.
@(log_fact = "server: received /sink: {body_size}, fnv1a64 {body_hash}, {rate} MB/s")
Sink_Received :: struct {
	body_size: value_kinds.Size_In_Bytes,
	body_hash: value_kinds.Hexadecimal_Sixteen_Digits,
	rate:      u64,
}

// The context of the process holds no random seed.
@(log_fact = "server: no random seed in the context")
No_Random_Seed :: struct {}

// The process has no private store: it serves no page of a store.
@(log_fact = "server: no private store: it serves no page of a store")
No_Private_Store :: struct {}

// The private store is new: it has no page.
@(log_fact = "server: a new store: no page")
New_Store :: struct {}

// The bytes of the Text field of the address of a host: the longest,
// "255.255.255.255 port 65535", has 26 bytes.
PEER_FIELD_BYTES :: 32
// The bytes of the Text field of a method of a request: the longest,
// "OPTIONS" and "CONNECT", have 7 bytes.
METHOD_FIELD_BYTES :: 8
// The bytes of the Text field of the target of a request: the target of an
// Access_Row, 48 bytes at most with its cut mark, and a zero byte.
TARGET_FIELD_BYTES :: 56
// The bytes of the Text field of the name of a page: web.PAGE_NAME_LIMIT
// bytes at most, and a zero byte.
PAGE_FIELD_BYTES :: 40
// The bytes of the Text field of how a connection ended: the longest,
// "aborted: an answer under 4096 bytes in one second", has 50 bytes.
HOW_FIELD_BYTES :: 56
// The bytes of the Text field of the cause of a stop: the longest, "no
// endpoint: the process has no grant of the network", has 52 bytes.
CAUSE_FIELD_BYTES :: 56

// The process stops, for a cause that it names.
@(log_fact = "server: {cause}")
Run_Failed :: struct {
	cause: [56]u8,
}

// The time of one draw of the window.
@(log_fact = "server: one draw of the window: {drawing}")
Window_Drawn :: struct {
	drawing: value_kinds.Time_In_Microseconds,
}

// A connection sent no request in 10 s: this server closed it.
@(log_fact = "server: {peer}: no request in 10 s, closed")
Request_Timeout :: struct {
	peer: [32]u8,
}

// The requests of one connection that stays open, and their rate.
@(log_fact = "server: {requests} requests on one connection of {peer} in {elapsed}: {rate} requests in one second")
Connection_Requests_Measured :: struct {
	requests: u64,
	elapsed:  value_kinds.Time_In_Milliseconds,
	rate:     u64,
	peer:     [32]u8,
}

// The requests answered in one second, and the connections that it
// accepted.
@(log_fact = "server: {requests} requests answered in one second, on {new_connections} new connections")
Requests_In_One_Second :: struct {
	requests:        u64,
	new_connections: u64,
}

// The ends of connections in one second past the log limit of the ends.
@(log_fact = "server: {ends} ends of connections in one second are not on the log (the limit is 50)")
Ends_Not_Logged :: struct {
	ends: u64,
}

// A connection ended: how, its requests, its bytes, its round trip, and
// what the library sent again.
@(log_fact = "server: {peer} {how}: {requests} requests, in {bytes_received}, out {bytes_sent}, srtt {round_trip}, {retransmissions} retransmissions, {probes} probes, {challenges} challenges")
Connection_Ended :: struct {
	requests:        u64,
	bytes_received:  u64,
	bytes_sent:      u64,
	round_trip:      value_kinds.Time_In_Microseconds,
	retransmissions: u64,
	probes:          u64,
	challenges:      u64,
	peer:            [32]u8,
	how:             [56]u8,
}

// The most connections open at one time so far.
@(log_fact = "server: {open} connections open at once")
Connections_Open :: struct {
	open: u64,
}

// The library dropped segments with a wrong checksum: a line at the first
// one, then each time the count doubles.
@(log_fact = "server: {segments} segments dropped for a wrong checksum")
Segments_Dropped :: struct {
	segments: u64,
}

// The server listens.
@(log_fact = "server: listening on the TCP port {listen_port}, a table of {capacity} connections, the secret of the initial sequence numbers from the generator of the process")
Listening :: struct {
	listen_port: u64,
	capacity:    u64,
}

// The pages read from the private store at the start.
@(log_fact = "server: {loaded} pages read from the private store, {refused} refused")
Pages_Read :: struct {
	loaded:  u64,
	refused: u64,
}

// The store refused a page: the page that is served is the one before.
@(log_fact = "server: the store refused the page /{page}: the page that is served did not change")
Page_Refused :: struct {
	page: [40]u8,
}

// The store refused the index of the pages after a new page.
@(log_fact = "server: the store refused the index of the pages: /{page} is not served")
Index_Refused :: struct {
	page: [40]u8,
}

// A page is in the store.
@(log_fact = "server: the page /{page} is in the store: {page_size}")
Page_Stored :: struct {
	page_size: value_kinds.Size_In_Bytes,
	page:      [40]u8,
}

// The store refused the removal of a page: it is still served.
@(log_fact = "server: the store refused the removal of /{page}: the page is still served")
Removal_Refused :: struct {
	page: [40]u8,
}

// The store refused the index of the pages after a removal.
@(log_fact = "server: the store refused the index of the pages after the removal of /{page}")
Index_Refused_After_Removal :: struct {
	page: [40]u8,
}

// A page is out of the store.
@(log_fact = "server: the page /{page} is out of the store")
Page_Removed :: struct {
	page: [40]u8,
}

#assert(PAGE_FIELD_BYTES > web.PAGE_NAME_LIMIT)
#assert(size_of(Connection_Ended) == 56 + PEER_FIELD_BYTES + HOW_FIELD_BYTES)
#assert(size_of(Page_Stored) == 8 + PAGE_FIELD_BYTES)

// peer_field gives the Text field of the address and the port of a host.
peer_field :: proc "contextless" (address: u32, port: u16) -> [PEER_FIELD_BYTES]u8 {
	text: [PEER_FIELD_BYTES]u8
	return value_kinds.text_field(address_text(text[:], address, port), PEER_FIELD_BYTES)
}

// page_field gives the Text field of the name of a page.
page_field :: proc "contextless" (name: string) -> [PAGE_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, PAGE_FIELD_BYTES)
}
