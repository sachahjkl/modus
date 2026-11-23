package fuzz

import "core:slice"
import "modus:contract/memory_screen"
import protocol "modus:contract/remote_display"

// The fuzz target of the remote display (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the service reads each record of a
// viewer that its handshake admitted, and a viewer reads each record of the
// service, with the screen pieces in their coder. The input is a screen, then
// records one after the other; the direction of each record is a bit of
// its kind word, as a hostile party chooses it. The oracles: a refusal
// gives no record; a record that the border takes writes again to its own
// bytes, names a rectangle inside the screen, and a screen piece whose code holds
// decodes, and its pixels code and decode to the same pixels; the input
// does not change.

FUZZ_REMOTE_DISPLAY_INPUT_LIMIT :: 64 << 10

@(private = "file")
fuzz_remote_display_pixels: [protocol.SCREEN_PIECE_PIXEL_LIMIT]u32
@(private = "file")
fuzz_remote_display_again: [protocol.SCREEN_PIECE_PIXEL_LIMIT]u32
@(private = "file")
fuzz_remote_display_code: [protocol.CODED_SCREEN_PIECE_LIMIT]u8

fuzz_remote_display_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	if len(input) < 8 {
		return FUZZ_PASSED
	}
	screen := protocol.Screen{u32(input[0]) | u32(input[1]) << 8, u32(input[2]) | u32(input[3]) << 8}
	place := 8
	for place + protocol.RECORD_HEADER_SIZE <= len(input) {
		header, _ := protocol.header_read(input[place:])
		direction := protocol.Direction.To_Viewer
		if input[place + 7] & 0x80 != 0 {
			// The high bit of the length chooses the direction; it is
			// cleared, so the length stays in the input.
			direction = .To_Service
			header.length &= 0x7FFF_FFFF
		}
		place += protocol.RECORD_HEADER_SIZE
		problem := protocol.record_length_problem(header, direction)
		if problem != .None {
			continue
		}
		length := min(int(header.length), len(input) - place)
		body := input[place:][:length]
		place += length
		verdict: Fuzz_Verdict
		if direction == .To_Service {
			verdict = fuzz_remote_display_viewer_check(header, body, screen)
		} else {
			verdict = fuzz_remote_display_service_check(header, body, screen)
		}
		if verdict.oracle != .None {
			return verdict
		}
	}
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "a border of the remote display changed the bytes of its input")
	}
	return FUZZ_PASSED
}

// fuzz_remote_display_rewrite writes a body again with its kind, and
// compares the bytes with the bytes that the border read.
@(private = "file")
fuzz_remote_display_rewrite :: proc(kind: protocol.Record_Kind, body: $T, read: []u8) -> bool {
	out: [protocol.RECORD_HEADER_SIZE + 64]u8
	bytes, ok := protocol.record_write(out[:], kind, body)
	return ok && slice.equal(bytes[protocol.RECORD_HEADER_SIZE:], read)
}

@(private = "file")
fuzz_remote_display_viewer_check :: proc(header: protocol.Record_Header, body: []u8, screen: protocol.Screen) -> Fuzz_Verdict {
	record, problem := protocol.viewer_record_check(header, body, screen)
	if problem != .None {
		if record != (protocol.Viewer_Record{}) {
			return fuzz_broken(.Contract, "viewer_record_check refuses with %v and gives a record", problem)
		}
		return FUZZ_PASSED
	}
	if protocol.kind_direction(record.kind) != .To_Service {
		return fuzz_broken(.Contract, "viewer_record_check takes the kind %v of the service", record.kind)
	}
	same := false
	switch record.kind {
	case .None, .Screen_Size, .Viewer_Frame_Start, .Screen_Piece, .Viewer_Frame_End, .Pointer_Place, .Pointer_Shape, .Pointer_Picture, .Pointer_Warp, .Screen_Size_Refused:
		return fuzz_broken(.Contract, "viewer_record_check takes the kind %v", record.kind)
	case .Screen_Size_Ask:
		ask := record.screen_size_ask
		same = fuzz_remote_display_rewrite(record.kind, ask, body) && memory_screen.size_in_bounds(u64(ask.width), u64(ask.height))
	case .Session_Start:
		same = fuzz_remote_display_rewrite(record.kind, record.session_start, body) && record.session_start.version == protocol.PROTOCOL_VERSION
	case .Viewer_Frame_Taken:
		same = fuzz_remote_display_rewrite(record.kind, record.viewer_frame_taken, body) && record.viewer_frame_taken.serial != 0
	case .Screen_Piece_Request:
		request := record.screen_piece_request
		inside := request.width > 0 && request.height > 0 && u64(request.x) + u64(request.width) <= u64(screen.width) && u64(request.y) + u64(request.height) <= u64(screen.height)
		same = fuzz_remote_display_rewrite(record.kind, request, body) && inside
	case .Key:
		key := record.key
		same = fuzz_remote_display_rewrite(record.kind, key, body) && key.code != 0 && key.code <= protocol.KEY_CODE_LIMIT && key.code & protocol.KEY_RELEASE_BIT == 0 && key.pressed <= 1
	case .Pointer:
		pointer := record.pointer
		same = fuzz_remote_display_rewrite(record.kind, pointer, body) && pointer.x < screen.width && pointer.y < screen.height
	}
	if !same {
		return fuzz_broken(.Round_Trip, "the record %v that viewer_record_check takes is not its bytes, or breaks its range", record.kind)
	}
	return FUZZ_PASSED
}

