// The concrete Display role contract: the exports and shared-memory ring faces
// that any holder of the Display role must provide (surfaces, presentation,
// control, input, palette, capture, and screen/window/pointer inspection).
package role_contract

import "modus:contract/display_choices"
import "modus:contract/draw_record"
import "modus:contract/notifications"
import op "modus:contract/operation"
import "modus:contract/palette_table"

// Contract version number for readers; the BLAKE3 hash decides every check.
// 3: Surface_Create, Surface_Resize, Surface_Rescale and Capture_Open give
// a budget, the holder makes the memory with it and names it in its answer
// (the event Capture_Opened for the capture face).
// 4: the settings of the role (set, reset, settings_state and the getters
// of each setting), and the event Presentation in place of Settings_Changed.
// 5: both changes together, the merge of two forms of 3 that each took the
// next number.
// 6: opt-in relative pointer lock on the window ring (Command.Pointer_Lock,
// Event_Kind.Pointer_Delta, and Event_Kind.Pointer_Lock_Changed).
DISPLAY_CONTRACT_VERSION :: u32(6)

// Closed counts of the Display ring protocols, matching the compositor faces.
DISPLAY_WINDOW_COMMAND_COUNT :: u32(23)
DISPLAY_WINDOW_EVENT_COUNT :: u32(15)
DISPLAY_CONTROL_COMMAND_COUNT :: u32(7)
DISPLAY_CONTROL_EVENT_COUNT :: u32(2)
DISPLAY_INPUT_COMMAND_COUNT :: u32(2)
DISPLAY_PALETTE_COMMAND_COUNT :: u32(5)
DISPLAY_PALETTE_OUTCOME_COUNT :: u32(7)

// Handle rights bits required on lent handles crossing Display rings.
DISPLAY_WINDOW_HANDLE_RIGHTS :: u32(1) << u32(op.Right.Read)
DISPLAY_CONTROL_HANDLE_RIGHTS :: (u32(1) << u32(op.Right.Read)) | (u32(1) << u32(op.Right.Write))

// Surface bounds of the Display contract.
DISPLAY_SURFACE_LIMIT :: u32(8192)
DISPLAY_PICTURE_COUNT :: u32(2)

// Required export names of the Display role.
DISPLAY_EXPORT_POINTER :: "pointer"
DISPLAY_EXPORT_WINDOWS :: "windows"
DISPLAY_EXPORT_SCREEN :: "screen"
// The settings of the role (modus:contract/display_choices): each holder
// serves them, so a holder that the plan puts in place of another keeps the
// choices of the principal and their setters.
DISPLAY_EXPORT_SET :: "set"
DISPLAY_EXPORT_RESET :: "reset"
DISPLAY_EXPORT_SETTINGS_STATE :: "settings_state"

// Required ring face names of the Display role.
DISPLAY_RING_WINDOW :: "window_ring"
DISPLAY_RING_CONTROL :: "control_ring"
DISPLAY_RING_INPUT :: "input_ring"
DISPLAY_RING_PALETTE :: "palette_ring"

@(private = "file")
DISPLAY_RING_FACE_WINDOW :: Required_Ring_Face {
	name             = DISPLAY_RING_WINDOW,
	command_count    = DISPLAY_WINDOW_COMMAND_COUNT,
	event_count      = DISPLAY_WINDOW_EVENT_COUNT,
	carries_handles  = true,
	handle_rights    = DISPLAY_WINDOW_HANDLE_RIGHTS,
	protocol_version = draw_record.VERSION,
}

@(private = "file")
DISPLAY_RING_FACE_CONTROL :: Required_Ring_Face {
	name             = DISPLAY_RING_CONTROL,
	command_count    = DISPLAY_CONTROL_COMMAND_COUNT,
	event_count      = DISPLAY_CONTROL_EVENT_COUNT,
	carries_handles  = true,
	handle_rights    = DISPLAY_CONTROL_HANDLE_RIGHTS,
	protocol_version = 1,
}

@(private = "file")
DISPLAY_RING_FACE_INPUT :: Required_Ring_Face {
	name             = DISPLAY_RING_INPUT,
	command_count    = DISPLAY_INPUT_COMMAND_COUNT,
	event_count      = 0,
	carries_handles  = false,
	handle_rights    = 0,
	protocol_version = 1,
}

@(private = "file")
DISPLAY_RING_FACE_PALETTE :: Required_Ring_Face {
	name             = DISPLAY_RING_PALETTE,
	command_count    = DISPLAY_PALETTE_COMMAND_COUNT,
	event_count      = DISPLAY_PALETTE_OUTCOME_COUNT,
	carries_handles  = false,
	handle_rights    = 0,
	protocol_version = palette_table.VERSION,
}

