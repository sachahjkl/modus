package vector_font

// The outlines of CFF and CFF2 (src/md/features/script_fonts.md, "A reader
// of CFF and CFF2"): the Compact Font Format of the tables "CFF " and
// "CFF2" of OpenType. A glyph is a Type 2 charstring: a small stack machine
// of moves, lines and cubic curves, with subroutines. The reader runs it
// and gives the outline of a TrueType glyph: each cubic curve becomes two
// quadratic curves, split at its middle, so the rasterizer stays one.
//
// A CFF2 font is variable: `blend` gives a value for each region of its
// variation store. The reader keeps the default instance: the default
// values, and none of the deltas.
//
// The table is hostile input, as the rest of the file: each read is checked
// against the table, each count bounds its loop, the subroutines call at
// most CFF_CALL_DEPTH levels deep, and a charstring runs at most
// CFF_STEP_LIMIT operators.

CFF_FONT_DICT_LIMIT :: 64 // The font dictionaries of a CID font (FDArray).
CFF_STACK_LIMIT :: 513 // The operands of a charstring (CFF2: 513, CFF: 48).
CFF_CALL_DEPTH :: 10 // The levels of the subroutines (CFF2, appendix: 10).
CFF_STEP_LIMIT :: 1 << 16 // The operators of one glyph, its subroutines included.
CFF_REGION_DATA_LIMIT :: 64 // The item variation data of a variation store.
CFF_DICT_OPERAND_LIMIT :: 64 // The operands of one operator of a dictionary.

// Cff_Index: an INDEX of the format, placed in the table: count items, the
// item i from data_base + offset(i) to data_base + offset(i + 1).
Cff_Index :: struct {
	count:       i32,
	offsets_at:  i32, // The place of the first offset.
	data_base:   i32, // The place before the first byte of the data: an offset is from it.
	offset_size: u8, // 1 to 4.
}

// Cff_Font: the parts of a table CFF or CFF2 that a glyph needs.
Cff_Font :: struct {
	table:             Table,
	version:           int, // 1: CFF, 2: CFF2; 0: none.
	char_strings:      Cff_Index,
	global_subrs:      Cff_Index,
	local_subrs:       [CFF_FONT_DICT_LIMIT]Cff_Index, // Of each font dictionary; the one of the Private dictionary for a font that is not CID.
	vsindex:           [CFF_FONT_DICT_LIMIT]u8, // The default variation data of each font dictionary (CFF2).
	font_dict_count:   int,
	fd_select:         i32, // The place of FDSelect; -1: each glyph takes the dictionary 0.
	region_counts:     [CFF_REGION_DATA_LIMIT]u16, // The regions of each item variation data (CFF2).
	region_data_count: int,
}

@(private)
cff_table :: #force_inline proc "contextless" (font: ^Font_File) -> []u8 {
	return font.bytes[font.cff.table.offset:][:font.cff.table.length]
}

// cff_index_read reads the header of an INDEX at a place of the table, and
// gives the place after it.
@(private)
cff_index_read :: proc "contextless" (table: []u8, at: int, version: int) -> (index: Cff_Index, end: int, problem: Font_Problem) {
	count, offset_size: int
	head: int
	read: bool
	if version == 2 {
		count, read = read_u32(table, at)
		head = at + 4
	} else {
		count, read = read_u16(table, at)
		head = at + 2
	}
	if !read {
		return {}, 0, .Too_Short
	}
	if count == 0 {
		return {}, head, .None
	}
	if head >= len(table) {
		return {}, 0, .Too_Short
	}
	offset_size = int(table[head])
	if offset_size < 1 || offset_size > 4 || count > len(table) {
		return {}, 0, .Unknown_Format
	}
	offsets_at := head + 1
	data_base := offsets_at + (count + 1) * offset_size - 1
	if data_base >= len(table) {
		return {}, 0, .Too_Short
	}
	index = {count = i32(count), offsets_at = i32(offsets_at), data_base = i32(data_base), offset_size = u8(offset_size)}
	last, last_ok := cff_offset(table, &index, count)
	if !last_ok || data_base + last > len(table) {
		return {}, 0, .Too_Short
	}
	return index, data_base + last, .None
}

