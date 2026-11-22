#+build !freestanding
package screen_reader

import "core:testing"
import "modus:contract/accessibility"
import "modus:contract/draw_record"

// The conformance suite of a reader and of a magnifier: the record output
// of utterances in place of sound, the view in place of pixels
// (src/md/features/accessibility.md, "2. The assistive role"). The trees
// are scripted frames of a fake window.

@(private = "file")
Frame_Builder :: struct {
	records:      [64]draw_record.Draw_Record,
	record_count: int,
	bytes:        [1024]u8 `align(8)`,
	byte_count:   int,
}

@(private = "file")
frame_text :: proc(b: ^Frame_Builder, text: string) -> (first: u32, count: u32) {
	first = u32(b.byte_count)
	copy(b.bytes[b.byte_count:], text)
	b.byte_count += len(text)
	return first, u32(len(text))
}

@(private = "file")
frame_push :: proc(b: ^Frame_Builder, element: u32, role: accessibility.Element_Role, box: [4]int, states: accessibility.Element_States = {}, name := "", live: accessibility.Live_Mode = .Off, toggle: accessibility.Toggle_State = .None) {
	name_first, name_count := u32(0), u32(0)
	if len(name) > 0 {
		name_first, name_count = frame_text(b, name)
	}
	push := draw_record.Draw_Element_Push{role = role, live = live, toggle = toggle, states = states, name_first = name_first, name_count = u16(name_count)}
	b.records[b.record_count] = draw_record.record_of(push, element, draw_record.units_of_pixels(box[0]), draw_record.units_of_pixels(box[1]), draw_record.units_of_pixels(box[2]), draw_record.units_of_pixels(box[3]))
	b.record_count += 1
}

@(private = "file")
frame_run :: proc(b: ^Frame_Builder, element: u32, text: string) {
	first, count := frame_text(b, text)
	run := draw_record.Draw_Text{first = first, count = count, color = draw_record.opaque(0x00FFFFFF), font = .Cells_8x16, weight = .Regular, size = 16 * draw_record.UNITS_PER_PIXEL}
	b.records[b.record_count] = draw_record.record_of(run, element, 0, 0, draw_record.units_of_pixels(8 * max(len(text), 1)), draw_record.units_of_pixels(16))
	b.record_count += 1
}

@(private = "file")
frame_pop :: proc(b: ^Frame_Builder) {
	b.records[b.record_count] = draw_record.record_of(draw_record.Draw_Element_Pop{}, 0, 0, 0, 0, 0)
	b.record_count += 1
}

// One frame of the fake window: a button, a checkbox, a protected field,
// a polite status and an assertive alert; focus names the element with the
// focus.
@(private = "file")
scripted_frame :: proc(b: ^Frame_Builder, tree: ^accessibility.Semantic_Tree, focus: u32, status, alert, secret: string) -> bool {
	b^ = {}
	focused :: proc(element, focus: u32) -> accessibility.Element_States {
		return element == focus ? {.Focusable, .Focused} : {.Focusable}
	}
	frame_push(b, 1, .Button, {10, 10, 90, 34}, focused(1, focus), toggle = .True)
	frame_run(b, 1, "Bold")
	frame_pop(b)
	frame_push(b, 2, .Checkbox, {700, 500, 780, 524}, focused(2, focus), name = "Wrap", toggle = .False)
	frame_pop(b)
	frame_push(b, 3, .Text_Box, {300, 200, 500, 224}, focused(3, focus) + {.Protected}, name = "Passphrase", live = .Polite)
	frame_run(b, 3, secret)
	frame_pop(b)
	frame_push(b, 4, .Status, {0, 560, 200, 584})
	if len(status) > 0 {
		frame_run(b, 4, status)
	}
	frame_pop(b)
	frame_push(b, 5, .Alert, {0, 580, 200, 600})
	if len(alert) > 0 {
		frame_run(b, 5, alert)
	}
	frame_pop(b)
	refusal, _ := accessibility.semantic_tree_extract(b.records[:b.record_count], b.bytes[:b.byte_count], tree)
	return refusal == .None
}

