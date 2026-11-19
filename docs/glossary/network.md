## Network

### Network service

The network service is the one client of the frame service: it gives each process with a network grant one endpoint, and it checks each datagram and segment against that grant.

The device of the first machine has one pair of queues, so one process reads its frames: the network service. It enforces the grant of each process: no process has ambient access to the network. It speaks Ethernet, ARP, IPv4 and ICMP echo. For UDP and TCP it checks the ports and the lengths of each header and keeps no state of a connection. The root service starts it with the first process that has a network grant. It is not a network stack: it has no sockets, no retransmission and no routing table.

The design: `docs/NETWORK.md`, "The parts".

Do not use: network stack, TCP/IP stack, netd, network daemon.

### Data path

The data path is the code that reads or writes the bytes of the data that a process sends or receives through a device.

The term asks one question: does this code touch the bytes? The kernel is off the data path: no kernel entry carries data. One read or one write of each byte by one process is a pass: a copy is a pass, and so is a checksum. Example: the network service makes one pass on receive, the copy into the datagram region, and none over the data on send. The data path is not the control path of a packet, which reads only the headers.

The design: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: fast path, hot path (for this).

### Control path of a packet

The control path of a packet is the code that reads the headers of a datagram or a segment and decides where it goes, and that reads no byte of its data.

A packet, in this term only, is the IPv4 packet that a frame carries: one datagram or one segment with its headers. When processes share one device, one process must read the ports of each packet, find the endpoint and check the grant. That work costs code and no pass over the data. Example: the network service is on the control path of each datagram and segment. It is not the data path, and not the control plane of the kernel, which runs no code for a packet.

The design: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: slow path, packet path.

### Endpoint

An endpoint is what a process holds to send and receive datagrams or segments: a datagram ring and a datagram region, with a grant that names what it can reach.

An endpoint replaces the socket of other systems, but the process does not choose its remote. The root service names the grant, and the network service enforces it: a request to another remote fails with `Not_Granted`, and what another remote sends never reaches the process. An endpoint is a datagram endpoint (UDP) or a segment endpoint (TCP), each with a client grant or a listen grant. A process has one. The console shows its grant with `grants` and ends it with `revoke`. An endpoint is not a connection.

The design: `src/library/contract/datagram`.

Do not use: socket, port (for this), connection (for this).

### Datagram

A datagram is one UDP datagram: its header of 8 bytes and its data, 1472 bytes of data at most, what a process sends and receives through a datagram endpoint.

1472 bytes is the data of one Ethernet frame after the IPv4 and UDP headers, so a datagram is never a fragment. The process writes the whole datagram in a place of its datagram region, with the header and its checksum (`network.udp_header_write`), and sends it with `Send`. The network service checks the ports in its own copy of the header, and the device reads the rest from the place. Example: QUIC is a library in the process over datagrams. A datagram is not a frame and not a segment.

The design: `src/library/contract/datagram`.

Do not use: packet, message.

### Remote

A remote is the IPv4 address and the UDP port or TCP port at the other end of a datagram or of a connection.

A grant names remotes: a client grant names one, and a listen grant admits the remotes that came to it. A command of the datagram ring names a remote by its address and its port. An error record of `Not_Granted` holds the remote of the request and the remote of the grant. Example: the remote of the client grant of `fetch` is 10.0.2.100 port 80. A remote is not the host, which is the computer that runs QEMU, and not the peer, which is one part of the modus tool.

The design: `src/library/contract/datagram`.

Do not use: peer (for this), destination, host.

### UDP port

A UDP port is the 16-bit number of UDP that names one endpoint at an address.

The network service finds the endpoint of a datagram that arrives by its destination port. With a client grant, the network service gives the local port, and the command `Info` returns it. The process writes that port as the source port of each datagram, and the network service refuses another one. A listen grant names its port: the remote service listens on the UDP port 7100. A UDP port is not the Ports object of the kernel, and not a TCP port: one number names two different ports in UDP and in TCP.

The design: `src/library/contract/datagram`.

Do not use: port (alone), socket number.

### TCP port

A TCP port is the 16-bit number of TCP that names one end of a connection at an address.

