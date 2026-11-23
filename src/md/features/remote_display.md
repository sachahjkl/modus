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

The remote display service, `remote_display`, is a process of the boot image, outside the kernel. Its start grant set holds:

- an endpoint of the network: a listen grant of UDP on its own port, `remote_display.LISTEN_PORT`, for the address of the host only, as `remote` has;
- the client table, with the right Read, by the start grant `Remote_Clients`, as `remote` reads it. It has no grant `Connect`: it calls no service;
- the start grant `Screen_Capture`: the capture face and the input face of the compositor.

**The two faces ride the window ring.** Each process that the root service starts with a window already has a ring to the compositor (`modus:display`). The service does not get a second ring: the root service tells the compositor, in the record `Client_Add` of the service, that this client holds `Screen_Capture`. The compositor takes the commands of the capture face and of the input face only from such a client, and counts and drops them from any other. A new ring would be a second path from the root service to the compositor for the same process; the flag is one value of a record that exists. The service opens no surface: it has no window, and it is never in front.

**The capture face** works as the surface of a window, in the other direction:

1. The service asks for the size of the screen (`Capture_Size_Ask`). The compositor answers with the event `Capture_Size`.
2. The service makes one memory object with its own budget: a header page, then two pictures of the size of the screen. It gives it through the ring with `Capture_Open`, as a window gives its surface. The compositor checks the handle, the size and the rights, maps it, and owes the whole screen to both pictures.
3. After each frame, before it draws the pointer, the compositor copies into the picture that the service does not hold the rectangles that the picture owes. It writes the rectangles that changed since its last record into the header of that picture, then sends the event `Capture_Frame`. The service holds that picture until `Capture_Taken`. While it holds it, the compositor adds the damage of each frame to the debt of each picture and to the rectangles of the next record, and does not wait.
4. `Capture_Close`, or the stop of the service, ends the face: the compositor unmaps the memory and copies nothing more.
5. A change of the size of a screen of memory: the compositor unmaps the pictures and keeps the face, its viewers and the mark of the bar, then sends `Capture_Size` with the new size; the service gives memory of the new size with `Capture_Open` ([screen_of_memory.md](screen_of_memory.md)).

The service copies the rectangles of each record into its own copy of the screen, then gives the picture back. The two pictures and the copy have the size of the screen in force, made when the face opens and given back when the last viewer ends: a screen of 1920 × 1080 costs 6 076 pages, one of 3840 × 2160 costs 24 301, one of 7680 × 4320 about 97 200. The service states them as three screen pictures (`screen_pictures` of its stated budget), and the root service adds their pages for the screen of the machine when it starts the service ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The budget that a module asks for"): a 4K machine pays a 4K screen and a 1080p machine does not, and a row of the plan of principal 0 may lower that cost, as a machine policy. When the budget does not pay the screen in force (a machine whose share of a process is smaller than the screen, or a lower plan row), or the screen is past the largest screen of the protocol, the service writes one line, keeps the face closed, and ends each viewer with the code `Screen_Not_Held`: a viewer that waited for a screen that never comes would hold its place with nothing to show. The next viewer asks again, so a refusal is one line for each viewer that comes, not one in each pass. Two forms were refused: a copy sized for the largest screen at every start, which took 97 200 pages for any screen; and a stated budget sized for one screen, which refused every larger screen. Each viewer codes the screen pieces of its viewer frame from that copy as its stream takes them, so the service holds no coded viewer frame: a viewer frame of a whole screen can be megabytes, a screen piece is at most 32 KiB. The service copies a picture only while no viewer is in the middle of a viewer frame, so each viewer frame shows one moment of the screen. A slow viewer delays the copy, never the compositor, which merges the damage while the service holds the picture; a viewer that does not take its viewer frame in its bound ends with the code `Timeout`. The cost is a third copy of the screen in the budget of the service.

**The pointer stays out of the pixels.** The compositor draws the pointer into its frame after the windows. The copy runs before the pointer phase, so the rectangles of this frame hold no pointer. A rectangle that a picture owes from an earlier frame can hold the pointer of now: before such a copy, the compositor adds the rectangle of the pointer to the damage of the frame, so that the frame draws it again without the pointer first. The header of each picture gives the place of the pointer and the rectangle that its picture covers; the viewer draws it.

