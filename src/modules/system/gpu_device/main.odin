// The GPU device service: the device service of one VirtIO-GPU 1.2 PCI device
// (vendor 0x1AF4, device 0x1050). It verifies the PCI identity, negotiates
// VirtIO-GPU features, drives the control queue for 2D scanout setup and
// the present of whole frames in one batch each (Get_Display_Info, Resource_Create_2D,
// Resource_Attach_Backing, Set_Scanout, Transfer_To_Host_2D, Resource_Flush,
// Resource_Unref), and, when the device carries Venus, creates one Venus
// context with the blob of its command ring and submits client Venus streams
// with Submit_3D (src/md/features/gpu_access.md). A device with no Venus keeps
// its 2D scanout unchanged.
//
// It holds only its one PCI device (registers, interrupt, queue memory,
// configuration copy, machine physical handle) and its client ring. No driver
// code lives in the kernel.
package gpu_device_service

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:contract/venus_vulkan"
import "modus:contract/virtio_gpu"
import "modus:pci"
import "modus:system"
import "modus:virtio"

// Memory layout inside pci.GRANT_QUEUES (pci.QUEUE_PAGES == 8):
// pages 0..2 hold the control virtqueue, pages 3..6 hold the outbound
// command buffer, and page 7 holds the inbound response buffer. The command
// buffer is four pages so that one Submit_3D carries a client Venus stream.
PAGE_CONTROL_QUEUE :: 0
PAGE_REQUEST_BUFFER :: PAGE_CONTROL_QUEUE + virtio.QUEUE_PAGES
REQUEST_BUFFER_PAGES :: 4
PAGE_RESPONSE_BUFFER :: PAGE_REQUEST_BUFFER + REQUEST_BUFFER_PAGES
#assert(PAGE_RESPONSE_BUFFER < pci.QUEUE_PAGES)

REQUEST_BUFFER_BYTES :: REQUEST_BUFFER_PAGES * system.PAGE_SIZE
// The largest response that the service reads: the display info.
RESPONSE_COPY_BYTES :: virtio_gpu.RESP_DISPLAY_INFO_SIZE
MAX_CAPSETS_PROBED :: u32(16)
DEVICE_ANSWER_BOUND_MILLISECONDS :: system.ANSWER_BOUND_MILLISECONDS

// The one Venus context of the service and its command ring blob.
VENUS_CONTEXT_ID :: u32(1)
VENUS_CONTEXT_NAME :: "modus-venus"
VENUS_RING_BUFFER_BYTES :: u32(64 * 1024)
VENUS_RING_BLOB_BYTES :: (u64(venus_vulkan.RING_BUFFER_OFFSET) + u64(VENUS_RING_BUFFER_BYTES) + system.PAGE_SIZE - 1) / system.PAGE_SIZE * system.PAGE_SIZE
MAX_VENUS_SUBMIT_BYTES :: REQUEST_BUFFER_BYTES - virtio_gpu.SUBMIT_3D_HEADER_SIZE
#assert(virtio_gpu.CTRL_HEADER_SIZE + venus_vulkan.VENUS_CAPSET_BYTES <= RESPONSE_COPY_BYTES)
#assert(virtio_gpu.RESP_MAP_INFO_SIZE <= RESPONSE_COPY_BYTES)

// VirtIO-GPU feature mask requested during negotiation: Virgl 3D, blob
// resources, and context init (for Venus capset contexts).
WANTED_FEATURES :: u32((1 << virtio_gpu.FEATURE_VIRGL) | (1 << virtio_gpu.FEATURE_RESOURCE_BLOB) | (1 << virtio_gpu.FEATURE_CONTEXT_INIT))

device: virtio.Device
control_queue: virtio.Queue
request_buffer: [^]u8
request_physical: u64
response_buffer: [^]u8
response_physical: u64

machine: system.Handle
clients: ring.Ring
ring_memory: system.Handle

// Negotiated features and device configuration metadata.
offered_features: u32
has_virgl: bool
has_resource_blob: bool
has_context_init: bool
num_scanouts: u32
num_capsets: u32

// Active scanout geometry discovered via Get_Display_Info.
active_scanout_id: u32
display_width: u32
display_height: u32

// Venus capability metadata discovered via Get_Capset_Info.
venus_available: bool
venus_max_version: u32
venus_max_size: u32

// The Venus context: 0 when the device carries no Venus. The ring blob is a
// host blob attached to the context; its mapping into a process waits for the
// device mapping of the kernel, so the service reports its cache type only.
venus_support: virtio_gpu.Venus_Support
venus_capset: venus_vulkan.Venus_Capset
venus_context_id: u32
venus_ring_resource_id: u32
venus_ring_cache: virtio_gpu.Map_Cache

// Currently attached 2D scanout framebuffer, and its mapping in this
// service: the service reads the present list of its last page.
framebuffer_memory: system.Handle
framebuffer_mapping: rawptr
framebuffer_physical: u64
framebuffer_size: u64
framebuffer_width: u32
framebuffer_height: u32
framebuffer_resource_id: u32
framebuffer_frames: u64 // The frames presented on the bound resource.
next_resource_id: u32 = 1

