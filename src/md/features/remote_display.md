# The remote display

A principal sees and drives the desktop of a machine from another machine. The machine can have a screen, or no screen: with no screen, the compositor draws into a screen of memory. The remote display service is a service like any other: the start policy starts it or does not ([start_policy.md](start_policy.md)). It sends the pixels of the damage rectangles that the compositor already knows, so a still screen costs nothing. The viewer sends back the keys, the pointer, the size of its window and, later, the clipboard.

## The constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 6: screen capture is a grant, with a visible indicator. Line 7: synthetic input is a grant. Line 13: each grant is recorded, visible, and can be revoked.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": the service holds only the handles that it was given. A fault of the code that reads the network reaches only those handles.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": a remote viewer is a process tree that received handles from a principal. Its identity is a public key.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface": no part of this design is in the kernel.
- **The compositor never waits for a process** ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)). A slow viewer, or a slow service, must not hold a frame of the screen.
- **The process pays.** The memory of each copy of the screen comes from the budget of the service.
- **The authority is the real cost.** A viewer with input acts as the principal at the machine. The grant, its indicator and its revocation are the design. The pixels are not the hard part.

## The chosen form

### The service

The remote display service, `remote_display`, is a process of the boot image, outside the kernel. Its role holds:

- an endpoint of the network, for its QUIC port;
- the client table, with the right Read, by the start grant `Remote_Clients`, as `remote` reads it;
- a capture face of the compositor: a ring, and the two pictures of a copy of the screen;
- an input face of the compositor: a ring of input records.

The capture face works as the surface of a window, in the other direction. The service makes the memory of two pictures of the size of the screen, with its own budget, and gives them to the compositor. After each whole frame that it presents, the compositor copies its damage rectangles into the picture that the service does not read, and sends one record with the rectangles. It keeps the debt of each picture as the window layer does ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)). If the service still reads the other picture, the compositor adds the rectangles to the debt of the picture and does not wait. With no viewer connected, the service closes the capture face, and the compositor copies nothing.

The input face carries the records of the keys and of the pointer, in the form of the records of the input service. The compositor sends them along the path of each key ([key_path.md](key_path.md)): to the window that has the focus, never to the bar or to a trusted surface of the system. The key combination that always goes to the system works from a viewer too. The ring has a stated capacity, and a full ring stops the writer, so no key is dropped in silence.

### The transport: a protocol of modus over QUIC

The system has QUIC with TLS 1.3, and the client keys of `remote` with mutual TLS and raw public keys ([remote_client_keys.md](remote_client_keys.md)). The first layer uses both, with a protocol of its own:

| Choice | Cost | Decision |
|---|---|---|
| A protocol of modus over QUIC | One contract package, and one viewer to write. The proof of the key and the encryption exist already | The first layer |
| A WebSocket stream to a browser, as voxl does | TLS over TCP, HTTP/1.1, WebSocket, and a viewer page in JavaScript. The browser cannot show a raw public key, so the proof of the client is a token | A gateway, later |
| WebTransport to a browser | HTTP/3 over the QUIC of the system. Closer to the first layer, and it still needs the viewer page and a token | A gateway, later, before WebSocket |
| VNC (RFB) | Small, but its authentication is weak and needs a tunnel | A gateway, later |
| RDP | Large: its security layers, its channels and its codecs | A gateway, after VNC |

The protocol has five kinds of record: a pixel update, the pointer, the input, the size, and the clipboard. Each is a fixed record of a contract package, `modus:contract/remote_display`, read through one border that refuses a word that names no member, as each other contract. The streams:

- **One stream of the screen, from the service.** One whole frame at a time: its pixel updates, then its end. The service sends the next frame only after the viewer took the last one.
- **One stream of the input, from the viewer.** The keys never wait behind the pixels.
- **One stream of control, in both directions:** the size, the pointer shape and its hot spot, the clipboard.

A pixel update is a damage rectangle with its pixels in a lossless coder in the manner of QOI: a run of one color, an index of the recent colors, a small difference from the last pixel. The screen is opaque `0x00RRGGBB`, and the desktop of the system has large areas of one color, so this coder fits it. Its rate and its size are estimates to measure. The pointer is not in the pixels: the viewer draws it at the place that the service sends, so a move of the pointer costs one record.

