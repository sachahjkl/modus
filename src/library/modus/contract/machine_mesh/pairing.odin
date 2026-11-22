// Pairing of two machines by a code of one use, the table of paired
// machines, and the holder of the newest machine list
// (src/md/features/several_machines.md, "A principal across machines").
//
// The machine that shows the code is the offerer and answers the CPace
// exchange; the machine where the principal types the code is the joiner and
// starts it. The channel identifier of CPace is the TLS exporter of the
// connection, and the associated data of each side is its machine identity
// key, so the confirmation tags prove the same code, the same connection and
// both identity keys at once.
package machine_mesh

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/remote"

// A pairing code holds 50 bits: ten characters of base32.
PAIRING_CODE_BITS :: 50
PAIRING_CODE_SECRET_SIZE :: 7
PAIRING_CODE_TEXT_SIZE :: 10
PAIRING_CODE_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
// A code ends 10 minutes after it was shown or typed.
PAIRING_CODE_LIFETIME_MS :: u64(600_000)
// The size of a TLS exporter value that binds the exchange to one connection.
PAIRING_CHANNEL_BINDING_SIZE :: 32
MAX_PAIRED_MACHINES :: 16
MAX_SPENT_PAIRING_CODES :: 16

MACHINE_IDENTITY_FINGERPRINT_DOMAIN :: "modus machine identity fingerprint v1"
PAIRING_CODE_SPENT_DOMAIN :: "modus pairing code spent v1"
PAIRING_TRANSCRIPT_DOMAIN :: "modus pairing transcript v1"
PAIRING_SESSION_IDENTIFIER :: "modus pairing v1"

#assert(PAIRING_CODE_TEXT_SIZE * 5 == PAIRING_CODE_BITS)
#assert(PAIRING_CODE_SECRET_SIZE * 8 >= PAIRING_CODE_BITS)

// The public machine identity key and the fingerprint that a window shows.
Machine_Identity :: struct {
	public_key:  [PUBLIC_KEY_SIZE]u8,
	fingerprint: blake3.Hash,
}

// The side of one machine in a pairing.
Pairing_Side :: enum u8 {
	Offerer = 1, // Shows the code; answers the exchange (CPace responder).
	Joiner  = 2, // Types the code; starts the exchange (CPace initiator).
}

Pairing_Phase :: enum u8 {
	Idle       = 0,
	Code_Ready = 1,
	Exchanging = 2,
	Confirming = 3,
	Paired     = 4,
	Failed     = 5,
}

Pairing_Status :: enum u8 {
	Ok                          = 1,
	Refused_Nil_Input           = 2,
	Refused_Bad_Side            = 3,
	Refused_Bad_Phase           = 4,
	Refused_Zero_Key            = 5,
	Refused_Same_Machine        = 6,
	Refused_Zero_Code           = 7,
	Refused_Bad_Code_Text       = 8,
	Refused_Code_Expired        = 9,
	Refused_Code_Spent          = 10,
	Refused_Spent_Ledger_Full   = 11,
	Refused_Bad_Channel_Binding = 12,
	Refused_Peer_Key_Mismatch   = 13,
	Refused_Exchange            = 14,
	Refused_Confirmation_Failed = 15,
	Refused_Bad_Uses            = 16,
	Refused_Already_Paired      = 17,
	Refused_Table_Full          = 18,
}

// Where the row of a paired machine comes from: a pairing of principal 0,
// or the newest machine list of the principal, which removes it again.
Paired_Machine_Source :: enum u8 {
	Pairing      = 1,
	Machine_List = 2,
}

Paired_Machine :: struct {
	identity_key:           [PUBLIC_KEY_SIZE]u8,
	uses:                   remote.Client_Uses,
	source:                 Paired_Machine_Source,
	paired_at_ms:           u64,
	// A hash of the CPace session key: both machines hold the same value, and
	// no one can derive the key from it.
	transcript_fingerprint: blake3.Hash,
}

Paired_Machine_Table :: struct {
	machines: [MAX_PAIRED_MACHINES]Paired_Machine,
	count:    int,
}

Spent_Pairing_Code :: struct {
	fingerprint: blake3.Hash,
	spent_at_ms: u64,
}