@(private = "file")
queue_texts :: proc(queue: ^Utterance_Queue, texts: []string) -> bool {
	if queue.count != len(texts) {
		return false
	}
	for &entry, index in queue.entries[:queue.count] {
		if utterance_text(&entry) != texts[index] {
			return false
		}
	}
	return true
}

// The queue refuses an empty and a long text and a priority word that names
// nothing; a polite utterance waits; an assertive one stops the one in
// progress; a full queue replaces its oldest polite one, with a count.
@(test)
conformance_utterance_queue_orders_polite_and_assertive :: proc(t: ^testing.T) {
	for word in u64(0) ..= 4 {
		priority, ok := utterance_priority_of_word(word)
		testing.expectf(t, ok == (word == 1 || word == 2) && (!ok || u64(priority) == word), "priority word %d: %v %v", word, priority, ok)
	}
	_, largest_ok := utterance_priority_of_word(max(u64))
	testing.expect(t, !largest_ok, "the largest word names no priority")

	queue: Utterance_Queue
	long: [MAX_ANNOUNCEMENT_BYTES + 1]u8
	for &byte in long {
		byte = 'a'
	}
	_, refusal := utterance_queue_push(&queue, .Queue, 1, nil)
	testing.expect_value(t, refusal, Utterance_Refusal.Empty_Text)
	_, refusal = utterance_queue_push(&queue, .Queue, 1, long[:])
	testing.expect_value(t, refusal, Utterance_Refusal.Too_Long)
	_, refusal = utterance_queue_push(&queue, .Queue, 1, long[:MAX_ANNOUNCEMENT_BYTES])
	testing.expect_value(t, refusal, Utterance_Refusal.None)
	testing.expect(t, utterance_queue_finish(&queue, queue.entries[0].serial), "the bound itself is said")
	testing.expect(t, queue.count == 0 && queue.last_serial == 1, "refusals give no serial")

	first, _ := utterance_queue_push(&queue, .Queue, 4, transmute([]u8)string("one"))
	_, _ = utterance_queue_push(&queue, .Queue, 4, transmute([]u8)string("two"))
	testing.expect(t, queue_texts(&queue, {"one", "two"}), "polite ones wait in order")
	_, _ = utterance_queue_push(&queue, .Interrupt, 5, transmute([]u8)string("alarm"))
	testing.expect(t, queue_texts(&queue, {"alarm", "two"}), "an assertive one stops the one in progress, the waiting one stays")
	testing.expect_value(t, queue.cut, u32(1))

	// Speech that ends the stopped utterance ends nothing.
	testing.expect(t, !utterance_queue_finish(&queue, first), "a stopped serial ends nothing")
	testing.expect(t, !utterance_queue_finish(&queue, 0), "serial 0 ends nothing")
	testing.expect(t, !utterance_queue_finish(&queue, max(u64)), "an unknown serial ends nothing")
	current, ok := utterance_queue_current(&queue)
	testing.expect(t, ok && utterance_text(current) == "alarm", "the alarm is in progress")
	testing.expect(t, utterance_queue_finish(&queue, current.serial), "speech ends the alarm")
	current, ok = utterance_queue_current(&queue)
	testing.expect(t, ok && utterance_text(current) == "two", "then the polite one")
	testing.expect(t, utterance_queue_finish(&queue, current.serial), "speech ends it")
	_, ok = utterance_queue_current(&queue)
	testing.expect(t, !ok, "nothing in progress")

	// Full: a new polite one replaces the oldest polite one that waits, never
	// the one in progress, and counts it.
	queue = {}
	_, _ = utterance_queue_push(&queue, .Queue, 1, transmute([]u8)string("speaking"))
	for index in 1 ..< UTTERANCE_QUEUE_CAPACITY {
		text := [1]u8{u8('0' + index)}
		_, refusal = utterance_queue_push(&queue, .Queue, 1, text[:])
		testing.expect_value(t, refusal, Utterance_Refusal.None)
	}
	_, refusal = utterance_queue_push(&queue, .Queue, 1, transmute([]u8)string("new"))
	testing.expect(t, refusal == .None && queue.replaced == 1, "a full queue replaces its oldest polite one")
	testing.expect(t, queue_texts(&queue, {"speaking", "2", "3", "4", "5", "6", "7", "new"}), "the oldest waiting one went, not the one in progress")

	// An interrupt into a full queue stops the head and never overflows.
	_, refusal = utterance_queue_push(&queue, .Interrupt, 1, transmute([]u8)string("now"))
	testing.expect(t, refusal == .None && queue.count == UTTERANCE_QUEUE_CAPACITY, "an interrupt never overflows the queue")
	testing.expect(t, queue_texts(&queue, {"now", "2", "3", "4", "5", "6", "7", "new"}), "the interrupt took the place of the one in progress")

	// Full of interrupts that wait: a polite one is refused and counted.
	queue = {count = UTTERANCE_QUEUE_CAPACITY, last_serial = UTTERANCE_QUEUE_CAPACITY}
	for &entry, index in queue.entries {
		entry = {serial = u64(index + 1), priority = .Interrupt, length = 1}
		entry.text[0] = 'a'
	}
	before := queue
	_, refusal = utterance_queue_push(&queue, .Queue, 1, transmute([]u8)string("late"))
	testing.expect(t, refusal == .Full && queue.refused == 1, "no polite one to replace: refused and counted")
	testing.expect(t, queue.entries == before.entries && queue.count == before.count, "a refusal changes no utterance")
}