The network service reads the TCP ports of each segment to find the endpoint and check the grant: a client grant has a block of 64 local TCP ports, and a listen grant has one. The process writes the ports in its header, and the network service checks the local port of each segment that leaves in its own copy of the header. Example: `server` has the listen grant of the TCP port 80. A TCP port is not the Ports object of the kernel, and not a UDP port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: port (alone), socket number.

### Segment

A segment is one TCP segment: its header, its options and its data, 1480 bytes at most, what a process sends and receives through a segment endpoint.

1480 bytes is the room of one Ethernet frame after the IPv4 header, so a segment is never a fragment. The TCP library of the process writes each segment in a place of the datagram region, with its checksum, and the process sends it with `Send`. The network service checks the ports and writes the IPv4 header. For a segment that arrives, the TCP library checks the checksum and drops a wrong one. A segment is not a datagram and not a packet: the process sees no IPv4 header.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: packet, TCP packet, message.

### Segment endpoint

A segment endpoint is an endpoint whose grant has the protocol TCP: the process writes and reads whole segments, and the network service keeps no state of a connection.

A segment endpoint puts TCP in the process: each connection is in its own memory. The ring, the region, the commands and the error records are those of a datagram endpoint; only the grant differs, with TCP ports, and a block of them for a client grant. The process drives it with the TCP library: `tcp.step` takes the segments that arrived and writes the segments to send. Example: `server` has one. A segment endpoint is not a TCP socket: it is not one connection, and it does not accept or connect.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: TCP socket, listening socket.

### Client grant

A client grant is the grant of an endpoint that reaches one remote: one remote address and one remote port.

A client grant lets a process reach exactly one server. The network service refuses a request to another remote with `Not_Granted`, and drops what another remote sends. With a datagram endpoint, the process gets one local UDP port. With a segment endpoint, it gets a block of 64 local TCP ports, because a closed connection stays in TIME-WAIT. Example: `fetch` has a TCP client grant of 10.0.2.100 port 80. A client grant is not a rule of a firewall: it is the only remote that the endpoint can name.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: outbound rule, connect permission.

### Listen grant

A listen grant is the grant of an endpoint that receives on one local TCP or UDP port that the root service names, from any remote, and answers only the admitted remotes.

A server must receive from remotes that it does not know in advance, but must not reach a machine that did not come to it. With a listen grant, the process answers, but it does not reach: a send to a remote that is not admitted fails with `Not_Granted`. A UDP listen grant can also name one remote address. Examples: `server` on the TCP port 80; `remote` on the UDP port 7100, for the address 10.0.2.2 only. A listen grant is not a listening socket: it accepts nothing.

The design: `docs/NETWORK.md`, "The listen grant of UDP".

Do not use: listening socket, bind permission, server socket.

### Admitted remote

An admitted remote is a remote that came to the port of a listen grant, and that the process can therefore answer.

A remote becomes admitted when it sends a SYN to the TCP port of a listen grant, or a datagram of 1200 bytes at least to its UDP port, while a `Receive` of the endpoint waits. The process releases one with `Release` when its connection ended, and a place with no traffic for 120 s serves again. The table of admitted remotes is the one state of TCP in the network service. An admitted remote is not an entry of connection tracking: it is one address and one port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: connection tracking entry, conntrack, NAT entry.

### Connection

In the group Network, a connection is the state of one TCP connection in the process that owns it: one record of fixed size of the TCP library, `tcp.Connection`.

TCP is a library in the process, so the state of each connection is in the memory of the process. The record holds the state, the sequence numbers, the windows, the timers and the counts. The process reads each field with no call; `server` draws them. The records are the rows of a connection table: `tcp.connect` opens one actively, and a SYN to the listen port opens one at the next `tcp.step`. A TCP connection is not the connection of the group Communication, and not a socket: no handle names it.

The design: `docs/NETWORK.md`, "The TCP library".

Do not use: socket, TCB (in this system), session.

### Web page

A web page is an object of the private store of `server` that `server` serves by its name, at the target `/name`.

`server` shows that a process reaches only what it was granted: its pages come from its own private store, not from a shared folder. The principal changes them from the console through the exports of `server`, such as `server.put` and `server.remove`. `server` reads its pages into its memory at its start, so a request never waits for the storage service. PUT and DELETE over HTTP are refused, because the network is not authenticated. A web page is not a file of a web root: it has no path and no folder.

