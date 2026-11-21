#+build !freestanding
package remote_display

import "core:math/rand"
import "core:testing"

// The screen of the tests: the screen of the test machine.
@(private = "file")
SCREEN := Screen{1280, 800}

// body_bytes gives the bytes of a body, in the temporary memory.
@(private = "file")
body_bytes :: proc(body: $T) -> []u8 {
	bytes := make([]u8, size_of(T), context.temp_allocator)
	value := body
	copy(bytes, (cast([^]u8)&value)[:size_of(T)])
	return bytes
}

@(private = "file")
viewer_check :: proc(kind: Record_Kind, body: $T) -> (Viewer_Record, Record_Problem) {
	bytes := body_bytes(body)
	return viewer_record_check({kind = kind, length = u32(len(bytes))}, bytes, SCREEN)
}

@(private = "file")
service_check :: proc(kind: Record_Kind, body: $T) -> (Service_Record, Record_Problem) {
	bytes := body_bytes(body)
	return service_record_check({kind = kind, length = u32(len(bytes))}, bytes, SCREEN)
}

// A header is refused on its kind and its length alone, before any byte of
// a body: a word that names no kind, a kind of the other direction, a
// length past the bound of the direction, a length that is not the length
// of the kind.
@(test)
record_length_problem_refuses_each_header_that_breaks_a_rule :: proc(t: ^testing.T) {
	unknown := [?]u32{u32(Record_Kind.None), u32(Record_Kind.Pointer_Place) + 1, u32(Record_Kind.Viewer_Frame_Taken) - 1, u32(max(Record_Kind)) + 1, 1 << 31, max(u32)}
	for word in unknown {
		for direction in Direction {
			problem := record_length_problem({kind = Record_Kind(word), length = 8}, direction)
			testing.expectf(t, problem == .Unknown_Kind, "the kind word %d gave %v", word, problem)
		}
	}
	for kind in Record_Kind {
		if kind == .None {
			continue
		}
		other := kind_direction(kind) == .To_Viewer ? Direction.To_Service : Direction.To_Viewer
		testing.expectf(t, record_length_problem({kind = kind, length = BODY_SIZES[kind]}, other) == .Wrong_Direction, "the kind %v went the other way", kind)
		own := kind_direction(kind)
		testing.expectf(t, record_length_problem({kind = kind, length = BODY_SIZES[kind]}, own) == .None, "the kind %v with its length was refused", kind)
		if kind != .Screen_Piece {
			testing.expectf(t, record_length_problem({kind = kind, length = BODY_SIZES[kind] - 1}, own) == .Wrong_Length, "the kind %v one byte short was taken", kind)
		}
	}
	past := [?]u32{VIEWER_BODY_LIMIT + 1, 1 << 20, max(u32)}
	for length in past {
		testing.expectf(t, record_length_problem({kind = .Key, length = length}, .To_Service) == .Past_Bound, "a key of %d bytes was not past its bound", length)
	}
	// The body of Key is the largest of the viewer, at the bound: one byte
	// more is past the bound. A body under the bound with one byte more has a
	// wrong length.
	#assert(size_of(Key_Body) == VIEWER_BODY_LIMIT && size_of(Viewer_Frame_Taken_Body) < VIEWER_BODY_LIMIT)
	testing.expect_value(t, record_length_problem({kind = .Key, length = BODY_SIZES[.Key] + 1}, .To_Service), Record_Problem.Past_Bound)
	testing.expect_value(t, record_length_problem({kind = .Viewer_Frame_Taken, length = BODY_SIZES[.Viewer_Frame_Taken] + 1}, .To_Service), Record_Problem.Wrong_Length)
	testing.expect_value(t, record_length_problem({kind = .Screen_Piece, length = SERVICE_BODY_LIMIT + 1}, .To_Viewer), Record_Problem.Past_Bound)
	testing.expect_value(t, record_length_problem({kind = .Screen_Piece, length = max(u32)}, .To_Viewer), Record_Problem.Past_Bound)
	testing.expect_value(t, record_length_problem({kind = .Screen_Piece, length = size_of(Screen_Piece_Header) - 1}, .To_Viewer), Record_Problem.Wrong_Length)
	testing.expect_value(t, record_length_problem({kind = .Screen_Piece, length = 0}, .To_Viewer), Record_Problem.Wrong_Length)
	testing.expect_value(t, record_length_problem({kind = .Screen_Piece, length = SERVICE_BODY_LIMIT}, .To_Viewer), Record_Problem.None)
}