### The viewer in gui_toolkit

The first viewer is a native program of `gui_toolkit`, which runs on Linux, macOS and Windows. It reuses:

- the packages `modus:support/quic` and `modus:contract/remote_display` from a copy of the repository of the system that its flake pins. The QUIC package reads and writes bytes only, and the tool already runs it on the host in its peer (`tools/modustool/machine/peer_remote.odin`);
- the form of the client key of the peer: an Ed25519 key, which the viewer keeps in the store of secrets of the toolkit and shows, so that a principal allows it;
- the draw layer of the toolkit, which shows the screen as one picture and changes only its damage rectangles.

The socket of each system is a part of the viewer, in the files of each system.

### The authority

- **A grant of a principal to a client key.** The client table holds the uses of each key: calls of `remote`, the view of the screen, the view and the input. A principal allows a key with its uses, from a console that acts for it: `remote_allow(key, view)` or `remote_allow(key, view_and_input)`. The disk grant table keeps the uses with the key, so they last as the key lasts. One table of client keys serves `remote` and `remote_display`, because the key, the principal, the serial and the revocation are the same concept for both.
- **The session in front.** A viewer sees the screen only while the session in front is the session of the principal of its row. Else the service sends one picture of one color, with the line of the cause. This matters at layer 4 of [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "1. The layers, and what is built", where two principals share one screen.
- **A visible indicator.** While a viewer is connected, the bar of the compositor shows a mark that no process can draw: the hash prefix of each key, and whether it has the input. A press on the mark lists the viewers. The compositor draws it, so the service cannot hide it.
- **The revocation.** `remote_disallow(key)` ends the grant as it does for `remote`: a new serial, the end of the connection with the code `Revoked`. The lock of the session ends the view of its viewers too. The list of the indicator can end one connection, but only the revocation ends the grant.
- **The trust in the service.** A fault of `remote_display` can show the screen to each key whose row holds the use `view`. It cannot act for a key with no row, and it cannot read the windows of a session that is not in front: it reads only the copy of the screen that the compositor writes.

### The screen of memory

With no screen, the compositor draws into a screen of memory. The start row of the compositor gives its size, and a viewer with the input can ask for another size. The machine parts page still says "no screen", and the compositor writes one line: `compositor: no screen: a screen of memory of 1920 x 1080`. So this is not a part that the system pretends to have ([missing_hardware.md](missing_hardware.md), "The refused forms"): no process reads it as a display device, and the line names it. The size is at most the size of the reference screen, 1920 × 1080, because the budget of the compositor and the window bound are sized for it ([desktop_to_browser.md](desktop_to_browser.md)).

### An interface for agents

The service exports three functions, which an agent calls through `remote` with a client key that has the use `view`:

- `picture()`: the screen as one picture, in a lossless form.
- `wait_settled(bound)`: a wait until no surface has a picture due and the compositor presented its last frame. This is a condition from the damage, not a quiet time. The result says `settled`, or `changing` at the bound.
- `wait_changed(bound)`: a wait until the next frame with damage.

A record of the screen is a work of the viewer, not of the system: the viewer keeps the stream that it receives, and the toolkit has the encoders of films. The system then keeps no file of video and no encoder.

The test pointer of the tool ([../infrastructure/test_pointer.md](../infrastructure/test_pointer.md)) stays as it is. It reads the element lines of the log and presses with the mouse of QEMU. A machine test must also run on a machine with no network and no `remote_display`, and the films start before any service, at the boot display. The interface for agents is for an agent outside the tool. A machine test of the service uses the tool as a viewer, with the key of its peer.

## Later: the browser gateway and its token

The first gateway gives the remote display to a browser by WebTransport: HTTP/3 over the QUIC of the system. It is a separate service, `remote_display_web`, which serves a viewer page and translates the records of the protocol. A browser cannot prove a raw public key in its handshake, so the gateway proves the client with a token.

- **What it is.** A display token: 32 random bytes that the root service draws, shown once to the principal, with the hash prefix that names it. The root service keeps only the hash of the token, in a row of the client table, with the principal, the uses (view, or view and input), the serial and the end time. The token is never on the log and never on the disk: the row ends with the run of the machine.
- **Who gives it.** A principal, from a console that acts for it: `remote_token(view, days)`. `days` is the absolute end, below. A token acts for the principal that gave it, and for no other.
- **Its end time.** Each token has one, one day after its grant or its renewal, and the root service refuses a token with none. A token ends at its end time: a use at that time is refused. The end times are on the clock of the system, which never goes back during a run, and not on the date page, which a setting changes. A token never outlives the run, so a clock of the run is enough.
- **The absolute end.** The row also holds an absolute end, past which no renewal is given, so a lost browser stops by itself. The default is 7 days after the grant, and the bound is 30 days: the root service refuses a grant past it. A week covers the work of a person away from the machine with one grant; a month bounds what a lost browser can do. No renewal passes the absolute end: the last renewal ends there.
- **The renewal.** The viewer page asks for a renewal on its open session when less than one hour of its token is left. The gateway sends `Display_Token_Renew` on its root ring with the row and its serial. The root service gives a new token when the token is still before its end time, the row is not revoked, the session of its principal is unlocked, and the absolute end is not reached. The new token has the end time of one day later, or the absolute end if it is sooner. The row then holds the hash of the new token only, so the old token ends at once. The session stays open across a renewal. A viewer whose token ended needs a new grant from the principal. The decision is one pure procedure of the contract, `display_token_renew_decision`, which the host tests run.
- **Its revocation.** `remote_disallow` with the hash prefix ends the row at once, with a new serial and the end of the session, as for a client key. The lock of the session of the principal ends its tokens too, and the unlock does not bring them back. The bar shows a viewer of a token with the mark of a viewer and the word "token".
- **The proof.** The browser sends the token in the first record of its session. The gateway reads that one record of a fixed size, and nothing else, before the check. The gateway compares the hash of the token with the rows of the client table in a time that does not depend on the bytes. A refused token ends the session, with one line that names no byte of it.

The tests of the token try to break it:

- a renewal one second before the end time gives a new token, and the old token is then refused at its next use;
- a renewal at the end time, and one second past it, is refused, and the row does not change;
- a renewal after `remote_disallow` is refused;
- a renewal after the lock of the session is refused, and so is a renewal after the unlock that follows;
- a renewal at the absolute end, and past it, is refused; a renewal one hour before it gives a token that ends at the absolute end;
- a grant past the bound of 30 days, and a grant with no end, are refused;
- a renewal with the old token after a renewal is refused.

The host tests run each case on `display_token_renew_decision`. A machine case runs the first case and the revocation, through the gateway, with a clock of the test that the tool moves.

The token is the one exception to "a client is a public key" ([remote_client_keys.md](remote_client_keys.md)). It keeps the properties for these reasons:

- **Property 20.** The token is a grant of a principal. It is recorded in the client table, visible in `remote_clients()` and in the bar, revocable at once, and it ends by itself (line 13: "A grant can have an end time"). A process with no handle reaches nothing with it: the gateway still holds only its own start grants.
- **Property 21.** The token names one principal, and a call through it acts for that principal only, through the row that the root service checks. It is a narrow, visible grant of the kind that property 21 accepts for work away from the machine.
- **Its cost.** A token is a bearer secret: whoever holds it acts with its uses, and renews it, until the absolute end. That cost is why it has an end time and an absolute end, and why the first layer has no token.

## The refused forms

- **The service in the kernel.** Property 1. Nothing in it needs the kernel.
- **A read of the screen pages by the service.** The display and the compositor already share them, and a third reader would need the order of the flips. The copy of the damage is the cost of a viewer, and only while one is connected.
- **A wait of the compositor for the service.** A slow link would then slow the desktop. The debt of the pictures merges the damage, and the viewer receives the newest pixels of each rectangle. No pixel is lost: a newer frame holds them.
- **A queue of frames for each viewer.** On a slow link, the queue grows, and the viewer shows a past screen with a delay. One frame in flight, with the damage merged, keeps the delay to one frame and the round trip.
- **The grant in `remote_display` itself, or a second table of keys.** The grants would have a second holder beside the root service, and a key would have two revocations.
- **A password or a shared token for the first layer.** The client key already proves the viewer in the handshake, before any stream. A token comes only with the browser gateway, which cannot show a raw public key ("Later: the browser gateway and its token").
- **A token with no end time, or a password that a principal chooses.** A secret that never ends is a grant for ever, against property 20, line 13. A chosen password is guessed, and is used again on other machines.
- **A PASETO token for the browser gateway.** PASETO carries signed claims that a verifier checks with no table. The verifier here is the gateway on the machine, which holds the client table anyway, and a revocation needs that table. An opaque random token whose hash sits in the table is simpler, ends at once at a revocation, and adds no parser of claims at the border. If a verifier with no state ever comes, such as a gateway on another machine, the form to take is PASETO v4 (`v4.public`), whose signature, Ed25519, the system already has.
- **WebSocket as the first browser gateway.** It needs TLS over TCP and HTTP/1.1 beside QUIC. WebTransport is HTTP/3 over the QUIC of the system.
- **H.264 or AV1 in the first layer.** An encoder is a large module, and a lossy codec blurs the text of the desktop. It comes when a measure of the bandwidth needs it, on the processor profile first, then through the GPU path of [desktop_to_browser.md](desktop_to_browser.md) and [gpu_access.md](gpu_access.md).
- **RDP or VNC as the first layer.** See the table of the transport.
- **The pointer in the pixels.** Each move would damage two rectangles and wait behind the screen stream.
- **A record export of the system.** See "An interface for agents".

## The subtle points

- **The latency.** A key from the viewer crosses one round trip, the path of the key and one frame. The service sends a frame as soon as the compositor gives its rectangles, with no timer and no batch. The measure is the key to the screen of [desktop_to_browser.md](desktop_to_browser.md), "The three measures on the path of the system", plus the round trip, which the viewer measures.
- **Many viewers.** Each viewer has its own damage set and its own frame in flight, and the service reads one copy of the screen for all. The count of the viewers is bounded by the rows of the client table. A viewer past the bound of the service is refused with one line.
- **A resize.** With a real screen, the viewer scales the picture in its window, and the size of the screen does not change. With a screen of memory, a viewer with the input asks for a size, and the compositor takes it at its next frame. Each viewer then receives the new size and one whole frame. With two viewers that ask, the last request holds.
- **The sound.** The sound device plays for one process at a time ([timed_stream.md](timed_stream.md)). A stream of the sound to a viewer waits for the sound service of several processes, which sums their frames: the sum is the stream to send.
- **The clipboard.** The compositor holds the one slot ([clipboard.md](clipboard.md)). A paste from the viewer is a paste of the principal: the viewer sends the text, and the compositor treats it as a Control+V of the principal, for the window in front only. A copy goes to the viewer only when the Control+C came from that viewer. The limits of the clipboard hold: text only, 4096 bytes.
- **A slow link.** QUIC controls the congestion. The damage set of a viewer has a stated capacity: past it, the service merges the rectangles into their bounding rectangle and counts the merges on its log, once in each second. The viewer then receives more pixels, never fewer.
- **A first frame.** A viewer that connects receives the whole screen once, then the damage.
- **The unlock window.** A viewer of principal 0 with the input can type in the window of `unlock` of a named principal. It sees the dots, never the passphrase. A passphrase typed through a viewer crosses the TLS of the viewer.

## State

Designed, not built. The layers, in their order:

1. The service, the capture face and the input face of the compositor, the protocol of modus with lossless pixel updates, the uses of a client key, the indicator, and the viewer of `gui_toolkit`.
2. The screen of memory, with its size from the start row and from a viewer.
3. The interface for agents.
4. A gateway to a browser by WebTransport, with the display token.
5. A gateway to a browser by WebSocket, with the same token.
6. A gateway to VNC, then to RDP.
7. A video codec, when a measure of the bandwidth needs it.