The design: `docs/NETWORK.md`, "The HTTP server".

Do not use: file (for this), static file, asset.

### Access record

An access record is the record of one request that `server` answered: the remote, the method, the target, the status, the bytes of the body and the time.

The access records let the principal see the traffic of the server with no text log to parse. `server` keeps the last ones in its window, and writes one log record for each request on its log channel `requests`. The time runs from the first byte of the head to the last byte of the answer in the send buffer. Example: "server: GET /hello.html 200, 12 bytes, 157 us, 10.0.2.2 port 49200". An access record is not a line of an access log in a common format: it is a record of fixed size.

The design: `src/modules/demonstrations/server`.

Do not use: access log line, hit.

### Connection table

A connection table is the connection records of one process, the memory of their buffers, and what is common to them: the local address, the listen port, the block of local ports and the secret of the initial sequence numbers.

The TCP library allocates nothing: the caller gives the table (`tcp.Table`) with its records and one block of memory for all the buffers. One call, `tcp.step`, works on the whole table: it takes the segments that arrived, runs the timers, writes the segments to send, and gives the next deadline. The table also counts what no connection took, such as the SYNs refused. Example: `server` serves one table of 48 connections from one thread. A connection table is not a pool of sockets in a kernel.

The design: `docs/NETWORK.md`, "The form of the interface".

Do not use: socket table, connection pool.

### Datagram ring

The datagram ring is the ring between a process and the network service for one endpoint.

Its commands, in `src/library/contract/datagram`:

- `Send` and `Receive`: a datagram, or a whole segment.
- `Info`, `Statistics` and `Problems`: the facts, the counts and the refused frames.
- `Resolve` and `Echo`: ARP and ICMP echo.
- `Release` and `Validate`: for a listen grant.

Many requests are in flight. A `Receive` stays in flight until a datagram arrives, and the network service drops a datagram when no place waits. A refused request has an error record. A datagram ring is not a socket: a request names a place in the datagram region, never an address.

The design: `src/library/contract/datagram`.

Do not use: socket, channel.

### Datagram region

The datagram region is the memory of an endpoint, 512 KiB, where the process writes the data to send and the network service writes the data that arrives.

The root service makes the region and gives it to the process and to the network service. A process does not give a region of its own: if it did, a revocation of that memory stops the network service on a page fault. A request names a place in bytes; a byte outside gives `Out_Of_Range`. The device reads the data to send from the region, a read region of the frame service, and the `Send` completes when the device read it. A datagram region is not a socket buffer of a kernel.

The design: `docs/NETWORK.md`, "The send with no copy".

Do not use: socket buffer, send buffer, receive buffer.

### Neighbor

A neighbor is an address of the link and its hardware address, which the network service learned from an answer to its own ARP request.

A frame needs the hardware address of the next machine on the link. The network service asks it by ARP and keeps the answer in a table of neighbors. It learns only an address that one of its own requests asked, so an ARP frame that nobody asked for changes nothing. When the table is full, the answer replaces the oldest entry that no waiting request uses. A process asks for a new resolution with the command `Resolve`. A neighbor is not an entry of a cache that each ARP frame of the link can change.

The design: `src/library/support/network`.

Do not use: ARP cache entry, neighbour entry.

### Gateway

The gateway is the machine of the link that carries IPv4 packets to other networks: 10.0.2.2 on the first machine.

The network service sends each datagram whose address is not on its link (10.0.2.0/24) to the hardware address of the gateway. With the network of the tests, the gateway is the peer of the modus tool; with the user network of QEMU, it is libslirp. The host reaches the machine from the address of the gateway, so the listen grant of the remote service admits that address only. The gateway is not a routing table: the network service has one route.

The design: `docs/NETWORK.md`, "The parts".

Do not use: router, default route.

### Peer

The peer is the part of the modus tool that is the gateway and the echo server of the network of the test machine, a TCP client that the tool drives, and the QUIC client of the remote service.

