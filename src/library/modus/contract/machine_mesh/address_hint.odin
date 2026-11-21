// Local network address hint (src/md/features/several_machines.md, "The address
// hint on the local network").
//
// Off by default so a machine does not announce its presence on untrusted
// networks. When explicitly enabled, a machine broadcasts a compact datagram
// carrying only its local address, a fresh nonce, and a keyed BLAKE3 tag bound
// to the principal's or peer's key. The datagram carries no principal name, no
// machine name, no public key in the clear, and grants zero authority: a peer
// that recognizes the tag only tries the address and lets the authenticated
// handshake decide.
package machine_mesh

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Wire magic, version, and field sizes of one local address hint datagram.
ADDRESS_HINT_MAGIC :: [4]u8{'M', 'D', 'A', 'H'}
ADDRESS_HINT_WIRE_VERSION :: u8(1)
ADDRESS_HINT_NONCE_SIZE :: 16
ADDRESS_HINT_TAG_SIZE :: blake3.HASH_SIZE
ADDRESS_HINT_ADDRESS_SIZE :: 16

// Domain separation context string for the keyed BLAKE3 tag.
ADDRESS_HINT_TAG_DOMAIN :: "modus local address hint v1"

// Exact binary wire size of one address hint datagram:
//   [0..4]   magic "MDAH"
//   [4]      version (1)
//   [5]      address_family (1 = IPv4, 2 = IPv6)
//   [6..8]   port (u16 LE)
//   [8..24]  address (16 bytes; for IPv4 bytes [4..16] must be 0)
//   [24..40] nonce (16 bytes, non-zero)
//   [40..72] tag (32-byte keyed BLAKE3 digest)
ADDRESS_HINT_WIRE_SIZE :: 4 + 1 + 1 + 2 + ADDRESS_HINT_ADDRESS_SIZE + ADDRESS_HINT_NONCE_SIZE + ADDRESS_HINT_TAG_SIZE

// Input length fed into blake3.derive_key when computing the hint tag:
//   [0..32]  hint_key (32 bytes)
//   [32]     version (1)
//   [33]     address_family
//   [34..36] port (u16 LE)
//   [36..52] address (16 bytes)
//   [52..68] nonce (16 bytes)
ADDRESS_HINT_TAG_INPUT_SIZE :: PUBLIC_KEY_SIZE + 1 + 1 + 2 + ADDRESS_HINT_ADDRESS_SIZE + ADDRESS_HINT_NONCE_SIZE

#assert(ADDRESS_HINT_WIRE_SIZE == 72)
#assert(ADDRESS_HINT_TAG_INPUT_SIZE == 68)

// Closed set of network address families carried in an address hint.
Address_Family :: enum u8 {
	IPv4 = 1,
	IPv6 = 2,
}

// Configuration for local address hint emission and reception.
// Zero value keeps address hints disabled by default.
Address_Hint_Config :: struct {
	enabled: bool,
}

// Parsed or built local address hint datagram.
Address_Hint_Datagram :: struct {
	address_family: Address_Family,
	port:           u16,
	address:        [ADDRESS_HINT_ADDRESS_SIZE]u8,
	nonce:          [ADDRESS_HINT_NONCE_SIZE]u8,
	tag:            [ADDRESS_HINT_TAG_SIZE]u8,
}

// Closed outcome of building, encoding, decoding, or verifying an address hint.
Address_Hint_Status :: enum u8 {
	Ok                 = 1,
	Refused_Disabled   = 2,
	Refused_Zero_Key   = 3,
	Refused_Bad_Family = 4,
	Refused_Bad_Port   = 5,
	Refused_Bad_Address = 6,
	Refused_Zero_Nonce = 7,
	Refused_Bad_Tag    = 8,
	Refused_Buffer_Too_Small = 9,
	Refused_Malformed_Wire   = 10,
}

// default_address_hint_config returns the default configuration with local
// address hints disabled.
default_address_hint_config :: proc "contextless" () -> Address_Hint_Config {
	return Address_Hint_Config{enabled = false}
}

// address_family_of_word is the single border converting a transport byte into
// an Address_Family member.
address_family_of_word :: proc "contextless" (word: u64) -> (family: Address_Family, ok: bool) {
	return enum_word.member_of_word(Address_Family, word)
}

// validate_address_hint_fields checks family, port, address, and nonce.
@(private)
validate_address_hint_fields :: proc "contextless" (
	family: Address_Family,
	port: u16,
	address: [ADDRESS_HINT_ADDRESS_SIZE]u8,
	nonce: [ADDRESS_HINT_NONCE_SIZE]u8,
) -> (checked_family: Address_Family, status: Address_Hint_Status) {
	parsed_family, family_ok := address_family_of_word(u64(family))
	if !family_ok {
		return {}, .Refused_Bad_Family
	}
	if port == 0 {
		return {}, .Refused_Bad_Port
	}
	addr_copy := address
	switch parsed_family {
	case .IPv4:
		if bytes_all_zero(addr_copy[0:4]) {
			return {}, .Refused_Bad_Address
		}
		if !bytes_all_zero(addr_copy[4:16]) {
			return {}, .Refused_Bad_Address
		}
	case .IPv6:
		if bytes_all_zero(addr_copy[:]) {
			return {}, .Refused_Bad_Address
		}
	}
	nonce_copy := nonce
	if bytes_all_zero(nonce_copy[:]) {
		return {}, .Refused_Zero_Nonce
	}
	return parsed_family, .Ok
}

