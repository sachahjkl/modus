## QUIC

### Connection identifier

A connection identifier is the 0 to 20 bytes by which a QUIC endpoint names a connection in each packet, independent of the addresses.

UDP gives no connection, and its addresses and ports can change on the path. So each QUIC packet carries a Destination Connection ID, and the receiver finds its connection by it. Each side chooses the identifiers that the other side sends to it: a client of this system chooses 8 bytes, the OpenSSL client 0 bytes. A server of this system finds the connection by the identifier and the remote together. In the library an identifier is one record, `quic.Connection_Identifier`, of at most 20 bytes.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: connection ID (in prose), CID.

### Packet protection

Packet protection is the AEAD that encrypts the payload of a QUIC packet and authenticates its header, with the key and the iv of one direction of one encryption level.

Each QUIC packet is sealed on its own: the nonce is the iv with the packet number, and the additional data is the header without header protection. Initial packets use AES-128-GCM; after the handshake this system prefers ChaCha20-Poly1305. `quic.datagram_take` copies each datagram once into private memory, and each later step works on that copy. A tag that does not verify gives `Not_Authentic`. It is not the record layer of TLS over TCP: QUIC carries the handshake in CRYPTO frames and protects whole packets.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: encryption (for this), record protection.

### Header protection

Header protection is the mask that hides the low bits of the first byte and the packet number of a QUIC packet, made from a sample of the protected payload.

Without it, an observer reads the packet numbers and the key phase of every packet. The mask is 5 bytes, from AES or ChaCha20 over a sample of the protected payload. The cryptography module exports the two masks, and `src/library/support/quic` applies them to the first byte and the packet number. The receiver removes it first (`header_protection_remove`), with a key that does not change at a key update, then reads the key phase and chooses the keys for the open.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: header encryption.

### Encryption level

An encryption level is one of the sets of keys of a QUIC connection: Initial, Handshake or Application.

The handshake moves through the levels, and each packet type uses one level. Any observer can compute the Initial keys from the connection identifier; the Handshake keys come from the handshake secrets of TLS, and the Application keys from its application traffic secrets. `quic.Encryption_Level` names the three, and the CRYPTO frames of each level carry their own sequence of handshake bytes. The Initial keys go when the client sends its first Handshake packet; the Handshake keys go when the handshake is confirmed. This system has no 0-RTT level.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: epoch, key phase (for this).

### Packet number space

A packet number space is the sequence of packet numbers that one encryption level uses: Initial, Handshake or application data.

Each space has its own packet numbers, its own acknowledgements, its own set of received numbers and its own packets in flight. A packet number is unique in its space and never used again. An ACK frame acknowledges numbers of the space of its packet only. The packet number floor of a space refuses numbers that the set of received numbers forgot.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: sequence number (for this).

### Initial packet

An Initial packet is one of the first packets of a QUIC connection, protected with keys that any observer can compute from the connection identifier, which carries the start of the TLS handshake.

The keys of an Initial packet authenticate nothing: they come from a public value with a fixed salt of version 1, so anyone can make an authentic Initial. A server of this system therefore takes a client only after the client came back with the token of a Retry packet, and an Initial that does not complete its handshake ends at the handshake deadline. A datagram with a client Initial is padded to 1200 bytes, and a server drops a client Initial in a smaller datagram.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: handshake packet (for this).

### Raw public key

A raw public key is a public key that a TLS peer sends in its Certificate message alone, with no certificate around it.

The server sends the SubjectPublicKeyInfo of its Ed25519 key, 44 bytes, and the client offers `server_certificate_type` with the one type RawPublicKey. No X.509 certificate is read: a parser of certificates is a large parser of hostile input, and the system has no certificate authority, no name and no date to check. The client trusts the key only when it is the pinned key, and CertificateVerify proves that the server holds its private key. A client proves its own key the same way when the server asks for it.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: self-signed certificate (for this).

### Pinned key

The pinned key is the one public key that the caller of a TLS client gives it as the key of the server: the client refuses any other key.

