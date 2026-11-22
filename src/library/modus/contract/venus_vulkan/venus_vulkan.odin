// The Venus wire protocol: Vulkan commands serialized as Mesa and
// virglrenderer serialize them (VK_EXT_command_serialization and
// VK_MESA_venus_protocol of the venus-protocol repository), carried in a
// VirtIO-GPU Submit_3D packet or in a Venus ring (src/md/features/gpu_access.md).
//
// A command is its VkCommandTypeEXT word, its VkCommandFlagsEXT word, then its
// parameters in order. Integers are little-endian and padded to 32 bits, an
// enum is an int32, a size_t is a uint64, an object handle is its 64-bit
// object id, and a pointer or an array is a uint64 count followed by the
// values. A reply is the VkCommandTypeEXT word, then the return value and the
// output parameters. No command carries its length: a decoder must know every
// command that it reads.
//
// This package allocates no memory and calls no kernel operation.
package venus_vulkan

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// The wire format that a Venus capset must announce (vn_protocol.py,
// VN_WIRE_FORMAT_VERSION).
WIRE_FORMAT_VERSION :: u32(1)

// The renderer creates no instance below Vulkan 1.1 (vkr_instance.c).
API_VERSION_1_1 :: u32((1 << 22) | (1 << 12))

// The two words that start every command.
COMMAND_HEADER_BYTES :: 8

// A string of the wire is at most this many bytes, its null byte included.
MAX_STRING_BYTES :: 256

// The decoder of this package refuses an array of more elements: the system
// sends at most a few elements in each array.
MAX_ARRAY_ELEMENTS :: 16

// Fixed array lengths of VkPhysicalDeviceProperties.
PHYSICAL_DEVICE_NAME_BYTES :: 256
UUID_BYTES :: 16

// An object id names one Vulkan object of one context. The driver side
// chooses it; 0 is VK_NULL_HANDLE.
Object_Id :: distinct u64

// The command type words of VK_EXT_command_serialization that this package
// encodes. The values are those of xmls/VK_EXT_command_serialization.xml.
Command_Type :: enum u32 {
	Create_Instance                = 0,
	Enumerate_Physical_Devices     = 2,
	Get_Physical_Device_Properties = 6,
	Create_Device                  = 11,
	Queue_Submit                   = 18,
	Queue_Wait_Idle                = 19,
	Allocate_Memory                = 21,
	Bind_Buffer_Memory             = 28,
	Bind_Image_Memory              = 29,
	Create_Buffer                  = 50,
	Create_Image                   = 54,
	Create_Image_View              = 57,
	Create_Shader_Module           = 59,
	Create_Graphics_Pipelines      = 65,
	Create_Pipeline_Layout         = 68,
	Create_Framebuffer             = 80,
	Create_Render_Pass             = 82,
	Create_Command_Pool            = 85,
	Allocate_Command_Buffers       = 88,
	Begin_Command_Buffer           = 90,
	End_Command_Buffer             = 91,
	Cmd_Bind_Pipeline              = 93,
	Cmd_Set_Viewport               = 94,
	Cmd_Set_Scissor                = 95,
	Cmd_Bind_Descriptor_Sets       = 103,
	Cmd_Bind_Index_Buffer          = 104,
	Cmd_Bind_Vertex_Buffers        = 105,
	Cmd_Draw                       = 106,
	Cmd_Draw_Indexed               = 107,
	Cmd_Copy_Buffer                = 112,
	Cmd_Copy_Buffer_To_Image       = 115,
	Cmd_Copy_Image_To_Buffer       = 116,
	Cmd_Update_Buffer              = 117,
	Cmd_Clear_Color_Image          = 119,
	Cmd_Pipeline_Barrier           = 126,
	Cmd_Push_Constants             = 132,
	Cmd_Begin_Render_Pass          = 133,
	Cmd_End_Render_Pass            = 135,
	Get_Device_Queue_2             = 155,
	Set_Reply_Command_Stream       = 178,
	Seek_Reply_Command_Stream      = 179,
	Create_Ring                    = 188,
	Destroy_Ring                   = 189,
	Notify_Ring                    = 190,
}

