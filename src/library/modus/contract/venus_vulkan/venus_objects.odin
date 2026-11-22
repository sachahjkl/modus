package venus_vulkan

import "modus:contract/webgpu_subset"

// The encoders of the Vulkan objects that a translated stream names: the
// image of a render target and its view, the memory bind of an image, the
// shader modules, the pipeline layout, the render pass, the framebuffer and
// the graphics pipeline. Each one validates its inputs, then writes the
// command in the order of the Vulkan parameters, as the generated
// vn_encode_vk* functions of Mesa do. The shape of each object is the one
// that the 2D draw of the system needs: one sample, one mip level, one
// layer, one color attachment, one subpass, the viewport and the scissor as
// dynamic state (src/md/features/gpu_access.md, "The Vulkan objects").

// A 2D image with one mip level and one layer. The initial layout is always
// UNDEFINED: a barrier gives the image its first layout.
Image_Description :: struct {
	format: Format,
	width:  u32,
	height: u32,
	usage:  Image_Usage,
	tiling: Image_Tiling,
}

// The one color attachment of a render pass, and its layouts at the start
// and at the end of the pass.
Color_Attachment_Description :: struct {
	format:         Format,
	load_op:        Attachment_Load_Op,
	store_op:       Attachment_Store_Op,
	initial_layout: Image_Layout,
	final_layout:   Image_Layout,
}

// VkPushConstantRange.
Push_Constant_Range :: struct {
	stages: Shader_Stages,
	offset: u32,
	size:   u32,
}

// VkVertexInputAttributeDescription of binding 0.
Vertex_Attribute :: struct {
	location: u32,
	format:   Format,
	offset:   u32,
}

MAX_VERTEX_ATTRIBUTES :: 8

// The blend of the one color attachment of a pipeline.
Color_Blend :: struct {
	enabled:                  bool,
	source_color_factor:      Blend_Factor,
	destination_color_factor: Blend_Factor,
	color_operation:          Blend_Op,
	source_alpha_factor:      Blend_Factor,
	destination_alpha_factor: Blend_Factor,
	alpha_operation:          Blend_Op,
}

// A graphics pipeline with a vertex and a fragment stage, one vertex
// binding, no depth test, and the viewport and the scissor as dynamic state.
Graphics_Pipeline_Description :: struct {
	vertex_shader:     Object_Id,
	fragment_shader:   Object_Id,
	entry_point:       string,
	vertex_stride:     u32,
	vertex_attributes: []Vertex_Attribute,
	topology:          Primitive_Topology,
	blend:             Color_Blend,
	layout:            Object_Id,
	render_pass:       Object_Id,
}

@(private)
enum_check :: proc "contextless" (value: $Enum) -> Venus_Problem {
	for member in Enum {
		if member == value {
			return .None
		}
	}
	return .Unknown_Enum_Word
}

@(private)
color_format_check :: proc "contextless" (format: Format) -> Venus_Problem {
	enum_check(format) or_return
	switch format {
	case .R8G8B8A8_Unorm, .R8G8B8A8_Srgb, .B8G8R8A8_Unorm, .B8G8R8A8_Srgb:
		return .None
	case .Undefined, .R32G32_Signed_Float, .R32G32B32A32_Signed_Float:
		return .Unknown_Enum_Word
	}
	return .Unknown_Enum_Word
}

@(private)
extent_check :: proc "contextless" (width, height: u32) -> Venus_Problem {
	if width == 0 || height == 0 {
		return .Zero_Extent
	}
	if width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION {
		return .Dimension_Too_Large
	}
	return .None
}

@(private)
put_subresource_range :: proc "contextless" (encoder: ^Encoder, range: Image_Subresource_Range) {
	put_u32(encoder, transmute(u32)range.aspects)
	put_u32(encoder, range.base_mip_level)
	put_u32(encoder, range.level_count)
	put_u32(encoder, range.base_array_layer)
	put_u32(encoder, range.layer_count)
}

