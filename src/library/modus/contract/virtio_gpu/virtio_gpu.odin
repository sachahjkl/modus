// The contract of a VirtIO-GPU 1.2 device (VIRTIO 1.2, section 5.7): control
// queue headers, 2D scanout lifecycle commands, the 3D context, capability set
// and blob resource commands that carry Venus, strict border decoding into
// closed enumerations, and the client service ring protocol for the GPU
// device service. The command words and the layouts follow the Linux header
// include/uapi/linux/virtio_gpu.h.
//
// All wire integers are little-endian. This package allocates no memory and
// calls no kernel operation.
package virtio_gpu

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// PCI identity of a modern VirtIO-GPU device (0x1040 + device type 16).
PCI_VENDOR_ID :: 0x1AF4
PCI_DEVICE_ID :: 0x1050

// Virtqueue indices of a VirtIO-GPU device.
CONTROL_QUEUE_INDEX :: 0
CURSOR_QUEUE_INDEX :: 1

// Service ring sizing and context role slot for the GPU device service.
RING_CAPACITY :: 64
SERVICE_RING :: 0

// Feature bit positions in device feature word 0 (VIRTIO 1.2, section 5.7.3).
FEATURE_VIRGL :: 0
FEATURE_EDID :: 1
FEATURE_RESOURCE_UUID :: 2
FEATURE_RESOURCE_BLOB :: 3
FEATURE_CONTEXT_INIT :: 4

// Device-specific configuration space offsets and total byte size.
CONFIG_OFFSET_EVENTS_READ :: 0
CONFIG_OFFSET_EVENTS_CLEAR :: 4
CONFIG_OFFSET_NUM_SCANOUTS :: 8
CONFIG_OFFSET_NUM_CAPSETS :: 12
CONFIG_TOTAL_SIZE :: 16

// Exact wire sizes and strict protocol bounds in bytes or counts.
CTRL_HEADER_SIZE :: 24
RECT_SIZE :: 16
DISPLAY_ONE_SIZE :: 24
MAX_SCANOUTS :: 16
RESP_DISPLAY_INFO_SIZE :: CTRL_HEADER_SIZE + MAX_SCANOUTS * DISPLAY_ONE_SIZE
RESOURCE_CREATE_2D_SIZE :: CTRL_HEADER_SIZE + 16
RESOURCE_UNREF_SIZE :: CTRL_HEADER_SIZE + 8
SET_SCANOUT_SIZE :: CTRL_HEADER_SIZE + 24
RESOURCE_FLUSH_SIZE :: CTRL_HEADER_SIZE + 24
TRANSFER_TO_HOST_2D_SIZE :: CTRL_HEADER_SIZE + 32
RESOURCE_ATTACH_BACKING_HEADER_SIZE :: CTRL_HEADER_SIZE + 8
MEM_ENTRY_SIZE :: 16
MAX_BACKING_ENTRIES :: 256
GET_CAPSET_INFO_SIZE :: CTRL_HEADER_SIZE + 8
RESP_CAPSET_INFO_SIZE :: CTRL_HEADER_SIZE + 16
GET_CAPSET_SIZE :: CTRL_HEADER_SIZE + 8
MAX_CAPSET_DATA_BYTES :: 4096
CTX_CREATE_NAME_BYTES :: 64
CTX_CREATE_SIZE :: CTRL_HEADER_SIZE + 8 + CTX_CREATE_NAME_BYTES
CTX_DESTROY_SIZE :: CTRL_HEADER_SIZE
CTX_RESOURCE_SIZE :: CTRL_HEADER_SIZE + 8
RESOURCE_CREATE_BLOB_SIZE :: CTRL_HEADER_SIZE + 32
RESOURCE_MAP_BLOB_SIZE :: CTRL_HEADER_SIZE + 16
RESP_MAP_INFO_SIZE :: CTRL_HEADER_SIZE + 8
RESOURCE_UNMAP_BLOB_SIZE :: CTRL_HEADER_SIZE + 8
SUBMIT_3D_HEADER_SIZE :: CTRL_HEADER_SIZE + 8
MAX_SUBMIT_3D_BYTES :: 65536
// The host maps a blob at a page boundary of its host-visible region.
MAP_BLOB_OFFSET_ALIGNMENT :: 4096
MAP_INFO_CACHE_MASK :: u32(0x0000_000F)
MAX_RESOURCE_DIMENSION :: 16384
CONTEXT_INIT_CAPSET_ID_MASK :: u32(0x0000_00FF)

// Closed set of VirtIO-GPU 1.2 control queue command and response type words.
Command_Type :: enum u32 {
	// 2D commands.
	Get_Display_Info                 = 0x0100,
	Resource_Create_2D               = 0x0101,
	Resource_Unref                   = 0x0102,
	Set_Scanout                      = 0x0103,
	Resource_Flush                   = 0x0104,
	Transfer_To_Host_2D              = 0x0105,
	Resource_Attach_Backing          = 0x0106,
	Resource_Detach_Backing          = 0x0107,
	Get_Capset_Info                  = 0x0108,
	Get_Capset                       = 0x0109,
	Get_Edid                         = 0x010A,
	Resource_Assign_Uuid             = 0x010B,
	Resource_Create_Blob             = 0x010C,
	Set_Scanout_Blob                 = 0x010D,

	// 3D and Venus context commands.
	Ctx_Create                       = 0x0200,
	Ctx_Destroy                      = 0x0201,
	Ctx_Attach_Resource              = 0x0202,
	Ctx_Detach_Resource              = 0x0203,
	Resource_Create_3D               = 0x0204,
	Transfer_To_Host_3D              = 0x0205,
	Transfer_From_Host_3D            = 0x0206,
	Submit_3D                        = 0x0207,
	Resource_Map_Blob                = 0x0208,
	Resource_Unmap_Blob              = 0x0209,

	// Cursor commands.
	Update_Cursor                    = 0x0300,
	Move_Cursor                      = 0x0301,

	// Success responses.
	Response_Ok_Nodata               = 0x1100,
	Response_Ok_Display_Info         = 0x1101,
	Response_Ok_Capset_Info          = 0x1102,
	Response_Ok_Capset               = 0x1103,
	Response_Ok_Edid                 = 0x1104,
	Response_Ok_Resource_Uuid        = 0x1105,
	Response_Ok_Map_Info             = 0x1106,

	// Error responses.
	Response_Err_Unspec              = 0x1200,
	Response_Err_Out_Of_Memory       = 0x1201,
	Response_Err_Invalid_Scanout_Id  = 0x1202,
	Response_Err_Invalid_Resource_Id = 0x1203,
	Response_Err_Invalid_Context_Id  = 0x1204,
	Response_Err_Invalid_Parameter   = 0x1205,
}

// Closed set of VirtIO-GPU 2D pixel formats.
Pixel_Format :: enum u32 {
	B8G8R8A8_Unorm = 1,
	B8G8R8X8_Unorm = 2,
	A8R8G8B8_Unorm = 3,
	X8R8G8B8_Unorm = 4,
	R8G8B8A8_Unorm = 67,
	X8B8G8R8_Unorm = 68,
}

// Closed set of VirtIO-GPU capability set identifiers.
Capset_Id :: enum u32 {
	Virgl        = 1,
	Virgl2       = 2,
	Gfxstream    = 3,
	Venus        = 4,
	Cross_Domain = 5,
	Drm          = 6,
}

// The cache type of a mapped blob, in the low four bits of map_info
// (VIRTIO_GPU_MAP_CACHE_*). The kernel maps the host-visible pages with it.
Map_Cache :: enum u32 {
	None           = 0,
	Cached         = 1,
	Uncached       = 2,
	Write_Combined = 3,
}

