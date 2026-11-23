# The address of the machine: DHCP, or a static address of the plan

State: **Decided.** Not built yet.

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

## Refused forms

- **The client in its own process.** The address is the state of the network service: a process that holds it would have to give it to the service at each change, and a hostile DHCP message would reach a second process.
- **A random wait** (the ±1 s of section 4.1): it serves many clients that start at once on one network; this service is one client, and a fixed order is a test that holds.
- **The address in the settings of the principal.** An address is a plan-only value: a principal who changes it changes the network of each other principal of the machine.

## Subtle points

- The service answers no ARP for an address that it does not hold yet: before the ACK, it holds 0.0.0.0, and the endpoints of the processes wait for the address.
- A lease that ends drops the address while endpoints are open: their sends are refused until the next ACK, and the log says why once.
