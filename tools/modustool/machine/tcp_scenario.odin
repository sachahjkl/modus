package machine

import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// TCP: two machines of their own (docs/NETWORK.md, "The tests").
//
// scenario_tcp: the network device goes to the peer of the tool. `server`
// listens on the TCP port 80; the peer is its TCP client, case by case,
// with loss, reorder, duplicates, a zero window, a RST, a segment of no
// connection, challenge ACKs and 16 connections at once.
//
// scenario_tcp_real: the network device goes to QEMU user networking: the
// TCP at the other end is the one of libslirp. The TCP of the host fetches
// the pages of `server` (hostfwd), and `fetch` fetches from a listener of
// the tool (guestfwd).

TEST_OUTPUT_TCP :: foundation.BUILD_FOLDER + "/test_output_tcp.txt"

scenario_tcp := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "server"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for server: TCP, the listen port 80, the remotes that send to it", any_order = true},
	{kind = .Wait, text = "root: started server"},
	{kind = .Wait, text = "server: listening on the TCP port 80, a table of 48 connections, the secret of the initial sequence numbers from the generator of the process"},
	// A page, and a close from the peer first.
	// The peer checks each answer; the access records are no lines of the
	// log, but records of the record output requests, which no one reads
	// in this scenario.
	{kind = .Peer, text = "page"},
	{kind = .Wait, text = "server: 1 connections open at once"},
	{kind = .Wait, text = " closed, the remote first: "},
	// 1 MiB each way, and a close from the server first.
	{kind = .Peer, text = "large"},
	{kind = .Wait, text = " closed, this server first: "},
	{kind = .Peer, text = "sink"},
	{kind = .Wait, text = "server: received /sink: 1048576 bytes, fnv1a64 e7867887f2822325, "},
	// The same with 5 % loss, a reorder of 10 %, duplicates of 10 %.
	{kind = .Peer, text = "loss"},
	{kind = .Peer, text = "reorder"},
	{kind = .Peer, text = "duplicate"},
	// The window of the peer goes to 0 for 1.5 s: the server probes it.
	{kind = .Peer, text = "zero window"},
	// RST: the peer resets a transfer; the server answers a segment of no
	// connection with a RST; a RST and a SYN in the window get challenge ACKs.
	{kind = .Peer, text = "reset"},
	{kind = .Wait, text = " reset by the remote: "},
	{kind = .Peer, text = "stray"},
	{kind = .Peer, text = "challenge"},
	{kind = .Wait, text = " 2 challenges"},
	// On a live connection, a segment that the wire damaged (a wrong
	// checksum, a malformed option), then the same segment with its checksum
	// whole: the library of the server drops both, the server releases no
	// remote for them, and the connection serves two more requests.
	{kind = .Peer, text = "damaged"},
	{kind = .Wait, text = "server: 1 segments dropped for a wrong checksum"},
	{kind = .Wait, text = " closed, the remote first: 3 requests, "},
	{kind = .Peer, text = "crowd"},
	{kind = .Wait, text = "server: 16 connections open at once"},
	// Three more rounds of 1 MiB each way: the spread of the measure.
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	// segments that must not fill the admitted remotes, then a page.
	{kind = .Peer, text = "leak"},
	// 32 connections of one host that make no progress: 8 refused by
	// the limit for each remote, each other one ended by a limit, then a page.
	{kind = .Peer, text = "slow"},
	{kind = .Wait, text = ": no request in 10 s, closed", any_order = true},
	{kind = .Wait, text = " aborted: a body under 4096 bytes in one second: ", any_order = true},
	{kind = .Wait, text = " aborted: an answer under 4096 bytes in one second: "},
	// The cases that a read of the HTTP server as hostile input found: each
	// case is a client that the server must end.
	// a whole request and one byte of the next one: 408 after 10 s.
	{kind = .Peer, text = "one byte after a request"},
	// the answers fill the window of the peer, which never reads; the
	// server closed, and must still end the connection.
	{kind = .Peer, text = "answers then close to a zero window"},
	// 1 MiB of a body of 16 MiB, then nothing; a reader of 1 KiB in one second.
	{kind = .Peer, text = "body then nothing"},
	{kind = .Wait, text = " aborted: no byte of the body in 10 s: "},
	{kind = .Peer, text = "slow reader"},
	{kind = .Wait, text = " aborted: an answer under 4096 bytes in one second: "},
	// the console removes a page while answers of it are in progress.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"server\")"},
	{kind = .Wait, text = "root: connected console to the service server"},
	{kind = .Type, text = "server.put(\"changing.txt\", repeat(\"0123456789abcdef\", 200))"},
	{kind = .Wait, text = "server: the page /changing.txt is in the store: 3200 bytes"},
	{kind = .Peer_Start, text = "page changed during its answer"},
	// The mark goes before the removal: a RST after it can be the change of
	// the page, a RST before it cannot.
	{kind = .Peer_Mark, text = "page changed during its answer"},
	{kind = .Type, text = "server.remove(\"changing.txt\")"},
	{kind = .Wait, text = "server: the page /changing.txt is out of the store"},
	// Until now the peer read at three times the least pace of the
	// slow-reader rule; now it reads as fast as it can: the server writes
	// the answer in progress again, and finds the change. The case checks
	// that the RST came after the removal, inside the answers of the page.
	{kind = .Peer_Result, text = "page changed during its answer"},
	{kind = .Wait, text = " aborted: the page changed during its answer: "},
	{kind = .Front, text = "server"},
	{kind = .Shot, text = "server"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"server\")"},
	{kind = .Wait, text = "[console] server   log      held"},
	{kind = .Wait, text = "[console] server   store    held"},
	{kind = .Wait, text = "[console] server   network  held"},
	{kind = .Close, text = "server"},
	{kind = .Wait, text = "root: server stopped: a holder"},
	{kind = .Wait, text = "network: the endpoint of server ended: "},
	// The passes of the network service over the bytes of the segments of
	// `server`: a measure, then the structural count: one copy each way, and
	// no checksum (the TCP library of `server` checks and writes it).
	{kind = .Wait, text = "network: a measure: the endpoint of server, TCP: the passes of this service over the data for each payload byte: "},
	{kind = .Wait, text = "network: the endpoint of server, TCP: this service read each payload byte one time on receive, for the copy, and on send only the 8 bytes of each header that it checks, and 0 bytes of the data; it computed no checksum: as it must"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_no_budget_holds  0 pages"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_tcp_real := [?]Step {
	// The server sends the field Date only when the date is known, and the
	// process `date` knows it after it saw a second of the real-time clock
	// begin: up to one second after its start. The fetch checks the field,
	// so the date is known first.
	// The date line and the line of the first window come in either order:
	// the first one is looked for with no move of the place in the log.
	{kind = .Wait, text = "date: ok, ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "server"},
	{kind = .Wait, text = "server: listening on the TCP port 80"},
	// The access records of server through the console
	// (src/md/features/module_outputs.md, "The migration"): 10 requests
	// with no reader, then a stream of the records of the status 404. Its
	// joined record counts the 10 records before it; its first row is the
	// next request, a 404. The wait for the wiring comes before that
	// request: a record written before the wiring is not in the ring.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"server\")"},
	{kind = .Wait, text = "root: connected console to the service server"},
	{kind = .Http, text = "requests 10"},
	{kind = .Type, text = "server.requests |> where(status = 404)"},
	{kind = .Wait, text = "wiring: wired the record output 1 of server to its asker console, wiring "},
	{kind = .Http, text = "missing nothing.txt"},
	{kind = .Wait, text = "[console] joined after 10 records"},
	{kind = .Wait, text = "/nothing.txt"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "[console] Escape closed the stream after "},
	// first gives a Table once one record of the status 404 came.
	{kind = .Type, text = "server.requests |> where(status = 404) |> first(1)"},
	{kind = .Wait, text = "wiring: wired the record output 1 of server to its asker console, wiring "},
	{kind = .Http, text = "missing other.txt"},
	{kind = .Wait, text = "[console] 1 row of Access_Record"},
	{kind = .Fetch, text = "/"},
	{kind = .Fetch, text = "/large"},
	{kind = .Fetch, text = "/sink"},
	{kind = .Wait, text = "server: received /sink: 1048576 bytes, fnv1a64 e7867887f2822325, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"fetch\")"},
	{kind = .Wait, text = "network: an endpoint for fetch: TCP, the local ports "},
	{kind = .Wait, text = "fetch: the grant: TCP to 10.0.2.100 port 80 only, from the local ports "},
	// The value and the limit are remotes: endpoint_pack of 10.0.2.2 port
	// 80, and of 10.0.2.100 port 80.
	{kind = .Wait, text = "fetch: a SYN to 10.0.2.2 port 80: refused by the network service: kind No_Grant, unit Endpoint, operation 2, argument 3, value 10995149963344, limit 10995156385872, found 0"},
	{kind = .Wait, text = "fetch: a SYN from the local port 1234: refused: kind No_Grant, unit Endpoint, operation 2, argument 3, value 10995156385872, limit 10995156385872, found 1234 (its ports are "},
	{kind = .Wait, text = "fetch: the handshake with 10.0.2.100 port 80: established in "},
	{kind = .Wait, text = "fetch: GET /hello: status 200, \"hello from the host\" in "},
	{kind = .Wait, text = "fetch: GET /large: 1048576 bytes, fnv1a64 e7867887f2822325 as expected, "},
	{kind = .Wait, text = "fetch: POST /sink, 1 MiB: the remote got the same hash, "},
	// libslirp acknowledges the FIN of a connection of guestfwd and keeps
	// its half open: FIN-WAIT-2 (a sending of its FIN gives TIME-WAIT).
	{kind = .Wait, text = "fetch: the close from this side: the remote acknowledged the FIN, and "},
	{kind = .Wait, text = "fetch: ok, 8 cases"},
	{kind = .Shot, text = "fetch"},
	// A page in the private store of server, from the console, through its
	// exports, functions with typed parameters: then the host fetches it,
	// byte for byte. The console connected to server above.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "server.put(\"hello.txt\", \"kept in the store of server\")"},
	{kind = .Wait, text = "server: the page /hello.txt is in the store: 27 bytes"},
	{kind = .Http, text = "page hello.txt", expected = "kept in the store of server"},
	{kind = .Type, text = "server.pages()"},
	{kind = .Wait, text = "hello.txt"},
	// HTTP/1.1 from the TCP of the host: keep-alive, a connection for each
	// request, pipelining, a split body, HEAD, 16 clients, each refusal.
	{kind = .Http, text = "keep-alive"},
	{kind = .Wait, text = " requests on one connection of 10.0.2.2 port ", any_order = true},
	// The measure of a reader (src/md/features/module_outputs.md, "The
	// measures that decide it", 6): the same 1000 requests while the
	// console holds a ring of requests whose condition no request passes:
	// the server tests the condition and publishes its counts at each
	// write, and writes the joined record once. The case prints the rate;
	// the counts of the writer then print what each write did. Nothing is
	// asserted. The console draws no row here: it writes each line that it
	// draws to its log, and 1000 rows in less than one second spend the
	// log records of its second, so the kernel refuses its next lines, the
	// line of Escape among them, and the wait for that line never ends.
	// The server is not held by the ring of the console in any case: the
	// pace Writer_Chooses and a write with no wait refuse with Full.
	{kind = .Type, text = "server.requests |> where(status = 500)"},
	{kind = .Wait, text = "wiring: wired the record output 1 of server to its asker console, wiring "},
	{kind = .Http, text = "keep-alive"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "[console] Escape closed the stream after "},
	{kind = .Type, text = "stream_counts(server.requests)"},
	{kind = .Wait, text = "wiring: wired the record output 1 of server to its asker console, wiring "},
	{kind = .Http, text = "requests 1"},
	{kind = .Wait, text = "[console] Writer_Counts"},
	// Each count is a row of the record, the last one the rings that the
	// writer closed past their gap: the console reads none of a ring of
	// no condition here, and server closed none.
	{kind = .Wait, text = "held "},
	{kind = .Wait, text = "rings_past_gap  0"},
	{kind = .Http, text = "new-connections"},
	// The ends of connections have their own budget on the log.
	{kind = .Wait, text = " ends of connections in one second are not on the log (the limit is 50)", any_order = true},
	{kind = .Http, text = "pipeline"},
	{kind = .Http, text = "split"},
	{kind = .Http, text = "head"},
	{kind = .Http, text = "crowd"},
	{kind = .Http, text = "errors"},
	// The cases that a read of the HTTP server as hostile input found.
	{kind = .Http, text = "body-not-taken"},
	{kind = .Http, text = "requests-then-fin"},
	{kind = .Http, text = "headers"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "server.remove(\"hello.txt\")"},
	{kind = .Wait, text = "server: the page /hello.txt is out of the store"},
	{kind = .Http, text = "missing hello.txt"},
	// The scenario revokes the store of server: a put and a remove
	// are refused, and the page that is served does not change.
	{kind = .Type, text = "server.put(\"kept.txt\", \"the first text\")"},
	{kind = .Wait, text = "server: the page /kept.txt is in the store: 14 bytes"},
	{kind = .Type, text = "revoke(\"server\", \"store\")"},
	{kind = .Wait, text = "root: revoked the grant store of server"},
	{kind = .Type, text = "server.put(\"kept.txt\", \"a second text\")"},
	{kind = .Wait, text = "server: the store refused the page /kept.txt: the page that is served did not change"},
	{kind = .Http, text = "page kept.txt", expected = "the first text"},
	{kind = .Type, text = "server.remove(\"kept.txt\")"},
	{kind = .Wait, text = "server: the store refused the removal of /kept.txt: the page is still served"},
	{kind = .Http, text = "page kept.txt", expected = "the first text"},
	{kind = .Front, text = "server"},
	{kind = .Shot, text = "server_real"},
	// Fan-out and the pace (src/md/features/module_outputs.md, "Fan-out
	// and flow control"): requests_pace starts a slow reader and a new
	// server whose requests go to three readers. The slow reader opens
	// each of its phases on a state of its rings, never on a time; the
	// tool sends the 80 requests of the test in three parts, each after the
	// line of the phase before, and each reader checks its
	// order and its counts.
	{kind = .Close, text = "server"},
	{kind = .Wait, text = "root: server stopped: a holder"},
	{kind = .Wait, text = "network: the endpoint of server ended: "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"requests_pace\")"},
	{kind = .Wait, text = "requests_pace: server runs with three readers of requests: held of the pace Always_Holds_Writer and gapped of the pace Never_Holds_Writer, in rings of 32, and this process, the fast reader", fails_on = "requests_pace: WRONG"},
	{kind = .Wait, text = "server: listening on the TCP port 80"},
	// The 80 requests in three parts, each sent after the slow reader said
	// that it drained its rings: no request is in flight while it drains,
	// so the server waits exactly once in each phase.
	{kind = .Http, text = "requests 32"},
	{kind = .Wait, text = "requests_reader: phase 1 read", fails_on = "requests_reader: WRONG"},
	{kind = .Http, text = "requests 32"},
	{kind = .Wait, text = "requests_reader: phase 2 read", fails_on = "requests_reader: WRONG"},
	{kind = .Http, text = "requests 16"},
	{kind = .Wait, text = "requests_pace: the fast reader read the 80 records; it waits for the stop of server", fails_on = "requests_pace: WRONG"},
	// The tool has the answer of each request: the principal stops server,
	// and the readers read the end of their rings. The window of the server
	// that requests_pace started is in front since its start: the console
	// comes in front first, or the keys of the command go to the server.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"server\")"},
	{kind = .Wait, text = "root: server stopped: "},
	{kind = .Wait, text = "requests_reader: held, of the pace Always_Holds_Writer: the joined record of 0 and the 80 records in order, no gap, with a ring of 32 that held the server twice: as it must", fails_on = "requests_reader: WRONG", any_order = true},
	{kind = .Wait, text = "requests_reader: gapped, of the pace Never_Holds_Writer: the joined record of 0, 48 records, and one gap record of exactly 32 records from the serial 31, which the records around it meet: as it must", fails_on = "requests_reader: WRONG", any_order = true},
	{kind = .Wait, text = "requests_pace: the fast reader: the joined record of 0 and the 80 records in order, no gap; the server was held 2 times by the slow reader of the pace Always_Holds_Writer and refused no record: as it must", fails_on = "requests_pace: WRONG"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

tcp_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	if !machine_test(part, scenario_tcp[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_TCP, exit_status = build.MACHINE_STOP_OK}) || !machine_test(part, scenario_tcp_real[:], {volume = build.BOOT_VOLUME, output = checks.TEST_OUTPUT_TCP_REAL, exit_status = build.MACHINE_STOP_OK, user_network = true}) {
		return false
	}
	frames_of_the_fetch_report(checks.TEST_OUTPUT_TCP_REAL)
	return true
}
