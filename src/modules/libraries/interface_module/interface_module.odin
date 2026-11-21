// The interface package as a module (docs/INTERFACE.md, section 7; the
// test of the claim "the functions are written so the package can become a
// module later with the same calls"). Each export calls one function of
// src/library/modus/interface over two tables in memory of the caller: the draw
// table (Table of Draw_Record, Append) and the text table (Bytes, Append).
// The module holds no state of the process: a frame of the package is made
// over the two tables for the time of one call.
//
// **What it is for.** It checks a claim of the interface package by doing
// it: the same functions, called through the call form, give the same draw
// records as a call of the package in the process. The process
// `interface_through_module` loads it, draws its window through it, and
// compares the records and the time of each way.
//
// **The rule of the results** of each export that appends: the result is
// the count of draw records of the whole answer. A result larger than the
// capacity of the table says that the answer did not fit, and the caller
// gives a larger table. The result is -1 with an error record for a table
// over 2^40 records or bytes, or for one element over 64 records or 4096
// bytes of text.
//
// **What it does not hold**: the damage of a frame and the draw of its
// records into pixels. They are the two exports of the drawing module
// (`src/modules/libraries/drawing`), which each module with a window imports. This
// module keeps the elements only: it shows what one element call through a
// border costs, and why the elements stay compiled into each module.
package interface_module

import "base:intrinsics"
import "modus:contract/accessibility"
import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// A rectangle of the surface: the place of an element.
Area :: struct {
	x:      i64,
	y:      i64,
	width:  i64,
	height: i64,
}

// A line with a name and a value.
Label_Value :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	value_x: i64, // 0: the value at the right of the area.
	color:   i64, // The color of the value.
}

// A value against a maximum, in a color.
Bar_Value :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	value:   i64,
	maximum: i64,
	color:   i64,
}

Draw_Records_To_Append :: system.Table_To_Append(draw_record.Draw_Record)

// The records and the text bytes that one element call can make: the
// element is built into an element frame of these sizes, then appended to
// the tables of the caller. An element larger than this is refused with -1
// and an error record Full.
ELEMENT_RECORD_CAPACITY :: 64
ELEMENT_TEXT_CAPACITY :: 4096

// One element call: a frame of the package over a draw table and a text
// table of its own, on the stack of the export. The tables of the caller
// are never the table of the package: the count of an Append table is the
// count of the full answer across calls (docs/MODULE_CONTRACT.md, "Did not
// fit, across calls"), which the package does not count; the module counts
// it when it appends. A count over the capacity on entry is not a mark of
// the module: such a mark works in a direct call only, and the contract
// refuses it.
@(private)
Element_Frame :: struct {
	records: [ELEMENT_RECORD_CAPACITY]draw_record.Draw_Record,
	text:    [ELEMENT_TEXT_CAPACITY]u8,
	table:   interface.Draw_Table,
	frame:   interface.Frame,
}

// The interface state and the input of each frame: empty. The elements of
// this module take no input and never write them, so the module keeps no
// state of a process in them; one empty record serves each call, with no
// zero bytes to write at each call.
@(private)
no_state: interface.Interface_State
@(private)
no_input: interface.Input

// The interface font of the process that runs the module, found once: in
// a direct call the caller, whose starter maps the font outlines at their
// fixed range; in an isolated call the call host, which has none, so its
// elements draw in the font of the cells. The state: 0 not looked at yet,
// 1 given, 2 none. Two threads that look at once open the same outlines
// and write the same values.
@(private)
module_interface_font: display.Interface_Font
@(private)
module_interface_font_state: u32

// A context with no bit set: what a host test reads, as it has no
// context of a process.
@(private)
no_context: system.Context

@(private)
interface_font_of_process :: proc "contextless" () -> ^display.Interface_Font {
	state := intrinsics.atomic_load_explicit(&module_interface_font_state, .Acquire)
	if state == 0 {
		context_record := &no_context
		when ODIN_OS == .Freestanding {
			context_record = system.context_record()
		}
		// The places of a text in the interface font come from its font
		// files: this copy of the text rendering opens the outlines that
		// the starter of the process mapped.
		state = 2
		if outlines_problem, _ := display.fallback_load(context_record); outlines_problem.kind == .None && display.interface_faces_opened() {
			module_interface_font = display.INTERFACE_FONT
			state = 1
		}
		intrinsics.atomic_store_explicit(&module_interface_font_state, state, .Release)
	}
	return state == 1 ? &module_interface_font : nil
}