// VK_COMMAND_GENERATE_REPLY_BIT_EXT asks the renderer for a reply.
Command_Flag :: enum u32 {
	Generate_Reply = 0,
}

Command_Flags :: bit_set[Command_Flag; u32]

// The VkStructureType values of the structures that this package encodes.
Structure_Type :: enum i32 {
	Application_Info             = 0,
	Instance_Create_Info         = 1,
	Device_Queue_Create_Info     = 2,
	Device_Create_Info           = 3,
	Submit_Info                  = 4,
	Memory_Allocate_Info         = 5,
	Buffer_Create_Info                        = 12,
	Image_Create_Info                         = 14,
	Image_View_Create_Info                    = 15,
	Shader_Module_Create_Info                 = 16,
	Pipeline_Shader_Stage_Create_Info         = 18,
	Pipeline_Vertex_Input_State_Create_Info   = 19,
	Pipeline_Input_Assembly_State_Create_Info = 20,
	Pipeline_Viewport_State_Create_Info       = 22,
	Pipeline_Rasterization_State_Create_Info  = 23,
	Pipeline_Multisample_State_Create_Info    = 24,
	Pipeline_Color_Blend_State_Create_Info    = 26,
	Pipeline_Dynamic_State_Create_Info        = 27,
	Graphics_Pipeline_Create_Info             = 28,
	Pipeline_Layout_Create_Info               = 30,
	Framebuffer_Create_Info                   = 37,
	Render_Pass_Create_Info                   = 38,
	Command_Pool_Create_Info                  = 39,
	Command_Buffer_Allocate_Info              = 40,
	Command_Buffer_Begin_Info                 = 42,
	Render_Pass_Begin_Info                    = 43,
	Image_Memory_Barrier                      = 45,
	Memory_Barrier                            = 46,
	Device_Queue_Info_2          = 1000145003,
	Ring_Create_Info             = 1000384000,
}

// The VkResult values of Vulkan 1.0 and 1.1. A reply with another value is
// refused at the border.
Vulkan_Result :: enum i32 {
	Success                     = 0,
	Not_Ready                   = 1,
	Timeout                     = 2,
	Event_Set                   = 3,
	Event_Reset                 = 4,
	Incomplete                  = 5,
	Error_Out_Of_Host_Memory    = -1,
	Error_Out_Of_Device_Memory  = -2,
	Error_Initialization_Failed = -3,
	Error_Device_Lost           = -4,
	Error_Memory_Map_Failed     = -5,
	Error_Layer_Not_Present     = -6,
	Error_Extension_Not_Present = -7,
	Error_Feature_Not_Present   = -8,
	Error_Incompatible_Driver   = -9,
	Error_Too_Many_Objects      = -10,
	Error_Format_Not_Supported  = -11,
	Error_Fragmented_Pool       = -12,
	Error_Unknown               = -13,
	Error_Out_Of_Pool_Memory    = -1000069000,
}

Physical_Device_Type :: enum i32 {
	Other          = 0,
	Integrated_Gpu = 1,
	Discrete_Gpu   = 2,
	Virtual_Gpu    = 3,
	Cpu            = 4,
}

Index_Type :: enum i32 {
	Uint16 = 0,
	Uint32 = 1,
}

Pipeline_Bind_Point :: enum i32 {
	Graphics = 0,
	Compute  = 1,
}

// The image layouts that the commands of this package name.
Image_Layout :: enum i32 {
	Undefined                    = 0,
	General                      = 1,
	Color_Attachment_Optimal     = 2,
	Shader_Read_Only_Optimal     = 5,
	Transfer_Source_Optimal      = 6,
	Transfer_Destination_Optimal = 7,
	Present_Source               = 1000001002, // VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
}

// The VkFormat values that the objects of this package name: the color
// formats of a render target and the vertex attribute formats of the 2D
// vertex.
Format :: enum i32 {
	Undefined                 = 0,
	R8G8B8A8_Unorm            = 37,
	R8G8B8A8_Srgb             = 43,
	B8G8R8A8_Unorm            = 44,
	B8G8R8A8_Srgb             = 50,
	R32G32_Signed_Float       = 103,
	R32G32B32A32_Signed_Float = 109,
}

