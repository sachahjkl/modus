package fuzz

import "core:slice"
import protocol "modus:contract/remote_display"

// The fuzz target of the remote display (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the service reads each record of a
// viewer that its handshake admitted, and a viewer reads each record of the
// service, with the tiles in their coder. The input is a screen, then
// records one after the other; the direction of each record is a bit of
// its kind word, as a hostile party chooses it. The oracles: a refusal
// gives no record; a record that the border takes writes again to its own
// bytes, names a rectangle inside the screen, and a tile whose code holds
// decodes, and its pixels code and decode to the same pixels; the input
// does not change.

FUZZ_REMOTE_DISPLAY_INPUT_LIMIT :: 64 << 10

@(private = "file")
fuzz_remote_display_pixels: [protocol.TILE_PIXEL_LIMIT]u32
@(private = "file")
fuzz_remote_display_again: [protocol.TILE_PIXEL_LIMIT]u32
@(private = "file")
fuzz_remote_display_code: [protocol.CODED_TILE_LIMIT]u8

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
	case .None, .Screen_Size, .Frame_Start, .Tile, .Frame_End, .Pointer_Place:
		return fuzz_broken(.Contract, "viewer_record_check takes the kind %v", record.kind)
	case .Session_Start:
		same = fuzz_remote_display_rewrite(record.kind, record.session_start, body) && record.session_start.version == protocol.PROTOCOL_VERSION
	case .Frame_Taken:
		same = fuzz_remote_display_rewrite(record.kind, record.frame_taken, body) && record.frame_taken.serial != 0
	case .Tile_Request:
		request := record.tile_request
		inside := request.width > 0 && request.height > 0 && u64(request.x) + u64(request.width) <= u64(screen.width) && u64(request.y) + u64(request.height) <= u64(screen.height)
		same = fuzz_remote_display_rewrite(record.kind, request, body) && inside
	case .Key:
		key := record.key
		same = fuzz_remote_display_rewrite(record.kind, key, body) && key.code != 0 && key.code <= protocol.KEY_CODE_LIMIT && key.pressed <= 1
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
	case .None, .Frame_Taken, .Tile_Request, .Key, .Pointer, .Session_Start:
		return fuzz_broken(.Contract, "service_record_check takes the kind %v", record.kind)
	case .Screen_Size:
		if protocol.screen_problem({record.screen_size.width, record.screen_size.height}) != .None || !fuzz_remote_display_rewrite(record.kind, record.screen_size, body) {
			return fuzz_broken(.Round_Trip, "service_record_check takes the screen %v", record.screen_size)
		}
	case .Frame_Start:
		start := record.frame_start
		if start.tile_count > protocol.FRAME_TILE_LIMIT || start.bytes > protocol.FRAME_BYTES_LIMIT || start.serial == 0 {
			return fuzz_broken(.Contract, "service_record_check takes a frame past its bound: %v", start)
		}
	case .Tile:
		tile := record.tile
		count := int(tile.width * tile.height)
		switch {
		case tile.width == 0 || tile.height == 0 || tile.width > protocol.TILE_WIDTH || tile.height > protocol.TILE_HEIGHT:
			return fuzz_broken(.Contract, "service_record_check takes the tile %v", tile)
		case u64(tile.x) + u64(tile.width) > u64(screen.width) || u64(tile.y) + u64(tile.height) > u64(screen.height):
			return fuzz_broken(.Contract, "service_record_check takes a tile outside the screen: %v", tile)
		case len(record.coded) != int(tile.coded_length) || raw_data(record.coded) != raw_data(body[size_of(protocol.Tile_Header):]):
			return fuzz_broken(.Contract, "the code of the tile is not the bytes after its header")
		}
		// A code that decodes holds: its pixels code and decode to the
		// same pixels.
		if protocol.tile_decode(record.coded, fuzz_remote_display_pixels[:count]) == .None {
			coded := protocol.tile_encode(fuzz_remote_display_pixels[:count], int(tile.width), 0, 0, int(tile.width), int(tile.height), fuzz_remote_display_code[:])
			if coded > int(protocol.coded_limit(u32(count))) {
				return fuzz_broken(.Contract, "the code of %d pixels is %d bytes, past its limit", count, coded)
			}
			again := protocol.tile_decode(fuzz_remote_display_code[:coded], fuzz_remote_display_again[:count])
			if again != .None || !slice.equal(fuzz_remote_display_pixels[:count], fuzz_remote_display_again[:count]) {
				return fuzz_broken(.Round_Trip, "the pixels of a tile do not code and decode to themselves (%v)", again)
			}
		}
	case .Frame_End:
		if record.frame_end.serial == 0 {
			return fuzz_broken(.Contract, "service_record_check takes the serial 0")
		}
	case .Pointer_Place:
		if record.pointer_place.x >= screen.width || record.pointer_place.y >= screen.height {
			return fuzz_broken(.Contract, "service_record_check takes a pointer outside the screen")
		}
	}
	return FUZZ_PASSED
}

fuzz_remote_display_seeds :: proc(seeds: ^[dynamic][]u8) {
	seed := make([dynamic]u8)
	screen := [8]u8{0x00, 0x05, 0x20, 0x03, 0, 0, 0, 0} // 1280 x 800.
	append(&seed, ..screen[:])
	out: [protocol.RECORD_HEADER_SIZE + protocol.TILE_BODY_LIMIT]u8
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
	bytes, _ = protocol.record_write(out[:], .Tile_Request, protocol.Tile_Request_Body{x = 10, y = 20, width = 30, height = 40})
	add(&seed, bytes, true)
	bytes, _ = protocol.record_write(out[:], .Screen_Size, protocol.Screen_Size_Body{1280, 800})
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Frame_Start, protocol.Frame_Start_Body{serial = 1, tile_count = 1, bytes = 4096})
	add(&seed, bytes, false)
	pixels: [16 * 8]u32
	for &pixel, index in pixels {
		pixel = index < 64 ? 0x00203040 : u32(index) * 0x00010203
	}
	bytes, _ = protocol.tile_record_write(out[:], pixels[:], 16, 0, 0, 16, 8)
	add(&seed, bytes, false)
	bytes, _ = protocol.record_write(out[:], .Frame_End, protocol.Frame_End_Body{serial = 1})
	add(&seed, bytes, false)
	append(seeds, seed[:])
}