// Whether a device can carry Venus, or the first missing part. The GPU device
// service keeps its 2D scanout in every case.
Venus_Support :: enum u8 {
	Available,
	No_Virgl_Feature,
	No_Resource_Blob_Feature,
	No_Context_Init_Feature,
	No_Venus_Capset,
}

// Bits of Ctrl_Header.flags (VIRTIO 1.2, section 5.7.6.7).
Header_Flag :: enum u32 {
	Fence         = 0,
	Info_Ring_Idx = 1,
}

Header_Flags :: bit_set[Header_Flag; u32]

// Blob backing memory locations for Resource_Create_Blob.
Blob_Memory :: enum u32 {
	Guest        = 0x0001,
	Host3D       = 0x0002,
	Host3D_Guest = 0x0003,
}

// Bits of blob_flags for Resource_Create_Blob.
Blob_Flag :: enum u32 {
	Use_Mappable     = 0,
	Use_Shareable    = 1,
	Use_Cross_Device = 2,
}

Blob_Flags :: bit_set[Blob_Flag; u32]

// Why an encoder or decoder refused a VirtIO-GPU record at the border.
Validation_Problem :: enum u8 {
	None = 0,
	Buffer_Too_Short,
	Unknown_Command_Type,
	Unknown_Header_Flags,
	Unknown_Pixel_Format,
	Unknown_Capset_Id,
	Unknown_Blob_Memory,
	Unknown_Blob_Flags,
	Zero_Resource_Id,
	Zero_Context_Id,
	Zero_Dimensions,
	Dimension_Too_Large,
	Scanout_Id_Out_Of_Range,
	Rect_Out_Of_Bounds,
	Empty_Backing_Entries,
	Too_Many_Backing_Entries,
	Zero_Backing_Length,
	Backing_Address_Overflow,
	Name_Too_Long,
	Zero_Blob_Size,
	Blob_Entries_Invalid,
	Submit_Size_Invalid,
	Unexpected_Response_Type,
	Non_Zero_Padding,
	Device_Error_Response,
	Capset_Data_Too_Large,
	Misaligned_Offset,
	Unknown_Map_Cache,
	Present_Count_Out_Of_Range, // A present list of 0 rectangles, or of more than PRESENT_RECTANGLE_CAPACITY.
}

// Commands carried on the client service ring of the GPU device service.
// Venus_Info answers: 0 the Venus context exists, 1 the capset max version,
// 2 the capset max size, 3 the Venus_Support word, 4 the context id, 5 the
// vk.xml version of the host, 6 the resource id of the ring blob.
// Venus_Submit takes: 0 a memory handle with the right Read, 1 the byte
// offset of the Venus stream in it, 2 its byte length; it answers the length.
// Attach_Framebuffer takes: 0 a memory handle with the right Read, of at
// least framebuffer_bytes_with_list bytes, 1 the width, 2 the height, 3 the
// Pixel_Format word. Present_Frame takes: 0 the count of the rectangles of
// the present list of that memory; it answers 0 the count of the frames
// that the service presented, this one included
// (src/md/infrastructure/whole_frame.md, "The screen through the scanout
// of the virtual GPU").
Service_Command :: enum u32 {
	None               = 0,
	Display_Info       = 1,
	Attach_Framebuffer = 2,
	Present_Frame      = 3,
	Venus_Info         = 4,
	Venus_Submit       = 5,
}

// The rectangles of one present list: each is a TRANSFER_TO_HOST_2D and a
// RESOURCE_FLUSH, each request two descriptors, in one batch of a control
// queue of 64 descriptors.
PRESENT_RECTANGLE_CAPACITY :: 15
PRESENT_RECTANGLE_BYTES :: 16 // x, y, width and height, four little-endian u32.
PRESENT_LIST_PAGE_BYTES :: 4096
#assert(PRESENT_RECTANGLE_CAPACITY * PRESENT_RECTANGLE_BYTES <= PRESENT_LIST_PAGE_BYTES)

// present_list_offset gives the place of the present list in the memory
// of a framebuffer: the page after its pixels.
present_list_offset :: proc "contextless" (width, height: u32) -> u64 {
	pixels := u64(width) * u64(height) * 4
	return (pixels + PRESENT_LIST_PAGE_BYTES - 1) / PRESENT_LIST_PAGE_BYTES * PRESENT_LIST_PAGE_BYTES
}

// framebuffer_bytes_with_list gives the bytes that the memory of a
// framebuffer of Attach_Framebuffer holds: its pixels, then the page of its
// present list.
framebuffer_bytes_with_list :: proc "contextless" (width, height: u32) -> u64 {
	return present_list_offset(width, height) + PRESENT_LIST_PAGE_BYTES
}

// present_list_encode writes rectangles into a present list. It writes
// nothing on a refusal: a count of 0 or past the capacity, a list too
// short for them, or a rectangle outside the framebuffer.
present_list_encode :: proc "contextless" (list: []u8, rectangles: []Rect, width, height: u32) -> Validation_Problem {
	if len(rectangles) == 0 || len(rectangles) > PRESENT_RECTANGLE_CAPACITY {
		return .Present_Count_Out_Of_Range
	}
	if len(list) < len(rectangles) * PRESENT_RECTANGLE_BYTES {
		return .Buffer_Too_Short
	}
	for rectangle in rectangles {
		if problem := rect_fits_in_bounds(rectangle, width, height); problem != .None {
			return problem
		}
	}
	for rectangle, index in rectangles {
		place := index * PRESENT_RECTANGLE_BYTES
		byte_order.write_u32_little_endian(list, place, rectangle.x)
		byte_order.write_u32_little_endian(list, place + 4, rectangle.y)
		byte_order.write_u32_little_endian(list, place + 8, rectangle.width)
		byte_order.write_u32_little_endian(list, place + 12, rectangle.height)
	}
	return .None
}

// present_list_decode reads count rectangles of a present list, which the
// caller copied out of memory that another process writes, and checks
// each against the framebuffer. The count is a word of a ring record: a
// count of 0 or past the capacity is refused, as a rectangle that is empty
// or outside the framebuffer.
present_list_decode :: proc "contextless" (list: []u8, count: u64, width, height: u32) -> (rectangles: [PRESENT_RECTANGLE_CAPACITY]Rect, problem: Validation_Problem) {
	if count == 0 || count > PRESENT_RECTANGLE_CAPACITY {
		return {}, .Present_Count_Out_Of_Range
	}
	if u64(len(list)) < count * PRESENT_RECTANGLE_BYTES {
		return {}, .Buffer_Too_Short
	}
	for index in 0 ..< int(count) {
		place := index * PRESENT_RECTANGLE_BYTES
		rectangle := Rect {
			x      = byte_order.read_u32_little_endian(list, place),
			y      = byte_order.read_u32_little_endian(list, place + 4),
			width  = byte_order.read_u32_little_endian(list, place + 8),
			height = byte_order.read_u32_little_endian(list, place + 12),
		}
		if rectangle_problem := rect_fits_in_bounds(rectangle, width, height); rectangle_problem != .None {
			return {}, rectangle_problem
		}
		rectangles[index] = rectangle
	}
	return rectangles, .None
}

// Completion status words of the client service ring of the GPU device service.
Service_Status :: enum u32 {
	Ok             = 0,
	Bad_Command    = 1,
	Out_Of_Range   = 2,
	No_Framebuffer = 3,
	Device_Error   = 4,
	Unsupported    = 5,
}

// Decoded 24-byte control queue header (virtio_gpu_ctrl_hdr).
Ctrl_Header :: struct {
	command_type: Command_Type,
	flags:        Header_Flags,
	fence_id:     u64,
	ctx_id:       u32,
	ring_idx:     u8,
}

// Rectangle in pixels (virtio_gpu_rect).
Rect :: struct {
	x:      u32,
	y:      u32,
	width:  u32,
	height: u32,
}