@(private)
cff_offset :: proc "contextless" (table: []u8, index: ^Cff_Index, item: int) -> (offset: int, ok: bool) {
	at := int(index.offsets_at) + item * int(index.offset_size)
	if at < 0 || at + int(index.offset_size) > len(table) {
		return 0, false
	}
	for byte_index in 0 ..< int(index.offset_size) {
		offset = offset << 8 | int(table[at + byte_index])
	}
	return offset, offset >= 1
}

// cff_item gives the bytes of one item of an INDEX.
@(private)
cff_item :: proc "contextless" (table: []u8, index: ^Cff_Index, item: int) -> (data: []u8, ok: bool) {
	if item < 0 || item >= int(index.count) {
		return nil, false
	}
	start := cff_offset(table, index, item) or_return
	end := cff_offset(table, index, item + 1) or_return
	first, last := int(index.data_base) + start, int(index.data_base) + end
	if end < start || last > len(table) {
		return nil, false
	}
	return table[first:last], true
}

// Cff_Dict: the values of a dictionary that the reader uses; -1 for a key
// that the dictionary lacks.
@(private)
Cff_Dict :: struct {
	char_strings:   int, // 17.
	private_size:   int, // 18, its first operand.
	private_offset: int, // 18, its second operand.
	fd_array:       int, // 12 36.
	fd_select:      int, // 12 37.
	cid:            bool, // 12 30, ROS: a CID font.
	subrs:          int, // 19, from the start of the Private dictionary.
	variation:      int, // 24, CFF2: the variation store.
	vsindex:        int, // 22, CFF2.
}

// cff_dict_read reads the keys of a dictionary. A real number is read as
// 0: no key that the reader uses holds one. In CFF2, blend leaves the
// default values of its operands.
@(private)
cff_dict_read :: proc "contextless" (font: ^Font_File, data: []u8) -> (dict: Cff_Dict, problem: Font_Problem) {
	dict = {-1, -1, -1, -1, -1, false, -1, -1, 0}
	operands: [CFF_DICT_OPERAND_LIMIT]int
	count := 0
	at := 0
	for at < len(data) {
		code := int(data[at])
		at += 1
		value: int
		is_operand := true
		switch {
		case code == 28:
			if at + 2 > len(data) {
				return dict, .Too_Short
			}
			value = int(i16(u16(data[at]) << 8 | u16(data[at + 1])))
			at += 2
		case code == 29:
			if at + 4 > len(data) {
				return dict, .Too_Short
			}
			value = int(i32(u32(data[at]) << 24 | u32(data[at + 1]) << 16 | u32(data[at + 2]) << 8 | u32(data[at + 3])))
			at += 4
		case code == 30:
			// A real number: nibbles until one of 0xF.
			for {
				if at >= len(data) {
					return dict, .Too_Short
				}
				nibbles := data[at]
				at += 1
				if nibbles & 0x0F == 0x0F || nibbles >> 4 == 0x0F {
					break
				}
			}
		case code >= 32 && code <= 246:
			value = code - 139
		case code >= 247 && code <= 250:
			if at >= len(data) {
				return dict, .Too_Short
			}
			value = (code - 247) * 256 + int(data[at]) + 108
			at += 1
		case code >= 251 && code <= 254:
			if at >= len(data) {
				return dict, .Too_Short
			}
			value = -(code - 251) * 256 - int(data[at]) - 108
			at += 1
		case:
			is_operand = false
		}
		if is_operand {
			if count >= CFF_DICT_OPERAND_LIMIT {
				return dict, .Unknown_Format
			}
			operands[count] = value
			count += 1
			continue
		}
		operator := code
		if code == 12 {
			if at >= len(data) {
				return dict, .Too_Short
			}
			operator = 1200 + int(data[at])
			at += 1
		}
		switch operator {
		case 17:
			if count >= 1 {dict.char_strings = operands[count - 1]}
		case 18:
			if count >= 2 {dict.private_size, dict.private_offset = operands[count - 2], operands[count - 1]}
		case 19:
			if count >= 1 {dict.subrs = operands[count - 1]}
		case 22:
			if count >= 1 {dict.vsindex = operands[count - 1]}
		case 23:
			// blend: n defaults, n times k deltas, then n.
			if count < 1 {
				return dict, .Unknown_Format
			}
			blended := operands[count - 1]
			regions := cff_regions_of(font, dict.vsindex)
			needed := blended * (regions + 1) + 1
			if blended < 0 || needed > count {
				return dict, .Unknown_Format
			}
			count = count - needed + blended
			continue // The defaults stay for the next operator.
		case 24:
			if count >= 1 {dict.variation = operands[count - 1]}
		case 1230:
			dict.cid = true
		case 1236:
			if count >= 1 {dict.fd_array = operands[count - 1]}
		case 1237:
			if count >= 1 {dict.fd_select = operands[count - 1]}
		}
		count = 0
	}
	return dict, .None
}

