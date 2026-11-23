package compositor

import "internal:compositor/bar"
import "modus:contract/desktop_shell"
import "modus:contract/errors"
import "modus:contract/isolated"
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
	attached:          i64, // 1: compositor framebuffer attached to VirtIO-GPU scanout.
	width:             i64, // Reported VirtIO-GPU scanout width in pixels.
	height:            i64, // Reported VirtIO-GPU scanout height in pixels.
	venus:             i64, // 1: host VirtIO-GPU exposes a Venus Vulkan capability set.
	venus_max_version: i64, // Highest Venus capset version reported by the host.
	presents:          i64, // Number of Present_Rect flushes completed on VirtIO-GPU.
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

ERROR_ACTS_FOR_PRINCIPAL :: -1

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

// pointer gives the place of the pointer on the screen, its buttons, the menu of the bar that is open, the state of the palette, and the name of the pointer shape, as one row. The result is 1, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
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
// it gets the error kind `No_Grant`, with the result -1: the place of the
// pointer tells where the input goes.
//
// ```
// connect("compositor")
// compositor.pointer()
// ```
@(export, link_name = "pointer")
pointer :: proc "c" (result: ^[]Pointer, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
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
	return 1
}

// windows gives one row for each window, the front one first: its title, its place and its size with the frame, its order from the front, whether it has the focus, and whether the keys go to it. The result is the count of rows, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
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
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// where(compositor.windows(), focus = 1)
// ```
@(export, link_name = "windows")
windows :: proc "c" (result: ^[]Window, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
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
	return i64(order_count)
}

// screen gives the frames that the compositor drew, the Present records that it received, the damage rectangles that wait for the next frame, whether a change of the desktop itself waits, and how its frames reached the screen, as one row. The result is 1, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
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
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.screen()
// ```
@(export, link_name = "screen")
screen_state :: proc "c" (result: ^[]Screen, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {frames = i64(frames), presents = i64(presents), damage = i64(damage_count), desktop = desktop_change_waits ? 1 : 0, page_flips = i64(page_flips), frames_on_the_shown_page = i64(frames_on_the_shown_page)}
	}
	return 1
}

// notify posts a non-focus-stealing desktop notification card in the top-right
// corner below the bar and returns its assigned notification identifier, or a
// negative number with an error record.
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
notify_export :: proc "c" (title: ^string, body: ^string, error: ^errors.Error_Record) -> i64 {
	if len(title^) == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1)
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
			return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 0, 0, notifications.MAX_LABEL_BYTES)
		}
		source = notifications.source_of_caller_name(name)
		label = transmute([]u8)name
		cards_limit = notifications.CARDS_PER_SOURCE_LIMIT
	}
	id, refusal := desktop_notification_post(source, .Normal, system.time(), transmute([]u8)(title^), transmute([]u8)(body^), label, cards_limit)
	switch refusal {
	case .None:
		return i64(id)
	case .Source_Full:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Full, .Requests, 0, 0, notifications.CARDS_PER_SOURCE_LIMIT, i64(notifications.source_card_count(&desktop_notifications, source)))
	case .Empty_Title:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1)
	case .Title_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 1, i64(len(title^)), notifications.MAX_TITLE_BYTES)
	case .Body_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 2, i64(len(body^)), notifications.MAX_BODY_BYTES)
	case .Label_Too_Long:
		// The root service names a process in 32 bytes at most: no name
		// of a connection is longer.
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 0, i64(len(label)), notifications.MAX_LABEL_BYTES)
	case .Queue_Full:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Full, .Records, 0, 0, notifications.MAX_NOTIFICATIONS, notifications.MAX_NOTIFICATIONS)
	case .Rate_Limited:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Busy, .Milliseconds, 0, 0, i64(desktop_notifications.min_interval_ms))
	case .Suppressed, .Nil_Queue, .Not_Found:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .None)
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .None)
}

// magnifier sets the desktop viewport magnifier zoom factor in eighths
// (0 disables; 12 to 64 enables 1.5x to 8x zoom centered on the pointer) and
// returns 1 on success, or a negative number with an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "magnifier")
magnifier_export :: proc "c" (zoom_eighths: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if zoom_eighths < 0 || zoom_eighths > 64 || (zoom_eighths != 0 && zoom_eighths < 12) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Out_Of_Range, .Counts, 1, zoom_eighths, 64)
	}
	if !desktop_magnifier_set(u16(zoom_eighths), i32(pointer_x), i32(pointer_y)) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Counts, 1, zoom_eighths)
	}
	return 1
}