// The size of one TRANSFER_TO_HOST_2D and of one RESOURCE_FLUSH request in
// the request buffer, and of one answer in the response buffer.
BATCH_REQUEST_SLOT_BYTES :: 64
BATCH_RESPONSE_SLOT_BYTES :: virtio_gpu.CTRL_HEADER_SIZE
#assert(virtio_gpu.TRANSFER_TO_HOST_2D_SIZE <= BATCH_REQUEST_SLOT_BYTES && virtio_gpu.RESOURCE_FLUSH_SIZE <= BATCH_REQUEST_SLOT_BYTES)
#assert(2 * virtio_gpu.PRESENT_RECTANGLE_CAPACITY * BATCH_REQUEST_SLOT_BYTES <= REQUEST_BUFFER_BYTES)
#assert(2 * virtio_gpu.PRESENT_RECTANGLE_CAPACITY * BATCH_RESPONSE_SLOT_BYTES <= system.PAGE_SIZE)

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// control_exchange submits request_bytes from request_buffer on control_queue
// and waits for the device response in response_buffer up to the hang bound.
// The response is copied once out of DMA memory before validation.
control_exchange :: proc "contextless" (name: string, request_bytes: u32, expected_response_bytes: u32) -> (response: [RESPONSE_COPY_BYTES]u8, received: u32, ok: bool) {
	if request_bytes == 0 || request_bytes > REQUEST_BUFFER_BYTES || expected_response_bytes == 0 || expected_response_bytes > len(response) {
		return {}, 0, false
	}
	control_queue.descriptors[0] = {
		address = request_physical,
		length  = request_bytes,
		flags   = virtio.DESCRIPTOR_NEXT,
		next    = 1,
	}
	control_queue.descriptors[1] = {
		address = response_physical,
		length  = expected_response_bytes,
		flags   = virtio.DESCRIPTOR_DEVICE_WRITES,
	}
	virtio.give(&control_queue, 0)
	virtio.notify(&control_queue)

	deadline := system.time() + DEVICE_ANSWER_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		if used, got := virtio.used(&control_queue); got {
			if used.id != 0 {
				fail("the device answered a control request that was not given")
			}
			received = min(used.length, expected_response_bytes)
			if received > 0 {
				intrinsics.mem_copy_non_overlapping(&response[0], response_buffer, int(received))
			}
			return response, received, true
		}
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			fail("the device needs a reset")
		}
		if system.time() >= deadline {
			// The descriptors stay with the device: a later request on them
			// can receive the answer of this one, or let the device write
			// the response buffer while the service reads it. The service
			// stops, and the device is no longer used.
			system.log_fact(.Error, Device_Silent{bound = DEVICE_ANSWER_BOUND_MILLISECONDS, request = request_field(name)})
			fail("the device did not answer a control request")
		}
		system.wait_end(&wait, deadline)
	}
}

// control_nodata runs one control queue command expecting Response_Ok_Nodata.
control_nodata :: proc "contextless" (name: string, request_bytes: int) -> (header: virtio_gpu.Ctrl_Header, ok: bool) {
	response, received, answered := control_exchange(name, u32(request_bytes), virtio_gpu.CTRL_HEADER_SIZE)
	if !answered {
		return {}, false
	}
	decoded, problem := virtio_gpu.nodata_response_decode(response[:received])
	if problem != .None {
		if problem == .Device_Error_Response {
			system.log_fact(.Error, Request_Refused{response_word = u64(decoded.command_type), request = request_field(name)})
		}
		return decoded, false
	}
	return decoded, true
}

// query_display_info executes Get_Display_Info and selects the first enabled scanout.
query_display_info :: proc "contextless" () {
	written, enc_problem := virtio_gpu.get_display_info_encode(request_buffer[:REQUEST_BUFFER_BYTES])
	if enc_problem != .None {
		fail("failed to encode Get_Display_Info")
	}
	response, received, answered := control_exchange("GET_DISPLAY_INFO", u32(written), virtio_gpu.RESP_DISPLAY_INFO_SIZE)
	if !answered {
		fail("the device did not answer GET_DISPLAY_INFO")
	}
	info, dec_problem := virtio_gpu.display_info_response_decode(response[:received])
	if dec_problem != .None {
		if dec_problem == .Device_Error_Response {
			system.log_fact(.Error, Request_Refused{response_word = u64(info.header.command_type), request = request_field("GET_DISPLAY_INFO")})
		}
		fail("the device returned a display info response that breaks the virtio GPU contract")
	}
	limit := min(num_scanouts, u32(virtio_gpu.MAX_SCANOUTS))
	for scanout in u32(0) ..< limit {
		entry := info.displays[scanout]
		if entry.enabled != 0 && entry.rect.width > 0 && entry.rect.height > 0 {
			active_scanout_id = scanout
			display_width = entry.rect.width
			display_height = entry.rect.height
			return
		}
	}
	active_scanout_id = 0
	display_width = info.displays[0].rect.width
	display_height = info.displays[0].rect.height
}