// Each record of the viewer whose field breaks its range is refused, at its
// edges first; the body must be the length that the header names.
@(test)
viewer_record_check_refuses_each_field_out_of_its_range :: proc(t: ^testing.T) {
	_, problem := viewer_check(.Viewer_Frame_Taken, Viewer_Frame_Taken_Body{serial = 0})
	testing.expect_value(t, problem, Record_Problem.Bad_Field)
	starts := [?]Session_Start_Body{{version = 0}, {version = PROTOCOL_VERSION + 1}, {version = max(u32)}, {version = PROTOCOL_VERSION, reserved = 1}}
	for start in starts {
		_, refused := viewer_check(.Session_Start, start)
		testing.expectf(t, refused == .Bad_Field, "the start %v gave %v", start, refused)
	}
	_, start_held := viewer_check(.Session_Start, Session_Start_Body{version = PROTOCOL_VERSION})
	testing.expect_value(t, start_held, Record_Problem.None)
	requests := [?]struct {
		body:    Screen_Piece_Request_Body,
		problem: Record_Problem,
	} {
		{{0, 0, 0, 1}, .Empty_Rectangle},
		{{0, 0, 1, 0}, .Empty_Rectangle},
		{{SCREEN.width, 0, 1, 1}, .Outside_Screen},
		{{0, SCREEN.height, 1, 1}, .Outside_Screen},
		{{0, 0, SCREEN.width + 1, 1}, .Outside_Screen},
		{{1, 0, SCREEN.width, 1}, .Outside_Screen},
		{{max(u32), 0, 2, 1}, .Outside_Screen},
		{{0, max(u32), 1, max(u32)}, .Outside_Screen},
	}
	for item in requests {
		_, refused := viewer_check(.Screen_Piece_Request, item.body)
		testing.expectf(t, refused == item.problem, "the request %v gave %v, not %v", item.body, refused, item.problem)
	}
	keys := [?]Key_Body {
		{code = 0, pressed = 1},
		{code = KEY_CODE_LIMIT + 1, pressed = 1},
		{code = KEY_RELEASE_BIT, pressed = 1},
		{code = KEY_RELEASE_BIT | 0x1E, pressed = 0},
		{code = 0x100 | KEY_RELEASE_BIT, pressed = 1},
		{code = 0x1FF, pressed = 1},
		{code = max(u32), pressed = 1},
		{code = 0x1E, character = CHARACTER_LIMIT + 1, pressed = 1},
		{code = 0x1E, character = 0xD800, pressed = 1},
		{code = 0x1E, character = 0xDFFF, pressed = 1},
		{code = 0x1E, pressed = 2},
		{code = 0x1E, pressed = max(u32)},
		{code = 0x1E, pressed = 1, modifiers = KEY_MODIFIERS + 1},
	}
	for key in keys {
		_, refused := viewer_check(.Key, key)
		testing.expectf(t, refused == .Bad_Field, "the key %v gave %v", key, refused)
	}
	pointers := [?]struct {
		body:    Pointer_Body,
		problem: Record_Problem,
	} {
		{{x = SCREEN.width, y = 0}, .Outside_Screen},
		{{x = 0, y = SCREEN.height}, .Outside_Screen},
		{{x = max(u32), y = 0}, .Outside_Screen},
		{{buttons = POINTER_BUTTONS + 1}, .Bad_Field},
		{{wheel = WHEEL_NOTCHES_LIMIT + 1}, .Bad_Field},
		{{wheel = -WHEEL_NOTCHES_LIMIT - 1}, .Bad_Field},
		{{wheel = min(i32)}, .Bad_Field},
	}
	for item in pointers {
		_, refused := viewer_check(.Pointer, item.body)
		testing.expectf(t, refused == item.problem, "the pointer %v gave %v, not %v", item.body, refused, item.problem)
	}
	// A body that is not the length of the header.
	bytes := body_bytes(Key_Body{code = 0x1E, pressed = 1})
	_, short := viewer_record_check({kind = .Key, length = BODY_SIZES[.Key]}, bytes[:len(bytes) - 1], SCREEN)
	testing.expect_value(t, short, Record_Problem.Wrong_Length)
	// The cases that hold come last: each edge inside its range.
	record, held := viewer_check(.Key, Key_Body{code = KEY_CODE_LIMIT, character = CHARACTER_LIMIT, pressed = 1, modifiers = KEY_MODIFIERS})
	testing.expect_value(t, held, Record_Problem.None)
	testing.expect_value(t, record.key.code, KEY_CODE_LIMIT)
	_, pointer_held := viewer_check(.Pointer, Pointer_Body{x = SCREEN.width - 1, y = SCREEN.height - 1, buttons = POINTER_BUTTONS, wheel = -WHEEL_NOTCHES_LIMIT})
	testing.expect_value(t, pointer_held, Record_Problem.None)
	request, request_held := viewer_check(.Screen_Piece_Request, Screen_Piece_Request_Body{0, 0, SCREEN.width, SCREEN.height})
	testing.expect_value(t, request_held, Record_Problem.None)
	testing.expect_value(t, request.screen_piece_request.height, SCREEN.height)
}