Image_Type :: enum i32 {
	One_Dimension    = 0,
	Two_Dimensions   = 1,
	Three_Dimensions = 2,
}

Image_View_Type :: enum i32 {
	One_Dimension    = 0,
	Two_Dimensions   = 1,
	Three_Dimensions = 2,
}

Image_Tiling :: enum i32 {
	Optimal = 0,
	Linear  = 1,
}

// VkSampleCountFlagBits as a value: the system renders with one sample.
Sample_Count :: enum u32 {
	One = 1,
}

Sharing_Mode :: enum i32 {
	Exclusive  = 0,
	Concurrent = 1,
}

Component_Swizzle :: enum i32 {
	Identity = 0,
	Zero     = 1,
	One      = 2,
	Red      = 3,
	Green    = 4,
	Blue     = 5,
	Alpha    = 6,
}

Attachment_Load_Op :: enum i32 {
	Load      = 0,
	Clear     = 1,
	Dont_Care = 2,
}

Attachment_Store_Op :: enum i32 {
	Store     = 0,
	Dont_Care = 1,
}

Vertex_Input_Rate :: enum i32 {
	Vertex   = 0,
	Instance = 1,
}

Primitive_Topology :: enum i32 {
	Point_List     = 0,
	Line_List      = 1,
	Line_Strip     = 2,
	Triangle_List  = 3,
	Triangle_Strip = 4,
	Triangle_Fan   = 5,
}

Polygon_Mode :: enum i32 {
	Fill  = 0,
	Line  = 1,
	Point = 2,
}

Front_Face :: enum i32 {
	Counter_Clockwise = 0,
	Clockwise         = 1,
}

Blend_Factor :: enum i32 {
	Zero                        = 0,
	One                         = 1,
	Source_Color                = 2,
	One_Minus_Source_Color      = 3,
	Destination_Color           = 4,
	One_Minus_Destination_Color = 5,
	Source_Alpha                = 6,
	One_Minus_Source_Alpha      = 7,
	Destination_Alpha           = 8,
	One_Minus_Destination_Alpha = 9,
}

Blend_Op :: enum i32 {
	Add              = 0,
	Subtract         = 1,
	Reverse_Subtract = 2,
	Min              = 3,
	Max              = 4,
}

// The logic operation of a color blend state. The system blends and never
// enables a logic operation, so the wire carries only the first member.
Logic_Op :: enum i32 {
	Clear = 0,
}

Dynamic_State :: enum i32 {
	Viewport = 0,
	Scissor  = 1,
}

// VkShaderStageFlagBits, by bit position.
Shader_Stage_Flag :: enum u32 {
	Vertex                  = 0,
	Tessellation_Control    = 1,
	Tessellation_Evaluation = 2,
	Geometry                = 3,
	Fragment                = 4,
	Compute                 = 5,
}

Shader_Stages :: bit_set[Shader_Stage_Flag; u32]

// VkCullModeFlagBits, by bit position.
Cull_Mode_Flag :: enum u32 {
	Front = 0,
	Back  = 1,
}

Cull_Modes :: bit_set[Cull_Mode_Flag; u32]

// VkColorComponentFlagBits, by bit position.
Color_Component_Flag :: enum u32 {
	Red   = 0,
	Green = 1,
	Blue  = 2,
	Alpha = 3,
}

Color_Components :: bit_set[Color_Component_Flag; u32]

// VkImageUsageFlagBits, by bit position.
Image_Usage_Flag :: enum u32 {
	Transfer_Source          = 0,
	Transfer_Destination     = 1,
	Sampled                  = 2,
	Storage                  = 3,
	Color_Attachment         = 4,
	Depth_Stencil_Attachment = 5,
	Transient_Attachment     = 6,
	Input_Attachment         = 7,
}

Image_Usage :: bit_set[Image_Usage_Flag; u32]

