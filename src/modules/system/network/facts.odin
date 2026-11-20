package network_service

import "modus:contract/value_kinds"
import "modus:support/network"
import "modus:support/system"

// The log facts of the network service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the endpoints made,
// changed and ended, and the faults of the frame service, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. A line whose sentence differs by its case (a listen grant of TCP
// or of UDP, a grant with an address or none) is one fact type for each
// case: the template has no condition. No field has the name of a column
// of the head of facts(): number, time, process, level.
//
// The name of the process that owns an endpoint and an address are Text
// fields, and the last fields: the serial line of a fact stops at its last
// byte that is not zero. A Text field is [N]u8 with N written out, as the
// tool reads it.

// The bytes of the Text field of an IPv4 address: the longest,
// "255.255.255.255", has 15 bytes, and a zero byte.
ADDRESS_FIELD_BYTES :: 16
// The bytes of the Text field of the name of a command of the frame ring:
// the longest, "Read_Region_Remove", has 18 bytes.
COMMAND_FIELD_BYTES :: 24

// An endpoint with a listen grant of TCP.
@(log_fact = "network: an endpoint for {owner}: TCP, the listen port {listen_port}, the remotes that send to it")
Endpoint_Listens_Tcp :: struct {
	listen_port: u64,
	owner:       value_kinds.Module_Name_Field,
}

// An endpoint with a listen grant of UDP for the remotes of one address.
@(log_fact = "network: an endpoint for {owner}: UDP, the listen port {listen_port}, the remotes of the address {remote_address} only that send 1200 bytes to it")
Endpoint_Listens_Udp_From_Address :: struct {
	listen_port:    u64,
	owner:          value_kinds.Module_Name_Field,
	remote_address: [16]u8,
}

// An endpoint with a listen grant of UDP for any remote.
@(log_fact = "network: an endpoint for {owner}: UDP, the listen port {listen_port}, the remotes that send 1200 bytes to it")
Endpoint_Listens_Udp :: struct {
	listen_port: u64,
	owner:       value_kinds.Module_Name_Field,
}

// An endpoint with a client grant of TCP: a block of local ports.
@(log_fact = "network: an endpoint for {owner}: TCP, the local ports {first_local_port} to {last_local_port}, the grant {remote_address} port {remote_port}")
Endpoint_Connects_Tcp :: struct {
	first_local_port: u64,
	last_local_port:  u64,
	remote_port:      u64,
	owner:            value_kinds.Module_Name_Field,
	remote_address:   [16]u8,
}

// An endpoint with a client grant of UDP: one local port.
@(log_fact = "network: an endpoint for {owner}: the local port {local_port}, the grant {remote_address} port {remote_port}")
Endpoint_Connects_Udp :: struct {
	local_port:     u64,
	remote_port:    u64,
	owner:          value_kinds.Module_Name_Field,
	remote_address: [16]u8,
}

// The grant of an endpoint changed to a new remote.
@(log_fact = "network: the grant of the endpoint of {owner} changed: a new remote")
Endpoint_Grant_Changed_To_Remote :: struct {
	owner: value_kinds.Module_Name_Field,
}

// The grant of an endpoint changed to none: a revocation.
@(log_fact = "network: the grant of the endpoint of {owner} changed: none")
Endpoint_Grant_Changed_To_None :: struct {
	owner: value_kinds.Module_Name_Field,
}

// An endpoint ended, with the datagrams that it sent and received.
@(log_fact = "network: the endpoint of {owner} ended: {datagrams_sent} datagrams sent, {datagrams_received} received")
Endpoint_Ended :: struct {
	datagrams_sent:     u64,
	datagrams_received: u64,
	owner:              value_kinds.Module_Name_Field,
}

// The frame service did not answer a command by the bound of an answer:
// this service stops.
@(log_fact = "network: the frame service did not answer the command {command} in {bound}: this service stops")
Frame_Service_Silent :: struct {
	bound:   value_kinds.Time_In_Milliseconds,
	command: [24]u8,
}

// The frame service refused the datagram region of an endpoint as a read
// region. The status is the word that the frame service wrote, any u32,
// so the field is an Integer, as the line wrote it.
@(log_fact = "network: the frame service refused the datagram region of {owner} as a read region: status {status_word}")
Read_Region_Refused :: struct {
	status_word: u64,
	owner:       value_kinds.Module_Name_Field,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Endpoint_Listens_Udp_From_Address) == 8 + value_kinds.MODULE_NAME_FIELD_BYTES + ADDRESS_FIELD_BYTES)
