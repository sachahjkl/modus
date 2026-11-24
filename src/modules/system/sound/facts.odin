package sound_device_service

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the sound service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the device found and
// ready, a device that does not answer, and the requests and the periods
// that the device refuses, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. No field has the name
// of a column of the head of facts(): number, time, process, level.
//
// The name of a control request is a Text field, and the last field: the
// serial line of a fact stops at its last byte that is not zero. A Text
// field is [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of the name of a control request: the
// longest, "PCM_SET_PARAMS", has 14 bytes, and a zero byte, on 8 bytes.
REQUEST_FIELD_BYTES :: 16

// The device did not answer a control request of the start by its bound:
// the service stops.
@(log_fact = "sound: the device did not answer {request} in {bound}")
Device_Silent :: struct {
	bound:   value_kinds.Time_In_Milliseconds,
	request: [16]u8,
}

// The device answered a control request with fewer bytes than its code.
@(log_fact = "sound: the device answered {request} with {answer_length}, fewer than its code")
Answer_Too_Short :: struct {
	answer_length: value_kinds.Size_In_Bytes,
	request:       [16]u8,
}

// The device refused a control request with a code of its own.
@(log_fact = "sound: the device refused {request} with the code {answer_code}")
Request_Refused :: struct {
	answer_code: u64,
	request:     [16]u8,
}

// The answer of the device to PCM_INFO does not hold the streams asked.
@(log_fact = "sound: the device answered PCM_INFO for {streams} streams with {answer_length}")
Stream_Information_Too_Short :: struct {
	streams:       u64,
	answer_length: value_kinds.Size_In_Bytes,
}

// The device refused PCM_INFO with a code of its own.
@(log_fact = "sound: the device refused PCM_INFO with the code {answer_code}")
Stream_Information_Refused :: struct {
	answer_code: u64,
}

// The device has no output stream of the one format: the service stops.
@(log_fact = "sound: the device has {streams} streams, and none plays 48000 frames in one second of 2 channels of signed 16-bit samples")
No_Stream_Of_The_Format :: struct {
	streams: u64,
}

// The device is ready: the service chose its output stream and prepared
// it.
@(log_fact = "sound: ok, the output stream {stream} of {streams}, 48000 frames in one second, 2 channels of signed 16-bit samples; {periods} periods of {period_frames} frames with the device; a transmit queue of {transmit_queue}")
Device_Ready :: struct {
	stream:         u64,
	streams:        u64,
	periods:        u64,
	period_frames:  u64,
	transmit_queue: u64,
}

// The device answered a period with a code that is not Ok: the service
// stops.
@(log_fact = "sound: the device answered a period with the code {answer_code}")
Period_Refused :: struct {
	answer_code: u64,
}

// The tool reads the length of a Text field as a literal: the constant
// names the same bytes.
#assert(size_of(Device_Silent) == 8 + REQUEST_FIELD_BYTES)

// request_field gives the Text field of the name of a control request.
request_field :: proc "contextless" (name: string) -> [REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, REQUEST_FIELD_BYTES)
}

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "sound: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The stream started: the time of the system clock of its frame 0, and
// the time that the service holds before the device.
@(log_fact = "sound: the stream started: the frame 0 plays at {frame_zero_time} of the system clock; the service holds {held_time}")
Stream_Started :: struct {
	frame_zero_time: value_kinds.Time_In_Nanoseconds,
	held_time:       value_kinds.Time_In_Nanoseconds,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

// The queues do not map, or have no device address: each status by the
// name of its member.
@(log_fact = "sound: the map of the queues gave the status {map_status}, their device address the status {address_status}")
Queues_Not_Mapped :: struct {
	map_status:     call_outcome.Call_Outcome,
	address_status: call_outcome.Call_Outcome,
}

// The kernel gave no memory for the periods.
@(log_fact = "sound: the memory of the periods gave the status {status}")
Periods_Memory_Refused :: struct {
	status: call_outcome.Call_Outcome,
}

// The periods do not map, or have no device address.
@(log_fact = "sound: the map of the periods gave the status {map_status}, their device address the status {address_status}")
Periods_Not_Mapped :: struct {
	map_status:     call_outcome.Call_Outcome,
	address_status: call_outcome.Call_Outcome,
}

// The first hold of the stream.
@(log_fact = "sound: the first hold: the device took the periods faster than their time; the service gives the next one when the time comes, and counts each hold")
First_Hold :: struct {}

// The first underrun of the stream.
@(log_fact = "sound: the first underrun: the device took each period before the next one came; the next frame plays now, and each completion counts the underruns")
First_Underrun :: struct {}

// bytes_field gives a count of bytes as a field with its unit.
bytes_field :: proc "contextless" (count: u32) -> value_kinds.Size_In_Bytes {
	return value_kinds.Size_In_Bytes(count)
}
