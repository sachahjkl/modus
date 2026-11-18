package interface

import "modus:contract/draw_record"
import "modus:support/graphics"

DAMAGE_CAPACITY :: 8 // The rectangles that one frame keeps, as the compositor does.

// Damage: the rectangles of a surface that changed between two frames. The
// caller gives the memory of the rectangles.
Damage :: struct {
	rectangles: [DAMAGE_CAPACITY]Rectangle, // The rectangles; no two of them touch.
	count:      int, // The rectangles in use.
}

// damage_add records that a rectangle changed. Rectangles that touch become
// one rectangle; with no room left, the new rectangle joins the first one.
damage_add :: proc "contextless" (damage: ^Damage, rectangle: Rectangle) {
	area := rectangle
	if empty(area) {
		return
	}
	index := 0
	for index < damage.count {
		other := damage.rectangles[index]
		apart := area.left > other.right || other.left > area.right || area.top > other.bottom || other.top > area.bottom
		if apart && damage.count < DAMAGE_CAPACITY {
			index += 1
			continue
		}
		area = {min(area.left, other.left), min(area.top, other.top), max(area.right, other.right), max(area.bottom, other.bottom)}
		damage.count -= 1
		damage.rectangles[index] = damage.rectangles[damage.count]
		index = 0 // The larger rectangle can touch one that it did not touch before.
	}
	damage.rectangles[damage.count] = area
	damage.count += 1
}

// damage_bounds gives the one rectangle that holds each damage rectangle.
damage_bounds :: proc "contextless" (damage: ^Damage) -> Rectangle {
	if damage.count == 0 {
		return {}
	}
	bounds := damage.rectangles[0]
	for rectangle in damage.rectangles[1:damage.count] {
		bounds = {min(bounds.left, rectangle.left), min(bounds.top, rectangle.top), max(bounds.right, rectangle.right), max(bounds.bottom, rectangle.bottom)}
	}
	return bounds
}

// records_equal says if two records draw the same thing: their 48 bytes are
// equal, except the places of their texts and grids in the two text tables,
// and the bytes of their texts are equal. A text record whose range is not
// inside its text table is equal to no record. Two Text_Grid records are
// equal when their bytes are equal except their places: their cells are
// compared one by one after it (grid_damage). The check is on the records
// that it receives, the copies that it compares.
//
// Most records of a frame are the records of the frame before, so the
// equal case is one comparison of 48 bytes, with no read through the
// border: two records with the same bytes draw the same thing, also two
// records that the border refuses, which draw nothing in both frames. Only
// a text compares its bytes too. The border keeps each byte of a record
// that it reads canonical (each unused byte is 0, and a color with alpha 0
// that draws nothing is 0), so two records whose bytes differ draw
// different things, or one of them draws nothing: they are not equal, and
// no read through the border is needed to know it. Where two records with
// other bytes still draw the same pixels (a gradient of one line whose
// second end, of alpha 0, is never drawn; rectangles of the color 0 with
// other patterns; a rectangle of the color 0 against a None), the damage
// is too large, never too small. The one exception is the first byte of the range of
// a Text or a Text_Grid, which can move in the text table
// with no change of what is drawn: those records are compared with that
// word masked. Two refused records that are equal under the mask draw
// nothing in both frames, or are damaged by the comparison of their texts
// or by the grid; the damage can be too large, never too small.
records_equal :: proc "contextless" (before: ^Draw_Table, old: Draw_Record, now: ^Draw_Table, new: Draw_Record) -> bool {
	old_words := transmute([draw_record.RECORD_WORDS]u64)old
	new_words := transmute([draw_record.RECORD_WORDS]u64)new
	kind, known := draw_record.draw_kind_of_word(new.kind)
	if old_words == new_words {
		if !known {
			return true
		}
		switch kind {
		case .Text:
			range := transmute(Range_Fields)new.fields
			return texts_equal(before, range.first, now, range.first, range.count)
		case .None, .Rectangle, .Vertical_Gradient, .Horizontal_Gradient, .Clip, .Picture, .Text_Grid, .Line:
			return true
		}
		return true
	}
	if old.kind != new.kind || !known {
		return false
	}
	switch kind {
	case .Text, .Text_Grid:
		old_words[RANGE_FIRST_WORD] &= ~RANGE_FIRST_MASK
		new_words[RANGE_FIRST_WORD] &= ~RANGE_FIRST_MASK
		if old_words != new_words {
			return false
		}
		if kind == .Text_Grid {
			return true
		}
		old_range := transmute(Range_Fields)old.fields
		new_range := transmute(Range_Fields)new.fields
		return texts_equal(before, old_range.first, now, new_range.first, new_range.count)
	case .None, .Rectangle, .Vertical_Gradient, .Horizontal_Gradient, .Clip, .Picture, .Line:
		return false
	}
	return false
}

