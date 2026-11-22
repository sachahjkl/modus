// The sample history of the process `monitor`
// (src/md/features/monitor_window.md, "The sample history"): the values of
// one measure in the last samples, and the points of the curve that the
// window draws from them. The points are computed when a sample comes and
// kept, so a frame copies them and computes nothing over the samples. The
// rates of a sample are here too: pure arithmetic that the host tests check
// at the largest values.
package sample_history

import "modus:contract/draw_record"

// The samples that a history keeps: 60 s at one sample each 500 ms.
SAMPLE_HISTORY_LENGTH :: 120
// The points of the stroke of the curve, one for each sample, and of the
// area under it: the curve, a point on the base at each end, and the close.
STROKE_POINT_CAPACITY :: SAMPLE_HISTORY_LENGTH
AREA_POINT_CAPACITY :: SAMPLE_HISTORY_LENGTH + 3
#assert(AREA_POINT_CAPACITY <= draw_record.PATH_POINT_LIMIT)

// The smallest side of a box, in pixels: the curve lies 1 pixel inside each
// edge, so a smaller box leaves no room between the two lines of places.
BOX_SIDE_LEAST :: 3

// The largest top of a scale that is rounded up: 10^19, the largest power
// of ten in 64 bits. A larger value draws on the top edge.
ROUNDED_TOP_LARGEST :: u64(10_000_000_000_000_000_000)

// How the top of the vertical scale of a graph is found.
Scale :: enum u8 {
	Fixed      = 0, // The top is a value that each push gives: all the pages, 100 %.
	Rounded_Up = 1, // The top is the largest value of the history, rounded up to 1, 2 or 5 times a power of ten.
}

// The box of a graph, in pixels of the surface.
Graph_Box :: struct {
	left, top, width, height: int,
}

Path_Point :: draw_record.Path_Point

// The values of one measure in the last samples, and the curve of them.
Sample_History :: struct {
	values:       [SAMPLE_HISTORY_LENGTH]u64,
	oldest:       int, // The place in values of the oldest value.
	count:        int, // The values in use: SAMPLE_HISTORY_LENGTH when the history is full.
	scale:        Scale,
	top:          u64, // The value at the top edge of the graph: at least 1.
	box:          Graph_Box,
	started:      bool, // sample_history_start set the box.
	// The curve of the values, oldest first: a Move and a Line for each
	// newer value. No point with fewer than two values: a path needs a
	// segment.
	stroke:       [STROKE_POINT_CAPACITY]Path_Point,
	stroke_count: int,
	// The area under the curve: a Move on the base under the oldest value,
	// the curve, a Line to the base under the newest value, and a Close.
	area:         [AREA_POINT_CAPACITY]Path_Point,
	area_count:   int,
}

// box_valid says if a box can hold a graph: no negative edge, each side at
// least BOX_SIDE_LEAST, and each edge inside COORDINATE_LIMIT. The checks
// compare before they add, so a large side cannot wrap the sum.
box_valid :: proc "contextless" (box: Graph_Box) -> bool {
	if box.left < 0 || box.top < 0 || box.width < BOX_SIDE_LEAST || box.height < BOX_SIDE_LEAST {
		return false
	}
	return box.left <= draw_record.COORDINATE_LIMIT - box.width && box.top <= draw_record.COORDINATE_LIMIT - box.height
}

// sample_history_start makes an empty history of a scale in a box. It
// refuses a box that box_valid refuses: the history is then not changed.
sample_history_start :: proc "contextless" (history: ^Sample_History, scale: Scale, box: Graph_Box) -> bool {
	if !box_valid(box) {
		return false
	}
	history^ = {}
	history.scale = scale
	history.box = box
	history.top = 1
	history.started = true
	return true
}

// sample_history_box_set moves the graph of a history to another box: the
// window was resized, and its layout gives the graph another place. The
// points of the curve are placed again from the kept values, once for the
// change; the same box changes nothing, so a frame that gives the box of
// the frame before does no work in proportion to the samples. It refuses a
// box that box_valid refuses and a history that sample_history_start did
// not start: the history is then not changed.
sample_history_box_set :: proc "contextless" (history: ^Sample_History, box: Graph_Box) -> bool {
	if !history.started || !box_valid(box) {
		return false
	}
	if history.box == box {
		return true
	}
	history.box = box
	curve_place(history)
	return true
}

// sample_history_push adds the value of a new sample, which replaces the
// oldest one in a full history, then finds the top of the scale and the
// points of the curve. fixed_top is the top of a Fixed scale (all the pages
// of the machine, 100 %); a Rounded_Up scale does not read it. It refuses a
// Fixed top of 0 and a history that sample_history_start did not start:
// nothing changes.
sample_history_push :: proc "contextless" (history: ^Sample_History, value: u64, fixed_top: u64) -> bool {
	if !history.started || !box_valid(history.box) {
		return false
	}
	if history.scale == .Fixed && fixed_top == 0 {
		return false
	}
	if history.count < SAMPLE_HISTORY_LENGTH {
		history.values[(history.oldest + history.count) % SAMPLE_HISTORY_LENGTH] = value
		history.count += 1
	} else {
		history.values[history.oldest] = value
		history.oldest = (history.oldest + 1) % SAMPLE_HISTORY_LENGTH
	}
	switch history.scale {
	case .Fixed:
		history.top = fixed_top
	case .Rounded_Up:
		largest: u64
		for index in 0 ..< history.count {
			largest = max(largest, value_at(history, index))
		}
		history.top = rounded_top(largest)
	}
	curve_place(history)
	return true
}

// value_at gives a value by its age order: 0 is the oldest value.
value_at :: proc "contextless" (history: ^Sample_History, index: int) -> u64 {
	return history.values[(history.oldest + index) % SAMPLE_HISTORY_LENGTH]
}