// The most records or bytes of a table of a caller, its count included: no
// count times a size wraps, and a count holds in the i64 of the result.
@(private)
TABLE_LIMIT :: u64(1) << 40

// The result of an export that fails: the error record says why.
@(private)
ERROR :: -1

// The arguments of each draw export that the error record names: the draw
// table is the first parameter, and the text table, when the export takes
// one, the second.
@(private)
ARGUMENT_DRAWN :: 1
@(private)
ARGUMENT_TEXT :: 2

// element_frame_begin starts one element call. It gives false for a table
// over TABLE_LIMIT (a capacity of 2^63 is a negative int), and writes the
// error record: Too_Long of the table, with the larger of its count and its
// capacity.
@(private)
element_frame_begin :: proc "contextless" (element: ^Element_Frame, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> bool {
	if drawn.capacity > TABLE_LIMIT || drawn.count > TABLE_LIMIT {
		errors.fail(error, ERROR, .Too_Long, .Records, ARGUMENT_DRAWN, value_of_size(max(drawn.capacity, drawn.count)), i64(TABLE_LIMIT))
		return false
	}
	if text != nil && (text.capacity > TABLE_LIMIT || text.count > TABLE_LIMIT) {
		errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_TEXT, value_of_size(max(text.capacity, text.count)), i64(TABLE_LIMIT))
		return false
	}
	element.table = {records = element.records[:], text = element.text[:], interface_font = interface_font_of_process()}
	element.frame = {table = &element.table, state = &no_state, input = &no_input}
	return true
}

// value_of_size gives a size of a caller as a value of an error record: a
// size past the largest i64 is that largest value, not a negative number.
@(private)
value_of_size :: proc "contextless" (size: u64) -> i64 {
	return i64(min(size, u64(max(i64))))
}

// element_frame_append_to_caller appends the records and the text of one
// element to the tables of the caller, by the Append rule: what fits is
// written, the count grows by all of it, and nothing is written at or after
// a capacity. A text record names its bytes at the count of the text table
// on entry: when they did not fit, the record names bytes past the text
// table, and the readers of a draw table check each range. The result is
// the count of draw records of the full answer, or -1 with an error record:
// Full for an element larger than the element frame, Out_Of_Range for a
// text table past 2^32 bytes (the first byte of a range is a u32).
@(private)
element_frame_append_to_caller :: proc "contextless" (element: ^Element_Frame, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	if element.table.full {
		if element.table.record_count >= ELEMENT_RECORD_CAPACITY {
			return errors.fail(error, ERROR, .Full, .Records, 0, 0, ELEMENT_RECORD_CAPACITY)
		}
		return errors.fail(error, ERROR, .Full, .Bytes, 0, 0, ELEMENT_TEXT_CAPACITY)
	}
	text_base := text != nil ? text.count : 0
	pad := u64(0)
	if text != nil {
		// Align the appended byte block to 4 bytes when any Element_Push carries
		// 16-byte detail records so detail_first stays a multiple of 4.
		for record in element.records[:element.table.record_count] {
			if primitive, problem := draw_record.read(record); problem == .None {
				if push, is_push := primitive.(draw_record.Draw_Element_Push); is_push && push.detail_count > 0 {
					pad = (4 - (text_base & 3)) & 3
					break
				}
			}
		}
	}
	shifted_base := text_base + pad
	if shifted_base + u64(element.table.text_count) > u64(max(u32)) {
		return errors.fail(error, ERROR, .Out_Of_Range, .Bytes, ARGUMENT_TEXT, value_of_size(shifted_base + u64(element.table.text_count)), i64(max(u32)))
	}
	for record in element.records[:element.table.record_count] {
		// The element frame wrote each record: the border reads it, and a
		// record that names a range of the text table names it again after
		// the text of the caller.
		placed := record
		if primitive, problem := draw_record.read(record); problem == .None {
			if first, _, has_range := draw_record.byte_range_of(primitive); has_range {
				placed = draw_record.record_of(draw_record.with_byte_place(primitive, first + u32(shifted_base)), record.element, record.left, record.top, record.right, record.bottom)
			} else if push, is_push := primitive.(draw_record.Draw_Element_Push); is_push {
				moved := push
				if moved.name_count > 0 {
					moved.name_first += u32(shifted_base)
				}
				if moved.detail_count > 0 {
					if u64(moved.detail_first) + u64(moved.detail_count) * accessibility.ELEMENT_DETAIL_RECORD_SIZE <= u64(element.table.text_count) {
						details := ([^]accessibility.Element_Detail_Record)(&element.text[moved.detail_first])[:moved.detail_count]
						for &d in details {
							if dk, dk_ok := accessibility.element_detail_kind_of_word(d.kind); dk_ok && accessibility.element_detail_kind_is_text_range(dk) && d.value_high > 0 {
								d.value_low += u32(shifted_base)
							}
						}
					}
					moved.detail_first += u32(shifted_base)
				}
				placed = draw_record.record_of(moved, record.element, record.left, record.top, record.right, record.bottom)
			}
		}
		system.table_append(drawn, placed)
	}
	if text != nil {
		if pad > 0 {
			zeros: [4]u8
			system.bytes_append(text, zeros[:pad])
		}
		system.bytes_append(text, element.text[:element.table.text_count])
	}
	return i64(min(drawn.count, u64(max(i64))))
}

