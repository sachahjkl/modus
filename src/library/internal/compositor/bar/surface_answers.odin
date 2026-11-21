package bar

// The decisions of the compositor that keep a window from a state with no
// way out (src/md/features/window_resize.md, "The rescale: one state
// machine on each side"), as pure procedures with host tests: the end of a
// drag at a release, the request at the end of a drag, the answer that a
// full ring of the window does not take, and the background that a surface
// leaves in its window.

import "modus:contract/ring"

// drag_ended_by_release says if the release of the surface of a window
// ends the drag of the principal in progress: the drag of that window. The
// drag ends with no request, since the window holds no surface that a
// resize could replace; the principal drags again after the rescale. -1 is
// no drag.
drag_ended_by_release :: proc "contextless" (dragged_window, released_window: int) -> bool {
	return dragged_window >= 0 && dragged_window == released_window
}

// drag_asks_size says if the release of the button at the end of a drag
// sends Resized: only to a window that shows its surface with no surface
// pending, and for another size. A window between two surfaces would
// refuse the answer that it cannot give, and stay there.
drag_asks_size :: proc "contextless" (surface_released, surface_pending, same_size: bool) -> bool {
	return !surface_released && !surface_pending && !same_size
}

// Answer_Slot: the one answer of a surface request (Surface_Answer) that
// the ring and the queue of a window refused. A window has one request at a
// time, so one slot is enough: the answer never goes lost, and the window
// never waits for an answer that the compositor dropped.
Answer_Slot :: struct {
	due:    bool,
	record: ring.Record,
}

// answer_slot_keep keeps a refused answer. A slot that holds an answer
// keeps it, and the new one is refused (false): nothing replaces an answer
// due, and a second one can come only from a window that broke the rule of
// one request at a time.
answer_slot_keep :: proc "contextless" (slot: ^Answer_Slot, record: ring.Record) -> bool {
	if slot.due {
		return false
	}
	slot^ = {due = true, record = record}
	return true
}

// answer_slot_send gives the answer due when the ring of the window has
// room, and empties the slot; the compositor sends it before the queue.
answer_slot_send :: proc "contextless" (slot: ^Answer_Slot, ring_has_room: bool) -> (record: ring.Record, send: bool) {
	if !slot.due || !ring_has_room {
		return {}, false
	}
	record = slot.record
	slot^ = {}
	return record, true
}

// background_strips gives the two strips of the interior that a surface
// leaves and that the frame does not cover: at the right of the surface
// and under it. inner is the part of the interior that no part of the
// frame covers. The compositor fills only these with the background, so no
// pixel is written twice; a surface of the scale in force leaves at most
// one pixel, which the frame covers, and the strips are empty.
background_strips :: proc "contextless" (surface, inner: Screen_Box) -> [2]Screen_Box {
	right := Screen_Box{max(surface.right, inner.left), inner.top, inner.right, inner.bottom}
	bottom := Screen_Box{inner.left, max(surface.bottom, inner.top), min(surface.right, inner.right), inner.bottom}
	strips := [2]Screen_Box{right, bottom}
	for &strip in strips {
		if strip.right <= strip.left || strip.bottom <= strip.top {
			strip = {}
		}
	}
	return strips
}

// frame_inner gives the part of the screen of the interior of a window
// that no part of its frame covers, from the boxes of the parts on the
// screen (frame_parts): title, bottom, left, right.
frame_inner :: proc "contextless" (parts: [4]Screen_Box) -> Screen_Box {
	return {parts[2].right, parts[0].bottom, parts[3].left, parts[1].top}
}
