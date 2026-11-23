// The remote display: what the service `remote_display` of the machine and
// a viewer on another machine agree on (src/md/features/remote_display.md;
// docs/QUIC.md, "8. The remote display").
//
// The viewer opens one QUIC connection to the service, with its own Ed25519
// key in mutual TLS 1.3 as a client of `remote` does, then one
// bidirectional stream, whose first record is its Session_Start. The
// service writes the screen in its direction of
// the stream; the viewer writes its input and the end of each viewer frame in the
// other. QUIC controls the flow of each direction alone, so a key never
// waits behind the pixels.
//
// Each record is a Record_Header and a body of the form of its kind. A
// reader trusts nothing: viewer_record_check and service_record_check are
// the borders of the two directions. A header whose length is past the
// bound of its direction is refused before any byte of its body is read
// (record_length_problem).
//
// The screen goes as viewer frames, one at a time: Viewer_Frame_Start, its screen pieces, then
// Viewer_Frame_End. The service sends the next viewer frame only after the Viewer_Frame_Taken
// of the viewer for the last one. A screen piece is a rectangle of at most
// SCREEN_PIECE_WIDTH x SCREEN_PIECE_HEIGHT pixels in the screen piece coder (screen_piece_coder.odin).
//
// All numbers are little-endian. This package allocates no memory and calls
// no kernel operation.
package remote_display

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/pointer_pictures"

// The UDP port of the listen grant of the service, on the address of the
// machine. The listen grant admits the address of the host only, as the one
// of `remote` does (remote.HOST_ADDRESS).
LISTEN_PORT :: 7101

// The application protocol (ALPN) of a connection to the service: a client
// that offers another one fails the handshake.
APPLICATION_PROTOCOL :: "modus-remote-display"

// The viewers that the service holds at one time: a person on two
// machines, agents and a colleague see the screen together. The viewer
// past this count gets no record until one ends.
CONNECTION_CAPACITY :: 8

// The largest screen that the protocol carries: 8K UHD, so 1440p, 4K and
// 5K screens pass. A record that names a larger one is refused. This bounds
// the words of the protocol only: the memory of the service follows the
// screen in force, and the bounds of a viewer frame follow the screen of
// its session (viewer_frame_piece_limit, viewer_frame_bytes_limit).
SCREEN_WIDTH_LIMIT :: 7680
SCREEN_HEIGHT_LIMIT :: 4320

// The largest screen piece. A rectangle of the damage goes as screen pieces of this size at
// most, from its top left corner, row after row.
SCREEN_PIECE_WIDTH :: 128
SCREEN_PIECE_HEIGHT :: 64
SCREEN_PIECE_PIXEL_LIMIT :: SCREEN_PIECE_WIDTH * SCREEN_PIECE_HEIGHT

// The rectangles of one viewer frame at most: the damage set of the service
// (interface.DAMAGE_CAPACITY), whose rectangles do not meet.
VIEWER_FRAME_RECTANGLE_LIMIT :: 8

// The application error code of a CONNECTION_CLOSE or a RESET_STREAM of a
// connection to the service.
Display_Error :: enum u64 {
	None              = 0, // No error: the end of a session that the viewer asked.
	Too_Large         = 1, // A record whose length is past the bound of its direction.
	Bad_Record        = 2, // A record that its border refused: an unknown kind, a wrong length, a field out of its range.
	Input_Not_Allowed = 3, // A key or a pointer from a client key whose row holds View and not Input.
	Revoked           = 4, // The grant of the key ended: a revocation, or a lock of the session of its principal.
	Out_Of_Order      = 5, // A Viewer_Frame_Taken that names no viewer frame in flight.
	Timeout           = 6, // The viewer did not take a viewer frame in its bound.
	Screen_Not_Held   = 7, // The service cannot hold the screen in force: its budget does not pay the screen, or the screen is past the largest screen of the protocol.
}

// The name of each code, for the log of the two sides.
@(rodata)
DISPLAY_ERROR_NAMES := [Display_Error]string {
	.None              = "None",
	.Too_Large         = "Too_Large",
	.Bad_Record        = "Bad_Record",
	.Input_Not_Allowed = "Input_Not_Allowed",
	.Revoked           = "Revoked",
	.Out_Of_Order      = "Out_Of_Order",
	.Timeout           = "Timeout",
	.Screen_Not_Held   = "Screen_Not_Held",
}