// Each record of the service that breaks a rule is refused: a screen past
// its limit, a viewer frame past its bound, a screen piece larger than a screen piece or outside
// the screen, a coded length that the header does not count.
@(test)
service_record_check_refuses_each_viewer_frame_and_screen_piece_past_its_bound :: proc(t: ^testing.T) {
	screens := [?]Screen_Size_Body{{0, 1}, {1, 0}, {SCREEN_WIDTH_LIMIT + 1, 1}, {1, SCREEN_HEIGHT_LIMIT + 1}, {max(u32), max(u32)}}
	for size in screens {
		_, problem := service_check(.Screen_Size, size)
		testing.expectf(t, problem == .Outside_Screen, "the screen %v gave %v", size, problem)
	}
	starts := [?]struct {
		body:    Viewer_Frame_Start_Body,
		problem: Record_Problem,
	} {
		{{serial = 0, screen_piece_count = 1, bytes = 64}, .Bad_Field},
		{{serial = 1, screen_piece_count = VIEWER_FRAME_PIECE_LIMIT + 1, bytes = VIEWER_FRAME_BYTES_LIMIT}, .Past_Bound},
		{{serial = 1, screen_piece_count = 1, bytes = VIEWER_FRAME_BYTES_LIMIT + 1}, .Past_Bound},
		{{serial = 1, screen_piece_count = max(u32), bytes = max(u64)}, .Past_Bound},
		{{serial = 1, screen_piece_count = 2, bytes = 2 * (RECORD_HEADER_SIZE + size_of(Screen_Piece_Header)) - 1}, .Wrong_Length},
	}
	for item in starts {
		_, problem := service_check(.Viewer_Frame_Start, item.body)
		testing.expectf(t, problem == item.problem, "the start %v gave %v, not %v", item.body, problem, item.problem)
	}
	pieces := [?]struct {
		screen_piece:    Screen_Piece_Header,
		problem: Record_Problem,
	} {
		{{x = 0, y = 0, width = SCREEN_PIECE_WIDTH + 1, height = 1, coded_length = 1}, .Empty_Rectangle},
		{{x = 0, y = 0, width = 1, height = SCREEN_PIECE_HEIGHT + 1, coded_length = 1}, .Empty_Rectangle},
		{{x = 0, y = 0, width = 0, height = 1, coded_length = 1}, .Empty_Rectangle},
		{{x = SCREEN.width - 1, y = 0, width = 2, height = 1, coded_length = 1}, .Outside_Screen},
		{{x = 0, y = 0, width = 1, height = 1, coded_length = 2}, .Wrong_Length},
		{{x = 0, y = 0, width = 1, height = 1, coded_length = coded_limit(1) + 1}, .Wrong_Length},
	}
	for item in pieces {
		bytes := make([]u8, size_of(Screen_Piece_Header) + 1, context.temp_allocator)
		screen_piece := item.screen_piece
		copy(bytes, (cast([^]u8)&screen_piece)[:size_of(Screen_Piece_Header)])
		_, problem := service_record_check({kind = .Screen_Piece, length = u32(len(bytes))}, bytes, SCREEN)
		testing.expectf(t, problem == item.problem, "the screen piece %v gave %v, not %v", item.screen_piece, problem, item.problem)
	}
	places := [?]struct {
		body:    Pointer_Place_Body,
		problem: Record_Problem,
	} {
		{{x = SCREEN.width, y = 0}, .Outside_Screen},
		{{x = 1, y = 1, left = 4, top = 0, right = 4, bottom = 2}, .Outside_Screen},
		{{x = 1, y = 1, left = 0, top = 0, right = SCREEN.width + 1, bottom = 2}, .Outside_Screen},
		{{x = 1, y = 1, left = 3, top = 0, right = 0, bottom = 0}, .Bad_Field},
	}
	for item in places {
		_, problem := service_check(.Pointer_Place, item.body)
		testing.expectf(t, problem == item.problem, "the place %v gave %v, not %v", item.body, problem, item.problem)
	}
	_, end_problem := service_check(.Viewer_Frame_End, Viewer_Frame_End_Body{serial = 0})
	testing.expect_value(t, end_problem, Record_Problem.Bad_Field)
	// The cases that hold: the largest screen, a viewer frame at its bounds.
	_, size_held := service_check(.Screen_Size, Screen_Size_Body{SCREEN_WIDTH_LIMIT, SCREEN_HEIGHT_LIMIT})
	testing.expect_value(t, size_held, Record_Problem.None)
	_, start_held := service_check(.Viewer_Frame_Start, Viewer_Frame_Start_Body{serial = 1, screen_piece_count = VIEWER_FRAME_PIECE_LIMIT, bytes = VIEWER_FRAME_BYTES_LIMIT})
	testing.expect_value(t, start_held, Record_Problem.None)
}

