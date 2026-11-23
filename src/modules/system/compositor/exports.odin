package compositor

import "internal:compositor/bar"
import "modus:contract/chosen_values"
import "modus:contract/desktop_shell"
import "modus:contract/call_outcome"
import "modus:contract/display_choices"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/notifications"
import pr "modus:contract/plans_recipes"
import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:system"

// The compositor is also a service: its exports give the place of the
// pointer and the windows, as tables of records that a caller in another
// process reads with no code of the compositor. The test
// tool reads them through the remote service before each press of the
// pointer, so that a press lands where the scenario wants it.
//
// The place of the pointer and the windows are facts of the screen: another
// process must not learn where the input goes. The exports give them only
// to a caller that acts for the principal. A Record result has no error record, so it cannot
// refuse (docs/MODULE_CONTRACT.md, section 4): pointer() is a Table of one
// row.

// The values of the context that name the file of this process: 0 to 3 are
// the screen (VALUE_WIDTH ...). The root service writes the same numbers.
VALUE_FILE_ADDRESS :: 4
VALUE_FILE_SIZE :: 5

// The place of the pointer: pointer().
Pointer :: struct {
	x:       i64, // From the left of the screen, in pixels.
	y:       i64, // From the top of the screen.
	buttons: i64, // Bit 0: the left button is down; bit 1: the right one; bit 2: the middle one.
	moves:   i64, // The pointer records that the input service sent since the start.
	keys:    i64, // The key records that the input service sent since the start: each press and each release is one. The palette takes some of them, and a record goes to no window when none is open.
	keys_waiting: i64, // The key records that wait in the compositor for a window whose ring is full.
	keys_refused: i64, // The key records that the compositor lost since the start: the ring of the window and the queue of the compositor for it were full. 0 on a system that works.
	menu:    [16]u8, // The menu or the card of the bar that is open: "start", "windows", "control_center", "notifications", "calendar", or empty.
	palette:  i64, // The state of the palette: 0 closed; 1 the search; 2 it asks for a second Enter; 3 it waits for its provider; 4 it shows a result; 5 it has the form of a command. Not 0: it takes the keys.
	shape:    [32]u8, // The name of the pointer shape on the screen: "arrow", "move", "text", ... (docs/POINTERS.md).
	form:     [8]u8, // The pointer form on the screen: "dark" or "light", from the appearance in force (docs/POINTERS.md).
}

// One row for each window, the front one first: windows().
Window :: struct {
	title:    [32]u8,
	x:        i64, // The place of the window with its frame and its title bar.
	y:        i64,
	width:    i64, // The size of the window with its frame and its title bar.
	height:   i64,
	order:    i64, // 0: the front window; 1: the one under it; ...
	focus:    i64, // 1: the window has the focus: the front one.
	keyboard: i64, // 1: the keys go to the window: the one with the focus, while the palette is closed.
	presents: i64, // The Present records that the process of the window sent since it created its surface.
	waits:    i64, // 1: a Present of the process changed a part of the screen, and no frame drew it yet.
	events_sent: i64, // The event records that the ring of the window took since the window opened: keys, pointer records, changes of the settings.
	events_unread: i64, // The event records in the ring that the process did not read yet. The process writes the count of its reads: it says this of itself.
	events_waiting: i64, // The event records that wait in the compositor, because the ring of the window is full.
	keys_refused: i64, // The key records of this window that the compositor lost: the ring and the queue were full.
	frames:   i64, // The frames of the screen that read a picture of this window.
	pictures_drawn_again: i64, // The Present records that named the picture that the compositor already read: the process drew in a picture on the screen. 0 for a process that shows whole frames.
	presents_refused: i64, // The Present records that the compositor refused: their picture number names no picture of the surface. 0 for a process of the system.
	due:      i64, // 1: the process said that a change of the window waits for its next picture, which it draws at a time of its own clock. The window does not show the last state of the process yet. The process says this of itself.
}

// VirtIO-GPU 1.2 scanout and Venus capability status: gpu_info().
Gpu_Info :: struct {
	present:           i64, // 1: VirtIO-GPU PCI device discovered and gpu_device running.
	attached:          i64, // 1: the screen is the scanout of the VirtIO-GPU: each frame goes through it.
	width:             i64, // Reported VirtIO-GPU scanout width in pixels.
	height:            i64, // Reported VirtIO-GPU scanout height in pixels.
	venus:             i64, // 1: host VirtIO-GPU exposes a Venus Vulkan capability set.
	venus_max_version: i64, // Highest Venus capset version reported by the host.
	presents:          i64, // The frames that the scanout showed: gpu_device answered each Present_Frame.
	frames_merged:     i64, // The frames whose damage waited for the answer of a present, and went with a later present.
}

// What the screen shows against what the compositor received: screen().
Screen :: struct {
	frames:   i64, // The frames that the compositor drew since the start.
	presents: i64, // The Present records of all the processes since the start.
	damage:   i64, // The damage rectangles that wait for the next frame.
	desktop:  i64, // 1: a change of the desktop itself waits for the next frame: the pointer, the bar, a menu, the palette, a window that appeared, moved or closed.
	page_flips: i64, // The page flips since the start: each one showed a frame whole.
	frames_on_the_shown_page: i64, // The frames that the compositor wrote into the screen page that the display showed. 0 on a display with two screen pages.
}

// One row for each requested grant that holds: window_grants().
Window_Grant_Row :: struct {
	grant:    i64, // The number of the grant: revoke_grant takes it.
	window:   [32]u8, // The name of the process, and the title of its window.
	resource: [96]u8, // The object of the grant, as the dialog showed it.
}
#assert(bar.WINDOW_GRANT_PROCESS_BYTES < 32 && bar.WINDOW_GRANT_RESOURCE_BYTES < 96)

// One row for each holder of the assistive role that reads the trees: assistive_holders().
Assistive_Holder_Row :: struct {
	holder:   i64, // The number of the holder: assistive_detach takes it.
	kind:     [16]u8, // screen_reader, magnifier or switch_input.
	nickname: [32]u8, // The nickname that its mark in the bar shows.
}
#assert(bar.ASSISTIVE_NICKNAME_BYTES < 32 && ASSISTIVE_KIND_FIELD_BYTES <= 16)

