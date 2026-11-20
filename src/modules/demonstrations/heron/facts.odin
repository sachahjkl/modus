package heron

import "modus:contract/value_kinds"

// The log facts of the demonstration heron (src/md/features/log_facts.md,
// "The facts of the demonstrations"): the animations played and what the
// window shows, as records of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A Text field comes last, and holds its
// longest text and a zero byte.
//
// A part of a sentence that is there or not (", held", the motion of the
// heron, the ways) is a Text field that holds it with its comma, or
// nothing. A line with no value is a fact type with no field.

// The means of the pictures of the first animation that a key asked for:
// the time of a picture to draw and the pixels that it damaged.
@(log_fact = "heron: a picture of {animation} took {picture_time} to draw and damaged {damaged_pixels} pixels of the {window_pixels} of the window, the means of {pictures} pictures (a measure)")
Picture_Measured :: struct {
	picture_time:   value_kinds.Nanoseconds_As_Microseconds,
	damaged_pixels: u64,
	window_pixels:  u64,
	pictures:       u64,
	animation:      [16]u8,
}

@(log_fact = "heron: no random seed in the context")
No_Random_Seed :: struct {}

@(log_fact = "heron: ok, the first picture is presented")
First_Picture_Presented :: struct {}

@(log_fact = "heron: paused")
Paused :: struct {}

@(log_fact = "heron: plays again")
Plays_Again :: struct {}

@(log_fact = "heron: slow")
Slow :: struct {}

@(log_fact = "heron: full speed")
Full_Speed :: struct {}

// An animation that the heron played in its own order.
@(log_fact = "heron: {animation} played in its own order: {frames} frames")
Played_In_Own_Order :: struct {
	frames:    u64,
	animation: [16]u8,
}

// An animation that a key asked for: its frames, where the heron ended,
// and the ways that it played.
@(log_fact = "heron: {animation} played: {frames} frames{motion}{ways}")
Played :: struct {
	frames:    u64,
	animation: [16]u8,
	motion:    [48]u8,
	ways:      [24]u8,
}

// The window shows the still heron.
@(log_fact = "heron: shows the still heron, {way}; the lines of the cells {cell_lines}")
Still_Shown :: struct {
	way:        [16]u8,
	cell_lines: [8]u8,
}

// The window shows a frame of an animation on the grid.
@(log_fact = "heron: shows {animation} at frame {frame} of {frame_count}{held}, on the grid: the form {form}, {cells_sideways} cells to the {side} and {cells_up} up; the lines of the cells {cell_lines}; {changed_cells} cells of the frame differ from the still heron")
Grid_Frame_Shown :: struct {
	frame:          u64,
	frame_count:    u64,
	cells_sideways: u64,
	cells_up:       u64,
	changed_cells:  u64,
	animation:      [16]u8,
	held:           [8]u8,
	form:           [16]u8,
	side:           [8]u8,
	cell_lines:     [8]u8,
}

// The window shows a frame of an animation, free.
@(log_fact = "heron: shows {animation} at frame {frame} of {frame_count}{held}, free: the frame stretched to {width} by {height} pixels; the lines of the cells {cell_lines}; {changed_cells} cells of the frame differ from the still heron")
Free_Frame_Shown :: struct {
	frame:         u64,
	frame_count:   u64,
	width:         u64,
	height:        u64,
	changed_cells: u64,
	animation:     [16]u8,
	held:          [8]u8,
	cell_lines:    [8]u8,
}

// The size of the cells changed.
@(log_fact = "heron: cells of {cell_size} pixels")
Cell_Size_Changed :: struct {
	cell_size: u64,
}