// What screen_piece_encode writes, screen_piece_decode reads to the same pixels, for each
// kind of picture at the edges of the size of a screen piece.
@(test)
screen_piece_coder_round_trip :: proc(t: ^testing.T) {
	sizes := [?][2]int{{1, 1}, {2, 1}, {1, 2}, {SCREEN_PIECE_WIDTH, SCREEN_PIECE_HEIGHT}, {SCREEN_PIECE_WIDTH - 1, 3}, {63, 63}}
	STRIDE :: SCREEN_PIECE_WIDTH + 7
	picture := make([]u32, STRIDE * (SCREEN_PIECE_HEIGHT + 3), context.temp_allocator)
	out := make([]u8, CODED_SCREEN_PIECE_LIMIT, context.temp_allocator)
	decoded := make([]u32, SCREEN_PIECE_PIXEL_LIMIT, context.temp_allocator)
	for pattern in 0 ..< 5 {
		for &pixel, index in picture {
			switch pattern {
			case 0:
				pixel = 0x00202830 // One color: runs.
			case 1:
				pixel = u32(index % 7) * 0x00010101 // Small changes.
			case 2:
				pixel = u32(index % 50) * 0x00030201 // Changes of the luma form.
			case 3:
				pixel = rand.uint32() // Any color; the high byte is not coded.
			case:
				pixel = index % 3 == 0 ? 0x00FFFFFF : 0 // Recent colors.
			}
		}
		for size in sizes {
			width, height := size[0], size[1]
			coded := screen_piece_encode(picture, STRIDE, 3, 2, width, height, out)
			testing.expectf(t, coded <= int(coded_limit(u32(width * height))), "the code of %dx%d is %d bytes, past its limit", width, height, coded)
			problem := screen_piece_decode(out[:coded], decoded[:width * height])
			testing.expectf(t, problem == .None, "the pattern %d, %dx%d: %v", pattern, width, height, problem)
			for row in 0 ..< height {
				for column in 0 ..< width {
					want := picture[(2 + row) * STRIDE + 3 + column] & COLOR_MASK
					if decoded[row * width + column] != want {
						testing.expectf(t, false, "the pattern %d, %dx%d: the pixel (%d, %d) is %x, not %x", pattern, width, height, column, row, decoded[row * width + column], want)
						return
					}
				}
			}
		}
	}
}

