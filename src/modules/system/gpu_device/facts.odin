package gpu_device_service

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the GPU device service: device readiness, Venus capability
// probing, 2D scanout binding, and fatal device failures. Each Text field uses
// a literal [N]u8 length as the tool reads it.

FAILURE_FIELD_BYTES :: 96
REQUEST_FIELD_BYTES :: 32
REASON_FIELD_BYTES :: 64

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

// The service created its Venus context. A ring that is not mapped has the
// cache 0; a context with no ring blob has the ring resource 0.
@(log_fact = "gpu_device: venus context {context_id} ready for vk.xml {vk_xml_version}, ring resource {ring_resource_id} with the cache {ring_cache}")
Venus_Context_Ready :: struct {
	context_id:       u64,
	vk_xml_version:   u64,
	ring_resource_id: u64,
	ring_cache:       u64,
}

// A device with a 3D feature carries no Venus: the service keeps its 2D
// scanout only.
@(log_fact = "gpu_device: 2D scanout only, {reason}")
Venus_Unavailable :: struct {
	reason: [64]u8,
}

// A client framebuffer was bound to a 2D scanout resource.
@(log_fact = "gpu_device: scanout {scanout} bound to resource {resource_id} at {width} x {height}")
Scanout_Bound :: struct {
	scanout:     u64,
	resource_id: u64,
	width:       u64,
	height:      u64,
}

// The first frame of a scanout: its rectangles went to the device in one
// batch, which the device used whole (src/md/infrastructure/whole_frame.md,
// "The screen through the scanout of the virtual GPU").
@(log_fact = "gpu_device: the first frame of resource {resource_id}: {rectangles} rectangles in one batch of {requests} requests")
Frame_Batch_First :: struct {
	resource_id: u64,
	rectangles:  u64,
	requests:    u64,
}

// The queue memory could not be mapped or translated for DMA.
@(log_fact = "gpu_device: the map of the queue gave the status {map_status}, its device address the status {address_status}")
Queue_Not_Mapped :: struct {
	map_status:     call_outcome.Call_Outcome,
	address_status: call_outcome.Call_Outcome,
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
#assert(size_of(Venus_Context_Ready) == 4 * 8)
#assert(size_of(Venus_Unavailable) == REASON_FIELD_BYTES)

request_field :: proc "contextless" (name: string) -> [REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, REQUEST_FIELD_BYTES)
}