// probe_venus_capsets iterates reported capability sets looking for Capset_Id.Venus.
probe_venus_capsets :: proc "contextless" () {
	if !has_virgl || !has_context_init || num_capsets == 0 {
		return
	}
	limit := min(num_capsets, MAX_CAPSETS_PROBED)
	for capset_index in u32(0) ..< limit {
		written, enc_problem := virtio_gpu.get_capset_info_encode(capset_index, request_buffer[:REQUEST_BUFFER_BYTES])
		if enc_problem != .None {
			continue
		}
		response, received, answered := control_exchange("GET_CAPSET_INFO", u32(written), virtio_gpu.RESP_CAPSET_INFO_SIZE)
		if !answered {
			fail("the device did not answer GET_CAPSET_INFO")
		}
		capset, dec_problem := virtio_gpu.capset_info_response_decode(response[:received])
		if dec_problem != .None {
			continue
		}
		if capset.capset_id == .Venus {
			venus_available = true
			venus_max_version = capset.capset_max_version
			venus_max_size = capset.capset_max_size
			system.log_fact(.Info, Venus_Probed{max_version = u64(venus_max_version), max_size = u64(venus_max_size)})
			return
		}
	}
}

// venus_unavailable records why the device carries no Venus. A device with no
// 3D feature is the common 2D case and logs nothing more.
venus_unavailable :: proc "contextless" (reason: string) {
	venus_context_id = 0
	if has_virgl {
		system.log_fact(.Info, Venus_Unavailable{reason = value_kinds.text_field(reason, REASON_FIELD_BYTES)})
	}
}

// venus_context_start creates the Venus context when the device carries
// Venus: Get_Capset, Ctx_Create with the Venus capset, then the blob of the
// command ring (Resource_Create_Blob, Ctx_Attach_Resource, Resource_Map_Blob).
// A refusal before Ctx_Create leaves the service with 2D scanout only; a
// refusal after it leaves the context without a ring, and Submit_3D still
// carries the client streams.
venus_context_start :: proc "contextless" () {
	venus_support = virtio_gpu.venus_support_check(offered_features, venus_available)
	switch venus_support {
	case .Available:
	case .No_Virgl_Feature:
		venus_unavailable("the device has no virgl feature")
		return
	case .No_Resource_Blob_Feature:
		venus_unavailable("the device has no blob feature")
		return
	case .No_Context_Init_Feature:
		venus_unavailable("the device has no context init feature")
		return
	case .No_Venus_Capset:
		venus_unavailable("the device has no venus capset")
		return
	}

	capset_written, capset_problem := virtio_gpu.get_capset_encode(.Venus, venus_max_version, request_buffer[:REQUEST_BUFFER_BYTES])
	if capset_problem != .None {
		venus_unavailable("GET_CAPSET was not encoded")
		return
	}
	capset_bytes := min(venus_max_size, RESPONSE_COPY_BYTES - virtio_gpu.CTRL_HEADER_SIZE) &~ 3
	response, received, answered := control_exchange("GET_CAPSET", u32(capset_written), virtio_gpu.CTRL_HEADER_SIZE + capset_bytes)
	if !answered {
		venus_unavailable("the device did not answer GET_CAPSET")
		return
	}
	capset_response, response_problem := virtio_gpu.capset_response_decode(response[:received])
	if response_problem != .None {
		venus_unavailable("the device refused GET_CAPSET")
		return
	}
	capset_problem_venus: venus_vulkan.Venus_Problem
	venus_capset, capset_problem_venus = venus_vulkan.venus_capset_decode(capset_response.data[:len(capset_response.data) &~ 3])
	if capset_problem_venus != .None {
		venus_unavailable("the venus capset is not of wire format 1")
		return
	}

	create_written, create_problem := virtio_gpu.ctx_create_encode(VENUS_CONTEXT_ID, .Venus, VENUS_CONTEXT_NAME, request_buffer[:REQUEST_BUFFER_BYTES])
	if create_problem != .None {
		venus_unavailable("CTX_CREATE was not encoded")
		return
	}
	if _, ok := control_nodata("CTX_CREATE", create_written); !ok {
		venus_unavailable("the device refused CTX_CREATE")
		return
	}
	venus_context_id = VENUS_CONTEXT_ID
	venus_ring_start()
	system.log_fact(.Info, Venus_Context_Ready{
		context_id       = u64(venus_context_id),
		vk_xml_version   = u64(venus_capset.vk_xml_version),
		ring_resource_id = u64(venus_ring_resource_id),
		ring_cache       = u64(venus_ring_cache),
	})
}