// The codes that a machine used: a code runs one exchange, whatever its
// outcome, so a relay that saw an exchange cannot start a second one with it.
Pairing_Code_Ledger :: struct {
	entries: [MAX_SPENT_PAIRING_CODES]Spent_Pairing_Code,
	count:   int,
}

Pairing_Session :: struct {
	side:              Pairing_Side,
	phase:             Pairing_Phase,
	own_identity:      [PUBLIC_KEY_SIZE]u8,
	peer_identity:     [PUBLIC_KEY_SIZE]u8,
	code_secret:       [PAIRING_CODE_SECRET_SIZE]u8,
	code_started_at_ms: u64,
	cpace:             Cpace_Session,
	cpace_status:      Cpace_Status, // The refusal of CPace, when the phase is Failed after Refused_Exchange.
}

// The holder of the newest machine list of one principal on this machine.
Machine_List_Holder :: struct {
	principal_root_public_key: Principal_Root_Public_Key,
	list:                      Signed_Machine_List,
	has_list:                  bool,
}

pairing_side_of_word :: proc "contextless" (word: u64) -> (side: Pairing_Side, ok: bool) {
	return enum_word.member_of_word(Pairing_Side, word)
}

paired_machine_source_of_word :: proc "contextless" (word: u64) -> (source: Paired_Machine_Source, ok: bool) {
	return enum_word.member_of_word(Paired_Machine_Source, word)
}

// machine_identity_from_public_key gives the identity of a public key and its
// fingerprint. A zero key is no identity.
machine_identity_from_public_key :: proc "contextless" (public_key: [PUBLIC_KEY_SIZE]u8) -> (identity: Machine_Identity, ok: bool) {
	if key_is_zero(public_key) {
		return {}, false
	}
	key := public_key
	identity.public_key = public_key
	identity.fingerprint = blake3.derive_key(MACHINE_IDENTITY_FINGERPRINT_DOMAIN, key[:])
	return identity, true
}

@(private = "file")
pairing_code_value :: proc "contextless" (secret: [PAIRING_CODE_SECRET_SIZE]u8) -> u64 {
	value: u64
	for index in 0 ..< PAIRING_CODE_SECRET_SIZE {
		value |= u64(secret[index]) << u64(8 * index)
	}
	return value
}

@(private = "file")
pairing_code_secret_of_value :: proc "contextless" (value: u64) -> (secret: [PAIRING_CODE_SECRET_SIZE]u8) {
	for index in 0 ..< PAIRING_CODE_SECRET_SIZE {
		secret[index] = u8(value >> u64(8 * index))
	}
	return secret
}

// pairing_code_secret_of_random keeps 50 bits of a random draw. A draw whose
// 50 bits are zero is refused: the caller draws again.
pairing_code_secret_of_random :: proc "contextless" (random_bytes: [8]u8) -> (secret: [PAIRING_CODE_SECRET_SIZE]u8, status: Pairing_Status) {
	bytes := random_bytes
	value := byte_order.read_u64_little_endian(bytes[:], 0) & ((u64(1) << PAIRING_CODE_BITS) - 1)
	clear_bytes_explicitly(bytes[:])
	if value == 0 {
		return {}, .Refused_Zero_Code
	}
	return pairing_code_secret_of_value(value), .Ok
}

// pairing_code_text writes the code as ten characters of the base32 alphabet
// of RFC 4648, the first character for the highest bits.
pairing_code_text :: proc "contextless" (secret: [PAIRING_CODE_SECRET_SIZE]u8) -> (text: [PAIRING_CODE_TEXT_SIZE]u8) {
	value := pairing_code_value(secret)
	alphabet := PAIRING_CODE_ALPHABET
	for index in 0 ..< PAIRING_CODE_TEXT_SIZE {
		shift := u64(PAIRING_CODE_BITS - 5 * (index + 1))
		text[index] = alphabet[(value >> shift) & 31]
	}
	return text
}

