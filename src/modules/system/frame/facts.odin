package frame_service

import "modus:contract/value_kinds"

// The log facts of the frame service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the device found and
// ready, as a record of fields. The fact template is the sentence that the
// line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. The state of the link is one fact type for
// each state: the template has no condition. No field has the name of a
// column of the head of facts(): number, time, process, level.

// The bytes of the Text field of a hardware address: six hexadecimal pairs
// with ":" between them, 17 bytes, and a zero byte, on 8 bytes.
HARDWARE_ADDRESS_FIELD_BYTES :: 24

// The device is ready, and its link is up.
@(log_fact = "frame: ok, the hardware address {hardware_address}, the link is up, queues of {receive_queue} and {send_queue}, {places} places for frames that arrive")
Device_Ready_Link_Up :: struct {
	receive_queue:    u64,
	send_queue:       u64,
	places:           u64,
	hardware_address: [24]u8,
}

// The device is ready, and its link is down.
@(log_fact = "frame: ok, the hardware address {hardware_address}, the link is down, queues of {receive_queue} and {send_queue}, {places} places for frames that arrive")
Device_Ready_Link_Down :: struct {
	receive_queue:    u64,
	send_queue:       u64,
	places:           u64,
	hardware_address: [24]u8,
}

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "frame: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// A read region that the service holds for the sends of a client, at its
// place among the read regions.
@(log_fact = "frame: a read region of {region_size} at the place {place}, held with the right Read only: the device reads the data of the frames to send there")
Read_Region_Added :: struct {
	region_size: value_kinds.Size_In_Pages,
	place:       u64,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Device_Ready_Link_Up) == 24 + HARDWARE_ADDRESS_FIELD_BYTES)
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

// hardware_address_field gives the Text field of the hardware address of
// the device, in the digits of the line before the fact.
hardware_address_field :: proc "contextless" () -> [HARDWARE_ADDRESS_FIELD_BYTES]u8 {
	text: [HARDWARE_ADDRESS_FIELD_BYTES]u8
	return value_kinds.text_field(hardware_text(text[:]), HARDWARE_ADDRESS_FIELD_BYTES)
}