// venus_ring_start creates the host blob of the command ring and asks its
// cache type. A blob with id 0 is shared memory of the renderer; a host that
// does not announce it gets no ring.
venus_ring_start :: proc "contextless" () {
	if !venus_capset.supports_blob_id_0 {
		return
	}
	resource_id := next_resource_id
	blob_written, blob_problem := virtio_gpu.resource_create_blob_encode(venus_context_id, resource_id, .Host3D, {.Use_Mappable}, 0, 0, VENUS_RING_BLOB_BYTES, request_buffer[:REQUEST_BUFFER_BYTES])
	if blob_problem != .None {
		return
	}
	if _, ok := control_nodata("RESOURCE_CREATE_BLOB", blob_written); !ok {
		return
	}
	next_resource_id += 1
	if next_resource_id == 0 {
		next_resource_id = 1
	}
	venus_ring_resource_id = resource_id
	attach_written, attach_problem := virtio_gpu.ctx_attach_resource_encode(venus_context_id, resource_id, request_buffer[:REQUEST_BUFFER_BYTES])
	if attach_problem != .None {
		return
	}
	if _, ok := control_nodata("CTX_ATTACH_RESOURCE", attach_written); !ok {
		return
	}
	map_written, map_problem := virtio_gpu.resource_map_blob_encode(resource_id, 0, request_buffer[:REQUEST_BUFFER_BYTES])
	if map_problem != .None {
		return
	}
	response, received, answered := control_exchange("RESOURCE_MAP_BLOB", u32(map_written), virtio_gpu.RESP_MAP_INFO_SIZE)
	if !answered {
		return
	}
	map_info, info_problem := virtio_gpu.map_info_response_decode(response[:received])
	if info_problem != .None {
		return
	}
	venus_ring_cache = map_info.cache
}

// venus_submit sends a client Venus stream to the context with Submit_3D.
// The stream is copied out of the client memory first and decoded whole, so
// the device receives the bytes that the service checked.
venus_submit :: proc "contextless" (command: ring.Record) -> (status: virtio_gpu.Service_Status, values: [7]u64) {
	SUBMIT :: u32(virtio_gpu.Service_Command.Venus_Submit)
	handle := system.Handle(command.values[0])
	kind, rights, through := system.handle_state(handle, ring_memory)
	// A handle that came through the ring belongs to the service now.
	defer {
		if through {
			system.close(handle)
		}
	}
	// A handle that did not come through the ring is one of the service:
	// its kind and its rights say nothing of the client.
	needed := system.Rights{.Read}
	switch {
	case !through:
		return .Bad_Command, errors.ring_fail(SUBMIT, .Absent, .Region, 1)
	case kind != .Memory:
		return .Bad_Command, errors.ring_fail(SUBMIT, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind))
	case !(needed <= rights):
		return .Bad_Command, errors.ring_fail(SUBMIT, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights))
	}
	if venus_context_id == 0 {
		return .Unsupported, errors.ring_fail(SUBMIT, .Unsupported, .None, 0)
	}
	offset := command.values[1]
	length := command.values[2]
	if length == 0 || length % 4 != 0 || length > MAX_VENUS_SUBMIT_BYTES {
		return .Out_Of_Range, errors.ring_fail(SUBMIT, .Bad_Value, .Bytes, 3, i64(min(length, 1 << 62)), MAX_VENUS_SUBMIT_BYTES)
	}
	pages, size_status := system.memory_size(handle)
	if size_status != .Succeeded {
		return .Bad_Command, errors.ring_fail(SUBMIT, .Refused, .None, 1, i64(handle), 0, i64(size_status))
	}
	region_bytes := pages * system.PAGE_SIZE
	if offset > region_bytes || length > region_bytes - offset {
		return .Out_Of_Range, errors.ring_fail(SUBMIT, .Out_Of_Range, .Bytes, 2, i64(min(offset, 1 << 62)), i64(region_bytes))
	}
	address, map_status := system.memory_map(handle, {})
	if map_status != .Succeeded {
		return .Bad_Command, errors.ring_fail(SUBMIT, .Refused, .None, 1, i64(handle), 0, i64(map_status))
	}
	payload := request_buffer[virtio_gpu.SUBMIT_3D_HEADER_SIZE:][:length]
	intrinsics.mem_copy_non_overlapping(raw_data(payload), rawptr(uintptr(address) + uintptr(offset)), int(length))
	system.memory_unmap(address)

	// A client sends rendering and resource commands only: the ring and the
	// reply stream of the context belong to this service.
	if _, stream_problem := venus_vulkan.stream_validate_client(payload); stream_problem != .None {
		return .Bad_Command, errors.ring_fail(SUBMIT, .Bad_Value, .None, 1, i64(stream_problem))
	}
	header_written, header_problem := virtio_gpu.submit_3d_header_encode(venus_context_id, int(length), request_buffer[:REQUEST_BUFFER_BYTES])
	if header_problem != .None {
		return .Bad_Command, errors.ring_fail(SUBMIT, .Bad_Value, .None, 0, i64(header_problem))
	}
	if _, ok := control_nodata("SUBMIT_3D", header_written + int(length)); !ok {
		return .Device_Error, errors.ring_fail(SUBMIT, .Device, .None, 0)
	}
	return .Ok, {0 = length}
}

