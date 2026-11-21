// Powerbox contract: grouped consent requests, trusted display dialogs,
// picker candidates, and trusted answers from the Display role holder
// (src/md/features/powerbox.md).
//
// Every request carries typed records only, with no free-text prose from the
// asking process. Every transport word crosses a single border parser that
// refuses zero and unknown values. This is a contract package: it imports base
// and contract packages only, calls no kernel operation, and allocates no
// memory.
package powerbox

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/text_encoding"

// Maximum items in a single grouped consent request batch or dialog. Sixteen
// rows fit the reference screen without scrolling so the principal sees every
// item before acting.
MAX_REQUEST_ITEMS :: 16

// Maximum store candidates passed to the trusted display for a Store_Share
// picker. Candidate names are never returned to the asking process.
MAX_PICKER_CANDIDATES :: 32

// Maximum byte length of a service name, store name, or asker label.
MAX_NAME_BYTES :: 64

// Maximum byte length of a DNS hostname or textual IPv4 host literal.
MAX_HOST_BYTES :: 253

// Maximum byte length of a single DNS label between dots.
MAX_HOST_LABEL_BYTES :: 63

// Maximum request records drained per pass from one service ring.
REQUESTS_PER_PASS :: 4

// Context handle slots and value slots for the delegated powerbox service.
SERVICE_RING_SLOT :: 10
TRUSTED_DISPLAY_RING_SLOT :: 11
SERVICE_REGION_SLOT :: 12
CONTEXT_VALUE_DISPLAY_SLOT :: 0

// Domain separator prefix written into every canonical dialog digest so a
// dialog hash cannot collide with module hashes or other signed records.
DIALOG_HASH_DOMAIN_TAG :: "MODUS_POWERBOX_DIALOG_V1"

// Stack buffer capacity for canonical dialog encoding before BLAKE3 hashing.
DIALOG_HASH_BUFFER_CAPACITY :: 16384

// Closed set of grant item kinds that a process can ask the powerbox for.
// Zero means unset and is refused at the border.
Request_Item_Kind :: enum u64 {
	None               = 0,
	Network_Endpoint   = 1,
	Store_Share        = 2,
	Service_Connection = 3,
	Plan_Difference    = 4,
}

// Closed set of grant durations. Zero means unset; ordinary items require a
// non-zero duration, whereas Plan_Difference requires None because plans apply
// whole with no duration choice.
Grant_Duration :: enum u64 {
	None     = 0,
	Once     = 1,
	This_Run = 2,
	Always   = 3,
}

// Closed set of per-item outcomes returned to the asking process or carried in
// a Display answer.
Item_Decision :: enum u64 {
	None    = 0,
	Granted = 1,
	Held    = 2,
	Refused = 3,
	Expired = 4,
	Invalid = 5,
}

// Closed set of access modes for a Store_Share item.
Store_Access_Mode :: enum u64 {
	None       = 0,
	Read_Only  = 1,
	Read_Write = 2,
}

// Closed set of actions sent from the powerbox to the trusted Display holder.
Dialog_Action :: enum u64 {
	None                 = 0,
	Show_Grant_Dialog    = 1,
	Show_Plan_Difference = 2,
	Dismiss_Dialog       = 3,
}

// Closed set of refusal reasons returned by border validators and the powerbox
// policy state machine.
Powerbox_Refusal :: enum u64 {
	None                             = 0,
	No_Window                        = 1,
	Empty_Batch                      = 2,
	Too_Many_Items                   = 3,
	Duplicate_Item                   = 4,
	Invalid_Kind                     = 5,
	Invalid_Duration                 = 6,
	Invalid_Host                     = 7,
	Always_Forbidden_For_Boot_Module = 8,
	Dialog_Queue_Full                = 9,
	Rate_Limited                     = 10,
	Untrusted_Answer                 = 11,
	Picker_Selection_Invalid         = 12,
}

// Closed set of network transports for Network_Endpoint items.
Network_Transport :: enum u64 {
	None = 0,
	Udp  = 1,
	Tcp  = 2,
}

// Rights bits requested on a Network_Endpoint item.
Network_Endpoint_Right :: enum u64 {
	Connect = 0,
	Listen  = 1,
}

Network_Endpoint_Rights :: bit_set[Network_Endpoint_Right;u64]

NETWORK_RIGHTS_KNOWN_MASK :: (u64(1) << u64(Network_Endpoint_Right.Connect)) | (u64(1) << u64(Network_Endpoint_Right.Listen))

// Closed set of optional structured reasons claimed by the asking process.
// Zero means no reason. Free-text prose is never carried across the border.
Grant_Reason :: enum u64 {
	None  = 0,
	Open  = 1,
	Save  = 2,
	Fetch = 3,
	Send  = 4,
	Serve = 5,
	Use   = 6,
}