// powerbox_ask opens an unforgeable trusted-display grant request dialog for a
// process requesting a network endpoint or store and returns the request ID, or
// a negative number with an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "powerbox_ask")
powerbox_ask_export :: proc "c" (process_name: ^string, resource: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if plan_difference_dialog.open {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Busy, .Requests, 0, 1, 1)
	}
	id := powerbox_prompt_open(.Network_Endpoint, process_name^, resource^)
	if id == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1)
	}
	return i64(id)
}

// The one process that may clear the wide-grant indicator through this
// export: the collector, which ends each wide grant.
WIDE_GRANT_INDICATOR_CLEARER :: "collector"

// wide_grant_indicator shows (active == 1) or clears (active == 0) the
// unforgeable wide-grant indicator badge in the top bar and returns 1, or a
// negative number with an error record.
//
// A wide grant lets an agent see and drive the screen: the indicator is how
// the principal knows. So a caller that can show the indicator cannot clear
// it: only the collector clears it, and the one-press revocation key clears
// it on the local keyboard. Any other caller, remote or local, gets
// No_Grant with the unit Grants when it clears an indicator that shows.
//
// **Grant**: the caller must **act for the principal** to show the
// indicator, and must be the collector to clear it.
@(export, link_name = "wide_grant_indicator")
wide_grant_indicator_export :: proc "c" (active: i64, grant_id: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if active != 0 && active != 1 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Counts, 1, active, 1)
	}
	if grant_id < 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Out_Of_Range, .Counts, 2, grant_id)
	}
	if active == 0 && wide_grant_display.active {
		caller := system.service_caller()
		if caller != nil && system.name_of(caller.caller[:]) != WIDE_GRANT_INDICATOR_CLEARER {
			return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Grants)
		}
	}
	wide_grant_mark_set(active == 1, u64(grant_id))
	return 1
}

// set_decoration switches a window between default server decorations (0) and
// borderless client-side decorations (1), returning 1 on success or a negative
// number with an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "set_decoration")
set_decoration_export :: proc "c" (window_order: i64, mode: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	dec, ok := desktop_shell.window_decoration_of_word(u64(mode))
	if mode < 0 || !ok {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Counts, 2, mode)
	}
	if window_order < 0 || int(window_order) >= order_count {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Out_Of_Range, .Counts, 1, window_order, i64(order_count))
	}
	idx := order[order_count - 1 - int(window_order)]
	clients[idx].decoration = dec
	damage_whole_screen()
	return 1
}

// open_context_menu opens the filterable fuzzy desktop context menu at (x, y)
// and returns 1, or a negative number with an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "open_context_menu")
open_context_menu_export :: proc "c" (x: i64, y: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	desktop_context_menu_open(int(x), int(y))
	return 1
}

// powerbox_pick_store opens the unforgeable trusted-display Store Picker dialog
// for a requesting process (which never sees the store list) and returns the
// request ID, or a negative number with an error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "powerbox_pick_store")
powerbox_pick_store_export :: proc "c" (process_name: ^string, mode: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if plan_difference_dialog.open {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Busy, .Requests, 0, 1, 1)
	}
	caller := system.service_caller()
	principal := caller == nil ? 0 : isolated.caller_principal(caller.grant)
	id := powerbox_prompt_open(.Store_Share, process_name^, mode^, principal)
	if id == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1)
	}
	return i64(id)
}

// bar_position moves the bar of the desktop to Top (1) or Bottom (2), and
// returns 1, or a negative number with an error record. Left (3) and Right
// (4) are taken and keep the bar at the top: the compositor draws no
// vertical bar yet (src/md/features/bar_edge.md).
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "bar_position")
bar_position_export :: proc "c" (pos_word: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	pos, ok := desktop_shell.bar_position_of_word(u64(pos_word))
	if pos_word <= 0 || !ok {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Counts, 1, pos_word)
	}
	desktop_bar_position_set(pos)
	return 1
}

// tray_widget_open opens the card of a tray widget, as a press on its part of the bar does, or closes the card that is open: 0 closes, 1 the control center, 2 the notification center, 3 the calendar. Opening a card closes the start menu, the menu of the windows, the list of the viewers and the context menu of the desktop. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Bad_Value (-1, a word that names no tray widget).
//
// The field `menu` of `pointer()` names the open card: `control_center`,
// `notifications` or `calendar` (src/md/features/tray_widgets.md).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.tray_widget_open(3)
// ```
@(export, link_name = "tray_widget_open")
tray_widget_open_export :: proc "c" (widget_word: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	widget, known := bar.tray_widget_of_word(u64(widget_word))
	if widget_word < 0 || !known {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 1, widget_word, i64(max(bar.Tray_Widget)))
	}
	tray_widget_show(widget) // tray_widgets.odin
	return 1
}