// start_device negotiates VirtIO-GPU features, initializes controlq, queries
// display geometry, probes Venus capability sets, and creates the Venus
// context when the device carries Venus.
start_device :: proc "contextless" (queues: system.Handle) {
	offered, start_error := virtio.start(&device, WANTED_FEATURES)
	switch start_error {
	case .None:
	case .No_Version_1:
		fail("the device has no virtio 1 interface")
	case .Features_Refused:
		fail("the device refused the features")
	case .Reset_Not_Done:
		fail("the device did not finish its reset")
	}
	offered_features = offered
	has_virgl = offered & (1 << virtio_gpu.FEATURE_VIRGL) != 0
	has_resource_blob = offered & (1 << virtio_gpu.FEATURE_RESOURCE_BLOB) != 0
	has_context_init = offered & (1 << virtio_gpu.FEATURE_CONTEXT_INIT) != 0

	if device.device_config_length < virtio_gpu.CONFIG_TOTAL_SIZE {
		fail("the device configuration is too short")
	}
	num_scanouts = virtio.load_32(device.device_config + virtio_gpu.CONFIG_OFFSET_NUM_SCANOUTS)
	num_capsets = virtio.load_32(device.device_config + virtio_gpu.CONFIG_OFFSET_NUM_CAPSETS)
	if num_scanouts == 0 {
		fail("the device reports zero scanouts")
	}

	if queue_pages, queue_status := system.memory_size(queues); queue_status != .Succeeded || queue_pages < pci.QUEUE_PAGES {
		fail("the memory of the queue is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Succeeded || physical_status != .Succeeded {
		system.log_fact(.Error, Queue_Not_Mapped{map_status = map_status, address_status = physical_status})
		fail("no physical address for the queue")
	}
	base := uintptr(address)
	queue_error: virtio.Queue_Error
	control_queue, queue_error = virtio.queue_start(&device, virtio_gpu.CONTROL_QUEUE_INDEX, base + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, physical + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, 2, 0)
	switch queue_error {
	case .None:
	case .Too_Small:
		fail("the control queue of the device is too small")
	case .No_Vector:
		fail("the device has no message interrupt for its control queue")
	case .Bad_Notify:
		fail("the notify register of the control queue is outside the device registers")
	}
	request_buffer = ([^]u8)(base + PAGE_REQUEST_BUFFER * system.PAGE_SIZE)
	request_physical = physical + PAGE_REQUEST_BUFFER * system.PAGE_SIZE
	response_buffer = ([^]u8)(base + PAGE_RESPONSE_BUFFER * system.PAGE_SIZE)
	response_physical = physical + PAGE_RESPONSE_BUFFER * system.PAGE_SIZE

	virtio.ready(&device)
	query_display_info()
	probe_venus_capsets()
	venus_context_start()
	system.log_fact(.Info, Device_Ready{
		scanout    = u64(active_scanout_id),
		width      = u64(display_width),
		height     = u64(display_height),
		queue_size = u64(control_queue.size),
		capsets    = u64(num_capsets),
	})
}

// resource_release removes a 2D resource from the device. The device holds
// the memory of the resource as its backing until it takes the unref, so
// the memory is closed only after: a device that refuses the unref keeps
// that memory, and the service stops rather than close it under the device.
resource_release :: proc "contextless" (resource_id: u32) {
	unref_written, unref_problem := virtio_gpu.resource_unref_encode(resource_id, request_buffer[:REQUEST_BUFFER_BYTES])
	if unref_problem != .None {
		fail("RESOURCE_UNREF was not encoded")
	}
	if _, ok := control_nodata("RESOURCE_UNREF", unref_written); !ok {
		fail("the device refused RESOURCE_UNREF")
	}
}

// attach_framebuffer binds a client memory object as a 2D scanout resource
// via Resource_Create_2D -> Resource_Attach_Backing -> Set_Scanout.
attach_framebuffer :: proc "contextless" (command: ring.Record) -> (status: virtio_gpu.Service_Status, values: [7]u64) {
	ATTACH :: u32(virtio_gpu.Service_Command.Attach_Framebuffer)
	handle := system.Handle(command.values[0])
	kind, rights, through := system.handle_state(handle, ring_memory)
	// A handle that came through the ring belongs to the service now: each
	// refusal closes it, and only the bound scanout keeps it.
	kept := false
	defer {
		if through && !kept {
			system.close(handle)
		}
	}
	// A handle that did not come through the ring is one of the service:
	// its kind and its rights say nothing of the client.
	needed := system.Rights{.Read}
	switch {
	case !through:
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Absent, .Region, 1)
	case kind != .Memory:
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind))
	case !(needed <= rights):
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights))
	}
	if command.values[1] > u64(virtio_gpu.MAX_RESOURCE_DIMENSION) || command.values[2] > u64(virtio_gpu.MAX_RESOURCE_DIMENSION) {
		return .Bad_Command, errors.ring_fail(ATTACH, .Too_Long, .None, 2, i64(min(max(command.values[1], command.values[2]), 1 << 62)), virtio_gpu.MAX_RESOURCE_DIMENSION)
	}
	width := u32(command.values[1])
	height := u32(command.values[2])
	if dim_problem := virtio_gpu.dimensions_validate(width, height); dim_problem != .None {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 2, i64(width), i64(height))
	}
	if command.values[3] > u64(max(u32)) {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 4)
	}
	format, format_ok := virtio_gpu.pixel_format_of_word(u32(command.values[3]))
	if !format_ok {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 4, i64(command.values[3]))
	}
	physical, phys_status := system.memory_physical(machine, handle)
	if phys_status != .Succeeded {
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(phys_status))
	}
	pages, size_status := system.memory_size(handle)
	if size_status != .Succeeded {
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(size_status))
	}
	region_bytes := pages * system.PAGE_SIZE
	required_bytes := u64(width) * u64(height) * 4
	// The pixels, then the page of the present list.
	needed_bytes, needed_ok := virtio_gpu.framebuffer_bytes_with_list(width, height)
	if !needed_ok {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 2, i64(width), i64(height))
	}
	if region_bytes < needed_bytes {
		return .Out_Of_Range, errors.ring_fail(ATTACH, .Too_Small, .Bytes, 1, i64(region_bytes), i64(needed_bytes))
	}
	// The service reads the present list through its own mapping, read
	// only; the device reads the pixels through the backing.
	mapping, map_status := system.memory_map(handle, {})
	if map_status != .Succeeded {
		return .No_Framebuffer, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(map_status))
	}
	mapping_kept := false
	defer if !mapping_kept {
		system.memory_unmap(mapping)
	}

	// The previous scanout stays on the screen and keeps its memory until
	// the new one is bound: a refusal below leaves it as it was.
	resource_id := next_resource_id
	next_resource_id += 1
	if next_resource_id == 0 {
		next_resource_id = 1
	}

	// 1. Resource_Create_2D
	create_bytes, create_prob := virtio_gpu.resource_create_2d_encode(resource_id, format, width, height, request_buffer[:REQUEST_BUFFER_BYTES])
	if create_prob != .None {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 0, i64(create_prob))
	}
	if _, ok := control_nodata("RESOURCE_CREATE_2D", create_bytes); !ok {
		return .Device_Error, errors.ring_fail(ATTACH, .Device, .None, 0)
	}

	// 2. Resource_Attach_Backing
	backing := [1]virtio_gpu.Mem_Entry{{address = physical, length = u32(required_bytes)}}
	attach_bytes, attach_prob := virtio_gpu.resource_attach_backing_encode(resource_id, backing[:], request_buffer[:REQUEST_BUFFER_BYTES])
	if attach_prob != .None {
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 0, i64(attach_prob))
	}
	if _, ok := control_nodata("RESOURCE_ATTACH_BACKING", attach_bytes); !ok {
		resource_release(resource_id)
		return .Device_Error, errors.ring_fail(ATTACH, .Device, .None, 0)
	}

	// 3. Set_Scanout
	full_rect := virtio_gpu.Rect{x = 0, y = 0, width = width, height = height}
	scanout_bytes, scanout_prob := virtio_gpu.set_scanout_encode(active_scanout_id, resource_id, full_rect, width, height, request_buffer[:REQUEST_BUFFER_BYTES])
	if scanout_prob != .None {
		resource_release(resource_id)
		return .Bad_Command, errors.ring_fail(ATTACH, .Bad_Value, .None, 0, i64(scanout_prob))
	}
	if _, ok := control_nodata("SET_SCANOUT", scanout_bytes); !ok {
		resource_release(resource_id)
		return .Device_Error, errors.ring_fail(ATTACH, .Device, .None, 0)
	}

	// The new scanout is on the screen: the old resource leaves the device
	// before its memory is closed.
	if framebuffer_resource_id != 0 {
		resource_release(framebuffer_resource_id)
	}
	if framebuffer_mapping != nil {
		system.memory_unmap(framebuffer_mapping)
	}
	if framebuffer_memory != 0 {
		system.close(framebuffer_memory)
	}
	kept = true
	mapping_kept = true
	framebuffer_mapping = mapping
	framebuffer_frames = 0
	framebuffer_memory = handle
	framebuffer_physical = physical
	framebuffer_size = region_bytes
	framebuffer_width = width
	framebuffer_height = height
	framebuffer_resource_id = resource_id
	system.log_fact(.Info, Scanout_Bound{
		scanout     = u64(active_scanout_id),
		resource_id = u64(resource_id),
		width       = u64(width),
		height      = u64(height),
	})
	return .Ok, {0 = u64(resource_id), 1 = u64(active_scanout_id)}
}