service: system.Service
pointer_moves: u64
key_records: u64

// service_start opens the service ring. The file of this process is at
// values 4 and 5, not at the places of a service that system.service_open
// reads (values 1 and 2 are the screen here): it reads a copy of the
// context with the two values at their places.
service_start :: proc "contextless" (ctx: ^system.Context) {
	copied := ctx^
	copied.values[system.GRANT_VALUE_FILE_ADDRESS] = ctx.values[VALUE_FILE_ADDRESS]
	copied.values[system.GRANT_VALUE_FILE_SIZE] = ctx.values[VALUE_FILE_SIZE]
	service, _ = system.service_open(&copied)
}

@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// plan_display_caller says if the caller of the export that runs may ask
// for the dialog of a difference and read its decision: the holder of Plans
// acts for nobody, and the root service names it in the amount of its grant
// (src/md/features/declarations.md, "The trusted display of a plan").
plan_display_caller :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || pr.plan_display_caller_allowed(caller.grant)
}

// pointer gives the place of the pointer on the screen, its buttons, the menu of the bar that is open, the state of the palette, and the name of the pointer shape, as one row. The result is 1, or a failure with its call outcome and an error record. The error kind: No_Grant (the caller does not act for the principal).
//
// **What it is for.** A caller that drives the desktop from outside, as
// the machine test does through the remote service, reads where the
// pointer is and what is open before it moves the pointer or presses a
// button. The row is the state after the input records that the compositor
// took before the call.
//
// **The row** (`Pointer`):
//
// - `x`, `y`: the place of the pointer, in pixels from the top left corner.
//   It is the point where a press acts: the hot spot of the picture.
// - `buttons`: bit 0 the left button, bit 1 the right one, bit 2 the
//   middle one.
// - `moves`, `keys`: the pointer records and the key records that the
//   input service sent since the start.
// - `keys_waiting`: the key records that wait in the compositor for a
//   window whose ring is full. They go to that window, in order, when it
//   reads.
// - `keys_refused`: the key records that the compositor lost since the
//   start, because the ring of a window and the queue of the compositor
//   for it were both full. It is 0 on a system that works; the log has a
//   line for each loss period.
// - `menu`: the menu or the card of the bar that is open: `start`,
//   `windows`, `control_center`, `notifications`, `calendar`, or empty.
// - `palette`: the state of the palette: 0 while it is closed; 1 while it
//   is open and the input searches; 2 while it asks for a second Enter; 3
//   while it waits for what its provider gives; 4 while it shows a result;
//   5 while its input band is the form of a command with parameters.
//   Open, it takes the keys.
// - `shape`: the name of the pointer shape on the screen (`arrow`, `move`,
//   `text`...; docs/POINTERS.md).
// - `form`: the pointer form on the screen, `dark` or `light`: the form of
//   the appearance in force.
//
// **Grant**: the caller must **act for the principal**. A caller without
// it gets the error kind `No_Grant`, with the call outcome Grant_Or_Right_Missing: the place of the
// pointer tells where the input goes.
//
// ```
// connect("compositor")
// compositor.pointer()
// ```
@(export, link_name = "pointer")
pointer :: proc "c" (result: ^[]Pointer, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {x = i64(pointer_x), y = i64(pointer_y), buttons = i64(buttons), moves = i64(pointer_moves), keys = i64(key_records), keys_waiting = i64(keys_waiting_of_all_windows()), keys_refused = i64(key_records_refused), palette = i64(palette_panel.state)}
		copy(result[0].shape[:len(result[0].shape) - 1], pointer_pictures.SHAPE_NAMES[pointer_shape_under()])
		copy(result[0].form[:len(result[0].form) - 1], pointer_form_name(pointer_form))
		switch menu_open {
		case .None:
			// No menu: the card of a tray widget, or empty.
			copy(result[0].menu[:len(result[0].menu) - 1], tray_widget_name(tray_state.open))
		case .Start:
			copy(result[0].menu[:], "start")
		case .Windows:
			copy(result[0].menu[:], "windows")
		}
	}
	return .Succeeded, 1
}

// windows gives one row for each window, the front one first: its title, its place and its size with the frame, its order from the front, whether it has the focus, and whether the keys go to it. The result is the count of rows, or a failure with its call outcome and an error record. The error kind: No_Grant (the caller does not act for the principal).
//
// **What it is for.** A caller finds a window by its title, then presses
// its title bar or its close button at a place that it computes from the
// row. The machine test does so before each drag.
//
// **A row** (`Window`):
//
// - `title`: the name of the process of the window.
// - `x`, `y`, `width`, `height`: the window with its frame and its title
//   bar, in pixels of the screen. The title bar is the top 24 pixels; the
//   close button is the square of 24 pixels at its right end.
// - `order`: 0 for the window in front, 1 for the one under it, and so on.
// - `focus`: 1 for the window in front.
// - `keyboard`: 1 when the keys go to the window: the window in front,
//   while the palette is closed.
// - `presents`: the `Present` records that the process of the window sent
//   since it created its surface.
// - `waits`: 1 while a `Present` of the process changed a part of the
//   screen and no frame drew it yet. 0: the screen shows the last picture
//   that the process sent before the call.
// - `events_sent`, `events_unread`: the event records that the ring of the
//   window took, and the ones in the ring that the process did not read
//   yet.
// - `events_waiting`: the event records that wait in the compositor while
//   the ring of the window is full (256 at most).
// - `keys_refused`: the key records of this window that were lost, because
//   256 records already waited.
// - `frames`: the frames of the screen that read a picture of the window.
// - `pictures_drawn_again`: the `Present` records that named the picture
//   that the compositor already read. A surface has two pictures, and a
//   process draws the one that the compositor does not read: each
//   `Present` names the other picture. A process that names the same
//   picture again drew in a picture on the screen, and the screen could
//   show it half drawn. It is 0 for a process that shows
//   [whole frames](term:whole-frame).
// - `presents_refused`: the `Present` records that the compositor refused,
//   because their picture number names no picture of the surface (it is 0
//   or 1). Such a record changes nothing on the screen and is not in
//   `presents`.
//
// Only a process that created its surface has a window. If the table of
// the caller has fewer places than windows, the rows of the windows at the
// back are missing, and the result still gives the count of all windows.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// where(compositor.windows(), focus = 1)
// ```
@(export, link_name = "windows")
windows :: proc "c" (result: ^[]Window, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	for position in 0 ..< order_count {
		row := order_count - 1 - position
		if row >= len(result^) {
			continue
		}
		client := &clients[order[position]]
		queue := &window_queues[order[position]]
		result[row] = {
			x        = i64(client.x),
			y        = i64(client.y),
			width    = i64(client.width + 2 * BORDER),
			height   = i64(client.height + TITLE_HEIGHT + BORDER),
			order    = i64(row),
			focus    = row == 0 ? 1 : 0,
			keyboard = row == 0 && !palette_is_open() ? 1 : 0,
			presents = i64(client.presents),
			waits    = client.present_waits ? 1 : 0,
			events_sent = i64(queue.delivered),
			events_unread = i64(ring.count(&client.ring.completions)),
			events_waiting = i64(queue.count + (queue.move_waits ? 1 : 0)),
			keys_refused = i64(queue.refused[.Key]),
			frames   = i64(client.frames),
			pictures_drawn_again = i64(client.pictures_drawn_again),
			presents_refused = i64(client.presents_refused),
			due      = client.picture_due ? 1 : 0,
		}
		copy(result[row].title[:len(result[row].title) - 1], system.name_of(client.title[:]))
	}
	return .Succeeded, i64(order_count)
}

