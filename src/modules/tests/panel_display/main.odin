// A minimal, barless second holder of the Display role
// (src/md/features/roles_and_contracts.md). It fills the full Display role
// contract (exports and rings) with zero bar height, giving every window a
// full-screen work area at scale 1 (1920x1080 on the reference screen).
//
// Only the plan_and_audit test image includes this module; the release boot
// image excludes it.
package panel_display

import "modus:contract/call_outcome"
import "modus:contract/desktop_shell"
import "modus:contract/display_choices"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/notifications"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:display"
import "modus:graphics"
import "modus:screen_presence"
import "modus:system"

// The tool counts the module, its load and its thread; no software backbuffer
// is allocated because pixels blit directly to screen, and client surfaces are
// paid by each client's budget.
MODULE_BUDGET :: system.Stated_Budget{processes = 1, threads = 1}

// Context slots passed by root display_holder_start.
GRANT_FRAMEBUFFER :: 0
GRANT_INPUT :: 1
GRANT_CONTROL :: 2
VALUE_WIDTH :: 0
VALUE_HEIGHT :: 1
VALUE_PIXELS_PER_LINE :: 2
VALUE_FORMAT :: 3
VALUE_FILE_ADDRESS :: 4
VALUE_FILE_SIZE :: 5
FORMAT_RED_FIRST :: 2

// Fixed window table capacity for the minimal test display holder.
CLIENT_CAPACITY :: 16

// Barless scale 1 gives windows the full pixel work area (1920x1080).
PANEL_SCALE :: scale_factor.Scale.Eight_Eighths

// Wait room sized for control, input, service + connections, and all clients.
WAIT_WORDS :: 2 + 2 + 2 * (1 + isolated.SERVICE_CONNECTION_CAPACITY) + 2 * CLIENT_CAPACITY
#assert(WAIT_WORDS <= op.WORD_WAIT_MOST)

Pointer :: struct {
	x:            i64,
	y:            i64,
	buttons:      i64,
	moves:        i64,
	keys:         i64,
	keys_waiting: i64,
	keys_refused: i64,
	menu:         [16]u8,
	palette:      i64,
	shape:        [32]u8,
	form:         [8]u8,
}

Window :: struct {
	title:                [32]u8,
	x:                    i64,
	y:                    i64,
	width:                i64,
	height:               i64,
	order:                i64,
	focus:                i64,
	keyboard:             i64,
	presents:             i64,
	waits:                i64,
	events_sent:          i64,
	events_unread:        i64,
	events_waiting:       i64,
	keys_refused:         i64,
	frames:               i64,
	pictures_drawn_again: i64,
	presents_refused:     i64,
	due:                  i64,
}

Screen :: struct {
	frames:                   i64,
	presents:                 i64,
	damage:                   i64,
	desktop:                  i64,
	page_flips:               i64,
	frames_on_the_shown_page: i64,
}

Setting_State :: struct {
	setting: i64,
	layer:   i64,
	value:   i64,
}

Client :: struct {
	ring_memory:          system.Handle,
	ring:                 ring.Ring,
	created:              bool,
	released:             bool,
	pictures:             [^]graphics.Color,
	pictures_memory:      system.Handle,
	surface:              graphics.Canvas,
	surface_serial:       u64,
	surface_scale:        scale_factor.Scale,
	shown:                int,
	width, height:        int,
	title:                system.Name,
	presents:             u64,
	frames:               u64,
	events_sent:          u64,
	pictures_drawn_again: u64,
	presents_refused:     u64,
	commands_refused:     u64,
	picture_due:          bool,
}

screen: graphics.Canvas
screen_of_memory: bool
red_first: bool
input: ring.Ring
control: ring.Ring
service: system.Service

clients: [CLIENT_CAPACITY]Client
order: [CLIENT_CAPACITY]int
order_count: int

pointer_x, pointer_y: int
buttons: u32
pointer_moves: u64
key_records: u64
total_frames: u64
total_presents: u64
frames_on_shown_page: u64

choices: display_choices.Choices = display_choices.CONTRACT_DEFAULTS
presentation_words: [settings.PRESENTATION_WORDS]u64

wait_words: [WAIT_WORDS]op.Word
wait_parts: [WAIT_WORDS]system.Wait_Part
wait_set: system.Wait_Set

@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

system_name_slice :: proc "contextless" (title: []u8) -> string {
	return system.name_of(title)
}