// gpu_info returns one row describing the VirtIO-GPU 1.2 scanout and Venus
// capability state discovered by the compositor, or a negative number with an
// error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "gpu_info")
gpu_info_export :: proc "c" (result: ^[]Gpu_Info, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
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
		}
	}
	return 1
}

// window_grants gives one row for each requested grant that holds, in the order of their record: its number, the process that holds it, and its object. The result is the count of the grants, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
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
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.window_grants()
// ```
@(export, link_name = "window_grants")
window_grants_export :: proc "c" (result: ^[]Window_Grant_Row, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	for slot in 0 ..< min(window_grants.count, len(result^)) {
		grant := &window_grants.grants[slot]
		result[slot] = {grant = i64(grant.grant_id)}
		copy(result[slot].window[:len(result[slot].window) - 1], bar.window_grant_process(grant))
		copy(result[slot].resource[:len(result[slot].resource) - 1], bar.window_grant_resource(grant))
	}
	return i64(window_grants.count)
}

// revoke_grant ends a requested grant by its number, as its button in the menu of the windows does. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Bad_Value (-1, a number under 1); Absent (-1, no grant of that number holds).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.revoke_grant(1)
// ```
@(export, link_name = "revoke_grant")
revoke_grant_export :: proc "c" (grant_id: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if grant_id < 1 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Grants, 1, grant_id)
	}
	if !window_grant_revoke(u64(grant_id)) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .Grants, 1, grant_id)
	}
	return 1
}

// plan_diff_ask shows the difference of a plan on the trusted display: its name, the grants and roles that it adds, and the ones that it removes, each a list of names that commas separate, as bytes of any count. The principal accepts or refuses it whole; the log says the decision. The result is the serial of the dialog, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Busy (-1, a dialog of the trusted display shows); Empty (-1, no name, or nothing added and nothing removed); Too_Long (-1, a name or an item past 48 bytes); Bad_Value (-1, an empty item in a list); Budget (-1, the budget of the display pays no memory for the items).
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
// principal**; else the error kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.plan_diff_ask("home", "notes: store documents", "paint: network")
// ```
@(export, link_name = "plan_diff_ask")
plan_diff_ask_export :: proc "c" (plan_name: ^string, added: ^system.Bytes_To_Read, removed: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	if !plan_display_caller() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if plan_name == nil || added == nil || removed == nil {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Address, .None, plan_name == nil ? 1 : added == nil ? 2 : 3)
	}
	// The call host checked each place against the memory that it mapped.
	added_bytes := added.bytes[:min(added.count, added.capacity)]
	removed_bytes := removed.bytes[:min(removed.count, removed.capacity)]
	serial, refusal, argument := plan_difference_show(plan_name^, added_bytes, removed_bytes)
	switch refusal {
	case .None:
		return i64(serial)
	case .Busy:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Busy, .Requests, 0, 1, 1)
	case .Empty_Name:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1, 0, bar.PLAN_DIFFERENCE_NAME_BYTES)
	case .Name_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 1, i64(len(plan_name^)), bar.PLAN_DIFFERENCE_NAME_BYTES)
	case .No_Change:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Records, i64(argument))
	case .Empty_Item:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Bytes, i64(argument))
	case .Item_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, i64(argument), 0, bar.PLAN_DIFFERENCE_ITEM_BYTES)
	case .Too_Many_Items:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Budget, .Records, i64(argument))
	case .Not_A_Name, .Not_An_Act, .No_Grant, .Bad_Serial:
		// The plan face checks no identifier, and its caller is checked
		// above: only the act face and a poll give these.
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
}

// plan_diff_poll gives the decision of the principal on the difference that plan_diff_ask showed with a serial: 0 while the dialog shows, 1 accepted, 2 refused, 3 unknown (a later dialog replaced it, or no dialog had the serial). The values are the members of plans_recipes.Plan_Display_Decision. The result is the decision, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Bad_Value (-1, a serial under 1).
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
// principal**; else the error kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.plan_diff_poll(1)
// ```
@(export, link_name = "plan_diff_poll")
plan_diff_poll_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> i64 {
	// The decision on an act is no decision on a plan.
	caller := bar.Plan_Difference_Caller{allowed = plan_display_caller(), is_asker = true}
	decision, known, refusal := bar.plan_difference_poll(&plan_difference_dialog, .Plan, caller, serial)
	return dialog_poll_result(decision, known, refusal, serial, error)
}