// compute_address_hint_tag computes the keyed BLAKE3 authentication tag over
// the hint key, protocol fields, address, and nonce.
@(private)
compute_address_hint_tag :: proc "contextless" (
	hint_key: [PUBLIC_KEY_SIZE]u8,
	family: Address_Family,
	port: u16,
	address: [ADDRESS_HINT_ADDRESS_SIZE]u8,
	nonce: [ADDRESS_HINT_NONCE_SIZE]u8,
) -> [ADDRESS_HINT_TAG_SIZE]u8 {
	tag_input: [ADDRESS_HINT_TAG_INPUT_SIZE]u8
	key_copy := hint_key
	addr_copy := address
	nonce_copy := nonce
	copy(tag_input[0:32], key_copy[:])
	tag_input[32] = ADDRESS_HINT_WIRE_VERSION
	tag_input[33] = u8(family)
	byte_order.write_u16_little_endian(tag_input[:], 34, port)
	copy(tag_input[36:52], addr_copy[:])
	copy(tag_input[52:68], nonce_copy[:])
	tag := blake3.derive_key(ADDRESS_HINT_TAG_DOMAIN, tag_input[:])
	clear_bytes_explicitly(tag_input[:])
	return tag
}

// address_hint_build creates an authenticated local address hint datagram when
// config.enabled is true. Refuses when disabled or when any input is invalid.
address_hint_build :: proc "contextless" (
	config: Address_Hint_Config,
	hint_key: [PUBLIC_KEY_SIZE]u8,
	family: Address_Family,
	port: u16,
	address: [ADDRESS_HINT_ADDRESS_SIZE]u8,
	nonce: [ADDRESS_HINT_NONCE_SIZE]u8,
) -> (datagram: Address_Hint_Datagram, status: Address_Hint_Status) {
	if !config.enabled {
		return {}, .Refused_Disabled
	}
	if key_is_zero(hint_key) {
		return {}, .Refused_Zero_Key
	}
	checked_family, field_status := validate_address_hint_fields(family, port, address, nonce)
	if field_status != .Ok {
		return {}, field_status
	}
	datagram.address_family = checked_family
	datagram.port = port
	datagram.address = address
	datagram.nonce = nonce
	datagram.tag = compute_address_hint_tag(hint_key, checked_family, port, address, nonce)
	return datagram, .Ok
}

// address_hint_verify checks whether datagram was produced by a peer holding
// hint_key, using constant-time tag comparison. Refuses when hints are disabled.
address_hint_verify :: proc "contextless" (
	config: Address_Hint_Config,
	hint_key: [PUBLIC_KEY_SIZE]u8,
	datagram: ^Address_Hint_Datagram,
) -> Address_Hint_Status {
	if !config.enabled {
		return .Refused_Disabled
	}
	if datagram == nil {
		return .Refused_Malformed_Wire
	}
	if key_is_zero(hint_key) {
		return .Refused_Zero_Key
	}
	checked_family, field_status := validate_address_hint_fields(
		datagram.address_family,
		datagram.port,
		datagram.address,
		datagram.nonce,
	)
	if field_status != .Ok {
		return field_status
	}
	expected_tag := compute_address_hint_tag(
		hint_key,
		checked_family,
		datagram.port,
		datagram.address,
		datagram.nonce,
	)
	if !keys_equal_constant_time(expected_tag, datagram.tag) {
		return .Refused_Bad_Tag
	}
	return .Ok
}

// address_hint_encode writes datagram into output (ADDRESS_HINT_WIRE_SIZE bytes).
// Refused calls leave output unchanged.
address_hint_encode :: proc "contextless" (
	datagram: ^Address_Hint_Datagram,
	output: []u8,
) -> (written: int, status: Address_Hint_Status) {
	if datagram == nil {
		return 0, .Refused_Malformed_Wire
	}
	checked_family, field_status := validate_address_hint_fields(
		datagram.address_family,
		datagram.port,
		datagram.address,
		datagram.nonce,
	)
	if field_status != .Ok {
		return 0, field_status
	}
	if len(output) < ADDRESS_HINT_WIRE_SIZE {
		return 0, .Refused_Buffer_Too_Small
	}
	magic := ADDRESS_HINT_MAGIC
	copy(output[0:4], magic[:])
	output[4] = ADDRESS_HINT_WIRE_VERSION
	output[5] = u8(checked_family)
	byte_order.write_u16_little_endian(output, 6, datagram.port)
	copy(output[8:24], datagram.address[:])
	copy(output[24:40], datagram.nonce[:])
	copy(output[40:72], datagram.tag[:])
	return ADDRESS_HINT_WIRE_SIZE, .Ok
}

// address_hint_decode strictly validates and decodes a wire address hint
// datagram. Callers must still invoke address_hint_verify with a peer key.
address_hint_decode :: proc "contextless" (input: []u8) -> (datagram: Address_Hint_Datagram, status: Address_Hint_Status) {
	if len(input) != ADDRESS_HINT_WIRE_SIZE {
		return {}, .Refused_Malformed_Wire
	}
	magic := ADDRESS_HINT_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Refused_Malformed_Wire
		}
	}
	if input[4] != ADDRESS_HINT_WIRE_VERSION {
		return {}, .Refused_Malformed_Wire
	}
	checked_family, family_ok := address_family_of_word(u64(input[5]))
	if !family_ok {
		return {}, .Refused_Bad_Family
	}
	port := byte_order.read_u16_little_endian(input, 6)
	address: [ADDRESS_HINT_ADDRESS_SIZE]u8
	nonce: [ADDRESS_HINT_NONCE_SIZE]u8
	copy(address[:], input[8:24])
	copy(nonce[:], input[24:40])
	_, field_status := validate_address_hint_fields(checked_family, port, address, nonce)
	if field_status != .Ok {
		return {}, field_status
	}
	datagram.address_family = checked_family
	datagram.port = port
	datagram.address = address
	datagram.nonce = nonce
	copy(datagram.tag[:], input[40:72])
	return datagram, .Ok
}
