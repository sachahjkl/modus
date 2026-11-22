// SSH-2 binary wire encoding, message identifiers, and protocol bounds (RFC 4251, RFC 4253).
//
// All serialization writes into caller-supplied byte buffers with zero heap allocation.
// Wire message type bytes convert through enum_word.member_of_word at one border so
// unknown opcodes are refused instead of cast to undefined members.
package ssh_client

import "modus:contract/byte_order"
import "modus:contract/enum_word"

CLIENT_BANNER :: "SSH-2.0-modus"
MAX_BANNER_LENGTH :: 255
MAX_PRE_BANNER_LINES :: 16
MAX_PACKET_LENGTH :: 35000
MIN_PADDING_LENGTH :: 4
CIPHER_BLOCK_SIZE :: 8
POLY1305_TAG_SIZE :: 16
CHACHA20_POLY1305_KEY_SIZE :: 64
X25519_KEY_SIZE :: 32
ED25519_PUBLIC_KEY_SIZE :: 32
ED25519_PRIVATE_KEY_SIZE :: 32
ED25519_SIGNATURE_SIZE :: 64
SHA256_DIGEST_SIZE :: 32
COOKIE_SIZE :: 16

// Rekey well before the 32-bit SSH packet sequence counter wraps so no nonce repeats.
REKEY_PACKET_LIMIT :: u32(1) << 30

// Single strict modern algorithm suite supported by the client.
ALG_KEX :: "curve25519-sha256"
ALG_HOST_KEY :: "ssh-ed25519"
ALG_CIPHER :: "chacha20-poly1305@openssh.com"
ALG_MAC_IMPLICIT :: "none"
ALG_COMPRESSION :: "none"

// SSH-2 transport, userauth, and connection protocol message numbers (RFC 4253, 4252, 4254).
Message_Type :: enum u8 {
	Disconnect                = 1,
	Ignore                    = 2,
	Unimplemented             = 3,
	Debug                     = 4,
	Service_Request           = 5,
	Service_Accept            = 6,
	Kexinit                   = 20,
	Newkeys                   = 21,
	Kex_Ecdh_Init             = 30,
	Kex_Ecdh_Reply            = 31,
	Userauth_Request          = 50,
	Userauth_Failure          = 51,
	Userauth_Success          = 52,
	Userauth_Banner           = 53,
	Userauth_Pk_Ok            = 60,
	Global_Request            = 80,
	Channel_Open              = 90,
	Channel_Open_Confirmation = 91,
	Channel_Open_Failure      = 92,
	Channel_Window_Adjust     = 93,
	Channel_Data              = 94,
	Channel_Extended_Data     = 95,
	Channel_Eof               = 96,
	Channel_Close             = 97,
	Channel_Request           = 98,
	Channel_Success           = 99,
	Channel_Failure           = 100,
}

// Explicit refusal and completion status for SSH operations.
Status :: enum u8 {
	Ok                 = 0,
	Invalid_Argument   = 1,
	Buffer_Too_Small   = 2,
	Truncated          = 3,
	Oversized_Packet   = 4,
	Bad_Padding        = 5,
	Bad_Banner         = 6,
	Algorithm_Mismatch = 7,
	Unknown_Host_Key   = 8,
	Host_Key_Mismatch  = 9,
	Bad_Host_Signature = 10,
	Bad_Kex_Point      = 11,
	Not_Authentic      = 12,
	Unexpected_Message = 13,
	Bad_State          = 14,
	Rekey_Required     = 15,
	Auth_Failed        = 16,
	Channel_Rejected   = 17,
	Window_Exceeded    = 18,
	Crypto_Error       = 19,
	Table_Full         = 20,
}

// message_type_of_byte converts a wire message type byte at the protocol border.
message_type_of_byte :: proc "contextless" (wire_byte: u8) -> (member: Message_Type, ok: bool) {
	return enum_word.member_of_word(Message_Type, u64(wire_byte))
}

// Bounded encoder into a caller-provided slice.
Packet_Encoder :: struct {
	buffer: []u8,
	offset: int,
}

encoder_init :: proc "contextless" (buffer: []u8) -> Packet_Encoder {
	return Packet_Encoder{buffer = buffer, offset = 0}
}

encoder_bytes :: proc "contextless" (enc: ^Packet_Encoder) -> []u8 {
	return enc.buffer[:enc.offset]
}

encode_byte :: proc "contextless" (enc: ^Packet_Encoder, value: u8) -> bool {
	if enc.offset + 1 > len(enc.buffer) {
		return false
	}
	enc.buffer[enc.offset] = value
	enc.offset += 1
	return true
}

encode_bool :: proc "contextless" (enc: ^Packet_Encoder, value: bool) -> bool {
	return encode_byte(enc, value ? 1 : 0)
}