@(private = "file")
fuzz_remote_display_service_check :: proc(header: protocol.Record_Header, body: []u8, screen: protocol.Screen) -> Fuzz_Verdict {
	record, problem := protocol.service_record_check(header, body, screen)
	if problem != .None {
		if record.kind != .None || record.coded != nil {
			return fuzz_broken(.Contract, "service_record_check refuses with %v and gives a record", problem)
		}
		return FUZZ_PASSED
	}
	switch record.kind {
	case .None, .Viewer_Frame_Taken, .Screen_Piece_Request, .Key, .Pointer, .Session_Start, .Screen_Size_Ask:
		return fuzz_broken(.Contract, "service_record_check takes the kind %v", record.kind)
	case .Screen_Size_Refused:
		refused := record.screen_size_refused
		if protocol.screen_problem({refused.width, refused.height}) != .None || record.refusal == .None || u32(record.refusal) != refused.refusal || refused.reserved != 0 || !fuzz_remote_display_rewrite(record.kind, refused, body) {
			return fuzz_broken(.Round_Trip, "service_record_check takes a bad Screen_Size_Refused: %v", refused)
		}
	case .Screen_Size:
		if protocol.screen_problem({record.screen_size.width, record.screen_size.height}) != .None || !fuzz_remote_display_rewrite(record.kind, record.screen_size, body) {
			return fuzz_broken(.Round_Trip, "service_record_check takes the screen %v", record.screen_size)
		}
	case .Viewer_Frame_Start:
		start := record.viewer_frame_start
		if u64(start.screen_piece_count) > protocol.viewer_frame_piece_limit(screen) || start.bytes > protocol.viewer_frame_bytes_limit(screen) || start.serial == 0 {
			return fuzz_broken(.Contract, "service_record_check takes a viewer frame past its bound: %v", start)
		}
	case .Screen_Piece:
		screen_piece := record.screen_piece
		count := int(screen_piece.width * screen_piece.height)
		switch {
		case screen_piece.width == 0 || screen_piece.height == 0 || screen_piece.width > protocol.SCREEN_PIECE_WIDTH || screen_piece.height > protocol.SCREEN_PIECE_HEIGHT:
			return fuzz_broken(.Contract, "service_record_check takes the screen piece %v", screen_piece)
		case u64(screen_piece.x) + u64(screen_piece.width) > u64(screen.width) || u64(screen_piece.y) + u64(screen_piece.height) > u64(screen.height):
			return fuzz_broken(.Contract, "service_record_check takes a screen piece outside the screen: %v", screen_piece)
		case len(record.coded) != int(screen_piece.coded_length) || raw_data(record.coded) != raw_data(body[size_of(protocol.Screen_Piece_Header):]):
			return fuzz_broken(.Contract, "the code of the screen piece is not the bytes after its header")
		}
		// A code that decodes holds: its pixels code and decode to the
		// same pixels.
		if protocol.screen_piece_decode(record.coded, fuzz_remote_display_pixels[:count]) == .None {
			coded := protocol.screen_piece_encode(fuzz_remote_display_pixels[:count], int(screen_piece.width), 0, 0, int(screen_piece.width), int(screen_piece.height), fuzz_remote_display_code[:])
			if coded > int(protocol.coded_limit(u32(count))) {
				return fuzz_broken(.Contract, "the code of %d pixels is %d bytes, past its limit", count, coded)
			}
			again := protocol.screen_piece_decode(fuzz_remote_display_code[:coded], fuzz_remote_display_again[:count])
			if again != .None || !slice.equal(fuzz_remote_display_pixels[:count], fuzz_remote_display_again[:count]) {
				return fuzz_broken(.Round_Trip, "the pixels of a screen piece do not code and decode to themselves (%v)", again)
			}
		}
	case .Viewer_Frame_End:
		if record.viewer_frame_end.serial == 0 {
			return fuzz_broken(.Contract, "service_record_check takes the serial 0")
		}
	case .Pointer_Place:
		if record.pointer_place.x >= screen.width || record.pointer_place.y >= screen.height {
			return fuzz_broken(.Contract, "service_record_check takes a pointer outside the screen")
		}
	case .Pointer_Shape:
		shape := record.pointer_shape
		if shape.size < protocol.POINTER_SIZE_MINIMUM || shape.size > protocol.POINTER_SIZE_MAXIMUM || shape.hot_spot_x >= shape.size || shape.hot_spot_y >= shape.size || shape.reserved != 0 || !fuzz_remote_display_rewrite(record.kind, shape, body) {
			return fuzz_broken(.Round_Trip, "service_record_check takes a bad Pointer_Shape: %v", shape)
		}
	case .Pointer_Picture:
		pic := record.pointer_picture
		if pic.size < protocol.POINTER_SIZE_MINIMUM || pic.size > protocol.POINTER_SIZE_MAXIMUM || pic.hot_spot_x >= pic.size || pic.hot_spot_y >= pic.size || pic.reserved != 0 || len(record.pointer_pixels) != int(pic.size * pic.size * 4) {
			return fuzz_broken(.Contract, "service_record_check takes a bad Pointer_Picture: %v", pic)
		}
	case .Pointer_Warp:
		warp := record.pointer_warp
		if warp.x >= screen.width || warp.y >= screen.height || !fuzz_remote_display_rewrite(record.kind, warp, body) {
			return fuzz_broken(.Round_Trip, "service_record_check takes a bad Pointer_Warp: %v", warp)
		}
	}
	return FUZZ_PASSED
}