// dialog_poll_result gives the result of plan_diff_poll and act_poll: the
// word of the decision, or the record of a refusal.
@(private = "file")
dialog_poll_result :: proc "contextless" (decision: bar.Plan_Difference_Decision, known: bool, refusal: bar.Plan_Difference_Refusal, serial: i64, error: ^errors.Error_Record) -> i64 {
	switch refusal {
	case .None:
	case .No_Grant:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	case .Bad_Serial:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Records, 1, serial, max(i64))
	case .Busy, .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Not_A_Name, .Not_An_Act:
		// A poll shows nothing: it gives none of the refusals of a show.
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
	}
	if !known {
		return i64(pr.Plan_Display_Decision.Unknown)
	}
	switch decision {
	case .Pending:
		return i64(pr.Plan_Display_Decision.Pending)
	case .Accepted:
		return i64(pr.Plan_Display_Decision.Accepted)
	case .Refused:
		return i64(pr.Plan_Display_Decision.Refused)
	}
	return i64(pr.Plan_Display_Decision.Unknown)
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

// act_ask shows one act of an agent on the trusted display, for the principal to allow once or refuse: the asker, which is the name of the calling process, and the act, `service.export`. The result is the serial of the dialog, or a negative number with an error record. The error kinds: No_Grant (-1, the caller may not ask an act, or the call comes from no connection); Busy (-1, a dialog of the trusted display shows); Bad_Value (-1, the act is not two identifiers with a period between them, or the name of the caller is no identifier).
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
// principal**; else the error kind `No_Grant`, with the result -1.
//
// ```
// compositor.act_ask("plans.apply")
// ```
@(export, link_name = "act_ask")
act_ask_export :: proc "c" (act: ^string, error: ^errors.Error_Record) -> i64 {
	serial, refusal, argument := act_dialog_show(system.service_caller(), act_display_caller(), act^)
	switch refusal {
	case .None:
		return i64(serial)
	case .No_Grant:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	case .Busy:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Busy, .Requests, 0, 1, 1)
	case .Not_A_Name, .Not_An_Act:
		// The argument of the export is the act; the asker is no argument.
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Bytes, i64(argument == 2 ? 1 : 0), i64(len(act^)), bar.PLAN_DIFFERENCE_ITEM_BYTES)
	case .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Bad_Serial:
		// The act face gives none of the refusals of a plan or of a poll.
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
}

// act_poll gives the decision of the principal on the act that act_ask showed with a serial, to the connection that asked: 0 while the dialog shows, 1 allowed, 2 refused, 3 unknown (a later dialog replaced it, no dialog had the serial, it was the dialog of a plan, or another connection asked for it). The result is the decision, or a negative number with an error record. The error kinds: No_Grant (-1, the caller may not ask an act, or the call comes from no connection); Bad_Value (-1, a serial under 1).
//
// **Grant**: the caller must have the right to **ask an act**, or **act
// for the principal**; else the error kind `No_Grant`, with the result
// -1.
//
// ```
// compositor.act_poll(1)
// ```
@(export, link_name = "act_poll")
act_poll_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> i64 {
	decision, known, refusal := bar.plan_difference_poll(&plan_difference_dialog, .Act, act_display_caller(), serial)
	return dialog_poll_result(decision, known, refusal, serial, error)
}

// act_cancel closes the act dialog that act_ask showed with a serial with a refusal, for the connection that asked: the agent withdrew the act. The result is 1 when the dialog closed, 0 when no act dialog of the caller with that serial shows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller may not ask an act, or the call comes from no connection); Bad_Value (-1, a serial under 1).
//
// **What it is for.** A window that asked for an act dialog and no longer
// shows the act, as when the entry of the act leaves its conversation,
// closes the dialog: the principal never decides an act that the window
// does not show.
//
// **Grant**: the caller must have the right to **ask an act**, or **act
// for the principal**; else the error kind `No_Grant`, with the result
// -1.
//
// ```
// compositor.act_cancel(1)
// ```
@(export, link_name = "act_cancel")
act_cancel_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> i64 {
	closed, refusal := bar.plan_difference_act_cancel(&plan_difference_dialog, act_display_caller(), serial)
	switch refusal {
	case .None:
	case .No_Grant:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	case .Bad_Serial:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Records, 1, serial, max(i64))
	case .Busy, .Empty_Name, .Name_Too_Long, .No_Change, .Empty_Item, .Item_Too_Long, .Too_Many_Items, .Not_A_Name, .Not_An_Act:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
	}
	if !closed {
		return 0
	}
	act_dialog_cancelled()
	return 1
}