// present_frame presents the rectangles of the present list of the
// framebuffer: for each, a TRANSFER_TO_HOST_2D then a RESOURCE_FLUSH, all
// given to the device before one notice, so that the device takes them in
// one turn and the display shows the frame whole
// (src/md/infrastructure/whole_frame.md, "The screen through the scanout
// of the virtual GPU"). The list is copied out of the memory of the client
// before its check. It answers when the device used every request.
present_frame :: proc "contextless" (command: ring.Record) -> (status: virtio_gpu.Service_Status, values: [7]u64) {
	PRESENT :: u32(virtio_gpu.Service_Command.Present_Frame)
	if framebuffer_resource_id == 0 || framebuffer_mapping == nil {
		return .No_Framebuffer, errors.ring_fail(PRESENT, .Absent, .Region)
	}
	count := command.values[0]
	// Each rectangle is two requests of two descriptors each.
	capacity := min(u64(virtio_gpu.PRESENT_RECTANGLE_CAPACITY), u64(control_queue.size) / 4)
	if count == 0 || count > capacity {
		return .Out_Of_Range, errors.ring_fail(PRESENT, .Bad_Value, .None, 1, i64(min(count, 1 << 62)), i64(capacity))
	}
	list: [virtio_gpu.PRESENT_RECTANGLE_CAPACITY * virtio_gpu.PRESENT_RECTANGLE_BYTES]u8
	list_offset, list_offset_ok := virtio_gpu.present_list_offset(framebuffer_width, framebuffer_height)
	if !list_offset_ok {
		return .Bad_Command, errors.ring_fail(PRESENT, .Bad_Value, .None, 0)
	}
	list_place := uintptr(framebuffer_mapping) + uintptr(list_offset)
	intrinsics.mem_copy_non_overlapping(&list[0], rawptr(list_place), int(count) * virtio_gpu.PRESENT_RECTANGLE_BYTES)
	rectangles, list_problem := virtio_gpu.present_list_decode(list[:], count, framebuffer_width, framebuffer_height)
	if list_problem != .None {
		return .Out_Of_Range, errors.ring_fail(PRESENT, .Out_Of_Range, .None, 1, i64(list_problem))
	}

	// Encode every request of the batch before giving any chain to the
	// queue, so a failed encode leaves no partial chains queued.
	requests := 2 * int(count)
	request_lengths: [2 * virtio_gpu.PRESENT_RECTANGLE_CAPACITY]int
	for index in 0 ..< int(count) {
		rectangle := rectangles[index]
		byte_offset := (u64(rectangle.y) * u64(framebuffer_width) + u64(rectangle.x)) * 4
		transfer := request_buffer[(2 * index) * BATCH_REQUEST_SLOT_BYTES:][:BATCH_REQUEST_SLOT_BYTES]
		transfer_bytes, transfer_problem := virtio_gpu.transfer_to_host_2d_encode(framebuffer_resource_id, rectangle, byte_offset, framebuffer_width, framebuffer_height, transfer)
		flush := request_buffer[(2 * index + 1) * BATCH_REQUEST_SLOT_BYTES:][:BATCH_REQUEST_SLOT_BYTES]
		flush_bytes, flush_problem := virtio_gpu.resource_flush_encode(framebuffer_resource_id, rectangle, framebuffer_width, framebuffer_height, flush)
		if transfer_problem != .None || flush_problem != .None {
			return .Bad_Command, errors.ring_fail(PRESENT, .Bad_Value, .None, 0, i64(transfer_problem), i64(flush_problem))
		}
		request_lengths[2 * index] = transfer_bytes
		request_lengths[2 * index + 1] = flush_bytes
	}
	for slot in 0 ..< requests {
		batch_request_give(slot, request_lengths[slot])
	}
	// The answers of an earlier batch are in the same slots: a device that
	// writes a short answer must not leave an old Ok there.
	intrinsics.mem_zero(response_buffer, requests * BATCH_RESPONSE_SLOT_BYTES)
	// One publish of the index and one notice for the whole frame.
	virtio.notify(&control_queue)
	received, answered := batch_answers_wait(requests)
	if !answered {
		return .Device_Error, errors.ring_fail(PRESENT, .Device, .None, 0)
	}
	for slot in 0 ..< requests {
		answer: [BATCH_RESPONSE_SLOT_BYTES]u8
		answer_bytes := int(min(received[slot], BATCH_RESPONSE_SLOT_BYTES))
		if answer_bytes > 0 {
			intrinsics.mem_copy_non_overlapping(&answer[0], &response_buffer[slot * BATCH_RESPONSE_SLOT_BYTES], answer_bytes)
		}
		decoded, problem := virtio_gpu.nodata_response_decode(answer[:answer_bytes])
		if problem != .None {
			if problem == .Device_Error_Response {
				system.log_fact(.Error, Request_Refused{response_word = u64(decoded.command_type), request = request_field(slot % 2 == 0 ? "TRANSFER_TO_HOST_2D" : "RESOURCE_FLUSH")})
			}
			return .Device_Error, errors.ring_fail(PRESENT, .Device, .None, 0, i64(problem))
		}
	}
	framebuffer_frames += 1
	if framebuffer_frames == 1 {
		system.log_fact(.Info, Frame_Batch_First{resource_id = u64(framebuffer_resource_id), rectangles = count, requests = u64(requests)})
	}
	return .Ok, {0 = framebuffer_frames}
}