#assert(size_of(Frame_Service_Silent) == 8 + COMMAND_FIELD_BYTES)
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
#assert(size_of(Ready_Link_Up) == 8 + INTERFACE_ADDRESS_FIELD_BYTES)
#assert(size_of(Payload_Passes_Checked) == 16 + value_kinds.MODULE_NAME_FIELD_BYTES + PROTOCOL_FIELD_BYTES)

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network, "no handle of the frame service with the right Read: a wait
// for the device would have no end", has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96
// The bytes of the Text field of the address of the interface: an IPv4
// address, its prefix and the hardware address, at most
// "255.255.255.255/24 ff:ff:ff:ff:ff:ff", 36 bytes, and a zero byte.
INTERFACE_ADDRESS_FIELD_BYTES :: 40
// The bytes of the Text field of the protocol of an endpoint: "TCP" or
// "UDP", and a zero byte.
PROTOCOL_FIELD_BYTES :: 8

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "network: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The service is ready, and the link of the device is up.
@(log_fact = "network: ok, the address {interface_address}, the gateway 10.0.2.2, the link is up, {receive_places} places for frames that arrive")
Ready_Link_Up :: struct {
	receive_places:    u64,
	interface_address: [40]u8,
}

// The service is ready, and the link of the device is down.
@(log_fact = "network: ok, the address {interface_address}, the gateway 10.0.2.2, the link is down, {receive_places} places for frames that arrive")
Ready_Link_Down :: struct {
	receive_places:    u64,
	interface_address: [40]u8,
}

// A measure: the time of the headers of IPv4 and Ethernet of one frame,
// in this process.
@(log_fact = "network: the headers of IPv4 and Ethernet of a frame with a payload of {payload_size}: {header_time}, in this process (no checksum of the payload)")
Headers_Measured :: struct {
	payload_size: value_kinds.Size_In_Bytes,
	header_time:  value_kinds.Time_In_Nanoseconds,
}

// The passes of the service over the data of an endpoint that ends are
// those of its design: one copy on receive, the check of each header on
// send, no byte of the data, no checksum.
@(log_fact = "network: the endpoint of {owner}, {protocol}: this service read each payload byte one time on receive, for the copy, and on send only the {header_bytes} of each header that it checks, and {data_bytes_read} of the data; it computed no checksum: as it must")
Payload_Passes_Checked :: struct {
	header_bytes:    value_kinds.Size_In_Bytes,
	data_bytes_read: value_kinds.Size_In_Bytes,
	owner:           value_kinds.Module_Name_Field,
	protocol:        [8]u8,
}

// The passes of the service over the data of an endpoint that ends are
// not those of its design.
@(log_fact = "network: the endpoint of {owner}, {protocol}: this service read each payload byte one time on receive, for the copy, and on send only the {header_bytes} of each header that it checks, and {data_bytes_read} of the data; it computed no checksum (WRONG)")
Payload_Passes_Wrong :: struct {
	header_bytes:    value_kinds.Size_In_Bytes,
	data_bytes_read: value_kinds.Size_In_Bytes,
	owner:           value_kinds.Module_Name_Field,
	protocol:        [8]u8,
}

// owner_field gives the Text field of the name of the process of an
// endpoint.
owner_field :: proc "contextless" (name: system.Name) -> value_kinds.Module_Name_Field {
	copied := name
	return value_kinds.module_name_field(system.name_of(copied[:]))
}

// command_field gives the Text field of the name of a command of the frame
// ring.
command_field :: proc "contextless" (name: string) -> [COMMAND_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, COMMAND_FIELD_BYTES)
}

// answer_bound_field gives the bound of an answer of the frame service as
// a time in milliseconds.
answer_bound_field :: proc "contextless" () -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(system.ANSWER_BOUND_MILLISECONDS)
}

// address_field gives the Text field of an IPv4 address, in the digits of
// the line before the fact.
address_field :: proc "contextless" (address: u32) -> [ADDRESS_FIELD_BYTES]u8 {
	text: [ADDRESS_FIELD_BYTES]u8
	writer := system.Writer{buffer = text[:]}
	network.address_write(&writer, address)
	return value_kinds.text_field(system.written(&writer), ADDRESS_FIELD_BYTES)
}