// display_error_name gives the name of an application error code, or "" for
// a code that this contract does not name.
display_error_name :: proc "contextless" (code: u64) -> string {
	member, known := enum_word.member_of_word(Display_Error, code)
	return known ? DISPLAY_ERROR_NAMES[member] : ""
}

// The kind of a record. The values from 1 go from the service to the
// viewer; the values from 16 go from the viewer to the service.
Record_Kind :: enum u32 {
	None                 = 0, // Not a record: refused.
	Screen_Size          = 1, // The first record of the service: Screen_Size_Body.
	Viewer_Frame_Start   = 2, // Viewer_Frame_Start_Body, then its screen pieces.
	Screen_Piece         = 3, // A Screen_Piece_Header, then its coded pixels.
	Viewer_Frame_End     = 4, // Viewer_Frame_End_Body.
	Pointer_Place        = 5, // Pointer_Place_Body.
	Pointer_Shape        = 6, // Pointer_Shape_Body: pointer shape, form, size, and hot spot.
	Pointer_Picture      = 7, // Pointer_Picture_Header, then size * size * 4 RGBA pixels.
	Pointer_Warp         = 8, // Pointer_Warp_Body: machine-initiated pointer move and input echo count.
	Viewer_Frame_Taken   = 16, // Viewer_Frame_Taken_Body.
	Screen_Piece_Request = 17, // Screen_Piece_Request_Body.
	Key                  = 18, // Key_Body.
	Pointer              = 19, // Pointer_Body.
	// Session_Start_Body: the first record of the viewer, which opens the
	// stream. The service writes nothing before it, and refuses it a
	// second time.
	Session_Start        = 20,
}

// The version of the protocol that Session_Start names. A viewer of
// another version is refused.
PROTOCOL_VERSION :: 2

// The allowed pixel side of a pointer picture in protocol version 2.
POINTER_SIZE_MINIMUM :: 24
POINTER_SIZE_MAXIMUM :: 48

Session_Start_Body :: struct {
	version:  u32, // PROTOCOL_VERSION.
	reserved: u32, // 0.
}

// The direction of a record on the stream.
Direction :: enum u8 {
	To_Viewer  = 0,
	To_Service = 1,
}

// The header of each record: its kind, and the bytes of its body after it.
Record_Header :: struct {
	kind:   Record_Kind,
	length: u32,
}
#assert(size_of(Record_Header) == 8)
RECORD_HEADER_SIZE :: size_of(Record_Header)

Screen_Size_Body :: struct {
	width:  u32,
	height: u32,
}

Viewer_Frame_Start_Body :: struct {
	serial:             u64, // One more for each viewer frame of the session, from 1.
	screen_piece_count: u32, // The Screen_Piece records before Viewer_Frame_End.
	reserved:           u32, // 0.
	// The most bytes of those Screen_Piece records, their headers included: each
	// pixel at its worst code. The service codes each screen piece as it goes, so
	// it knows the bound before the bytes; a viewer can hold the viewer frame.
	bytes:              u64,
	// Monotonic count of input records of this viewer already applied by the
	// compositor before copying the pixels of this viewer frame.
	input_echo_count:   u64,
}
#assert(size_of(Viewer_Frame_Start_Body) == 32)

// The head of the body of a Screen_Piece: the coded pixels follow it.
Screen_Piece_Header :: struct {
	x, y:          u32, // The top left corner, in pixels of the screen.
	width, height: u32,
	coded_length:  u32, // The bytes of the coded pixels after this header.
	_:             u32,
}
#assert(size_of(Screen_Piece_Header) == 24)

Viewer_Frame_End_Body :: struct {
	serial: u64,
}

// The place of the pointer, and the rectangle of the screen that its
// picture covers: the viewer draws the pointer there. A rectangle of four
// zeros covers nothing: the pointer is not drawn.
Pointer_Place_Body :: struct {
	x, y:                     u32,
	left, top, right, bottom: u32,
}

// The shape, theme form, pixel side, and hot spot of the pointer so a
// viewer draws its own host cursor with zero wait.
Pointer_Shape_Body :: struct {
	shape:      u32, // pointer_pictures.Pointer_Shape.
	form:       u32, // pointer_pictures.Pointer_Form.
	size:       u32, // Side in pixels, in [POINTER_SIZE_MINIMUM..POINTER_SIZE_MAXIMUM].
	hot_spot_x: u32, // < size.
	hot_spot_y: u32, // < size.
	reserved:   u32, // 0.
}
#assert(size_of(Pointer_Shape_Body) == 24)