// screen gives the frames that the compositor drew, the Present records that it received, the damage rectangles that wait for the next frame, whether a change of the desktop itself waits, and how its frames reached the screen, as one row. The result is 1, or a failure with its call outcome and an error record. The error kind: No_Grant (the caller does not act for the principal).
//
// **What it is for.** A caller that takes a picture of the screen from
// outside, as the machine test does through the remote service, reads if
// the screen shows what the compositor received. The compositor draws a
// frame at most once in 16 ms: between a change and its frame, the screen
// shows the picture before.
//
// **The row** (`Screen`):
//
// - `frames`: the frames drawn since the start.
// - `presents`: the `Present` records of all the processes since the start.
// - `damage`: the damage rectangles that wait for the next frame, of the
//   desktop and of the processes.
// - `desktop`: 1 while a change of the desktop itself waits for the next
//   frame: the pointer, the bar, a menu, the palette, a window that
//   appeared, moved or closed. The `Present` of a process is not in it:
//   `windows()` gives it for each window, in `waits`.
// - `page_flips`: the [page flips](term:page-flip) since the start. With
//   two [screen pages](term:screen-page), each frame goes into the page
//   that the display does not show, and a flip shows it whole.
// - `frames_on_the_shown_page`: the frames that the compositor wrote into
//   the screen page that the display showed, which the display could show
//   in part. It is 0 on a display with two screen pages. With one, or after
//   a flip that the display refused, it counts each frame.
//
// The row counts each record that a process sent before the call: the
// compositor reads the ring of each window before it answers. It does not
// say that a process sent its last picture: a process that still computes
// has sent nothing yet. The state of the threads of the process says that
// (`monitor.processes()`).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.screen()
// ```
@(export, link_name = "screen")
screen_state :: proc "c" (result: ^[]Screen, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {frames = i64(frames), presents = i64(presents), damage = i64(damage_count), desktop = desktop_change_waits ? 1 : 0, page_flips = i64(page_flips), frames_on_the_shown_page = i64(frames_on_the_shown_page)}
	}
	return .Succeeded, 1
}

// notify posts a non-focus-stealing desktop notification card in the top-right
// corner below the bar and returns its assigned notification identifier, or a failure with its call outcome and an error record.
//
// A caller that acts for the principal posts as the principal. Any other
// caller posts under its own process name, which the card shows before the
// title, and holds at most 3 cards at once
// (src/md/features/tray_widgets.md, "The export notify").
//
// The error kinds:
//
// - Empty: an empty title (argument 1), or a caller whose connection has
//   no name (argument 0).
// - Too_Long: a title past 96 bytes (argument 1) or a body past 256 bytes
//   (argument 2).
// - Full, unit Requests: the caller shows 3 cards already; limit 3, found
//   the cards that it shows.
// - Full, unit Records: the desktop shows 64 cards already; limit 64.
// - Busy, unit Milliseconds: a post within 500 ms of the last one of the
//   caller; limit 500.
// - Refused: the notifications are off (do not disturb), or the desktop
//   is not ready.
//
// **Grant**: a connection to the compositor.
@(export, link_name = "notify")
notify_export :: proc "c" (title: ^string, body: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if len(title^) == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1)
	}
	source := notifications.PRINCIPAL_SOURCE
	label: []u8
	cards_limit := 0
	if !acts_for_principal() {
		// The name of the connection, as the root service gave it: never
		// a text of the caller. A card with no name would name nobody.
		caller := system.service_caller()
		name := system.name_of(caller.caller[:])
		if len(name) == 0 {
			return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 0, 0, notifications.MAX_LABEL_BYTES)
		}
		source = notifications.source_of_caller_name(name)
		label = transmute([]u8)name
		cards_limit = notifications.CARDS_PER_SOURCE_LIMIT
	}
	id, refusal := desktop_notification_post(source, .Normal, system.time(), transmute([]u8)(title^), transmute([]u8)(body^), label, cards_limit)
	switch refusal {
	case .None:
		return .Succeeded, i64(id)
	case .Source_Full:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Requests, 0, 0, notifications.CARDS_PER_SOURCE_LIMIT, i64(notifications.source_card_count(&desktop_notifications, source)))
	case .Empty_Title:
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1)
	case .Title_Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(title^)), notifications.MAX_TITLE_BYTES)
	case .Body_Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(body^)), notifications.MAX_BODY_BYTES)
	case .Label_Too_Long:
		// The root service names a process in 32 bytes at most: no name
		// of a connection is longer.
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 0, i64(len(label)), notifications.MAX_LABEL_BYTES)
	case .Queue_Full:
		return call_outcome.fail(error, .Callee_Busy, .Full, .Records, 0, 0, notifications.MAX_NOTIFICATIONS, notifications.MAX_NOTIFICATIONS)
	case .Rate_Limited:
		return call_outcome.fail(error, .Callee_Busy, .Busy, .Milliseconds, 0, 0, i64(notifications.RATE_INTERVAL_MILLISECONDS))
	case .Show_Time_Out_Of_Range:
		// The compositor gives the time, never the caller: a time out of
		// the range is the setting that its border refused.
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Milliseconds, 0, 0, i64(notifications.SHOW_MILLISECONDS_LEAST), i64(notifications.SHOW_MILLISECONDS_MOST))
	case .Suppressed, .Nil_Queue, .Not_Found:
		return call_outcome.fail(error, .Wrong_State, .Refused, .None)
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused, .None)
}