// VkPipelineStageFlagBits, by bit position.
Pipeline_Stage_Flag :: enum u32 {
	Top_Of_Pipe                    = 0,
	Draw_Indirect                  = 1,
	Vertex_Input                   = 2,
	Vertex_Shader                  = 3,
	Tessellation_Control_Shader    = 4,
	Tessellation_Evaluation_Shader = 5,
	Geometry_Shader                = 6,
	Fragment_Shader                = 7,
	Early_Fragment_Tests           = 8,
	Late_Fragment_Tests            = 9,
	Color_Attachment_Output        = 10,
	Compute_Shader                 = 11,
	Transfer                       = 12,
	Bottom_Of_Pipe                 = 13,
	Host                           = 14,
	All_Graphics                   = 15,
	All_Commands                   = 16,
}

Pipeline_Stages :: bit_set[Pipeline_Stage_Flag; u32]

// VkAccessFlagBits, by bit position.
Access_Flag :: enum u32 {
	Indirect_Command_Read          = 0,
	Index_Read                     = 1,
	Vertex_Attribute_Read          = 2,
	Uniform_Read                   = 3,
	Input_Attachment_Read          = 4,
	Shader_Read                    = 5,
	Shader_Write                   = 6,
	Color_Attachment_Read          = 7,
	Color_Attachment_Write         = 8,
	Depth_Stencil_Attachment_Read  = 9,
	Depth_Stencil_Attachment_Write = 10,
	Transfer_Read                  = 11,
	Transfer_Write                 = 12,
	Host_Read                      = 13,
	Host_Write                     = 14,
	Memory_Read                    = 15,
	Memory_Write                   = 16,
}

Access_Flags :: bit_set[Access_Flag; u32]

Command_Buffer_Level :: enum i32 {
	Primary   = 0,
	Secondary = 1,
}

Subpass_Contents :: enum i32 {
	Inline = 0,
}

// The member that a VkClearValue carries: its union tag on the wire. The
// default tag of vn_protocol.py is Color.
Clear_Value_Tag :: enum u32 {
	Color         = 0,
	Depth_Stencil = 1,
}

// The member that a VkClearColorValue carries: its union tag on the wire.
// The default tag of vn_protocol.py is Unsigned_32, which keeps the bits of
// each float.
Clear_Color_Tag :: enum u32 {
	Float_32    = 0,
	Signed_32   = 1,
	Unsigned_32 = 2,
}

// VkBufferUsageFlagBits, by bit position.
Buffer_Usage_Flag :: enum u32 {
	Transfer_Source      = 0,
	Transfer_Destination = 1,
	Uniform_Texel_Buffer = 2,
	Storage_Texel_Buffer = 3,
	Uniform_Buffer       = 4,
	Storage_Buffer       = 5,
	Index_Buffer         = 6,
	Vertex_Buffer        = 7,
	Indirect_Buffer      = 8,
}

Buffer_Usage :: bit_set[Buffer_Usage_Flag; u32]

// VkCommandPoolCreateFlagBits, by bit position.
Command_Pool_Flag :: enum u32 {
	Transient            = 0,
	Reset_Command_Buffer = 1,
}

Command_Pool_Flags :: bit_set[Command_Pool_Flag; u32]

// VkCommandBufferUsageFlagBits, by bit position.
Command_Buffer_Usage_Flag :: enum u32 {
	One_Time_Submit      = 0,
	Render_Pass_Continue = 1,
	Simultaneous_Use     = 2,
}

Command_Buffer_Usage :: bit_set[Command_Buffer_Usage_Flag; u32]

// VkImageAspectFlagBits, by bit position.
Image_Aspect_Flag :: enum u32 {
	Color   = 0,
	Depth   = 1,
	Stencil = 2,
}

Image_Aspects :: bit_set[Image_Aspect_Flag; u32]