// The head of the body of a Pointer_Picture: size * size * 4 bytes of
// premultiplied pixels follow this header.
Pointer_Picture_Header :: struct {
	shape:      u32, // pointer_pictures.Pointer_Shape.
	form:       u32, // pointer_pictures.Pointer_Form.
	size:       u32, // Side in pixels, in [POINTER_SIZE_MINIMUM..POINTER_SIZE_MAXIMUM].
	hot_spot_x: u32, // < size.
	hot_spot_y: u32, // < size.
	reserved:   u32, // 0.
}
#assert(size_of(Pointer_Picture_Header) == 24)

// A machine-initiated cursor move (not caused by this viewer's own
// Pointer records), with the exact screen coordinates and the count of
// viewer input records applied before this warp.
Pointer_Warp_Body :: struct {
	x:                u32,
	y:                u32,
	input_echo_count: u64,
}
#assert(size_of(Pointer_Warp_Body) == 16)

Viewer_Frame_Taken_Body :: struct {
	serial: u64,
}

// A rectangle of the screen that the viewer asks again: the service adds
// it to the damage of the viewer.
Screen_Piece_Request_Body :: struct {
	x, y:          u32,
	width, height: u32,
}

// A key, in the form of the record of the input service: the scan code of
// set 1 (modus:display, KEY_*), the code point or 0, 1 when pressed
// and 0 when released, the modifier bits.
Key_Body :: struct {
	code:      u32,
	character: u32,
	pressed:   u32,
	modifiers: u32,
}

// The pointer at a place of the screen, with its buttons and the notches of
// its wheel.
Pointer_Body :: struct {
	x, y:    u32,
	buttons: u32,
	wheel:   i32,
}

// The largest code of a key: a scan code of set 1, with KEY_EXTENDED.
KEY_CODE_LIMIT :: 0x17F
// The bit of a released key in a scan code of set 1. The record carries
// pressed apart, so a code with this bit names no key.
KEY_RELEASE_BIT :: 0x80
// The largest code point.
CHARACTER_LIMIT :: 0x10FFFF
// The modifier bits that a key carries: shift and control.
KEY_MODIFIERS :: 0b11
// The buttons that a pointer carries: left and right.
POINTER_BUTTONS :: 0b11
// The most notches of the wheel in one record.
WHEEL_NOTCHES_LIMIT :: 64

// The bytes of the body of each kind; Screen_Piece has its header and at most the
// coded pixels of a whole screen piece.
// The values of Record_Kind have a gap between the two directions, so the
// table is sparse.
@(rodata)
BODY_SIZES := #sparse[Record_Kind]u32 {
	.None                 = 0,
	.Screen_Size          = size_of(Screen_Size_Body),
	.Viewer_Frame_Start   = size_of(Viewer_Frame_Start_Body),
	.Screen_Piece         = size_of(Screen_Piece_Header),
	.Viewer_Frame_End     = size_of(Viewer_Frame_End_Body),
	.Pointer_Place        = size_of(Pointer_Place_Body),
	.Pointer_Shape        = size_of(Pointer_Shape_Body),
	.Pointer_Picture      = size_of(Pointer_Picture_Header),
	.Pointer_Warp         = size_of(Pointer_Warp_Body),
	.Viewer_Frame_Taken   = size_of(Viewer_Frame_Taken_Body),
	.Screen_Piece_Request = size_of(Screen_Piece_Request_Body),
	.Key                  = size_of(Key_Body),
	.Pointer              = size_of(Pointer_Body),
	.Session_Start        = size_of(Session_Start_Body),
}

