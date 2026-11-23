// The test of the border of compositor.notify for a caller that does not
// act for the principal (src/md/features/tray_widgets.md, "The export
// notify"). Its name has 31 bytes, the longest name that the root service
// gives a process: each card carries it as its label.
//
// The checks, in this order:
//
// - an empty title, a title of 97 bytes and a body of 257 bytes are
//   refused with Empty and Too_Long, and change nothing: the first card
//   after them is accepted at once (no time of the rate was kept), and the
//   bound below finds 3 cards (no card was added);
// - a post right after an accepted one is refused with Busy, unit
//   Milliseconds, limit 500; or it came 500 ms or more after the first by the
//   clock of the system, and the rate was not tried: no check of a speed;
// - posts 500 ms apart are accepted until the caller shows 3 cards; the next
//   is refused with Full, unit Requests, limit 3, found 3.
//
// A card leaves after 8 seconds: a post that comes so late that a card
// left is accepted, and the loop posts again, up to POST_LIMIT posts.
//
// **Start**: start("notify_border_of_the_compositor") in the console.
// **What a reader sees**: up to 3 cards labelled with its name, and one
// line "notify_border_of_the_compositor: ok, ..." or "...: WRONG: ...".
package notify_border_of_the_compositor

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:system"

PROCESS_NAME :: "notify_border_of_the_compositor"
#assert(len(PROCESS_NAME) == 31)
CARDS_LIMIT :: 3 // notifications.CARDS_PER_SOURCE_LIMIT, as the compositor states it.
RATE_MILLISECONDS :: 500 // The rate of the queue of the compositor: one card in 500 ms for each source.
POST_LIMIT :: 12 // The posts of the loop: more means that the compositor never refused.

connection: system.Call_Connection
file: []u8
export: u32

// post calls compositor.notify with a title, and gives its result, its
// error record and its call outcome.
post :: proc "contextless" (title: string, body := "the border of notify") -> (result: i64, error: errors.Error_Record, status: system.Status, outcome: call_outcome.Call_Outcome) {
	arguments: [2]isolated.Argument
	arguments[0].text = transmute([]u8)title
	arguments[1].text = transmute([]u8)body
	call_result, call_status, call_ended := system.call_isolated(&connection, file, export, arguments[:], &error)
	return call_result, error, call_status == .Ok || call_status == .Failed ? .Ok : .Bad_State, call_ended
}

wrong :: proc "contextless" (what: string) -> ! {
	system.log_fact(.Warning, Wrong{what = value_kinds.text_field(what, 96)})
	system.stop(.Failed)
}

// is_refusal says if an error record has a kind and a unit.
is_refusal :: proc "contextless" (error: errors.Error_Record, kind: errors.Kind, unit: errors.Unit) -> bool {
	return error.kind == i64(kind) && error.unit == i64(unit)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	address, mapped := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if mapped != .Ok {
		wrong("the boot image does not map")
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	file = system.image_find(image, "compositor")
	if file == nil {
		wrong("the boot image has no module compositor")
	}
	export = module.export_find(file, "notify")
	if export == 0 {
		wrong("the compositor has no export notify")
	}
	requests, opened := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if opened != .Ok {
		wrong("the ring to the root service does not open")
	}
	connected: system.Status
	connection, connected = system.service_connection(&requests, 1, "compositor")
	if connected != .Ok {
		wrong("the root service gave no connection to the compositor")
	}

	// The refused posts: each changes nothing.
	long_title: [97]u8
	long_body: [257]u8
	for &byte in long_title {
		byte = 't'
	}
	for &byte in long_body {
		byte = 'b'
	}
	refused_posts := [3]struct {
		title, body: string,
		kind:        errors.Kind,
		argument:    i64,
		limit:       i64,
	} {
		{"", "a body", .Empty, 1, 0},
		{string(long_title[:]), "a body", .Too_Long, 1, 96},
		{"a title", string(long_body[:]), .Too_Long, 2, 256},
	}
	for refused_post in refused_posts {
		_, error, status, outcome := post(refused_post.title, refused_post.body)
		if status != .Ok {
			wrong("the call of a refused post did not come back")
		}
		if outcome != .Argument_Refused || !is_refusal(error, refused_post.kind, .Bytes) || error.argument != refused_post.argument || refused_post.kind == .Too_Long && error.limit != refused_post.limit {
			system.log_fact(.Warning, Wrong_Refusal(errors.error_record_fact_fields(error)))
			wrong("an empty title, a title of 97 bytes or a body of 257 bytes was not refused with its record")
		}
	}

	// The rate: a post right after an accepted one. The first card comes
	// right after the refused posts: they kept no time of the rate.
	first_time := system.time()
	result, error, status, outcome := post("the first card")
	if status != .Ok || outcome != .Succeeded || result <= 0 {
		system.log_fact(.Warning, Wrong_Refusal(errors.error_record_fact_fields(error)))
		wrong("the first card was refused")
	}
	result, error, status, outcome = post("a card within 500 ms")
	second_time := system.time()
	if status != .Ok {
		wrong("the call of the second card did not come back")
	}
	if outcome != .Succeeded {
		if outcome != .Callee_Busy || !is_refusal(error, .Busy, .Milliseconds) || error.limit != RATE_MILLISECONDS {
			system.log_fact(.Warning, Wrong_Refusal(errors.error_record_fact_fields(error)))
			wrong("a post within 500 ms was not refused with Busy, unit Milliseconds, limit 500")
		}
	} else if second_time - first_time < RATE_MILLISECONDS {
		wrong("a post within 500 ms by the clock was accepted")
	}

	// The bound: posts 500 ms apart until the compositor refuses one.
	refused := false
	for _ in 0 ..< POST_LIMIT {
		system.sleep(system.time() + RATE_MILLISECONDS + 100)
		result, error, status, outcome = post("a card toward the bound")
		if status != .Ok {
			wrong("a call of notify did not come back")
		}
		if outcome == .Succeeded {
			continue
		}
		if is_refusal(error, .Busy, .Milliseconds) {
			// The sleep ended early by the clock of the rate: post again.
			continue
		}
		if outcome != .Budget_Or_Capacity_Exhausted || !is_refusal(error, .Full, .Requests) || error.limit != CARDS_LIMIT || error.found != CARDS_LIMIT {
			system.log_fact(.Warning, Wrong_Refusal(errors.error_record_fact_fields(error)))
			wrong("the post past the bound was not refused with Full, unit Requests, limit 3, found 3")
		}
		refused = true
		break
	}
	if !refused {
		wrong("the compositor took each post: no bound")
	}
	system.log_fact(.Info, Border_Held{limit = CARDS_LIMIT, name_bytes = len(PROCESS_NAME)})
	system.stop(.Done)
}