// batch_request_give gives the device the request in the slot of the
// request buffer, with its answer in the same slot of the response buffer:
// the descriptors 2 * slot and 2 * slot + 1. The device sees it at the next
// notice.
batch_request_give :: proc "contextless" (slot: int, request_bytes: int) {
	head := u16(2 * slot)
	control_queue.descriptors[head] = {
		address = request_physical + u64(slot * BATCH_REQUEST_SLOT_BYTES),
		length  = u32(request_bytes),
		flags   = virtio.DESCRIPTOR_NEXT,
		next    = head + 1,
	}
	control_queue.descriptors[head + 1] = {
		address = response_physical + u64(slot * BATCH_RESPONSE_SLOT_BYTES),
		length  = BATCH_RESPONSE_SLOT_BYTES,
		flags   = virtio.DESCRIPTOR_DEVICE_WRITES,
	}
	virtio.give(&control_queue, head)
}

// batch_answers_wait waits until the device used each of the requests of a
// batch, up to the hang bound. A used chain that is not a head of the
// batch, or a chain used twice, stops the service: the device then writes
// where the service does not expect it.
batch_answers_wait :: proc "contextless" (requests: int) -> (received: [2 * virtio_gpu.PRESENT_RECTANGLE_CAPACITY]u32, ok: bool) {
	used_heads: [2 * virtio_gpu.PRESENT_RECTANGLE_CAPACITY]bool
	used_count := 0
	deadline := system.time() + DEVICE_ANSWER_BOUND_MILLISECONDS
	for used_count < requests {
		wait := system.wait_begin()
		for used_count < requests {
			item := virtio.used(&control_queue) or_break
			if item.id % 2 != 0 || int(item.id / 2) >= requests || used_heads[item.id / 2] {
				fail("the device answered a request of a frame that was not given")
			}
			slot := int(item.id / 2)
			received[slot] = item.length
			// Keep draining every chain of the batch even on a short answer:
			// the caller passes received[slot] to nodata_response_decode,
			// which refuses a short header.
			if item.length < BATCH_RESPONSE_SLOT_BYTES {
				system.log_fact(.Error, Request_Refused{response_word = u64(item.length), request = request_field("a short answer of a frame")})
			}
			used_heads[slot] = true
			used_count += 1
		}
		if used_count == requests {
			break
		}
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			fail("the device needs a reset")
		}
		if system.time() >= deadline {
			system.log_fact(.Error, Device_Silent{bound = DEVICE_ANSWER_BOUND_MILLISECONDS, request = request_field("a frame batch")})
			fail("the device did not answer a frame batch")
		}
		system.wait_end(&wait, deadline)
	}
	return received, true
}

