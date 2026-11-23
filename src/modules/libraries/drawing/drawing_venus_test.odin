#+build !freestanding
package drawing

import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/venus_vulkan"
import "modus:contract/webgpu_subset"
import "modus:system"

// The GPU back end of the module: draw_table_to_venus_20 writes the Venus
// stream of a frame, refuses each word of its target that names nothing,
// and writes no byte of its output when it refuses.

@(private = "file")
TARGET :: Venus_Target {
	width               = 64,
	height              = 48,
	format              = 37,
	start               = 0,
	clear_color         = 0xFF20_4080,
	command_buffer      = 100,
	queue               = 200,
	fence               = 300,
	pipeline_layout     = 400,
	render_pass_base    = 1000,
	framebuffer_base    = 2000,
	buffer_base         = 3000,
	image_base          = 4000,
	pipeline_base       = 5000,
	vertex_buffer_bytes = 32768,
	index_buffer_bytes  = 8192,
}

@(private = "file")
Venus_Call :: struct {
	records: []draw_record.Draw_Record,
	text:    []u8,
	scratch: []u8,
	venus:   []u8,
	target:  Venus_Target,
}

@(private = "file")
call :: proc(arguments: Venus_Call) -> (result: i64, refused: errors.Error_Record, outcome: call_outcome.Call_Outcome) {
	now := system.Table_To_Read(draw_record.Draw_Record){records = raw_data(arguments.records), count = u64(len(arguments.records)), capacity = u64(len(arguments.records))}
	text := system.Bytes_To_Read{bytes = raw_data(arguments.text), count = u64(len(arguments.text)), capacity = u64(len(arguments.text))}
	scratch := system.Bytes_To_Change{bytes = raw_data(arguments.scratch), count = u64(len(arguments.scratch)), capacity = u64(len(arguments.scratch))}
	venus := system.Bytes_To_Change{bytes = raw_data(arguments.venus), count = u64(len(arguments.venus)), capacity = u64(len(arguments.venus))}
	target := arguments.target
	outcome, result = draw_table_to_venus_20(&now, &text, &scratch, &venus, &target, &refused)
	return
}

@(private = "file")
pixel_rectangle :: proc(color: u32, left, top, right, bottom: int) -> draw_record.Draw_Record {
	return draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.Draw_Color(color)}, 0, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

@(private = "file")
fill_venus :: proc(bytes: []u8) {
	for &byte_value in bytes {
		byte_value = 0xAA
	}
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, arguments: Venus_Call, kind: errors.Kind, unit: errors.Unit, argument: i64, value: i64, loc := #caller_location) {
	fill_venus(arguments.venus)
	result, refused, outcome := call(arguments)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused, loc = loc)
	testing.expect_value(t, result, 0, loc = loc)
	testing.expect_value(t, refused.kind, i64(kind), loc = loc)
	testing.expect_value(t, refused.unit, i64(unit), loc = loc)
	testing.expect_value(t, refused.argument, argument, loc = loc)
	testing.expect_value(t, refused.value, value, loc = loc)
	for byte_value in arguments.venus {
		if byte_value != 0xAA {
			testing.expect(t, false, "a refused call must not write venus", loc = loc)
			return
		}
	}
}

@(private = "file")
command_types :: proc(t: ^testing.T, bytes: []u8, types: []venus_vulkan.Command_Type) -> int {
	decoder := venus_vulkan.decoder_init(bytes)
	count := 0
	for decoder.cursor < len(bytes) && count < len(types) {
		command, problem := venus_vulkan.command_decode_next(&decoder)
		testing.expect_value(t, problem, venus_vulkan.Venus_Problem.None)
		if problem != .None {
			break
		}
		types[count] = command.command_type
		count += 1
	}
	testing.expect(t, venus_vulkan.decoder_done(&decoder), "the stream must hold whole commands only")
	return count
}