// pointer gives the current pointer coordinates and input counters as one row.
@(export, link_name = "pointer")
pointer :: proc "c" (result: ^[]Pointer, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {
			x       = i64(pointer_x),
			y       = i64(pointer_y),
			buttons = i64(buttons),
			moves   = i64(pointer_moves),
			keys    = i64(key_records),
		}
		copy(result[0].shape[:len(result[0].shape) - 1], "arrow")
		copy(result[0].form[:len(result[0].form) - 1], "dark")
	}
	return .Succeeded, 1
}

// windows gives one row per open window from front to back.
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
		result[row] = {
			x                    = 0,
			y                    = 0,
			width                = i64(client.width),
			height               = i64(client.height),
			order                = i64(row),
			focus                = row == 0 ? 1 : 0,
			keyboard             = row == 0 ? 1 : 0,
			presents             = i64(client.presents),
			events_sent          = i64(client.events_sent),
			events_unread        = i64(ring.count(&client.ring.completions)),
			frames               = i64(client.frames),
			pictures_drawn_again = i64(client.pictures_drawn_again),
			presents_refused     = i64(client.presents_refused),
			due                  = client.picture_due ? 1 : 0,
		}
		copy(result[row].title[:len(result[row].title) - 1], system.name_of(client.title[:]))
	}
	return .Succeeded, i64(order_count)
}

// screen gives the frame and present counts of the holder as one row.
@(export, link_name = "screen")
screen_state :: proc "c" (result: ^[]Screen, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {
			frames                   = i64(total_frames),
			presents                 = i64(total_presents),
			frames_on_the_shown_page = i64(frames_on_shown_page),
		}
	}
	return .Succeeded, 1
}

// set updates the Display role settings kept by this holder in memory.
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
	arguments := display_choices.Set_Arguments {
		bar_edge_presence, bar_edge,
		do_not_disturb_presence, do_not_disturb,
		notification_show_milliseconds_presence, notification_show_milliseconds,
		magnifier_eighths_presence, magnifier_eighths,
		consent_arm_milliseconds_presence, consent_arm_milliseconds,
	}
	changes, count, argument, problem := display_choices.changes_of_set(arguments)
	switch problem {
	case .None:
	case .Nothing_Given:
		return call_outcome.fail(error, .Argument_Refused, .Absent, .None, 0)
	case .Bad_Value:
		words := [5]i64{i64(bar_edge), i64(do_not_disturb), notification_show_milliseconds, magnifier_eighths, consent_arm_milliseconds}
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, i64(argument), words[argument - 1])
	}
	for change in changes[:count] {
		switch change.name {
		case "bar_edge":
			if edge, ok := desktop_shell.bar_position_of_word(change.value); ok {
				choices.bar_edge = edge
				choices.layers[.Bar_Edge] = .Chosen
			}
		case "do_not_disturb":
			choices.do_not_disturb = change.value == u64(display_choices.Do_Not_Disturb.On) ? .On : .Off
			choices.layers[.Do_Not_Disturb] = .Chosen
		case "notification_show_milliseconds":
			choices.notification_show_milliseconds = change.value
			choices.layers[.Notification_Show_Time] = .Chosen
		case "magnifier_eighths":
			choices.magnifier_eighths = change.value
			choices.layers[.Magnifier_Factor] = .Chosen
		case "consent_arm_milliseconds":
			choices.consent_arm_milliseconds = change.value
			choices.layers[.Consent_Arm_Time] = .Chosen
		}
	}
	return .Succeeded, 1
}

// bar_edge gives the bar edge setting of the Display contract.
@(export, link_name = "bar_edge")
bar_edge_get :: proc "c" () -> desktop_shell.Bar_Position {
	return choices.bar_edge
}

// do_not_disturb gives the do-not-disturb setting of the Display contract.
@(export, link_name = "do_not_disturb")
do_not_disturb_get :: proc "c" () -> display_choices.Do_Not_Disturb {
	return choices.do_not_disturb
}

// notification_time gives the notification duration setting in milliseconds.
@(export, link_name = "notification_time")
notification_time_get :: proc "c" () -> i64 {
	return i64(choices.notification_show_milliseconds)
}

// magnifier_factor gives the magnifier factor setting in eighths.
@(export, link_name = "magnifier_factor")
magnifier_factor_get :: proc "c" () -> i64 {
	return i64(choices.magnifier_eighths)
}

// consent_arm_time gives the trusted-display consent arm time in milliseconds.
@(export, link_name = "consent_arm_time")
consent_arm_time_get :: proc "c" () -> i64 {
	return i64(choices.consent_arm_milliseconds)
}