// cff_regions_of gives the regions of an item variation data, 0 for one
// that the store lacks.
@(private)
cff_regions_of :: proc "contextless" (font: ^Font_File, vsindex: int) -> int {
	if vsindex < 0 || vsindex >= font.cff.region_data_count {
		return 0
	}
	return int(font.cff.region_counts[vsindex])
}

// cff_private_read reads the local subroutines and the variation data of
// a Private dictionary into the font dictionary number.
@(private)
cff_private_read :: proc "contextless" (font: ^Font_File, table: []u8, size, offset, number: int) -> Font_Problem {
	if size < 0 || offset < 0 || offset > len(table) || size > len(table) - offset {
		return .Too_Short
	}
	private := cff_dict_read(font, table[offset:][:size]) or_return
	font.cff.vsindex[number] = u8(clamp(private.vsindex, 0, 255))
	if private.subrs > 0 {
		index, _ := cff_index_read(table, offset + private.subrs, font.cff.version) or_return
		font.cff.local_subrs[number] = index
	}
	return .None
}

// cff_open reads the table CFF or CFF2 of a font: its charstrings, its
// global subroutines, and the local subroutines of each font dictionary.
@(private)
cff_open :: proc "contextless" (font: ^Font_File) -> Font_Problem {
	table := cff_table(font)
	version := font.cff.version
	font.cff.fd_select = -1
	if len(table) < 5 {
		return .Too_Short
	}
	if int(table[0]) != version {
		return .Unknown_Format
	}
	header_size := int(table[2])
	top: []u8
	global_at: int
	if version == 2 {
		top_size := read_u16(table, 3) or_else -1
		if top_size < 0 || header_size + top_size > len(table) {
			return .Too_Short
		}
		top = table[header_size:][:top_size]
		global_at = header_size + top_size
	} else {
		names, after_names := cff_index_read(table, header_size, 1) or_return
		_ = names
		tops, after_tops := cff_index_read(table, after_names, 1) or_return
		_, after_strings := cff_index_read(table, after_tops, 1) or_return
		top = cff_item(table, &tops, 0) or_else nil
		if top == nil {
			return .Unknown_Format
		}
		global_at = after_strings
	}
	font.cff.global_subrs, _ = cff_index_read(table, global_at, version) or_return
	// The variation store comes first: a blend in a dictionary needs it.
	first := cff_dict_read(font, top) or_return
	if version == 2 && first.variation > 0 {
		cff_variation_read(font, table, first.variation) or_return
	}
	dict := cff_dict_read(font, top) or_return
	if dict.char_strings <= 0 {
		return .Missing_Table
	}
	font.cff.char_strings, _ = cff_index_read(table, dict.char_strings, version) or_return
	if int(font.cff.char_strings.count) < font.glyph_count {
		return .Unknown_Format
	}
	if dict.fd_array > 0 {
		fonts, _ := cff_index_read(table, dict.fd_array, version) or_return
		if fonts.count < 1 || int(fonts.count) > CFF_FONT_DICT_LIMIT {
			return .Unknown_Format
		}
		font.cff.font_dict_count = int(fonts.count)
		for number in 0 ..< int(fonts.count) {
			data, read := cff_item(table, &fonts, number)
			if !read {
				return .Too_Short
			}
			font_dict := cff_dict_read(font, data) or_return
			if font_dict.private_offset >= 0 {
				cff_private_read(font, table, font_dict.private_size, font_dict.private_offset, number) or_return
			}
		}
		if dict.fd_select > 0 {
			if dict.fd_select >= len(table) {
				return .Too_Short
			}
			font.cff.fd_select = i32(dict.fd_select)
		}
	} else {
		font.cff.font_dict_count = 1
		if dict.private_offset >= 0 {
			cff_private_read(font, table, dict.private_size, dict.private_offset, 0) or_return
		}
	}
	return .None
}