// pairing_code_of_text reads ten characters of base32. Lower case letters are
// taken as upper case, because a person types the code; each other byte, a
// text of another length, and a zero code are refused.
pairing_code_of_text :: proc "contextless" (text: []u8) -> (secret: [PAIRING_CODE_SECRET_SIZE]u8, status: Pairing_Status) {
	if len(text) != PAIRING_CODE_TEXT_SIZE {
		return {}, .Refused_Bad_Code_Text
	}
	value: u64
	for character in text {
		digit: u64
		switch character {
		case 'A' ..= 'Z':
			digit = u64(character - 'A')
		case 'a' ..= 'z':
			digit = u64(character - 'a')
		case '2' ..= '7':
			digit = u64(character - '2') + 26
		case:
			return {}, .Refused_Bad_Code_Text
		}
		value = (value << 5) | digit
	}
	if value == 0 {
		return {}, .Refused_Zero_Code
	}
	return pairing_code_secret_of_value(value), .Ok
}

// pairing_session_clear erases every secret of the session and makes it Idle.
pairing_session_clear :: proc "contextless" (session: ^Pairing_Session) {
	if session == nil {
		return
	}
	clear_bytes_explicitly(([^]u8)(session)[:size_of(Pairing_Session)])
}

// A refusal after the start spends the session: one wrong step ends the
// pairing, and the code is gone.
@(private = "file")
pairing_fail :: proc "contextless" (session: ^Pairing_Session, status: Pairing_Status) -> Pairing_Status {
	cpace_status := session.cpace_status
	side := session.side
	pairing_session_clear(session)
	session.side = side
	session.cpace_status = cpace_status
	session.phase = .Failed
	return status
}

@(private = "file")
pairing_begin :: proc "contextless" (
	session: ^Pairing_Session,
	side: Pairing_Side,
	own_identity: [PUBLIC_KEY_SIZE]u8,
	secret: [PAIRING_CODE_SECRET_SIZE]u8,
	now_ms: u64,
) -> Pairing_Status {
	checked_side, side_ok := pairing_side_of_word(u64(side))
	if !side_ok {
		return .Refused_Bad_Side
	}
	if key_is_zero(own_identity) {
		return .Refused_Zero_Key
	}
	switch session.phase {
	case .Idle, .Paired, .Failed:
	case .Code_Ready, .Exchanging, .Confirming:
		return .Refused_Bad_Phase
	}
	pairing_session_clear(session)
	session.side = checked_side
	session.phase = .Code_Ready
	session.own_identity = own_identity
	session.code_secret = secret
	session.code_started_at_ms = now_ms
	return .Ok
}

// pairing_offer starts a pairing on the machine that shows the code, from 64
// random bits of a generator for keys, and gives the text of the code.
pairing_offer :: proc "contextless" (
	session: ^Pairing_Session,
	own_identity: [PUBLIC_KEY_SIZE]u8,
	random_bytes: [8]u8,
	now_ms: u64,
) -> (code_text: [PAIRING_CODE_TEXT_SIZE]u8, status: Pairing_Status) {
	if session == nil {
		return {}, .Refused_Nil_Input
	}
	secret, secret_status := pairing_code_secret_of_random(random_bytes)
	defer clear_bytes_explicitly(secret[:])
	if secret_status != .Ok {
		return {}, secret_status
	}
	begin_status := pairing_begin(session, .Offerer, own_identity, secret, now_ms)
	if begin_status != .Ok {
		return {}, begin_status
	}
	return pairing_code_text(secret), .Ok
}

// pairing_join starts a pairing on the machine where the principal typed the
// code.
pairing_join :: proc "contextless" (
	session: ^Pairing_Session,
	own_identity: [PUBLIC_KEY_SIZE]u8,
	code_text: []u8,
	now_ms: u64,
) -> Pairing_Status {
	if session == nil {
		return .Refused_Nil_Input
	}
	secret, text_status := pairing_code_of_text(code_text)
	defer clear_bytes_explicitly(secret[:])
	if text_status != .Ok {
		return text_status
	}
	return pairing_begin(session, .Joiner, own_identity, secret, now_ms)
}

// pairing_code_expired is true from 10 minutes after the start, and when the
// clock is before the start: a clock that went back cannot extend a code.
pairing_code_expired :: proc "contextless" (started_at_ms: u64, now_ms: u64) -> bool {
	return now_ms < started_at_ms || now_ms - started_at_ms >= PAIRING_CODE_LIFETIME_MS
}

