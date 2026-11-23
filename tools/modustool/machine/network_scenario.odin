package machine

import "modustool:build"
import "modustool:checks"
import "modustool:foundation"

TEST_OUTPUT_NO_NETWORK_DEVICE :: foundation.BUILD_FOLDER + "/test_output_no_network_device.txt"

network_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_network[:], {volume = build.BOOT_VOLUME, output = checks.TEST_OUTPUT_NETWORK, exit_status = build.MACHINE_STOP_OK}) && no_network_device_run(part)
}

// The network: a machine of its own. The network service starts when `net`
// starts, with the frame service of the network device. The peer of the
// tool (peer.odin) is the gateway and the echo server. `net` shows each
// case, then the measures. The scenario revokes the grant of the network:
// the next datagram is refused. Then the endpoint ends with its process,
// and each page is free or paid.
scenario_network := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "root: started frame for the device at the place 18 of the bus"},
	// The device found, by its hardware address: the step reads the field,
	// the wait the sentence.
	{kind = .Fact, process = "frame", fact = "frame_service.Device_Ready_Link_Up", condition = "hardware_address = \"52:54:00:12:34:56\"", any_order = true},
	{kind = .Wait, text = "frame: ok, the hardware address 52:54:00:12:34:56, the link is up", any_order = true},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: ok, the address 10.0.2.15/24 52:54:00:12:34:56, the gateway 10.0.2.2, the link is up", any_order = true},
	{kind = .Wait, text = "network: the headers of IPv4 and Ethernet of a frame with a payload of 1480 bytes: ", any_order = true},
	{kind = .Wait, text = "network: an endpoint for net: the local port 49152, the grant 10.0.2.2 port 7", any_order = true},
	// The datagram region of `net` is a read region of the frame service:
	// the device reads the data of each datagram there, with no copy.
	{kind = .Wait, text = "frame: a read region of 128 pages at the place 0, held with the right Read only: the device reads the data of the frames to send there", any_order = true},
	{kind = .Wait, text = "root: started net"},
	{kind = .Wait, text = "net: the link and the address: 10.0.2.15/24, the link is up, 52:54:00:12:34:56"},
	{kind = .Wait, text = "net: ARP: who has 10.0.2.2: the gateway answered 52:55:0a:00:02:02 in "},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.2, 56 bytes: the echo reply came in "},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from 10.0.2.2 port 7 in "},
	// The refusals write the fields of their error record: the operation
	// Send is 2 and Echo 5, and a remote is errors.endpoint_pack of its
	// address and its port (10.0.2.2 port 9 is 10995149963273, port 7
	// 10995149963271, 10.0.2.3 10995150028800).
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 9: refused: kind No_Grant, unit Endpoint, operation 2, argument 3, value 10995149963273, limit 10995149963271, found "},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.3: refused: kind No_Grant, unit Endpoint, operation 5, argument 1, value 10995150028800, limit "},
	{kind = .Wait, text = "net: UDP of 2000 bytes: refused, no fragment: kind Too_Long, unit Bytes, operation 2, argument 2, value 2000, limit 1480, found 0"},
	// The process writes the UDP header: the network service checks the
	// source port in its own copy of it.
	{kind = .Wait, text = "net: UDP from the source port 1234: refused: the source port 1234 of the header is not the local port of this endpoint, 49152"},
	// The network service refuses a datagram whose length field is not its
	// count of bytes, and a datagram shorter than its header.
	{kind = .Wait, text = "net: UDP with a wrong length field: refused: the length field of the header says 29 bytes, the Send has 28"},
	{kind = .Wait, text = "net: UDP of 7 bytes: refused: the Send has 7 bytes, a datagram has 8 bytes at least, its header"},
	// The network service computes no checksum of a datagram: the datagram
	// of the peer with a wrong one reaches the endpoint of its port, and
	// the process drops it.
	{kind = .Wait, text = "net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this process: 1 datagram; the network service gave it to the endpoint of its port"},
	// The row of the endpoint names its own grant; the rows of the machine
	// need the right Inspect, that `net` has with the machine.
	{kind = .Wait, text = "net: refused for this endpoint: 1 x udp, byte 34: the remote port 9 is not the port of the grant, 7"},
	{kind = .Wait, text = "net: refused for the machine: 1 x ipv4, byte 24: the checksum is 0x"},
	{kind = .Wait, text = "net: UDP from 10.0.2.2 port 9 to this endpoint: refused: from port 9; a row of this endpoint"},
	{kind = .Wait, text = "net: malformed frames from the wire: 9 refused in 9 kinds, 9 of 9 expected; no fault"},
	{kind = .Wait, text = "net: ICMP echo from 10.0.2.2 to this machine: the network service answered 1 request"},
	// The words of a command record that name no command: None, one past
	// the last command, the largest word. The network service answers what
	// its border decided, and serves the next command.
	{kind = .Wait, text = "net: the command word 0 of the datagram ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	{kind = .Wait, text = "net: the command word 10 of the datagram ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	{kind = .Wait, text = "net: the command word 4294967295 of the datagram ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	{kind = .Wait, text = "net: ok, 14 cases"},
	{kind = .Wait, text = "net: the header and the checksum of a datagram of 1472 bytes: "},
	{kind = .Wait, text = "net: the round trip of one datagram of 64 bytes: "},
	{kind = .Wait, text = "net: a burst with 64 datagrams in flight: "},
	{kind = .Wait, text = " datagrams in one second, sent and answered, 0 lost"},
	{kind = .Wait, text = "net: kernel entries for each datagram: "},
	{kind = .Wait, text = "net: the measures are done"},
	{kind = .Shot, text = "network"},
	// The grant is a record of the root service: the scenario lists it and
	// revokes it. The network service ends the grant of the endpoint.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"net\")"},
	{kind = .Wait, text = "[console] net      log      held"},
	{kind = .Wait, text = "[console] net      machine  held"},
	{kind = .Wait, text = "[console] net      network  held"},
	{kind = .Type, text = "revoke(\"net\", \"network\")"},
	// The line of the revocation is a log fact of the root service: the
	// step reads the field that names its process, the wait its sentence
	// with the count.
	{kind = .Fact, process = "root", fact = "root.Grant_Revoked_Endpoints", condition = "holder = \"net\"", any_order = true},
	{kind = .Wait, text = "root: revoked the grant network of net, endpoints changed: 1", any_order = true}, // The network service can write its line first.
	{kind = .Wait, text = "network: the grant of the endpoint of net changed: none"},
	{kind = .Front, text = "net"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "net: a datagram to 10.0.2.2 port 7 after a key: refused, the endpoint has no grant now: kind No_Grant, unit Endpoint, operation 2, argument 3, value 10995149963271, limit 0, found "},
	{kind = .Close, text = "net"},
	{kind = .Wait, text = "root: net stopped: a holder"},
	// The end of the endpoint, by the process that owned it.
	{kind = .Fact, process = "network", fact = "network_service.Endpoint_Ended", condition = "owner = \"net\"", any_order = true},
	{kind = .Wait, text = "network: the endpoint of net ended: "},
	// The passes of the network service over the bytes of the datagrams of
	// `net`: a measure, then the structural count: one copy on receive, on
	// send the copy of 8 bytes of each header and no byte of the data, and
	// no checksum.
	{kind = .Wait, text = "network: a measure: the endpoint of net, UDP: the passes of this service over the data for each payload byte: "},
	{kind = .Wait, text = "network: the endpoint of net, UDP: this service read each payload byte one time on receive, for the copy, and on send only the 8 bytes of each header that it checks, and 0 bytes of the data; it computed no checksum: as it must"},
	// The calls of the host (docs/MODULE_CONTRACT.md, "A call from the
	// host"). The remote service holds an endpoint whose grant names the
	// host, and connects to the services that the root service names for it.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "display: monitor" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "display: manual" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "remote"},
	// The service prints its key while the root service starts it: the key
	// can come before the line of the start.
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only, and for the client keys that a principal allowed", any_order = true},
	// The key of the client of the peer: the principal allows it from a
	// console that acts for it, and each call of that client acts for that
	// principal (docs/PRINCIPALS.md, "The client keys of remote").
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Front, text = "remote"},
	// Six malformed call requests, each on its own stream: each one has its
	// error record, and no call runs. The first connection binds the key of
	// the client to its principal.
	{kind = .Remote_Case, text = "malformed"},
	{kind = .Wait, text = ": its calls act for principal 0", any_order = true},
	{kind = .Wait, text = "remote: refused a request: kind Too_Small, unit Bytes, operation 0, argument 0, value 20, limit 104, found 0"},
	{kind = .Wait, text = "remote: refused a request: kind Bad_Value, unit None, operation 0, argument 1, value 9, limit 1, found 0"},
	{kind = .Wait, text = "remote: refused a request: kind Too_Long, unit Bytes, operation 0, argument 5, value 400, limit 16, found 0"},
	{kind = .Wait, text = "remote: refused a request: kind Too_Long, unit Bytes, operation 0, argument 8, value 65536, limit 65472, found 0"},
	{kind = .Wait, text = "remote: refused a request: kind Bad_Value, unit Bytes, operation 0, argument 10, value 28, limit 65480, found 0"},
	{kind = .Wait, text = "remote: refused a request: kind No_Grant, unit Connection, operation 0, argument 3, value 0, limit 0, found 0"},
	// The place of the pointer and the windows: each press from now on is
	// confirmed.
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Call, text = "compositor.windows()", expected = "rows of Window"},
	// An Integer, with the measure of a small call.
	{kind = .Call, text = "monitor.count(\"processors\")", expected = "4", repeat = 1000},
	{kind = .Wait, text = "root: connected remote to the service monitor, acting for principal 0, for the client key ", any_order = true},
	// The connection of remote to a service, by the service.
	{kind = .Fact, process = "remote", fact = "remote_service.Service_Connected", condition = "service = \"monitor\"", any_order = true},
	{kind = .Wait, text = "remote: connected to the service monitor, for principal 0"},
	{kind = .Wait, text = "remote: the window drew one picture in ", any_order = true},
	// A Table: the row of the remote service is there, and the count of the
	// rows is the count that the monitor wrote on the log.
	{kind = .Call, text = "monitor.processes()", expected = "remote", rows_call = "monitor.count(\"processes\")"},
	// A lost datagram: QUIC sends it again, and the call runs one time.
	{kind = .Call, text = "monitor.count(\"processors\")", expected = "4", lose = 1},
	// Another module than the one that runs: the remote service refuses it,
	// and the tool names the two hashes.
	{kind = .Call, text = "monitor.count(\"processors\")", outcome = .Refused, wrong_hash = true, expected = "the request named "},
	{kind = .Wait, text = "remote: refused a request: kind Bad_Value, unit None, operation 0, argument 4, value 0, limit 0, found 0"},
	{kind = .Call, text = "monitor.counts()", expected = "15 rows of Count"},
	// A Record: the counts of the monitor itself, which each caller sees.
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	// A result larger than one datagram, on one stream.
	{kind = .Call, text = "manual.modules()", expected = " rows of Module", least_answer_bytes = 1201},
	{kind = .Call, text = "manual.running()", expected = " rows of Running"},
	// A Text, from a service that starts at the first connection.
	{kind = .Call, text = "storage.stores()", expected = " blocks in use"},
	// Failures: the sentence of the error record of the service.
	{kind = .Call, text = "monitor.count(\"nothing\")", outcome = .Failed, expected = "error: monitor.count: the argument name names nothing that exists"},
	{kind = .Call, text = "storage.size(0, \"note\")", outcome = .Failed, expected = "error: storage.size: the caller has no grant for this: a private store"},
	{kind = .Call, text = "manual.exports(\"nothing\")", outcome = .Failed, expected = "error: manual.exports: the argument name names none of the modules"},
	// The tool checks the arguments against the description before it sends.
	{kind = .Call, text = "monitor.count(4)", outcome = .Wrong, expected = "error: the parameter name of monitor.count is a Text, the argument is an Integer"},
	// The transport (docs/QUIC.md, section 7). Two calls at one time, on two
	// streams: each answer on its own stream, in any order.
	{kind = .Remote_Case, text = "two at once"},
	// A request of more than a header and a call region: reset with
	// Too_Large, and no call.
	{kind = .Remote_Case, text = "too large"},
	{kind = .Wait, text = ": a request of more than 65640 bytes: reset with the code Too_Large, and no call"},
	// A stream with a part of a request and no end: reset with Timeout at
	// the bound of a request, in time of the machine.
	{kind = .Remote_Case, text = "a part and no end"},
	{kind = .Wait, text = " ms of the machine; the bound of a request held"},
	// A datagram from an address that the listen grant does not admit gets
	// nothing: the network service drops it before remote.
	{kind = .Remote_Case, text = "stranger"},
	// The connection of the peer lost: remote ends it at its idle bound, in
	// time of the machine, and the next call opens a new connection.
	{kind = .Remote_Case, text = "silence"},
	{kind = .Wait, text = ": the idle end held its bound: "},
	{kind = .Remote_Case, text = "silence ends"},
	// The scenario lists the grant, and revokes it: the services refuse what
	// they give only to a caller that acts for the principal.
	// The developer tool serves its tables to a caller that acts for the
	// principal: the remote service, until the revocation below.
	{kind = .Launch, text = "inspect"},
	{kind = .Wait, text = "inspect: ok, "},
	{kind = .Call, text = "inspect.mappings(\"remote\")", expected = " rows of Mapping"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"remote\")"},
	{kind = .Wait, text = "[console] remote   log                 held"},
	{kind = .Wait, text = "[console] remote   network             held"},
	{kind = .Wait, text = "[console] remote   acts_for_principal  held"},
	{kind = .Type, text = "revoke(\"remote\", \"acts_for_principal\")"},
	{kind = .Wait, text = "root: revoked the grant acts_for_principal of remote, connections changed: 5"},
	{kind = .Call, text = "inspect.mappings(\"remote\")", outcome = .Failed, expected = "error: inspect.mappings: the caller has no grant for this: to act for the principal"},
	{kind = .Call, text = "inspect.threads(\"remote\")", outcome = .Failed, expected = "error: inspect.threads: the caller has no grant for this: to act for the principal"},
	{kind = .Call, text = "inspect.modules(\"remote\")", outcome = .Failed, expected = "error: inspect.modules: the caller has no grant for this: to act for the principal"},
	{kind = .Call, text = "monitor.processes()", outcome = .Failed, expected = "error: monitor.processes: the caller has no grant for this: to act for the principal"},
	// The place of the pointer is a fact of the screen: the
	// tool moves the pointer with no confirmation again.
	{kind = .Call, text = "compositor.pointer()", outcome = .Failed, pointer = true, expected = "error: compositor.pointer: the caller has no grant for this: to act for the principal"},
	// The window of inspect covers the windows under it: it closes now.
	{kind = .Close, text = "inspect"},
	{kind = .Wait, text = "root: inspect stopped: a holder"},
	{kind = .Call, text = "manual.running()", outcome = .Failed, expected = "error: manual.running: the caller has no grant for this: to act for the principal"},
	{kind = .Call, text = "storage.stores()", outcome = .Failed, expected = "error: storage.stores: the caller has no grant for this: to act for the principal"},
	{kind = .Call, text = "manual.modules()", expected = " rows of Module"},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	// The principal revokes the key of the client while its connection is
	// open: remote ends that connection with the code Revoked, and refuses
	// the key in the next handshake with one line of its log. A key that no
	// principal allowed is refused the same way. The two processes write
	// their lines of the revocation in either order.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_disallow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 revoked the client key ", any_order = true},
	{kind = .Wait, text = " of principal 0 ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port "},
	{kind = .Remote_Case, text = "revoked"},
	{kind = .Wait, text = ": no principal allowed it; the handshake ends before any call"},
	{kind = .Remote_Case, text = "unknown client key"},
	{kind = .Wait, text = ": no principal allowed it; the handshake ends before any call"},
	// Three grants of the same key, each ended while no client of it is
	// connected: each end frees the slot of its connection to a service,
	// so the table of connections of remote never fills. Each allow gives
	// the row a new serial, as an unlock does; principal 0 has no lock.
	// remote no longer acts for the principal here (its grant was revoked
	// above), so each round calls an export that needs no such grant.
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	{kind = .Remote_Case, text = "close"},
	{kind = .Type, text = "remote_disallow(\"{client key}\")"},
	{kind = .Wait, text = REMOTE_ONE_SLOT_FREED},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	{kind = .Remote_Case, text = "close"},
	{kind = .Type, text = "remote_disallow(\"{client key}\")"},
	{kind = .Wait, text = REMOTE_ONE_SLOT_FREED},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	{kind = .Remote_Case, text = "close"},
	{kind = .Type, text = "remote_disallow(\"{client key}\")"},
	{kind = .Wait, text = REMOTE_ONE_SLOT_FREED},
	{kind = .Front, text = "remote"},
	{kind = .Shot, text = "remote"},
	// The desktop: the scenario closes remote and manual, the palette starts
	// two processes, and the scenario places four windows. The title bar of
	// the window in front goes from blue to a darker blue; the other title
	// bars are quiet.
	{kind = .Close, text = "remote"},
	{kind = .Wait, text = "root: remote stopped"},
	{kind = .Close, text = "manual"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "lif"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts life"},
	{kind = .Wait, text = "display: life" + WINDOW_TAKEN, any_order = true},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "pla"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts plasma"},
	{kind = .Wait, text = "display: plasma" + WINDOW_TAKEN, any_order = true},
	// The windows move from the one in front to the one at the back: no
	// window covers the title bar of the next one. The console covers the
	// title bar of monitor: monitor comes to the front first. Then each
	// window comes to the front, from the back to the front.
	{kind = .Move, text = "plasma", to_x = 440, to_y = 120},
	{kind = .Move, text = "life", to_x = 8, to_y = 416},
	{kind = .Front, text = "monitor"},
	{kind = .Move, text = "monitor", to_x = 576, to_y = 384},
	{kind = .Move, text = "console", to_x = 8, to_y = 40},
	{kind = .Front, text = "life"},
	{kind = .Front, text = "monitor"},
	{kind = .Front, text = "plasma"},
	{kind = .Shot, text = "desktop"},
	// The list narrows at each key, over the processes and the windows in
	// one ranking. Each name that starts with the typed part has one score:
	// the process that the palette started last comes first, then the
	// window, then the processes in the order of their table. The arrows
	// move the choice.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "p"},
	{kind = .Wait, text = " for \"p\": plasma (module), plasma (window), paint (module), pages (module), ..."},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette chooses plasma (window)"},
	{kind = .Shot, text = "palette"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A part that no name has: the list is empty, and Enter runs nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "xyz"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette has no entry to run"},
	{kind = .Shot, text = "palette_empty"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_no_budget_holds  0 pages"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The machine with no network device: the root service writes its line at
// the first process with an endpoint, refuses a second one with no new
// start of the frame service, and the console still runs.
scenario_no_network_device := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "root: no virtio device for frame at the place 18 of the bus"},
	{kind = .Wait, text = "root: the network service did not start: no process with an endpoint of the network starts until the machine starts again; the other processes start"},
	// A second process with an endpoint: refused with no new start of the
	// frame service, so no second line of the device.
	{kind = .Launch, text = "net"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "1 + 2 * 3"},
	{kind = .Wait, text = "[console] 7", fails_on = "root: the network service did not start"},
	{kind = .Quit},
}

no_network_device_run :: proc(part: ^Test_Part_Run) -> bool {
	if !machine_test(part, scenario_no_network_device[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_NO_NETWORK_DEVICE, exit_status = 0, no_network_device = true}) {
		return false
	}
	// Two starts of net, one line of each: the second start is refused
	// with no new start of the frame service and no new line.
	return lines_once(TEST_OUTPUT_NO_NETWORK_DEVICE, {"root: no virtio device for frame", "root: the network service did not start"})
}

// A binary of the tool runs the test part network only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
network_test_part_register :: proc "contextless" () {
	test_part_scenario_register("network", network_tests_run)
}