// The first two fields of a Text and a Text_Grid: the
// place of the range in the text table, and its count of bytes.
@(private)
Range_Fields :: struct {
	first:    u32,
	count:    u32,
	reserved: [draw_record.FIELDS_SIZE - 8]u8,
}

// The word of the record that holds the field first of a range, and the
// bits of that field in it: the fields start at the byte HEADER_SIZE, a
// multiple of 8, and first is their first 4 bytes, the low half of the
// word on this little-endian machine.
@(private)
RANGE_FIRST_WORD :: draw_record.HEADER_SIZE / size_of(u64)
@(private)
RANGE_FIRST_MASK :: u64(0xFFFF_FFFF)

#assert(draw_record.HEADER_SIZE % size_of(u64) == 0)
#assert(size_of(Range_Fields) == draw_record.FIELDS_SIZE)
#assert(offset_of(draw_record.Text_Fields, first) == 0 && offset_of(draw_record.Text_Fields, count) == 4)
#assert(offset_of(draw_record.Text_Grid_Fields, first) == 0 && offset_of(draw_record.Text_Grid_Fields, count) == 4)

// texts_equal says if two ranges of count bytes, in the text tables of two
// frames, hold the same bytes. A range outside its text table is equal to
// no range: the sums are in 64 bits, so no range wraps.
@(private)
texts_equal :: proc "contextless" (before: ^Draw_Table, old_first: u32, now: ^Draw_Table, new_first: u32, count: u32) -> bool {
	if u64(old_first) + u64(count) > u64(before.text_count) || u64(new_first) + u64(count) > u64(now.text_count) {
		return false
	}
	return string(before.text[old_first:][:count]) == string(now.text[new_first:][:count])
}

// is_clip_record says if a record is a Clip: a clip that changes changes
// what each record after it draws.
@(private)
is_clip_record :: proc "contextless" (record: Draw_Record) -> bool {
	kind, known := draw_record.draw_kind_of_word(record.kind)
	return known && kind == .Clip
}

// damage_by_difference finds what changed from the table before to the
// table now, record by record at the same index: where two records differ,
// the rectangle of the old one and the rectangle of the new one are damaged;
// the records after the end of the shorter table are damaged. A record added
// in the middle damages each record after it: the damage can be too large,
// never too small (docs/INTERFACE.md, section 2.2).
damage_by_difference :: proc "contextless" (before, now: ^Draw_Table, damage: ^Damage) {
	shared := min(before.record_count, now.record_count)
	for index in 0 ..< shared {
		// One copy of each record: a table can be in memory that another
		// program writes during the call (the interface as a module).
		old := draw_record.copy_once(&before.records[index])
		new := draw_record.copy_once(&now.records[index])
		if records_equal(before, old, now, new) {
			grid_damage(before, old, now, new, damage)
			continue
		}
		// A clip that changes changes what the next records draw.
		if is_clip_record(old) || is_clip_record(new) {
			damage_rest(before, now, index, damage)
			return
		}
		damage_add(damage, record_rectangle(old))
		damage_add(damage, record_rectangle(new))
	}
	for index in shared ..< before.record_count {
		damage_add(damage, record_rectangle(draw_record.copy_once(&before.records[index])))
	}
	for index in shared ..< now.record_count {
		damage_add(damage, record_rectangle(draw_record.copy_once(&now.records[index])))
	}
}

// damage_rest damages each record of the two tables from an index to the
// end. One copy of each record, as each other reader takes.
@(private)
damage_rest :: proc "contextless" (before, now: ^Draw_Table, first: int, damage: ^Damage) {
	tables := [2]^Draw_Table{before, now}
	for table in tables {
		for index in first ..< table.record_count {
			record := draw_record.copy_once(&table.records[index])
			if !is_clip_record(record) {
				damage_add(damage, record_rectangle(record))
			}
		}
	}
}

