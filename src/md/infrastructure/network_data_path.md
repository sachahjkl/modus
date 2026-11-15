# The network service and the data path

The kernel is off the data path, and the network stack is a library in the program. One network device with one pair of queues still needs a multiplexer in user space: the network service. This file records what that service is allowed to do to the bytes of a packet, why one copy stays, and the layers that take the service off the data path (`docs/DECISIONS.md`, D-235).

What the service does today is in [`docs/NETWORK.md`](../../../docs/NETWORK.md), "Property 5 as it is built". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Data path".

## Two terms

The property is about the kernel. It does not define the data path for a service. Two terms make the question exact.

- **Data path**: the code that reads or writes the bytes of the data of a packet.
- **Control path of a packet**: the code that reads the headers of a packet and decides where it goes.

A service on the control path of each packet is not a breach of the letter of the property: its cost line names the multiplexer. What was wrong was work of the transport done outside the program, and more passes over the data than the constraint needs.

## The irreducible constraints

1. **One reader of the receive queue.** The device fills the next buffer, whatever the flow. So a buffer cannot belong to one program in advance, or a program reads frames of another program.
2. **A party that the program cannot change must filter.** A program that writes raw frames forges any source address and port. A program that reads raw frames reads the frames of others.
3. **No kernel entry for each packet**, and a small kernel.
4. **Send has no such constraint.** A send descriptor can name any physical memory. Only the header must be in memory that the program cannot change after the check.

From 1 and 2: on receive, one program outside the receiver reads the headers of each frame, and the frame then moves to the receiver. One copy by a third party stays. No honest design removes it without steering in the device or a kernel entry for each frame.

From 4: on send, nothing is irreducible.

## The layers

| Layer | What changes | Passes of the service over the data |
|---|---|---|
| Before | The service checked the transport checksum on receive, and wrote the UDP header and its checksum on send | Receive 2; send 1 for TCP and 2 for UDP |
| The checksum moves to the program | The program checks the checksum of what it receives. It reads those bytes in any case | Receive 1 |
| One form of endpoint for UDP and TCP | The program writes the whole datagram with its header. The service checks the ports in its copy | Send 1 |
| Send with no copy of the data | A frame has two parts: the headers in memory of the service, the data read by the device from the region of the program | Send 0 |
| A receive queue for each endpoint | The device steers by destination port; the service leaves the receive path of an endpoint | Receive 0 |

The three layers after "Before" are built. The last one is not. On send, the service still copies the first 8 bytes of the transport header for its check: a pass over the header, not over the data (see "The send with no copy").

## The reasons of each layer

- **UDP is corrected with TCP.** The decision named TCP. But UDP had more of the service on its path than TCP, and the two share the code of the copy and of the check. With only TCP corrected, the service has two send paths and two receive paths. One path is less code than two.
- **The checksum after the demultiplexing.** A frame whose port the wire damaged, and whose Ethernet check passed, can now reach the wrong program before that program refuses it. This was accepted: the check of the link is the guard against damage. The grant, not the checksum, is the guard against a hostile sender, and a hostile sender writes a correct checksum.
- **QUIC does not check the UDP checksum on receive.** It authenticates each packet, which is more. It writes a real checksum on send, because a remote can require it.
- **Send with no copy.** The service copies and checks a private copy of the headers only. The program can change the data after the check: it damages only its own checksum. No new trust: with no IOMMU the frame service can already make the device read any memory; with the IOMMU the device reads the datagram region and cannot write it.

## The send with no copy

A frame to send is a chain of up to four descriptors of the send queue of the device:

1. the virtio header, 12 bytes of zero, in the memory of the frame service;
2. the headers, in a send place of the frame region of the network service: Ethernet, IPv4, then the first 8 bytes of the UDP or TCP header, which the service copied from the datagram region and checked;
3. the rest of the datagram or the segment, in the datagram region of the program, from the byte 8 of its place.

4. for a frame shorter than 60 bytes, the zero bytes that make it 60, in the memory of the frame service.

A datagram of 8 bytes has no third descriptor. A frame of 60 bytes or more has no fourth. The fourth descriptor is the padding of a short frame, which the frame contract promises (a pure ACK of TCP is 58 bytes): a device of a real wire pads such a frame, a virtual device sends it as it is, and a copy of the data to pad it would make the service read the data. The 8 bytes hold the two ports and, for UDP, the length field: all that the check reads. For TCP they are the ports and the sequence number, never the data. The device reads the chain as one frame.