// magnifier sets the desktop viewport magnifier zoom factor in eighths
// (0 disables; 12 to 64 enables 1.5x to 8x zoom centered on the pointer) and
// returns 1 on success, or a failure with its call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "magnifier")
magnifier_export :: proc "c" (zoom_eighths: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if zoom_eighths < 0 || zoom_eighths > 64 || (zoom_eighths != 0 && zoom_eighths < 12) {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Counts, 1, zoom_eighths, 64)
	}
	if !desktop_magnifier_set(u16(zoom_eighths), i32(pointer_x), i32(pointer_y)) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Counts, 1, zoom_eighths)
	}
	return .Succeeded, 1
}

// powerbox_ask opens an unforgeable trusted-display grant request dialog for a
// process requesting a network endpoint or store and returns the request ID, or a failure with its call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "powerbox_ask")
powerbox_ask_export :: proc "c" (process_name: ^string, resource: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	// One trusted dialog at a time: a dialog of a plan, the screen of a
	// wide grant or the card of its mark shows, or a screen waits.
	if plan_difference_dialog.open || wide_grant_trusted_surface_open() || wide_grant_screen_waits {
		return call_outcome.fail(error, .Callee_Busy, .Busy, .Requests, 0, 1, 1)
	}
	id := powerbox_prompt_open(.Network_Endpoint, process_name^, resource^)
	if id == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1)
	}
	return .Succeeded, i64(id)
}

// set_decoration switches a window between default server decorations (0) and
// borderless client-side decorations (1), returning 1 on success or a failure with its call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "set_decoration")
set_decoration_export :: proc "c" (window_order: i64, mode: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	dec, ok := desktop_shell.window_decoration_of_word(u64(mode))
	if mode < 0 || !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Counts, 2, mode)
	}
	if window_order < 0 || int(window_order) >= order_count {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Counts, 1, window_order, i64(order_count))
	}
	idx := order[order_count - 1 - int(window_order)]
	clients[idx].decoration = dec
	damage_whole_screen()
	return .Succeeded, 1
}

// open_context_menu opens the filterable fuzzy desktop context menu at (x, y)
// and returns 1, or a failure with its call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "open_context_menu")
open_context_menu_export :: proc "c" (x: i64, y: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	desktop_context_menu_open(int(x), int(y))
	return .Succeeded, 1
}

// powerbox_pick_store opens the unforgeable trusted-display Store Picker dialog
// for a requesting process (which never sees the store list) and returns the
// request ID, or a failure with its call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "powerbox_pick_store")
powerbox_pick_store_export :: proc "c" (process_name: ^string, mode: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	// One trusted dialog at a time: a dialog of a plan, the screen of a
	// wide grant or the card of its mark shows, or a screen waits.
	if plan_difference_dialog.open || wide_grant_trusted_surface_open() || wide_grant_screen_waits {
		return call_outcome.fail(error, .Callee_Busy, .Busy, .Requests, 0, 1, 1)
	}
	caller := system.service_caller()
	principal := caller == nil ? 0 : isolated.caller_principal(caller.grant)
	id := powerbox_prompt_open(.Store_Share, process_name^, mode^, principal)
	if id == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1)
	}
	return .Succeeded, i64(id)
}

// set changes the settings of the role Display, each optional: the edge of
// the bar, "do not disturb", how long a card of a notification shows (in
// milliseconds, 1000 to 60000), the factor of the magnifier when the
// principal turns it on (in eighths, 12 to 64), and the arm time of a dialog
// of the trusted display (in milliseconds, 500 to 10000: nothing makes it
// shorter than 500). The change holds at once; the keeper writes it to the
// store of the role after, on its worker, so a restart of the compositor
// keeps it (src/md/features/module_settings.md, modus:kept_choices). A
// write that the store refuses leaves the change for this run only, with
// one line of the log. The result is 1, or -1 with an error record:
// No_Grant for a caller that does not act for the principal, Absent for a
// call that gives no setting, Bad_Value for a word that names no member or
// a number out of its range (argument: its place, from 1), or for changes
// that the kept record has no room for, Refused with the unit Store when
// the compositor has no role store, No_Grant with the unit Plan_Lock for a
// setting that a lock of the plan holds (argument: its place). A refused
// call changes nothing. The edges left and right are kept and draw the bar at the top:
// the compositor draws no vertical bar yet (src/md/features/bar_edge.md).
//
// **Grant**: the caller must **act for the principal**.
//
// ```
// connect("compositor")
// compositor.set(bar_edge = .bottom, notification_show_milliseconds = 12000)
// ```
@(export, link_name = "set", enum_getters = "bar_edge = bar_edge, do_not_disturb = do_not_disturb", parameter_ranges = "notification_show_milliseconds = 1000..60000, magnifier_eighths = 12..64, consent_arm_milliseconds = 500..10000")
display_set_export :: proc "c" (
	bar_edge_presence: module.Presence,
	bar_edge: desktop_shell.Bar_Position,
	do_not_disturb_presence: module.Presence,
	do_not_disturb: display_choices.Do_Not_Disturb,
	notification_show_milliseconds_presence: module.Presence,
	notification_show_milliseconds: i64,
	magnifier_eighths_presence: module.Presence,
	magnifier_eighths: i64,
	consent_arm_milliseconds_presence: module.Presence,
	consent_arm_milliseconds: i64,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	arguments := display_choices.Set_Arguments{bar_edge_presence, bar_edge, do_not_disturb_presence, do_not_disturb, notification_show_milliseconds_presence, notification_show_milliseconds, magnifier_eighths_presence, magnifier_eighths, consent_arm_milliseconds_presence, consent_arm_milliseconds}
	changes, count, argument, problem := display_choices.changes_of_set(arguments)
	switch problem {
	case .None:
	case .Nothing_Given:
		return call_outcome.fail(error, .Argument_Refused, .Absent, .None, 0)
	case .Bad_Value:
		words := [5]i64{i64(bar_edge), i64(do_not_disturb), notification_show_milliseconds, magnifier_eighths, consent_arm_milliseconds}
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, i64(argument), words[argument - 1])
	}
	// A lock of the plan holds over the choice: a call that names a locked
	// setting changes none (src/md/features/module_settings.md, "The lock").
	presences := [display_choices.Setting]module.Presence{.Bar_Edge = bar_edge_presence, .Do_Not_Disturb = do_not_disturb_presence, .Notification_Show_Time = notification_show_milliseconds_presence, .Magnifier_Factor = magnifier_eighths_presence, .Consent_Arm_Time = consent_arm_milliseconds_presence}
	if locked, found := display_choices.first_locked(display_plan, presences); found {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, i64(locked) + 1)
	}
	return choice_change_fail(display_choices_change(changes[:count]), error, 0, 0)
}