The peer makes the network tests closed and repeatable: no frame leaves the host, and each run has the same answers. It reads each frame with its own code, so a fault of the network service in a checksum or a length is a fault that the peer sees. It sends frames that the network service must refuse, and can drop, reorder and repeat the frames of TCP. The peer is not a simulator of a network: it speaks the real protocols. It is in `tools/modustool/machine/peer.odin`.

The design: `docs/NETWORK.md`, "With the controlled peer".

Do not use: mock, fake server, simulator.

### Host

The host is the computer that runs QEMU and the modus tool; the system does not run on it.

The host builds the system, starts the machine, and drives the tests. For the network of the machine, the host is at the address of the gateway, 10.0.2.2: the peer of the tool answers for it, and each call of the tool to the remote service comes from that address.

The host is not the machine: the machine is the computer, real or emulated, that runs the system. The host is not a remote either: a remote is any address and port at the other end of a datagram.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: build machine (for this), remote (for this).

### Remote service

The remote service is the process `remote`: a QUIC server that takes each call of the host on a call stream, makes it as an isolated call of an export of a service, and writes the call answer on the same stream.

The remote service lets the modus tool on the host call an export of a running service, for tests and for the console of the developer. It has a UDP listen grant on the port 7100 that admits the address of the host only. It makes an Ed25519 key at its start and logs it, and the tool pins that key. A call acts for the principal that allowed the key of the client. The remote service is not a debug agent: it calls only exports.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: RPC server, debug agent, gdbstub.

### Call socket

The call socket is the Unix socket where the peer of the modus tool takes the calls of the tool to the remote service, one connection of the socket for each call.

The call socket keeps the calls on the host to one user: it is in a folder of that user with no right for the group and the others. `modustool run` takes the socket `calls-run.socket` and prints its path, and `modustool call` finds it by the same rule. On a connection, the tool writes a header with the key to pin, then the call request; the peer writes the outcome and the call answer. The call socket is not a port of the network: no other machine reaches it.

The design: `docs/QUIC.md`, "The client of the tool".

Do not use: call port, loopback port (for this).

### Call stream

A call stream is one bidirectional QUIC stream of a connection to the remote service that carries one call: the call request from the host, then the call answer from the remote service.

The stream names the call: no number in a header matches an answer to its request. The host writes the call request and ends its direction; the remote service makes the call, writes the call answer and ends its direction. QUIC sends a lost datagram again, so the host never sends a call again: a call whose answer did not come can have run. A call that fails ends its stream with a stream error code, and the other calls go on. A call stream is not a channel of many calls.

The design: `docs/QUIC.md`, "One call, one stream".

Do not use: RPC channel, request stream (for this).

### Stream error code

A stream error code is the application error code of a RESET_STREAM, a STOP_SENDING or a CONNECTION_CLOSE of the remote service: a value of `remote.Stream_Error`, which the tool prints by its name.

The values are `Too_Large` (1), a request of more than `REQUEST_LIMIT` bytes; `Timeout` (2), a bound of time that passed; and `Cancelled` (3), a stream that the host ended before the call. A request that does not pass its check gets no stream error code: it gets a call answer with the status Refused and its error record. A stream error code is not a status of a call and not an error number: it says why the transport of one call ended.

The design: `docs/QUIC.md`, "Errors and ends of a call".

Do not use: status (for this), error number.

### Call request

A call request is the bytes of a call stream from the host to the remote service: a fixed header, `remote.Request`, then the bytes of the call region from offset 0.

The header names the service, the BLAKE3 hash of its module and the index of the export. The host encodes the arguments with the description of the export. The remote service trusts nothing in a request: `remote.request_check` checks each count and each place against the bytes of the stream and the size of the call region. A refusal is a call answer with the status Refused. A call request is not a message with names in text: it names the export by its index and the module by its hash.

The design: `docs/MODULE_CONTRACT.md`, "A call from the host".

Do not use: RPC request, message, packet.

### Call answer

A call answer is the bytes of a call stream from the remote service to the host: a fixed header, `remote.Answer`, then the bytes of the result.

The header has 112 bytes: the status, the integer result, the error record, and the count of the bytes of the result that follow (`total`). The host trusts nothing in it: `remote.answer_check` checks that the bytes are exactly a header and its total, and that the status names a member. The host decodes the result with the description of the export and prints it. The answers come back in any order; the host matches each one to its call by its stream. A call answer is not a response of HTTP: it has no headers of text.