// grid_damage damages, in each row of a grid that did not move, the span
// from the first changed cell to the last one. The two records are equal
// except their places in their text tables; a record that is no grid
// damages nothing here. A grid whose cells one of the two tables does not
// hold (grid_of) is damaged whole.
@(private)
grid_damage :: proc "contextless" (before: ^Draw_Table, old_record: Draw_Record, now: ^Draw_Table, record: Draw_Record, damage: ^Damage) {
	// The word of the kind first: most equal records are no grid, and they
	// cost no read through the border here.
	if kind, known := draw_record.draw_kind_of_word(record.kind); !known || kind != .Text_Grid {
		return
	}
	primitive, problem := draw_record.read(record)
	if _, is_grid := primitive.(draw_record.Draw_Text_Grid); problem != .None || !is_grid {
		return
	}
	old, old_ok := grid_of(before, old_record)
	new, new_ok := grid_of(now, record)
	if !old_ok || !new_ok || old.columns != new.columns || old.rows != new.rows {
		damage_add(damage, record_rectangle(record))
		return
	}
	place := record_rectangle(record)
	x, y := place.left, place.top
	for row in 0 ..< new.rows {
		old_row := old.cells[row * old.stride:][:new.columns]
		new_row := new.cells[row * new.stride:][:new.columns]
		first, last := -1, -1
		for column in 0 ..< new.columns {
			if old_row[column] != new_row[column] {
				if first < 0 {
					first = column
				}
				last = column
			}
		}
		if first >= 0 {
			top := y + row * graphics.CELL_HEIGHT
			damage_add(damage, {x + first * graphics.CELL_WIDTH, top, x + (last + 1) * graphics.CELL_WIDTH, top + graphics.CELL_HEIGHT})
		}
	}
}

// Picture_Debts: what each of the two pictures of a surface owes. A
// program draws one picture while the screen shows the other, so a picture holds the frame of two
// frames before. The window layer keeps one table, the table of the last
// frame that it presented, and here, for each picture, the rectangles where
// the picture differs from that table: its debt. A record of zeros: no
// picture is known, and each one is drawn whole.
Picture_Debts :: struct {
	owed:  [2]Damage, // The rectangles where the picture differs from the last table. Read only while the picture is known.
	known: [2]bool, // The picture is the last table, except in its debt.
}

// damage_of_picture finds what a frame draws and what it presents. picture
// is the picture that the program draws now; the screen shows the other
// one. changed is the difference from the last table to the frame.
//
// draw: the changed rectangles and the debt of the picture, the pixels of
// this picture to make again. present: the changed rectangles and the debt
// of the other picture, because the screen must change wherever it shows
// something other than the frame. A picture that is not known gives the
// whole surface: it can hold anything that an older frame drew, also where
// the frame now draws nothing.
//
// The caller empties debts before the call when it has no difference with
// the last table (no last table, or a table that was full).
damage_of_picture :: proc "contextless" (debts: ^Picture_Debts, picture: int, changed: ^Damage, surface: Rectangle, draw, present: ^Damage) {
	sides := [2]^Damage{draw, present}
	for side, index in sides {
		of_picture := index == 0 ? picture : 1 - picture
		side^ = {}
		if !debts.known[of_picture] {
			damage_add(side, surface)
			continue
		}
		side^ = changed^
		owed := debts.owed[of_picture]
		for rectangle in owed.rectangles[:owed.count] {
			damage_add(side, rectangle)
		}
	}
}

// picture_debts_after records the end of a frame that drew `picture` and
// sent its Present. presented: the compositor has the Present. The drawn
// picture is then the frame, with no debt, and the other picture owes the
// changed rectangles more. A Present that was lost leaves the last table
// as it was while the picture is the frame: the picture is not known.
picture_debts_after :: proc "contextless" (debts: ^Picture_Debts, picture: int, changed: ^Damage, presented: bool) {
	if !presented {
		debts.known[picture] = false
		return
	}
	debts.known[picture] = true
	debts.owed[picture] = {}
	for rectangle in changed.rectangles[:changed.count] {
		damage_add(&debts.owed[1 - picture], rectangle)
	}
}