@(test)
draw_table_to_venus_writes_the_frame :: proc(t: ^testing.T) {
	scratch: [16384]u8
	venus: [16384]u8
	// An empty table clears the image and reads it back.
	written, refused, outcome := call({scratch = scratch[:], venus = venus[:], target = TARGET})
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, refused.kind, i64(errors.Kind.None))
	testing.expect(t, written > 0)
	types: [64]venus_vulkan.Command_Type
	count := command_types(t, venus[:written], types[:])
	expected := [?]venus_vulkan.Command_Type {
		.Begin_Command_Buffer, .Cmd_Pipeline_Barrier, .Cmd_Set_Viewport, .Cmd_Push_Constants, .Cmd_Begin_Render_Pass,
		.Cmd_End_Render_Pass, .Cmd_Pipeline_Barrier, .Cmd_Copy_Image_To_Buffer, .Cmd_Pipeline_Barrier,
		.End_Command_Buffer, .Queue_Submit,
	}
	testing.expect_value(t, count, len(expected))
	for want, index in expected {
		testing.expect_value(t, types[index], want)
	}

	// Two rectangles, one with alpha, and a clip: the vertices are uploaded
	// and each clip draws under its scissor.
	records := [?]draw_record.Draw_Record {
		pixel_rectangle(0xFF10_2030, 0, 0, 64, 48),
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8), draw_record.units_of_pixels(24), draw_record.units_of_pixels(24)),
		pixel_rectangle(0x80FF_0000, 0, 0, 64, 48),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
	}
	written, refused, outcome = call({records = records[:], scratch = scratch[:], venus = venus[:], target = TARGET})
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, refused.kind, i64(errors.Kind.None))
	count = command_types(t, venus[:written], types[:])
	updates, scissors, draws := 0, 0, 0
	for command_type in types[:count] {
		#partial switch command_type {
		case .Cmd_Update_Buffer:
			updates += 1
		case .Cmd_Set_Scissor:
			scissors += 1
		case .Cmd_Draw_Indexed:
			draws += 1
		}
	}
	testing.expect_value(t, updates, 2)
	testing.expect_value(t, scissors, 2)
	testing.expect_value(t, draws, 2)
	stream_count, stream_problem := venus_vulkan.stream_validate(venus[:written])
	testing.expect_value(t, stream_problem, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, stream_count, count)

	// A frame that keeps the last contents is accepted too, in BGRA.
	kept := TARGET
	kept.start = 1
	kept.format = 44
	written, refused, outcome = call({records = records[:], scratch = scratch[:], venus = venus[:], target = kept})
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, refused.kind, i64(errors.Kind.None))
	testing.expect(t, written > 0)
}

@(test)
draw_table_to_venus_refuses_each_wrong_target_word :: proc(t: ^testing.T) {
	scratch: [16384]u8
	venus: [8192]u8
	records := [1]draw_record.Draw_Record{pixel_rectangle(0xFFFF_0000, 0, 0, 16, 16)}
	base := Venus_Call{records = records[:], scratch = scratch[:], venus = venus[:], target = TARGET}

	refused_word :: proc(t: ^testing.T, base: Venus_Call, target: Venus_Target, word: i64, loc := #caller_location) {
		arguments := base
		arguments.target = target
		expect_refused(t, arguments, .Bad_Value, .None, ARGUMENT_TARGET, word, loc = loc)
	}
	target := TARGET
	for word in ([?]i64{0, -1, i64(max(u32)) + 1}) {
		target = TARGET
		target.width = word
		refused_word(t, base, target, word)
		target = TARGET
		target.height = word
		refused_word(t, base, target, word)
	}
	for word in ([?]i64{0, -37, 36, 45, 50, 1000001002}) {
		target = TARGET
		target.format = word
		refused_word(t, base, target, word)
	}
	for word in ([?]i64{-1, 2, max(i64)}) {
		target = TARGET
		target.start = word
		refused_word(t, base, target, word)
	}
	for word in ([?]i64{-1, i64(max(u32)) + 1}) {
		target = TARGET
		target.clear_color = word
		refused_word(t, base, target, word)
	}
	target = TARGET
	target.vertex_buffer_bytes = 0
	refused_word(t, base, target, 0)
	target = TARGET
	target.index_buffer_bytes = -5
	refused_word(t, base, target, -5)
	// An object id that names nothing: the value is the problem.
	target = TARGET
	target.command_buffer = 0
	refused_word(t, base, target, i64(venus_vulkan.Venus_Problem.Zero_Object_Id))
	target = TARGET
	target.pipeline_layout = 0
	refused_word(t, base, target, i64(venus_vulkan.Venus_Problem.Zero_Object_Id))
	target = TARGET
	target.image_base = -1
	refused_word(t, base, target, i64(venus_vulkan.Venus_Problem.Object_Id_Overflow))
	// The largest surface that one image holds passes the border of the words.
	target = TARGET
	target.width = venus_vulkan.MAX_IMAGE_DIMENSION + 1
	refused_word(t, base, target, i64(venus_vulkan.Venus_Problem.Dimension_Too_Large))
}