// The bound of the length of a record of each direction. A record of the
// viewer is small: one past this is a viewer that sends what no viewer
// sends.
VIEWER_BODY_LIMIT :: 16
SCREEN_PIECE_BODY_LIMIT :: size_of(Screen_Piece_Header) + CODED_SCREEN_PIECE_LIMIT
POINTER_PICTURE_MIN_BODY :: size_of(Pointer_Picture_Header) + POINTER_SIZE_MINIMUM * POINTER_SIZE_MINIMUM * 4
POINTER_PICTURE_BODY_LIMIT :: size_of(Pointer_Picture_Header) + POINTER_SIZE_MAXIMUM * POINTER_SIZE_MAXIMUM * 4
SERVICE_BODY_LIMIT :: SCREEN_PIECE_BODY_LIMIT
#assert(POINTER_PICTURE_BODY_LIMIT <= SERVICE_BODY_LIMIT)
// viewer_frame_piece_limit gives the most screen pieces of one viewer frame
// of a screen: the pieces of the whole screen, and the partial pieces of
// VIEWER_FRAME_RECTANGLE_LIMIT rectangles that do not meet. A rectangle of
// w x h has at most (w / 128 + 1) * (h / 64 + 1) pieces: its area, then a
// row and a column of partial pieces and a corner, each of which the area
// of the screen does not count. The sum of the areas is at most the screen.
viewer_frame_piece_limit :: proc "contextless" (screen: Screen) -> u64 {
	across := u64((screen.width + SCREEN_PIECE_WIDTH - 1) / SCREEN_PIECE_WIDTH)
	down := u64((screen.height + SCREEN_PIECE_HEIGHT - 1) / SCREEN_PIECE_HEIGHT)
	return across * down + VIEWER_FRAME_RECTANGLE_LIMIT * (across + down + 1)
}

// viewer_frame_bytes_limit gives the bytes of the screen pieces of one
// viewer frame of a screen at most: each pixel of the screen in its worst
// code, and the headers of the most screen pieces.
viewer_frame_bytes_limit :: proc "contextless" (screen: Screen) -> u64 {
	return u64(screen.width) * u64(screen.height) * CODED_PIXEL_LIMIT + viewer_frame_piece_limit(screen) * (RECORD_HEADER_SIZE + size_of(Screen_Piece_Header))
}

// The largest screen, as a Screen.
SCREEN_LARGEST :: Screen{SCREEN_WIDTH_LIMIT, SCREEN_HEIGHT_LIMIT}
// The pieces of a viewer frame of the largest screen fit the count of a
// Viewer_Frame_Start.
#assert((SCREEN_WIDTH_LIMIT / SCREEN_PIECE_WIDTH + 1) * (SCREEN_HEIGHT_LIMIT / SCREEN_PIECE_HEIGHT + 1) * (VIEWER_FRAME_RECTANGLE_LIMIT + 1) < 1 << 32)

// Why a border refused a record.
Record_Problem :: enum u8 {
	None,
	Unknown_Kind, // The kind names no member, or None.
	Wrong_Direction, // A kind of the other direction.
	Past_Bound, // A length past the bound of the direction, a viewer frame past viewer_frame_bytes_limit or viewer_frame_piece_limit of its screen.
	Wrong_Length, // A length that is not the length of the kind, or a body that is not that length.
	Outside_Screen, // A rectangle or a place outside the screen, or a screen past its limit.
	Empty_Rectangle, // A rectangle of width or height 0, or a screen piece larger than SCREEN_PIECE_WIDTH x SCREEN_PIECE_HEIGHT.
	Bad_Field, // A field out of its range: a key code, a character, pressed, a modifier, a button, the wheel, a serial of 0, a reserved field that is not 0.
}

// The sentence of each problem, for a line of the log.
@(rodata)
RECORD_PROBLEM_SENTENCES := [Record_Problem]string {
	.None            = "the record holds",
	.Unknown_Kind    = "its kind names no record",
	.Wrong_Direction = "its kind goes the other way",
	.Past_Bound      = "it is past its bound",
	.Wrong_Length    = "its length is not the length of its kind",
	.Outside_Screen  = "it names a place outside the screen",
	.Empty_Rectangle = "it names an empty rectangle, or a screen piece larger than 128 x 64",
	.Bad_Field       = "a field is out of its range",
}

// The screen that the two sides agree on, from Screen_Size.
Screen :: struct {
	width, height: u32,
}

// screen_problem checks a size of a screen: not 0, and at most the limit.
screen_problem :: proc "contextless" (screen: Screen) -> Record_Problem {
	if screen.width == 0 || screen.height == 0 || screen.width > SCREEN_WIDTH_LIMIT || screen.height > SCREEN_HEIGHT_LIMIT {
		return .Outside_Screen
	}
	return .None
}

// rectangle_problem checks a rectangle against a screen, as words: a sum
// that passes the width is never cut back into it.
rectangle_problem :: proc "contextless" (x, y, width, height: u32, screen: Screen) -> Record_Problem {
	if width == 0 || height == 0 {
		return .Empty_Rectangle
	}
	if u64(x) + u64(width) > u64(screen.width) || u64(y) + u64(height) > u64(screen.height) {
		return .Outside_Screen
	}
	return .None
}