@(private)
area_of :: proc "contextless" (area: Area) -> interface.Area {
	return {int(area.x), int(area.y), int(area.width), int(area.height)}
}

// draw_background appends the background of the rules on an area: one color and the grid of points. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_background")
draw_background :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), area: ^Area, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil, error) {
		return ERROR
	}
	interface.background(&element.frame, area_of(area^))
	return element_frame_append_to_caller(&element, drawn, nil, error)
}

// draw_card appends the frame of one subject: its border, its surface, its title in the accent and its caption. It writes the area of its content in the one row of `area`. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_card")
draw_card :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), text: ^system.Bytes_To_Append, area: ^system.Table_To_Change(Area), title: ^string, caption: ^string, accent: i64, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text, error) {
		return ERROR
	}
	if area.count == 1 {
		// One copy of the record: the rule of an export (docs/MODULE_CONTRACT.md).
		content := interface.card(&element.frame, area_of(intrinsics.volatile_load(&area.records[0])), title^, caption^, graphics.Color(accent))
		area.records[0] = {i64(content.x), i64(content.y), i64(content.width), i64(content.height)}
	}
	return element_frame_append_to_caller(&element, drawn, text, error)
}

// draw_cell_text appends a text in a cell of a line, at the left, or at the right when `right` is not 0. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_cell_text")
draw_cell_text :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), text: ^system.Bytes_To_Append, cell: ^Area, words: ^string, color: i64, right: i64, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text, error) {
		return ERROR
	}
	interface.cell_text(&element.frame, area_of(cell^), words^, graphics.Color(color), right != 0 ? .Right : .Left)
	return element_frame_append_to_caller(&element, drawn, text, error)
}

// draw_label_value_line appends a name in the dim color and its value. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_label_value_line")
draw_label_value_line :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), text: ^system.Bytes_To_Append, line: ^Label_Value, label: ^string, value: ^string, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text, error) {
		return ERROR
	}
	interface.label_value_line(&element.frame, {int(line.x), int(line.y), int(line.width), int(line.height)}, label^, value^, graphics.Color(line.color), int(line.value_x))
	return element_frame_append_to_caller(&element, drawn, text, error)
}

// draw_table_band appends the band under line `index` of a table: every second line has the surface of a card. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_table_band")
draw_table_band :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), area: ^Area, index: i64, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil, error) {
		return ERROR
	}
	interface.table_band(&element.frame, area_of(area^), int(index))
	return element_frame_append_to_caller(&element, drawn, nil, error)
}

// draw_bar appends a value against a maximum: the track and the full part. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 with an error record: Too_Long for a table over 2^40 records or bytes, Full for an element over 64 records or 4096 bytes of text, Out_Of_Range for a text table past 2^32 bytes.
@(export, link_name = "draw_bar")
draw_bar :: proc "c" (drawn: ^system.Table_To_Append(draw_record.Draw_Record), bar: ^Bar_Value, error: ^errors.Error_Record) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil, error) {
		return ERROR
	}
	interface.bar(&element.frame, {int(bar.x), int(bar.y), int(bar.width), int(bar.height)}, u64(max(bar.value, 0)), u64(max(bar.maximum, 0)), graphics.Color(bar.color))
	return element_frame_append_to_caller(&element, drawn, nil, error)
}