- **The read region.** The frame contract has a second kind of memory object of the client: a read region, which the device only reads, for the third descriptor. `Read_Region_Add` gives one with a place number, `Read_Region_Remove` ends it, and a `Send` names a place, an offset and a count in it. The network service adds the datagram region of each endpoint at `Endpoint_Add`, with the place of the endpoint, and removes it at `Endpoint_Remove`.
- **The physical address.** The frame service calls `Memory_Physical` on the handle of the read region, as for the frame region. That call refuses an object that is not contiguous, so the root service makes each datagram region `Contiguous`. The cost: 512 KiB of contiguous memory for each endpoint, which can fail on a fragmented machine; the start of the program then fails, with the status on the log.
- **The rights.** The network service gives the frame service the region with Read only, and the frame service refuses a handle with Write. With the IOMMU, the declaration of a handle with Read only maps the pages with no write bit ([iommu.md](iommu.md), "The rights of the handle"): the device reads the region of the program and cannot write it. For that give, the root service gives the network service the region with Give: the network service already holds the region and the frame ring, and no other program holds both.
- **The completion.** The completion of a `Send` of the program comes when the frame service completes the frame: the device used it. Before, it came after the copy. A program writes its place again only after the completion, as the contract always said. A program that writes it earlier changes what goes on the wire, with its own checksum then wrong: it harms its own packet.
- **The checksum.** The program writes it, as before. The device computes none (no offload is asked): an offload needs the virtio header with a start and an offset, and would move a check of the program into the device for no gain in isolation.
- **Who holds the object.** The handle of the frame service keeps the memory object, and its declaration to the device, until the last send that reads it is complete. `Read_Region_Remove` with sends in flight waits for them, then closes the handle, then completes. The program can stop and the network service can close its handle at any time: the frames of the object stay until the frame service closes. A `Read_Region_Add` to a place that is still ending waits in the frame service, as a `Send` waits for a free slot of the device.
- **The bounds.** A program can hold no send in the frame service longer than the device takes to send it: the send places of the network service (128) bound the frames in flight, as before. A device that never completes a send keeps the object for ever, as it keeps the frame region: that is a fault of the device, and the device service owns it.
- **The count.** The service counts each byte that it reads of a datagram or a segment, and among them the bytes of the data, after the transport header. When an endpoint ends, the log says that on send it copied 8 bytes of each header and read 0 bytes of the data. The tests `network`, `tcp`, `quic` and `iommu` wait for that line.

Refused for this layer:

- **The data with no check of the header.** The device would read the ports from memory that the program can change after the check, and a program could send from any port.
- **A copy of the whole TCP header.** The check reads 8 bytes. The length of a TCP header is a field that the program writes: the service would copy a count that the program chose, for no rule of the grant.
- **A pool of read regions shared by all endpoints.** One region for each endpoint keeps the end of an endpoint the end of its declaration.
- **The completion after the check.** The program would write its place while the device reads it, with no way to know when the device is done.

## The refused forms

- **Pages move, bytes do not, on receive.** The service gives the page of a frame to the program. This is one change of a mapping for each frame: a kernel entry for each packet, or a new batch operation. The service also needs a handle on the program to map into it, an authority that it must not hold. Each unmap needs a message to each processor of the program. A copy of 1460 bytes costs less.
- **A shared pool of frames mapped read-only in each program.** Each program then reads the frames of the others.
- **The frame service reads the headers and copies to the program.** It removes one wake, not the copy. The code that reads hostile frames then holds the right to physical memory. Today that right is in a program that reads no frame.
- **A test machine with several queues.** The two network back ends of the test machine refuse several queues. The others need a right on the host that the tests do not have.
- **Batching as the correction.** It is a mitigation: it lowers the cost of each packet and changes nothing about who reads the bytes.
- **The note of the property deleted.** A deleted note says what the code does not do. The property now has one sentence "as built" that agrees with its cost line.

## The subtle points

- **The correction is of structure, not of speed.** The checksum of a full frame costs under a microsecond, and a round trip costs 60 to 200 microseconds, spent in three programs that wake each other. The tests assert no change of throughput. They wait for a structural fact that the service writes on the log: how many times it read each payload byte, and that it computed no checksum.
- **A segment with a wrong checksum now reaches the library.** A program must release the remote of a dropped segment only when no connection has that remote. Else a damaged segment of a live connection makes the service forget the connection.
- **A SYN with a wrong checksum takes a place** of the admitted remotes of a listen grant until the program releases it or the place goes idle.
- **IPv4, ARP and ICMP echo stay in the service.** They are the shared identity of the machine. The rule for a shared network identity is open.
- **The end of a datagram region while the device reads it.** The kernel frees the frames of an object only when no handle and no mapping names it, and takes a page out of a device only at the close of the last handle of the service. The frame service closes its handle after the last completion, so neither happens while a send is in flight.
- **Four descriptors for each send.** A queue of 256 descriptors has 64 send slots, not 128. A `Send` that finds no free slot waits in the frame service, and the commands after it wait too, until the device completes a frame.
- **No revocation of the region while the device reads it.** The root service closes its handles of the region after the start of the program, and the network service ends the read region with `Read_Region_Remove`, never with a revocation of the handle that it gave. A revocation would end that handle while a send reads the region: with the IOMMU the device then faults, and with no IOMMU it reads frames that can be free again.
- **A late completion.** A send of an endpoint that ended can complete after its end, and a new endpoint can have the same place. The network service forgets the owner of each send place of an endpoint when it ends, so the completion frees the place and reaches no program.
- **For the layer "a queue for each endpoint"**: the table of admitted remotes of a listen grant has no home. The program then needs its own budgets for unknown remotes, as the QUIC library has. The send path still needs the header check in a service, unless the device filters the source.

## The condition under which the exception ends

A network device with at least one receive queue for each endpoint, and an exact filter by destination port that only the frame service programs. For send, also a filter of the source in the device.

## Not explained by this design

One fetch program sends much slower than it receives. The cause is unknown.