// Each damaged code is refused: too short, cut, past its pixels, bytes
// after the last one, the reserved tag, a recent color that no pixel gave.
@(test)
screen_piece_decode_refuses_each_damaged_code :: proc(t: ^testing.T) {
	out: [4]u32
	cases := [?]struct {
		code:    []u8,
		pixels:  int,
		problem: Screen_Piece_Problem,
	} {
		{{}, 1, .Short},
		{{TAG_RUN | 0}, 2, .Short},
		{{TAG_RUN | 1}, 1, .Past_Pixels},
		{{TAG_RUN | (RUN_LIMIT - 1)}, 4, .Past_Pixels},
		{{TAG_COLOR, 1, 2}, 1, .Cut_Code},
		{{TAG_COLOR}, 1, .Cut_Code},
		{{TAG_LUMA | 3}, 1, .Cut_Code},
		{{TAG_RESERVED, 1, 2, 3, 4}, 1, .Reserved_Tag},
		{{TAG_RUN | 0, 0}, 1, .Bytes_After},
		{{TAG_INDEX | 5}, 1, .Empty_Recent},
	}
	for item in cases {
		problem := screen_piece_decode(item.code, out[:item.pixels])
		testing.expectf(t, problem == item.problem, "the code %v for %d pixels gave %v, not %v", item.code, item.pixels, problem, item.problem)
	}
	// The case that holds: one whole color, then a run of it.
	code := [?]u8{TAG_COLOR, 0x12, 0x34, 0x56, TAG_RUN | 2}
	testing.expect_value(t, screen_piece_decode(code[:], out[:]), Screen_Piece_Problem.None)
	testing.expect_value(t, out[3], u32(0x00123456))
}

// The screen pieces of a rectangle cover it once, each at most a screen piece, at the edges
// of the size of a screen piece.
@(test)
screen_pieces_cover_a_rectangle_once :: proc(t: ^testing.T) {
	sizes := [?][2]u32{{1, 1}, {SCREEN_PIECE_WIDTH, SCREEN_PIECE_HEIGHT}, {SCREEN_PIECE_WIDTH + 1, SCREEN_PIECE_HEIGHT + 1}, {SCREEN_WIDTH_LIMIT, SCREEN_HEIGHT_LIMIT}}
	for size in sizes {
		covered: u64
		count := screen_piece_count(size[0], size[1])
		for index in 0 ..< count {
			x, y, width, height := screen_piece_at(5, 7, size[0], size[1], index)
			testing.expect(t, width >= 1 && width <= SCREEN_PIECE_WIDTH && height >= 1 && height <= SCREEN_PIECE_HEIGHT)
			testing.expect(t, x >= 5 && y >= 7 && x + width <= 5 + size[0] && y + height <= 7 + size[1])
			covered += u64(width) * u64(height)
		}
		testing.expectf(t, covered == u64(size[0]) * u64(size[1]), "the screen pieces of %v cover %d pixels", size, covered)
	}
	testing.expect_value(t, screen_piece_count(SCREEN_WIDTH_LIMIT, SCREEN_HEIGHT_LIMIT), 15 * 17)
	testing.expect(t, screen_piece_count(SCREEN_WIDTH_LIMIT, SCREEN_HEIGHT_LIMIT) <= VIEWER_FRAME_PIECE_LIMIT)
}