**The input face** carries the records of the keys and of the pointer, in the form of the records of the input service (`Remote_Key`, `Remote_Pointer`, the pointer at a place of the screen). The compositor sends them along the path of each key ([key_path.md](key_path.md)): to the palette, to the clipboard, or to the window that has the focus, never to the bar or to a trusted surface of the system. The key super works from a viewer too. The window ring has a stated capacity, and a full ring stops the writer, the service, so no key is dropped in silence. The compositor takes input only while the capture face is open: the input face is part of a session that the bar shows.

### The transport: a protocol of modus over QUIC

The system has QUIC with TLS 1.3, and the client keys of `remote` with mutual TLS and raw public keys ([remote_client_keys.md](remote_client_keys.md)). The first layer uses both, with a protocol of its own:

| Choice | Cost | Decision |
|---|---|---|
| A protocol of modus over QUIC | One contract package, and one viewer to write. The proof of the key and the encryption exist already | The first layer |
| A WebSocket stream to a browser, as voxl does | TLS over TCP, HTTP/1.1, WebSocket, and a viewer page in JavaScript. The browser cannot show a raw public key, so the proof of the client is a token | A gateway, later |
| WebTransport to a browser | HTTP/3 over the QUIC of the system. Closer to the first layer, and it still needs the viewer page and a token | A gateway, later, before WebSocket |
| VNC (RFB) | Small, but its authentication is weak and needs a tunnel | A gateway, later |
| RDP | Large: its security layers, its channels and its codecs | A gateway, after VNC |

Each record is a header (its kind and the length of its body) and a body of a fixed form, in a contract package, `modus:contract/remote_display`, with the values of each enum written. One border for each direction refuses a kind that names no member, a kind of the other direction, a length that is not the length of the kind, a length past its bound before any byte of the body is read, a rectangle outside the screen, and a field out of its range. The records:

| Direction | Kind | Body |
|---|---|---|
| Service to viewer | `Screen_Size` | the width and the height of the screen; the first record, and again after a change of the size of a screen of memory |
| Service to viewer | `Viewer_Frame_Start` | the serial of the frame, its count of screen pieces, the bytes of its screen pieces |
| Service to viewer | `Screen_Piece` | a rectangle of at most 128 × 64 pixels, then its pixels in the screen piece coder |
| Service to viewer | `Viewer_Frame_End` | the serial of the frame |
| Service to viewer | `Pointer_Place` | the place of the pointer, and the rectangle that its picture covers |
| Viewer to service | `Viewer_Frame_Taken` | the serial of the frame that the viewer took whole |
| Viewer to service | `Screen_Piece_Request` | a rectangle of the screen that the viewer asks again |
| Viewer to service | `Key` | the code, the character, pressed, the modifiers |
| Viewer to service | `Pointer` | the place on the screen, the buttons, the wheel notches |

**One bidirectional stream, which the viewer opens.** The screen goes in the direction of the service, the input and `Viewer_Frame_Taken` in the direction of the viewer. QUIC controls the flow of each direction alone, so a key never waits behind the pixels. The first form had a stream of the screen that the service opens, a stream of input and a stream of control: three streams give the same order with two more streams to open, to bound and to end, and the server of `modus:quic` opens no stream. The control records (a size that a viewer asks, its refusal, later the clipboard) go in the two directions of the same stream.

**One viewer frame in flight.** The service sends a viewer frame only after `Viewer_Frame_Taken` of the last one. Each viewer has its own damage set of 8 rectangles; past it, the rectangles merge, and the service counts the merges. The first viewer frame of a viewer is the whole screen.

**The screen and the bounds of a viewer frame.** `Screen_Size` names a screen up to 7680 × 4320 (`remote_display.SCREEN_WIDTH_LIMIT`, `SCREEN_HEIGHT_LIMIT`): 1440p, 4K, 5K and 8K pass the border. The bounds of a `Viewer_Frame_Start` follow the screen of its session, not the largest screen (`viewer_frame_piece_limit`, `viewer_frame_bytes_limit`): the pieces of the whole screen, and a row, a column and a corner of partial pieces for each of the 8 rectangles of a damage set, which do not meet; the bytes are each pixel in its worst code and the headers of those pieces. A fixed bound sized for 8K would let a viewer of a small screen take a frame of a gigabyte; a fixed bound sized for 1080p refused a 4K screen.