// reset restores one Display role setting to its contract default.
@(export, link_name = "reset")
display_reset_export :: proc "c" (setting: display_choices.Setting, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	member, ok := display_choices.setting_of_word(u64(setting))
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, i64(setting))
	}
	switch member {
	case .Bar_Edge:
		choices.bar_edge = display_choices.CONTRACT_DEFAULTS.bar_edge
	case .Do_Not_Disturb:
		choices.do_not_disturb = display_choices.CONTRACT_DEFAULTS.do_not_disturb
	case .Notification_Show_Time:
		choices.notification_show_milliseconds = notifications.SHOW_MILLISECONDS_DEFAULT
	case .Magnifier_Factor:
		choices.magnifier_eighths = display_choices.MAGNIFIER_EIGHTHS_DEFAULT
	case .Consent_Arm_Time:
		choices.consent_arm_milliseconds = display_choices.CONSENT_ARM_MILLISECONDS_LEAST
	}
	choices.layers[member] = .Contract_Default
	return .Succeeded, 1
}

// settings_state gives one row for each setting of the Display contract.
@(export, link_name = "settings_state")
settings_state_export :: proc "c" (result: ^[]Setting_State, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	for setting in display_choices.Setting {
		row := int(setting)
		if row < len(result^) {
			result[row] = {
				setting = i64(setting),
				layer   = i64(choices.layers[setting]),
				value   = i64(display_choices.word_of(choices, setting)),
			}
		}
	}
	return .Succeeded, i64(len(display_choices.Setting))
}

@(private = "file")
send_event :: proc "contextless" (client: ^Client, kind: display.Event_Kind, values: [7]u64) {
	if client.ring.head == nil {
		return
	}
	if system.send(&client.ring.completions, ring.Record{kind = u32(kind), values = values}) {
		client.events_sent += 1
	}
}

@(private = "file")
surface_memory_end :: proc "contextless" (client: ^Client) {
	if client.pictures != nil {
		system.memory_unmap(client.pictures)
	}
	if client.pictures_memory != 0 {
		system.close(client.pictures_memory)
	}
	client.pictures = nil
	client.pictures_memory = 0
	client.surface = {}
}

