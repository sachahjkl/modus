// The record output of a reader and the rectangle of a magnifier, as the
// conformance suite reads them in place of sound and of pixels
// (src/md/features/accessibility.md, "2. The assistive role"). A reader
// turns the events of two trees into utterances; a magnifier keeps the box
// of the focus in its view. Fixed tables, no allocator.
package screen_reader

import "modus:contract/accessibility"
import "modus:contract/enum_word"

// The utterances that wait, the one in progress included. The speech
// contract states a capacity; past it a polite utterance replaces the
// oldest polite one, with a count (src/md/features/accessibility.md, "5. Speech").
UTTERANCE_QUEUE_CAPACITY :: 8

// When an utterance is said: after the one in progress, or at once.
Utterance_Priority :: enum u8 {
	Queue     = 1, // A polite live region: after the utterance in progress and the ones that wait.
	Interrupt = 2, // A focus move or an assertive live region: it stops the utterance in progress.
}

// utterance_priority_of_word is the one border of the word of a priority.
utterance_priority_of_word :: proc "contextless" (word: u64) -> (priority: Utterance_Priority, ok: bool) {
	return enum_word.member_of_word(Utterance_Priority, word)
}

// One utterance of the record output of a reader.
Utterance :: struct {
	serial:   u64, // From 1, never given twice by one queue.
	element:  u32, // The element that the utterance speaks of.
	priority: Utterance_Priority,
	length:   u16,
	text:     [MAX_ANNOUNCEMENT_BYTES]u8,
}

// The utterances of a reader: entries[0] is in progress while count > 0,
// the others wait in their order.
Utterance_Queue :: struct {
	entries:     [UTTERANCE_QUEUE_CAPACITY]Utterance,
	count:       int,
	last_serial: u64,
	replaced:    u32, // Polite utterances that a newer one replaced in a full queue: the reader says their count after.
	cut:         u32, // Utterances in progress that an Interrupt stopped.
	refused:     u32, // Polite utterances refused because each waiting one was an Interrupt.
}

// Why an utterance is not queued. A refusal is counted, never silent.
Utterance_Refusal :: enum u8 {
	None,
	Empty_Text, // Nothing to say.
	Too_Long, // Past MAX_ANNOUNCEMENT_BYTES.
	Full, // The queue is full of utterances that no polite one replaces.
}

// utterance_text gives the text of an utterance.
utterance_text :: proc "contextless" (utterance: ^Utterance) -> string {
	return string(utterance.text[:min(int(utterance.length), MAX_ANNOUNCEMENT_BYTES)])
}

@(private = "file")
queue_remove :: proc "contextless" (queue: ^Utterance_Queue, index: int) {
	copy(queue.entries[index:queue.count - 1], queue.entries[index + 1:queue.count])
	queue.count -= 1
	queue.entries[queue.count] = {}
}

// utterance_queue_push queues a text. An Interrupt stops the utterance in
// progress and is said at once; the ones that wait stay, in their order. A
// Queue utterance goes after the others; in a full queue it replaces the
// oldest polite one that waits.
utterance_queue_push :: proc "contextless" (queue: ^Utterance_Queue, priority: Utterance_Priority, element: u32, text: []u8) -> (serial: u64, refusal: Utterance_Refusal) {
	if len(text) == 0 {
		return 0, .Empty_Text
	}
	if len(text) > MAX_ANNOUNCEMENT_BYTES {
		return 0, .Too_Long
	}
	place := queue.count
	switch priority {
	case .Interrupt:
		if queue.count > 0 {
			queue_remove(queue, 0)
			queue.cut += 1
		}
		copy(queue.entries[1:queue.count + 1], queue.entries[0:queue.count])
		place = 0
	case .Queue:
		if queue.count >= UTTERANCE_QUEUE_CAPACITY {
			oldest := -1
			for index in 1 ..< queue.count {
				if queue.entries[index].priority == .Queue {
					oldest = index
					break
				}
			}
			if oldest < 0 {
				queue.refused += 1
				return 0, .Full
			}
			queue_remove(queue, oldest)
			queue.replaced += 1
		}
		place = queue.count
	}
	queue.last_serial += 1
	entry := &queue.entries[place]
	entry^ = {serial = queue.last_serial, element = element, priority = priority, length = u16(len(text))}
	copy(entry.text[:], text)
	queue.count += 1
	return entry.serial, .None
}

// utterance_queue_current gives the utterance in progress.
utterance_queue_current :: proc "contextless" (queue: ^Utterance_Queue) -> (utterance: ^Utterance, ok: bool) {
	if queue.count == 0 {
		return nil, false
	}
	return &queue.entries[0], true
}