// One display scanout descriptor inside Display_Info_Response.
Display_One :: struct {
	rect:    Rect,
	enabled: u32,
	flags:   u32,
}

// Decoded Response_Ok_Display_Info payload.
Display_Info_Response :: struct {
	header:   Ctrl_Header,
	displays: [MAX_SCANOUTS]Display_One,
}

// One contiguous physical backing range (virtio_gpu_mem_entry).
Mem_Entry :: struct {
	address: u64,
	length:  u32,
}

// Decoded Resource_Create_2D command.
Resource_Create_2D_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
	format:      Pixel_Format,
	width:       u32,
	height:      u32,
}

// Decoded Resource_Unref command.
Resource_Unref_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
}

// Decoded Set_Scanout command.
Set_Scanout_Request :: struct {
	header:      Ctrl_Header,
	rect:        Rect,
	scanout_id:  u32,
	resource_id: u32,
}

// Decoded Transfer_To_Host_2D command.
Transfer_To_Host_2D_Request :: struct {
	header:      Ctrl_Header,
	rect:        Rect,
	offset:      u64,
	resource_id: u32,
}

// Decoded Resource_Flush command.
Resource_Flush_Request :: struct {
	header:      Ctrl_Header,
	rect:        Rect,
	resource_id: u32,
}

// Decoded Get_Capset_Info command.
Get_Capset_Info_Request :: struct {
	header:       Ctrl_Header,
	capset_index: u32,
}

// Decoded Response_Ok_Capset_Info payload.
Capset_Info_Response :: struct {
	header:             Ctrl_Header,
	capset_id:          Capset_Id,
	capset_max_version: u32,
	capset_max_size:    u32,
}

// Decoded Ctx_Create command for Venus or another capability set.
Ctx_Create_Request :: struct {
	header:      Ctrl_Header,
	capset_id:   Capset_Id,
	name_length: u32,
	debug_name:  [CTX_CREATE_NAME_BYTES]u8,
}

// Decoded Resource_Create_Blob command.
Resource_Create_Blob_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
	blob_memory: Blob_Memory,
	blob_flags:  Blob_Flags,
	entry_count: u32,
	blob_id:     u64,
	size:        u64,
}

// Decoded Submit_3D header with the validated command stream byte slice.
Submit_3D_Frame :: struct {
	header:  Ctrl_Header,
	payload: []u8,
}

// Decoded Get_Capset command.
Get_Capset_Request :: struct {
	header:         Ctrl_Header,
	capset_id:      Capset_Id,
	capset_version: u32,
}

// Decoded Response_Ok_Capset: the header and a slice over the capset bytes.
Capset_Response :: struct {
	header: Ctrl_Header,
	data:   []u8,
}

// Decoded Ctx_Attach_Resource or Ctx_Detach_Resource command.
Ctx_Resource_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
}

// Decoded Resource_Map_Blob command.
Resource_Map_Blob_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
	offset:      u64,
}

// Decoded Response_Ok_Map_Info payload.
Map_Info_Response :: struct {
	header: Ctrl_Header,
	cache:  Map_Cache,
}

// Decoded Resource_Unmap_Blob command.
Resource_Unmap_Blob_Request :: struct {
	header:      Ctrl_Header,
	resource_id: u32,
}

// command_type_of_word is the one border from a wire word to Command_Type.
command_type_of_word :: proc "contextless" (word: u32) -> (command_type: Command_Type, ok: bool) {
	return enum_word.member_of_word(Command_Type, u64(word))
}

// pixel_format_of_word is the one border from a wire word to Pixel_Format.
pixel_format_of_word :: proc "contextless" (word: u32) -> (format: Pixel_Format, ok: bool) {
	return enum_word.member_of_word(Pixel_Format, u64(word))
}

// capset_id_of_word is the one border from a wire word to Capset_Id.
capset_id_of_word :: proc "contextless" (word: u32) -> (capset: Capset_Id, ok: bool) {
	return enum_word.member_of_word(Capset_Id, u64(word))
}

// map_cache_of_word is the one border from a map_info word to Map_Cache. The
// bits above the cache mask are reserved and refused.
map_cache_of_word :: proc "contextless" (word: u32) -> (cache: Map_Cache, ok: bool) {
	if word & ~MAP_INFO_CACHE_MASK != 0 {
		return .None, false
	}
	return enum_word.member_of_word(Map_Cache, u64(word))
}

// venus_support_check says whether the offered feature word and the probed
// capability sets let the service create a Venus context.
venus_support_check :: proc "contextless" (offered_features: u32, venus_capset_reported: bool) -> Venus_Support {
	if offered_features & (1 << FEATURE_VIRGL) == 0 {
		return .No_Virgl_Feature
	}
	if offered_features & (1 << FEATURE_RESOURCE_BLOB) == 0 {
		return .No_Resource_Blob_Feature
	}
	if offered_features & (1 << FEATURE_CONTEXT_INIT) == 0 {
		return .No_Context_Init_Feature
	}
	if !venus_capset_reported {
		return .No_Venus_Capset
	}
	return .Available
}

// blob_memory_of_word is the one border from a wire word to Blob_Memory.
blob_memory_of_word :: proc "contextless" (word: u32) -> (memory: Blob_Memory, ok: bool) {
	return enum_word.member_of_word(Blob_Memory, u64(word))
}

// header_flags_of_word refuses any unknown bit outside Header_Flag.
header_flags_of_word :: proc "contextless" (word: u32) -> (flags: Header_Flags, ok: bool) {
	known := transmute(u32)(Header_Flags{.Fence, .Info_Ring_Idx})
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Header_Flags)word, true
}

// blob_flags_of_word refuses any unknown bit outside Blob_Flag.
blob_flags_of_word :: proc "contextless" (word: u32) -> (flags: Blob_Flags, ok: bool) {
	known := transmute(u32)(Blob_Flags{.Use_Mappable, .Use_Shareable, .Use_Cross_Device})
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Blob_Flags)word, true
}