@(private = "file")
surface_make :: proc "contextless" (client: ^Client, budget: system.Handle, screen_width, screen_height: u64) -> (pictures: [^]graphics.Color, memory, given: system.Handle, made: bool) {
	pages := (screen_width * screen_height * u64(size_of(graphics.Color) * display.PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	status: call_outcome.Call_Outcome
	memory, status = system.memory_create(pages, budget)
	if status != .Succeeded {
		return nil, 0, 0, false
	}
	address, map_status := system.memory_map(memory, {})
	if map_status != .Succeeded {
		system.close(memory)
		return nil, 0, 0, false
	}
	give_status: call_outcome.Call_Outcome
	given, give_status = system.give(client.ring_memory, memory, {.Read, .Write})
	if give_status != .Succeeded {
		system.memory_unmap(address)
		system.close(memory)
		return nil, 0, 0, false
	}
	return ([^]graphics.Color)(address), memory, given, true
}

@(private = "file")
screen_clear :: proc "contextless" () {
	if screen_of_memory || screen.pixels == nil {
		return
	}
	color := graphics.colors.background
	if red_first {
		color = color >> 16 & 0xFF | color & 0xFF00 | (color & 0xFF) << 16
	}
	for row in 0 ..< screen.height {
		base := row * screen.stride
		for col in 0 ..< screen.width {
			screen.pixels[base + col] = color
		}
	}
}

@(private = "file")
blit_client :: proc "contextless" (client: ^Client) {
	if screen_of_memory || screen.pixels == nil || client.surface.pixels == nil {
		return
	}
	copy_width := min(client.surface.width, screen.width)
	copy_height := min(client.surface.height, screen.height)
	for row in 0 ..< copy_height {
		src_base := row * client.surface.stride
		dst_base := row * screen.stride
		for col in 0 ..< copy_width {
			color := client.surface.pixels[src_base + col]
			if red_first {
				color = color >> 16 & 0xFF | color & 0xFF00 | (color & 0xFF) << 16
			}
			screen.pixels[dst_base + col] = color
		}
	}
	frames_on_shown_page += 1
}

@(private = "file")
client_add :: proc "contextless" (record: ring.Record) {
	memory := system.Handle(record.values[0])
	for &client in clients {
		if client.ring_memory != 0 {
			continue
		}
		opened, status := system.ring_open(memory, receive_handles = true)
		if status != .Succeeded {
			break
		}
		client = {ring_memory = memory, ring = opened}
		return
	}
	system.close(memory)
}

@(private = "file")
client_remove :: proc "contextless" (memory: system.Handle) {
	for &client, index in clients {
		if client.ring_memory != memory {
			continue
		}
		if client.created {
			system.log_fact(.Info, Window_Removed{window = window_field(client.title[:])})
		}
		for pos in 0 ..< order_count {
			if order[pos] == index {
				copy(order[pos:order_count - 1], order[pos + 1:order_count])
				order_count -= 1
				break
			}
		}
		surface_memory_end(&client)
		system.ring_close(&client.ring)
		system.close(client.ring_memory)
		client = {}
		screen_clear()
		if order_count > 0 {
			front := &clients[order[order_count - 1]]
			if front.presents > 0 && front.surface.pixels != nil {
				blit_client(front)
			}
		}
		return
	}
}

@(private = "file")
surface_create :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	budget := system.Handle(record.values[0] & 0xFFFF_FFFF)
	kind, rights, through := system.handle_state(budget, client.ring_memory)
	if client.created {
		if through {
			system.close(budget)
		}
		return
	}
	refuse :: proc "contextless" (client: ^Client) {
		send_event(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Create_Refused), 1 = 1})
	}
	if !through {
		refuse(client)
		return
	}
	defer system.close(budget)

	surface_scale, scale_problem := scale_factor.scale_of_word(record.values[0] >> display.SURFACE_CREATE_SCALE_SHIFT)
	logical_w, logical_h := record.values[1], record.values[2]
	if scale_problem != .None || logical_w == 0 || logical_h == 0 || logical_w > display.SURFACE_LIMIT || logical_h > display.SURFACE_LIMIT {
		refuse(client)
		return
	}
	screen_w, screen_h := display.surface_size_of(int(logical_w), int(logical_h), surface_scale)
	needed_budget := display.surface_budget_pages(u64(screen_w), u64(screen_h))
	if kind != .Budget || rights & {.Spend, .Read} != {.Spend, .Read} || needed_budget == 0 {
		refuse(client)
		return
	}
	amounts, budget_status := system.budget_read(budget)
	if budget_status != .Succeeded || amounts.pages < needed_budget {
		refuse(client)
		return
	}
	pictures, memory, given, made := surface_make(client, budget, u64(screen_w), u64(screen_h))
	if !made {
		refuse(client)
		return
	}
	send_event(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Create_Taken), 1 = 1, 2 = u64(given)})
	client.created = true
	client.released = false
	client.pictures = pictures
	client.pictures_memory = memory
	client.surface = {pixels = pictures, width = screen_w, height = screen_h, stride = screen_w}
	client.surface_serial = 1
	client.surface_scale = surface_scale
	client.width = int(logical_w)
	client.height = int(logical_h)
	client.title = system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	order[order_count] = index
	order_count += 1
	send_event(client, .Presentation, {0 = 1, 1 = u64(PANEL_SCALE), 2 = 0, 3 = presentation_words[0], 4 = presentation_words[1], 5 = presentation_words[2], 6 = presentation_words[3]})
	// Full screen with zero bar height so clients see 1920x1080 on the reference screen.
	send_event(client, .Work_Area, {0 = u64(max(screen.width, 1)), 1 = u64(max(screen.height, 1))})
	system.log_fact(.Info, Surface_Made{width = u64(client.width), height = u64(client.height), window = window_field(client.title[:])})
}

@(private = "file")
surface_release :: proc "contextless" (client: ^Client, record: ring.Record) {
	serial := record.values[0]
	if !client.created || client.released || serial != client.surface_serial {
		return
	}
	surface_memory_end(client)
	client.released = true
	send_event(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Released), 1 = serial})
}