// encode_create_image writes vkCreateImage for an exclusive 2D image of one
// sample, one mip level and one layer, in the layout UNDEFINED.
encode_create_image :: proc "contextless" (encoder: ^Encoder, device, image: Object_Id, description: Image_Description, flags := REPLY) -> Venus_Problem {
	if device == 0 || image == 0 {
		return .Zero_Object_Id
	}
	color_format_check(description.format) or_return
	extent_check(description.width, description.height) or_return
	usage_word := transmute(u32)description.usage
	if usage_word == 0 {
		return .Missing_Flag_Bits
	}
	if usage_word & ~IMAGE_USAGE_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	enum_check(description.tiling) or_return
	mark := command_begin(encoder, .Create_Image, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Image_Create_Info)
	put_u32(encoder, 0) // flags
	put_i32(encoder, i32(Image_Type.Two_Dimensions))
	put_i32(encoder, i32(description.format))
	put_u32(encoder, description.width)
	put_u32(encoder, description.height)
	put_u32(encoder, 1) // depth
	put_u32(encoder, 1) // mipLevels
	put_u32(encoder, 1) // arrayLayers
	put_u32(encoder, u32(Sample_Count.One))
	put_i32(encoder, i32(description.tiling))
	put_u32(encoder, usage_word)
	put_i32(encoder, i32(Sharing_Mode.Exclusive))
	put_u32(encoder, 0) // queueFamilyIndexCount
	put_array_size(encoder, 0)
	put_i32(encoder, i32(Image_Layout.Undefined))
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, image)
	return command_end(encoder, mark)
}

// encode_bind_image_memory writes vkBindImageMemory.
encode_bind_image_memory :: proc "contextless" (encoder: ^Encoder, device, image, memory: Object_Id, memory_offset: u64, flags := REPLY) -> Venus_Problem {
	if device == 0 || image == 0 || memory == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Bind_Image_Memory, flags) or_return
	put_object(encoder, device)
	put_object(encoder, image)
	put_object(encoder, memory)
	put_u64(encoder, memory_offset)
	return command_end(encoder, mark)
}

// encode_create_image_view writes vkCreateImageView for a 2D view with the
// identity swizzle.
encode_create_image_view :: proc "contextless" (encoder: ^Encoder, device, image, view: Object_Id, format: Format, range: Image_Subresource_Range, flags := REPLY) -> Venus_Problem {
	if device == 0 || image == 0 || view == 0 {
		return .Zero_Object_Id
	}
	color_format_check(format) or_return
	range_check(range) or_return
	mark := command_begin(encoder, .Create_Image_View, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Image_View_Create_Info)
	put_u32(encoder, 0) // flags
	put_object(encoder, image)
	put_i32(encoder, i32(Image_View_Type.Two_Dimensions))
	put_i32(encoder, i32(format))
	for _ in 0 ..< 4 {
		put_i32(encoder, i32(Component_Swizzle.Identity))
	}
	put_subresource_range(encoder, range)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, view)
	return command_end(encoder, mark)
}

// encode_create_shader_module writes vkCreateShaderModule. The code is
// SPIR-V that the build compiled: its header and each instruction length
// are checked, as the WebGPU subset checks them.
encode_create_shader_module :: proc "contextless" (encoder: ^Encoder, device, shader_module: Object_Id, code: []u8, flags := REPLY) -> Venus_Problem {
	if device == 0 || shader_module == 0 {
		return .Zero_Object_Id
	}
	if len(code) > MAX_SHADER_CODE_WORDS * 4 {
		return .Count_Out_Of_Range
	}
	if _, refusal := webgpu_subset.spirv_bytes_validate(code); refusal != .None {
		return .Shader_Code_Invalid
	}
	mark := command_begin(encoder, .Create_Shader_Module, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Shader_Module_Create_Info)
	put_u32(encoder, 0) // flags
	put_u64(encoder, u64(len(code))) // codeSize
	put_array_size(encoder, u64(len(code) / 4))
	put_bytes(encoder, code)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, shader_module)
	return command_end(encoder, mark)
}

@(private)
push_constant_range_check :: proc "contextless" (stages: Shader_Stages, offset, size: u32) -> Venus_Problem {
	stage_word := transmute(u32)stages
	if stage_word == 0 {
		return .Missing_Flag_Bits
	}
	if stage_word & ~SHADER_STAGE_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	if size == 0 {
		return .Zero_Extent
	}
	if offset % 4 != 0 || size % 4 != 0 {
		return .Misaligned_Length
	}
	if u64(offset) + u64(size) > MAX_PUSH_CONSTANT_BYTES {
		return .Count_Out_Of_Range
	}
	return .None
}