// Where the deliberate input that produced a Display answer originated. Only
// Local_Machine input can answer a trusted dialog.
Input_Origin :: enum u64 {
	None           = 0,
	Local_Machine  = 1,
	Remote_Display = 2,
}

// Whether the asking process came from the signed boot image or from the disk.
// Boot_Image modules are never eligible for Always grants.
Module_Origin :: enum u64 {
	None        = 0,
	Boot_Image  = 1,
	Disk_Module = 2,
}

// Commands carried on the powerbox service ring.
Service_Ring_Command :: enum u32 {
	None            = 0,
	Submit_Batch    = 1,
	Display_Shown   = 2,
	Display_Answer  = 3,
	Withdraw_Dialog = 4,
	Query_Counts    = 5,
}

// Completion statuses returned on the powerbox service ring.
Service_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
	Busy        = 3,
}

// Closed allowlist of services that a running process can request a caller-only
// connection to through the powerbox. Privileged machine services are excluded.
@(rodata)
REQUESTABLE_SERVICES := [?]string {
	"settings",
	"date",
	"manual",
	"sound",
	"speech",
}

// Reserved system service ports that no powerbox Network_Endpoint item may name.
@(rodata)
RESERVED_SYSTEM_PORTS := [?]u16 {
	remote.LISTEN_PORT,
	remote_display.LISTEN_PORT,
}

// One requested capability item in a grouped consent batch. There is no
// free-text reason field; reasons use Grant_Reason only.
Request_Item :: struct {
	kind_word:           u64,
	duration_word:       u64,
	reason_word:         u64,
	// Network_Endpoint fields:
	ipv4_address:        u32,
	port:                u16,
	transport_word:      u64,
	network_rights_word: u64,
	host_bytes:          [MAX_HOST_BYTES]u8,
	host_length:         u16,
	// Store_Share fields (the asking process never names a store or sees candidates):
	store_access_word:   u64,
	// Service_Connection fields:
	service_name_bytes:  [MAX_NAME_BYTES]u8,
	service_name_length: u8,
	// Plan_Difference fields:
	plan_hash:           blake3.Hash,
	// Optional serial of an already-held grant when requesting wider rights:
	former_grant_serial: u64,
}

// Grouped consent request batch submitted by an asking process. One batch opens
// at most one grouped screen for all items.
Request_Batch :: struct {
	request_serial:      u64,
	asker_process_slot:  u32,
	asker_principal:     u64,
	asker_has_window:    bool,
	asker_module_origin: u64,
	asker_module_hash:   blake3.Hash,
	asker_label_bytes:   [MAX_NAME_BYTES]u8,
	asker_label_length:  u8,
	item_count:          u32,
	items:               [MAX_REQUEST_ITEMS]Request_Item,
}

// One store candidate shown by the trusted Display picker. Never returned to
// the asking process.
Picker_Candidate :: struct {
	name_bytes:  [MAX_NAME_BYTES]u8,
	name_length: u8,
	name_hash:   blake3.Hash,
	store_id:    u64,
}

// Dialog payload sent from the powerbox to the trusted Display role holder.
Dialog_Record :: struct {
	action_word:            u64,
	dialog_serial:          u64,
	request_serial:         u64,
	session_principal:      u64,
	asker_process_slot:     u32,
	asker_module_origin:    u64,
	asker_module_hash:      blake3.Hash,
	asker_label_bytes:      [MAX_NAME_BYTES]u8,
	asker_label_length:     u8,
	allow_per_item_ticks:   bool,
	allow_duration_choice:  bool,
	allow_always_duration:  bool,
	item_count:             u32,
	items:                  [MAX_REQUEST_ITEMS]Request_Item,
	picker_change_count:    u64,
	picker_candidate_count: u32,
	picker_candidates:      [MAX_PICKER_CANDIDATES]Picker_Candidate,
	record_hash:            blake3.Hash,
}

// Per-item decision carried inside a trusted Grant_Answer from the Display holder.
Item_Answer :: struct {
	decision_word:       u64,
	duration_word:       u64,
	picker_selected:     bool,
	picker_index:        u32,
	picker_change_count: u64,
	picker_name_hash:    blake3.Hash,
}

// Trusted answer returned by the Display role holder after the principal acts.
Grant_Answer :: struct {
	dialog_serial:            u64,
	request_serial:           u64,
	dialog_record_hash:       blake3.Hash,
	display_holder_slot:      u32,
	input_origin_word:        u64,
	shown_timestamp_ms:       u64,
	input_press_timestamp_ms: u64,
	answer_timestamp_ms:      u64,
	never_ask_again:          bool,
	whole_plan_accepted:      bool,
	item_count:               u32,
	items:                    [MAX_REQUEST_ITEMS]Item_Answer,
}

