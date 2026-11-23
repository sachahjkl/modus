package machine

import "core:strings"
import "modus:contract/virtio_input"

// The absolute pointer of a test machine with the virtio tablet
// (tablet_scenario.odin). QEMU reports a place on each axis in 0 to
// TABLET_AXIS_MAXIMUM; the input service scales it to its own extent, and
// the compositor scales that to the logical screen. The tool gives the
// report whose two scalings land on the logical pixel that a step names.

// The largest place of an axis of the tablet of QEMU (INPUT_EVENT_ABS_MAX).
TABLET_AXIS_MAXIMUM :: 0x7FFF
// The extent of the axes of the records of the input service: one more
// than the largest place (src/modules/system/input, TABLET_COORDINATE_EXTENT).
TABLET_RECORD_EXTENT :: u32(virtio_input.ABSOLUTE_AXIS_DEFAULT_MAXIMUM) + 1

// tablet_pixel_of_report gives the logical pixel that a report of the
// tablet gives on an axis of a logical extent: the scale of the input
// service, then the scale of the compositor.
tablet_pixel_of_report :: proc(report: int, logical_extent: int) -> (pixel: int, ok: bool) {
	if report < 0 || report > TABLET_AXIS_MAXIMUM || logical_extent <= 0 || logical_extent > TABLET_AXIS_MAXIMUM {
		return 0, false
	}
	axis := virtio_input.Axis_Range{0, TABLET_AXIS_MAXIMUM}
	in_record, problem := virtio_input.scale_axis_coordinate(i32(report), axis, TABLET_RECORD_EXTENT)
	if problem != .None {
		return 0, false
	}
	on_screen, screen_problem := virtio_input.scale_axis_coordinate(i32(in_record), {0, i32(TABLET_RECORD_EXTENT - 1)}, u32(logical_extent))
	if screen_problem != .None {
		return 0, false
	}
	return int(on_screen), true
}

// tablet_report_of_pixel gives the smallest report of the tablet that lands
// on a logical pixel of an axis. A pixel outside the extent gives none.
// The two scalings never go down as the report grows, so a search by
// halves finds it.
tablet_report_of_pixel :: proc(pixel: int, logical_extent: int) -> (report: int, ok: bool) {
	if pixel < 0 || pixel >= logical_extent || logical_extent > TABLET_AXIS_MAXIMUM {
		return 0, false
	}
	low, high := 0, TABLET_AXIS_MAXIMUM
	for low < high {
		middle := low + (high - low) / 2
		landed := tablet_pixel_of_report(middle, logical_extent) or_return
		if landed < pixel {
			low = middle + 1
		} else {
			high = middle
		}
	}
	landed := tablet_pixel_of_report(low, logical_extent) or_return
	return low, landed == pixel
}

// tablet_act_words gives the act of a step of the tablet, for its line.
tablet_act_words :: proc(kind: Step_Kind) -> string {
	if kind == .Press_Absolute {
		return "pressed and held"
	} else if kind == .Move_Absolute {
		return "moved with the button down"
	} else if kind == .Release_Absolute {
		return "released"
	}
	return "pressed and released"
}

// qmp_tablet_click_command gives the command that reports an absolute
// place and the left button in one report of the tablet: the input service
// commits them together, so the press is at the new place.
qmp_tablet_click_command :: proc(report_x, report_y: int, down: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":")
	strings.write_int(&builder, report_x)
	strings.write_string(&builder, "}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":")
	strings.write_int(&builder, report_y)
	strings.write_string(&builder, "}},{\"type\":\"btn\",\"data\":{\"down\":")
	strings.write_string(&builder, down ? "true" : "false")
	strings.write_string(&builder, ",\"button\":\"left\"}}]}}")
	return strings.to_string(builder)
}