// encode_create_pipeline_layout writes vkCreatePipelineLayout.
encode_create_pipeline_layout :: proc "contextless" (encoder: ^Encoder, device, layout: Object_Id, set_layouts: []Object_Id, push_constant_ranges: []Push_Constant_Range, flags := REPLY) -> Venus_Problem {
	if device == 0 || layout == 0 {
		return .Zero_Object_Id
	}
	if len(set_layouts) > 0 {
		objects_check(set_layouts) or_return
	}
	if len(push_constant_ranges) > MAX_ARRAY_ELEMENTS {
		return .Count_Out_Of_Range
	}
	for range in push_constant_ranges {
		push_constant_range_check(range.stages, range.offset, range.size) or_return
	}
	mark := command_begin(encoder, .Create_Pipeline_Layout, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Pipeline_Layout_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, u32(len(set_layouts)))
	put_array_size(encoder, u64(len(set_layouts)))
	for id in set_layouts {
		put_object(encoder, id)
	}
	put_u32(encoder, u32(len(push_constant_ranges)))
	put_array_size(encoder, u64(len(push_constant_ranges)))
	for range in push_constant_ranges {
		put_u32(encoder, transmute(u32)range.stages)
		put_u32(encoder, range.offset)
		put_u32(encoder, range.size)
	}
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, layout)
	return command_end(encoder, mark)
}

// encode_create_render_pass writes vkCreateRenderPass with one color
// attachment, one graphics subpass that writes it in the layout
// COLOR_ATTACHMENT_OPTIMAL, and no dependency: the barriers of the command
// buffer order the work around the pass.
encode_create_render_pass :: proc "contextless" (encoder: ^Encoder, device, render_pass: Object_Id, attachment: Color_Attachment_Description, flags := REPLY) -> Venus_Problem {
	if device == 0 || render_pass == 0 {
		return .Zero_Object_Id
	}
	color_format_check(attachment.format) or_return
	enum_check(attachment.load_op) or_return
	enum_check(attachment.store_op) or_return
	enum_check(attachment.initial_layout) or_return
	enum_check(attachment.final_layout) or_return
	// Vulkan forbids the final layout UNDEFINED.
	if attachment.final_layout == .Undefined {
		return .Layout_Transition_Invalid
	}
	mark := command_begin(encoder, .Create_Render_Pass, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Render_Pass_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 1) // attachmentCount
	put_array_size(encoder, 1)
	put_u32(encoder, 0) // flags
	put_i32(encoder, i32(attachment.format))
	put_u32(encoder, u32(Sample_Count.One))
	put_i32(encoder, i32(attachment.load_op))
	put_i32(encoder, i32(attachment.store_op))
	put_i32(encoder, i32(Attachment_Load_Op.Dont_Care))
	put_i32(encoder, i32(Attachment_Store_Op.Dont_Care))
	put_i32(encoder, i32(attachment.initial_layout))
	put_i32(encoder, i32(attachment.final_layout))
	put_u32(encoder, 1) // subpassCount
	put_array_size(encoder, 1)
	put_u32(encoder, 0) // flags
	put_i32(encoder, i32(Pipeline_Bind_Point.Graphics))
	put_u32(encoder, 0) // inputAttachmentCount
	put_array_size(encoder, 0)
	put_u32(encoder, 1) // colorAttachmentCount
	put_array_size(encoder, 1)
	put_u32(encoder, 0) // attachment
	put_i32(encoder, i32(Image_Layout.Color_Attachment_Optimal))
	put_array_size(encoder, 0) // pResolveAttachments
	put_pointer(encoder, false) // pDepthStencilAttachment
	put_u32(encoder, 0) // preserveAttachmentCount
	put_array_size(encoder, 0)
	put_u32(encoder, 0) // dependencyCount
	put_array_size(encoder, 0)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, render_pass)
	return command_end(encoder, mark)
}