// Border parsers: each converts a raw transport word into its closed enum,
// refusing unknown words and zero where zero means unset.

request_item_kind_from_word :: proc "contextless" (word: u64) -> (kind: Request_Item_Kind, ok: bool) {
	member := enum_word.member_of_word(Request_Item_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

grant_duration_from_word :: proc "contextless" (word: u64) -> (duration: Grant_Duration, ok: bool) {
	member := enum_word.member_of_word(Grant_Duration, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

item_decision_from_word :: proc "contextless" (word: u64) -> (decision: Item_Decision, ok: bool) {
	member := enum_word.member_of_word(Item_Decision, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

store_access_mode_from_word :: proc "contextless" (word: u64) -> (mode: Store_Access_Mode, ok: bool) {
	member := enum_word.member_of_word(Store_Access_Mode, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

dialog_action_from_word :: proc "contextless" (word: u64) -> (action: Dialog_Action, ok: bool) {
	member := enum_word.member_of_word(Dialog_Action, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

powerbox_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Powerbox_Refusal, ok: bool) {
	return enum_word.member_of_word(Powerbox_Refusal, word)
}

network_transport_from_word :: proc "contextless" (word: u64) -> (transport: Network_Transport, ok: bool) {
	member := enum_word.member_of_word(Network_Transport, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

grant_reason_from_word :: proc "contextless" (word: u64) -> (reason: Grant_Reason, ok: bool) {
	return enum_word.member_of_word(Grant_Reason, word)
}

input_origin_from_word :: proc "contextless" (word: u64) -> (origin: Input_Origin, ok: bool) {
	member := enum_word.member_of_word(Input_Origin, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

module_origin_from_word :: proc "contextless" (word: u64) -> (origin: Module_Origin, ok: bool) {
	member := enum_word.member_of_word(Module_Origin, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

service_ring_command_from_word :: proc "contextless" (word: u32) -> (command: Service_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Service_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

network_endpoint_rights_from_word :: proc "contextless" (word: u64) -> (rights: Network_Endpoint_Rights, ok: bool) {
	if word == 0 || word & ~NETWORK_RIGHTS_KNOWN_MASK != 0 {
		return {}, false
	}
	result: Network_Endpoint_Rights
	if word & (u64(1) << u64(Network_Endpoint_Right.Connect)) != 0 {
		result += {.Connect}
	}
	if word & (u64(1) << u64(Network_Endpoint_Right.Listen)) != 0 {
		result += {.Listen}
	}
	return result, true
}

// grant_reason_allowed_for_kind reports whether the given structured reason is
// valid for the item kind. None is always allowed.
grant_reason_allowed_for_kind :: proc "contextless" (kind: Request_Item_Kind, reason: Grant_Reason) -> bool {
	if reason == .None {
		return true
	}
	switch kind {
	case .None:
		return false
	case .Network_Endpoint:
		switch reason {
		case .Fetch, .Send, .Serve:
			return true
		case .None, .Open, .Save, .Use:
			return false
		}
	case .Store_Share:
		switch reason {
		case .Open, .Save:
			return true
		case .None, .Fetch, .Send, .Serve, .Use:
			return false
		}
	case .Service_Connection:
		switch reason {
		case .Use:
			return true
		case .None, .Open, .Save, .Fetch, .Send, .Serve:
			return false
		}
	case .Plan_Difference:
		return false
	}
	return false
}

// network_port_valid refuses port 0 and reserved ports of system services.
network_port_valid :: proc "contextless" (port: u16) -> bool {
	if port == 0 {
		return false
	}
	for reserved in RESERVED_SYSTEM_PORTS {
		if port == reserved {
			return false
		}
	}
	return true
}

// ipv4_address_valid checks an IPv4 address for a Network_Endpoint item.
// Connect requires a non-zero, non-broadcast, non-loopback, non-link-local
// address. Pure Listen may leave ipv4_address as 0 to accept on the local port.
ipv4_address_valid :: proc "contextless" (address: u32, rights: Network_Endpoint_Rights) -> bool {
	if address == 0 {
		return .Listen in rights && .Connect not_in rights
	}
	if address == 0xFFFF_FFFF {
		return false
	}
	first_octet := address >> 24
	if first_octet == 0 || first_octet == 127 {
		return false
	}
	if (address >> 16) == 0xA9FE {
		return false
	}
	return true
}

// host_name_valid validates a DNS hostname or textual IPv4 literal: non-empty,
// valid UTF-8, bounded length, ASCII hostname labels separated by single dots,
// with no leading or trailing hyphen or dot.
host_name_valid :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) == 0 || len(bytes) > MAX_HOST_BYTES {
		return false
	}
	if !text_encoding.text_valid(bytes) {
		return false
	}
	label_length := 0
	last_byte: u8 = 0
	for value in bytes {
		if value == '.' {
			if label_length == 0 || last_byte == '-' {
				return false
			}
			label_length = 0
			last_byte = value
			continue
		}
		is_letter := (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
		is_digit := value >= '0' && value <= '9'
		is_hyphen := value == '-'
		if !is_letter && !is_digit && !is_hyphen {
			return false
		}
		if label_length == 0 && is_hyphen {
			return false
		}
		label_length += 1
		if label_length > MAX_HOST_LABEL_BYTES {
			return false
		}
		last_byte = value
	}
	if label_length == 0 || last_byte == '-' {
		return false
	}
	return true
}

// service_name_is_requestable reports whether bytes name a service in the
// closed allowlist of services that a process can ask to connect to.
service_name_is_requestable :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) == 0 || len(bytes) > MAX_NAME_BYTES {
		return false
	}
	if !text_encoding.identifier_valid(bytes) {
		return false
	}
	candidate := string(bytes)
	for allowed in REQUESTABLE_SERVICES {
		if candidate == allowed {
			return true
		}
	}
	return false
}

// picker_candidate_make builds a validated Picker_Candidate with its BLAKE3
// name hash for trusted pick verification.
picker_candidate_make :: proc "contextless" (name: string, store_id: u64) -> (candidate: Picker_Candidate, ok: bool) {
	raw := transmute([]u8)name
	if store_id == 0 || len(raw) == 0 || len(raw) > MAX_NAME_BYTES {
		return {}, false
	}
	if !text_encoding.display_text_valid(raw) {
		return {}, false
	}
	copy(candidate.name_bytes[:len(raw)], raw)
	candidate.name_length = u8(len(raw))
	candidate.name_hash = blake3.hash(candidate.name_bytes[:len(raw)])
	candidate.store_id = store_id
	return candidate, true
}

@(private = "file")
ascii_lower :: proc "contextless" (value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

@(private = "file")
ascii_bytes_equal_case_insensitive :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if ascii_lower(first[index]) != ascii_lower(second[index]) {
			return false
		}
	}
	return true
}

@(private = "file")
bytes_equal :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// request_item_same_target reports whether two validated Request_Item records
// refer to the same target object, used for duplicate detection within a batch
// and for already-held grant matching.
request_item_same_target :: proc "contextless" (first, second: ^Request_Item) -> bool {
	first_kind, first_ok := request_item_kind_from_word(first.kind_word)
	second_kind, second_ok := request_item_kind_from_word(second.kind_word)
	if !first_ok || !second_ok || first_kind != second_kind {
		return false
	}
	switch first_kind {
	case .None:
		return false
	case .Network_Endpoint:
		if first.port != second.port || first.transport_word != second.transport_word {
			return false
		}
		if first.host_length != 0 || second.host_length != 0 {
			if first.host_length != second.host_length {
				return false
			}
			if int(first.host_length) > MAX_HOST_BYTES {
				return false
			}
			return ascii_bytes_equal_case_insensitive(first.host_bytes[:first.host_length], second.host_bytes[:second.host_length])
		}
		return first.ipv4_address == second.ipv4_address
	case .Store_Share:
		return first.store_access_word == second.store_access_word &&
			first.reason_word == second.reason_word &&
			first.former_grant_serial == second.former_grant_serial
	case .Service_Connection:
		if first.service_name_length != second.service_name_length || int(first.service_name_length) > MAX_NAME_BYTES {
			return false
		}
		return bytes_equal(first.service_name_bytes[:first.service_name_length], second.service_name_bytes[:second.service_name_length])
	case .Plan_Difference:
		return true
	}
	return false
}

@(private = "file")
validate_single_request_item :: proc "contextless" (item: ^Request_Item, module_origin: Module_Origin) -> Powerbox_Refusal {
	kind, kind_ok := request_item_kind_from_word(item.kind_word)
	if !kind_ok {
		return .Invalid_Kind
	}
	reason, reason_ok := grant_reason_from_word(item.reason_word)
	if !reason_ok || !grant_reason_allowed_for_kind(kind, reason) {
		return .Invalid_Kind
	}

	switch kind {
	case .None:
		return .Invalid_Kind
	case .Network_Endpoint:
		duration, duration_ok := grant_duration_from_word(item.duration_word)
		if !duration_ok {
			return .Invalid_Duration
		}
		if module_origin == .Boot_Image && duration == .Always {
			return .Always_Forbidden_For_Boot_Module
		}
		if _, transport_ok := network_transport_from_word(item.transport_word); !transport_ok {
			return .Invalid_Kind
		}
		rights, rights_ok := network_endpoint_rights_from_word(item.network_rights_word)
		if !rights_ok {
			return .Invalid_Kind
		}
		if !network_port_valid(item.port) {
			return .Invalid_Host
		}
		if int(item.host_length) > MAX_HOST_BYTES {
			return .Invalid_Host
		}
		if item.host_length > 0 {
			if !host_name_valid(item.host_bytes[:item.host_length]) {
				return .Invalid_Host
			}
		} else {
			if !ipv4_address_valid(item.ipv4_address, rights) {
				return .Invalid_Host
			}
		}
		return .None
	case .Store_Share:
		duration, duration_ok := grant_duration_from_word(item.duration_word)
		if !duration_ok {
			return .Invalid_Duration
		}
		if module_origin == .Boot_Image && duration == .Always {
			return .Always_Forbidden_For_Boot_Module
		}
		if _, mode_ok := store_access_mode_from_word(item.store_access_word); !mode_ok {
			return .Invalid_Kind
		}
		return .None
	case .Service_Connection:
		duration, duration_ok := grant_duration_from_word(item.duration_word)
		if !duration_ok {
			return .Invalid_Duration
		}
		if module_origin == .Boot_Image && duration == .Always {
			return .Always_Forbidden_For_Boot_Module
		}
		if int(item.service_name_length) > MAX_NAME_BYTES {
			return .Invalid_Host
		}
		if !service_name_is_requestable(item.service_name_bytes[:item.service_name_length]) {
			return .Invalid_Host
		}
		return .None
	case .Plan_Difference:
		if item.duration_word != u64(Grant_Duration.None) {
			return .Invalid_Duration
		}
		if item.plan_hash == (blake3.Hash{}) {
			return .Invalid_Host
		}
		return .None
	}
	return .Invalid_Kind
}

// request_batch_validate strictly validates a Request_Batch at the border.
// Refuses missing window, empty batch, >MAX_REQUEST_ITEMS items, invalid enum
// words, invalid hosts/ports/UTF-8, duplicate items, mixed Plan_Difference
// batches, and Always grants for boot-image modules.
request_batch_validate :: proc "contextless" (batch: ^Request_Batch) -> (refusal: Powerbox_Refusal, item_index: u32) {
	if !batch.asker_has_window {
		return .No_Window, 0
	}
	if batch.request_serial == 0 || batch.asker_process_slot == 0 {
		return .Invalid_Kind, 0
	}
	origin, origin_ok := module_origin_from_word(batch.asker_module_origin)
	if !origin_ok {
		return .Invalid_Kind, 0
	}
	if batch.asker_module_hash == (blake3.Hash{}) {
		return .Invalid_Kind, 0
	}
	if int(batch.asker_label_length) == 0 || int(batch.asker_label_length) > MAX_NAME_BYTES {
		return .Invalid_Host, 0
	}
	if !text_encoding.display_text_valid(batch.asker_label_bytes[:batch.asker_label_length]) {
		return .Invalid_Host, 0
	}
	if batch.item_count == 0 {
		return .Empty_Batch, 0
	}
	if batch.item_count > MAX_REQUEST_ITEMS {
		return .Too_Many_Items, 0
	}

	has_plan_difference := false
	has_ordinary_item := false
	for index in u32(0) ..< batch.item_count {
		item := &batch.items[index]
		item_refusal := validate_single_request_item(item, origin)
		if item_refusal != .None {
			return item_refusal, index
		}
		kind, _ := request_item_kind_from_word(item.kind_word)
		if kind == .Plan_Difference {
			has_plan_difference = true
		} else {
			has_ordinary_item = true
		}
		if has_plan_difference && has_ordinary_item {
			return .Invalid_Kind, index
		}
		for earlier in u32(0) ..< index {
			if request_item_same_target(&batch.items[earlier], item) {
				return .Duplicate_Item, index
			}
		}
	}
	return .None, 0
}

@(private = "file")
Hash_Writer :: struct {
	buffer:   []u8,
	position: int,
	overflow: bool,
}

@(private = "file")
hash_write_byte :: proc "contextless" (writer: ^Hash_Writer, value: u8) {
	if writer.overflow || writer.position >= len(writer.buffer) {
		writer.overflow = true
		return
	}
	writer.buffer[writer.position] = value
	writer.position += 1
}

@(private = "file")
hash_write_u16 :: proc "contextless" (writer: ^Hash_Writer, value: u16) {
	if writer.overflow || len(writer.buffer) - writer.position < 2 {
		writer.overflow = true
		return
	}
	byte_order.write_u16_little_endian(writer.buffer, writer.position, value)
	writer.position += 2
}

@(private = "file")
hash_write_u32 :: proc "contextless" (writer: ^Hash_Writer, value: u32) {
	if writer.overflow || len(writer.buffer) - writer.position < 4 {
		writer.overflow = true
		return
	}
	byte_order.write_u32_little_endian(writer.buffer, writer.position, value)
	writer.position += 4
}

@(private = "file")
hash_write_u64 :: proc "contextless" (writer: ^Hash_Writer, value: u64) {
	if writer.overflow || len(writer.buffer) - writer.position < 8 {
		writer.overflow = true
		return
	}
	byte_order.write_u64_little_endian(writer.buffer, writer.position, value)
	writer.position += 8
}

@(private = "file")
hash_write_slice :: proc "contextless" (writer: ^Hash_Writer, data: []u8) {
	hash_write_u32(writer, u32(len(data)))
	if writer.overflow || len(writer.buffer) - writer.position < len(data) {
		writer.overflow = true
		return
	}
	for index in 0 ..< len(data) {
		writer.buffer[writer.position + index] = data[index]
	}
	writer.position += len(data)
}

// dialog_record_hash computes the deterministic BLAKE3 digest of the canonical
// payload of a Dialog_Record (excluding record_hash itself).
dialog_record_hash :: proc "contextless" (dialog: ^Dialog_Record) -> (digest: blake3.Hash, refusal: Powerbox_Refusal) {
	if dialog.item_count > MAX_REQUEST_ITEMS {
		return {}, .Too_Many_Items
	}
	if dialog.picker_candidate_count > MAX_PICKER_CANDIDATES {
		return {}, .Picker_Selection_Invalid
	}
	if int(dialog.asker_label_length) > MAX_NAME_BYTES {
		return {}, .Invalid_Host
	}

	buffer: [DIALOG_HASH_BUFFER_CAPACITY]u8
	writer := Hash_Writer{buffer = buffer[:]}
	tag := DIALOG_HASH_DOMAIN_TAG
	hash_write_slice(&writer, transmute([]u8)tag)
	hash_write_u64(&writer, dialog.action_word)
	hash_write_u64(&writer, dialog.dialog_serial)
	hash_write_u64(&writer, dialog.request_serial)
	hash_write_u64(&writer, dialog.session_principal)
	hash_write_u32(&writer, dialog.asker_process_slot)
	hash_write_u64(&writer, dialog.asker_module_origin)
	hash_write_slice(&writer, dialog.asker_module_hash[:])
	hash_write_slice(&writer, dialog.asker_label_bytes[:dialog.asker_label_length])
	hash_write_byte(&writer, dialog.allow_per_item_ticks ? 1 : 0)
	hash_write_byte(&writer, dialog.allow_duration_choice ? 1 : 0)
	hash_write_byte(&writer, dialog.allow_always_duration ? 1 : 0)
	hash_write_u32(&writer, dialog.item_count)

	for index in u32(0) ..< dialog.item_count {
		item := &dialog.items[index]
		if int(item.host_length) > MAX_HOST_BYTES || int(item.service_name_length) > MAX_NAME_BYTES {
			return {}, .Invalid_Host
		}
		hash_write_u64(&writer, item.kind_word)
		hash_write_u64(&writer, item.duration_word)
		hash_write_u64(&writer, item.reason_word)
		hash_write_u32(&writer, item.ipv4_address)
		hash_write_u16(&writer, item.port)
		hash_write_u64(&writer, item.transport_word)
		hash_write_u64(&writer, item.network_rights_word)
		hash_write_slice(&writer, item.host_bytes[:item.host_length])
		hash_write_u64(&writer, item.store_access_word)
		hash_write_slice(&writer, item.service_name_bytes[:item.service_name_length])
		hash_write_slice(&writer, item.plan_hash[:])
		hash_write_u64(&writer, item.former_grant_serial)
	}

	hash_write_u64(&writer, dialog.picker_change_count)
	hash_write_u32(&writer, dialog.picker_candidate_count)
	for index in u32(0) ..< dialog.picker_candidate_count {
		candidate := &dialog.picker_candidates[index]
		if int(candidate.name_length) > MAX_NAME_BYTES {
			return {}, .Picker_Selection_Invalid
		}
		hash_write_slice(&writer, candidate.name_bytes[:candidate.name_length])
		hash_write_slice(&writer, candidate.name_hash[:])
		hash_write_u64(&writer, candidate.store_id)
	}

	if writer.overflow {
		return {}, .Too_Many_Items
	}
	return blake3.hash(buffer[:writer.position]), .None
}

// dialog_record_seal validates the structural fields of a Dialog_Record and
// populates its canonical record_hash.
dialog_record_seal :: proc "contextless" (dialog: ^Dialog_Record) -> Powerbox_Refusal {
	digest, hash_refusal := dialog_record_hash(dialog)
	if hash_refusal != .None {
		return hash_refusal
	}
	dialog.record_hash = digest
	refusal, _ := dialog_record_validate(dialog)
	return refusal
}

// dialog_record_validate checks a Dialog_Record at the trusted display border.
dialog_record_validate :: proc "contextless" (dialog: ^Dialog_Record) -> (refusal: Powerbox_Refusal, item_index: u32) {
	action, action_ok := dialog_action_from_word(dialog.action_word)
	if !action_ok {
		return .Invalid_Kind, 0
	}
	if dialog.dialog_serial == 0 {
		return .Invalid_Kind, 0
	}

	switch action {
	case .None:
		return .Invalid_Kind, 0
	case .Dismiss_Dialog:
		if dialog.item_count != 0 || dialog.picker_candidate_count != 0 {
			return .Invalid_Kind, 0
		}
		expected_hash, hash_refusal := dialog_record_hash(dialog)
		if hash_refusal != .None {
			return hash_refusal, 0
		}
		if dialog.record_hash != expected_hash {
			return .Untrusted_Answer, 0
		}
		return .None, 0
	case .Show_Grant_Dialog, .Show_Plan_Difference:
		if dialog.request_serial == 0 || dialog.asker_process_slot == 0 {
			return .Invalid_Kind, 0
		}
		origin, origin_ok := module_origin_from_word(dialog.asker_module_origin)
		if !origin_ok {
			return .Invalid_Kind, 0
		}
		if dialog.asker_module_hash == (blake3.Hash{}) {
			return .Invalid_Kind, 0
		}
		if int(dialog.asker_label_length) == 0 || int(dialog.asker_label_length) > MAX_NAME_BYTES {
			return .Invalid_Host, 0
		}
		if !text_encoding.display_text_valid(dialog.asker_label_bytes[:dialog.asker_label_length]) {
			return .Invalid_Host, 0
		}
		if origin == .Boot_Image && dialog.allow_always_duration {
			return .Always_Forbidden_For_Boot_Module, 0
		}
		if dialog.item_count == 0 {
			return .Empty_Batch, 0
		}
		if dialog.item_count > MAX_REQUEST_ITEMS {
			return .Too_Many_Items, 0
		}
		if dialog.picker_candidate_count > MAX_PICKER_CANDIDATES {
			return .Picker_Selection_Invalid, 0
		}

		if action == .Show_Plan_Difference {
			// A plan difference applies whole or refuses whole: no per-item
			// ticks, no duration choice, and no picker candidates.
			if dialog.allow_per_item_ticks || dialog.allow_duration_choice || dialog.allow_always_duration {
				return .Invalid_Duration, 0
			}
			if dialog.picker_candidate_count != 0 {
				return .Picker_Selection_Invalid, 0
			}
		}

		for index in u32(0) ..< dialog.item_count {
			item := &dialog.items[index]
			item_refusal := validate_single_request_item(item, origin)
			if item_refusal != .None {
				return item_refusal, index
			}
			kind, _ := request_item_kind_from_word(item.kind_word)
			if action == .Show_Plan_Difference && kind != .Plan_Difference {
				return .Invalid_Kind, index
			}
			if action == .Show_Grant_Dialog && kind == .Plan_Difference {
				return .Invalid_Kind, index
			}
			for earlier in u32(0) ..< index {
				if request_item_same_target(&dialog.items[earlier], item) {
					return .Duplicate_Item, index
				}
			}
		}

		for cand_index in u32(0) ..< dialog.picker_candidate_count {
			cand := &dialog.picker_candidates[cand_index]
			if cand.store_id == 0 || int(cand.name_length) == 0 || int(cand.name_length) > MAX_NAME_BYTES {
				return .Picker_Selection_Invalid, cand_index
			}
			if !text_encoding.display_text_valid(cand.name_bytes[:cand.name_length]) {
				return .Picker_Selection_Invalid, cand_index
			}
			expected_name_hash := blake3.hash(cand.name_bytes[:cand.name_length])
			if cand.name_hash != expected_name_hash {
				return .Picker_Selection_Invalid, cand_index
			}
		}

		expected_hash, hash_refusal := dialog_record_hash(dialog)
		if hash_refusal != .None {
			return hash_refusal, 0
		}
		if dialog.record_hash != expected_hash {
			return .Untrusted_Answer, 0
		}
		return .None, 0
	}
	return .Invalid_Kind, 0
}

// answer_record_validate strictly checks a Grant_Answer from the Display role
// holder against the Dialog_Record that was shown. Refuses non-Display callers,
// remote-display input, serial or hash mismatches, partial ticks on a plan
// difference, Always for boot modules, invalid enum words, and out-of-range or
// tampered picker selections.
answer_record_validate :: proc "contextless" (dialog: ^Dialog_Record, answer: ^Grant_Answer, trusted_display_slot: u32) -> (refusal: Powerbox_Refusal, item_index: u32) {
	dialog_refusal, bad_dialog_item := dialog_record_validate(dialog)
	if dialog_refusal != .None {
		return dialog_refusal, bad_dialog_item
	}
	action, _ := dialog_action_from_word(dialog.action_word)
	origin, _ := module_origin_from_word(dialog.asker_module_origin)

	if trusted_display_slot == 0 || answer.display_holder_slot != trusted_display_slot {
		return .Untrusted_Answer, 0
	}
	input_origin, input_ok := input_origin_from_word(answer.input_origin_word)
	if !input_ok || input_origin != .Local_Machine {
		return .Untrusted_Answer, 0
	}
	if answer.dialog_serial == 0 || answer.request_serial == 0 {
		return .Untrusted_Answer, 0
	}
	if answer.dialog_serial != dialog.dialog_serial || answer.request_serial != dialog.request_serial {
		return .Untrusted_Answer, 0
	}
	if answer.dialog_record_hash == (blake3.Hash{}) || answer.dialog_record_hash != dialog.record_hash {
		return .Untrusted_Answer, 0
	}
	if answer.item_count != dialog.item_count {
		return .Untrusted_Answer, 0
	}

	switch action {
	case .None, .Dismiss_Dialog:
		return .Untrusted_Answer, 0
	case .Show_Plan_Difference:
		for index in u32(0) ..< answer.item_count {
			item_ans := &answer.items[index]
			decision, dec_ok := item_decision_from_word(item_ans.decision_word)
			if !dec_ok {
				return .Untrusted_Answer, index
			}
			if item_ans.duration_word != u64(Grant_Duration.None) {
				return .Invalid_Duration, index
			}
			if item_ans.picker_selected {
				return .Picker_Selection_Invalid, index
			}
			if answer.whole_plan_accepted {
				if decision != .Granted {
					return .Untrusted_Answer, index
				}
			} else {
				if decision != .Refused && decision != .Expired {
					return .Untrusted_Answer, index
				}
			}
		}
		return .None, 0
	case .Show_Grant_Dialog:
		for index in u32(0) ..< answer.item_count {
			req_item := &dialog.items[index]
			item_ans := &answer.items[index]
			req_kind, _ := request_item_kind_from_word(req_item.kind_word)
			decision, dec_ok := item_decision_from_word(item_ans.decision_word)
			if !dec_ok {
				return .Untrusted_Answer, index
			}
			switch decision {
			case .None, .Held, .Invalid:
				// The Display holder cannot forge Held or Invalid outcomes.
				return .Untrusted_Answer, index
			case .Refused, .Expired:
				if item_ans.picker_selected {
					return .Picker_Selection_Invalid, index
				}
				if item_ans.duration_word != u64(Grant_Duration.None) {
					if _, dur_ok := grant_duration_from_word(item_ans.duration_word); !dur_ok {
						return .Invalid_Duration, index
					}
				}
			case .Granted:
				duration, dur_ok := grant_duration_from_word(item_ans.duration_word)
				if !dur_ok {
					return .Invalid_Duration, index
				}
				if (origin == .Boot_Image || !dialog.allow_always_duration) && duration == .Always {
					return .Always_Forbidden_For_Boot_Module, index
				}
				switch req_kind {
				case .None, .Plan_Difference:
					return .Invalid_Kind, index
				case .Store_Share:
					if !item_ans.picker_selected {
						return .Picker_Selection_Invalid, index
					}
					if dialog.picker_candidate_count == 0 || item_ans.picker_index >= dialog.picker_candidate_count {
						return .Picker_Selection_Invalid, index
					}
					if item_ans.picker_change_count != dialog.picker_change_count {
						return .Picker_Selection_Invalid, index
					}
					chosen := &dialog.picker_candidates[item_ans.picker_index]
					if item_ans.picker_name_hash != chosen.name_hash {
						return .Picker_Selection_Invalid, index
					}
				case .Network_Endpoint, .Service_Connection:
					if item_ans.picker_selected {
						return .Picker_Selection_Invalid, index
					}
				}
			}
		}
		return .None, 0
	}
	return .Untrusted_Answer, 0
}