// A reader of the scripted window says the name, the role and the states of
// a new focus at once; a polite status after the utterance in progress; an
// assertive alert at once; nothing of a protected field.
@(test)
conformance_reader_utters_focus_live_regions_and_no_secret :: proc(t: ^testing.T) {
	b := new(Frame_Builder)
	defer free(b)
	before := new(accessibility.Semantic_Tree)
	defer free(before)
	now := new(accessibility.Semantic_Tree)
	defer free(now)
	events: [32]accessibility.Semantic_Event
	queue: Utterance_Queue

	testing.expect(t, scripted_frame(b, before, 1, "Ready", "", "a"), "frame 1")

	// The focus moves to the checkbox, and the status changes.
	testing.expect(t, scripted_frame(b, now, 2, "Saved", "", "ab"), "frame 2")
	written, _ := accessibility.semantic_tree_diff(before, now, events[:])
	testing.expect_value(t, reader_utter_events(&queue, now, events[:written]), 0)
	testing.expectf(t, queue_texts(&queue, {"Wrap, checkbox", "Saved"}), "the focus first, the polite status after it: %v", queue.count)
	testing.expect_value(t, queue.entries[0].priority, Utterance_Priority.Interrupt)
	testing.expect_value(t, queue.entries[1].priority, Utterance_Priority.Queue)

	// The alert stops the focus utterance; the status still waits.
	before^ = now^
	testing.expect(t, scripted_frame(b, now, 2, "Saved", "Disk full", "abc"), "frame 3")
	written, _ = accessibility.semantic_tree_diff(before, now, events[:])
	_ = reader_utter_events(&queue, now, events[:written])
	testing.expect(t, queue_texts(&queue, {"Disk full", "Saved"}), "the assertive alert is said at once")
	testing.expect_value(t, queue.cut, u32(1))

	// The focus moves to the pressed button, then to the protected field:
	// its name, its role and its state, never its text.
	before^ = now^
	testing.expect(t, scripted_frame(b, now, 1, "Saved", "Disk full", "abcd"), "frame 4")
	written, _ = accessibility.semantic_tree_diff(before, now, events[:])
	_ = reader_utter_events(&queue, now, events[:written])
	current, _ := utterance_queue_current(&queue)
	testing.expect_value(t, utterance_text(current), "Bold, button, pressed")
	before^ = now^
	testing.expect(t, scripted_frame(b, now, 3, "Saved", "Disk full", "hunter2"), "frame 5")
	written, _ = accessibility.semantic_tree_diff(before, now, events[:])
	_ = reader_utter_events(&queue, now, events[:written])
	current, _ = utterance_queue_current(&queue)
	testing.expect_value(t, utterance_text(current), "Passphrase, textbox, protected")
	for &entry in queue.entries[:queue.count] {
		text := utterance_text(&entry)
		for index in 0 ..< max(0, len(text) - 1) {
			testing.expectf(t, text[index:][:2] != "hu" && text[index:][:2] != "ab", "a secret was said: %q", text)
		}
	}

	// An event whose node is not in the tree is said by nobody.
	stray := [2]accessibility.Semantic_Event{{kind = .Focus_Changed, node_index = -1}, {kind = .Live_Announcement, node_index = 9999}}
	count := queue.count
	testing.expect_value(t, reader_utter_events(&queue, now, stray[:]), 0)
	testing.expect_value(t, queue.count, count)
}