encode_u32 :: proc "contextless" (enc: ^Packet_Encoder, value: u32) -> bool {
	if enc.offset + 4 > len(enc.buffer) {
		return false
	}
	byte_order.write_u32_big_endian(enc.buffer, enc.offset, value)
	enc.offset += 4
	return true
}

encode_raw :: proc "contextless" (enc: ^Packet_Encoder, data: []u8) -> bool {
	if len(data) > len(enc.buffer) - enc.offset {
		return false
	}
	copy(enc.buffer[enc.offset:], data)
	enc.offset += len(data)
	return true
}

encode_ssh_bytes :: proc "contextless" (enc: ^Packet_Encoder, data: []u8) -> bool {
	if len(data) > int(max(u32)) {
		return false
	}
	if !encode_u32(enc, u32(len(data))) {
		return false
	}
	return encode_raw(enc, data)
}

encode_ssh_string :: proc "contextless" (enc: ^Packet_Encoder, text: string) -> bool {
	return encode_ssh_bytes(enc, transmute([]u8)text)
}

// encode_mpint writes an unsigned big-endian integer in SSH mpint format (RFC 4251, section 5):
// leading zero bytes are stripped, zero encodes as length 0, and a leading 0x00 is prepended
// when the most significant bit of the first non-zero byte is set.
encode_mpint :: proc "contextless" (enc: ^Packet_Encoder, big_endian_unsigned: []u8) -> bool {
	start := 0
	for start < len(big_endian_unsigned) && big_endian_unsigned[start] == 0 {
		start += 1
	}
	trimmed := big_endian_unsigned[start:]
	if len(trimmed) == 0 {
		return encode_u32(enc, 0)
	}
	needs_zero_prefix := (trimmed[0] & 0x80) != 0
	total := len(trimmed) + (needs_zero_prefix ? 1 : 0)
	if !encode_u32(enc, u32(total)) {
		return false
	}
	if needs_zero_prefix {
		if !encode_byte(enc, 0) {
			return false
		}
	}
	return encode_raw(enc, trimmed)
}

// Bounded decoder over a caller-provided slice.
Packet_Decoder :: struct {
	buffer: []u8,
	offset: int,
}

decoder_init :: proc "contextless" (buffer: []u8) -> Packet_Decoder {
	return Packet_Decoder{buffer = buffer, offset = 0}
}

decoder_remaining :: proc "contextless" (dec: ^Packet_Decoder) -> int {
	return len(dec.buffer) - dec.offset
}

decode_byte :: proc "contextless" (dec: ^Packet_Decoder) -> (value: u8, ok: bool) {
	if dec.offset + 1 > len(dec.buffer) {
		return 0, false
	}
	value = dec.buffer[dec.offset]
	dec.offset += 1
	return value, true
}

decode_bool :: proc "contextless" (dec: ^Packet_Decoder) -> (value: bool, ok: bool) {
	b, b_ok := decode_byte(dec)
	if !b_ok {
		return false, false
	}
	return b != 0, true
}

decode_u32 :: proc "contextless" (dec: ^Packet_Decoder) -> (value: u32, ok: bool) {
	if dec.offset + 4 > len(dec.buffer) {
		return 0, false
	}
	value = byte_order.read_u32_big_endian(dec.buffer, dec.offset)
	dec.offset += 4
	return value, true
}

decode_raw :: proc "contextless" (dec: ^Packet_Decoder, count: int) -> (slice: []u8, ok: bool) {
	if count < 0 || count > len(dec.buffer) - dec.offset {
		return nil, false
	}
	slice = dec.buffer[dec.offset : dec.offset + count]
	dec.offset += count
	return slice, true
}

decode_ssh_bytes :: proc "contextless" (dec: ^Packet_Decoder) -> (slice: []u8, ok: bool) {
	length, length_ok := decode_u32(dec)
	if !length_ok {
		return nil, false
	}
	if int(length) > len(dec.buffer) - dec.offset {
		return nil, false
	}
	return decode_raw(dec, int(length))
}

// name_list_contains checks whether a comma-separated SSH name-list contains target as a whole token.
name_list_contains :: proc "contextless" (list_bytes: []u8, target: string) -> bool {
	if len(target) == 0 || len(list_bytes) == 0 {
		return false
	}
	target_bytes := transmute([]u8)target
	start := 0
	for i := 0; i <= len(list_bytes); i += 1 {
		if i == len(list_bytes) || list_bytes[i] == ',' {
			token := list_bytes[start:i]
			if bytes_equal(token, target_bytes) {
				return true
			}
			start = i + 1
		}
	}
	return false
}

// bytes_equal compares two byte slices of non-secret data.
bytes_equal :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
