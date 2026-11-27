// Rules of the principals service: deterministic validation, canonical sorting,
// and BLAKE3 snapshot digest of Disk_Rows_Set before delivery to the root
// service (src/md/api/root_service_split.md).
//
// The delegated `principals` service owns the rules of disk grants, remote
// client keys, and the start policy choice of principal 0, delivering one
// validated canonical Disk_Rows_Set snapshot to the root service core.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package principals_rules

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: domain separation context for canonical Disk_Rows_Set digests.
DISK_ROWS_DIGEST_DOMAIN :: "modus principals disk rows v1"

// Plan value: principal slot count on one machine (principal 0 plus up to 7
// named principals, matching modus:principals.PRINCIPAL_CAPACITY).
PRINCIPAL_CAPACITY :: u64(8)

// Plan value: bounded disk grant rows per principal snapshot transferred to root.
DISK_GRANT_ROW_CAPACITY :: 64

// Format property: client key row capacity matching remote.CLIENT_CAPACITY.
REMOTE_CLIENT_ROW_CAPACITY :: 32

// Format property: maximum ASCII byte length of a disk process nickname.
DISK_NICKNAME_LIMIT :: 32

// Format property: byte length of an Ed25519 remote client public key.
CLIENT_KEY_SIZE :: 32

// Computed: stack buffer size for canonical BLAKE3 digest encoding of Disk_Rows_Set
// (header 8+8+1+32+4+4 = 57 + 64*(4+32+32+8+8 = 84) + 32*(32+8+8+1 = 49) = 7001 bytes).
DISK_ROWS_DIGEST_BUFFER_SIZE :: 57 + DISK_GRANT_ROW_CAPACITY * (4 + DISK_NICKNAME_LIMIT + blake3.HASH_SIZE + 8 + 8) + REMOTE_CLIENT_ROW_CAPACITY * (CLIENT_KEY_SIZE + 8 + 8 + 1)

// Closed set of start policy selections owned by principal 0.
Start_Policy_Kind :: enum u8 {
	None               = 0,
	Boot_Image_Default = 1, // Default start policy of the signed boot image.
	Chosen_Disk_Module = 2, // Disk module selected by principal 0 (requires non-zero module hash).
	Rescue             = 3, // Rescue start policy of the signed boot image.
}

// Closed set of grant classes that a Disk_Grant_Row can carry.
Disk_Grant_Flag :: enum u8 {
	Store = 0, // Private persistent store bound to the disk process nickname.
}

// Bit set of disk grant classes carried in a Disk_Grant_Row.
Disk_Grant_Flags :: bit_set[Disk_Grant_Flag;u64]

// Mask of every allowed Disk_Grant_Flag bit; unknown bits are refused at the border.
ALL_DISK_GRANT_FLAGS :: Disk_Grant_Flags{.Store}

// Closed set of authorized uses of a remote client public key.
Client_Use_Flag :: enum u8 {
	Calls = 0, // Remote service calls over QUIC.
	View  = 1, // Remote display screen view.
	Input = 2, // Remote display keyboard and pointer input.
}

// Bit set of authorized uses carried in a Remote_Client_Row.
Client_Use_Flags :: bit_set[Client_Use_Flag;u64]

// Mask of every allowed Client_Use_Flag bit; unknown bits are refused at the border.
ALL_CLIENT_USE_FLAGS :: Client_Use_Flags{.Calls, .View, .Input}

// Closed set of refusal reasons for Disk_Rows_Set validation and canonicalization.
Principals_Rules_Refusal :: enum u8 {
	None                                  = 0,
	Bad_Principal                         = 1,
	Unknown_Start_Policy_Kind             = 2,
	Zero_Start_Policy_Hash                = 3,
	Nonzero_Start_Policy_Hash_For_Default = 4,
	Start_Policy_Not_Principal_Zero       = 5,
	Too_Many_Disk_Grants                  = 6,
	Too_Many_Remote_Clients               = 7,
	Empty_Nickname                        = 8,
	Nickname_Too_Long                     = 9,
	Bad_Nickname_Byte                     = 10,
	Zero_Module_Hash                      = 11,
	Unknown_Disk_Grant_Bits               = 12,
	Duplicate_Disk_Grant_Nickname         = 13,
	Zero_Client_Key                       = 14,
	Empty_Client_Uses                     = 15,
	Unknown_Client_Use_Bits               = 16,
	Duplicate_Remote_Client_Key           = 17,
}