// header_read copies a header out of the first RECORD_HEADER_SIZE bytes. ok
// is false with fewer bytes.
header_read :: proc "contextless" (bytes: []u8) -> (header: Record_Header, ok: bool) {
	if len(bytes) < RECORD_HEADER_SIZE {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&header, raw_data(bytes), RECORD_HEADER_SIZE)
	return header, true
}

// record_length_problem is the first border of a record of a direction: it
// reads the header only, so a reader refuses a record past its bound before
// it reads or keeps any byte of the body. It refuses a kind that names no
// member, a kind of the other direction, and a length that is not the
// length of the kind (a Screen_Piece: its header, and at most the coded pixels of a
// whole screen piece).
record_length_problem :: proc "contextless" (header: Record_Header, direction: Direction) -> Record_Problem {
	kind, known := enum_word.member_of_word(Record_Kind, u64(header.kind))
	if !known || kind == .None {
		return .Unknown_Kind
	}
	if kind_direction(kind) != direction {
		return .Wrong_Direction
	}
	limit: u32 = direction == .To_Service ? VIEWER_BODY_LIMIT : SERVICE_BODY_LIMIT
	if header.length > limit {
		return .Past_Bound
	}
	if kind == .Screen_Piece {
		if header.length < size_of(Screen_Piece_Header) {
			return .Wrong_Length
		}
		return .None
	}
	if kind == .Pointer_Picture {
		if header.length > POINTER_PICTURE_BODY_LIMIT {
			return .Past_Bound
		}
		if header.length < POINTER_PICTURE_MIN_BODY {
			return .Wrong_Length
		}
		return .None
	}
	if header.length != BODY_SIZES[kind] {
		return .Wrong_Length
	}
	return .None
}

// kind_direction gives the direction of a kind.
kind_direction :: proc "contextless" (kind: Record_Kind) -> Direction {
	switch kind {
	case .None, .Screen_Size, .Viewer_Frame_Start, .Screen_Piece, .Viewer_Frame_End, .Pointer_Place, .Pointer_Shape, .Pointer_Picture, .Pointer_Warp:
		return .To_Viewer
	case .Viewer_Frame_Taken, .Screen_Piece_Request, .Key, .Pointer, .Session_Start:
		return .To_Service
	}
	return .To_Viewer
}

// A record of the viewer that its border took: the kind, and the body of
// that kind.
Viewer_Record :: struct {
	kind:          Record_Kind,
	session_start: Session_Start_Body,
	viewer_frame_taken:   Viewer_Frame_Taken_Body,
	screen_piece_request: Screen_Piece_Request_Body,
	key:          Key_Body,
	pointer:      Pointer_Body,
}

// viewer_record_check is the border of a whole record from the viewer: the
// header and the bytes of its body. It copies the body, then checks the
// copy against the screen of the session.
viewer_record_check :: proc "contextless" (header: Record_Header, body: []u8, screen: Screen) -> (record: Viewer_Record, problem: Record_Problem) {
	if problem = record_length_problem(header, .To_Service); problem != .None {
		return {}, problem
	}
	if u64(len(body)) != u64(header.length) {
		return {}, .Wrong_Length
	}
	record.kind = header.kind
	switch header.kind {
	case .None, .Screen_Size, .Viewer_Frame_Start, .Screen_Piece, .Viewer_Frame_End, .Pointer_Place, .Pointer_Shape, .Pointer_Picture, .Pointer_Warp:
		// record_length_problem took only a kind of this direction.
		return {}, .Wrong_Direction
	case .Session_Start:
		start := body_read(body, Session_Start_Body)
		if start.version != PROTOCOL_VERSION || start.reserved != 0 {
			return {}, .Bad_Field
		}
		record.session_start = start
	case .Viewer_Frame_Taken:
		record.viewer_frame_taken = body_read(body, Viewer_Frame_Taken_Body)
		if record.viewer_frame_taken.serial == 0 {
			return {}, .Bad_Field
		}
	case .Screen_Piece_Request:
		request := body_read(body, Screen_Piece_Request_Body)
		if problem = rectangle_problem(request.x, request.y, request.width, request.height, screen); problem != .None {
			return {}, problem
		}
		record.screen_piece_request = request
	case .Key:
		key := body_read(body, Key_Body)
		if key.code == 0 || key.code > KEY_CODE_LIMIT || key.code & KEY_RELEASE_BIT != 0 || key.character > CHARACTER_LIMIT || (key.character >= 0xD800 && key.character <= 0xDFFF) || key.pressed > 1 || key.modifiers & ~u32(KEY_MODIFIERS) != 0 {
			return {}, .Bad_Field
		}
		record.key = key
	case .Pointer:
		pointer := body_read(body, Pointer_Body)
		if pointer.x >= screen.width || pointer.y >= screen.height {
			return {}, .Outside_Screen
		}
		if pointer.buttons & ~u32(POINTER_BUTTONS) != 0 || pointer.wheel > WHEEL_NOTCHES_LIMIT || pointer.wheel < -WHEEL_NOTCHES_LIMIT {
			return {}, .Bad_Field
		}
		record.pointer = pointer
	}
	return record, .None
}