// bar_edge gives the edge of the screen that holds the bar.
@(export, link_name = "bar_edge")
bar_edge_get :: proc "c" () -> desktop_shell.Bar_Position {
	return display_choices_in_force.bar_edge
}

// do_not_disturb gives whether a card that is not critical shows: `.off`,
// they show; `.on`, only a critical card shows.
@(export, link_name = "do_not_disturb")
do_not_disturb_get :: proc "c" () -> display_choices.Do_Not_Disturb {
	return display_choices_in_force.do_not_disturb
}

// notification_time gives how long a card of a notification shows, in
// milliseconds.
@(export, link_name = "notification_time")
notification_time_get :: proc "c" () -> i64 {
	return i64(display_choices_in_force.notification_show_milliseconds)
}

// magnifier_factor gives the factor of the magnifier when it turns on, in
// eighths.
@(export, link_name = "magnifier_factor")
magnifier_factor_get :: proc "c" () -> i64 {
	return i64(display_choices_in_force.magnifier_eighths)
}

// consent_arm_time gives the arm time of a dialog of the trusted display, in
// milliseconds.
@(export, link_name = "consent_arm_time")
consent_arm_time_get :: proc "c" () -> i64 {
	return i64(display_choices_in_force.consent_arm_milliseconds)
}

// reset makes the choice of one setting of the role absent: the default
// holds for it again. The value is 1. A failure gives its call outcome and an error record:
// No_Grant (unit Plan_Lock: a lock of the plan holds it), Bad_Value for a word that names no setting, Refused when the
// store did not keep the change.
//
// **Grant**: the caller must **act for the principal**.
//
// ```
// compositor.reset(.bar_edge)
// ```
@(export, link_name = "reset")
display_reset_export :: proc "c" (setting: display_choices.Setting, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	member, ok := display_choices.setting_of_word(u64(setting))
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, i64(setting))
	}
	if display_choices.setting_locked(display_plan, member) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 1)
	}
	changes := [1]chosen_values.Change{{name = display_choices.SETTING_NAMES[member], kind = .Reset}}
	return choice_change_fail(display_choices_change(changes[:]), error, 1, i64(setting))
}

// The state of one setting of the role: the setting, the layer that gives
// its value (0 the contract default, 1 a default of the plan, 2 a choice of
// the principal, 3 a lock of the plan), and the word of its value.
Setting_State :: struct {
	setting: i64,
	layer:   i64,
	value:   i64,
}

// settings_state gives one row for each setting of the role Display: which
// layer gives its value, and the value. A reader sees that a choice hides a
// default. The value is the count of the settings. A failure gives its
// call outcome and an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "settings_state")
settings_state_export :: proc "c" (result: ^[]Setting_State, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	for setting in display_choices.Setting {
		row := int(setting)
		if row < len(result^) {
			result[row] = {setting = i64(setting), layer = i64(display_choices_in_force.layers[setting]), value = i64(display_choices.word_of(display_choices_in_force, setting))}
		}
	}
	return .Succeeded, i64(len(display_choices.Setting))
}

// tray_widget_open opens the card of a tray widget, as a press on its part of the bar does, or closes the card that is open: 0 closes, 1 the control center, 2 the notification center, 3 the calendar. Opening a card closes the start menu, the menu of the windows, the list of the viewers and the context menu of the desktop. The result is 1, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Bad_Value (a word that names no tray widget).
//
// The field `menu` of `pointer()` names the open card: `control_center`,
// `notifications` or `calendar` (src/md/features/tray_widgets.md).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.tray_widget_open(3)
// ```
@(export, link_name = "tray_widget_open")
tray_widget_open_export :: proc "c" (widget_word: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	widget, known := bar.tray_widget_of_word(u64(widget_word))
	if widget_word < 0 || !known {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, widget_word, i64(max(bar.Tray_Widget)))
	}
	tray_widget_show(widget) // tray_widgets.odin
	return .Succeeded, 1
}

// gpu_info returns one row describing the VirtIO-GPU 1.2 scanout and Venus
// capability state discovered by the compositor, or a failure with its call outcome
// and an error record. With the scanout, `presents` counts the frames that the
// scanout showed, and `frames_merged` the frames whose damage waited for
// the answer of a present and went with the next one: a host that is slow
// to answer merges frames, and never holds the compositor
// (src/md/infrastructure/whole_frame.md, "The screen through the scanout of
// the virtual GPU").
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "gpu_info")
gpu_info_export :: proc "c" (result: ^[]Gpu_Info, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {
			present           = gpu_present ? 1 : 0,
			attached          = gpu_attached ? 1 : 0,
			width             = i64(gpu_width),
			height            = i64(gpu_height),
			venus             = gpu_venus_available ? 1 : 0,
			venus_max_version = i64(gpu_venus_max_version),
			presents          = i64(gpu_presents),
			frames_merged     = i64(gpu_frames_merged),
		}
	}
	return .Succeeded, 1
}