@(private = "file", rodata)
display_required_ring_faces := [4]Required_Ring_Face {
	DISPLAY_RING_FACE_WINDOW,
	DISPLAY_RING_FACE_CONTROL,
	DISPLAY_RING_FACE_INPUT,
	DISPLAY_RING_FACE_PALETTE,
}

@(private = "file", rodata)
display_required_faces := [5]Required_Face {
	{
		kind    = .Exports,
		name    = "display_exports",
		exports = {
			{
				name               = DISPLAY_EXPORT_POINTER,
				parameters         = nil,
				result             = .Table,
				result_record_name = "Pointer",
				has_error_record   = true,
				error_record_name  = "Error_Record",
			},
			{
				name               = DISPLAY_EXPORT_WINDOWS,
				parameters         = nil,
				result             = .Table,
				result_record_name = "Window",
				has_error_record   = true,
				error_record_name  = "Error_Record",
			},
			{
				name               = DISPLAY_EXPORT_SCREEN,
				parameters         = nil,
				result             = .Table,
				result_record_name = "Screen",
				has_error_record   = true,
				error_record_name  = "Error_Record",
			},
			{
				name              = DISPLAY_EXPORT_SET,
				// Each setting is optional; a number carries the range of its
				// contract, so a holder with another range is refused.
				parameters        = {
					{type = .Enum, direction = .Read, record_name = "Bar_Position", optional = true},
					{type = .Enum, direction = .Read, record_name = "Do_Not_Disturb", optional = true},
					{type = .Integer, direction = .Read, optional = true, has_range = true, least = i64(notifications.SHOW_MILLISECONDS_LEAST), most = i64(notifications.SHOW_MILLISECONDS_MOST)},
					{type = .Integer, direction = .Read, optional = true, has_range = true, least = i64(display_choices.MAGNIFIER_EIGHTHS_LEAST), most = i64(display_choices.MAGNIFIER_EIGHTHS_MOST)},
					{type = .Integer, direction = .Read, optional = true, has_range = true, least = i64(display_choices.CONSENT_ARM_MILLISECONDS_LEAST), most = i64(display_choices.CONSENT_ARM_MILLISECONDS_MOST)},
				},
				result            = .Integer,
				has_error_record  = true,
				error_record_name = "Error_Record",
			},
			{name = "bar_edge", parameters = nil, result = .Enum},
			{name = "do_not_disturb", parameters = nil, result = .Enum},
			{name = "notification_time", parameters = nil, result = .Integer},
			{name = "magnifier_factor", parameters = nil, result = .Integer},
			{name = "consent_arm_time", parameters = nil, result = .Integer},
			{
				name              = DISPLAY_EXPORT_RESET,
				parameters        = {{type = .Enum, direction = .Read, record_name = "Setting"}},
				result            = .Integer,
				has_error_record  = true,
				error_record_name = "Error_Record",
			},
			{
				name               = DISPLAY_EXPORT_SETTINGS_STATE,
				parameters         = nil,
				result             = .Table,
				result_record_name = "Setting_State",
				has_error_record   = true,
				error_record_name  = "Error_Record",
			},
		},
	},
	{
		kind      = .Ring,
		name      = DISPLAY_RING_WINDOW,
		ring_face = DISPLAY_RING_FACE_WINDOW,
	},
	{
		kind      = .Ring,
		name      = DISPLAY_RING_CONTROL,
		ring_face = DISPLAY_RING_FACE_CONTROL,
	},
	{
		kind      = .Ring,
		name      = DISPLAY_RING_INPUT,
		ring_face = DISPLAY_RING_FACE_INPUT,
	},
	{
		kind      = .Ring,
		name      = DISPLAY_RING_PALETTE,
		ring_face = DISPLAY_RING_FACE_PALETTE,
	},
}

// display_contract returns the canonical Role_Contract for Role.Display.
display_contract :: proc "contextless" () -> Role_Contract {
	return {
		role    = .Display,
		version = DISPLAY_CONTRACT_VERSION,
		faces   = display_required_faces[:],
	}
}

// display_ring_faces returns the canonical list of ring faces required by the
// Display contract.
display_ring_faces :: proc "contextless" () -> []Required_Ring_Face {
	return display_required_ring_faces[:]
}

// display_contract_hash computes the deterministic BLAKE3 hash of the Display
// role contract.
display_contract_hash :: proc "contextless" () -> Contract_Hash {
	digest, _ := contract_hash(display_contract())
	return digest
}
