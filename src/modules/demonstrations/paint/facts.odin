package paint

// The log facts of paint (src/md/features/log_facts.md). A Text field
// comes last, and holds its longest text and a zero byte.

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

// A picture is in the private store.
@(log_fact = "paint: the picture is saved: {width} x {height} pixels in {bytes} bytes as {name}")
Picture_Saved :: struct {
	width:  u64,
	height: u64,
	bytes:  u64,
	name:   [40]u8,
}

// A picture of the private store is the picture of the window.
@(log_fact = "paint: the picture is open: {width} x {height} pixels from {name}")
Picture_Opened :: struct {
	width:  u64,
	height: u64,
	name:   [40]u8,
}

// The file of a picture is refused: the picture of the window stays.
@(log_fact = "paint: the file of the picture is refused, problem {problem}: {name}")
Picture_Refused :: struct {
	problem: u64,
	name:    [40]u8,
}

// A call of the store failed.
@(log_fact = "paint: the store refused the call {act} with the status {status}")
Store_Call_Failed :: struct {
	status: u64,
	act:    [16]u8,
}
