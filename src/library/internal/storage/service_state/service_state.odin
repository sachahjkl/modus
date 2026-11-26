// Decoupled readiness state of the storage service: image-tree serving is
// independent of the data disk lifecycle (src/md/features/objects_by_hash.md).
//
// Image-tree reads stay available in every Disk_State as long as
// image_tree_ready is true. Disk-store calls require disk_state == .Opened.
package service_state

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"

// Closed set of data-disk lifecycle states inside the storage service.
Disk_State :: enum u8 {
	Absent   = 0, // No data disk or block service granted to storage.
	Opening  = 1, // Block ring attached; mount in progress.
	Opened   = 2, // Disk mounted; disk-store reads and writes available.
	Silent   = 3, // Disk or block service stopped answering; no further disk I/O.
	Unusable = 4, // Disk present but mount failed (older format, damaged root, or budget refusal).
}

// disk_state_of_word converts a transport word into a Disk_State member,
// refusing any word that names no member.
disk_state_of_word :: proc "contextless" (word: u64) -> (state: Disk_State, ok: bool) {
	return enum_word.member_of_word(Disk_State, word)
}

// Closed set of events that advance Disk_State.
Disk_Event :: enum u8 {
	No_Block_Ring  = 0, // Context holds no usable block ring or block service handle.
	Begin_Open     = 1, // Block ring opened and data region attached; starting mount.
	Open_Succeeded = 2, // Mount finished cleanly (existing or newly formatted disk).
	Open_Unusable  = 3, // Mount failed permanently (older format, corrupt root, or no table memory).
	Went_Silent    = 4, // Block service stopped or failed to answer within the deadline.
}

// Combined readiness of the storage service. Zero value is safe: neither image
// tree nor disk is ready yet.
Service_Readiness :: struct {
	image_tree_ready: bool,
	disk_state:       Disk_State,
}

// disk_state_transition computes the next Disk_State for event. Invalid or
// terminal transitions leave current unchanged and return changed = false.
disk_state_transition :: proc "contextless" (current: Disk_State, event: Disk_Event) -> (next: Disk_State, changed: bool) {
	switch current {
	case .Absent:
		switch event {
		case .No_Block_Ring:
			return .Absent, false
		case .Begin_Open:
			return .Opening, true
		case .Went_Silent:
			return .Silent, true
		case .Open_Succeeded, .Open_Unusable:
			return .Absent, false
		}
	case .Opening:
		switch event {
		case .Open_Succeeded:
			return .Opened, true
		case .Open_Unusable:
			return .Unusable, true
		case .Went_Silent:
			return .Silent, true
		case .No_Block_Ring, .Begin_Open:
			return .Opening, false
		}
	case .Opened:
		switch event {
		case .Went_Silent:
			return .Silent, true
		case .No_Block_Ring, .Begin_Open, .Open_Succeeded, .Open_Unusable:
			return .Opened, false
		}
	case .Silent:
		// Silent is terminal until the service restarts: late completions must
		// never reactivate disk I/O.
		switch event {
		case .No_Block_Ring, .Begin_Open, .Open_Succeeded, .Open_Unusable, .Went_Silent:
			return .Silent, false
		}
	case .Unusable:
		// Unusable is terminal until the service restarts: storage never retries
		// mounting an older-format or corrupt disk automatically.
		switch event {
		case .No_Block_Ring, .Begin_Open, .Open_Succeeded, .Open_Unusable, .Went_Silent:
			return .Unusable, false
		}
	}
	return current, false
}

// image_tree_available reports whether read-only image-tree calls can be
// served. Availability depends solely on image_tree_ready, never on disk_state.
image_tree_available :: proc "contextless" (readiness: Service_Readiness) -> bool {
	return readiness.image_tree_ready
}

// disk_store_available reports whether disk-backed store calls can run.
disk_store_available :: proc "contextless" (readiness: Service_Readiness) -> bool {
	return readiness.disk_state == .Opened
}

// disk_call_refusal gives the refusal outcome and error kind when a disk-store
// call arrives in state. Returns refused = false only when state == .Opened.
disk_call_refusal :: proc "contextless" (state: Disk_State) -> (outcome: call_outcome.Call_Outcome, kind: errors.Kind, refused: bool) {
	switch state {
	case .Opened:
		return .Succeeded, .None, false
	case .Absent, .Opening, .Silent, .Unusable:
		return .Callee_Unavailable, .Device, true
	}
	return .Callee_Unavailable, .Device, true
}
