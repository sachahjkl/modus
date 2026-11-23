// The concrete Powerbox role contract: the exports and shared-memory ring
// faces that any holder of Role.Powerbox must provide (grouped consent request
// handling, trusted display dialog mediation, and status inspection).
package role_contract

import op "modus:contract/operation"

// Contract version number for readers; the BLAKE3 hash decides every check.
POWERBOX_CONTRACT_VERSION :: u32(1)

// Closed counts of the Powerbox ring protocols.
POWERBOX_SERVICE_COMMAND_COUNT :: u32(5)
POWERBOX_SERVICE_EVENT_COUNT :: u32(5)
POWERBOX_DISPLAY_COMMAND_COUNT :: u32(3)
POWERBOX_DISPLAY_EVENT_COUNT :: u32(2)

// Handle rights required on lent request regions crossing the service ring.
POWERBOX_SERVICE_HANDLE_RIGHTS :: u32(1) << u32(op.Right.Read)

// Required export names of the Powerbox role.
POWERBOX_EXPORT_PENDING_COUNT :: "pending_count"
POWERBOX_EXPORT_STATUS :: "status"

// Required ring face names of the Powerbox role.
POWERBOX_RING_GRANT_REQUEST :: "grant_request_ring"
POWERBOX_RING_TRUSTED_DISPLAY :: "trusted_display_ring"

@(private = "file")
POWERBOX_RING_FACE_GRANT_REQUEST :: Required_Ring_Face {
	name             = POWERBOX_RING_GRANT_REQUEST,
	command_count    = POWERBOX_SERVICE_COMMAND_COUNT,
	event_count      = POWERBOX_SERVICE_EVENT_COUNT,
	carries_handles  = true,
	handle_rights    = POWERBOX_SERVICE_HANDLE_RIGHTS,
	protocol_version = 1,
}

@(private = "file")
POWERBOX_RING_FACE_TRUSTED_DISPLAY :: Required_Ring_Face {
	name             = POWERBOX_RING_TRUSTED_DISPLAY,
	command_count    = POWERBOX_DISPLAY_COMMAND_COUNT,
	event_count      = POWERBOX_DISPLAY_EVENT_COUNT,
	carries_handles  = false,
	handle_rights    = 0,
	protocol_version = 1,
}

@(private = "file", rodata)
powerbox_required_ring_faces := [2]Required_Ring_Face {
	POWERBOX_RING_FACE_GRANT_REQUEST,
	POWERBOX_RING_FACE_TRUSTED_DISPLAY,
}

@(private = "file", rodata)
powerbox_required_faces := [3]Required_Face {
	{
		kind    = .Exports,
		name    = "powerbox_exports",
		exports = {
			{
				name              = POWERBOX_EXPORT_PENDING_COUNT,
				parameters        = nil,
				result            = .Integer,
				has_error_record  = true,
				error_record_name = "Error_Record",
			},
			{
				name               = POWERBOX_EXPORT_STATUS,
				parameters         = nil,
				result             = .Record,
				result_record_name = "Powerbox_Status",
				has_error_record   = true,
				error_record_name  = "Error_Record",
			},
		},
	},
	{
		kind      = .Ring,
		name      = POWERBOX_RING_GRANT_REQUEST,
		ring_face = POWERBOX_RING_FACE_GRANT_REQUEST,
	},
	{
		kind      = .Ring,
		name      = POWERBOX_RING_TRUSTED_DISPLAY,
		ring_face = POWERBOX_RING_FACE_TRUSTED_DISPLAY,
	},
}

// powerbox_contract returns the canonical Role_Contract for Role.Powerbox.
powerbox_contract :: proc "contextless" () -> Role_Contract {
	return {
		role    = .Powerbox,
		version = POWERBOX_CONTRACT_VERSION,
		faces   = powerbox_required_faces[:],
	}
}

// powerbox_ring_faces returns the canonical list of ring faces required by the
// Powerbox contract.
powerbox_ring_faces :: proc "contextless" () -> []Required_Ring_Face {
	return powerbox_required_ring_faces[:]
}

// powerbox_contract_hash computes the deterministic BLAKE3 hash of the Powerbox
// role contract.
powerbox_contract_hash :: proc "contextless" () -> Contract_Hash {
	digest, _ := contract_hash(powerbox_contract())
	return digest
}