// cff_variation_read reads the count of regions of each item variation
// data of the variation store of a CFF2 table: the count that a blend
// needs. Its deltas are not read: the reader keeps the default instance.
@(private)
cff_variation_read :: proc "contextless" (font: ^Font_File, table: []u8, at: int) -> Font_Problem {
	store := at + 2 // A length of 2 bytes, then the item variation store.
	format := read_u16(table, store) or_else -1
	data_count := read_u16(table, store + 6) or_else -1
	if format != 1 || data_count < 0 {
		return .Unknown_Format
	}
	if data_count > CFF_REGION_DATA_LIMIT {
		return .Unknown_Format
	}
	for number in 0 ..< data_count {
		offset := read_u32(table, store + 8 + 4 * number) or_else -1
		regions := read_u16(table, store + offset + 4) or_else -1
		if offset < 0 || regions < 0 {
			return .Too_Short
		}
		font.cff.region_counts[number] = u16(regions)
	}
	font.cff.region_data_count = data_count
	return .None
}

// cff_font_dict_of gives the font dictionary of a glyph, from FDSelect.
@(private)
cff_font_dict_of :: proc "contextless" (font: ^Font_File, table: []u8, glyph: int) -> (number: int, problem: Font_Problem) {
	if font.cff.fd_select < 0 {
		return 0, .None
	}
	at := int(font.cff.fd_select)
	format := int(table[at])
	switch format {
	case 0:
		if at + 1 + glyph >= len(table) {
			return 0, .Too_Short
		}
		number = int(table[at + 1 + glyph])
	case 3, 4:
		wide := format == 4
		ranges := cff_number_at(table, at + 1, wide) or_else -1
		size := wide ? 6 : 3
		first_at := at + (wide ? 5 : 3)
		if ranges < 1 || first_at + ranges * size + (wide ? 4 : 2) > len(table) {
			return 0, .Too_Short
		}
		// The last range whose first glyph is at most the glyph, by halves.
		low, high := 0, ranges
		for high - low > 1 {
			middle := low + (high - low) / 2
			first := cff_number_at(table, first_at + middle * size, wide) or_else 0
			if first <= glyph {
				low = middle
			} else {
				high = middle
			}
		}
		if wide {
			number = read_u16(table, first_at + low * size + 4) or_else 0
		} else {
			number = int(table[first_at + low * size + 2])
		}
	case:
		return 0, .Unknown_Format
	}
	if number >= font.cff.font_dict_count {
		return 0, .Unknown_Format
	}
	return number, .None
}

// cff_number_at reads a number of 32 bits when wide, else of 16 bits.
@(private)
cff_number_at :: proc "contextless" (table: []u8, at: int, wide: bool) -> (value: int, ok: bool) {
	if wide {
		return read_u32(table, at)
	}
	return read_u16(table, at)
}

// The bias of a subroutine number (the Type 2 Charstring Format, 4.7).
@(private)
cff_bias :: proc "contextless" (count: i32) -> int {
	switch {
	case count < 1240:
		return 107
	case count < 33900:
		return 1131
	}
	return 32768
}

// Cff_Machine: the state of the run of one charstring. The values are in
// 16.16 fixed point; a point is rounded to a whole unit.
@(private)
Cff_Machine :: struct {
	font:          ^Font_File,
	table:         []u8,
	outline:       ^Outline,
	local:         ^Cff_Index,
	stack:         [CFF_STACK_LIMIT]i64,
	count:         int,
	x, y:          i64,
	stems:         int,
	width_done:    bool, // CFF: the first operator that clears the stack took the width, if any.
	contour_first: int, // The first point of the open contour; -1 when none is open.
	regions:       int,
	steps:         int,
	ended:         bool,
	problem:       Font_Problem,
}