// window_grants gives one row for each requested grant that holds, in the order of their record: its number, the process that holds it, and its object. The result is the count of the grants, or a failure with its call outcome and an error record. The error kind: No_Grant (the caller does not act for the principal).
//
// **What it is for.** The menu of the windows lists the same grants under
// the window of their process, each with a button that revokes it. A
// caller reads them here, and revokes one with `revoke_grant`.
//
// **A row** (`Window_Grant_Row`):
//
// - `grant`: the number of the grant, from 1, never given twice in one run.
// - `window`: the name of the process, the title of its window.
// - `resource`: the object of the grant: an endpoint, or the store that
//   the principal picked with the mode that the process asked for.
//
// If the table of the caller has fewer places than grants, the last
// grants are missing, and the result still gives the count of all.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.window_grants()
// ```
@(export, link_name = "window_grants")
window_grants_export :: proc "c" (result: ^[]Window_Grant_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	for slot in 0 ..< min(window_grants.count, len(result^)) {
		grant := &window_grants.grants[slot]
		result[slot] = {grant = i64(grant.grant_id)}
		copy(result[slot].window[:len(result[slot].window) - 1], bar.window_grant_process(grant))
		copy(result[slot].resource[:len(result[slot].resource) - 1], bar.window_grant_resource(grant))
	}
	return .Succeeded, i64(window_grants.count)
}

// revoke_grant ends a requested grant by its number, as its button in the menu of the windows does. The result is 1, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Bad_Value (a number under 1); Absent (no grant of that number holds).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.revoke_grant(1)
// ```
@(export, link_name = "revoke_grant")
revoke_grant_export :: proc "c" (grant_id: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if grant_id < 1 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Grants, 1, grant_id)
	}
	if !window_grant_revoke(u64(grant_id)) {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Grants, 1, grant_id)
	}
	return .Succeeded, 1
}

// plan_diff_ask shows the difference of a plan on the trusted display: its name, and a memory object that holds the grants and roles that it adds, then the ones that it removes, each a list of items that line feeds separate, of any count, an item at most 384 bytes of UTF-8 with no control byte, shown in lines of 53 characters. The caller gives the object through the call ring of its connection, with Read only; `difference` is that handle as the display names it, and the display keeps it until it read the object. The dialog shows at once, with "Reading the difference"; a worker of the display reads the lines. The principal accepts or refuses it whole; the log says the decision. The result is the serial of the dialog, or a failure with its call outcome and an error record. The error kinds: No_Grant (Grant_Or_Right_Missing: the caller does not act for the principal); Busy (Callee_Busy: a dialog of the trusted display shows); Empty (Argument_Refused: no name, or nothing added and nothing removed); Too_Long (Argument_Refused: a name past 48 bytes); Bad_Value (Argument_Refused, argument 2: the object did not come through the ring of the caller, is no memory object, holds another right than Read, or has other pages than its two sides). An empty item, an item past 384 bytes or an item that is not UTF-8 or holds a control byte, which the worker finds, ends the dialog with no decision: a poll gives unknown (3).
//
// **The act.** The focus starts on Refuse. An act counts 500 ms after the
// dialog showed: Enter acts on the button that has the focus, Tab, Left and
// Right move it, a press on a button acts on it. Escape refuses at once.
// Up, Down, Page Up and Page Down scroll the items; with more items than the
// view holds, Accept counts only once the view showed the last one.
// While the dialog shows, no window receives a key or a press.
//
// **Grant**: the caller must be the holder of the role Plans, which the
// root service names in the amount of its grant, or **act for the
// principal**; else the error kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.plan_diff_ask("home", difference, 22, 14)
// ```
@(export, link_name = "plan_diff_ask")
plan_diff_ask_export :: proc "c" (plan_name: ^string, difference: i64, added_bytes: i64, removed_bytes: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	memory := difference > 0 && difference <= i64(max(u32)) ? system.Handle(difference) : 0
	if !plan_display_caller() || plan_name == nil {
		// The object that a refused caller gave is not kept.
		if caller := system.service_caller(); caller != nil && memory != 0 {
			if _, _, through := system.handle_state(memory, caller.ring_memory); through {
				system.close(memory)
			}
		}
		if plan_name == nil {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
		}
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	serial, refusal, argument := plan_difference_show(plan_name^, memory, added_bytes, removed_bytes)
	switch refusal {
	case .Not_A_Difference:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, i64(argument), difference)
	case .None:
		return .Succeeded, i64(serial)
	case .Busy:
		return call_outcome.fail(error, .Callee_Busy, .Busy, .Requests, 0, 1, 1)
	case .Empty_Name:
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1, 0, bar.PLAN_DIFFERENCE_NAME_BYTES)
	case .Name_Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(plan_name^)), bar.PLAN_DIFFERENCE_NAME_BYTES)
	case .No_Change:
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Records, i64(argument))
	case .Empty_Item:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, i64(argument))
	case .Item_Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, i64(argument), 0, bar.PLAN_DIFFERENCE_ITEM_BYTES)
	case .Too_Many_Items:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Records, i64(argument))
	case .Item_Not_Text:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Byte, .Bytes, i64(argument))
	case .Not_A_Name, .Not_An_Act, .No_Grant, .Bad_Serial:
		// The plan face checks no identifier, and its caller is checked
		// above: only the act face and a poll give these.
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused)
}

// plan_diff_poll gives the decision of the principal on the difference that plan_diff_ask showed with a serial: 0 while the dialog shows, 1 accepted, 2 refused, 3 unknown (a later dialog replaced it, or no dialog had the serial). The values are the members of plans_recipes.Plan_Display_Decision. The result is the decision, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Bad_Value (a serial under 1).
//
#assert(bar.PLAN_DIFFERENCE_NAME_BYTES == pr.PLAN_DISPLAY_NAME_BYTES)
#assert(bar.PLAN_DIFFERENCE_ITEM_BYTES == pr.PLAN_DISPLAY_ITEM_BYTES)

