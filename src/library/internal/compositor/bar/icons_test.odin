#+build !freestanding
package bar

import "core:testing"
import "modus:interface"

// Each icon draws at least two rectangles, each inside its square of
// ICON_SIZE pixels, wherever the corner is: an icon never paints the text
// next to it.
@(test)
each_icon_stays_in_its_square :: proc(t: ^testing.T) {
	UNITS :: 64 // A coordinate of a record is in 1/64 pixel.
	for icon in Icon {
		for corner in ([?][2]int{{0, 0}, {37, 5}, {-16, -16}}) {
			records: [32]interface.Draw_Record
			table := interface.Draw_Table{records = records[:]}
			icon_records(&table, corner.x, corner.y, icon, 0xFFFFFF, 0x3F7CC4)
			testing.expectf(t, table.record_count >= 2 && !table.full, "%v draws its parts", icon)
			for record in records[:table.record_count] {
				inside_square := int(record.left) >= corner.x * UNITS && int(record.top) >= corner.y * UNITS && int(record.right) <= (corner.x + ICON_SIZE) * UNITS && int(record.bottom) <= (corner.y + ICON_SIZE) * UNITS
				testing.expectf(t, inside_square, "%v at %v: a part leaves the square: %v", icon, corner, record)
			}
		}
	}
}

// A name gets the icon of its kind; a name that no module has, an empty
// name and a name that differs by one character get the framed window.
@(test)
a_name_gets_the_icon_of_its_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, icon_of("console"), Icon.Console)
	testing.expect_value(t, icon_of("terminal"), Icon.Console)
	testing.expect_value(t, icon_of("monitor"), Icon.Monitor)
	testing.expect_value(t, icon_of("clock"), Icon.Clock)
	testing.expect_value(t, icon_of("settings"), Icon.Settings)
	testing.expect_value(t, icon_of("notes"), Icon.Document)
	testing.expect_value(t, icon_of("manual"), Icon.Manual)
	testing.expect_value(t, icon_of("net"), Icon.Network)
	testing.expect_value(t, icon_of("remote"), Icon.Network)
	testing.expect_value(t, icon_of("debugger_window"), Icon.Debugger)
	testing.expect_value(t, icon_of("paint"), Icon.Picture)
	testing.expect_value(t, icon_of("disk"), Icon.Disk)
	testing.expect_value(t, icon_of("kernel_events"), Icon.Console)
	testing.expect_value(t, icon_of(""), Icon.Window)
	testing.expect_value(t, icon_of("consol"), Icon.Window)
	testing.expect_value(t, icon_of("console "), Icon.Window)
	testing.expect_value(t, icon_of("my_nickname"), Icon.Window)
	for name, index in names {
		testing.expectf(t, icon_of(name) == name_icons[index], "%s has the icon of its line", name)
	}
}

// Each name of the start menu is there once: a module is in one pane only,
// and center finds the one line of each name.
@(test)
each_name_is_listed_once :: proc(t: ^testing.T) {
	for name, index in names {
		testing.expectf(t, name != "", "the name %v is empty", index)
		for other in index + 1 ..< len(names) {
			testing.expectf(t, names[other] != name, "%s is listed twice", name)
		}
	}
}