// Why an encoder, a decoder, the ring or the translator refused an input.
Venus_Problem :: enum u8 {
	None = 0,
	Buffer_Too_Short,
	Stream_Empty,
	Stream_Too_Large,
	Stream_Truncated,
	Misaligned_Length,
	Unknown_Command_Type,
	Unknown_Command_Flags,
	Unexpected_Command_Type,
	Structure_Type_Mismatch,
	Next_Chain_Refused,
	Pointer_Invalid,
	Array_Size_Mismatch,
	Count_Out_Of_Range,
	Zero_Object_Id,
	Object_Id_Mismatch,
	Object_Id_Overflow,
	Unknown_Enum_Word,
	Unknown_Flag_Bits,
	Unknown_Union_Tag,
	Unknown_Result,
	String_Too_Long,
	String_Unterminated,
	Zero_Extent,
	Dimension_Too_Large,
	Invalid_Slot,
	Capset_Too_Short,
	Capset_Wire_Format_Unsupported,
	Capset_Boolean_Invalid,
	Ring_Memory_Misaligned,
	Ring_Memory_Too_Small,
	Ring_Buffer_Size_Invalid,
	Ring_Full,
	Ring_Fatal,
	Ring_Head_Invalid,
	Ring_Tail_Invalid,
	Ring_Status_Invalid,
	Webgpu_Stream_Invalid,
	Virtio_Frame_Invalid,
	Missing_Flag_Bits,
	Shader_Code_Invalid,
	Layout_Transition_Invalid,
	Draw_Table_Refused,
	Gpu_Buffer_Too_Small,
	Reply_Not_Requested, // A command sent for its reply has no flag Generate_Reply.
	Reply_Stream_Full, // The reply stream has no room until a waiting reply is read.
	Reply_Already_Read,
	String_Not_Text, // A string of a reply is not valid UTF-8.
	Client_Command_Refused, // A client stream holds a command of the ring or of the reply stream, which only the GPU device service sends.
	Client_Reply_Refused, // A client stream asks for a reply, which only the GPU device service reads.
}

// Encoder appends commands to caller-owned storage. In measuring mode it
// counts the bytes and writes nothing, so a caller can size a destination
// before it writes. A command that fails leaves no byte behind.
Encoder :: struct {
	storage:       []u8,
	used_bytes:    int,
	command_count: u32,
	measuring:     bool,
	problem:       Venus_Problem,
}

// Decoder reads a command stream or a reply stream. The first fault stops it.
Decoder :: struct {
	source:  []u8,
	cursor:  int,
	problem: Venus_Problem,
}

encoder_init :: proc "contextless" (storage: []u8) -> Encoder {
	return Encoder{storage = storage}
}

// encoder_measure returns an encoder that only counts bytes.
encoder_measure :: proc "contextless" () -> Encoder {
	return Encoder{measuring = true}
}

encoder_bytes :: proc "contextless" (encoder: ^Encoder) -> []u8 {
	if encoder.measuring {
		return nil
	}
	return encoder.storage[:encoder.used_bytes]
}

decoder_init :: proc "contextless" (source: []u8) -> Decoder {
	return Decoder{source = source}
}

decoder_done :: proc "contextless" (decoder: ^Decoder) -> bool {
	return decoder.problem == .None && decoder.cursor == len(decoder.source)
}

// Border conversions from wire words to closed enumerations.

command_type_of_word :: proc "contextless" (word: u32) -> (command_type: Command_Type, ok: bool) {
	return enum_word.member_of_word(Command_Type, u64(word))
}

command_flags_of_word :: proc "contextless" (word: u32) -> (flags: Command_Flags, ok: bool) {
	known := Command_Flags{.Generate_Reply}
	if word & ~transmute(u32)known != 0 {
		return {}, false
	}
	return transmute(Command_Flags)word, true
}

structure_type_of_word :: proc "contextless" (word: i32) -> (structure_type: Structure_Type, ok: bool) {
	return enum_word.member_of_word(Structure_Type, u64(i64(word)))
}

vulkan_result_of_word :: proc "contextless" (word: i32) -> (result: Vulkan_Result, ok: bool) {
	return enum_word.member_of_word(Vulkan_Result, u64(i64(word)))
}

physical_device_type_of_word :: proc "contextless" (word: i32) -> (device_type: Physical_Device_Type, ok: bool) {
	return enum_word.member_of_word(Physical_Device_Type, u64(i64(word)))
}

index_type_of_word :: proc "contextless" (word: i32) -> (index_type: Index_Type, ok: bool) {
	return enum_word.member_of_word(Index_Type, u64(i64(word)))
}