@(private = "file")
surface_rescale :: proc "contextless" (client: ^Client, record: ring.Record) {
	serial := record.values[4]
	budget := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(budget, client.ring_memory)
	refuse :: proc "contextless" (client: ^Client, serial: u64) {
		send_event(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Refused), 1 = serial})
	}
	if !through {
		refuse(client, serial)
		return
	}
	defer system.close(budget)
	offered_scale, scale_problem := scale_factor.scale_of_word(record.values[3])
	screen_w, screen_h := record.values[1], record.values[2]
	needed_budget := display.surface_budget_pages(screen_w, screen_h)
	if !client.created || !client.released || serial != client.surface_serial + 1 || scale_problem != .None || offered_scale != PANEL_SCALE || needed_budget == 0 || kind != .Budget || rights & {.Spend, .Read} != {.Spend, .Read} {
		refuse(client, serial)
		return
	}
	amounts, budget_status := system.budget_read(budget)
	if budget_status != .Succeeded || amounts.pages < needed_budget {
		refuse(client, serial)
		return
	}
	pictures, memory, given, made := surface_make(client, budget, screen_w, screen_h)
	if !made {
		refuse(client, serial)
		return
	}
	client.pictures = pictures
	client.pictures_memory = memory
	client.surface = {pixels = pictures, width = int(screen_w), height = int(screen_h), stride = int(screen_w)}
	client.surface_serial = serial
	client.surface_scale = offered_scale
	client.released = false
	send_event(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Taken), 1 = serial, 2 = u64(given)})
}