// cff_glyph_outline reads the outline of a glyph of a CFF or CFF2 font.
@(private)
cff_glyph_outline :: proc "contextless" (font: ^Font_File, glyph: int, outline: ^Outline) -> Font_Problem {
	table := cff_table(font)
	data, read := cff_item(table, &font.cff.char_strings, glyph)
	if !read {
		return .Too_Short
	}
	number := cff_font_dict_of(font, table, glyph) or_return
	machine := Cff_Machine{font = font, table = table, outline = outline, local = &font.cff.local_subrs[number], contour_first = -1, width_done = font.cff.version == 2}
	machine.regions = cff_regions_of(font, int(font.cff.vsindex[number]))
	cff_run(&machine, data, 0)
	if machine.problem != .None {
		outline.point_count, outline.contour_count = 0, 0
		return machine.problem
	}
	cff_contour_close(&machine)
	return machine.problem
}

@(private)
cff_fail :: #force_inline proc "contextless" (machine: ^Cff_Machine, problem: Font_Problem) {
	if machine.problem == .None {
		machine.problem = problem
	}
}

@(private)
cff_point :: proc "contextless" (machine: ^Cff_Machine, x, y: i64, on_curve: bool) {
	outline := machine.outline
	if outline.point_count >= len(outline.points) {
		cff_fail(machine, .Too_Many_Points)
		return
	}
	outline.points[outline.point_count] = {x = i32(clamp((x + 0x8000) >> 16, -32768, 32767)), y = i32(clamp((y + 0x8000) >> 16, -32768, 32767)), on_curve = on_curve}
	outline.point_count += 1
}

// cff_contour_close ends the open contour: a contour of one point, a move
// with no line, leaves no point.
@(private)
cff_contour_close :: proc "contextless" (machine: ^Cff_Machine) {
	outline := machine.outline
	if machine.contour_first < 0 {
		return
	}
	if outline.point_count - machine.contour_first < 2 {
		outline.point_count = machine.contour_first
	} else if outline.contour_count >= len(outline.contour_ends) {
		cff_fail(machine, .Too_Many_Points)
	} else {
		outline.contour_ends[outline.contour_count] = outline.point_count
		outline.contour_count += 1
	}
	machine.contour_first = -1
}

@(private)
cff_move :: proc "contextless" (machine: ^Cff_Machine, dx, dy: i64) {
	cff_contour_close(machine)
	machine.x += dx
	machine.y += dy
	machine.contour_first = machine.outline.point_count
	cff_point(machine, machine.x, machine.y, true)
}

@(private)
cff_line :: proc "contextless" (machine: ^Cff_Machine, dx, dy: i64) {
	if machine.contour_first < 0 {
		cff_move(machine, 0, 0)
	}
	machine.x += dx
	machine.y += dy
	cff_point(machine, machine.x, machine.y, true)
}

// cff_curve adds a cubic curve from the current point by three relative
// steps, as two quadratic curves split at its middle: each with the
// control point (3 (c1 + c2) - p0 - p3) / 4 of its half.
@(private)
cff_curve :: proc "contextless" (machine: ^Cff_Machine, dx1, dy1, dx2, dy2, dx3, dy3: i64) {
	if machine.contour_first < 0 {
		cff_move(machine, 0, 0)
	}
	x0, y0 := machine.x, machine.y
	x1, y1 := x0 + dx1, y0 + dy1
	x2, y2 := x1 + dx2, y1 + dy2
	x3, y3 := x2 + dx3, y2 + dy3
	// de Casteljau at the middle.
	ax, ay := (x0 + x1) / 2, (y0 + y1) / 2
	bx, by := (x1 + x2) / 2, (y1 + y2) / 2
	cx, cy := (x2 + x3) / 2, (y2 + y3) / 2
	dx, dy := (ax + bx) / 2, (ay + by) / 2
	ex, ey := (bx + cx) / 2, (by + cy) / 2
	mx, my := (dx + ex) / 2, (dy + ey) / 2
	cff_point(machine, (3 * (ax + dx) - x0 - mx) / 4, (3 * (ay + dy) - y0 - my) / 4, false)
	cff_point(machine, mx, my, true)
	cff_point(machine, (3 * (ex + cx) - mx - x3) / 4, (3 * (ey + cy) - my - y3) / 4, false)
	cff_point(machine, x3, y3, true)
	machine.x, machine.y = x3, y3
}