// encode_create_framebuffer writes vkCreateFramebuffer with one layer.
encode_create_framebuffer :: proc "contextless" (encoder: ^Encoder, device, framebuffer, render_pass: Object_Id, attachments: []Object_Id, width, height: u32, flags := REPLY) -> Venus_Problem {
	if device == 0 || framebuffer == 0 || render_pass == 0 {
		return .Zero_Object_Id
	}
	objects_check(attachments) or_return
	extent_check(width, height) or_return
	mark := command_begin(encoder, .Create_Framebuffer, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Framebuffer_Create_Info)
	put_u32(encoder, 0) // flags
	put_object(encoder, render_pass)
	put_u32(encoder, u32(len(attachments)))
	put_array_size(encoder, u64(len(attachments)))
	for id in attachments {
		put_object(encoder, id)
	}
	put_u32(encoder, width)
	put_u32(encoder, height)
	put_u32(encoder, 1) // layers
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, framebuffer)
	return command_end(encoder, mark)
}

// vertex_format_bytes gives the size of one vertex attribute of a format,
// and 0 for a format that is not a vertex format of the system.
@(private)
vertex_format_bytes :: proc "contextless" (format: Format) -> u32 {
	switch format {
	case .R32G32_Signed_Float:
		return 8
	case .R32G32B32A32_Signed_Float:
		return 16
	case .R8G8B8A8_Unorm:
		return 4
	case .Undefined, .R8G8B8A8_Srgb, .B8G8R8A8_Unorm, .B8G8R8A8_Srgb:
		return 0
	}
	return 0
}

@(private = "file")
pipeline_description_check :: proc "contextless" (description: Graphics_Pipeline_Description) -> Venus_Problem {
	if description.vertex_shader == 0 || description.fragment_shader == 0 || description.layout == 0 || description.render_pass == 0 {
		return .Zero_Object_Id
	}
	if len(description.entry_point) == 0 {
		return .String_Unterminated
	}
	string_check(description.entry_point) or_return
	if description.vertex_stride == 0 {
		return .Zero_Extent
	}
	if len(description.vertex_attributes) == 0 || len(description.vertex_attributes) > MAX_VERTEX_ATTRIBUTES {
		return .Count_Out_Of_Range
	}
	for attribute, index in description.vertex_attributes {
		enum_check(attribute.format) or_return
		attribute_bytes := vertex_format_bytes(attribute.format)
		if attribute_bytes == 0 {
			return .Unknown_Enum_Word
		}
		if u64(attribute.offset) + u64(attribute_bytes) > u64(description.vertex_stride) {
			return .Dimension_Too_Large
		}
		for other in description.vertex_attributes[:index] {
			if other.location == attribute.location {
				return .Count_Out_Of_Range
			}
		}
	}
	enum_check(description.topology) or_return
	blend := description.blend
	enum_check(blend.source_color_factor) or_return
	enum_check(blend.destination_color_factor) or_return
	enum_check(blend.color_operation) or_return
	enum_check(blend.source_alpha_factor) or_return
	enum_check(blend.destination_alpha_factor) or_return
	enum_check(blend.alpha_operation) or_return
	return .None
}

@(private = "file")
put_shader_stage :: proc "contextless" (encoder: ^Encoder, stage: Shader_Stage_Flag, shader_module: Object_Id, entry_point: string) {
	put_structure(encoder, .Pipeline_Shader_Stage_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, transmute(u32)Shader_Stages{stage})
	put_object(encoder, shader_module)
	put_string(encoder, entry_point)
	put_pointer(encoder, false) // pSpecializationInfo
}

