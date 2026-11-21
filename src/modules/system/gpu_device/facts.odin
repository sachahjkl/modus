package gpu_device_service

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the GPU device service: device readiness, Venus capability
// probing, 2D scanout binding, and fatal device failures. Each Text field uses
// a literal [N]u8 length as the tool reads it.

FAILURE_FIELD_BYTES :: 96
REQUEST_FIELD_BYTES :: 32

// The service stops on a fatal device or contract failure.
@(log_fact = "gpu_device: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The VirtIO-GPU device is ready after display info and capability probing.
@(log_fact = "gpu_device: ok, scanout {scanout} at {width} x {height}, queue of {queue_size}, capsets {capsets}")
Device_Ready :: struct {
	scanout:    u64,
	width:      u64,
	height:     u64,
	queue_size: u64,
	capsets:    u64,
}

// A Venus Vulkan capability set was reported by the host virtual GPU.
@(log_fact = "gpu_device: venus capset available, max version {max_version}, max size {max_size}")
Venus_Probed :: struct {
	max_version: u64,
	max_size:    u64,
}

// A client framebuffer was bound to a 2D scanout resource.
@(log_fact = "gpu_device: scanout {scanout} bound to resource {resource_id} at {width} x {height}")
Scanout_Bound :: struct {
	scanout:     u64,
	resource_id: u64,
	width:       u64,
	height:      u64,
}

// The queue memory could not be mapped or translated for DMA.
@(log_fact = "gpu_device: the map of the queue gave the status {map_status}, its device address the status {address_status}")
Queue_Not_Mapped :: struct {
	map_status:     op.Status,
	address_status: op.Status,
}

// The device did not answer a control queue command within the hang bound.
@(log_fact = "gpu_device: the device did not answer {request} in {bound}")
Device_Silent :: struct {
	bound:   value_kinds.Time_In_Milliseconds,
	request: [32]u8,
}

// The device answered a control queue command with an error response word.
@(log_fact = "gpu_device: the device refused {request} with the response {response_word}")
Request_Refused :: struct {
	response_word: u64,
	request:       [32]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
#assert(size_of(Device_Silent) == 8 + REQUEST_FIELD_BYTES)
#assert(size_of(Request_Refused) == 8 + REQUEST_FIELD_BYTES)

request_field :: proc "contextless" (name: string) -> [REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, REQUEST_FIELD_BYTES)
}