**The screen piece coder** codes each screen piece alone, in the manner of QOI: a run of the last color, an index of 64 recent colors, a small difference from the last pixel in two forms, and a whole color. The screen is opaque `0x00RRGGBB`, and the desktop has large areas of one color, so this coder fits it. A screen piece alone decodes in any order, and a damaged tile spoils no other. The decoder refuses a code past the pixels of its screen piece, a code that ends before them, a byte after the last pixel, and the reserved tag of a color with alpha. The bytes of a full screen and of a viewer frame with a small damage are measure lines of the machine test.

**The pointer is not in the pixels**: the viewer draws it at the place that the service sends, so a move of the pointer costs one record.

### The viewer, a program of its own

The first viewer is a native program in a repository of its own, which runs on Linux, macOS and Windows and uses `gui_toolkit` as a library. It is not a part of `gui_toolkit`: the toolkit holds what several programs share, and the viewer is one program. A part of the viewer that a second program needs later moves into the toolkit then. The viewer reuses:

- the packages `modus:quic` and `modus:contract/remote_display` from a copy of the repository of the system that its flake pins. The QUIC package reads and writes bytes only, and the tool already runs it on the host in its peer (`tools/modustool/machine/peer_remote.odin`);
- the form of the client key of the peer: an Ed25519 key, which the viewer keeps in the store of secrets of the toolkit and shows, so that a principal allows it;
- the draw layer of the toolkit, which shows the screen as one picture and changes only its damage rectangles.

The socket of each system is a part of the viewer, in the files of each system.

### A machine for a viewer on the host

`modustool run --remote-display <viewer key>` runs a machine that a viewer on the same computer reaches, with no person at the machine. The command `viewertool machine <port> <machine key>` of the viewer connects to it.

- **The path of the datagrams.** QEMU user networking with `restrict=on` drops each UDP datagram of the machine, so the machine has the network device of the peer of the tool (`-netdev dgram`), and the UDP relay of the peer carries the datagrams of the viewer. The relay reaches one port of the machine, which is a parameter of the peer: 7101 of `remote_display` here, 4433 of `quic_echo` for `test quic-real`. Each datagram of the relay comes from 10.0.2.2, the one address that the listen grant of `remote_display` admits, so the grant does not change.
- **No window.** The machine runs as a test machine: its log goes to a file, and the tool types through the machine protocol of QEMU. A run for a program never opens a window on the desktop of the host.
- **The allow and the start.** The tool types `remote_display_allow("<viewer key>", "view_and_input")` in the console of principal 0 first: the root service holds the client table, with no `remote_display`. The boot image of `run` holds `remote_display`, and the start policy does not start it, so the tool then types `start("remote_display")`. When the service listens, the tool prints the port of the relay and the line of the public key of the service: a viewer that connects at once is allowed and finds the service. The machine has a new data disk, so no named principal is unlocked, and the session in front is the session of principal 0, the principal of the row of the key. The uses last until the machine stops: the next run allows the key again.
- **The viewer key.** The viewer keeps its key, and prints its public key with `modus-viewer -print-key`. The tool allows that key only: it never allows a key that the machine refused, because an allow of any key that tries is a grant to whoever reaches the relay.
- **The end.** The tool waits until the last viewer ends (`remote_display: no viewer: the capture face is closed`), then stops the machine with `shutdown()`. The bound of that wait is one hour: it ends only a run that no viewer used.

The refused forms:

- **`hostfwd=udp` of QEMU user networking.** libslirp drops the datagrams of the machine before any forward (docs/QUIC.md, section 6).
- **`run` in its window, with the allow typed by a person.** The run of a program, a screenshot of the viewer for example, must open no window on the desktop, and a person is not there to type.
- **A key of the viewer drawn by the tool.** The key of the viewer is the viewer's: the tool would hand a private key to another program, and the viewer would not run as a person runs it.

### The pointer of a viewer, and the echo of the input (protocol version 2)