// encode_create_graphics_pipelines writes vkCreateGraphicsPipelines with
// one create info and no pipeline cache.
encode_create_graphics_pipelines :: proc "contextless" (encoder: ^Encoder, device, pipeline: Object_Id, description: Graphics_Pipeline_Description, flags := REPLY) -> Venus_Problem {
	if device == 0 || pipeline == 0 {
		return .Zero_Object_Id
	}
	pipeline_description_check(description) or_return
	mark := command_begin(encoder, .Create_Graphics_Pipelines, flags) or_return
	put_object(encoder, device)
	put_object(encoder, 0) // pipelineCache
	put_u32(encoder, 1) // createInfoCount
	put_array_size(encoder, 1)
	put_structure(encoder, .Graphics_Pipeline_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 2) // stageCount
	put_array_size(encoder, 2)
	put_shader_stage(encoder, .Vertex, description.vertex_shader, description.entry_point)
	put_shader_stage(encoder, .Fragment, description.fragment_shader, description.entry_point)

	put_pointer(encoder, true) // pVertexInputState
	put_structure(encoder, .Pipeline_Vertex_Input_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 1) // vertexBindingDescriptionCount
	put_array_size(encoder, 1)
	put_u32(encoder, 0) // binding
	put_u32(encoder, description.vertex_stride)
	put_i32(encoder, i32(Vertex_Input_Rate.Vertex))
	put_u32(encoder, u32(len(description.vertex_attributes)))
	put_array_size(encoder, u64(len(description.vertex_attributes)))
	for attribute in description.vertex_attributes {
		put_u32(encoder, attribute.location)
		put_u32(encoder, 0) // binding
		put_i32(encoder, i32(attribute.format))
		put_u32(encoder, attribute.offset)
	}

	put_pointer(encoder, true) // pInputAssemblyState
	put_structure(encoder, .Pipeline_Input_Assembly_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_i32(encoder, i32(description.topology))
	put_u32(encoder, 0) // primitiveRestartEnable

	put_pointer(encoder, false) // pTessellationState

	put_pointer(encoder, true) // pViewportState
	put_structure(encoder, .Pipeline_Viewport_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 1) // viewportCount
	put_array_size(encoder, 0) // pViewports: dynamic state
	put_u32(encoder, 1) // scissorCount
	put_array_size(encoder, 0) // pScissors: dynamic state

	put_pointer(encoder, true) // pRasterizationState
	put_structure(encoder, .Pipeline_Rasterization_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 0) // depthClampEnable
	put_u32(encoder, 0) // rasterizerDiscardEnable
	put_i32(encoder, i32(Polygon_Mode.Fill))
	put_u32(encoder, 0) // cullMode: a 2D quad of the translator has either winding
	put_i32(encoder, i32(Front_Face.Counter_Clockwise))
	put_u32(encoder, 0) // depthBiasEnable
	put_f32(encoder, 0) // depthBiasConstantFactor
	put_f32(encoder, 0) // depthBiasClamp
	put_f32(encoder, 0) // depthBiasSlopeFactor
	put_f32(encoder, 1) // lineWidth

	put_pointer(encoder, true) // pMultisampleState
	put_structure(encoder, .Pipeline_Multisample_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, u32(Sample_Count.One))
	put_u32(encoder, 0) // sampleShadingEnable
	put_f32(encoder, 0) // minSampleShading
	put_array_size(encoder, 0) // pSampleMask
	put_u32(encoder, 0) // alphaToCoverageEnable
	put_u32(encoder, 0) // alphaToOneEnable

	put_pointer(encoder, false) // pDepthStencilState

	blend := description.blend
	put_pointer(encoder, true) // pColorBlendState
	put_structure(encoder, .Pipeline_Color_Blend_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 0) // logicOpEnable
	put_i32(encoder, i32(Logic_Op.Clear))
	put_u32(encoder, 1) // attachmentCount
	put_array_size(encoder, 1)
	put_u32(encoder, blend.enabled ? 1 : 0)
	put_i32(encoder, i32(blend.source_color_factor))
	put_i32(encoder, i32(blend.destination_color_factor))
	put_i32(encoder, i32(blend.color_operation))
	put_i32(encoder, i32(blend.source_alpha_factor))
	put_i32(encoder, i32(blend.destination_alpha_factor))
	put_i32(encoder, i32(blend.alpha_operation))
	put_u32(encoder, transmute(u32)Color_Components{.Red, .Green, .Blue, .Alpha})
	put_array_size(encoder, 4) // blendConstants
	for _ in 0 ..< 4 {
		put_f32(encoder, 0)
	}

	put_pointer(encoder, true) // pDynamicState
	put_structure(encoder, .Pipeline_Dynamic_State_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 2) // dynamicStateCount
	put_array_size(encoder, 2)
	put_i32(encoder, i32(Dynamic_State.Viewport))
	put_i32(encoder, i32(Dynamic_State.Scissor))

	put_object(encoder, description.layout)
	put_object(encoder, description.render_pass)
	put_u32(encoder, 0) // subpass
	put_object(encoder, 0) // basePipelineHandle
	put_i32(encoder, -1) // basePipelineIndex
	put_pointer(encoder, false) // pAllocator
	put_array_size(encoder, 1) // pPipelines
	put_object(encoder, pipeline)
	return command_end(encoder, mark)
}
