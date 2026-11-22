#+build !freestanding
package display

import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:contract/scale_factor"
import "core:testing"

// The window ring of the display contract carries each event of Event_Kind
// but None: the count of the contract follows the enum, so a new event
// changes the hash of the contract.
@(test)
the_window_ring_of_the_contract_counts_each_event :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(len(Event_Kind) - 1), role_contract.DISPLAY_WINDOW_EVENT_COUNT)
	testing.expect_value(t, u32(max(Event_Kind)), role_contract.DISPLAY_WINDOW_EVENT_COUNT)
}

// The border of a Work_Area, refusals first: a width or a height of 0, one
// past WORK_AREA_LIMIT, and the largest word. Each refusal gives the zero
// event. The bounds 1 and WORK_AREA_LIMIT are taken last.
@(test)
a_work_area_out_of_its_range_is_refused :: proc(t: ^testing.T) {
	refused := [?][2]u64{{0, 700}, {1000, 0}, {0, 0}, {WORK_AREA_LIMIT + 1, 700}, {1000, WORK_AREA_LIMIT + 1}, {max(u64), 700}, {1000, max(u64)}}
	for size in refused {
		record := ring.Record{kind = u32(Event_Kind.Work_Area)}
		record.values[0], record.values[1] = size[0], size[1]
		event, ok := event_of_record(record)
		testing.expectf(t, !ok, "the work area %v is taken", size)
		testing.expect_value(t, event, Event{})
	}
	for size in ([2][2]u64{{1, 1}, {WORK_AREA_LIMIT, WORK_AREA_LIMIT}}) {
		record := ring.Record{kind = u32(Event_Kind.Work_Area)}
		record.values[0], record.values[1] = size[0], size[1]
		event, ok := event_of_record(record)
		testing.expectf(t, ok, "the work area %v is refused", size)
		testing.expect_value(t, event.kind, Event_Kind.Work_Area)
		testing.expect_value(t, event.width, int(size[0]))
		testing.expect_value(t, event.height, int(size[1]))
	}
}

// A holder of the display of the test: it names no module and draws a band
// of lines_kept lines of its own. It speaks the window ring of the contract
// only.
@(private = "file")
Holder_Of_Test :: struct {
	lines_kept: i64,
}

// holder_takes_window is what each holder sends when it takes the surface
// of a window: the work area at the scale in force.
@(private = "file")
holder_takes_window :: proc(holder: Holder_Of_Test, completions: ^ring.Queue, scale: scale_factor.Scale) -> bool {
	width, height := scale_factor.logical_screen(scale)
	return ring.push(completions, ring.Record{kind = u32(Event_Kind.Work_Area), values = {0 = u64(width), 1 = u64(height - holder.lines_kept)}})
}

// The client side of the contract reads one event of the window ring, as
// next_event does with no kernel: the border, then the work area.
@(private = "file")
client_reads_work_area :: proc(t: ^testing.T, window: ^Window) -> (event: Event, first: bool) {
	record, has := ring.pop(&window.ring.completions)
	testing.expect(t, has)
	read, ok := event_of_record(record)
	testing.expect(t, ok)
	testing.expect_value(t, read.kind, Event_Kind.Work_Area)
	return read, work_area_take(window, read.width, read.height)
}

// Two holders of the role Display: one with no bar, and one that keeps the
// most lines that the contract lets a holder keep. The client library does
// the same with each: the first Work_Area is the take of the window, a
// later one changes the area and is no take, and the area holds the least
// work area at each scale up to the window bound. A holder that keeps one
// line more than the contract allows gives less than the least work area.
@(test)
a_window_takes_its_work_area_from_any_holder_of_the_display :: proc(t: ^testing.T) {
	holders := [2]Holder_Of_Test{{lines_kept = 0}, {lines_kept = scale_factor.HOLDER_LINES_MOST}}
	for holder in holders {
		ring_memory := make([]u8, ring.PAGE_COUNT * ring.PAGE_SIZE)
		defer delete(ring_memory)
		window: Window
		opened, opened_ok := ring.open(raw_data(ring_memory), ring.PAGE_COUNT)
		testing.expect(t, opened_ok)
		window.ring = opened
		_, _, named_before := work_area(&window)
		testing.expect(t, !named_before, "a window names a work area before its holder sent one")

		testing.expect(t, holder_takes_window(holder, &window.ring.completions, scale_factor.WINDOW_BOUND))
		event, first := client_reads_work_area(t, &window)
		testing.expectf(t, first, "the holder that keeps %d lines: its first work area is no take", holder.lines_kept)
		width, height, named := work_area(&window)
		testing.expect(t, named)
		testing.expect_value(t, width, event.width)
		testing.expect_value(t, height, event.height)
		testing.expectf(t, height >= scale_factor.WORK_AREA_LEAST_HEIGHT, "the holder that keeps %d lines gives %d lines", holder.lines_kept, height)

		for scale in scale_factor.Scale {
			if u8(scale) > u8(scale_factor.WINDOW_BOUND) {
				continue
			}
			testing.expect(t, holder_takes_window(holder, &window.ring.completions, scale))
			again, again_first := client_reads_work_area(t, &window)
			testing.expect(t, !again_first, "a later work area is a second take")
			testing.expect(t, again.height >= scale_factor.WORK_AREA_LEAST_HEIGHT)
			_, kept_height, _ := work_area(&window)
			testing.expect_value(t, kept_height, again.height)
		}
	}
	past := Holder_Of_Test{lines_kept = scale_factor.HOLDER_LINES_MOST + 1}
	_, bound_height := scale_factor.logical_screen(scale_factor.WINDOW_BOUND)
	testing.expect(t, bound_height - past.lines_kept < scale_factor.WORK_AREA_LEAST_HEIGHT)
}