// service_command_of_ring_word decodes a client service ring command word.
// Word 0 (None) is refused.
service_command_of_ring_word :: proc "contextless" (word: u32) -> (command: Service_Command, ok: bool) {
	decoded, found := enum_word.member_of_word(Service_Command, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

// command_type_is_error reports whether a decoded command type is a VirtIO-GPU error response.
command_type_is_error :: proc "contextless" (command_type: Command_Type) -> bool {
	switch command_type {
	case .Get_Display_Info,
	     .Resource_Create_2D,
	     .Resource_Unref,
	     .Set_Scanout,
	     .Resource_Flush,
	     .Transfer_To_Host_2D,
	     .Resource_Attach_Backing,
	     .Resource_Detach_Backing,
	     .Get_Capset_Info,
	     .Get_Capset,
	     .Get_Edid,
	     .Resource_Assign_Uuid,
	     .Resource_Create_Blob,
	     .Set_Scanout_Blob,
	     .Ctx_Create,
	     .Ctx_Destroy,
	     .Ctx_Attach_Resource,
	     .Ctx_Detach_Resource,
	     .Resource_Create_3D,
	     .Transfer_To_Host_3D,
	     .Transfer_From_Host_3D,
	     .Submit_3D,
	     .Resource_Map_Blob,
	     .Resource_Unmap_Blob,
	     .Update_Cursor,
	     .Move_Cursor,
	     .Response_Ok_Nodata,
	     .Response_Ok_Display_Info,
	     .Response_Ok_Capset_Info,
	     .Response_Ok_Capset,
	     .Response_Ok_Edid,
	     .Response_Ok_Resource_Uuid,
	     .Response_Ok_Map_Info:
		return false
	case .Response_Err_Unspec,
	     .Response_Err_Out_Of_Memory,
	     .Response_Err_Invalid_Scanout_Id,
	     .Response_Err_Invalid_Resource_Id,
	     .Response_Err_Invalid_Context_Id,
	     .Response_Err_Invalid_Parameter:
		return true
	}
	return false
}

// dimensions_validate checks that width and height are non-zero and within MAX_RESOURCE_DIMENSION.
dimensions_validate :: proc "contextless" (width, height: u32) -> Validation_Problem {
	if width == 0 || height == 0 {
		return .Zero_Dimensions
	}
	if width > MAX_RESOURCE_DIMENSION || height > MAX_RESOURCE_DIMENSION {
		return .Dimension_Too_Large
	}
	return .None
}

// rect_fits_in_bounds checks that rect has non-zero extent and lies completely
// inside [0..bound_width) x [0..bound_height) using overflow-safe 64-bit math.
rect_fits_in_bounds :: proc "contextless" (rect: Rect, bound_width, bound_height: u32) -> Validation_Problem {
	if rect.width == 0 || rect.height == 0 {
		return .Zero_Dimensions
	}
	if u64(rect.x) + u64(rect.width) > u64(bound_width) || u64(rect.y) + u64(rect.height) > u64(bound_height) {
		return .Rect_Out_Of_Bounds
	}
	return .None
}

@(private = "file")
rect_write :: proc "contextless" (destination: []u8, offset: int, rect: Rect) {
	byte_order.write_u32_little_endian(destination, offset + 0, rect.x)
	byte_order.write_u32_little_endian(destination, offset + 4, rect.y)
	byte_order.write_u32_little_endian(destination, offset + 8, rect.width)
	byte_order.write_u32_little_endian(destination, offset + 12, rect.height)
}

@(private = "file")
rect_read :: proc "contextless" (source: []u8, offset: int) -> Rect {
	return Rect{
		x      = byte_order.read_u32_little_endian(source, offset + 0),
		y      = byte_order.read_u32_little_endian(source, offset + 4),
		width  = byte_order.read_u32_little_endian(source, offset + 8),
		height = byte_order.read_u32_little_endian(source, offset + 12),
	}
}

// ctrl_header_encode serializes a 24-byte VirtIO-GPU control queue header.
ctrl_header_encode :: proc "contextless" (header: Ctrl_Header, destination: []u8) -> (written: int, problem: Validation_Problem) {
	if len(destination) < CTRL_HEADER_SIZE {
		return 0, .Buffer_Too_Short
	}
	if _, known := command_type_of_word(u32(header.command_type)); !known {
		return 0, .Unknown_Command_Type
	}
	flags_word := transmute(u32)header.flags
	if _, flags_ok := header_flags_of_word(flags_word); !flags_ok {
		return 0, .Unknown_Header_Flags
	}
	byte_order.write_u32_little_endian(destination, 0, u32(header.command_type))
	byte_order.write_u32_little_endian(destination, 4, flags_word)
	byte_order.write_u64_little_endian(destination, 8, header.fence_id)
	byte_order.write_u32_little_endian(destination, 16, header.ctx_id)
	destination[20] = header.ring_idx
	destination[21] = 0
	destination[22] = 0
	destination[23] = 0
	return CTRL_HEADER_SIZE, .None
}

// ctrl_header_decode validates and decodes a 24-byte control queue header.
ctrl_header_decode :: proc "contextless" (source: []u8) -> (header: Ctrl_Header, problem: Validation_Problem) {
	if len(source) < CTRL_HEADER_SIZE {
		return {}, .Buffer_Too_Short
	}
	command_type, type_ok := command_type_of_word(byte_order.read_u32_little_endian(source, 0))
	if !type_ok {
		return {}, .Unknown_Command_Type
	}
	flags, flags_ok := header_flags_of_word(byte_order.read_u32_little_endian(source, 4))
	if !flags_ok {
		return {}, .Unknown_Header_Flags
	}
	if source[21] != 0 || source[22] != 0 || source[23] != 0 {
		return {}, .Non_Zero_Padding
	}
	return Ctrl_Header{
		command_type = command_type,
		flags        = flags,
		fence_id     = byte_order.read_u64_little_endian(source, 8),
		ctx_id       = byte_order.read_u32_little_endian(source, 16),
		ring_idx     = source[20],
	}, .None
}

// nodata_response_decode checks a 24-byte response header, distinguishing
// Response_Ok_Nodata, VirtIO-GPU error responses, and unexpected types.
nodata_response_decode :: proc "contextless" (source: []u8) -> (header: Ctrl_Header, problem: Validation_Problem) {
	header, problem = ctrl_header_decode(source)
	if problem != .None {
		return {}, problem
	}
	if header.command_type == .Response_Ok_Nodata {
		return header, .None
	}
	if command_type_is_error(header.command_type) {
		return header, .Device_Error_Response
	}
	return {}, .Unexpected_Response_Type
}

// get_display_info_encode writes a Get_Display_Info command (24 bytes).
get_display_info_encode :: proc "contextless" (destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	return ctrl_header_encode(Ctrl_Header{command_type = .Get_Display_Info, flags = flags, fence_id = fence_id}, destination)
}

// display_info_response_encode serializes a Response_Ok_Display_Info record (408 bytes).
display_info_response_encode :: proc "contextless" (response: Display_Info_Response, destination: []u8) -> (written: int, problem: Validation_Problem) {
	if len(destination) < RESP_DISPLAY_INFO_SIZE {
		return 0, .Buffer_Too_Short
	}
	header := response.header
	header.command_type = .Response_Ok_Display_Info
	_, problem = ctrl_header_encode(header, destination)
	if problem != .None {
		return 0, problem
	}
	for index in 0 ..< MAX_SCANOUTS {
		base := CTRL_HEADER_SIZE + index * DISPLAY_ONE_SIZE
		entry := response.displays[index]
		rect_write(destination, base, entry.rect)
		byte_order.write_u32_little_endian(destination, base + 16, entry.enabled)
		byte_order.write_u32_little_endian(destination, base + 20, entry.flags)
	}
	return RESP_DISPLAY_INFO_SIZE, .None
}

// display_info_response_decode validates and decodes a 408-byte display info response.
display_info_response_decode :: proc "contextless" (source: []u8) -> (response: Display_Info_Response, problem: Validation_Problem) {
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if command_type_is_error(header.command_type) {
		return Display_Info_Response{header = header}, .Device_Error_Response
	}
	if header.command_type != .Response_Ok_Display_Info {
		return {}, .Unexpected_Response_Type
	}
	if len(source) < RESP_DISPLAY_INFO_SIZE {
		return {}, .Buffer_Too_Short
	}
	response.header = header
	for index in 0 ..< MAX_SCANOUTS {
		base := CTRL_HEADER_SIZE + index * DISPLAY_ONE_SIZE
		response.displays[index] = Display_One{
			rect    = rect_read(source, base),
			enabled = byte_order.read_u32_little_endian(source, base + 16),
			flags   = byte_order.read_u32_little_endian(source, base + 20),
		}
	}
	return response, .None
}

// resource_create_2d_encode validates and writes a Resource_Create_2D command (40 bytes).
resource_create_2d_encode :: proc "contextless" (resource_id: u32, format: Pixel_Format, width, height: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if _, format_ok := pixel_format_of_word(u32(format)); !format_ok {
		return 0, .Unknown_Pixel_Format
	}
	if dim_problem := dimensions_validate(width, height); dim_problem != .None {
		return 0, dim_problem
	}
	if len(destination) < RESOURCE_CREATE_2D_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Create_2D, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, u32(format))
	byte_order.write_u32_little_endian(destination, 32, width)
	byte_order.write_u32_little_endian(destination, 36, height)
	return RESOURCE_CREATE_2D_SIZE, .None
}

// resource_create_2d_decode validates and decodes a Resource_Create_2D command.
resource_create_2d_decode :: proc "contextless" (source: []u8) -> (request: Resource_Create_2D_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_CREATE_2D_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Create_2D {
		return {}, .Unexpected_Response_Type
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	format, format_ok := pixel_format_of_word(byte_order.read_u32_little_endian(source, 28))
	if !format_ok {
		return {}, .Unknown_Pixel_Format
	}
	width := byte_order.read_u32_little_endian(source, 32)
	height := byte_order.read_u32_little_endian(source, 36)
	if dim_problem := dimensions_validate(width, height); dim_problem != .None {
		return {}, dim_problem
	}
	return Resource_Create_2D_Request{
		header      = header,
		resource_id = resource_id,
		format      = format,
		width       = width,
		height      = height,
	}, .None
}

// resource_unref_encode validates and writes a Resource_Unref command (32 bytes).
resource_unref_encode :: proc "contextless" (resource_id: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if len(destination) < RESOURCE_UNREF_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Unref, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, 0)
	return RESOURCE_UNREF_SIZE, .None
}

// resource_unref_decode validates and decodes a Resource_Unref command.
resource_unref_decode :: proc "contextless" (source: []u8) -> (request: Resource_Unref_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_UNREF_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Unref {
		return {}, .Unexpected_Response_Type
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Resource_Unref_Request{header = header, resource_id = resource_id}, .None
}

// resource_attach_backing_encode validates and writes a Resource_Attach_Backing
// header followed by its physical Mem_Entry array.
resource_attach_backing_encode :: proc "contextless" (resource_id: u32, entries: []Mem_Entry, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if len(entries) == 0 {
		return 0, .Empty_Backing_Entries
	}
	if len(entries) > MAX_BACKING_ENTRIES {
		return 0, .Too_Many_Backing_Entries
	}
	for entry in entries {
		if entry.length == 0 {
			return 0, .Zero_Backing_Length
		}
		if entry.address > max(u64) - u64(entry.length) {
			return 0, .Backing_Address_Overflow
		}
	}
	total_bytes := RESOURCE_ATTACH_BACKING_HEADER_SIZE + len(entries) * MEM_ENTRY_SIZE
	if len(destination) < total_bytes {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Attach_Backing, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, u32(len(entries)))
	for entry, index in entries {
		base := RESOURCE_ATTACH_BACKING_HEADER_SIZE + index * MEM_ENTRY_SIZE
		byte_order.write_u64_little_endian(destination, base + 0, entry.address)
		byte_order.write_u32_little_endian(destination, base + 8, entry.length)
		byte_order.write_u32_little_endian(destination, base + 12, 0)
	}
	return total_bytes, .None
}

// resource_attach_backing_decode validates and decodes a Resource_Attach_Backing
// command into caller-supplied entries_output.
resource_attach_backing_decode :: proc "contextless" (source: []u8, entries_output: []Mem_Entry) -> (header: Ctrl_Header, resource_id: u32, entry_count: u32, problem: Validation_Problem) {
	if len(source) < RESOURCE_ATTACH_BACKING_HEADER_SIZE {
		return {}, 0, 0, .Buffer_Too_Short
	}
	header, problem = ctrl_header_decode(source)
	if problem != .None {
		return {}, 0, 0, problem
	}
	if header.command_type != .Resource_Attach_Backing {
		return {}, 0, 0, .Unexpected_Response_Type
	}
	resource_id = byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, 0, 0, .Zero_Resource_Id
	}
	entry_count = byte_order.read_u32_little_endian(source, 28)
	if entry_count == 0 {
		return {}, 0, 0, .Empty_Backing_Entries
	}
	if entry_count > MAX_BACKING_ENTRIES {
		return {}, 0, 0, .Too_Many_Backing_Entries
	}
	total_bytes := RESOURCE_ATTACH_BACKING_HEADER_SIZE + int(entry_count) * MEM_ENTRY_SIZE
	if len(source) < total_bytes || len(entries_output) < int(entry_count) {
		return {}, 0, 0, .Buffer_Too_Short
	}
	for index in 0 ..< int(entry_count) {
		base := RESOURCE_ATTACH_BACKING_HEADER_SIZE + index * MEM_ENTRY_SIZE
		address := byte_order.read_u64_little_endian(source, base + 0)
		length := byte_order.read_u32_little_endian(source, base + 8)
		padding := byte_order.read_u32_little_endian(source, base + 12)
		if padding != 0 {
			return {}, 0, 0, .Non_Zero_Padding
		}
		if length == 0 {
			return {}, 0, 0, .Zero_Backing_Length
		}
		if address > max(u64) - u64(length) {
			return {}, 0, 0, .Backing_Address_Overflow
		}
		entries_output[index] = Mem_Entry{address = address, length = length}
	}
	return header, resource_id, entry_count, .None
}

// set_scanout_encode validates and writes a Set_Scanout command (48 bytes),
// checking that rect lies within the backing resource dimensions.
set_scanout_encode :: proc "contextless" (scanout_id, resource_id: u32, rect: Rect, resource_width, resource_height: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if scanout_id >= MAX_SCANOUTS {
		return 0, .Scanout_Id_Out_Of_Range
	}
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return 0, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return 0, rect_problem
	}
	if len(destination) < SET_SCANOUT_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Set_Scanout, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	rect_write(destination, 24, rect)
	byte_order.write_u32_little_endian(destination, 40, scanout_id)
	byte_order.write_u32_little_endian(destination, 44, resource_id)
	return SET_SCANOUT_SIZE, .None
}