// pairing_ledger_spend records a code as spent. A code that the ledger holds
// is refused. Entries older than the life of a code leave the ledger; when
// no entry can leave, the ledger refuses, and no code runs until one ends.
pairing_ledger_spend :: proc "contextless" (
	ledger: ^Pairing_Code_Ledger,
	secret: [PAIRING_CODE_SECRET_SIZE]u8,
	now_ms: u64,
) -> Pairing_Status {
	if ledger == nil || ledger.count < 0 || ledger.count > MAX_SPENT_PAIRING_CODES {
		return .Refused_Nil_Input
	}
	secret_copy := secret
	fingerprint := blake3.derive_key(PAIRING_CODE_SPENT_DOMAIN, secret_copy[:])
	clear_bytes_explicitly(secret_copy[:])
	kept := 0
	spent := false
	for index in 0 ..< ledger.count {
		entry := ledger.entries[index]
		if keys_equal_constant_time(entry.fingerprint, fingerprint) {
			spent = true
		}
		if !pairing_code_expired(entry.spent_at_ms, now_ms) {
			ledger.entries[kept] = entry
			kept += 1
		}
	}
	for index in kept ..< ledger.count {
		ledger.entries[index] = {}
	}
	ledger.count = kept
	// A spent code stays refused while it lives; after its life the
	// session refuses it as expired anyway.
	if spent {
		return .Refused_Code_Spent
	}
	if ledger.count >= MAX_SPENT_PAIRING_CODES {
		return .Refused_Spent_Ledger_Full
	}
	ledger.entries[ledger.count] = Spent_Pairing_Code{fingerprint = fingerprint, spent_at_ms = now_ms}
	ledger.count += 1
	return .Ok
}

// pairing_exchange_start binds the code to the connection and to the identity
// key that the peer proved in the handshake, spends the code, and gives the
// CPace element to send.
pairing_exchange_start :: proc "contextless" (
	session: ^Pairing_Session,
	ledger: ^Pairing_Code_Ledger,
	peer_identity: [PUBLIC_KEY_SIZE]u8,
	channel_binding: []u8,
	ephemeral_scalar: [CPACE_SCALAR_SIZE]u8,
	now_ms: u64,
) -> (own_element: [CPACE_PUBLIC_ELEMENT_SIZE]u8, status: Pairing_Status) {
	if session == nil || ledger == nil {
		return {}, .Refused_Nil_Input
	}
	if session.phase != .Code_Ready {
		return {}, .Refused_Bad_Phase
	}
	if pairing_code_expired(session.code_started_at_ms, now_ms) {
		return {}, pairing_fail(session, .Refused_Code_Expired)
	}
	if key_is_zero(peer_identity) {
		return {}, pairing_fail(session, .Refused_Zero_Key)
	}
	if keys_equal_constant_time(peer_identity, session.own_identity) {
		return {}, pairing_fail(session, .Refused_Same_Machine)
	}
	if len(channel_binding) != PAIRING_CHANNEL_BINDING_SIZE || bytes_all_zero(channel_binding) {
		return {}, pairing_fail(session, .Refused_Bad_Channel_Binding)
	}
	spend_status := pairing_ledger_spend(ledger, session.code_secret, now_ms)
	if spend_status != .Ok {
		return {}, pairing_fail(session, spend_status)
	}
	role: Cpace_Role
	switch session.side {
	case .Offerer:
		role = .Responder
	case .Joiner:
		role = .Initiator
	}
	element, cpace_status := cpace_start(
		&session.cpace,
		role,
		session.code_secret[:],
		channel_binding,
		transmute([]u8)string(PAIRING_SESSION_IDENTIFIER),
		session.own_identity[:],
		ephemeral_scalar,
	)
	// The code is needed only to derive the generator.
	clear_bytes_explicitly(session.code_secret[:])
	if cpace_status != .Ok {
		session.cpace_status = cpace_status
		return {}, pairing_fail(session, .Refused_Exchange)
	}
	session.peer_identity = peer_identity
	session.phase = .Exchanging
	return element, .Ok
}

