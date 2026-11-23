package paint

import "modus:contract/value_kinds"

// The log facts of paint (src/md/features/log_facts.md). A Text field
// comes last, and holds its longest text and a zero byte. A name of a
// picture has the length of a name of the store, so it is a text view, a
// last field.

// The window is open and draws.
@(log_fact = "paint: ok")
Running :: struct {}

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "paint: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

// The process has no connection to its private store: it draws, and keeps
// no picture.
@(log_fact = "paint: no store: the pictures cannot be saved")
No_Store :: struct {}

// The store kept the changed rows of the open picture, in one commit.
@(log_fact = "paint: the store keeps the picture: {rows} rows in {bytes} bytes of {name}")
Picture_Kept :: struct {
	rows:  u64,
	bytes: u64,
	name:  value_kinds.Text_View,
}

// A picture of the private store is the picture of the window, and it
// holds a drawing: pixels that are not paper.
@(log_fact = "paint: the picture is open with a drawing: {width} x {height} pixels, {drawn_pixels} not paper, from {name}")
Picture_Opened :: struct {
	width:        u64,
	height:       u64,
	drawn_pixels: u64,
	name:         value_kinds.Text_View,
}

// A picture of the private store is the picture of the window, all paper.
@(log_fact = "paint: the picture is open, all paper: {width} x {height} pixels from {name}")
Picture_Opened_Blank :: struct {
	width:  u64,
	height: u64,
	name:   value_kinds.Text_View,
}

// The file of a picture is refused: the picture of the window stays.
@(log_fact = "paint: the file of the picture is refused, problem {problem}: {name}")
Picture_Refused :: struct {
	problem: u64,
	name:    value_kinds.Text_View,
}

// The budget did not pay the memory of a picture of a size: the picture of
// the window stays as it was. A budget that the plan gives pays more.
@(log_fact = "paint: the budget does not pay a picture of {width} x {height} pixels")
Picture_Memory_Refused :: struct {
	width:  u64,
	height: u64,
}

// A call of the store failed.
@(log_fact = "paint: the store refused the call {act} with the status {status}")
Store_Call_Failed :: struct {
	status: u64,
	act:    [16]u8,
}
