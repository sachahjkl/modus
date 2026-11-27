// Decoupled readiness state of the storage service: image-tree serving is
// independent of the data disk lifecycle (src/md/features/objects_by_hash.md).
//
// Image-tree reads stay available in every Disk_State as long as
// image_tree_ready is true. Disk-store calls require disk_state == .Opened.
package service_state

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:principals"

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

// caller_has_own_store reports whether a storage connection owns a non-empty
// named store with a non-zero block quota. A fonts-only or tree-only
// connection has an empty store name and zero limit.
caller_has_own_store :: proc "contextless" (store_name: string, store_limit: u64) -> bool {
	return store_name != "" && store_limit > 0
}

// caller_may_name_store decides whether a storage caller may open or list
// target_store_name. Shares, disconnected callers, and empty target names are
// always refused; own-store access requires a non-empty name and non-zero
// block limit; cross-store access requires acts_for_principal on the caller's
// own principal.
caller_may_name_store :: proc "contextless" (connected, is_share, acts_for_principal: bool, caller_principal: u64, own_store_name: string, own_store_limit: u64, target_store_name: string) -> bool {
	if !connected || is_share || target_store_name == "" {
		return false
	}
	if caller_has_own_store(own_store_name, own_store_limit) && target_store_name == own_store_name {
		return true
	}
	if !acts_for_principal {
		return false
	}
	return principals.store_name_principal(target_store_name) == caller_principal
}

// caller_may_read_usage reports whether a storage caller may query store or
// share usage counts.
caller_may_read_usage :: proc "contextless" (connected: bool, own_store_name: string, own_store_limit: u64) -> bool {
	return connected && caller_has_own_store(own_store_name, own_store_limit)
}

// caller_may_list_pins reports whether a storage caller may invoke list_pins.
caller_may_list_pins :: proc "contextless" (connected, is_share, acts_for_principal: bool, own_store_name: string, own_store_limit: u64) -> bool {
	return connected && !is_share && (acts_for_principal || caller_has_own_store(own_store_name, own_store_limit))
}

// Closed set of actions storage_public_object_publish can take on an incoming
// Publish_Public_Object handle.
Public_Object_Publish_Action :: enum u8 {
	Ignore         = 0, // Do not close incoming handle and do not mutate state.
	Close_Incoming = 1, // Close verified incoming handle; leave published state unchanged.
	Install        = 2, // Replace published object with incoming handle.
}

Public_Object_Publish_Decision :: struct {
	action:         Public_Object_Publish_Action,
	close_existing: bool,
	kind:           isolated.Public_Object_Kind,
}

// public_object_publish_decide validates an incoming Publish_Public_Object
// handle and decides whether to ignore it, close it safely, or install it.
// An unverified handle (!through) is never closed, and a handle aliasing the
// currently published handle is never self-closed.
public_object_publish_decide :: proc "contextless" (memory, existing_handle: u64, through: bool, handle_kind: op.Object_Kind, rights: op.Rights, kind_word: u64, size: u64, pages_ok: bool, pages: u64, page_size: u64) -> Public_Object_Publish_Decision {
	if memory == 0 || !through {
		return {action = .Ignore}
	}
	kind, kind_ok := isolated.public_object_kind_of_word(kind_word)
	fits := pages_ok && page_size > 0 && pages <= max(u64) / page_size && size <= pages * page_size
	rights_ok := handle_kind == .Memory && .Read in rights && .Give in rights && .Write not_in rights && .Execute not_in rights
	if !kind_ok || kind == .None || size == 0 || !rights_ok || !fits {
		if memory == existing_handle {
			return {action = .Ignore}
		}
		return {action = .Close_Incoming}
	}
	return {
		action         = .Install,
		close_existing = existing_handle != 0 && existing_handle != memory,
		kind           = kind,
	}
}
