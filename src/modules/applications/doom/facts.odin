package doom

import "modus:contract/value_kinds"

// Log facts of the Doom application module. Text fields come last in each
// record so the log formatter stops at the trailing zero byte.

REASON_FIELD_BYTES :: 40
STATE_FIELD_BYTES :: 16
LOG_LINE_FIELD_BYTES :: 96

// The module loaded its WAD and presented its first game frame.
@(log_fact = "doom: ok, {width}x{height} window, {wad_size} WAD")
Running :: struct {
	width:    u64,
	height:   u64,
	wad_size: value_kinds.Size_In_Bytes,
}

// No WAD object was found in the process private store.
@(log_fact = "doom: no WAD file in the private store")
Wad_Missing :: struct {}

// Reading the WAD from the private store failed.
@(log_fact = "doom: WAD read failed with status {status}")
Wad_Read_Failed :: struct {
	status: u64,
}

// No virtio sound device was granted to this process; audio runs silent.
@(log_fact = "doom: sound device absent; running silent")
Sound_Absent :: struct {}

// The 48 kHz stereo timed stream started for Doom sound effects.
@(log_fact = "doom: sound stream started; latency {latency}")
Sound_Started :: struct {
	latency: value_kinds.Time_In_Nanoseconds,
}

// Measured frame rate reported every 35 rendered frames.
@(log_fact = "doom: frame {frame} rendered ({fps} fps)")
Fps_Measured :: struct {
	frame: u64,
	fps:   u64,
}

// Pointer lock state changed as confirmed by the compositor.
@(log_fact = "doom: pointer lock {state} ({reason})")
Pointer_Lock_Event :: struct {
	state:  [16]u8,
	reason: [40]u8,
}

// The Doom engine ended through I_Quit or I_Error.
@(log_fact = "doom: engine stopped ({reason})")
Engine_Stopped :: struct {
	reason: [40]u8,
}

// One line printed by the C engine during startup or error reporting.
@(log_fact = "doom: engine: {line}")
Engine_Log :: struct {
	line: [96]u8,
}