`Tls_Configuration.server_public_key` holds it. A server that presents another key fails the handshake with the alert bad_certificate, and `tls_start` refuses a client with no pinned key. The peer of the modus tool pins the key that `remote` wrote on its log. A pin belongs to one start of the server: each start makes a new key. A pinned key is not a trust anchor: it vouches for no other key and names no one.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: trust anchor, root certificate.

### Transcript

The transcript is the handshake messages of TLS, in order, whose hash the key schedule and the Finished messages use.

Each message of each side goes into the transcript as it comes. The key schedule hashes it at fixed points to derive the secrets, CertificateVerify signs its hash, and each Finished is an HMAC of it. So a change of one byte of one message by the path makes the two sides disagree and the handshake fail. The transcript holds 8192 bytes: a ClientHello of up to 4092 bytes and the flight of the server.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: handshake hash (for the bytes).

### Key schedule

The key schedule is the chain of the secrets of TLS 1.3, each one derived from the one before with HKDF and a transcript hash: early, handshake, master, and the traffic secrets of each side.

The X25519 shared secret enters at the handshake secret; the hash of the transcript at each point binds the secrets to the messages. QUIC takes its packet keys from the traffic secrets: `tls_packet_keys` gives the Handshake and the Application keys through `packet_keys_from_secret`, with the labels "quic key", "quic iv" and "quic hp". The code is `src/library/support/quic/tls_key_schedule.odin`, tested against the trace "Simple 1-RTT Handshake" of RFC 8448. The secrets of TLS are erased once the 1-RTT keys are installed.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: key derivation (for the whole).

### Alert

An alert is the reason of a failure of TLS, as one byte.

The handshake of this system writes the alert in `Tls_Handshake.alert` and in the `found` field of its error record. QUIC has no alert messages: it closes the connection with the error code 0x100 + alert. Examples: bad_certificate (42) for a key that is not the pinned key, unexpected_message for a message of the wrong type at its level, no_application_protocol for another ALPN.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: TLS error (for this).

### Frame

A frame is one unit of the payload of a QUIC packet: a type, then its fields.

A packet carries one frame or more: STREAM frames with the data of a QUIC stream, ACK frames, CRYPTO frames with the bytes of the handshake, CONNECTION_CLOSE, and others. Each frame is read as hostile input, with each length checked first: a frame that is cut or of an unknown type is FRAME_ENCODING_ERROR. It is not the frame of the network device (an Ethernet frame), which the group "Devices" defines: a QUIC frame lives inside a protected packet inside a UDP datagram.

The design: `docs/QUIC.md`, "The frames".

Do not use: message (for this), chunk.

### Ack-eliciting packet

An ack-eliciting packet is a packet with a frame other than PADDING, ACK and CONNECTION_CLOSE, which the peer must acknowledge.

Only ack-eliciting packets count for loss detection, the probe timeout and the congestion window: a packet of ACK frames alone is never acknowledged and never sent again. In the 1-RTT space this side sends an ACK after 2 ack-eliciting packets or 25 ms. The first ack-eliciting packet sent after a receive moves the bound of the idle timeout.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reliable packet.

### Probe timeout

The probe timeout is the time after which a side that received no acknowledgement sends one or two probe packets, computed from the round-trip time and its variation.

The base probe timeout is the smoothed round trip, 4 times its variation and the max_ack_delay of the peer: about 28 to 45 ms on a fast network. A probe carries the data of the oldest packets in flight, or a PING, and goes past the congestion window. The timeout doubles at each probe that nothing answers. The idle timeout and the closing and draining states use the base value with no doubling (`probe_timeout_base`), so a vanished peer cannot keep a record for hours.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: retransmission timeout, RTO (for this).

### Congestion window

The congestion window is the most bytes of ack-eliciting packets that a side has in flight at one time.

It stops a sender from filling the path faster than the path drains. This layer keeps it fixed at 12 000 bytes (`CONGESTION_WINDOW`), the initial window of RFC 9002: it does not grow and does not shrink after a loss (no NewReno, no pacing). Probes go past it.