pipeline_bind_point_of_word :: proc "contextless" (word: i32) -> (bind_point: Pipeline_Bind_Point, ok: bool) {
	return enum_word.member_of_word(Pipeline_Bind_Point, u64(i64(word)))
}

image_layout_of_word :: proc "contextless" (word: i32) -> (layout: Image_Layout, ok: bool) {
	return enum_word.member_of_word(Image_Layout, u64(i64(word)))
}

command_buffer_level_of_word :: proc "contextless" (word: i32) -> (level: Command_Buffer_Level, ok: bool) {
	return enum_word.member_of_word(Command_Buffer_Level, u64(i64(word)))
}

subpass_contents_of_word :: proc "contextless" (word: i32) -> (contents: Subpass_Contents, ok: bool) {
	return enum_word.member_of_word(Subpass_Contents, u64(i64(word)))
}

clear_value_tag_of_word :: proc "contextless" (word: u32) -> (tag: Clear_Value_Tag, ok: bool) {
	return enum_word.member_of_word(Clear_Value_Tag, u64(word))
}

clear_color_tag_of_word :: proc "contextless" (word: u32) -> (tag: Clear_Color_Tag, ok: bool) {
	return enum_word.member_of_word(Clear_Color_Tag, u64(word))
}

format_of_word :: proc "contextless" (word: i32) -> (format: Format, ok: bool) {
	return enum_word.member_of_word(Format, u64(i64(word)))
}

sample_count_of_word :: proc "contextless" (word: u32) -> (count: Sample_Count, ok: bool) {
	return enum_word.member_of_word(Sample_Count, u64(word))
}

// The masks of the known bits of each flag word.
BUFFER_USAGE_KNOWN_BITS :: u32(0x0000_01FF)
COMMAND_POOL_KNOWN_BITS :: u32(0x0000_0003)
COMMAND_BUFFER_USAGE_KNOWN_BITS :: u32(0x0000_0007)
IMAGE_ASPECT_KNOWN_BITS :: u32(0x0000_0007)
IMAGE_USAGE_KNOWN_BITS :: u32(0x0000_00FF)
SHADER_STAGE_KNOWN_BITS :: u32(0x0000_003F)
CULL_MODE_KNOWN_BITS :: u32(0x0000_0003)
COLOR_COMPONENT_KNOWN_BITS :: u32(0x0000_000F)
PIPELINE_STAGE_KNOWN_BITS :: u32(0x0001_FFFF)
ACCESS_KNOWN_BITS :: u32(0x0001_FFFF)

// VkDependencyFlagBits: by region, view local, device group.
DEPENDENCY_KNOWN_BITS :: u32(0x0000_0007)

// VK_ATTACHMENT_UNUSED: a reference that names no attachment.
ATTACHMENT_UNUSED :: u32(0xFFFF_FFFF)

// VK_QUEUE_FAMILY_IGNORED: a barrier that transfers no ownership.
QUEUE_FAMILY_IGNORED :: u32(0xFFFF_FFFF)

// The largest width or height of an image or a framebuffer that the
// encoders take, the bound of the WebGPU subset.
MAX_IMAGE_DIMENSION :: 16384

// vkCmdUpdateBuffer carries at most 65536 bytes, a multiple of 4.
MAX_UPDATE_BUFFER_BYTES :: 65536

// vkCmdPushConstants: the system pushes at most 128 bytes, the least
// maxPushConstantsSize that Vulkan guarantees.
MAX_PUSH_CONSTANT_BYTES :: 128

// A shader module of the system is at most 64 KiB of SPIR-V.
MAX_SHADER_CODE_WORDS :: 16384

// The first word of a SPIR-V module.
SPIRV_MAGIC :: u32(0x0723_0203)

// Encoder primitives. Each one stops on the first fault of the encoder.

@(private)
encoder_room :: proc "contextless" (encoder: ^Encoder, byte_count: int) -> (offset: int, ok: bool) {
	if encoder.problem != .None {
		return 0, false
	}
	if !encoder.measuring && len(encoder.storage) - encoder.used_bytes < byte_count {
		encoder.problem = .Buffer_Too_Short
		return 0, false
	}
	offset = encoder.used_bytes
	encoder.used_bytes += byte_count
	return offset, !encoder.measuring
}