// set_scanout_decode validates and decodes a Set_Scanout command against resource bounds.
set_scanout_decode :: proc "contextless" (source: []u8, resource_width, resource_height: u32) -> (request: Set_Scanout_Request, problem: Validation_Problem) {
	if len(source) < SET_SCANOUT_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Set_Scanout {
		return {}, .Unexpected_Response_Type
	}
	rect := rect_read(source, 24)
	scanout_id := byte_order.read_u32_little_endian(source, 40)
	resource_id := byte_order.read_u32_little_endian(source, 44)
	if scanout_id >= MAX_SCANOUTS {
		return {}, .Scanout_Id_Out_Of_Range
	}
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return {}, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return {}, rect_problem
	}
	return Set_Scanout_Request{
		header      = header,
		rect        = rect,
		scanout_id  = scanout_id,
		resource_id = resource_id,
	}, .None
}

// transfer_to_host_2d_encode validates and writes a Transfer_To_Host_2D command (56 bytes).
transfer_to_host_2d_encode :: proc "contextless" (resource_id: u32, rect: Rect, offset: u64, resource_width, resource_height: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return 0, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return 0, rect_problem
	}
	if len(destination) < TRANSFER_TO_HOST_2D_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Transfer_To_Host_2D, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	rect_write(destination, 24, rect)
	byte_order.write_u64_little_endian(destination, 40, offset)
	byte_order.write_u32_little_endian(destination, 48, resource_id)
	byte_order.write_u32_little_endian(destination, 52, 0)
	return TRANSFER_TO_HOST_2D_SIZE, .None
}

// transfer_to_host_2d_decode validates and decodes a Transfer_To_Host_2D command.
transfer_to_host_2d_decode :: proc "contextless" (source: []u8, resource_width, resource_height: u32) -> (request: Transfer_To_Host_2D_Request, problem: Validation_Problem) {
	if len(source) < TRANSFER_TO_HOST_2D_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Transfer_To_Host_2D {
		return {}, .Unexpected_Response_Type
	}
	rect := rect_read(source, 24)
	offset := byte_order.read_u64_little_endian(source, 40)
	resource_id := byte_order.read_u32_little_endian(source, 48)
	if byte_order.read_u32_little_endian(source, 52) != 0 {
		return {}, .Non_Zero_Padding
	}
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return {}, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return {}, rect_problem
	}
	return Transfer_To_Host_2D_Request{
		header      = header,
		rect        = rect,
		offset      = offset,
		resource_id = resource_id,
	}, .None
}