// Return the principal's decision for a trusted plan difference dialog.
//
// **What it is for.** The service plans asks for a difference, then reads
// the decision here, and commits the plan only when the principal accepted
// it on the trusted display. The dialog keeps the decision of the last
// dialog only.
//
// **Grant**: the caller must be the holder of the role Plans, which the
// root service names in the amount of its grant, or **act for the
// principal**; else the error kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.plan_diff_poll(1)
// ```
@(export, link_name = "plan_diff_poll")
plan_diff_poll_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// The decision on an act is no decision on a plan.
	caller := bar.Plan_Difference_Caller{allowed = plan_display_caller(), is_asker = true}
	decision, known, refusal := bar.plan_difference_poll(&plan_difference_dialog, .Plan, caller, serial)
	return dialog_poll_result(decision, known, refusal, serial, error)
}

// dialog_poll_result gives the result of plan_diff_poll and act_poll: the
// word of the decision, or the record of a refusal.
@(private = "file")
dialog_poll_result :: proc "contextless" (decision: bar.Plan_Difference_Decision, known: bool, refusal: bar.Plan_Difference_Refusal, serial: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	switch refusal {
	case .None:
	case .No_Grant:
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	case .Bad_Serial:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, serial, max(i64))
	case .Busy, .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Item_Not_Text, .Not_A_Name, .Not_An_Act, .Not_A_Difference:
		// A poll shows nothing: it gives none of the refusals of a show.
		return call_outcome.fail(error, .Argument_Refused, .Refused)
	}
	if !known {
		return .Succeeded, i64(pr.Plan_Display_Decision.Unknown)
	}
	switch decision {
	case .Pending:
		return .Succeeded, i64(pr.Plan_Display_Decision.Pending)
	case .Accepted:
		return .Succeeded, i64(pr.Plan_Display_Decision.Accepted)
	case .Refused:
		return .Succeeded, i64(pr.Plan_Display_Decision.Refused)
	}
	return .Succeeded, i64(pr.Plan_Display_Decision.Unknown)
}

// act_display_caller gives the facts of the caller of the act export that
// runs: it may ask an act (the amount of an asker of acts, or the grant to
// act for its principal), and it is the asker of the last dialog. A call
// from no connection may not ask: the asker is the name of a connection.
@(private = "file")
act_display_caller :: proc "contextless" () -> bar.Plan_Difference_Caller {
	caller := system.service_caller()
	if caller == nil {
		return {}
	}
	return {allowed = pr.act_display_caller_allowed(caller.grant), is_asker = dialog_asker_is(caller)}
}

// act_ask shows one act of an agent on the trusted display, for the principal to allow once or refuse: the asker, which is the name of the calling process, and the act, `service.export`. The result is the serial of the dialog, or a failure with its call outcome and an error record. The error kinds: No_Grant (Grant_Or_Right_Missing: the caller may not ask an act, or the call comes from no connection); Busy (Callee_Busy: a dialog of the trusted display shows); Bad_Value (Argument_Refused: the act is not two identifiers with a period between them, or, with the argument 0, the name of the caller is no identifier).
//
// **What it is for.** An agent proposes acts to the principal through a
// window such as the assistant (src/md/features/assistant.md, "The act
// dialog"). An act that the bridge stops needs a decision that the agent
// cannot give: this dialog. It shows no word of the agent: the asker comes
// from the connection, and the act is two identifiers that it checks.
//
// **The act.** The focus starts on Refuse, and Enter acts on the button
// that has it 500 ms after the dialog showed. Tab and the arrows move the
// focus only after that time, and each move starts the time again; a press
// on the other button moves the focus the same way, and a press on the
// button that has it acts. Escape refuses at once. The dialog closes with
// a refusal when the connection of its asker ends.
//
// **Grant**: the caller must have the right to **ask an act**, which the
// root service names in the amount of its grant, or **act for the
// principal**; else the error kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// compositor.act_ask("plans.apply")
// ```
@(export, link_name = "act_ask")
act_ask_export :: proc "c" (act: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	serial, refusal, argument := act_dialog_show(system.service_caller(), act_display_caller(), act^)
	switch refusal {
	case .None:
		return .Succeeded, i64(serial)
	case .No_Grant:
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	case .Busy:
		return call_outcome.fail(error, .Callee_Busy, .Busy, .Requests, 0, 1, 1)
	case .Not_A_Name, .Not_An_Act:
		// The argument of the export is the act; the asker is no argument.
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, i64(argument == 2 ? 1 : 0), i64(len(act^)), bar.PLAN_DIFFERENCE_ITEM_BYTES)
	case .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Item_Not_Text, .Bad_Serial, .Not_A_Difference:
		// The act face gives none of the refusals of a plan or of a poll.
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused)
}

// act_poll gives the decision of the principal on the act that act_ask showed with a serial, to the connection that asked: 0 while the dialog shows, 1 allowed, 2 refused, 3 unknown (a later dialog replaced it, no dialog had the serial, it was the dialog of a plan, or another connection asked for it). The result is the decision, or a failure with its call outcome and an error record. The error kinds: No_Grant (Grant_Or_Right_Missing: the caller may not ask an act, or the call comes from no connection); Bad_Value (Argument_Refused: a serial under 1).
//
// **Grant**: the caller must have the right to **ask an act**, or **act
// for the principal**; else the error kind `No_Grant`, with the call
// outcome Grant_Or_Right_Missing.
//
// ```
// compositor.act_poll(1)
// ```
@(export, link_name = "act_poll")
act_poll_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	decision, known, refusal := bar.plan_difference_poll(&plan_difference_dialog, .Act, act_display_caller(), serial)
	return dialog_poll_result(decision, known, refusal, serial, error)
}

// act_cancel closes the act dialog that act_ask showed with a serial with a refusal, for the connection that asked: the agent withdrew the act. The result is 1 when the dialog closed, 0 when no act dialog of the caller with that serial shows, or a failure with its call outcome and an error record. The error kinds: No_Grant (Grant_Or_Right_Missing: the caller may not ask an act, or the call comes from no connection); Bad_Value (Argument_Refused: a serial under 1).
//
// **What it is for.** A window that asked for an act dialog and no longer
// shows the act, as when the entry of the act leaves its conversation,
// closes the dialog: the principal never decides an act that the window
// does not show.
//
// **Grant**: the caller must have the right to **ask an act**, or **act
// for the principal**; else the error kind `No_Grant`, with the call
// outcome Grant_Or_Right_Missing.
//
// ```
// compositor.act_cancel(1)
// ```
@(export, link_name = "act_cancel")
act_cancel_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	closed, refusal := bar.plan_difference_act_cancel(&plan_difference_dialog, act_display_caller(), serial)
	switch refusal {
	case .None:
	case .No_Grant:
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	case .Bad_Serial:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, serial, max(i64))
	case .Busy, .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Item_Not_Text, .Not_A_Name, .Not_An_Act, .Not_A_Difference:
		return call_outcome.fail(error, .Argument_Refused, .Refused)
	}
	if !closed {
		return .Succeeded, 0
	}
	act_dialog_cancelled()
	return .Succeeded, 1
}