// After each move of the focus, the view of the magnifier holds the box of
// the focus, at each edge of the screen and at each factor; a box wider or
// taller than the view shows its first edge.
@(test)
conformance_magnifier_follows_the_focus_box :: proc(t: ^testing.T) {
	b := new(Frame_Builder)
	defer free(b)
	before := new(accessibility.Semantic_Tree)
	defer free(before)
	now := new(accessibility.Semantic_Tree)
	defer free(now)
	events: [32]accessibility.Semantic_Event

	for factor in ([?]u16{12, 16, 64}) {
		magnifier: Magnifier_State
		testing.expect(t, magnifier_init(&magnifier, 800, 600, factor), "magnifier")
		testing.expect(t, scripted_frame(b, before, 1, "", "", "a"), "frame 1")
		for focus in ([?]u32{2, 3, 1, 2}) {
			testing.expect(t, scripted_frame(b, now, focus, "", "", "a"), "frame")
			written, _ := accessibility.semantic_tree_diff(before, now, events[:])
			testing.expect(t, magnifier_follow_events(&magnifier, now, events[:written]), "a focus move moves the view")
			box := now.nodes[now.focused_node].box
			x, y, width, height := magnifier_view(&magnifier)
			// On each axis the view holds the box when it fits, else it
			// starts at the first edge of the box, as far as the screen lets it.
			holds_x := box.right - box.left <= width ? x <= box.left && x + width >= box.right : x == min(box.left, 800 - width)
			holds_y := box.bottom - box.top <= height ? y <= box.top && y + height >= box.bottom : y == min(box.top, 600 - height)
			testing.expectf(t, holds_x && holds_y, "factor %d focus %d: view %d,%d %dx%d misses %v", factor, focus, x, y, width, height, box)
			testing.expect(t, x >= 0 && y >= 0 && x + width <= 800 && y + height <= 600, "the view stays on the screen")
			before^ = now^
		}
		// No focus event: the view stays.
		x, y, _, _ := magnifier_view(&magnifier)
		testing.expect(t, !magnifier_follow_events(&magnifier, now, nil), "no event: no move")
		after_x, after_y, _, _ := magnifier_view(&magnifier)
		testing.expect(t, x == after_x && y == after_y, "the view stays")
	}

	// A box larger than the view shows its left and top edge; an empty box
	// and a magnifier that is off move nothing.
	magnifier: Magnifier_State
	_ = magnifier_init(&magnifier, 800, 600, 64)
	magnifier_follow_box(&magnifier, {left = 300, top = 200, right = 700, bottom = 500})
	testing.expect(t, magnifier.view_x == 300 && magnifier.view_y == 200, "a large box shows its first edge")
	magnifier_follow_box(&magnifier, {left = 50, top = 50, right = 50, bottom = 90})
	testing.expect(t, magnifier.view_x == 300, "an empty box moves nothing")
	magnifier.enabled = false
	magnifier_follow_box(&magnifier, {left = 0, top = 0, right = 10, bottom = 10})
	testing.expect(t, magnifier.view_x == 300, "a magnifier that is off moves nothing")
	_, _, width, height := magnifier_view(nil)
	testing.expect(t, width == 0 && height == 0, "no magnifier: no view")
}