// entry verifies PCI identity (vendor 0x1AF4, device 0x1050), starts the
// VirtIO-GPU control queue, discovers display geometry and Venus capability
// sets, and serves the GPU client ring.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	ring_memory = ctx.handles[virtio_gpu.SERVICE_RING]
	ring_status: call_outcome.Call_Outcome
	if clients, ring_status = system.ring_open(ring_memory, receive_handles = true); ring_status != .Succeeded {
		fail("no gpu device ring")
	}
	configuration_address, configuration_status := system.memory_map(ctx.handles[pci.GRANT_CONFIGURATION], {})
	if configuration_status != .Succeeded {
		fail("no configuration of the device")
	}
	configuration := ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE]
	vendor_id := byte_order.read_u16_little_endian(configuration, 0)
	device_id := byte_order.read_u16_little_endian(configuration, 2)
	if vendor_id != virtio_gpu.PCI_VENDOR_ID || device_id != virtio_gpu.PCI_DEVICE_ID {
		fail("the pci device is not a virtio-gpu device")
	}
	found: bool
	if device, found = virtio.find(ctx, configuration); !found {
		fail("the device has no virtio registers in the memory that it received")
	}
	start_device(ctx.handles[pci.GRANT_QUEUES])

	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		wait := system.wait_begin()
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			fail("the device needs a reset")
		}
		answered := false
		for ring.count(&clients.completions) < ring.capacity(&clients.completions) {
			command := system.receive(&clients.commands) or_break
			kind, kind_ok := virtio_gpu.service_command_of_ring_word(command.kind)
			result := virtio_gpu.Service_Status.Ok
			values: [7]u64
			if !kind_ok {
				result = .Bad_Command
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
			} else {
				switch kind {
				case .None:
					result = .Bad_Command
					values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
				case .Display_Info:
					values = {
						0 = u64(display_width),
						1 = u64(display_height),
						2 = u64(active_scanout_id),
						3 = u64(venus_available),
						4 = u64(num_capsets),
						5 = u64(has_resource_blob),
					}
				case .Attach_Framebuffer:
					result, values = attach_framebuffer(command)
				case .Present_Frame:
					result, values = present_frame(command)
				case .Venus_Info:
					values = {
						0 = u64(venus_context_id != 0),
						1 = u64(venus_max_version),
						2 = u64(venus_max_size),
						3 = u64(venus_support),
						4 = u64(venus_context_id),
						5 = u64(venus_capset.vk_xml_version),
						6 = u64(venus_ring_resource_id),
					}
				case .Venus_Submit:
					result, values = venus_submit(command)
				}
			}
			ring.push(&clients.completions, ring.Record{kind = u32(result), tag = command.tag, values = values})
			answered = true
		}
		if answered {
			system.wake_reader(&clients.completions)
		}
		if ring.count(&clients.completions) < ring.capacity(&clients.completions) {
			system.wait_records(&wait, &clients.commands)
		} else {
			system.wait_room(&wait, &clients.completions)
		}
		system.wait_end(&wait)
	}
}

#assert(virtio_gpu.PCI_VENDOR_ID == pci.VENDOR_VIRTIO)
#assert(virtio_gpu.PCI_DEVICE_ID == pci.DEVICE_VIRTIO_GPU)
#assert(virtio_gpu.RESP_DISPLAY_INFO_SIZE <= system.PAGE_SIZE)