// assistive_attach records a holder of the assistive role, which reads the semantic trees of the windows from here on, and gives its number. The bar shows a mark in the warning color with the word assistive and the nickname while it reads. The result is the number of the holder, or a failure with its call outcome and an error record. The error kinds: No_Grant (Grant_Or_Right_Missing: the caller does not act for the principal); Empty (Argument_Refused: no nickname); Too_Long (Argument_Refused: a nickname past 31 bytes); Bad_Value (Argument_Refused: a nickname with a control byte or a damaged character, or a kind that names no holder: 1 screen reader, 2 magnifier, 3 switch input); Full (Callee_Busy: 4 holders read already).
//
// **Several holders at once.** A principal with low vision uses a
// magnifier and a screen reader together, so each holder has its own
// number and its own mark.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.assistive_attach("screen_reader", 1)
// ```
@(export, link_name = "assistive_attach")
assistive_attach_export :: proc "c" (nickname: ^string, kind_word: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	kind, known := bar.assistive_holder_kind_of_word(u64(kind_word))
	if kind_word < 0 || !known || kind == .None {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, kind_word, i64(max(bar.Assistive_Holder_Kind)))
	}
	id, refusal := assistive_holder_attach(nickname^, kind)
	switch refusal {
	case .None:
		return .Succeeded, i64(id)
	case .Kind_None:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2, kind_word, i64(max(bar.Assistive_Holder_Kind)))
	case .Empty_Nickname:
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1, 0, bar.ASSISTIVE_NICKNAME_BYTES)
	case .Nickname_Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(nickname^)), bar.ASSISTIVE_NICKNAME_BYTES)
	case .Nickname_Invalid:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, 1)
	case .Full:
		return call_outcome.fail(error, .Callee_Busy, .Full, .Records, 0, 0, bar.ASSISTIVE_HOLDER_LIMIT)
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused)
}

// assistive_detach ends a holder of the assistive role by its number. Its mark leaves the bar; with the last holder, a magnification that a holder asked for ends too. The result is 1, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Bad_Value (a number under 1); Absent (no holder of that number reads).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.assistive_detach(1)
// ```
@(export, link_name = "assistive_detach")
assistive_detach_export :: proc "c" (holder_id: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if holder_id < 1 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, holder_id)
	}
	if !assistive_holder_detach(u64(holder_id)) {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Records, 1, holder_id)
	}
	return .Succeeded, 1
}

// assistive_holders gives one row for each holder of the assistive role that reads the trees, in the order of their marks from the right: its number, its kind and its nickname. The result is the count of the holders, or a failure with its call outcome and an error record. The error kind: No_Grant (the caller does not act for the principal).
//
// If the table of the caller has fewer places than holders, the last
// holders are missing, and the result still gives the count of all.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.assistive_holders()
// ```
@(export, link_name = "assistive_holders")
assistive_holders_export :: proc "c" (result: ^[]Assistive_Holder_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	row := 0
	for &holder in assistive_registry.holders {
		if !holder.active {
			continue
		}
		if row < len(result^) {
			result[row] = {holder = i64(holder.id)}
			copy(result[row].kind[:len(result[row].kind) - 1], ASSISTIVE_HOLDER_KIND_NAMES[holder.kind])
			copy(result[row].nickname[:len(result[row].nickname) - 1], bar.assistive_holder_nickname(&holder))
		}
		row += 1
	}
	return .Succeeded, i64(row)
}

// assistive_magnify draws a rectangle of the screen larger, over the whole screen, for a holder of the assistive role: the view centers on the rectangle when it fits, else it starts at its left and top edges. The rectangle is in logical pixels; the factor is in eighths, from 12 (1.5 times) to 64 (8 times). No pixel leaves the compositor. The result is 1, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Absent (no assistive holder reads, so no mark would explain the magnification); Bad_Value (a factor past its bounds, or a width or a height under 1); Out_Of_Range (a part of the rectangle is off the screen: argument 1 for the left and the width, 2 for the top and the height).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.assistive_magnify(100, 80, 200, 24, 16)
// ```
@(export, link_name = "assistive_magnify")
assistive_magnify_export :: proc "c" (left, top, width, height, factor_eighths: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	screen_width, screen_height := i64(desktop_width), i64(desktop_height)
	switch bar.assistive_magnify_check(&assistive_registry, left, top, width, height, factor_eighths, screen_width, screen_height) {
	case .None:
		assistive_magnify_start(left, top, width, height, factor_eighths)
		return .Succeeded, 1
	case .No_Holder:
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Records)
	case .Factor_Out_Of_Range:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 5, factor_eighths, bar.ASSISTIVE_MAGNIFY_FACTOR_MOST)
	case .Empty_Rectangle:
		if width < 1 {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, width)
		}
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 4, height)
	case .Outside_Screen:
		if left < 0 || width > screen_width || left > screen_width - width {
			return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .None, 1, left, screen_width)
		}
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .None, 2, top, screen_height)
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused)
}

// assistive_magnify_end ends the magnification that a holder of the assistive role asked for. The result is 1 when a magnification ended, 0 when none was on, or a failure with its call outcome and an error record. The error kinds: No_Grant (the caller does not act for the principal); Absent (no assistive holder reads).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the call outcome Grant_Or_Right_Missing.
//
// ```
// connect("compositor")
// compositor.assistive_magnify_end()
// ```
@(export, link_name = "assistive_magnify_end")
assistive_magnify_end_export :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if !bar.assistive_mark_shown(&assistive_registry) {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Records)
	}
	if !assistive_magnifying {
		return .Succeeded, 0
	}
	assistive_magnify_stop()
	return .Succeeded, 1
}