@(private)
put_u32 :: proc "contextless" (encoder: ^Encoder, value: u32) {
	if offset, write := encoder_room(encoder, 4); write {
		byte_order.write_u32_little_endian(encoder.storage, offset, value)
	}
}

@(private)
put_i32 :: proc "contextless" (encoder: ^Encoder, value: i32) {
	put_u32(encoder, u32(value))
}

@(private)
put_f32 :: proc "contextless" (encoder: ^Encoder, value: f32) {
	put_u32(encoder, transmute(u32)value)
}

@(private)
put_u64 :: proc "contextless" (encoder: ^Encoder, value: u64) {
	if offset, write := encoder_room(encoder, 8); write {
		byte_order.write_u64_little_endian(encoder.storage, offset, value)
	}
}

@(private)
put_object :: proc "contextless" (encoder: ^Encoder, id: Object_Id) {
	put_u64(encoder, u64(id))
}

@(private)
put_array_size :: proc "contextless" (encoder: ^Encoder, count: u64) {
	put_u64(encoder, count)
}

@(private)
put_pointer :: proc "contextless" (encoder: ^Encoder, present: bool) {
	put_u64(encoder, present ? 1 : 0)
}

@(private)
put_structure :: proc "contextless" (encoder: ^Encoder, structure_type: Structure_Type) {
	put_i32(encoder, i32(structure_type))
	// The system sends no extension structure: every pNext is null.
	put_pointer(encoder, false)
}

// put_bytes writes the bytes of a blob array, padded with zero bytes to 32
// bits. The caller writes the array size before it.
@(private)
put_bytes :: proc "contextless" (encoder: ^Encoder, bytes: []u8) {
	padded := (len(bytes) + 3) & ~int(3)
	if offset, write := encoder_room(encoder, padded); write {
		for index in 0 ..< padded {
			encoder.storage[offset + index] = index < len(bytes) ? bytes[index] : 0
		}
	}
}

// put_string writes an optional C string: absent when empty, else its bytes
// and its null byte, padded with zero bytes to 32 bits.
@(private)
put_string :: proc "contextless" (encoder: ^Encoder, text: string) {
	if len(text) == 0 {
		put_array_size(encoder, 0)
		return
	}
	size := len(text) + 1
	put_array_size(encoder, u64(size))
	padded := (size + 3) & ~int(3)
	if offset, write := encoder_room(encoder, padded); write {
		for index in 0 ..< padded {
			encoder.storage[offset + index] = index < len(text) ? text[index] : 0
		}
	}
}

// command_begin writes the two header words and returns the mark that
// command_end rolls back to on a fault.
@(private)
command_begin :: proc "contextless" (encoder: ^Encoder, command_type: Command_Type, flags: Command_Flags) -> (mark: int, problem: Venus_Problem) {
	if encoder.problem != .None {
		return encoder.used_bytes, encoder.problem
	}
	if _, flags_ok := command_flags_of_word(transmute(u32)flags); !flags_ok {
		return encoder.used_bytes, .Unknown_Command_Flags
	}
	mark = encoder.used_bytes
	put_u32(encoder, u32(command_type))
	put_u32(encoder, transmute(u32)flags)
	return mark, .None
}

@(private)
command_end :: proc "contextless" (encoder: ^Encoder, mark: int) -> Venus_Problem {
	if encoder.problem != .None {
		problem := encoder.problem
		encoder.used_bytes = mark
		encoder.problem = .None
		return problem
	}
	encoder.command_count += 1
	return .None
}

// Decoder primitives. Each one returns 0 after the first fault.

@(private)
decoder_take :: proc "contextless" (decoder: ^Decoder, byte_count: int) -> (offset: int, ok: bool) {
	if decoder.problem != .None {
		return 0, false
	}
	if byte_count < 0 || len(decoder.source) - decoder.cursor < byte_count {
		decoder.problem = .Stream_Truncated
		return 0, false
	}
	offset = decoder.cursor
	decoder.cursor += byte_count
	return offset, true
}

