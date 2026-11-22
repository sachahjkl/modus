// Contract between the root service core and the delegated principals
// service: the input records that the core writes in the transfer region
// of the service, the transport words of their actions, and the places of
// that region (src/md/api/root_service_split.md, "State").
//
// The core cannot import the state machine of the service, so each record
// that crosses the region is defined here, once, for both sides.
package root_delegation

import "modus:contract/blake3"
import "modus:contract/enum_word"
import op "modus:contract/operation"

// The bytes of the name of a named principal: the name limit of the
// principals of the core.
PRINCIPAL_NAME_CAPACITY :: 23

#assert(PRINCIPAL_NAME_CAPACITY == NICKNAME_CAPACITY)

// The transfer region of the principals service holds one place for each
// command in flight, so two commands never share bytes. A place is one
// page: the largest record, a whole Disk_Rows_Set_Request, fits in it.
PRINCIPALS_TRANSFER_PLACE_COUNT :: 8
PRINCIPALS_TRANSFER_PLACE_BYTES :: op.PAGE_SIZE
PRINCIPALS_REGION_PAGES :: PRINCIPALS_TRANSFER_PLACE_COUNT * PRINCIPALS_TRANSFER_PLACE_BYTES / op.PAGE_SIZE

#assert(size_of(Disk_Rows_Set_Request) <= PRINCIPALS_TRANSFER_PLACE_BYTES)
#assert(size_of(Register_Principal_Input) <= PRINCIPALS_TRANSFER_PLACE_BYTES)
#assert(size_of(Session_Transition_Input) <= PRINCIPALS_TRANSFER_PLACE_BYTES)
#assert(size_of(Client_Key_Input) <= PRINCIPALS_TRANSFER_PLACE_BYTES)
#assert(size_of(Start_Policy_Input) <= PRINCIPALS_TRANSFER_PLACE_BYTES)

// Closed set of session lifecycle transitions.
// Zero means unset and is refused at the border.
Session_Action :: enum u32 {
	None           = 0,
	Unlock         = 1,
	Lock           = 2,
	Bring_To_Front = 3,
	Stop_Session   = 4,
}

// Closed set of client key operations for remote and remote_display.
Client_Key_Action :: enum u32 {
	None   = 0,
	Allow  = 1,
	Revoke = 2,
}

// Closed set of start policy choice operations for principal 0.
Start_Policy_Action :: enum u32 {
	None                    = 0,
	Set_Choice              = 1,
	Clear_Choice            = 2,
	Set_Passphrase_Required = 3,
}

// Input record for registering a named principal.
Register_Principal_Input :: struct {
	principal_id: u64,
	name:         [PRINCIPAL_NAME_CAPACITY]u8,
	name_length:  u8,
	public_key:   [32]u8,
}

// Input record for transitioning a principal session.
Session_Transition_Input :: struct {
	principal_id: u64,
	action_word:  u32,
}

// Input record for allowing or revoking a remote client key.
Client_Key_Input :: struct {
	principal_id:     u64,
	action_word:      u32,
	client_key:       [32]u8,
	client_uses_word: u64,
}

// Input record for managing principal 0's start policy choice.
Start_Policy_Input :: struct {
	principal_id:        u64,
	action_word:         u32,
	nickname:            [NICKNAME_CAPACITY]u8,
	nickname_length:     u8,
	module_hash:         blake3.Hash,
	passphrase_required: bool,
}

// session_action_from_word converts a transport word into a Session_Action,
// refusing zero and every unknown value.
session_action_from_word :: proc "contextless" (word: u32) -> (action: Session_Action, ok: bool) {
	member := enum_word.member_of_word(Session_Action, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// client_key_action_from_word converts a transport word into a
// Client_Key_Action, refusing zero and every unknown value.
client_key_action_from_word :: proc "contextless" (word: u32) -> (action: Client_Key_Action, ok: bool) {
	member := enum_word.member_of_word(Client_Key_Action, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// start_policy_action_from_word converts a transport word into a
// Start_Policy_Action, refusing zero and every unknown value.
start_policy_action_from_word :: proc "contextless" (word: u32) -> (action: Start_Policy_Action, ok: bool) {
	member := enum_word.member_of_word(Start_Policy_Action, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// principals_transfer_place_offset gives the offset of one place of the
// transfer region, refusing a place past PRINCIPALS_TRANSFER_PLACE_COUNT.
principals_transfer_place_offset :: proc "contextless" (place: int) -> (offset: u64, ok: bool) {
	if place < 0 || place >= PRINCIPALS_TRANSFER_PLACE_COUNT {
		return 0, false
	}
	return u64(place) * PRINCIPALS_TRANSFER_PLACE_BYTES, true
}