It is not the flow control limit: the congestion window protects the path, and the flow control limit protects the buffers of the receiver.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: send window (for this).

### QUIC stream

A QUIC stream is one ordered flow of bytes in each direction inside a QUIC connection, named by a stream identifier.

A connection carries several streams at once, and the bytes of one never wait for a loss of another, which TCP cannot give. This system has bidirectional streams only, and only the client opens them. A stream ends when both directions ended, and its identifier then never names a stream again. A program uses `stream_open`, `stream_write`, `stream_read`, `stream_reset` and `stream_stop_sending`; each stream lives in a stream record. Example: `remote` maps one call to one stream.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: channel (for this), substream.

### Stream record

A stream record is one `quic.Stream` in the table that the caller of a QUIC connection gives: the state and the buffers of one open QUIC stream.

The caller allocates the table, in its own memory, with the connection; each record holds two buffers of 64 KiB. Their count bounds the streams that are open at one time, and a server gives the client a limit of streams equal to its records. When a stream ends, its record is free again and its buffers are written with zeros. A program must read each stream to its end: a stream that it never reads keeps its record for the life of the connection.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: stream slot.

### Limit of streams

The limit of streams is the count of QUIC streams that one side allows the other to open since the start of the connection (MAX_STREAMS).

It is a count since the start, not a count of open streams. A server of this system gives the client a limit equal to its stream records, then raises it by one with a MAX_STREAMS frame each time a stream of the client ended, so the limit never promises a stream that has no record. A client that reaches the limit sends STREAMS_BLOCKED and waits; a frame for a stream past the limit is STREAM_LIMIT_ERROR. Example: a host that opens a 9th stream of `remote` waits for MAX_STREAMS.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: stream credit, concurrency limit (for this).

### Implicit open

An implicit open is the open of a QUIC stream by a frame of the peer that names it, or names a higher stream of the same kind, before the peer sent anything on it.

Streams of one kind open in order, so a frame for client stream 8 also opens the client streams 0 and 4 that are not open yet. The limit of streams bounds that count: a stream far ahead within the limit takes records that exist, and one past it is STREAM_LIMIT_ERROR. The program finds the streams that the peer opened by a walk of `connection.streams`.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Flow control limit

A flow control limit is the largest offset of data that a side allows the peer to send, for one stream (MAX_STREAM_DATA) or for the whole connection (MAX_DATA).

It protects the buffers of the receiver: a side never receives more than it has room for. Here each stream has 64 KiB, moved forward when the application read half of it; the connection has the buffers of every stream record (256 KiB for 4), moved forward the same way. Data past a limit closes the connection with FLOW_CONTROL_ERROR; a final size that changes is FINAL_SIZE_ERROR. A reset counts its final size, and the bytes that the application never read give their room back to the connection.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: receive window (for this).

### Anti-amplification limit

The anti-amplification limit is the rule that a server sends at most 3 times the bytes that it received from a client whose address it did not validate.

An attacker can forge the source address of a datagram, and without the limit one small forged datagram can make a server send a large answer to a victim. The limit is held twice: by `src/library/support/quic` in the program, until the address validation of the connection, and by the network service, which knows no QUIC and refuses a Send past 3 times (the status `Amplification`) until the program sends the command `Validate`. A Retry packet answers a datagram of 1200 bytes with at most 113 bytes.

The design: `docs/QUIC.md`, "The listen grant of UDP".

### Address validation

Address validation is the proof that a client receives datagrams at the address that it claims.

Until it, a server holds the anti-amplification limit. A connection of this system validates the address of the client by a Handshake packet of the client, which needs the keys of the flight of the server, or by an Initial that carries the retry token of that address. Each record of `quic.Server` is validated at its start, because a record needs a token. The program then sends `Validate` to the network service for that remote, which makes it a validated remote.

The design: `docs/QUIC.md`, "The server of several connections".

### Handshake confirmed

Handshake confirmed is the point after which a side drops its Handshake keys: a server when its handshake completes, a client when HANDSHAKE_DONE comes.