@(private)
get_u32 :: proc "contextless" (decoder: ^Decoder) -> u32 {
	if offset, ok := decoder_take(decoder, 4); ok {
		return byte_order.read_u32_little_endian(decoder.source, offset)
	}
	return 0
}

@(private)
get_i32 :: proc "contextless" (decoder: ^Decoder) -> i32 {
	return i32(get_u32(decoder))
}

@(private)
get_u64 :: proc "contextless" (decoder: ^Decoder) -> u64 {
	if offset, ok := decoder_take(decoder, 8); ok {
		return byte_order.read_u64_little_endian(decoder.source, offset)
	}
	return 0
}

@(private)
peek_u64 :: proc "contextless" (decoder: ^Decoder) -> u64 {
	if decoder.problem != .None || len(decoder.source) - decoder.cursor < 8 {
		return 0
	}
	return byte_order.read_u64_little_endian(decoder.source, decoder.cursor)
}

@(private)
fail :: proc "contextless" (decoder: ^Decoder, problem: Venus_Problem) {
	if decoder.problem == .None {
		decoder.problem = problem
	}
}

// get_pointer reads a simple pointer: 1 when present, 0 when absent. Any
// other count is a fault.
@(private)
get_pointer :: proc "contextless" (decoder: ^Decoder) -> bool {
	count := get_u64(decoder)
	if count > 1 {
		fail(decoder, .Pointer_Invalid)
		return false
	}
	return count == 1
}

@(private)
expect_pointer :: proc "contextless" (decoder: ^Decoder, present: bool) {
	if get_pointer(decoder) != present && decoder.problem == .None {
		fail(decoder, .Pointer_Invalid)
	}
}

@(private)
get_object :: proc "contextless" (decoder: ^Decoder) -> Object_Id {
	return Object_Id(get_u64(decoder))
}

@(private)
get_required_object :: proc "contextless" (decoder: ^Decoder) -> Object_Id {
	id := get_object(decoder)
	if id == 0 {
		fail(decoder, .Zero_Object_Id)
	}
	return id
}

// expect_array_size reads an array size that must equal count.
@(private)
expect_array_size :: proc "contextless" (decoder: ^Decoder, count: u64) {
	if get_u64(decoder) != count {
		fail(decoder, .Array_Size_Mismatch)
	}
}

@(private)
expect_structure :: proc "contextless" (decoder: ^Decoder, structure_type: Structure_Type) {
	word := get_i32(decoder)
	if decoder.problem != .None {
		return
	}
	if decoded, ok := structure_type_of_word(word); !ok || decoded != structure_type {
		fail(decoder, .Structure_Type_Mismatch)
		return
	}
	if get_pointer(decoder) {
		fail(decoder, .Next_Chain_Refused)
	}
}

// skip_string reads an optional C string and checks its null byte.
@(private)
skip_string :: proc "contextless" (decoder: ^Decoder) {
	size := get_u64(decoder)
	if size == 0 || decoder.problem != .None {
		return
	}
	if size > MAX_STRING_BYTES {
		fail(decoder, .String_Too_Long)
		return
	}
	padded := (int(size) + 3) & ~int(3)
	if offset, ok := decoder_take(decoder, padded); ok && decoder.source[offset + int(size) - 1] != 0 {
		fail(decoder, .String_Unterminated)
	}
}

// expect_command_type reads the first word of a reply.
@(private)
expect_command_type :: proc "contextless" (decoder: ^Decoder, command_type: Command_Type) {
	word := get_u32(decoder)
	if decoder.problem == .None && word != u32(command_type) {
		fail(decoder, .Unexpected_Command_Type)
	}
}

@(private)
get_result :: proc "contextless" (decoder: ^Decoder) -> Vulkan_Result {
	word := get_i32(decoder)
	if decoder.problem != .None {
		return .Error_Unknown
	}
	result, ok := vulkan_result_of_word(word)
	if !ok {
		fail(decoder, .Unknown_Result)
		return .Error_Unknown
	}
	return result
}