// cff_width_take drops the width of a CFF glyph: an operand before the
// arguments of the first operator that clears the stack, when the count
// of the operands says there is one.
@(private)
cff_width_take :: proc "contextless" (machine: ^Cff_Machine, has_width: bool) -> (first: int) {
	if machine.width_done {
		return 0
	}
	machine.width_done = true
	return has_width ? 1 : 0
}

@(private)
cff_run :: proc "contextless" (machine: ^Cff_Machine, data: []u8, depth: int) {
	if depth > CFF_CALL_DEPTH {
		cff_fail(machine, .Composite_Too_Deep)
		return
	}
	at := 0
	for at < len(data) && machine.problem == .None && !machine.ended {
		machine.steps += 1
		if machine.steps > CFF_STEP_LIMIT {
			cff_fail(machine, .Composite_Too_Deep)
			return
		}
		code := int(data[at])
		at += 1
		// An operand.
		if code == 28 || code >= 32 {
			value: i64
			switch {
			case code == 28:
				if at + 2 > len(data) {
					cff_fail(machine, .Too_Short)
					return
				}
				value = i64(i16(u16(data[at]) << 8 | u16(data[at + 1]))) << 16
				at += 2
			case code <= 246:
				value = i64(code - 139) << 16
			case code <= 250:
				if at >= len(data) {
					cff_fail(machine, .Too_Short)
					return
				}
				value = i64((code - 247) * 256 + int(data[at]) + 108) << 16
				at += 1
			case code <= 254:
				if at >= len(data) {
					cff_fail(machine, .Too_Short)
					return
				}
				value = i64(-(code - 251) * 256 - int(data[at]) - 108) << 16
				at += 1
			case:
				if at + 4 > len(data) {
					cff_fail(machine, .Too_Short)
					return
				}
				value = i64(i32(u32(data[at]) << 24 | u32(data[at + 1]) << 16 | u32(data[at + 2]) << 8 | u32(data[at + 3])))
				at += 4
			}
			if machine.count >= CFF_STACK_LIMIT {
				cff_fail(machine, .Unknown_Format)
				return
			}
			machine.stack[machine.count] = value
			machine.count += 1
			continue
		}
		s := machine.stack[:machine.count]
		n := machine.count
		switch code {
		case 1, 3, 18, 23: // hstem, vstem, hstemhm, vstemhm
			first := cff_width_take(machine, n % 2 == 1)
			machine.stems += (n - first) / 2
			machine.count = 0
		case 19, 20: // hintmask, cntrmask: the stems of an implied vstem, then the mask.
			first := cff_width_take(machine, n % 2 == 1)
			machine.stems += (n - first) / 2
			machine.count = 0
			at += (machine.stems + 7) / 8
		case 21: // rmoveto
			first := cff_width_take(machine, n > 2)
			if n - first < 2 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			cff_move(machine, s[first], s[first + 1])
			machine.count = 0
		case 22, 4: // hmoveto, vmoveto
			first := cff_width_take(machine, n > 1)
			if n - first < 1 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			if code == 22 {
				cff_move(machine, s[first], 0)
			} else {
				cff_move(machine, 0, s[first])
			}
			machine.count = 0
		case 5: // rlineto
			for index := 0; index + 1 < n; index += 2 {
				cff_line(machine, s[index], s[index + 1])
			}
			machine.count = 0
		case 6, 7: // hlineto, vlineto: alternate.
			horizontal := code == 6
			for index in 0 ..< n {
				if horizontal {
					cff_line(machine, s[index], 0)
				} else {
					cff_line(machine, 0, s[index])
				}
				horizontal = !horizontal
			}
			machine.count = 0
		case 8: // rrcurveto
			for index := 0; index + 5 < n; index += 6 {
				cff_curve(machine, s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5])
			}
			machine.count = 0
		case 24: // rcurveline
			index := 0
			for ; index + 7 < n; index += 6 {
				cff_curve(machine, s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5])
			}
			if index + 1 < n {
				cff_line(machine, s[index], s[index + 1])
			}
			machine.count = 0
		case 25: // rlinecurve
			index := 0
			for ; index + 7 < n; index += 2 {
				cff_line(machine, s[index], s[index + 1])
			}
			if index + 5 < n {
				cff_curve(machine, s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5])
			}
			machine.count = 0
		case 26: // vvcurveto
			index := 0
			dx1: i64
			if n % 2 == 1 {
				dx1 = s[0]
				index = 1
			}
			for ; index + 3 < n; index += 4 {
				cff_curve(machine, dx1, s[index], s[index + 1], s[index + 2], 0, s[index + 3])
				dx1 = 0
			}
			machine.count = 0
		case 27: // hhcurveto
			index := 0
			dy1: i64
			if n % 2 == 1 {
				dy1 = s[0]
				index = 1
			}
			for ; index + 3 < n; index += 4 {
				cff_curve(machine, s[index], dy1, s[index + 1], s[index + 2], s[index + 3], 0)
				dy1 = 0
			}
			machine.count = 0
		case 30, 31: // vhcurveto, hvcurveto
			horizontal := code == 31
			index := 0
			for index + 3 < n {
				last: i64
				if n - index == 5 {
					last = s[index + 4]
				}
				if horizontal {
					cff_curve(machine, s[index], 0, s[index + 1], s[index + 2], last, s[index + 3])
				} else {
					cff_curve(machine, 0, s[index], s[index + 1], s[index + 2], s[index + 3], last)
				}
				index += n - index == 5 ? 5 : 4
				horizontal = !horizontal
			}
			machine.count = 0
		case 10, 29: // callsubr, callgsubr
			if n < 1 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			subrs := code == 10 ? machine.local : &machine.font.cff.global_subrs
			number := int(s[n - 1] >> 16) + cff_bias(subrs.count)
			machine.count -= 1
			sub, read := cff_item(machine.table, subrs, number)
			if !read {
				cff_fail(machine, .Unknown_Format)
				return
			}
			cff_run(machine, sub, depth + 1)
		case 11: // return
			return
		case 14: // endchar
			if machine.font.cff.version == 2 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			cff_width_take(machine, n == 1 || n == 5)
			cff_contour_close(machine)
			machine.count = 0
			machine.ended = true
			return
		case 15: // vsindex (CFF2)
			if n < 1 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			machine.regions = cff_regions_of(machine.font, int(s[n - 1] >> 16))
			machine.count = 0
		case 16: // blend (CFF2): keep the defaults, drop the deltas.
			if n < 1 {
				cff_fail(machine, .Unknown_Format)
				return
			}
			blended := int(s[n - 1] >> 16)
			needed := blended * (machine.regions + 1) + 1
			if blended < 0 || needed > n {
				cff_fail(machine, .Unknown_Format)
				return
			}
			machine.count = n - needed + blended
		case 12:
			if at >= len(data) {
				cff_fail(machine, .Too_Short)
				return
			}
			escape := int(data[at])
			at += 1
			switch escape {
			case 35: // flex
				if n < 13 {cff_fail(machine, .Unknown_Format); return}
				cff_curve(machine, s[0], s[1], s[2], s[3], s[4], s[5])
				cff_curve(machine, s[6], s[7], s[8], s[9], s[10], s[11])
			case 34: // hflex
				if n < 7 {cff_fail(machine, .Unknown_Format); return}
				cff_curve(machine, s[0], 0, s[1], s[2], s[3], 0)
				cff_curve(machine, s[4], 0, s[5], -s[2], s[6], 0)
			case 36: // hflex1
				if n < 9 {cff_fail(machine, .Unknown_Format); return}
				cff_curve(machine, s[0], s[1], s[2], s[3], s[4], 0)
				cff_curve(machine, s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]))
			case 37: // flex1
				if n < 11 {cff_fail(machine, .Unknown_Format); return}
				sum_x := s[0] + s[2] + s[4] + s[6] + s[8]
				sum_y := s[1] + s[3] + s[5] + s[7] + s[9]
				cff_curve(machine, s[0], s[1], s[2], s[3], s[4], s[5])
				if abs(sum_x) > abs(sum_y) {
					cff_curve(machine, s[6], s[7], s[8], s[9], s[10], -sum_y)
				} else {
					cff_curve(machine, s[6], s[7], s[8], s[9], -sum_x, s[10])
				}
			case:
				cff_fail(machine, .Unknown_Format)
				return
			}
			machine.count = 0
		case:
			cff_fail(machine, .Unknown_Format)
			return
		}
	}
}