// resource_flush_encode validates and writes a Resource_Flush command (48 bytes).
resource_flush_encode :: proc "contextless" (resource_id: u32, rect: Rect, resource_width, resource_height: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return 0, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return 0, rect_problem
	}
	if len(destination) < RESOURCE_FLUSH_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Flush, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	rect_write(destination, 24, rect)
	byte_order.write_u32_little_endian(destination, 40, resource_id)
	byte_order.write_u32_little_endian(destination, 44, 0)
	return RESOURCE_FLUSH_SIZE, .None
}

// resource_flush_decode validates and decodes a Resource_Flush command.
resource_flush_decode :: proc "contextless" (source: []u8, resource_width, resource_height: u32) -> (request: Resource_Flush_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_FLUSH_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Flush {
		return {}, .Unexpected_Response_Type
	}
	rect := rect_read(source, 24)
	resource_id := byte_order.read_u32_little_endian(source, 40)
	if byte_order.read_u32_little_endian(source, 44) != 0 {
		return {}, .Non_Zero_Padding
	}
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if dim_problem := dimensions_validate(resource_width, resource_height); dim_problem != .None {
		return {}, dim_problem
	}
	if rect_problem := rect_fits_in_bounds(rect, resource_width, resource_height); rect_problem != .None {
		return {}, rect_problem
	}
	return Resource_Flush_Request{
		header      = header,
		rect        = rect,
		resource_id = resource_id,
	}, .None
}

// get_capset_info_encode writes a Get_Capset_Info command (32 bytes).
get_capset_info_encode :: proc "contextless" (capset_index: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if len(destination) < GET_CAPSET_INFO_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Get_Capset_Info, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, capset_index)
	byte_order.write_u32_little_endian(destination, 28, 0)
	return GET_CAPSET_INFO_SIZE, .None
}

// get_capset_info_decode validates and decodes a Get_Capset_Info command.
get_capset_info_decode :: proc "contextless" (source: []u8) -> (request: Get_Capset_Info_Request, problem: Validation_Problem) {
	if len(source) < GET_CAPSET_INFO_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Get_Capset_Info {
		return {}, .Unexpected_Response_Type
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Get_Capset_Info_Request{
		header       = header,
		capset_index = byte_order.read_u32_little_endian(source, 24),
	}, .None
}

// capset_info_response_encode writes a Response_Ok_Capset_Info payload (40 bytes).
capset_info_response_encode :: proc "contextless" (response: Capset_Info_Response, destination: []u8) -> (written: int, problem: Validation_Problem) {
	if _, capset_ok := capset_id_of_word(u32(response.capset_id)); !capset_ok {
		return 0, .Unknown_Capset_Id
	}
	if len(destination) < RESP_CAPSET_INFO_SIZE {
		return 0, .Buffer_Too_Short
	}
	header := response.header
	header.command_type = .Response_Ok_Capset_Info
	_, problem = ctrl_header_encode(header, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, u32(response.capset_id))
	byte_order.write_u32_little_endian(destination, 28, response.capset_max_version)
	byte_order.write_u32_little_endian(destination, 32, response.capset_max_size)
	byte_order.write_u32_little_endian(destination, 36, 0)
	return RESP_CAPSET_INFO_SIZE, .None
}

// capset_info_response_decode validates and decodes a 40-byte capset info response.
capset_info_response_decode :: proc "contextless" (source: []u8) -> (response: Capset_Info_Response, problem: Validation_Problem) {
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if command_type_is_error(header.command_type) {
		return Capset_Info_Response{header = header}, .Device_Error_Response
	}
	if header.command_type != .Response_Ok_Capset_Info {
		return {}, .Unexpected_Response_Type
	}
	if len(source) < RESP_CAPSET_INFO_SIZE {
		return {}, .Buffer_Too_Short
	}
	capset_id, capset_ok := capset_id_of_word(byte_order.read_u32_little_endian(source, 24))
	if !capset_ok {
		return {}, .Unknown_Capset_Id
	}
	if byte_order.read_u32_little_endian(source, 36) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Capset_Info_Response{
		header             = header,
		capset_id          = capset_id,
		capset_max_version = byte_order.read_u32_little_endian(source, 28),
		capset_max_size    = byte_order.read_u32_little_endian(source, 32),
	}, .None
}

// ctx_create_encode validates and writes a Ctx_Create command (96 bytes)
// selecting the given Capset_Id (for example Capset_Id.Venus).
ctx_create_encode :: proc "contextless" (ctx_id: u32, capset_id: Capset_Id, debug_name: string, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Context_Id
	}
	if _, capset_ok := capset_id_of_word(u32(capset_id)); !capset_ok {
		return 0, .Unknown_Capset_Id
	}
	if len(debug_name) > CTX_CREATE_NAME_BYTES {
		return 0, .Name_Too_Long
	}
	if len(destination) < CTX_CREATE_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Ctx_Create, flags = flags, fence_id = fence_id, ctx_id = ctx_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, u32(len(debug_name)))
	byte_order.write_u32_little_endian(destination, 28, u32(capset_id) & CONTEXT_INIT_CAPSET_ID_MASK)
	for index in 0 ..< CTX_CREATE_NAME_BYTES {
		destination[32 + index] = index < len(debug_name) ? debug_name[index] : 0
	}
	return CTX_CREATE_SIZE, .None
}

// ctx_create_decode validates and decodes a 96-byte Ctx_Create command.
ctx_create_decode :: proc "contextless" (source: []u8) -> (request: Ctx_Create_Request, problem: Validation_Problem) {
	if len(source) < CTX_CREATE_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Ctx_Create {
		return {}, .Unexpected_Response_Type
	}
	if header.ctx_id == 0 {
		return {}, .Zero_Context_Id
	}
	name_length := byte_order.read_u32_little_endian(source, 24)
	if name_length > CTX_CREATE_NAME_BYTES {
		return {}, .Name_Too_Long
	}
	context_init := byte_order.read_u32_little_endian(source, 28)
	if context_init & ~CONTEXT_INIT_CAPSET_ID_MASK != 0 {
		return {}, .Unknown_Capset_Id
	}
	capset_id, capset_ok := capset_id_of_word(context_init & CONTEXT_INIT_CAPSET_ID_MASK)
	if !capset_ok {
		return {}, .Unknown_Capset_Id
	}
	request.header = header
	request.capset_id = capset_id
	request.name_length = name_length
	for index in 0 ..< CTX_CREATE_NAME_BYTES {
		request.debug_name[index] = source[32 + index]
	}
	return request, .None
}

// ctx_destroy_encode validates and writes a Ctx_Destroy command (24 bytes).
ctx_destroy_encode :: proc "contextless" (ctx_id: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Context_Id
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	return ctrl_header_encode(Ctrl_Header{command_type = .Ctx_Destroy, flags = flags, fence_id = fence_id, ctx_id = ctx_id}, destination)
}

// ctx_destroy_decode validates and decodes a 24-byte Ctx_Destroy command.
ctx_destroy_decode :: proc "contextless" (source: []u8) -> (header: Ctrl_Header, problem: Validation_Problem) {
	header, problem = ctrl_header_decode(source)
	if problem != .None {
		return {}, problem
	}
	if header.command_type != .Ctx_Destroy {
		return {}, .Unexpected_Response_Type
	}
	if header.ctx_id == 0 {
		return {}, .Zero_Context_Id
	}
	return header, .None
}