// A record of the service that its border took.
Service_Record :: struct {
	kind:                 Record_Kind,
	screen_size:          Screen_Size_Body,
	viewer_frame_start:   Viewer_Frame_Start_Body,
	screen_piece:         Screen_Piece_Header,
	coded:                []u8, // A Screen_Piece: its coded pixels, in the body that the caller gave.
	viewer_frame_end:     Viewer_Frame_End_Body,
	pointer_place:        Pointer_Place_Body,
	pointer_shape:        Pointer_Shape_Body,
	pointer_picture:      Pointer_Picture_Header,
	pointer_shape_member: pointer_pictures.Pointer_Shape,
	pointer_form_member:  pointer_pictures.Pointer_Form,
	pointer_pixels:       []u8, // A Pointer_Picture: its size * size * 4 pixel bytes, in the body that the caller gave.
	pointer_warp:         Pointer_Warp_Body,
}

// pointer_shape_fields_check validates the closed shape and form members,
// the theme size range, the hot spot bounds, and the reserved word.
@(private)
pointer_shape_fields_check :: proc "contextless" (shape_word, form_word, size, hot_spot_x, hot_spot_y, reserved: u32) -> (shape: pointer_pictures.Pointer_Shape, form: pointer_pictures.Pointer_Form, ok: bool) {
	shape_member, shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, u64(shape_word))
	form_member, form_ok := enum_word.member_of_word(pointer_pictures.Pointer_Form, u64(form_word))
	if !shape_ok || !form_ok || reserved != 0 {
		return {}, {}, false
	}
	if size < POINTER_SIZE_MINIMUM || size > POINTER_SIZE_MAXIMUM {
		return {}, {}, false
	}
	if hot_spot_x >= size || hot_spot_y >= size {
		return {}, {}, false
	}
	return shape_member, form_member, true
}