Before it, a side can still need the Handshake keys to send the flight again. After it, those keys are erased, and a Handshake packet is dropped. A server sends HANDSHAKE_DONE in its first 1-RTT packet after the Finished of the client; a server that receives one gets PROTOCOL_VIOLATION.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake done (for the state).

### Connection record

A connection record is one `quic.Connection` in memory of the program: all the state of one QUIC connection.

The record holds the packet number spaces, the keys, the handshake of TLS, the timers and the connection identifiers: no allocation and no kernel call happen behind it. Its streams are in a separate table of stream records. A record goes in global memory or in a mapping, never on a stack, which leaves too little room for the cryptography module. A server holds a table of records, and a record gets a new generation each time it is taken. It is not a socket: the network service sees only datagrams.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: session (for this), socket.

### Version Negotiation packet

A Version Negotiation packet is the packet with the version 0 that a server sends to a client whose long header names a version that the server does not speak: it lists the versions that the server speaks.

A server of this system speaks version 1 only. It answers a long header of another version in a datagram of 1200 bytes at least, with one packet of 51 bytes at most, and 16 in one second at most. The packet has no authentication; a client of this system speaks version 1 only and never needs one.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: version error.

### Retry token

A retry token is the value that a server gives in a Retry packet and that the client sends back in its next Initial packet, to prove that it receives datagrams at its address.

The server seals with ChaCha20-Poly1305, under a key of its start, the original Destination Connection ID of the client, the identifier of the Retry and the time, with the remote address and port as additional data. The token does not open for another address or port, after another start of the server, or more than 10 s after the Retry. A token takes a record once. It is not the token of NEW_TOKEN, which a client of this system never keeps, and not a token of a token bucket.

The design: `docs/QUIC.md`, "The token of a Retry".

Do not use: cookie (for this), address token (for the token of NEW_TOKEN).

### Validated remote

A validated remote is an admitted remote of a UDP listen grant that the program marked with the command `Validate`, because it proved its address.

The network service then sends to it with no limit of 3 times the bytes that came from it. `quic_echo` and `remote` validate a remote when its client came back with the token of a Retry. A program that validates every remote can send any volume, for 120 s, to an address whose name came in one forged datagram; the principal revokes the grant of such a program.

The design: `docs/QUIC.md`, "The listen grant of UDP".

Do not use: trusted remote, whitelisted address.

### Stateless reset

A stateless reset is a packet that ends a connection whose state a side lost, proven by a token that the side gave before.

It is not built. A server of this system that restarts forgets its connections, and their clients end at their idle timeout. A connection drops a datagram of this kind.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reset (for this).

### Handshake deadline

The handshake deadline is the time after which a connection whose handshake did not complete ends: 10 s from the start of a client, or from the first authentic Initial at a server.

Anyone can make an authentic Initial packet, so without a deadline a few packets could hold records of a server for the whole idle timeout. `HANDSHAKE_TIME_LIMIT` ends such a record whatever the idle timeout. A client has the same limit: a client that a server over a limit ignores ends at its own deadline. The deadline counts time of the machine: in `remote`, isolated calls count in it too.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake timeout (for the value).

### Packet number floor

The packet number floor is the packet number below which a side refuses each packet of a space, because its set of received numbers forgot those ranges.

The set of received packet numbers keeps 32 ranges. When it drops its lowest range, it can no longer tell whether a number below it came before, so it raises the floor to the end of that range (`packet_number_floor` of a space). A packet below the floor is refused before its open, so that no packet is processed two times.

It is not a replay window of a fixed width: it moves only when the set loses a range.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: replay window.

### Idle timeout

The idle timeout is the time with no activity of the peer after which a side ends a QUIC connection with no packet: the smaller of the values that the two sides give, and 3 base probe timeouts at least.

It frees the record of a peer that vanished. The activity that moves its bound is a packet received, processed and recorded, and the first ack-eliciting packet sent after it; a datagram that does not authenticate moves nothing. A server of this system always has one: `server_init` refuses an idle timeout of 0. `quic_echo` uses 30 s, and logs at each idle end whether the end held its bound. It is not a keep-alive: this side sends nothing to keep a connection open.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: keep-alive.

