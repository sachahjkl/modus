# The address of the machine: DHCP, or a static address of the plan

State: **Decided.** Built: the client as a pure package with its host tests (`internal:network/dhcp_client`), the static address of the plan with its border (`dhcp_client.static_of`), the input and output of the client in the network service (`src/modules/system/network/dhcp.odin`), and its machine case: the peer of the machine tests is a DHCP server (`tools/modustool/machine/peer_dhcp.odin`).

## Purpose

The network service had one static address, 10.0.2.15/24, and the gateway 10.0.2.2: the network of QEMU. A real network gives its address with DHCP (RFC 2131). The address of the machine is a plan-only value ([module_settings.md](module_settings.md), "Plan records"): a static address widens what the machine claims on its network, so only the plan of principal 0 gives it. With no static address in the plan, the service asks DHCP.

## The client

One pure package, `internal:network/dhcp_client`, holds the whole client: the messages it writes, the border of each message that it reads, and the state machine with its times. The network service gives it the frames of UDP port 68 and the time, and sends what it gives back. The host tests drive it with hostile messages and with a clock of their own.

- **The exchange** (RFC 2131, section 3.1): DISCOVER, then the first OFFER that passes the border, then REQUEST of that offer, then ACK, which binds the address; NAK starts again from DISCOVER. The client takes one offer: it does not compare offers, so a slow server never holds the start.
- **The times** (section 4.4.5): the lease from the ACK, T1 at half of it and T2 at seven eighths unless the ACK gives them, and T1 < T2 < lease, else the ACK is refused. At T1 the client asks the server of its lease again (RENEWING, unicast); at T2 it asks any server (REBINDING, broadcast); at the end of the lease it drops the address and starts from DISCOVER. A wait for an answer doubles from 4 s to 64 s, as section 4.1 says, with no random part: the service has one machine to start, and a test checks the order.
- **The identity**: the transaction word comes from the generator of the process (its fresh bytes), never a counter that another machine can guess; a message that does not carry the word of the transaction in flight, or the hardware address of the device, is no answer.

## The border of a message

A message comes from any machine of the network, so each field is hostile. The border refuses a message whole, and the client changes no state for it:

- fewer than 240 bytes (the fixed part and the magic cookie), another op than BOOTREPLY, a hardware type or length that is not Ethernet, another transaction word, another hardware address, no magic cookie;
- an option whose length passes the end of the message, an option after END that is not padding, an option given twice, no message type, a message type that is not OFFER, ACK or NAK;
- an OFFER or an ACK with no server identifier, no lease time, a lease of 0, a subnet mask that is not a run of ones then zeros, or a prefix shorter than 8 or longer than 30;
- an address that a machine cannot hold: 0.0.0.0, the broadcast address of its subnet, the subnet itself, 255.255.255.255, a loopback address, a multicast address; a router outside the subnet of the address.

The options that the client does not use are passed over by their length; the overload option (52) is refused, so the fields `file` and `sname` are never read.

## As built

- The service reads its plan values at its start: a whole static address holds, and a refused one starts DHCP with one line of the log that names the rule (`Address_Static_Refused`).

## The static address of the plan

The plan gives two texts to the owner `network`: `static_address`, the address and the bits of its prefix, "10.0.2.15/24", and `static_gateway`, "10.0.2.2". `network.interface_address_of_text` reads them: four numbers of 0 to 255 each with no zero before a digit, a prefix of one or two digits; then `network.interface_address_check`, the one border of an address of an interface, checks the prefix (1 to 32 bits), the address (not 0, all ones, multicast, nor the network or broadcast address of a prefix of 30 bits or less) and the gateway (on the link, not the address). The export `network.plan_only` describes the two texts, with their bounds, 9 to 18 and 7 to 15 bytes.

Why texts and not numbers: a principal writes an address as it reads it; one number of 32 bits for 10.0.2.15 is 167772687, which no reader checks by eye on the trusted display.

Why the rules of an interface and not of a reply of DHCP. The address of a plan is the address of the interface, which the service holds as a field with its prefix; a reply of a server keeps its own border (a prefix of 8 to 30 bits, a router that may be absent), because the server is hostile and the plan is not.
- Each datagram from UDP port 67 to port 68 goes to the client before the check of the destination address: a reply comes to the broadcast address, or to the address that it offers. The UDP checksum is checked when the server wrote one.
- A REQUEST of a renewal goes to the hardware address of the server when the table of the neighbors holds it, else to the broadcast hardware address with the server as the IPv4 destination.
- The transaction words come from the generator of the process, seeded from its context; the generator spends bytes only at a step of the client.
- While no address holds, the service reads no request of an endpoint: each one waits in its ring, and no frame of a process leaves from 0.0.0.0. It takes no frame but a DHCP reply: an ARP request or a segment for 0.0.0.0 names no machine.
- The line of the start of the service names the hardware address and the link; the address has its own line, `Address_Bound` or `Address_Static`, which the machine tests wait for.

## The machine case

The peer of the machine tests answers DHCP with its own code, not with the client package, so a fault of a field of the client is a fault that the peer sees. It answers the first DISCOVER with an OFFER whose router is outside the subnet, then with the correct OFFER: the scenario of the network waits for the refusal ("refused a DHCP reply (a router outside)") and then for the address 10.0.2.15/24. The peer does not answer a message with the option 60 (the vendor class of the firmware). A machine with QEMU user networking takes its address from the DHCP server of QEMU.

## Refused forms

- **The client in its own process.** The address is the state of the network service: a process that holds it would have to give it to the service at each change, and a hostile DHCP message would reach a second process.
- **A random wait** (the ±1 s of section 4.1): it serves many clients that start at once on one network; this service is one client, and a fixed order is a test that holds.
- **The address in the settings of the principal.** An address is a plan-only value: a principal who changes it changes the network of each other principal of the machine.

## Subtle points

- The service answers no ARP for an address that it does not hold yet: before the ACK, it holds 0.0.0.0, and the requests of the endpoints wait for the address.
- A lease that ends drops the address while endpoints are open: their requests wait until the next ACK, and the log says why once. A request that waits past the answer bound of its caller ends there, as with a slow service.
- Why a request waits and is not refused: a process that starts before the ACK would fail at once on a machine that has an address a few milliseconds later; the order of the starts would decide.