// assistive_attach records a holder of the assistive role, which reads the semantic trees of the windows from here on, and gives its number. The bar shows a mark in the warning color with the word assistive and the nickname while it reads. The result is the number of the holder, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Empty (-1, no nickname); Too_Long (-1, a nickname past 31 bytes); Bad_Value (-1, a nickname with a control byte or a damaged character, or a kind that names no holder: 1 screen reader, 2 magnifier, 3 switch input); Full (-1, 4 holders read already).
//
// **Several holders at once.** A principal with low vision uses a
// magnifier and a screen reader together, so each holder has its own
// number and its own mark.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.assistive_attach("screen_reader", 1)
// ```
@(export, link_name = "assistive_attach")
assistive_attach_export :: proc "c" (nickname: ^string, kind_word: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	kind, known := bar.assistive_holder_kind_of_word(u64(kind_word))
	if kind_word < 0 || !known || kind == .None {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 2, kind_word, i64(max(bar.Assistive_Holder_Kind)))
	}
	id, refusal := assistive_holder_attach(nickname^, kind)
	switch refusal {
	case .None:
		return i64(id)
	case .Kind_None:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 2, kind_word, i64(max(bar.Assistive_Holder_Kind)))
	case .Empty_Nickname:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Empty, .Bytes, 1, 0, bar.ASSISTIVE_NICKNAME_BYTES)
	case .Nickname_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 1, i64(len(nickname^)), bar.ASSISTIVE_NICKNAME_BYTES)
	case .Nickname_Invalid:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Bytes, 1)
	case .Full:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Full, .Records, 0, 0, bar.ASSISTIVE_HOLDER_LIMIT)
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
}

// assistive_detach ends a holder of the assistive role by its number. Its mark leaves the bar; with the last holder, a magnification that a holder asked for ends too. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Bad_Value (-1, a number under 1); Absent (-1, no holder of that number reads).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.assistive_detach(1)
// ```
@(export, link_name = "assistive_detach")
assistive_detach_export :: proc "c" (holder_id: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if holder_id < 1 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .Records, 1, holder_id)
	}
	if !assistive_holder_detach(u64(holder_id)) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .Records, 1, holder_id)
	}
	return 1
}

// assistive_holders gives one row for each holder of the assistive role that reads the trees, in the order of their marks from the right: its number, its kind and its nickname. The result is the count of the holders, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// If the table of the caller has fewer places than holders, the last
// holders are missing, and the result still gives the count of all.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.assistive_holders()
// ```
@(export, link_name = "assistive_holders")
assistive_holders_export :: proc "c" (result: ^[]Assistive_Holder_Row, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
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
	return i64(row)
}

// assistive_magnify draws a rectangle of the screen larger, over the whole screen, for a holder of the assistive role: the view centers on the rectangle when it fits, else it starts at its left and top edges. The rectangle is in logical pixels; the factor is in eighths, from 12 (1.5 times) to 64 (8 times). No pixel leaves the compositor. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Absent (-1, no assistive holder reads, so no mark would explain the magnification); Bad_Value (-1, a factor past its bounds, or a width or a height under 1); Out_Of_Range (-1, a part of the rectangle is off the screen: argument 1 for the left and the width, 2 for the top and the height).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.assistive_magnify(100, 80, 200, 24, 16)
// ```
@(export, link_name = "assistive_magnify")
assistive_magnify_export :: proc "c" (left, top, width, height, factor_eighths: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	screen_width, screen_height := i64(desktop_width), i64(desktop_height)
	switch bar.assistive_magnify_check(&assistive_registry, left, top, width, height, factor_eighths, screen_width, screen_height) {
	case .None:
		assistive_magnify_start(left, top, width, height, factor_eighths)
		return 1
	case .No_Holder:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .Records)
	case .Factor_Out_Of_Range:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 5, factor_eighths, bar.ASSISTIVE_MAGNIFY_FACTOR_MOST)
	case .Empty_Rectangle:
		if width < 1 {
			return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 3, width)
		}
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 4, height)
	case .Outside_Screen:
		if left < 0 || width > screen_width || left > screen_width - width {
			return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Out_Of_Range, .None, 1, left, screen_width)
		}
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Out_Of_Range, .None, 2, top, screen_height)
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused)
}

// assistive_magnify_end ends the magnification that a holder of the assistive role asked for. The result is 1 when a magnification ended, 0 when none was on, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Absent (-1, no assistive holder reads).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.assistive_magnify_end()
// ```
@(export, link_name = "assistive_magnify_end")
assistive_magnify_end_export :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if !bar.assistive_mark_shown(&assistive_registry) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .Records)
	}
	if !assistive_magnifying {
		return 0
	}
	assistive_magnify_stop()
	return 1
}