// ctx_attach_resource_encode writes a Ctx_Attach_Resource command (32 bytes):
// the context ctx_id gains access to the resource.
ctx_attach_resource_encode :: proc "contextless" (ctx_id, resource_id: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	return ctx_resource_encode(.Ctx_Attach_Resource, ctx_id, resource_id, destination, fence_id)
}

// ctx_detach_resource_encode writes a Ctx_Detach_Resource command (32 bytes).
ctx_detach_resource_encode :: proc "contextless" (ctx_id, resource_id: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	return ctx_resource_encode(.Ctx_Detach_Resource, ctx_id, resource_id, destination, fence_id)
}

@(private = "file")
ctx_resource_encode :: proc "contextless" (command_type: Command_Type, ctx_id, resource_id: u32, destination: []u8, fence_id: u64) -> (written: int, problem: Validation_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Context_Id
	}
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if len(destination) < CTX_RESOURCE_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = command_type, flags = flags, fence_id = fence_id, ctx_id = ctx_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, 0)
	return CTX_RESOURCE_SIZE, .None
}

// ctx_resource_decode validates a Ctx_Attach_Resource or Ctx_Detach_Resource command.
ctx_resource_decode :: proc "contextless" (source: []u8) -> (request: Ctx_Resource_Request, problem: Validation_Problem) {
	if len(source) < CTX_RESOURCE_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Ctx_Attach_Resource && header.command_type != .Ctx_Detach_Resource {
		return {}, .Unexpected_Response_Type
	}
	if header.ctx_id == 0 {
		return {}, .Zero_Context_Id
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Ctx_Resource_Request{header = header, resource_id = resource_id}, .None
}

// get_capset_encode writes a Get_Capset command (32 bytes) that asks for the
// bytes of one capability set at one version.
get_capset_encode :: proc "contextless" (capset_id: Capset_Id, capset_version: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if _, capset_ok := capset_id_of_word(u32(capset_id)); !capset_ok {
		return 0, .Unknown_Capset_Id
	}
	if len(destination) < GET_CAPSET_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Get_Capset, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, u32(capset_id))
	byte_order.write_u32_little_endian(destination, 28, capset_version)
	return GET_CAPSET_SIZE, .None
}

// get_capset_decode validates and decodes a Get_Capset command.
get_capset_decode :: proc "contextless" (source: []u8) -> (request: Get_Capset_Request, problem: Validation_Problem) {
	if len(source) < GET_CAPSET_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Get_Capset {
		return {}, .Unexpected_Response_Type
	}
	capset_id, capset_ok := capset_id_of_word(byte_order.read_u32_little_endian(source, 24))
	if !capset_ok {
		return {}, .Unknown_Capset_Id
	}
	return Get_Capset_Request{
		header         = header,
		capset_id      = capset_id,
		capset_version = byte_order.read_u32_little_endian(source, 28),
	}, .None
}

// capset_response_encode writes a Response_Ok_Capset: the header, then the
// capset bytes. The device writes it; the tests use it.
capset_response_encode :: proc "contextless" (header: Ctrl_Header, data: []u8, destination: []u8) -> (written: int, problem: Validation_Problem) {
	if len(data) > MAX_CAPSET_DATA_BYTES {
		return 0, .Capset_Data_Too_Large
	}
	total_bytes := CTRL_HEADER_SIZE + len(data)
	if len(destination) < total_bytes {
		return 0, .Buffer_Too_Short
	}
	response_header := header
	response_header.command_type = .Response_Ok_Capset
	_, problem = ctrl_header_encode(response_header, destination)
	if problem != .None {
		return 0, problem
	}
	copy(destination[CTRL_HEADER_SIZE:total_bytes], data)
	return total_bytes, .None
}

// capset_response_decode validates a Response_Ok_Capset and returns a slice
// over its bytes. The length comes from the used length of the device.
capset_response_decode :: proc "contextless" (source: []u8) -> (response: Capset_Response, problem: Validation_Problem) {
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if command_type_is_error(header.command_type) {
		return Capset_Response{header = header}, .Device_Error_Response
	}
	if header.command_type != .Response_Ok_Capset {
		return {}, .Unexpected_Response_Type
	}
	if len(source) - CTRL_HEADER_SIZE > MAX_CAPSET_DATA_BYTES {
		return {}, .Capset_Data_Too_Large
	}
	return Capset_Response{header = header, data = source[CTRL_HEADER_SIZE:]}, .None
}

// resource_map_blob_encode writes a Resource_Map_Blob command (40 bytes): the
// device maps the blob at offset in its host-visible memory region.
resource_map_blob_encode :: proc "contextless" (resource_id: u32, offset: u64, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if offset % MAP_BLOB_OFFSET_ALIGNMENT != 0 {
		return 0, .Misaligned_Offset
	}
	if len(destination) < RESOURCE_MAP_BLOB_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Map_Blob, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, 0)
	byte_order.write_u64_little_endian(destination, 32, offset)
	return RESOURCE_MAP_BLOB_SIZE, .None
}