A remote desktop feels immediate when the pointer never waits for the machine. The native viewer draws its cursor itself: the cursor of its host, at the place of the host pointer, moved by the host system. The machine then owes it three facts that version 1 does not give: the shape of its pointer, the moves that it makes itself, and which input a frame shows. The design of the viewer side is [immediacy.md in the repository of the viewer](https://github.com/sachahjkl/modus-viewer/blob/master/src/md/features/immediacy.md).

What exists in version 1:

- **The capture without the pointer.** The compositor copies the screen before its pointer phase, and draws the rectangle of the pointer again without it when a picture owes it ("The pointer stays out of the pixels", above). Nothing to add.
- **`Pointer_Place`:** the place and the rectangle of the pointer, at each move, whoever made it. A viewer that holds the input cannot tell its own moves, one round trip late, from a move of the machine.

What version 2 adds. Version 1 is removed before 1.0; version 3 adds the size of a screen of memory below, and `Session_Start` names version 3.

| Direction | Kind | Body | Border |
|---|---|---|---|
| Service to viewer | `Pointer_Shape` (6) | the shape (`pointer_pictures.Pointer_Shape`), the form (`Pointer_Form`), the size in pixels, the hotspot, a reserved word (24 bytes) | the shape and the form name members; the size is in 24 to 48; the hotspot is inside the size; the reserved word is 0 |
| Service to viewer | `Pointer_Picture` (7) | the shape, the form, the size, the hotspot, a reserved word (24 bytes), then the RGBA pixels of the picture | as `Pointer_Shape`; the bytes are size × size × 4, at most 48 × 48 × 4 |
| Service to viewer | `Pointer_Warp` (8) | the place `(x, y)` and the 64-bit count of input records of this viewer applied before it (16 bytes) | the place is inside the screen; the echo count is monotonic and at most the records sent |
| Service to viewer | `Viewer_Frame_Start` (2) | serial, screen piece count, reserved (0), bytes, and `input_echo_count` (`u64`): the monotonic count of input records of this viewer applied before the copy of the frame (32 bytes) | the reserved word is 0; the count is monotonic and at most the records that the viewer sent |

- **The shape.** The compositor sends `Pointer_Shape` when the shape of its pointer changes, and once at the start. The service sends `Pointer_Picture` of a shape the first time that a session uses it: the viewer uses a cursor of its host of the same kind when it has one, else that picture. The pictures are drawn from the outlines of the theme at the build ([vector_pointers.md](vector_pointers.md)), so the service sends the pixels that the compositor would draw. A theme identifier that both sides know was refused: the host has no modus theme, and the picture is 9 KiB once for each shape.
- **The warp.** The compositor marks a move of the pointer that no pointer record caused: a warp of a process, a drag that it constrains to a window, the pointer of another viewer. The service sends those as `Pointer_Warp` to each viewer, and never the moves that its own records made: a viewer with the input knows them. `Pointer_Place` stays for the viewer that does not hold the input.
- **The echo of the input.** The compositor counts the input records of each viewer that it applied. The capture face writes the count of the moment of its copy in the header of the picture, beside the place of the pointer; the service puts it in the `Viewer_Frame_Start` that codes that picture. The viewer ties its records to their times. This is the tie of a key to the screen of [desktop_to_browser.md](desktop_to_browser.md): a serial that the compositor keeps, never a time sent back.
- **The motions on datagrams, later.** Only the newest place of the pointer matters, so a lost motion needs no second send. When `modus:quic` has the DATAGRAM frame (RFC 9221), the motions go as datagrams and the keys and buttons stay on the stream, in order. Until then the stream carries all input; the viewer sends at most one motion for each frame of its display.

The tests, before any machine: the host tests of the contract give each new record at its edges (a shape past the last member, a size of 23 and of 49, a hotspot on the edge and one past it, a picture one byte short and one byte long, a warp one pixel past the screen, a count that goes back) and check each refusal; the fuzz target `remote_display_records` takes the new kinds. The machine test adds a case to the part `remote_display`: the viewer of the peer moves the pointer over the console and receives `Pointer_Shape` of `Text`, and a frame whose count covers that move.

### The size of a screen of memory (protocol version 3)

A viewer with the input asks the screen of memory for a size; the design of the machine side is [screen_of_memory.md](screen_of_memory.md). `Session_Start` names version 3 (`PROTOCOL_VERSION :: 3`), and the peer of the tool speaks version 3.

| Direction | Kind | Body | Border |
|---|---|---|---|
| Viewer to service | `Screen_Size_Ask` (21) | the width and the height (8 bytes) | each side inside 320 × 240 to 7680 × 4320 (`modus:contract/memory_screen`); else the connection ends with `Bad_Record` |
| Service to viewer | `Screen_Size_Refused` (9) | the width and the height that the viewer asked, the cause (`memory_screen.Resize_Refusal`: `Device_Screen`, `Outside_Bounds`, `Compositor_Budget`, `Service_Budget`, `Too_Soon`), a reserved word (16 bytes) | the size passes the limit of a screen; the cause names a member that is not `None`; the reserved word is 0 |
| Service to viewer | `Screen_Size` (1) | as before | it comes again after a change, between two viewer frames: the next viewer frame is the whole screen |

- **Only a viewer with the input asks.** A viewer with the view alone that asks ends with `Input_Not_Allowed`, as for a key: a size changes the desktop of the principal.
- **A refusal is a record, not an end.** `Device_Screen` (the machine has a screen of a device), `Outside_Bounds`, `Compositor_Budget`, `Service_Budget` and `Too_Soon` (less than one second after the last change, or after the last ask of the viewer) are states of the machine: the viewer keeps its session and can ask another size.
- **The records that cross a change.** Until the viewer takes a viewer frame at the size in force, its records are read against the largest side of each screen since it last saw that size, and each place and each rectangle is cut to the screen in force.

### The authority

- **A grant of a principal to a client key.** Each row of the client table holds the uses of its key, a set of three: `Calls` (the calls of `remote`), `View` (the view of the screen) and `Input` (the keys and the pointer). `Input` never comes without `View`: the border of the word of the uses refuses that set, and an unknown bit. `remote_allow(key)` gives `Calls`, as before. `remote_display_allow(key, "view")` gives `View`, and `remote_display_allow(key, "view_and_input")` gives `View` and `Input`. An allow of a key that the principal holds already adds the uses to its row and keeps its serial: a grant that grows ends no connection. `remote` takes only a key whose row holds `Calls`, and `remote_display` only a key whose row holds `View`; a key with `View` alone makes no call. One table of client keys serves `remote` and `remote_display`, because the key, the principal, the serial and the revocation are the same concept for both.
- **The uses on the disk.** The disk grant table (format 4, 2288 bytes) keeps each allowed client key as a 40-byte row: the 32-byte Ed25519 public key followed by its 8-byte little-endian `Client_Uses` word (`Calls`, `View`, `Input`). The decoder refuses zero uses, unknown use bits, and `Input` without `View`. Revoking a key removes the row and clears its persisted uses on disk, so an allowed viewer sees the screen and sends input again after a restart unless revoked or forgotten.
- **The session in front.** A viewer sees the screen only while the session in front is the session of the principal of its row: principal 0 cannot see the data of a named principal ([`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "2. Principal 0: the machine"), and the screen of a named session shows them. The session in front is the session of the named principal that is unlocked, else the session of principal 0. Each row has a flag `not_in_front`, which the root service writes at each unlock and each lock, and at each new row, from one pure procedure of the contract, `client_display_paused(principal of the row, principal in front)`. While the flag is set, the row holds no `View` and no `Input`; `Calls` is not touched. When the flag of a row with `View` changes, the row gets a new serial, as a lock does, so a session open through it ends with the code `Revoked` and the next handshake of its key is refused until the flag clears; a new serial cannot be missed between two passes of `remote_display`, where a flag that changes back could. The cost: a client of `remote` whose key also holds `View` loses its open calls at the change, because its row has a new serial too; it opens a new connection. The rows of a named principal while its session is locked already hold nothing. The picture of one color with the line of the cause, for a viewer whose session is not in front, waits for layer 4 of [`docs/PRINCIPALS.md`](../../../docs/PRINCIPALS.md), "1. The layers, and what is built", where two sessions share one screen.
- **A visible indicator.** While the capture face is open, the bar of the compositor shows a mark: the word `viewer`, the hash prefix of each key that the service names, and `input` for a key with the input. The compositor draws it from its own state: the mark shows while the face is open, whatever the service says, so the service cannot hide it. The service names the keys; a fault of the service can name them wrong, never hide the mark. A text that does not fit the room between the buttons and the hint of the palette becomes the count of the viewers, then a mark with no text: no text is cut. When even that mark has no room, the hint of the palette is not drawn, and the mark takes its room: the mark is never left out, as the hint is a help and the mark is the indicator. A press on the mark opens a compact viewer list popover showing each connected viewer's key prefix, grant role (`view` or `input`), and an explicit `disconnect` button that sends `Capture_Disconnect` to `remote_display` to end that viewer immediately without opening the console. Escape, clicking outside the popover, clicking the mark again, or disconnecting the last viewer closes the popover.
- **The revocation.** `remote_disallow(key)` ends the grant as it does for `remote`: the row is free, and `remote_display` ends the connection with the code `Revoked`, in the middle of a viewer frame too. The lock of the session ends the view of its viewers too. Only the revocation ends the grant. The keys and the pointer of a viewer that wait in `remote_display` for room in the window ring carry the place and the generation of their viewer, and the end of the viewer drops them: no key of a revoked viewer goes after its end. A record that is already in the window ring cannot be taken back: the compositor reads it as a key of a viewer whose face is open. The ring holds at most its capacity of such records, and the service stops reading a viewer while it waits for room, so what passes the revocation is bounded by the ring, never by the viewer.
- **Input from a key of the view alone.** The service ends the connection with the code `Input_Not_Allowed`, writes one line, and gives the compositor nothing: a viewer that sends a key it was not given has a fault or an attacker behind it.
- **The trust in the service.** A fault of `remote_display` can show the screen to each key whose row holds the use `view`. It cannot act for a key with no row, and it cannot read the windows of a session that is not in front: it reads only the copy of the screen that the compositor writes.

### The screen of memory

With no screen of a device, the compositor draws into a screen of memory, and a viewer sees it as it sees a screen ([screen_of_memory.md](screen_of_memory.md)). The row `display` of the start list gives its size, the reference screen in the default lists, and a viewer with the input can ask another size. The machine parts page still says "no screen", and the compositor writes one line: `compositor: no screen: a screen of memory of 1920 x 1080`. So this is not a part that the system pretends to have ([missing_hardware.md](missing_hardware.md), "The refused forms"): no process reads it as a display device, and the line names it. The frame of the compositor is the screen, so the screen of memory costs the two screen pictures that the compositor states for any screen.

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
- **A queue of frames for each viewer.** On a slow link, the queue grows, and the viewer shows a past screen with a delay. One viewer frame in flight, with the damage merged, keeps the delay to one frame and the round trip.
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

- **A small damage is a share of the screen.** The service and the tests measure the viewer frames of a small damage apart from the whole screen: at most 1/64 of the screen (`small_damage_pixels` of the contract). The small damage that comes each second is the clock of the bar, which grows with the scale: at the scale 1.25 its viewer frames hold 4824 pixels, past the 64 by 64 pixels that the measures took before, so no frame counted, and the case `small frames` of the test failed with the compositor and the service at work. Refused: a count fixed in pixels of the screen, which breaks at each new scale.
- **The latency.** A key from the viewer crosses one round trip, the path of the key and one frame. The service sends a viewer frame as soon as the compositor gives its rectangles, with no timer and no batch. The measure is the key to the screen of [desktop_to_browser.md](desktop_to_browser.md), "The three measures on the path of the system", plus the round trip, which the viewer measures.
- **Many viewers.** Each viewer has its own damage set and its own viewer frame in flight, and the service reads one copy of the screen for all. The count of the viewers is bounded by the rows of the client table, and the service holds eight connections (`remote_display.CONNECTION_CAPACITY`): a ninth client gets no record of the server until one ends. The bar names each of the eight: `Capture_Viewers` goes in parts of four keys (`display.CAPTURE_VIEWER_KEYS_OF_A_PART`), as a ring record holds seven words, and the compositor changes its mark with the last part only. A slow viewer holds back the other one: the copy of the screen changes only while no viewer writes a viewer frame, so the viewer frames of a fast viewer wait for the slowest one, up to the write bound of a viewer frame. The cost is a delay of the fast viewer, never a wrong pixel and never a wait of the compositor. So that one viewer cannot hold the other for long, the write bound of a viewer frame is 10 s alone and 2 s while another viewer waits for the copy; a viewer past it ends with the code `Timeout` and one line that names the bound.
- **The bounds of a viewer.** Each bound starts at its own step and writes its own line: the write of a viewer frame (from `Screen_Size` or `Viewer_Frame_Start` to the last byte of `Viewer_Frame_End` in the stream), the take of a viewer frame (from `Viewer_Frame_End` to `Viewer_Frame_Taken`), and the read of a record (from its first byte to its last). A viewer that stops in the middle of a record ends at the read bound, not at the idle timeout of QUIC.
- **A resize.** With a screen of a device, the viewer scales the picture in its window, and an ask of a size gets `Screen_Size_Refused` with `Device_Screen`. With a screen of memory, a viewer with the input asks for a size, and the compositor takes it at once, or refuses it with its cause. Each viewer then receives the new size and one whole frame. With two viewers that ask, the last request holds.
- **The sound.** The sound device plays for one process at a time ([timed_stream.md](timed_stream.md)). A stream of the sound to a viewer waits for the sound service of several processes, which sums their frames: the sum is the stream to send.
- **The clipboard.** The compositor holds the one slot ([clipboard.md](clipboard.md)). A paste from the viewer is a paste of the principal: the viewer sends the text, and the compositor treats it as a Control+V of the principal, for the window in front only. A copy goes to the viewer only when the Control+C came from that viewer. The limits of the clipboard hold: text only, of the size that the copier pays and the place that pastes takes.
- **A slow link.** QUIC controls the congestion. The damage set of a viewer has a stated capacity: past it, the service merges the rectangles into their bounding rectangle and counts the merges on its log, once in each second. The viewer then receives more pixels, never fewer.
- **A first frame.** A viewer that connects receives the whole screen once, then the damage.
- **The unlock window.** A viewer of principal 0 with the input can type in the window of `unlock` of a named principal. It sees the dots, never the passphrase. A passphrase typed through a viewer crosses the TLS of the viewer.

## State

The first layer and protocol version 2 are built on the side of the system: the shared QUIC server support package (`src/library/modus/quic_server`, used by `remote`, `remote_display`, and `quic_echo`), the service `remote_display`, the capture face and the input face of the compositor (including pointer shape metadata, machine-initiated pointer warp masks, and per-viewer input echo counters keyed by generation), the protocol v2 contract (`Pointer_Shape`, `Pointer_Picture`, `Pointer_Warp`, `Viewer_Frame_Start.input_echo_count`, `Input_Echo_Tracker`) and the screen piece coder in `modus:contract/remote_display` with their host tests and the fuzz target `remote_display_records`, the headless virtual framebuffer contract and backing state model (`src/library/modus/contract/memory_screen`) with its host tests, the uses of a client key persisted in disk grant table format 4 (`Calls`, `View`, `Input`) across restarts, eight viewers at one time, screens up to 7680 × 4320 with the memory of the service, its budget (three screen pictures) and the bounds of a viewer frame from the screen in force, `remote_display_allow`, the mark in the bar, and the interactive viewer list popover opened from the bar mark with per-viewer disconnect (`Capture_Disconnect`). The peer of the tool speaks protocol version 3 and verifies monotonic input echo counts on frames and warps. The screen of memory is built: its size from the start row and from a viewer (protocol version 3), the compositor with no framebuffer, and the capture face across a change of size ([screen_of_memory.md](screen_of_memory.md)).

Left of the first layer: the native viewer, a program of its own that uses `gui_toolkit`; the session in front of layer 4; the row of machine policy that lowers the cost of the screen pictures, which waits for machine policy in the plan. The layers, in their order:

1. The viewer, a program of its own that uses `gui_toolkit`, and the rest of the first layer above.
2. The interface for agents (freestanding contract `Agent_Capture_Mode`, `Agent_Screen_Request`, `Agent_Screen_Response`, and `Settle_Tracker` in `src/library/modus/contract/remote_display/agent_gateway.odin` with host tests; service wiring remains).
3. A gateway to a browser by WebTransport, with the display token (freestanding contract `Gateway_Transport`, signed 1-day `Display_Token` with `absolute_end_unix` ceiling, `Token_Revocation_List`, `display_token_verify_and_renew`, and binary `gateway_frame_encode` / `gateway_frame_decode` in `src/library/modus/contract/remote_display/agent_gateway.odin` with host tests; service wiring remains).
4. A gateway to a browser by WebSocket, sharing the same token and binary gateway frame encoder/decoder.
5. A gateway to VNC, then to RDP.
6. A video codec, when a measure of the bandwidth needs it.