// service_record_check is the border of a whole record from the service.
// The screen of a Screen_Size is checked against the limits; each other
// record is checked against screen, the size that the first record gave.
service_record_check :: proc "contextless" (header: Record_Header, body: []u8, screen: Screen) -> (record: Service_Record, problem: Record_Problem) {
	if problem = record_length_problem(header, .To_Viewer); problem != .None {
		return {}, problem
	}
	if u64(len(body)) != u64(header.length) {
		return {}, .Wrong_Length
	}
	record.kind = header.kind
	switch header.kind {
	case .None, .Viewer_Frame_Taken, .Screen_Piece_Request, .Key, .Pointer, .Session_Start:
		// record_length_problem took only a kind of this direction.
		return {}, .Wrong_Direction
	case .Screen_Size:
		size := body_read(body, Screen_Size_Body)
		if problem = screen_problem({size.width, size.height}); problem != .None {
			return {}, problem
		}
		record.screen_size = size
	case .Viewer_Frame_Start:
		start := body_read(body, Viewer_Frame_Start_Body)
		switch {
		case start.serial == 0 || start.reserved != 0:
			return {}, .Bad_Field
		case u64(start.screen_piece_count) > viewer_frame_piece_limit(screen) || start.bytes > viewer_frame_bytes_limit(screen):
			return {}, .Past_Bound
		case u64(start.screen_piece_count) * (RECORD_HEADER_SIZE + size_of(Screen_Piece_Header)) > start.bytes:
			// Each screen piece has its two headers at least.
			return {}, .Wrong_Length
		}
		record.viewer_frame_start = start
	case .Screen_Piece:
		screen_piece := body_read(body, Screen_Piece_Header)
		if problem = rectangle_problem(screen_piece.x, screen_piece.y, screen_piece.width, screen_piece.height, screen); problem != .None {
			return {}, problem
		}
		if screen_piece.width > SCREEN_PIECE_WIDTH || screen_piece.height > SCREEN_PIECE_HEIGHT {
			return {}, .Empty_Rectangle
		}
		if u64(screen_piece.coded_length) != u64(header.length) - size_of(Screen_Piece_Header) || screen_piece.coded_length > coded_limit(screen_piece.width * screen_piece.height) {
			return {}, .Wrong_Length
		}
		record.screen_piece = screen_piece
		record.coded = body[size_of(Screen_Piece_Header):]
	case .Viewer_Frame_End:
		record.viewer_frame_end = body_read(body, Viewer_Frame_End_Body)
		if record.viewer_frame_end.serial == 0 {
			return {}, .Bad_Field
		}
	case .Pointer_Place:
		place := body_read(body, Pointer_Place_Body)
		if place.x >= screen.width || place.y >= screen.height {
			return {}, .Outside_Screen
		}
		if place.right != 0 || place.bottom != 0 {
			if place.left >= place.right || place.top >= place.bottom || place.right > screen.width || place.bottom > screen.height {
				return {}, .Outside_Screen
			}
		} else if place.left != 0 || place.top != 0 {
			return {}, .Bad_Field
		}
		record.pointer_place = place
	case .Pointer_Shape:
		shape_body := body_read(body, Pointer_Shape_Body)
		shape_member, form_member, fields_ok := pointer_shape_fields_check(shape_body.shape, shape_body.form, shape_body.size, shape_body.hot_spot_x, shape_body.hot_spot_y, shape_body.reserved)
		if !fields_ok {
			return {}, .Bad_Field
		}
		record.pointer_shape = shape_body
		record.pointer_shape_member = shape_member
		record.pointer_form_member = form_member
	case .Pointer_Picture:
		pic := body_read(body, Pointer_Picture_Header)
		shape_member, form_member, fields_ok := pointer_shape_fields_check(pic.shape, pic.form, pic.size, pic.hot_spot_x, pic.hot_spot_y, pic.reserved)
		if !fields_ok {
			return {}, .Bad_Field
		}
		expected_bytes := size_of(Pointer_Picture_Header) + u64(pic.size) * u64(pic.size) * 4
		if u64(len(body)) != expected_bytes {
			return {}, .Wrong_Length
		}
		record.pointer_picture = pic
		record.pointer_shape_member = shape_member
		record.pointer_form_member = form_member
		record.pointer_pixels = body[size_of(Pointer_Picture_Header):]
	case .Pointer_Warp:
		warp := body_read(body, Pointer_Warp_Body)
		if warp.x >= screen.width || warp.y >= screen.height {
			return {}, .Outside_Screen
		}
		record.pointer_warp = warp
	}
	return record, .None
}

// Input_Echo_Tracker enforces monotonic viewer input echo counts across
// frames and warps, and ensures the service never echoes more inputs than
// the viewer sent.
Input_Echo_Tracker :: struct {
	last_echo_count: u64,
}

// input_echo_check refuses a count that goes backward or exceeds sent_count,
// leaving tracker unchanged on refusal.
input_echo_check :: proc "contextless" (tracker: ^Input_Echo_Tracker, echo_count: u64, sent_count: u64) -> Record_Problem {
	if echo_count < tracker.last_echo_count || echo_count > sent_count {
		return .Bad_Field
	}
	tracker.last_echo_count = echo_count
	return .None
}

// body_read copies a body out of bytes, with no alignment. The border
// checked the length first.
@(private)
body_read :: proc "contextless" (bytes: []u8, $T: typeid) -> (value: T) {
	intrinsics.mem_copy_non_overlapping(&value, raw_data(bytes), size_of(T))
	return value
}

// record_write writes a header and its body in out, and gives the bytes.
// ok is false when they do not fit.
record_write :: proc "contextless" (out: []u8, kind: Record_Kind, body: $T) -> (bytes: []u8, ok: bool) {
	total := RECORD_HEADER_SIZE + size_of(T)
	if len(out) < total {
		return nil, false
	}
	header := Record_Header{kind = kind, length = size_of(T)}
	value := body
	intrinsics.mem_copy_non_overlapping(raw_data(out), &header, RECORD_HEADER_SIZE)
	intrinsics.mem_copy_non_overlapping(raw_data(out[RECORD_HEADER_SIZE:]), &value, size_of(T))
	return out[:total], true
}