### Closing state

The closing state is the state of a side that sent CONNECTION_CLOSE: for 3 base probe timeouts, it answers datagrams of the connection with its close.

The close can be lost, so the side answers again when the peer sends more. A record of this system answers the 1st, 2nd, 4th, 8th... datagram, not each one, and does not open them: a third party that knows the identifier makes at most a few packets of about 50 bytes.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

### Draining state

The draining state is the state of a side that received CONNECTION_CLOSE: it sends nothing for 3 base probe timeouts, then ends the connection.

It lets the packets of the peer that are still on the path arrive and be dropped, with no answer.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Transport parameters

The transport parameters are the values that each side of QUIC gives the other inside the TLS handshake: its limits, its timeouts and the connection identifiers that it used.

They ride in the extension `quic_transport_parameters`, so the handshake authenticates them. Examples: the flow control limits, the limit of streams and the idle timeout. Each value of the peer is checked: a repeated parameter, a value out of its range or an identifier that is not the one of the packets gives TRANSPORT_PARAMETER_ERROR. A side writes its own from a record that has a field only for each parameter that the system sends, so no value that it sets is lost. They are not settings of the system: they belong to one connection.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: settings.

### Retry packet

A Retry packet is a packet of a server that asks the client to send its Initial packet again with a retry token, to prove its address.

A server of this system answers each Initial with an unknown identifier and no token with a Retry, and keeps nothing: no record, no key, no open of the Initial. Its integrity tag, with a fixed key of version 1, proves to the client only that the Retry answers its own Initial. A client takes one Retry, before any Initial of the server, then derives its Initial keys from the identifier of the Retry and sends its ClientHello again with the token.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: redirect.

### Table of address budgets

The table of address budgets is the table of a QUIC server that holds a budget of Initial checks for each address whose retry token opened.

A host with one real address can take one Retry and then send many Initials with its valid token that do not open, each with about 30 µs of cryptography. So each address gets its own token bucket of Initial checks. A new address takes a place only when the place holds no information: free, or its bucket full again. So the table gives at most the sum of its buckets, and addresses that rotate through it spend at most half of the shared budget.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: address cache.

### Budget of work

A budget of work is the most pieces of one kind of work that a QUIC server does for datagrams of unknown identifiers, as a token bucket.

That work is cryptography for a sender that nobody checked yet. The server has three shared budgets: Retries, token checks, and Initial checks with a valid token. A datagram over a budget is dropped before any cryptography. The datagrams of known records have no budget and come first. A flood above a shared budget still stops new clients while it lasts. It is not a budget of the kernel: a budget of memory pays for kernel objects, and a budget of work bounds time spent by one program.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: rate limit (for this), quota.

### Token bucket

A token bucket is a count of units that grows by a rate in each second up to a depth, and from which each piece of work takes one unit.

A burst takes the depth at once, then the rate, so no boundary of a window lets a burst get the budget of two seconds in one millisecond. `quic.Work_Bucket` counts millionths of a unit, so a rate per second adds its value in each microsecond, and a bucket that was never used starts full. The budgets of work and the table of address budgets are token buckets. The tokens of a bucket are units of work, not retry tokens.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: leaky bucket, fixed window.

### UDP relay

The UDP relay is the part of the peer of the modus tool that carries UDP datagrams between a program of the host, on a socket of the loopback, and the UDP port 4433 of the machine.

QEMU user networking with `restrict=on` drops each UDP datagram that the machine sends, so a UDP forward of the host cannot reach `quic_echo`. The relay replaces it: a datagram of a client of the host becomes a frame from 10.0.2.2 to the port 4433 of the machine, and the answers go back the same way. A datagram over 1472 bytes is dropped and counted. `modustool test quic-real` uses it to run the OpenSSL QUIC client of the host against `quic_echo`.

The design: `docs/QUIC.md`, "A stack that this project did not write".

Do not use: port forward, proxy, hostfwd (for this).