// resource_map_blob_decode validates and decodes a Resource_Map_Blob command.
resource_map_blob_decode :: proc "contextless" (source: []u8) -> (request: Resource_Map_Blob_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_MAP_BLOB_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Map_Blob {
		return {}, .Unexpected_Response_Type
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	offset := byte_order.read_u64_little_endian(source, 32)
	if offset % MAP_BLOB_OFFSET_ALIGNMENT != 0 {
		return {}, .Misaligned_Offset
	}
	return Resource_Map_Blob_Request{header = header, resource_id = resource_id, offset = offset}, .None
}

// map_info_response_encode writes a Response_Ok_Map_Info (32 bytes).
map_info_response_encode :: proc "contextless" (response: Map_Info_Response, destination: []u8) -> (written: int, problem: Validation_Problem) {
	if _, cache_ok := map_cache_of_word(u32(response.cache)); !cache_ok {
		return 0, .Unknown_Map_Cache
	}
	if len(destination) < RESP_MAP_INFO_SIZE {
		return 0, .Buffer_Too_Short
	}
	header := response.header
	header.command_type = .Response_Ok_Map_Info
	_, problem = ctrl_header_encode(header, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, u32(response.cache))
	byte_order.write_u32_little_endian(destination, 28, 0)
	return RESP_MAP_INFO_SIZE, .None
}

// map_info_response_decode validates a Response_Ok_Map_Info and its cache type.
map_info_response_decode :: proc "contextless" (source: []u8) -> (response: Map_Info_Response, problem: Validation_Problem) {
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if command_type_is_error(header.command_type) {
		return Map_Info_Response{header = header}, .Device_Error_Response
	}
	if header.command_type != .Response_Ok_Map_Info {
		return {}, .Unexpected_Response_Type
	}
	if len(source) < RESP_MAP_INFO_SIZE {
		return {}, .Buffer_Too_Short
	}
	cache, cache_ok := map_cache_of_word(byte_order.read_u32_little_endian(source, 24))
	if !cache_ok {
		return {}, .Unknown_Map_Cache
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Map_Info_Response{header = header, cache = cache}, .None
}

// resource_unmap_blob_encode writes a Resource_Unmap_Blob command (32 bytes).
resource_unmap_blob_encode :: proc "contextless" (resource_id: u32, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if len(destination) < RESOURCE_UNMAP_BLOB_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Unmap_Blob, flags = flags, fence_id = fence_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, 0)
	return RESOURCE_UNMAP_BLOB_SIZE, .None
}

// resource_unmap_blob_decode validates and decodes a Resource_Unmap_Blob command.
resource_unmap_blob_decode :: proc "contextless" (source: []u8) -> (request: Resource_Unmap_Blob_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_UNMAP_BLOB_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Unmap_Blob {
		return {}, .Unexpected_Response_Type
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	return Resource_Unmap_Blob_Request{header = header, resource_id = resource_id}, .None
}

// blob_rules_check refuses the blob forms that the device cannot honour: a
// blob of host memory belongs to a 3D context and has no guest pages, and a
// blob of guest memory needs its guest pages.
@(private = "file")
blob_rules_check :: proc "contextless" (ctx_id: u32, blob_memory: Blob_Memory, entry_count: u32) -> Validation_Problem {
	switch blob_memory {
	case .Host3D:
		if ctx_id == 0 {
			return .Zero_Context_Id
		}
		if entry_count != 0 {
			return .Blob_Entries_Invalid
		}
	case .Host3D_Guest:
		if ctx_id == 0 {
			return .Zero_Context_Id
		}
		if entry_count == 0 {
			return .Blob_Entries_Invalid
		}
	case .Guest:
		if entry_count == 0 {
			return .Blob_Entries_Invalid
		}
	}
	return .None
}

// resource_create_blob_encode validates and writes a Resource_Create_Blob command (56 bytes).
resource_create_blob_encode :: proc "contextless" (
	ctx_id: u32,
	resource_id: u32,
	blob_memory: Blob_Memory,
	blob_flags: Blob_Flags,
	entry_count: u32,
	blob_id: u64,
	size: u64,
	destination: []u8,
	fence_id: u64 = 0,
) -> (written: int, problem: Validation_Problem) {
	if resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if _, memory_ok := blob_memory_of_word(u32(blob_memory)); !memory_ok {
		return 0, .Unknown_Blob_Memory
	}
	flags_word := transmute(u32)blob_flags
	if _, flags_ok := blob_flags_of_word(flags_word); !flags_ok {
		return 0, .Unknown_Blob_Flags
	}
	if entry_count > MAX_BACKING_ENTRIES {
		return 0, .Too_Many_Backing_Entries
	}
	if problem = blob_rules_check(ctx_id, blob_memory, entry_count); problem != .None {
		return 0, problem
	}
	if size == 0 {
		return 0, .Zero_Blob_Size
	}
	if len(destination) < RESOURCE_CREATE_BLOB_SIZE {
		return 0, .Buffer_Too_Short
	}
	header_flags := Header_Flags{}
	if fence_id != 0 {
		header_flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Resource_Create_Blob, flags = header_flags, fence_id = fence_id, ctx_id = ctx_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, resource_id)
	byte_order.write_u32_little_endian(destination, 28, u32(blob_memory))
	byte_order.write_u32_little_endian(destination, 32, flags_word)
	byte_order.write_u32_little_endian(destination, 36, entry_count)
	byte_order.write_u64_little_endian(destination, 40, blob_id)
	byte_order.write_u64_little_endian(destination, 48, size)
	return RESOURCE_CREATE_BLOB_SIZE, .None
}

// resource_create_blob_decode validates and decodes a Resource_Create_Blob command.
resource_create_blob_decode :: proc "contextless" (source: []u8) -> (request: Resource_Create_Blob_Request, problem: Validation_Problem) {
	if len(source) < RESOURCE_CREATE_BLOB_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Resource_Create_Blob {
		return {}, .Unexpected_Response_Type
	}
	resource_id := byte_order.read_u32_little_endian(source, 24)
	if resource_id == 0 {
		return {}, .Zero_Resource_Id
	}
	blob_memory, memory_ok := blob_memory_of_word(byte_order.read_u32_little_endian(source, 28))
	if !memory_ok {
		return {}, .Unknown_Blob_Memory
	}
	blob_flags, flags_ok := blob_flags_of_word(byte_order.read_u32_little_endian(source, 32))
	if !flags_ok {
		return {}, .Unknown_Blob_Flags
	}
	entry_count := byte_order.read_u32_little_endian(source, 36)
	if entry_count > MAX_BACKING_ENTRIES {
		return {}, .Too_Many_Backing_Entries
	}
	if rules_problem := blob_rules_check(header.ctx_id, blob_memory, entry_count); rules_problem != .None {
		return {}, rules_problem
	}
	blob_id := byte_order.read_u64_little_endian(source, 40)
	size := byte_order.read_u64_little_endian(source, 48)
	if size == 0 {
		return {}, .Zero_Blob_Size
	}
	return Resource_Create_Blob_Request{
		header      = header,
		resource_id = resource_id,
		blob_memory = blob_memory,
		blob_flags  = blob_flags,
		entry_count = entry_count,
		blob_id     = blob_id,
		size        = size,
	}, .None
}

// submit_3d_header_encode writes the 32-byte Submit_3D header for a command
// stream of payload_bytes that the caller places right after it. A caller that
// encodes the stream in place uses it, and copies nothing.
submit_3d_header_encode :: proc "contextless" (ctx_id: u32, payload_bytes: int, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Context_Id
	}
	if payload_bytes <= 0 || payload_bytes > MAX_SUBMIT_3D_BYTES || payload_bytes % 4 != 0 {
		return 0, .Submit_Size_Invalid
	}
	if len(destination) < SUBMIT_3D_HEADER_SIZE {
		return 0, .Buffer_Too_Short
	}
	flags := Header_Flags{}
	if fence_id != 0 {
		flags = {.Fence}
	}
	_, problem = ctrl_header_encode(Ctrl_Header{command_type = .Submit_3D, flags = flags, fence_id = fence_id, ctx_id = ctx_id}, destination)
	if problem != .None {
		return 0, problem
	}
	byte_order.write_u32_little_endian(destination, 24, u32(payload_bytes))
	byte_order.write_u32_little_endian(destination, 28, 0)
	return SUBMIT_3D_HEADER_SIZE, .None
}

// submit_3d_encode frames a 32-bit word-aligned Venus or 3D command stream
// inside a Submit_3D control queue packet.
submit_3d_encode :: proc "contextless" (ctx_id: u32, command_stream: []u8, destination: []u8, fence_id: u64 = 0) -> (written: int, problem: Validation_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Context_Id
	}
	if len(command_stream) == 0 || len(command_stream) > MAX_SUBMIT_3D_BYTES || len(command_stream) % 4 != 0 {
		return 0, .Submit_Size_Invalid
	}
	total_bytes := SUBMIT_3D_HEADER_SIZE + len(command_stream)
	if len(destination) < total_bytes {
		return 0, .Buffer_Too_Short
	}
	_, problem = submit_3d_header_encode(ctx_id, len(command_stream), destination, fence_id)
	if problem != .None {
		return 0, problem
	}
	copy(destination[SUBMIT_3D_HEADER_SIZE:total_bytes], command_stream)
	return total_bytes, .None
}

// submit_3d_decode validates a Submit_3D packet and returns a subslice over its command stream.
submit_3d_decode :: proc "contextless" (source: []u8) -> (frame: Submit_3D_Frame, problem: Validation_Problem) {
	if len(source) < SUBMIT_3D_HEADER_SIZE {
		return {}, .Buffer_Too_Short
	}
	header, header_problem := ctrl_header_decode(source)
	if header_problem != .None {
		return {}, header_problem
	}
	if header.command_type != .Submit_3D {
		return {}, .Unexpected_Response_Type
	}
	if header.ctx_id == 0 {
		return {}, .Zero_Context_Id
	}
	payload_size := byte_order.read_u32_little_endian(source, 24)
	if byte_order.read_u32_little_endian(source, 28) != 0 {
		return {}, .Non_Zero_Padding
	}
	if payload_size == 0 || payload_size > MAX_SUBMIT_3D_BYTES || payload_size % 4 != 0 {
		return {}, .Submit_Size_Invalid
	}
	total_bytes := SUBMIT_3D_HEADER_SIZE + int(payload_size)
	if len(source) < total_bytes {
		return {}, .Buffer_Too_Short
	}
	return Submit_3D_Frame{
		header  = header,
		payload = source[SUBMIT_3D_HEADER_SIZE:total_bytes],
	}, .None
}
