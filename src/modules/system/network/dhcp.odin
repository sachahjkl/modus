package network_service

// The address of the machine (src/md/features/dhcp_client.md): a static
// address that the plan of principal 0 gives, or the address that the
// DHCP client takes (internal:network/dhcp_client, pure code with its host
// tests). This file is the input and output of the client: it gives the
// client the time and each datagram to UDP port 68, and sends what the
// client writes.

import "internal:network/dhcp_client"
import "modus:contract/value_kinds"
import "modus:network"
import "modus:random"
import "modus:system"

// The address in force: 0.0.0.0 until the plan or a lease gives one. Each
// check of a frame and of an endpoint reads these.
local_address: u32
gateway_address: u32
network_mask: u32
address_prefix: u8

// The client, when the plan gives no static address.
dhcp: dhcp_client.Client
dhcp_in_use: bool
dhcp_generator: random.Generator // The transaction words: never a counter that another machine guesses.
dhcp_message: [dhcp_client.MESSAGE_CAPACITY]u8

// address_start takes the static address of the plan, or starts the
// client. A static address of the plan that its border refuses starts the
// client, and the log says it.
address_start :: proc "contextless" (ctx: ^system.Context, now: u64) {
	plan, _ := system.plan_values_of_process(&ctx.values)
	static, found, refused := dhcp_client.static_of(plan)
	if found && !refused {
		address_take(static.address, static.mask, static.prefix, static.gateway)
		system.log_fact(.Info, Address_Static{address = address_field(static.address), prefix = u64(static.prefix), gateway = address_field(static.gateway)})
		return
	}
	if refused {
		system.log_fact(.Warning, Address_Static_Refused{})
	}
	if !random.generator_from_context(&dhcp_generator, ctx) {
		system.log_fact(.Error, Address_No_Seed{})
		return
	}
	dhcp_client.client_start(&dhcp, hardware, now)
	dhcp_in_use = true
}

// address_take makes an address the address in force.
@(private = "file")
address_take :: proc "contextless" (address, mask: u32, prefix: u8, gateway: u32) {
	local_address, network_mask, address_prefix, gateway_address = address, mask, prefix, gateway
}

// dhcp_step runs the client at the time now and gives the time of its
// next step, or max(u64).
dhcp_step :: proc "contextless" (now: u64) -> (deadline: u64) {
	if !dhcp_in_use {
		return max(u64)
	}
	if now < dhcp.deadline {
		return dhcp.deadline
	}
	// A fresh transaction word only when a step is due: the generator
	// spends nothing at the other turns of the loop.
	word: [4]u8
	random.fill(&dhcp_generator, word[:])
	output := dhcp_client.client_tick(&dhcp, dhcp_message[:], now, transmute(u32)word)
	dhcp_output(output)
	return dhcp.deadline
}

// dhcp_arrived gives the client one datagram from port 67 to port 68: the
// whole datagram, its header included; a datagram whose UDP header or
// checksum is wrong reaches nothing.
dhcp_arrived :: proc "contextless" (packet: network.Packet, now: u64) {
	if !dhcp_in_use {
		return
	}
	data, ok := network.udp_data_read(packet.data, packet.source_address, packet.destination_address, .Verify)
	if !ok {
		return
	}
	output, problem := dhcp_client.client_receive(&dhcp, data, dhcp_message[:], now)
	if problem != .None {
		system.log_fact(.Warning, Address_Reply_Refused{reply_problem = value_kinds.text_field(REPLY_PROBLEM_NAMES[problem], 24)})
		return
	}
	dhcp_output(output)
}

// dhcp_output sends the message of an output and applies its event.
@(private = "file")
dhcp_output :: proc "contextless" (output: dhcp_client.Output) {
	switch output.event {
	case .None:
	case .Bound, .Renewed:
		lease := dhcp.lease
		address_take(lease.address, lease.mask, lease.prefix, lease.router)
		if output.event == .Bound {
			system.log_fact(.Info, Address_Bound{address = address_field(lease.address), prefix = u64(lease.prefix), gateway = address_field(lease.router), lease = value_kinds.Time_In_Seconds(i64(lease.lease_seconds))})
		}
	case .Lost:
		system.log_fact(.Warning, Address_Lost{address = address_field(local_address)})
		address_take(0, 0, 0, 0)
	}
	if !output.send {
		return
	}
	place, taken := send_place_take()
	if !taken {
		return // The next send of the client comes after its wait.
	}
	frame_bytes := place_bytes(place)
	copy(frame_bytes[network.IPV4_DATA + network.UDP_HEADER:], dhcp_message[:output.length])
	source := output.broadcast ? 0 : local_address
	destination := output.broadcast ? 0xFFFF_FFFF : output.destination
	length := network.udp_header_write(frame_bytes[network.IPV4_DATA:], source, destination, dhcp_client.CLIENT_PORT, dhcp_client.SERVER_PORT, output.length)
	hardware_to := network.BROADCAST
	if !output.broadcast {
		if found, known := neighbor_of(destination); known {
			hardware_to = found
		}
	}
	total := network.ipv4_frame(frame_bytes, hardware_to, hardware, source, destination, network.PROTOCOL_UDP, length, next_identification())
	if length == 0 || total == 0 {
		send_place_free(place)
		return
	}
	frame_send(place, total)
}

// The name of each problem of a reply, for a line of the log.
@(rodata)
REPLY_PROBLEM_NAMES := [dhcp_client.Reply_Problem]string {
	.None              = "none",
	.Too_Short         = "too short",
	.Not_A_Reply       = "not a reply",
	.Not_Ethernet      = "not Ethernet",
	.Other_Transaction = "another transaction",
	.Other_Client      = "another client",
	.No_Cookie         = "no magic cookie",
	.Option_Past_End   = "an option past its end",
	.Bytes_After_End   = "bytes after the end",
	.Option_Twice      = "an option twice",
	.Bad_Option_Length = "an option length",
	.No_Message_Type   = "no message type",
	.Bad_Message_Type  = "a message type",
	.No_Server         = "no server",
	.No_Lease          = "no lease",
	.Zero_Lease        = "a lease of 0",
	.Bad_Mask          = "a mask",
	.Bad_Address       = "an address",
	.Router_Outside    = "a router outside",
	.Bad_Times         = "the times",
	.Overload          = "an overload",
}
