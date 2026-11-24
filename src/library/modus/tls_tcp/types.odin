// TLS 1.3 over TCP (RFC 8446) types, closed enumerations, and wire borders.
// Pure freestanding code with zero allocations.
package tls_tcp

import "base:intrinsics"
import "modus:contract/enum_word"

// RFC 8446 record layer limits.
RECORD_HEADER_SIZE :: 5
MAX_PLAINTEXT_SIZE :: 16384 // 2^14 bytes maximum TLSPlaintext fragment length.
MAX_CIPHERTEXT_SIZE :: MAX_PLAINTEXT_SIZE + 256 // 16640 bytes maximum TLSCiphertext length.
AEAD_TAG_SIZE :: 16
NONCE_SIZE :: 12
HASH_SIZE :: 32
X25519_KEY_SIZE :: 32
ED25519_KEY_SIZE :: 32
ED25519_SIGNATURE_SIZE :: 64
ED25519_SPKI_SIZE :: 44 // 12-byte DER SubjectPublicKeyInfo prefix + 32-byte public key.
HANDSHAKE_HEADER_SIZE :: 4
MAX_SERVER_NAME_LEN :: 255
// Format property: RFC 8446 practical multi-record handshake message bound
// (65535 bytes) covering real-world X.509 certificate chains.
MAX_HANDSHAKE_REASSEMBLY :: 65535
// Computed: holds one maximum-size handshake message (e.g. Certificate chain)
// plus up to 8 KiB for ClientHello, ServerHello, EncryptedExtensions,
// CertificateVerify, and Finished.
MAX_TRANSCRIPT_SIZE :: MAX_HANDSHAKE_REASSEMBLY + 8192
MAX_WIRE_BUFFER :: 20480
MAX_APP_BUFFER :: 16384

// Wire protocol constants (values > 255).
TLS_LEGACY_VERSION :: u16(0x0303)
TLS_LEGACY_CLIENT_HELLO_RECORD_VERSION :: u16(0x0301)
TLS_VERSION_1_3 :: u16(0x0304)
NAMED_GROUP_X25519 :: u16(0x001D)
SIGNATURE_SCHEME_ED25519 :: u16(0x0807)

// DER SubjectPublicKeyInfo prefix for an Ed25519 public key (RFC 8410).
@(rodata)
ED25519_SPKI_PREFIX := [12]u8{0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00}

// RFC 8446 HelloRetryRequest fixed Random value.
@(rodata)
HELLO_RETRY_REQUEST_RANDOM := [32]u8{
	0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11,
	0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
	0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
	0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
}

// RFC 8446 section 4.1.3 downgrade detection sentinels in ServerHello.random[24..32].
@(rodata)
TLS12_DOWNGRADE_SENTINEL := [8]u8{0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44, 0x01}

@(rodata)
TLS11_DOWNGRADE_SENTINEL := [8]u8{0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44, 0x00}