// screen_piece_record_write writes a whole Screen_Piece record in out: the header, the screen piece
// header, then the code of the pixels of the rectangle of a picture, from
// the pixel at (x, y) of rows of stride pixels. ok is false when out cannot
// hold the worst code of the screen piece.
screen_piece_record_write :: proc "contextless" (out: []u8, pixels: []u32, stride: int, x, y, width, height: u32) -> (bytes: []u8, ok: bool) {
	head := RECORD_HEADER_SIZE + size_of(Screen_Piece_Header)
	if width == 0 || height == 0 || width > SCREEN_PIECE_WIDTH || height > SCREEN_PIECE_HEIGHT || u64(len(out)) < u64(head) + u64(coded_limit(width * height)) {
		return nil, false
	}
	coded := screen_piece_encode(pixels, stride, int(x), int(y), int(width), int(height), out[head:])
	screen_piece := Screen_Piece_Header{x = x, y = y, width = width, height = height, coded_length = u32(coded)}
	header := Record_Header{kind = .Screen_Piece, length = u32(size_of(Screen_Piece_Header) + coded)}
	intrinsics.mem_copy_non_overlapping(raw_data(out), &header, RECORD_HEADER_SIZE)
	intrinsics.mem_copy_non_overlapping(raw_data(out[RECORD_HEADER_SIZE:]), &screen_piece, size_of(Screen_Piece_Header))
	return out[:head + coded], true
}

// pointer_picture_record_write writes a whole Pointer_Picture record into
// out: Record_Header, Pointer_Picture_Header, and size * size * 4 pixel bytes.
pointer_picture_record_write :: proc "contextless" (out: []u8, shape: pointer_pictures.Pointer_Shape, form: pointer_pictures.Pointer_Form, size, hot_spot_x, hot_spot_y: u32, pixels: []u32) -> (bytes: []u8, ok: bool) {
	if size < POINTER_SIZE_MINIMUM || size > POINTER_SIZE_MAXIMUM || hot_spot_x >= size || hot_spot_y >= size {
		return nil, false
	}
	pixel_count := int(size * size)
	if len(pixels) != pixel_count {
		return nil, false
	}
	pixel_bytes := pixel_count * 4
	body_length := size_of(Pointer_Picture_Header) + pixel_bytes
	total := RECORD_HEADER_SIZE + body_length
	if len(out) < total {
		return nil, false
	}
	header := Record_Header{kind = .Pointer_Picture, length = u32(body_length)}
	pic := Pointer_Picture_Header{
		shape      = u32(shape),
		form       = u32(form),
		size       = size,
		hot_spot_x = hot_spot_x,
		hot_spot_y = hot_spot_y,
	}
	intrinsics.mem_copy_non_overlapping(raw_data(out), &header, RECORD_HEADER_SIZE)
	intrinsics.mem_copy_non_overlapping(raw_data(out[RECORD_HEADER_SIZE:]), &pic, size_of(Pointer_Picture_Header))
	intrinsics.mem_copy_non_overlapping(raw_data(out[RECORD_HEADER_SIZE + size_of(Pointer_Picture_Header):]), raw_data(pixels), pixel_bytes)
	return out[:total], true
}

// The screen pieces of a rectangle: a rectangle of the damage goes as screen pieces of
// SCREEN_PIECE_WIDTH x SCREEN_PIECE_HEIGHT at most, from its top left corner, row after
// row.
screen_piece_count :: proc "contextless" (width, height: u32) -> u32 {
	return ((width + SCREEN_PIECE_WIDTH - 1) / SCREEN_PIECE_WIDTH) * ((height + SCREEN_PIECE_HEIGHT - 1) / SCREEN_PIECE_HEIGHT)
}

// screen_piece_at gives the screen piece with an index of a rectangle, from 0 to
// screen_piece_count - 1.
screen_piece_at :: proc "contextless" (x, y, width, height: u32, index: u32) -> (piece_x, piece_y, piece_width, piece_height: u32) {
	across := (width + SCREEN_PIECE_WIDTH - 1) / SCREEN_PIECE_WIDTH
	column, row := index % max(across, 1), index / max(across, 1)
	piece_x = x + column * SCREEN_PIECE_WIDTH
	piece_y = y + row * SCREEN_PIECE_HEIGHT
	piece_width = min(SCREEN_PIECE_WIDTH, x + width - piece_x)
	piece_height = min(SCREEN_PIECE_HEIGHT, y + height - piece_y)
	return
}