@(test)
draw_table_to_venus_refuses_tables_and_sizes :: proc(t: ^testing.T) {
	scratch: [16384]u8
	venus: [8192]u8
	records := [1]draw_record.Draw_Record{pixel_rectangle(0xFFFF_0000, 0, 0, 16, 16)}
	base := Venus_Call{records = records[:], scratch = scratch[:], venus = venus[:], target = TARGET}

	// A table that the border of the draw table refuses.
	unbalanced := [1]draw_record.Draw_Record{draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, 0, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8))}
	arguments := base
	arguments.records = unbalanced[:]
	expect_refused(t, arguments, .Bad_Value, .Records, ARGUMENT_NOW, i64(webgpu_subset.Draw_Table_Translation_Problem.Unbalanced_Clips_Or_Elements))
	damaged := records
	damaged[0].kind = 200
	arguments.records = damaged[:]
	expect_refused(t, arguments, .Bad_Value, .Records, ARGUMENT_NOW, i64(webgpu_subset.Draw_Table_Translation_Problem.Invalid_Draw_Record))

	// A scratch that does not hold the translation.
	arguments = base
	arguments.scratch = nil
	expect_refused(t, arguments, .Too_Small, .Bytes, ARGUMENT_SCRATCH, 0)
	arguments.scratch = scratch[:256]
	expect_refused(t, arguments, .Too_Small, .Bytes, ARGUMENT_SCRATCH, 256)

	// Buffers of the GPU smaller than the vertices of the frame.
	arguments = base
	arguments.target.vertex_buffer_bytes = 64
	expect_refused(t, arguments, .Too_Small, .Bytes, ARGUMENT_TARGET, 64)

	// An output one word short of the stream, and no output.
	needed, _, needed_outcome := call(base)
	testing.expect(t, needed_outcome == .Succeeded && needed > 4)
	arguments = base
	arguments.venus = venus[:needed - 4]
	expect_refused(t, arguments, .Too_Small, .Bytes, ARGUMENT_VENUS, needed - 4)
	arguments.venus = nil
	expect_refused(t, arguments, .Too_Small, .Bytes, ARGUMENT_VENUS, 0)
	// The exact size is enough.
	arguments.venus = venus[:needed]
	exact, _, exact_outcome := call(arguments)
	testing.expect_value(t, exact_outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, exact, needed)

	// A frame whose stream does not fit in one packet.
	many: [600]draw_record.Draw_Record
	for &record, index in many {
		record = pixel_rectangle(0xFF00_0000 | u32(index), index % 60, index / 60, index % 60 + 2, index / 60 + 2)
	}
	large_scratch := make([]u8, 1 << 18)
	defer delete(large_scratch)
	arguments = base
	arguments.records = many[:]
	arguments.scratch = large_scratch
	arguments.target.vertex_buffer_bytes = 1 << 20
	arguments.target.index_buffer_bytes = 1 << 20
	expect_refused(t, arguments, .Too_Long, .Records, ARGUMENT_NOW, 600)

	// Counts past the limit of a table are refused before any read.
	now := system.Table_To_Read(draw_record.Draw_Record){records = &records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{}
	huge := system.Bytes_To_Change{bytes = &scratch[0], count = TABLE_LIMIT + 1, capacity = TABLE_LIMIT + 1}
	output := system.Bytes_To_Change{bytes = &venus[0], count = len(venus), capacity = len(venus)}
	target := TARGET
	refused: errors.Error_Record
	testing.expect_value(t, answer_of(draw_table_to_venus_20(&now, &text, &huge, &output, &target, &refused)), Answer{.Argument_Refused, 0})
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, ARGUMENT_SCRATCH)
	ordinary := system.Bytes_To_Change{bytes = &scratch[0], count = len(scratch), capacity = len(scratch)}
	testing.expect_value(t, answer_of(draw_table_to_venus_20(&now, &text, &ordinary, &huge, &target, &refused)), Answer{.Argument_Refused, 0})
	testing.expect_value(t, refused.argument, ARGUMENT_VENUS)
	far := system.Table_To_Read(draw_record.Draw_Record){records = &records[0], count = TABLE_LIMIT + 1, capacity = 1}
	testing.expect_value(t, answer_of(draw_table_to_venus_20(&far, &text, &ordinary, &output, &target, &refused)), Answer{.Argument_Refused, 0})
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, ARGUMENT_NOW)
}

@(test)
clear_color_is_in_linear_light :: proc(t: ^testing.T) {
	color := clear_color_of_draw_color(0x80FF_0000)
	testing.expect_value(t, transmute(f32)color.r_bits, f32(1))
	testing.expect_value(t, transmute(f32)color.g_bits, f32(0))
	testing.expect_value(t, transmute(f32)color.a_bits, f32(128) / 255)
	half := clear_color_of_draw_color(0xFF80_8080)
	level := f32(128) / 255
	testing.expect_value(t, transmute(f32)half.b_bits, level * level)
}
