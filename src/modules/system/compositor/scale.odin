package compositor

// The scale factor of the desktop (src/md/features/desktop_to_browser.md,
// "The reference screen"). The compositor lays out the desktop in logical
// pixels: the places of the windows, the bar, the menus, the palette, the
// pointer, the drag and each hit test. It turns them into pixels of the
// screen at one place each: the damage (damage_add), the draw of its tables
// by the drawing module at the scale, the corner of each surface
// (surface_screen_corner) and the pointer picture (pointer_screen_place).
// The surface of a window is pixels of the screen, which it copies as they
// are.

import "modus:contract/scale_factor"
import "modus:contract/settings"
import "internal:compositor/bar"
import "modus:system"

// The scale of the desktop: the scale of the settings page. The compositor
// names it to each window in Settings_Changed, and each window rescales to
// it (src/md/features/window_resize.md, "The rescale").
scale: scale_factor.Scale = scale_factor.DEFAULT

// The screen in logical pixels at the scale: the room of the layout.
desktop_width, desktop_height: int

// A place of the layout past this distance is cut to it before it goes to
// the screen: no place of the desktop is that far.
@(private = "file")
LAYOUT_PLACE_LIMIT :: 1 << 22

@(private = "file")
layout_place :: proc "contextless" (place: int) -> i32 {
	return i32(clamp(place, -LAYOUT_PLACE_LIMIT, LAYOUT_PLACE_LIMIT))
}

// screen_pixel_of gives the pixel of the screen of an edge at a logical
// pixel of the desktop.
screen_pixel_of :: proc "contextless" (place: int) -> int {
	return int(scale_factor.screen_pixel_of_logical_pixel(layout_place(place), scale))
}

// logical_pixel_of gives the logical pixel of the desktop that holds a
// pixel of the screen.
logical_pixel_of :: proc "contextless" (pixel: int) -> int {
	return int(scale_factor.logical_pixel_of_screen_pixel(layout_place(pixel), scale))
}

// screen_rectangle_of gives the rectangle of the screen of a logical
// rectangle of the desktop: each edge by the rule of each edge.
screen_rectangle_of :: proc "contextless" (x, y, width, height: int) -> Rectangle {
	return {screen_pixel_of(x), screen_pixel_of(y), screen_pixel_of(x + max(width, 0)), screen_pixel_of(y + max(height, 0))}
}

// desktop_scale_take takes the scale of a choice of the settings page: the
// logical size of the screen, and the pointer inside it. A page that read
// refused (read_ok false), or a writer left in its change, gives no scale:
// the desktop keeps the last one, as each window keeps the scale that the
// compositor named last. It gives true when the scale changed: the whole
// screen is damage.
desktop_scale_take :: proc "contextless" (choice: settings.Choice, read_ok: bool) -> (changed: bool) {
	taken := bar.scale_after_read(scale, choice.scale, read_ok)
	changed = taken != scale || desktop_width == 0
	scale = taken
	desktop_width, desktop_height = logical_pixel_of(screen.width), logical_pixel_of(screen.height)
	// The zones of the maximize and of the snap are in logical pixels of the
	// screen: they follow the new logical screen, or a maximize at the new
	// scale would ask the size of the old one.
	if changed {
		desktop_features_resize(i32(desktop_width), i32(desktop_height), i32(BAR_HEIGHT)) // desktop_features.odin
	}
	before_x, before_y := pointer_x, pointer_y
	pointer_x = clamp(pointer_x, 0, desktop_width - 1)
	pointer_y = clamp(pointer_y, 0, desktop_height - 1)
	if pointer_x != before_x || pointer_y != before_y {
		capture_note_machine_pointer_move()
	}
	return changed
}

// interior_screen_box gives the box of the screen of the logical interior
// of a window: the room of its surface. The compositor copies the surface
// from its corner and cuts it to this box.
interior_screen_box :: proc "contextless" (client: ^Client) -> bar.Screen_Box {
	return bar.screen_box_of({client.x + BORDER, client.y + TITLE_HEIGHT, client.x + BORDER + client.width, client.y + TITLE_HEIGHT + client.height}, scale)
}

// The count of the windows that declined the scale in force, as the last
// Settings_Changed named it to each window.
windows_declined_told: int

// window_declined_scale_in_force says if a window declined the scale in
// force and shows no surface: its budget does not pay a surface at it.
window_declined_scale_in_force :: proc "contextless" (client: ^Client) -> bool {
	return client.created && client.released && client.declined && client.declined_scale == scale
}

// windows_declined_count counts the windows that declined the scale in
// force.
windows_declined_count :: proc "contextless" () -> int {
	count := 0
	for &client in clients {
		if window_declined_scale_in_force(&client) {
			count += 1
		}
	}
	return count
}

// settings_changed_send names the settings to a window: the count of the
// change, the scale and the count of the windows that declined it. A
// window whose fit waits (scale_due) is named the scale that it was told
// before, so its fit request is not declined by a release.
settings_changed_send :: proc "contextless" (client: ^Client) {
	told := client.scale_due ? client.scale_told : scale
	client.scale_told = told
	send(client, .Settings_Changed, {0 = settings_count_told, 1 = u64(told), 2 = u64(windows_declined_told)})
}