// start_policy_kind_from_word converts a transport word into a Start_Policy_Kind
// at the border, refusing None and every unknown value.
start_policy_kind_from_word :: proc "contextless" (word: u64) -> (kind: Start_Policy_Kind, ok: bool) {
	member := enum_word.member_of_word(Start_Policy_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// principals_rules_refusal_from_word converts a transport word into a
// Principals_Rules_Refusal at the border, refusing any unknown value.
principals_rules_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Principals_Rules_Refusal, ok: bool) {
	return enum_word.member_of_word(Principals_Rules_Refusal, word)
}

// disk_grant_flags_to_word returns the canonical u64 transport word of grants.
disk_grant_flags_to_word :: proc "contextless" (grants: Disk_Grant_Flags) -> u64 {
	return transmute(u64)grants
}

// disk_grant_flags_from_word converts a transport word into Disk_Grant_Flags,
// refusing any bit outside ALL_DISK_GRANT_FLAGS.
disk_grant_flags_from_word :: proc "contextless" (word: u64) -> (grants: Disk_Grant_Flags, ok: bool) {
	all_grants := ALL_DISK_GRANT_FLAGS
	allowed := transmute(u64)all_grants
	if (word & ~allowed) != 0 {
		return {}, false
	}
	return transmute(Disk_Grant_Flags)word, true
}

// client_use_flags_to_word returns the canonical u64 transport word of uses.
client_use_flags_to_word :: proc "contextless" (uses: Client_Use_Flags) -> u64 {
	return transmute(u64)uses
}

// client_use_flags_from_word converts a transport word into Client_Use_Flags,
// refusing any bit outside ALL_CLIENT_USE_FLAGS.
client_use_flags_from_word :: proc "contextless" (word: u64) -> (uses: Client_Use_Flags, ok: bool) {
	all_uses := ALL_CLIENT_USE_FLAGS
	allowed := transmute(u64)all_uses
	if (word & ~allowed) != 0 {
		return {}, false
	}
	return transmute(Client_Use_Flags)word, true
}

// One disk-process grant row owned by `principals` and sent to `root`.
Disk_Grant_Row :: struct {
	nickname:        [DISK_NICKNAME_LIMIT]u8,
	nickname_length: u32,
	module_hash:     blake3.Hash,
	grants:          Disk_Grant_Flags,
	store_blocks:    u64,
}

// One remote client public key row owned by `principals` and sent to `root`.
Remote_Client_Row :: struct {
	public_key:     [CLIENT_KEY_SIZE]u8,
	uses:           Client_Use_Flags,
	serial:         u64,
	session_locked: bool,
}

// Complete snapshot of one principal's disk grants, remote client keys, and
// start policy selection validated before delivery to the root service core.
Disk_Rows_Set :: struct {
	principal:           u64,
	generation:          u64,
	start_policy_kind:   Start_Policy_Kind,
	start_policy_hash:   blake3.Hash,
	disk_grants:         [DISK_GRANT_ROW_CAPACITY]Disk_Grant_Row,
	disk_grant_count:    u32,
	remote_clients:      [REMOTE_CLIENT_ROW_CAPACITY]Remote_Client_Row,
	remote_client_count: u32,
}

// is_zero_bytes reports whether every byte of slice is zero.
@(private = "file")
is_zero_bytes :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8 = 0
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

// compare_bytes orders two byte slices lexicographically: -1, 0, or 1.
@(private = "file")
compare_bytes :: proc "contextless" (left, right: []u8) -> int {
	limit := min(len(left), len(right))
	for index in 0 ..< limit {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	if len(left) != len(right) {
		return len(left) < len(right) ? -1 : 1
	}
	return 0
}

// nickname_check validates a disk process nickname (1..32 lowercase ASCII,
// digits, '_', or '-').
@(private = "file")
nickname_check :: proc "contextless" (bytes: []u8) -> Principals_Rules_Refusal {
	if len(bytes) == 0 {
		return .Empty_Nickname
	}
	if len(bytes) > DISK_NICKNAME_LIMIT {
		return .Nickname_Too_Long
	}
	for b in bytes {
		is_lower := b >= 'a' && b <= 'z'
		is_digit := b >= '0' && b <= '9'
		is_punct := b == '_' || b == '-'
		if !(is_lower || is_digit || is_punct) {
			return .Bad_Nickname_Byte
		}
	}
	return .None
}

// disk_grant_row_make builds a validated Disk_Grant_Row from a nickname string.
disk_grant_row_make :: proc "contextless" (
	nickname: string,
	module_hash: blake3.Hash,
	grants: Disk_Grant_Flags,
	store_blocks: u64,
) -> (row: Disk_Grant_Row, refusal: Principals_Rules_Refusal) {
	bytes := transmute([]u8)nickname
	if check := nickname_check(bytes); check != .None {
		return {}, check
	}
	hash_copy := module_hash
	if is_zero_bytes(hash_copy[:]) {
		return {}, .Zero_Module_Hash
	}
	if _, ok := disk_grant_flags_from_word(disk_grant_flags_to_word(grants)); !ok {
		return {}, .Unknown_Disk_Grant_Bits
	}
	built: Disk_Grant_Row
	copy(built.nickname[:len(bytes)], bytes)
	built.nickname_length = u32(len(bytes))
	built.module_hash = module_hash
	built.grants = grants
	built.store_blocks = store_blocks
	return built, .None
}

// disk_grant_row_nickname returns the nickname slice held in row, or empty
// string if nickname_length exceeds DISK_NICKNAME_LIMIT.
disk_grant_row_nickname :: proc "contextless" (row: ^Disk_Grant_Row) -> string {
	if row == nil || row.nickname_length > DISK_NICKNAME_LIMIT {
		return ""
	}
	return string(row.nickname[:row.nickname_length])
}

// disk_rows_set_validate checks every border rule of a Disk_Rows_Set snapshot
// without mutating it.
disk_rows_set_validate :: proc "contextless" (rows: ^Disk_Rows_Set) -> Principals_Rules_Refusal {
	if rows == nil {
		return .Bad_Principal
	}
	if rows.principal >= PRINCIPAL_CAPACITY {
		return .Bad_Principal
	}
	kind, kind_ok := start_policy_kind_from_word(u64(rows.start_policy_kind))
	if !kind_ok {
		return .Unknown_Start_Policy_Kind
	}
	policy_hash := rows.start_policy_hash
	switch kind {
	case .None:
		return .Unknown_Start_Policy_Kind
	case .Boot_Image_Default, .Rescue:
		if !is_zero_bytes(policy_hash[:]) {
			return .Nonzero_Start_Policy_Hash_For_Default
		}
	case .Chosen_Disk_Module:
		if rows.principal != 0 {
			return .Start_Policy_Not_Principal_Zero
		}
		if is_zero_bytes(policy_hash[:]) {
			return .Zero_Start_Policy_Hash
		}
	}
	if rows.disk_grant_count > DISK_GRANT_ROW_CAPACITY {
		return .Too_Many_Disk_Grants
	}
	if rows.remote_client_count > REMOTE_CLIENT_ROW_CAPACITY {
		return .Too_Many_Remote_Clients
	}

	grant_count := int(rows.disk_grant_count)
	for index in 0 ..< grant_count {
		item := rows.disk_grants[index]
		if item.nickname_length == 0 {
			return .Empty_Nickname
		}
		if item.nickname_length > DISK_NICKNAME_LIMIT {
			return .Nickname_Too_Long
		}
		if check := nickname_check(item.nickname[:item.nickname_length]); check != .None {
			return check
		}
		if is_zero_bytes(item.module_hash[:]) {
			return .Zero_Module_Hash
		}
		if _, ok := disk_grant_flags_from_word(disk_grant_flags_to_word(item.grants)); !ok {
			return .Unknown_Disk_Grant_Bits
		}
		for prev in 0 ..< index {
			other := rows.disk_grants[prev]
			if compare_bytes(item.nickname[:item.nickname_length], other.nickname[:other.nickname_length]) == 0 {
				return .Duplicate_Disk_Grant_Nickname
			}
		}
	}

	client_count := int(rows.remote_client_count)
	for index in 0 ..< client_count {
		client := rows.remote_clients[index]
		if is_zero_bytes(client.public_key[:]) {
			return .Zero_Client_Key
		}
		if _, ok := client_use_flags_from_word(client_use_flags_to_word(client.uses)); !ok {
			return .Unknown_Client_Use_Bits
		}
		if client.uses == {} {
			return .Empty_Client_Uses
		}
		for prev in 0 ..< index {
			other := rows.remote_clients[prev]
			if compare_bytes(client.public_key[:], other.public_key[:]) == 0 {
				return .Duplicate_Remote_Client_Key
			}
		}
	}
	return .None
}

// disk_rows_set_canonicalize validates input and returns a canonically sorted
// copy (disk_grants sorted by nickname, remote_clients sorted by public_key,
// trailing unused slots zeroed). On refusal, returns an empty snapshot.
disk_rows_set_canonicalize :: proc "contextless" (
	input: ^Disk_Rows_Set,
) -> (canonical: Disk_Rows_Set, refusal: Principals_Rules_Refusal) {
	if check := disk_rows_set_validate(input); check != .None {
		return {}, check
	}
	out: Disk_Rows_Set
	out.principal = input.principal
	out.generation = input.generation
	out.start_policy_kind = input.start_policy_kind
	out.start_policy_hash = input.start_policy_hash
	out.disk_grant_count = input.disk_grant_count
	out.remote_client_count = input.remote_client_count

	grant_count := int(input.disk_grant_count)
	for index in 0 ..< grant_count {
		row := input.disk_grants[index]
		// Zero trailing nickname bytes past nickname_length for canonical equality.
		clean: Disk_Grant_Row
		clean.nickname_length = row.nickname_length
		copy(clean.nickname[:row.nickname_length], row.nickname[:row.nickname_length])
		clean.module_hash = row.module_hash
		clean.grants = row.grants
		clean.store_blocks = row.store_blocks
		out.disk_grants[index] = clean
	}
	for i := 1; i < grant_count; i += 1 {
		key := out.disk_grants[i]
		j := i - 1
		for j >= 0 && compare_bytes(out.disk_grants[j].nickname[:out.disk_grants[j].nickname_length], key.nickname[:key.nickname_length]) > 0 {
			out.disk_grants[j + 1] = out.disk_grants[j]
			j -= 1
		}
		out.disk_grants[j + 1] = key
	}

	client_count := int(input.remote_client_count)
	for index in 0 ..< client_count {
		out.remote_clients[index] = input.remote_clients[index]
	}
	for i := 1; i < client_count; i += 1 {
		key := out.remote_clients[i]
		j := i - 1
		for j >= 0 && compare_bytes(out.remote_clients[j].public_key[:], key.public_key[:]) > 0 {
			out.remote_clients[j + 1] = out.remote_clients[j]
			j -= 1
		}
		out.remote_clients[j + 1] = key
	}
	return out, .None
}

// disk_rows_set_digest computes the canonical order-invariant BLAKE3 digest of
// a validated Disk_Rows_Set snapshot.
disk_rows_set_digest :: proc "contextless" (
	rows: ^Disk_Rows_Set,
) -> (digest: blake3.Hash, refusal: Principals_Rules_Refusal) {
	canonical, check := disk_rows_set_canonicalize(rows)
	if check != .None {
		return {}, check
	}
	buffer: [DISK_ROWS_DIGEST_BUFFER_SIZE]u8
	offset := 0
	byte_order.write_u64_little_endian(buffer[:], offset, canonical.principal)
	offset += 8
	byte_order.write_u64_little_endian(buffer[:], offset, canonical.generation)
	offset += 8
	buffer[offset] = u8(canonical.start_policy_kind)
	offset += 1
	copy(buffer[offset:][:blake3.HASH_SIZE], canonical.start_policy_hash[:])
	offset += blake3.HASH_SIZE
	byte_order.write_u32_little_endian(buffer[:], offset, canonical.disk_grant_count)
	offset += 4
	for index in 0 ..< int(canonical.disk_grant_count) {
		item := canonical.disk_grants[index]
		byte_order.write_u32_little_endian(buffer[:], offset, item.nickname_length)
		offset += 4
		copy(buffer[offset:][:item.nickname_length], item.nickname[:item.nickname_length])
		offset += int(item.nickname_length)
		copy(buffer[offset:][:blake3.HASH_SIZE], item.module_hash[:])
		offset += blake3.HASH_SIZE
		byte_order.write_u64_little_endian(buffer[:], offset, disk_grant_flags_to_word(item.grants))
		offset += 8
		byte_order.write_u64_little_endian(buffer[:], offset, item.store_blocks)
		offset += 8
	}
	byte_order.write_u32_little_endian(buffer[:], offset, canonical.remote_client_count)
	offset += 4
	for index in 0 ..< int(canonical.remote_client_count) {
		client := canonical.remote_clients[index]
		copy(buffer[offset:][:CLIENT_KEY_SIZE], client.public_key[:])
		offset += CLIENT_KEY_SIZE
		byte_order.write_u64_little_endian(buffer[:], offset, client_use_flags_to_word(client.uses))
		offset += 8
		byte_order.write_u64_little_endian(buffer[:], offset, client.serial)
		offset += 8
		buffer[offset] = client.session_locked ? 1 : 0
		offset += 1
	}
	return blake3.derive_key(DISK_ROWS_DIGEST_DOMAIN, buffer[:offset]), .None
}
