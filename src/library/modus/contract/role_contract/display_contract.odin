// The concrete Display role contract: the exports and shared-memory ring faces
// that any holder of the Display role must provide (surfaces, presentation,
// control, input, palette, capture, and screen/window/pointer inspection).
package role_contract

import "modus:contract/draw_record"
import op "modus:contract/operation"
import "modus:contract/palette_table"

// Contract version number for readers; the BLAKE3 hash decides every check.
DISPLAY_CONTRACT_VERSION :: u32(2)

// Closed counts of the Display ring protocols, matching the compositor faces.
DISPLAY_WINDOW_COMMAND_COUNT :: u32(20)
DISPLAY_WINDOW_EVENT_COUNT :: u32(12)
DISPLAY_CONTROL_COMMAND_COUNT :: u32(7)
DISPLAY_CONTROL_EVENT_COUNT :: u32(2)
DISPLAY_INPUT_COMMAND_COUNT :: u32(2)
DISPLAY_PALETTE_COMMAND_COUNT :: u32(5)
DISPLAY_PALETTE_OUTCOME_COUNT :: u32(7)

// Handle rights bits required on lent handles crossing Display rings.
DISPLAY_WINDOW_HANDLE_RIGHTS :: u32(1) << u32(op.Right.Read)
DISPLAY_CONTROL_HANDLE_RIGHTS :: (u32(1) << u32(op.Right.Read)) | (u32(1) << u32(op.Right.Write))

// Surface bounds of the Display contract.
DISPLAY_SURFACE_LIMIT :: u32(2048)
DISPLAY_PICTURE_COUNT :: u32(2)

// Required export names of the Display role.
DISPLAY_EXPORT_POINTER :: "pointer"
DISPLAY_EXPORT_WINDOWS :: "windows"
DISPLAY_EXPORT_SCREEN :: "screen"

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