The design: `src/library/contract/remote`.

Do not use: response, reply.

### Developer tool

A developer tool is a process that shows how the system runs: what a process holds in memory and how its threads run; it reads reports of the kernel with a grant and changes nothing.

A developer tool makes the state of the kernel visible with no debugger attached. Each tool reads reports with the operation `Inspect`, with the machine handle and the right **Inspect**. Examples: `monitor` shows the counts of each process, `scheduler` the run queues, and `inspect` the address space and the threads of one process. Each tool also serves its facts as exports, so the console reads them as tables, such as `monitor.processes()`. A developer tool is not a debugger: it does not stop a thread or read the bytes of another process.

The design: `docs/TOOLS.md`, "What each tool reads".

Do not use: debugger (for this), profiler, task manager.

### Sample

A sample is one read of all the reports that a developer tool shows, at one time.

A developer tool reads several reports, and the system runs between two reads. A sample groups them so that the window shows one state. `inspect` takes a sample each 250 ms, and shows the time and the kernel entries of one sample, so the cost of the tool is visible. A sample whose reports come from two processes of one slot is dropped. A value that changed since the last sample has another color. A sample is not a snapshot of the store, and not a frame of the screen.

The design: `docs/TOOLS.md`, "The process `inspect`".

Do not use: snapshot (for this), poll, frame (for this).

### Sample history

A sample history is the values of one measure in the last samples of a developer tool, kept in the process that shows them.

The monitor keeps one for each of its graphs: 120 values, the last minute at one sample each 500 ms, in a fixed array whose newest value replaces the oldest one. At each push it computes the top of the scale and the points of the curve, and keeps them, so a frame computes nothing over the samples. It is not the line history of the console, and not a measure history of the releases.

The design: `src/md/features/monitor_window.md`, "The sample history".

Do not use: history (alone), time series, ring (for this).

### Sample graph

A sample graph is the curve of one sample history over the grid of points, with the name of its measure and its scale at its left.

The newest sample is at the right edge, and each older one a step to the left: a step is a sample, not a time. The vertical scale is fixed (all the memory, 100 %) or the largest value of the sample history rounded up to 1, 2 or 5 times a power of ten. The monitor draws three: the memory in use, the processor time and the kernel entries in one second. It is not a measure chart of the site.

The design: `src/md/features/monitor_window.md`, "The sample graphs".

Do not use: chart (for this), sparkline, plot.

### Folded gap

A folded gap is the part of the band of an address space between two mappings that has no mapping: the band draws it with a fixed width and lines at an angle.

On a scale by address, the small mappings of a process would be invisible lines. `inspect` folds each gap, so each mapping keeps a readable width. The element `draw_folded_gap` of the interface package draws it as a rectangle and two lines: it is no kind of draw record.

A folded gap is not an ellipsis of a text: it is a part of a drawn band, and its width says nothing of its size.

The design: `docs/TOOLS.md`, "The process `inspect`", and `docs/DESIGN.md`, "2. Forms".

Do not use: ellipsis, break.

### Near export

A near export is the export of a module with the highest address at or below an address: a reader names the address "module + offset, near name".

A module names its exports only. With no debug image, a frame of a stack trace in a function that is not an export has no name of its own. The near export gives it the name of the export before it, as a hint, with the offset from the module. With a debug image, a frame has the name of its procedure and its source line. A near export is not a symbol: it is an export, and it can be far from the real function.

The design: `docs/TOOLS.md`, "Names and lines".

Do not use: symbol (for this), nearest symbol.

### Confirmed place

A confirmed place is a place of the pointer that the modus tool read from the compositor before a press, through the remote service.

A press must land where the step wants it, and the tool does not trust its count of the moves that it sent to QEMU. So, in a machine test, the tool calls `compositor.pointer()` before each press, and moves the pointer again from the place that the compositor gives, a few tries at most. Before the remote service runs, the tool does not confirm the place. A confirmed place is not a move of the pointer by the system: the compositor only reports where the pointer is.

The design: `docs/TOOLS.md`, "How the tool sends input and waits".

Do not use: pointer sync, warp.