// rounded_top gives the smallest of 1, 2 and 5 times a power of ten that is
// at least value: 1 for 0, ROUNDED_TOP_LARGEST for each value past 5 * 10^18.
rounded_top :: proc "contextless" (value: u64) -> u64 {
	factors := [3]u64{1, 2, 5}
	power: u64 = 1
	// 5 * 10^18 is the largest product that the loop makes: under 2^64.
	for power < ROUNDED_TOP_LARGEST {
		for factor in factors {
			if value <= factor * power {
				return factor * power
			}
		}
		power *= 10
	}
	return ROUNDED_TOP_LARGEST
}

// The places of the curve, in units of 1/64 pixel. The stroke is 2 pixels
// wide, so each place is 1 pixel inside the box, and the stroke stays in it.
UNITS :: draw_record.UNITS_PER_PIXEL

// curve_place computes the points of the stroke and of the area from the
// values: the newest value at the right, each older one a step to the left,
// a step being the width over SAMPLE_HISTORY_LENGTH - 1. A value past the
// top lies on the top edge.
@(private)
curve_place :: proc "contextless" (history: ^Sample_History) {
	history.stroke_count = 0
	history.area_count = 0
	if history.count < 2 {
		return
	}
	box := history.box
	left := i64(box.left + 1) * UNITS
	right := i64(box.left + box.width - 1) * UNITS
	top := i64(box.top + 1) * UNITS
	base := i64(box.top + box.height - 1) * UNITS
	span := right - left
	height := u64(base - top)
	for index in 0 ..< history.count {
		age := i64(history.count - 1 - index)
		x := right - age * span / (SAMPLE_HISTORY_LENGTH - 1)
		y := base - i64(height_of(value_at(history, index), history.top, height))
		command := draw_record.Path_Command.Line
		if index == 0 {
			command = .Move
		}
		history.stroke[index] = {command = command, x = i32(x), y = i32(y)}
		history.area[index + 1] = {command = .Line, x = i32(x), y = i32(y)}
	}
	first_x := history.stroke[0].x
	last_x := history.stroke[history.count - 1].x
	history.area[0] = {command = .Move, x = first_x, y = i32(base)}
	history.area[history.count + 1] = {command = .Line, x = last_x, y = i32(base)}
	history.area[history.count + 2] = {command = .Close}
	history.stroke_count = history.count
	history.area_count = history.count + 3
}

// height_of gives the height of a value over the base, in units: value
// times height over top, with value cut to top. When that product passes 64
// bits, the value is divided by top over height: top is then far larger
// than height, so the quotient is at least 1.
height_of :: proc "contextless" (value, top, height: u64) -> u64 {
	if top == 0 {
		return 0
	}
	shown := min(value, top)
	if top <= max(u64) / max(height, 1) {
		return shown * height / top
	}
	return min(shown / (top / height), height)
}

// rate_per_second gives a count in a time as a count in one second. It
// refuses a time of 0. The product with 1000 is done after the division
// when it passes 64 bits, and the result saturates at the largest value.
rate_per_second :: proc "contextless" (count, milliseconds: u64) -> (rate: u64, ok: bool) {
	if milliseconds == 0 {
		return 0, false
	}
	if count <= max(u64) / 1000 {
		return count * 1000 / milliseconds, true
	}
	whole := count / milliseconds
	if whole > max(u64) / 1000 {
		return max(u64), true
	}
	return whole * 1000, true
}

// processor_time_percent gives the processor time of all the processes in
// a time, over that time on every processor, in percent. It refuses a time
// of 0 and 0 processors. The run times and the time of the report are read
// at two moments, so a sum past the whole saturates at 100.
processor_time_percent :: proc "contextless" (run_time, milliseconds, processors: u64) -> (percent: u64, ok: bool) {
	if milliseconds == 0 || processors == 0 {
		return 0, false
	}
	whole := milliseconds > max(u64) / processors ? max(u64) : milliseconds * processors
	if run_time >= whole {
		return 100, true
	}
	// run_time is under whole: its product with 100 passes 64 bits only
	// when whole is large, and then whole / 100 is at least 1. That quotient
	// rounds down, so the share can be one more than its floor, and a time
	// under the whole stays under 100.
	if run_time <= max(u64) / 100 {
		return run_time * 100 / whole, true
	}
	return min(run_time / (whole / 100), 99), true
}

// The suffixes of a compact number: thousands, millions, and so on, up to
// 10^18, past which no 64-bit number has a digit.
COMPACT_SUFFIXES :: "kMGTPE"
// The bytes of a compact number: four digits and one suffix.
COMPACT_TEXT_SIZE :: 5

// compact_number_text writes a number with at most four digits: a number of
// 10 000 or more is divided by 1000 until it is under 10 000, and gets the
// suffix of each division (20 000 is "20k"). The division cuts: the tops of
// a rounded scale are exact.
compact_number_text :: proc "contextless" (buffer: ^[COMPACT_TEXT_SIZE]u8, value: u64) -> string {
	shown := value
	divisions := 0
	for shown >= 10_000 && divisions < len(COMPACT_SUFFIXES) {
		shown /= 1000
		divisions += 1
	}
	// A number under 10 000 has at most four digits.
	digits: [4]u8
	count := 0
	for {
		digits[count] = u8('0' + shown % 10)
		count += 1
		shown /= 10
		if shown == 0 || count == len(digits) {
			break
		}
	}
	length := 0
	for index := count - 1; index >= 0; index -= 1 {
		buffer[length] = digits[index]
		length += 1
	}
	if divisions > 0 {
		suffixes := COMPACT_SUFFIXES
		buffer[length] = suffixes[divisions - 1]
		length += 1
	}
	return string(buffer[:length])
}
