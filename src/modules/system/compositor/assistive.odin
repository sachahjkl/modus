// The assistive face of the compositor: the holders of the assistive role,
// their marks in the bar, and the magnification that a holder asks for
// (src/md/features/accessibility.md, "2. The assistive role"). The rules
// and the places are in src/library/internal/compositor/bar (assistive.odin),
// so a host test reads the same table and the same marks.
package compositor

import "internal:compositor/bar"
import "modus:contract/accessibility"
import "modus:contract/screen_reader"
import "modus:contract/value_kinds"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The name of each kind of holder, as the log and the rows of the export
// say it.
@(rodata)
ASSISTIVE_HOLDER_KIND_NAMES := [bar.Assistive_Holder_Kind]string {
	.None          = "none",
	.Screen_Reader = "screen_reader",
	.Magnifier     = "magnifier",
	.Switch_Input  = "switch_input",
}
#assert(len("screen_reader") < ASSISTIVE_KIND_FIELD_BYTES)
#assert(bar.ASSISTIVE_NICKNAME_BYTES < value_kinds.MODULE_NAME_FIELD_BYTES)

assistive_registry: bar.Assistive_Registry
// The marks of the last frame: the tray starts at their left.
assistive_mark_layout: bar.Assistive_Mark_Layout
// The magnifier shows what a holder asked for: it ends with the last holder,
// so no magnification stays that no mark explains.
assistive_magnifying: bool

// assistive_holder_attach records a holder, shows its mark and says it in
// the log.
assistive_holder_attach :: proc "contextless" (nickname: string, kind: bar.Assistive_Holder_Kind) -> (id: u64, refusal: bar.Assistive_Attach_Refusal) {
	id, refusal = bar.assistive_attach(&assistive_registry, nickname, kind)
	if refusal != .None {
		return id, refusal
	}
	system.log_fact(.Info, Assistive_Holder_Attached{holder = id, kind = value_kinds.text_field(ASSISTIVE_HOLDER_KIND_NAMES[kind], ASSISTIVE_KIND_FIELD_BYTES), nickname = value_kinds.module_name_field(nickname)})
	damage_bar()
	return id, .None
}

// assistive_holder_detach ends a holder and its mark. With the last
// holder, the magnification that a holder asked for ends too.
assistive_holder_detach :: proc "contextless" (id: u64) -> bool {
	detached, ok := bar.assistive_detach(&assistive_registry, id)
	if !ok {
		return false
	}
	system.log_fact(.Info, Assistive_Holder_Detached{holder = detached.id, holders = u64(assistive_registry.count), nickname = value_kinds.module_name_field(bar.assistive_holder_nickname(&detached))})
	if assistive_registry.count == 0 && assistive_magnifying {
		assistive_magnify_stop()
	}
	damage_bar()
	return true
}

// assistive_magnify_start draws a rectangle of the screen larger, after
// bar.assistive_magnify_check took it.
assistive_magnify_start :: proc "contextless" (left, top, width, height, factor_eighths: i64) {
	if !desktop_features_ready {
		return
	}
	desktop_magnifier.zoom_eighths = u16(factor_eighths)
	desktop_magnifier.enabled = true
	screen_reader.magnifier_follow_box(&desktop_magnifier, accessibility.Semantic_Box{left = i32(left), top = i32(top), right = i32(left + width), bottom = i32(top + height)})
	assistive_magnifying = true
	damage_whole_screen()
}

// assistive_magnify_stop ends the magnification that a holder asked for.
assistive_magnify_stop :: proc "contextless" () {
	assistive_magnifying = false
	desktop_magnifier.enabled = false
	damage_whole_screen()
}

// assistive_marks_records draws one mark for each holder at the right of the
// tray, which ends at right, and gives the first column of the leftmost
// mark. A mark has the form of the mark of a viewer: an outline in the
// warning color, which both appearances keep at a contrast of 3 to 1 on the
// bar, and the text in the text color of the appearance. A mark with no
// room is the square, so a holder never reads with no mark.
assistive_marks_records :: proc "contextless" (table: ^interface.Draw_Table, right: int) -> (left: int) {
	assistive_mark_layout = {}
	if !bar.assistive_mark_shown(&assistive_registry) {
		return right
	}
	texts: [bar.ASSISTIVE_HOLDER_LIMIT][bar.ASSISTIVE_MARK_TEXT_BYTES]u8
	widths: [bar.ASSISTIVE_HOLDER_LIMIT]int
	for &holder, slot in assistive_registry.holders {
		if holder.active {
			widths[slot] = interface.text_measured_width(table, interface.FONT_INTERFACE, bar.assistive_mark_text(&holder, &texts[slot]))
		}
	}
	assistive_mark_layout = bar.assistive_marks_place(&assistive_registry, widths, right, bar.PLATES_X + bar.PLATE_WIDTH + 16)
	bar_top := desktop_bar_y()
	for &mark in assistive_mark_layout.marks[:assistive_mark_layout.count] {
		if mark.square {
			y := bar_top + bar.TRAY_Y + (bar.TRAY_HEIGHT - bar.ASSISTIVE_MARK_SQUARE) / 2
			interface.draw_rectangle(table, mark.x, y, bar.ASSISTIVE_MARK_SQUARE, bar.ASSISTIVE_MARK_SQUARE, graphics.colors.warning)
			continue
		}
		y := bar_top + bar.TRAY_Y
		text := bar.assistive_mark_text(&assistive_registry.holders[mark.slot], &texts[mark.slot])
		interface.draw_outline(table, mark.x, y, mark.width, bar.TRAY_HEIGHT, 2, graphics.colors.warning)
		interface.draw_text(table, mark.x + bar.PADDING, y + (bar.TRAY_HEIGHT - graphics.CELL_HEIGHT) / 2, text, graphics.colors.text, interface.FONT_INTERFACE)
	}
	return assistive_mark_layout.left
}