// utterance_queue_finish ends the utterance in progress when speech says it
// ended. A serial that is not the one in progress changes nothing: speech
// that ends a stopped utterance must not end the next one.
utterance_queue_finish :: proc "contextless" (queue: ^Utterance_Queue, serial: u64) -> bool {
	if queue.count == 0 || serial == 0 || queue.entries[0].serial != serial {
		return false
	}
	queue_remove(queue, 0)
	return true
}

// reader_utter_events turns the events of a frame into utterances: the
// name, the role and the states of a new focus at once; the new text of a
// live region at its politeness; nothing for a protected field, nothing
// for the other events. It gives the count of refused utterances.
//
// The focus of a frame is said before its live regions: the diff gives the
// focus last, and an Interrupt said last would stop a polite text of the
// same frame before a principal heard it.
reader_utter_events :: proc "contextless" (queue: ^Utterance_Queue, now: ^accessibility.Semantic_Tree, events: []accessibility.Semantic_Event) -> (refused: int) {
	refused += reader_utter_events_of_kind(queue, now, events, .Focus_Changed)
	refused += reader_utter_events_of_kind(queue, now, events, .Live_Announcement)
	return refused
}

@(private = "file")
reader_utter_events_of_kind :: proc "contextless" (queue: ^Utterance_Queue, now: ^accessibility.Semantic_Tree, events: []accessibility.Semantic_Event, kind: accessibility.Semantic_Event_Kind) -> (refused: int) {
	for &event in events {
		if event.kind != kind {
			continue
		}
		if event.node_index < 0 || int(event.node_index) >= now.node_count {
			continue
		}
		node := &now.nodes[event.node_index]
		text: [MAX_ANNOUNCEMENT_BYTES]u8
		length := 0
		priority := Utterance_Priority.Queue
		if kind == .Focus_Changed {
			if .Hidden in node.states {
				continue
			}
			pressed, checked := toggle_words_of(node.role, node.toggle)
			name := accessibility.semantic_node_name(now, node)
			length = announce_element(node.role, node.states, pressed, checked, node.expanded, transmute([]u8)name, text[:])
			priority = .Interrupt
		} else {
			if .Protected in node.states {
				continue
			}
			said := accessibility.semantic_node_live_text(now, node)
			if len(said) == 0 {
				said = accessibility.semantic_node_name(now, node)
			}
			length = copy(text[:], said)
			priority = event.live == .Assertive ? .Interrupt : .Queue
		}
		if _, refusal := utterance_queue_push(queue, priority, node.element, text[:length]); refusal != .None {
			refused += 1
		}
	}
	return refused
}

// A button says its toggle as pressed; each other role says it as checked.
@(private = "file")
toggle_words_of :: proc "contextless" (role: accessibility.Element_Role, toggle: accessibility.Toggle_State) -> (pressed, checked: accessibility.Toggle_State) {
	if role == .Button {
		return toggle, .None
	}
	return .None, toggle
}

// magnifier_view gives the rectangle of the screen that the magnifier draws
// larger.
magnifier_view :: proc "contextless" (m: ^Magnifier_State) -> (x, y, width, height: i32) {
	if m == nil || m.zoom_eighths < 8 {
		return 0, 0, 0, 0
	}
	return m.view_x, m.view_y, (m.screen_w * 8) / i32(m.zoom_eighths), (m.screen_h * 8) / i32(m.zoom_eighths)
}

// magnifier_follow_box moves the view so it holds a box: centered on it
// when it fits, its left or top edge first when it does not, since a
// principal reads from that edge.
magnifier_follow_box :: proc "contextless" (m: ^Magnifier_State, box: accessibility.Semantic_Box) {
	if m == nil || !m.enabled || m.zoom_eighths < 8 || box.right <= box.left || box.bottom <= box.top {
		return
	}
	_, _, view_width, view_height := magnifier_view(m)
	x := box.right - box.left <= view_width ? box.left + (box.right - box.left) / 2 - view_width / 2 : box.left
	y := box.bottom - box.top <= view_height ? box.top + (box.bottom - box.top) / 2 - view_height / 2 : box.top
	m.view_x = clamp(x, 0, max(i32(0), m.screen_w - view_width))
	m.view_y = clamp(y, 0, max(i32(0), m.screen_h - view_height))
}

// magnifier_follow_events follows the focus after a move of the focus, or
// of the value or the caret of the element with the focus.
magnifier_follow_events :: proc "contextless" (m: ^Magnifier_State, now: ^accessibility.Semantic_Tree, events: []accessibility.Semantic_Event) -> (followed: bool) {
	focus := now.focused_node
	if focus < 0 || int(focus) >= now.node_count {
		return false
	}
	for &event in events {
		if event.kind == .Focus_Changed || (event.kind == .Value_Changed && event.node_index == focus) {
			magnifier_follow_box(m, now.nodes[focus].box)
			return true
		}
	}
	return false
}