// X25519 standard basepoint u = 9 (RFC 7748).
@(rodata)
X25519_BASEPOINT := [32]u8{9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

// Role of a TLS endpoint. Zero is invalid and refused at the border.
Tls_Role :: enum u8 {
	Client = 1,
	Server = 2,
}

// Handshake and session state machine.
Tls_State :: enum u8 {
	Initial                          = 0,
	Client_Wait_Server_Hello         = 1,
	Client_Wait_Encrypted_Extensions = 2,
	Client_Wait_Certificate          = 3,
	Client_Wait_Certificate_Verify   = 4,
	Client_Wait_Finished             = 5,
	Server_Wait_Client_Hello         = 6,
	Server_Wait_Client_Finished      = 7,
	Connected                        = 8,
	Closed                           = 9,
	Failed                           = 10,
}

// RFC 8446 record layer ContentType values.
Tls_Content_Type :: enum u8 {
	Change_Cipher_Spec = 20,
	Alert              = 21,
	Handshake          = 22,
	Application_Data   = 23,
}

// Supported TLS 1.3 cipher suites (RFC 8446 appendix B.4).
Tls_Cipher_Suite :: enum u16 {
	TLS_AES_128_GCM_SHA256       = 0x1301,
	TLS_CHACHA20_POLY1305_SHA256 = 0x1303,
}

// RFC 8446 handshake message types.
Tls_Handshake_Type :: enum u8 {
	Client_Hello         = 1,
	Server_Hello         = 2,
	New_Session_Ticket   = 4,
	Encrypted_Extensions = 8,
	Certificate          = 11,
	Certificate_Verify   = 15,
	Finished             = 20,
	Key_Update           = 24,
}

// RFC 8446 alert levels.
Tls_Alert_Level :: enum u8 {
	Warning = 1,
	Fatal   = 2,
}

// RFC 8446 alert descriptions.
Tls_Alert_Description :: enum u8 {
	Close_Notify            = 0,
	Unexpected_Message      = 10,
	Bad_Record_Mac          = 20,
	Record_Overflow         = 22,
	Handshake_Failure       = 40,
	Bad_Certificate         = 42,
	Unsupported_Certificate = 43,
	Illegal_Parameter       = 47,
	Decode_Error            = 50,
	Decrypt_Error           = 51,
	Protocol_Version        = 70,
	Internal_Error          = 80,
	Missing_Extension       = 109,
	Unsupported_Extension   = 110,
}

// RFC 8446 extension identifiers handled by this implementation.
Tls_Extension_Type :: enum u16 {
	Server_Name          = 0,
	Supported_Groups     = 10,
	Signature_Algorithms = 13,
	Supported_Versions   = 43,
	Key_Share            = 51,
}

// Refusal reasons returned by TLS operations.
Tls_Refusal :: enum u8 {
	None                         = 0,
	Invalid_Role                 = 1,
	Invalid_Configuration        = 2,
	Invalid_State                = 3,
	Invalid_Content_Type         = 4,
	Invalid_Cipher_Suite         = 5,
	Record_Header_Incomplete     = 6,
	Record_Incomplete            = 7,
	Record_Too_Large             = 8,
	Invalid_Legacy_Version       = 9,
	Sequence_Exhausted           = 10,
	Authentication_Failed        = 11,
	Inner_Content_Missing        = 12,
	Handshake_Incomplete         = 13,
	Unexpected_Handshake_Message = 14,
	Downgrade_Refused            = 15,
	Unsupported_Cipher_Suite     = 16,
	Missing_Required_Extension   = 17,
	Duplicate_Extension          = 18,
	Invalid_Key_Share            = 19,
	Invalid_Certificate          = 20,
	Invalid_Certificate_Verify   = 21,
	Invalid_Finished             = 22,
	Malformed_Message            = 23,
	Buffer_Too_Small             = 24,
	Transcript_Full              = 25,
	Crypto_Failed                = 26,
	Peer_Closed                  = 27,
	Peer_Alert                   = 28,
}

// Strict wire-to-enum borders.

tls_role_of_word :: proc "contextless" (word: u8) -> (role: Tls_Role, ok: bool) {
	return enum_word.member_of_word(Tls_Role, u64(word))
}

content_type_of_word :: proc "contextless" (word: u8) -> (ct: Tls_Content_Type, ok: bool) {
	return enum_word.member_of_word(Tls_Content_Type, u64(word))
}

cipher_suite_of_word :: proc "contextless" (word: u16) -> (suite: Tls_Cipher_Suite, ok: bool) {
	return enum_word.member_of_word(Tls_Cipher_Suite, u64(word))
}

handshake_type_of_word :: proc "contextless" (word: u8) -> (ht: Tls_Handshake_Type, ok: bool) {
	return enum_word.member_of_word(Tls_Handshake_Type, u64(word))
}

alert_level_of_word :: proc "contextless" (word: u8) -> (level: Tls_Alert_Level, ok: bool) {
	return enum_word.member_of_word(Tls_Alert_Level, u64(word))
}

alert_description_of_word :: proc "contextless" (word: u8) -> (desc: Tls_Alert_Description, ok: bool) {
	return enum_word.member_of_word(Tls_Alert_Description, u64(word))
}

extension_type_of_word :: proc "contextless" (word: u16) -> (ext: Tls_Extension_Type, ok: bool) {
	return enum_word.member_of_word(Tls_Extension_Type, u64(word))
}

// cipher_suite_key_size returns the AEAD key length in bytes for a validated cipher suite.
cipher_suite_key_size :: proc "contextless" (suite: Tls_Cipher_Suite) -> int {
	switch suite {
	case .TLS_AES_128_GCM_SHA256:
		return 16
	case .TLS_CHACHA20_POLY1305_SHA256:
		return 32
	}
	return 0
}

// erase_bytes clears sensitive key material using volatile writes so the compiler retains the wipe.
erase_bytes :: proc "contextless" (buf: []u8) {
	for i := 0; i < len(buf); i += 1 {
		intrinsics.volatile_store(&buf[i], 0)
	}
}

// constant_time_equal compares two byte slices without early exit on mismatch.
@(optimization_mode = "none")
constant_time_equal :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	diff: u8 = 0
	for i := 0; i < len(a); i += 1 {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

// is_all_zero checks whether every byte in a slice is zero.
is_all_zero :: proc "contextless" (buf: []u8) -> bool {
	acc: u8 = 0
	for b in buf {
		acc |= b
	}
	return acc == 0
}