// pairing_exchange_finish takes the element and the associated data of the
// peer. The associated data must be the identity key that the handshake
// proved: a relay that swaps it is refused before any key is derived.
pairing_exchange_finish :: proc "contextless" (
	session: ^Pairing_Session,
	peer_element: [CPACE_PUBLIC_ELEMENT_SIZE]u8,
	peer_associated_data: []u8,
) -> (own_confirmation_tag: [CPACE_CONFIRM_TAG_SIZE]u8, status: Pairing_Status) {
	if session == nil {
		return {}, .Refused_Nil_Input
	}
	if session.phase != .Exchanging {
		return {}, .Refused_Bad_Phase
	}
	if !slices_equal_constant_time(peer_associated_data, session.peer_identity[:]) {
		return {}, pairing_fail(session, .Refused_Peer_Key_Mismatch)
	}
	tag, cpace_status := cpace_finish(&session.cpace, peer_element, peer_associated_data)
	if cpace_status != .Ok {
		session.cpace_status = cpace_status
		return {}, pairing_fail(session, .Refused_Exchange)
	}
	session.phase = .Confirming
	return tag, .Ok
}

// pairing_confirm checks the confirmation tag of the peer, then writes the
// peer in the table with the uses that the principal accepted.
pairing_confirm :: proc "contextless" (
	session: ^Pairing_Session,
	table: ^Paired_Machine_Table,
	peer_confirmation_tag: [CPACE_CONFIRM_TAG_SIZE]u8,
	uses_word: u64,
	now_ms: u64,
) -> (paired: Paired_Machine, status: Pairing_Status) {
	if session == nil || table == nil {
		return {}, .Refused_Nil_Input
	}
	if session.phase != .Confirming {
		return {}, .Refused_Bad_Phase
	}
	uses, uses_ok := remote.client_uses_of_word(uses_word)
	if !uses_ok {
		return {}, pairing_fail(session, .Refused_Bad_Uses)
	}
	session_key, cpace_status := cpace_verify_peer_confirmation(&session.cpace, peer_confirmation_tag)
	defer clear_bytes_explicitly(session_key[:])
	if cpace_status != .Ok {
		session.cpace_status = cpace_status
		return {}, pairing_fail(session, .Refused_Confirmation_Failed)
	}
	paired = Paired_Machine {
		identity_key           = session.peer_identity,
		uses                   = uses,
		source                 = .Pairing,
		paired_at_ms           = now_ms,
		transcript_fingerprint = blake3.derive_key(PAIRING_TRANSCRIPT_DOMAIN, session_key[:]),
	}
	add_status := paired_machine_add(table, paired)
	if add_status != .Ok {
		return {}, pairing_fail(session, add_status)
	}
	side := session.side
	pairing_session_clear(session)
	session.side = side
	session.phase = .Paired
	return paired, .Ok
}

// paired_machine_add writes a new row. A key that has a row is refused: a
// second pairing does not change the uses of a first one in silence.
paired_machine_add :: proc "contextless" (table: ^Paired_Machine_Table, machine: Paired_Machine) -> Pairing_Status {
	if table == nil || table.count < 0 || table.count > MAX_PAIRED_MACHINES {
		return .Refused_Nil_Input
	}
	if key_is_zero(machine.identity_key) {
		return .Refused_Zero_Key
	}
	if _, uses_ok := remote.client_uses_of_word(remote.client_uses_word(machine.uses)); !uses_ok {
		return .Refused_Bad_Uses
	}
	if _, source_ok := paired_machine_source_of_word(u64(machine.source)); !source_ok {
		return .Refused_Nil_Input
	}
	if _, found := paired_machine_find(table, machine.identity_key); found {
		return .Refused_Already_Paired
	}
	if table.count >= MAX_PAIRED_MACHINES {
		return .Refused_Table_Full
	}
	table.machines[table.count] = machine
	table.count += 1
	return .Ok
}