// window_scale_step names the scale in force to a window whose scale is
// due, once no request of its size waits. Once for each change of the
// scale it fits the window into the work area of the scale, in the order
// of bar.fit_order: a fit that gives a size no larger goes first, and the
// end of its request calls this again; a fit that grows the window waits
// until the window shows its surface at the new scale (window_fit_after_scale),
// since the larger size at the old, larger scale can pass its budget. It
// gives true when it sent the Settings_Changed.
window_scale_step :: proc "contextless" (client: ^Client) -> (sent: bool) {
	if !client.scale_due || client.resize_asked {
		return false
	}
	if client.fit_due {
		client.fit_due = false
		client.fit_after_scale = false
		x, y, width, height := window_fit_target(client)
		switch bar.fit_order(client.width, client.height, width, height) {
		case .Fit_First:
			window_place_and_size_take(client, x, y, width, height) // window_resize.odin
			if client.resize_asked {
				return false
			}
		case .Scale_First:
			client.fit_after_scale = true
		}
	}
	client.scale_due = false
	settings_changed_send(client)
	return true
}

// window_fit_after_scale takes the fit that waited for the rescale, once
// the window shows a surface of the scale in force: the size that grows is
// paid at the new, smaller scale. A window that declined the scale shows
// no such surface, and keeps its size.
window_fit_after_scale :: proc "contextless" (client: ^Client) {
	if !client.fit_after_scale || client.scale_due || client.surface_scale != scale || client.resize_asked {
		return
	}
	client.fit_after_scale = false
	x, y, width, height := window_fit_target(client)
	window_place_and_size_take(client, x, y, width, height) // window_resize.odin
}

// window_fit_target gives the place and the size of a window in the work
// area of the scale in force (bar.window_fit): a maximized window takes the
// work area; a larger resizable window gets the size that fits, within its
// limits; each window is moved onto the screen. The size is the surface of
// the window, as window_place_and_size_take asks it.
window_fit_target :: proc "contextless" (client: ^Client) -> (x, y, width, height: int) {
	chrome_width, chrome_height := 2 * BORDER, TITLE_HEIGHT + BORDER
	if client.decoration == .Client {
		chrome_width, chrome_height = 0, 0
	}
	if client.maximized {
		if zone_x, zone_y, outer_width, outer_height, ok := desktop_zone_frame(.Maximized); ok {
			x, y, width, height = zone_x, zone_y, outer_width - chrome_width, outer_height - chrome_height
			if client.resizable {
				limits := size_range_of(client)
				width = clamp(width, limits.least_width, limits.largest_width)
				height = clamp(height, limits.least_height, limits.largest_height)
			} else {
				width, height = client.width, client.height
			}
			return
		}
	}
	top := desktop_work_top()
	work := bar.Work_Box{left = 0, top = top, width = desktop_width, height = desktop_work_bottom() - top}
	return bar.window_fit({x = client.x, y = client.y, width = client.width, height = client.height, chrome_width = chrome_width, chrome_height = chrome_height, limits = size_range_of(client), resizable = client.resizable}, work)
}

// windows_declined_tell names a new count of the windows that declined the
// scale in force to each window, in a Settings_Changed of the same scale:
// the window of settings shows it, and each other window rescales to the
// scale that it has already, which changes nothing.
windows_declined_tell :: proc "contextless" () {
	count := windows_declined_count()
	if count == windows_declined_told {
		return
	}
	windows_declined_told = count
	for &client in clients {
		if client.ring.head != nil {
			settings_changed_send(&client)
		}
	}
}

// A change of the scale waits for each window to show a surface of the new
// scale: windows_at_scale_check then writes its one line.
windows_at_scale_due: bool

// windows_at_scale_check writes the line of a change of the scale when each
// window shows a surface of the scale in force. The loop calls it at each
// turn after the records of the windows; it reads the clients only while a
// change waits, at most 32.
windows_at_scale_check :: proc "contextless" () {
	if !windows_at_scale_due {
		return
	}
	windows: u64
	for &client in clients {
		if !client.created {
			continue
		}
		// A window that declined the scale in force is settled: it waits
		// for another scale, and the count of Settings_Changed names it.
		if window_declined_scale_in_force(&client) {
			continue
		}
		if client.released || client.resize_pictures != nil || client.surface_scale != scale {
			return
		}
		windows += 1
	}
	windows_at_scale_due = false
	system.log_fact(.Info, Windows_At_Scale{windows = windows, scale = u64(scale)})
}

// window_frame_inner gives the part of the screen of the interior of a
// window that no part of its frame covers.
window_frame_inner :: proc "contextless" (client: ^Client) -> bar.Screen_Box {
	parts := bar.frame_parts(client.x, client.y, client.width, client.height, BORDER, TITLE_HEIGHT)
	on_screen: [4]bar.Screen_Box
	for part, index in parts {
		on_screen[index] = bar.screen_box_of(part, scale)
	}
	return bar.frame_inner(on_screen)
}

// surface_screen_box gives the part of the screen that the surface of a
// window covers: copied pixel for pixel from the corner of the interior,
// cut to the interior. A surface of an older scale, larger than the
// interior, covers no frame and no other window. The frame is drawn from
// the logical place of the window; its borders reach under the interior by
// one logical pixel, so the rounding of the corner leaves no gap.
surface_screen_box :: proc "contextless" (client: ^Client) -> bar.Screen_Box {
	interior := interior_screen_box(client)
	return bar.surface_clip(interior.left, interior.top, client.surface.width, client.surface.height, interior)
}