fuzz_remote_display_seeds :: proc(seeds: ^[dynamic][]u8) {
	seed := make([dynamic]u8)
	screen := [8]u8{0x00, 0x05, 0x20, 0x03, 0, 0, 0, 0} // 1280 x 800.
	append(&seed, ..screen[:])
	out: [protocol.RECORD_HEADER_SIZE + protocol.SCREEN_PIECE_BODY_LIMIT]u8
	add :: proc(seed: ^[dynamic]u8, bytes: []u8, to_service: bool) {
		start := len(seed^)
		append(seed, ..bytes)
		if to_service {
			seed^[start + 7] |= 0x80
		}
	}
	bytes, _ := protocol.record_write(out[:], .Session_Start, protocol.Session_Start_Body{version = protocol.PROTOCOL_VERSION})
	add(&seed, bytes, true)
	bytes, _ = protocol.record_write(out[:], .Key, protocol.Key_Body{code = 0x1E, character = 'a', pressed = 1})
	add(&seed, bytes, true)
	bytes, _ = protocol.record_write(out[:], .Screen_Piece_Request, protocol.Screen_Piece_Request_Body{x = 10, y = 20, width = 30, height = 40})
	add(&seed, bytes, true)
	bytes, _ = protocol.record_write(out[:], .Screen_Size, protocol.Screen_Size_Body{1280, 800})
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Screen_Size_Ask, protocol.Screen_Size_Body{2560, 1440})
	add(&seed, bytes, true)
	bytes, _ = protocol.record_write(out[:], .Screen_Size_Refused, protocol.Screen_Size_Refused_Body{width = 2560, height = 1440, refusal = u32(memory_screen.Resize_Refusal.Device_Screen)})
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Pointer_Shape, protocol.Pointer_Shape_Body{shape = 1, form = 0, size = 24, hot_spot_x = 11, hot_spot_y = 11})
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Pointer_Warp, protocol.Pointer_Warp_Body{x = 100, y = 200, input_echo_count = 1})
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Viewer_Frame_Start, protocol.Viewer_Frame_Start_Body{serial = 1, screen_piece_count = 1, bytes = 4096, input_echo_count = 1})
	add(&seed, bytes, false)
	pixels: [16 * 8]u32
	for &pixel, index in pixels {
		pixel = index < 64 ? 0x00203040 : u32(index) * 0x00010203
	}
	bytes, _ = protocol.screen_piece_record_write(out[:], pixels[:], 16, 0, 0, 16, 8)
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Viewer_Frame_End, protocol.Viewer_Frame_End_Body{serial = 1})
	add(&seed, bytes, false)
	append(seeds, seed[:])
}