paired_machine_find :: proc "contextless" (table: ^Paired_Machine_Table, identity_key: [PUBLIC_KEY_SIZE]u8) -> (machine: Paired_Machine, found: bool) {
	if table == nil || key_is_zero(identity_key) || table.count < 0 || table.count > MAX_PAIRED_MACHINES {
		return {}, false
	}
	for index in 0 ..< table.count {
		if keys_equal_constant_time(table.machines[index].identity_key, identity_key) {
			return table.machines[index], true
		}
	}
	return {}, false
}

// paired_machine_remove removes the row of a key; false when it had none.
paired_machine_remove :: proc "contextless" (table: ^Paired_Machine_Table, identity_key: [PUBLIC_KEY_SIZE]u8) -> bool {
	if table == nil || key_is_zero(identity_key) || table.count <= 0 || table.count > MAX_PAIRED_MACHINES {
		return false
	}
	for index in 0 ..< table.count {
		if keys_equal_constant_time(table.machines[index].identity_key, identity_key) {
			last := table.count - 1
			table.machines[index] = table.machines[last]
			table.machines[last] = {}
			table.count = last
			return true
		}
	}
	return false
}

machine_list_holder_init :: proc "contextless" (holder: ^Machine_List_Holder, principal_root_public_key: Principal_Root_Public_Key) -> bool {
	if holder == nil || key_is_zero(principal_root_public_key) {
		return false
	}
	holder^ = {}
	holder.principal_root_public_key = principal_root_public_key
	return true
}

// machine_list_holder_update takes a newer signed machine list of the
// principal whose root key the holder names, then makes the rows of the
// table follow it: a row that came from a list and whose machine is not
// active in the new list leaves at once, and each other active machine of
// the list gets a row with its uses. A refused list changes nothing.
// not_added counts the machines that found no free row.
machine_list_holder_update :: proc "contextless" (
	holder: ^Machine_List_Holder,
	table: ^Paired_Machine_Table,
	own_identity: [PUBLIC_KEY_SIZE]u8,
	candidate: ^Signed_Machine_List,
	policy: Join_Policy,
	verify_signature: Signature_Verify_Proc,
	now_ms: u64,
	user_data: rawptr = nil,
) -> (status: Machine_List_Status, revoked: int, added: int, not_added: int) {
	if holder == nil || table == nil || candidate == nil || table.count < 0 || table.count > MAX_PAIRED_MACHINES {
		return .Refused_Nil_Input, 0, 0, 0
	}
	if key_is_zero(holder.principal_root_public_key) {
		return .Refused_Zero_Root_Key, 0, 0, 0
	}
	if !keys_equal_constant_time(holder.principal_root_public_key, candidate.principal_root_public_key) {
		return .Refused_Root_Key_Mismatch, 0, 0, 0
	}
	status = machine_list_apply_update(&holder.list, holder.has_list, candidate, policy, verify_signature, user_data)
	if !machine_list_status_accepted(status) {
		return status, 0, 0, 0
	}
	holder.has_list = true
	index := table.count - 1
	for index >= 0 {
		machine := table.machines[index]
		if machine.source == .Machine_List {
			if _, active := machine_list_find_active_by_machine_id(&holder.list, machine.identity_key); !active {
				paired_machine_remove(table, machine.identity_key)
				revoked += 1
			}
		}
		index -= 1
	}
	for entry_index in 0 ..< int(holder.list.entry_count) {
		entry := holder.list.entries[entry_index]
		if entry.state != .Active || keys_equal_constant_time(entry.machine_id, own_identity) {
			continue
		}
		found := false
		for row_index in 0 ..< table.count {
			row := &table.machines[row_index]
			if keys_equal_constant_time(row.identity_key, entry.machine_id) {
				found = true
				// The list is the authority over its own rows; a row of a
				// pairing keeps the uses that the principal accepted there.
				if row.source == .Machine_List {
					row.uses = entry.uses
				}
				break
			}
		}
		if found {
			continue
		}
		row := Paired_Machine {
			identity_key = entry.machine_id,
			uses         = entry.uses,
			source       = .Machine_List,
			paired_at_ms = now_ms,
		}
		if paired_machine_add(table, row) == .Ok {
			added += 1
		} else {
			not_added += 1
		}
	}
	return status, revoked, added, not_added
}