@(private = "file")
cycle_focus :: proc "contextless" () {
	if order_count <= 1 {
		return
	}
	front := order[order_count - 1]
	copy(order[1:order_count], order[0:order_count - 1])
	order[0] = front
	screen_clear()
	new_front := &clients[order[order_count - 1]]
	if new_front.presents > 0 && new_front.surface.pixels != nil {
		blit_client(new_front)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	width := int(ctx.values[VALUE_WIDTH])
	height := int(ctx.values[VALUE_HEIGHT])
	fb_addr, fb_status := system.memory_map(ctx.handles[GRANT_FRAMEBUFFER])
	input_status, control_status: call_outcome.Call_Outcome
	input, input_status = system.ring_open(ctx.handles[GRANT_INPUT])
	control, control_status = system.ring_open(ctx.handles[GRANT_CONTROL])
	form := screen_presence.screen_form(fb_status, ctx.values[VALUE_WIDTH], ctx.values[VALUE_HEIGHT])
	if form == .None {
		system.log_fact(.Error, No_Framebuffer{})
		system.stop(.Failed)
	}
	if input_status != .Succeeded || control_status != .Succeeded {
		system.log_fact(.Error, No_Input_Or_Control_Ring{})
		system.stop(.Failed)
	}
	screen_of_memory = form == .Memory
	if screen_of_memory {
		screen = {width = width, height = height, stride = width}
	} else {
		screen = {pixels = ([^]graphics.Color)(fb_addr), width = width, height = height, stride = int(ctx.values[VALUE_PIXELS_PER_LINE])}
	}
	red_first = ctx.values[VALUE_FORMAT] == FORMAT_RED_FIRST
	pointer_x, pointer_y = width / 2, height / 2

	default_choice := settings.choice_default()
	default_choice.scale = PANEL_SCALE
	presentation_words = settings.presentation_words_of(default_choice)

	copied := ctx^
	copied.values[system.GRANT_VALUE_FILE_ADDRESS] = ctx.values[VALUE_FILE_ADDRESS]
	copied.values[system.GRANT_VALUE_FILE_SIZE] = ctx.values[VALUE_FILE_SIZE]
	service, _ = system.service_open(&copied)

	screen_clear()
	system.ready()
	system.log_fact(.Info, Panel_Ready{width = u64(width), height = u64(height)})

	wait_set = system.wait_set_of(wait_words[:], wait_parts[:])
	for {
		wait := system.wait_of_set(&wait_set)
		system.wait_records(&wait, &control.commands)
		system.wait_records(&wait, &input.commands)
		system.service_wait(&wait, &service)
		for &client in clients {
			if client.ring.head != nil {
				system.wait_records(&wait, &client.ring.commands)
			}
		}
		_ = system.wait_end(&wait, system.WAIT_FOREVER)

		for record in system.receive(&control.commands) {
			kind, kind_ok := display.control_of_ring_word(record.kind)
			if !kind_ok {
				system.log_fact(.Info, Control_Word_Refused{word = u64(record.kind)})
				continue
			}
			switch kind {
			case .Client_Add:
				client_add(record)
			case .Client_Remove:
				client_remove(system.Handle(record.values[0]))
			case .None, .Start, .Stop, .Palette_Provider_Add, .Palette_Provider_Remove, .Client_Started, .Appearance_Next, .Settings_Raise, .Screen_Budget_Give, .Screen_Budget_Release, .Wide_Grant_Screen_Show, .Wide_Grant_Screen_Answer, .Wide_Grant_Mark, .Wide_Grant_Revoke_Pressed, .Session_Reset, .Keyboard_Layout_Set:
			}
		}

		for record in system.receive(&input.commands) {
			kind, kind_ok := display.input_of_ring_word(record.kind)
			if !kind_ok {
				system.log_fact(.Info, Input_Word_Refused{word = u64(record.kind)})
				continue
			}
			switch kind {
			case .None:
			case .Key:
				key_records += 1
				code := u32(record.values[0])
				pressed := record.values[2] != 0
				modifiers := u32(record.values[3])
				if pressed && code == display.KEY_TAB && (modifiers & display.MODIFIER_ALT) != 0 {
					cycle_focus()
					continue
				}
				if order_count > 0 {
					front := &clients[order[order_count - 1]]
					send_event(front, .Key, {0 = record.values[0], 1 = record.values[1], 2 = record.values[2], 3 = record.values[3]})
				}
			case .Pointer:
				pointer_moves += 1
				pointer_x = clamp(pointer_x + int(i64(record.values[0])), 0, max(screen.width - 1, 0))
				pointer_y = clamp(pointer_y + int(i64(record.values[1])), 0, max(screen.height - 1, 0))
				buttons = u32(record.values[2])
				if order_count > 0 {
					front := &clients[order[order_count - 1]]
					send_event(front, .Pointer, {0 = u64(i64(pointer_x)), 1 = u64(i64(pointer_y)), 2 = u64(buttons), 3 = record.values[3]})
				}
			case .Pointer_Absolute:
				pointer_moves += 1
				if record.values[4] > 0 && record.values[5] > 0 {
					pointer_x = clamp(int(record.values[0] * u64(screen.width) / record.values[4]), 0, max(screen.width - 1, 0))
					pointer_y = clamp(int(record.values[1] * u64(screen.height) / record.values[5]), 0, max(screen.height - 1, 0))
				}
				buttons = u32(record.values[2] & u64(display.BUTTON_LEFT | display.BUTTON_RIGHT))
				if order_count > 0 {
					front := &clients[order[order_count - 1]]
					send_event(front, .Pointer, {0 = u64(i64(pointer_x)), 1 = u64(i64(pointer_y)), 2 = u64(buttons), 3 = record.values[3]})
				}
			}
		}

		for &client, index in clients {
			if client.ring.head == nil {
				continue
			}
			taken := false
			for _ in 0 ..< system.records_of_turn(&client.ring.commands) {
				record := system.receive(&client.ring.commands) or_break
				taken = true
				command, command_ok := display.command_of_ring_word(record.kind)
				if !command_ok {
					if client.commands_refused == 0 {
						system.log_fact(.Info, Window_Word_Refused{word = u64(record.kind)})
					}
					client.commands_refused += 1
					continue
				}
				switch command {
				case .None:
				case .Surface_Create:
					surface_create(index, record)
				case .Present:
					client.picture_due = false
					picture := record.values[0]
					serial := record.values[display.PRESENT_SURFACE_SERIAL]
					if !client.created || client.released || client.pictures == nil || picture >= display.PICTURE_COUNT || serial != client.surface_serial {
						client.presents_refused += 1
						continue
					}
					if client.presents > 0 && int(picture) == client.shown {
						client.pictures_drawn_again += 1
					}
					client.shown = int(picture)
					client.surface.pixels = client.pictures[client.shown * client.surface.width * client.surface.height:]
					if client.presents == 0 {
						system.log_fact(.Info, Window_Shown{window = window_field(client.title[:])})
					}
					client.presents += 1
					total_presents += 1
					client.frames += 1
					total_frames += 1
					if order_count > 0 && order[order_count - 1] == index {
						blit_client(&client)
					}
				case .Picture_Due:
					client.picture_due = record.values[0] != 0
				case .Surface_Release:
					surface_release(&client, record)
				case .Surface_Rescale:
					surface_rescale(&client, record)
				case .Surface_Resize:
					budget := system.Handle(record.values[0])
					if _, _, through := system.handle_state(budget, client.ring_memory); through {
						system.close(budget)
					}
					send_event(&client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Resize_Refused), 1 = record.values[3]})
				case .Pointer_Shape, .Act_Names, .Resizable, .Resize_Declined, .Copy, .Copy_Declined, .Paste_Taken, .Capture_Size_Ask, .Capture_Open, .Capture_Taken, .Capture_Close, .Capture_Viewers, .Remote_Key, .Remote_Pointer, .Surface_Declined, .Screen_Size_Set, .Pointer_Lock:
				}
			}
			if taken && client.ring.head != nil {
				system.wake_writer(&client.ring.commands)
			}
		}

		system.service_run(&service)
	}
}
