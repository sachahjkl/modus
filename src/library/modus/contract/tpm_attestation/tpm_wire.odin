// The wire form of TPM2_PolicyAuthorize and TPM2_HierarchyChangeAuth, and
// the read of the header of an answer (TCG TPM 2.0 Library, part 3:
// Commands). A signed policy of the machine key needs the first
// (src/md/features/rollback_floors.md, "Built and left"); an authorization
// value of the owner hierarchy, which keeps the floors and the pins against
// code with the TPM, needs the second.
//
// Each number is big-endian. An encoder checks each argument and the size
// of the buffer before it writes a byte, so a refused call leaves the
// buffer as it was. A decoder takes the bytes from a device: it checks each
// size against the bytes that it holds before a use.
package tpm_attestation

import "modus:contract/byte_order"
import "modus:contract/enum_word"

COMMAND_HIERARCHY_CHANGE_AUTH :: u32(0x0000_0129)

TPM_RC_SUCCESS :: u32(0)

// The bytes of the header of a command and of an answer: tag, size, code.
TPM_HEADER_SIZE :: 10

// The tag of a verified ticket (TPM_ST_VERIFIED).
TPM_ST_VERIFIED :: u16(0x8022)

// The handle of the password session (TPM_RS_PW).
TPM_RS_PW :: u32(0x4000_0009)

// The kind byte of the handle of a policy session (TPM_HT_POLICY_SESSION).
HANDLE_KIND_POLICY_SESSION :: u32(0x03)

// The bytes of a name of a key of SHA-256: the algorithm, then the digest.
KEY_NAME_SIZE :: 2 + SHA256_SIZE

// The largest authorization value and policy reference that the TPM takes
// with SHA-256: the size of its digest.
AUTHORIZATION_LIMIT :: SHA256_SIZE
POLICY_REFERENCE_LIMIT :: SHA256_SIZE

// The bytes of a successful answer of TPM2_HierarchyChangeAuth: the header,
// the size of the parameters (0), and the answer of one password session
// (an empty nonce, the attributes, an empty HMAC).
HIERARCHY_CHANGE_AUTH_ANSWER_SIZE :: TPM_HEADER_SIZE + 4 + 2 + 1 + 2

// The tag of a command or an answer (TPM_ST).
Response_Tag :: enum u16 {
	No_Sessions = 0x8001,
	Sessions    = 0x8002,
}

// The hierarchies whose authorization value TPM2_HierarchyChangeAuth
// changes (TPMI_RH_HIERARCHY_AUTH).
Hierarchy :: enum u32 {
	Owner       = 0x4000_0001,
	Lockout     = 0x4000_000A,
	Endorsement = 0x4000_000B,
	Platform    = 0x4000_000C,
}

// The hierarchy of a verified ticket. The null hierarchy is left out: a
// ticket of it proves nothing, and TPM2_PolicyAuthorize refuses it.
Ticket_Hierarchy :: enum u32 {
	Owner       = 0x4000_0001,
	Endorsement = 0x4000_000B,
	Platform    = 0x4000_000C,
}

// The ticket of TPM2_VerifySignature that proves that the key of the name
// signed the approved policy (TPMT_TK_VERIFIED). The tag is fixed, so it is
// not a field.
Verified_Ticket :: struct {
	hierarchy: Ticket_Hierarchy,
	digest:    Digest,
}

// The header of an answer.
Response_Header :: struct {
	tag:  Response_Tag,
	size: u32,
	code: u32,
}

// The refusals of an encoder and of a decoder of this file.
Wire_Refusal :: enum u8 {
	None                       = 0,
	Buffer_Too_Small           = 1,
	Handle_Not_Policy_Session  = 2,
	Zero_Approved_Policy       = 3,
	Policy_Reference_Too_Large = 4,
	Key_Name_Malformed         = 5,
	Zero_Ticket_Digest         = 6,
	Authorization_Too_Large    = 7,
	Empty_Authorization        = 8,
	Zero_Authorization         = 9,
	Response_Truncated         = 10,
	Response_Tag_Unknown       = 11,
	Response_Size_Mismatch     = 12,
	Response_Malformed         = 13,
	Response_Error             = 14,
}

// hierarchy_of_word is the border of a hierarchy handle that a client or a
// record gives.
hierarchy_of_word :: proc "contextless" (word: u64) -> (hierarchy: Hierarchy, ok: bool) {
	return enum_word.member_of_word(Hierarchy, word)
}

// ticket_hierarchy_of_word is the border of the hierarchy of a ticket that
// an answer gives.
ticket_hierarchy_of_word :: proc "contextless" (word: u64) -> (hierarchy: Ticket_Hierarchy, ok: bool) {
	return enum_word.member_of_word(Ticket_Hierarchy, word)
}

// response_tag_of_word is the border of the tag of an answer.
response_tag_of_word :: proc "contextless" (word: u64) -> (tag: Response_Tag, ok: bool) {
	return enum_word.member_of_word(Response_Tag, word)
}

// A writer that never checks a bound: its caller checked the whole size.
@(private = "file")
Wire_Writer :: struct {
	bytes: []u8,
	place: int,
}

@(private = "file")
put_u8 :: proc "contextless" (writer: ^Wire_Writer, value: u8) {
	writer.bytes[writer.place] = value
	writer.place += 1
}

@(private = "file")
put_u16 :: proc "contextless" (writer: ^Wire_Writer, value: u16) {
	byte_order.write_u16_big_endian(writer.bytes, writer.place, value)
	writer.place += 2
}

@(private = "file")
put_u32 :: proc "contextless" (writer: ^Wire_Writer, value: u32) {
	byte_order.write_u32_big_endian(writer.bytes, writer.place, value)
	writer.place += 4
}

@(private = "file")
put_sized :: proc "contextless" (writer: ^Wire_Writer, data: []u8) {
	put_u16(writer, u16(len(data)))
	copy(writer.bytes[writer.place:], data)
	writer.place += len(data)
}

@(private = "file")
put_header :: proc "contextless" (writer: ^Wire_Writer, tag: Response_Tag, size: int, command: u32) {
	put_u16(writer, u16(tag))
	put_u32(writer, u32(size))
	put_u32(writer, command)
}

// policy_authorize_size gives the bytes of TPM2_PolicyAuthorize with a
// policy reference of reference_size bytes.
policy_authorize_size :: proc "contextless" (reference_size: int) -> int {
	return TPM_HEADER_SIZE + 4 + (2 + SHA256_SIZE) + (2 + reference_size) + (2 + KEY_NAME_SIZE) + (2 + 4 + 2 + SHA256_SIZE)
}

// encode_policy_authorize builds TPM2_PolicyAuthorize. The command needs no
// authorization session: the TPM checks the ticket against the name of the
// key and the approved policy, then replaces the digest of the session
// with the authorized policy. The name is of a SHA-256 key, as each digest
// of this system.
encode_policy_authorize :: proc "contextless" (
	session_handle: u32,
	approved_policy: Digest,
	policy_ref: []u8,
	key_sign_name: []u8,
	check_ticket: Verified_Ticket,
	out: []u8,
) -> (count: int, refusal: Wire_Refusal) {
	if session_handle >> 24 != HANDLE_KIND_POLICY_SESSION {
		return 0, .Handle_Not_Policy_Session
	}
	approved := approved_policy
	if is_all_zero(approved[:]) {
		return 0, .Zero_Approved_Policy
	}
	if len(policy_ref) > POLICY_REFERENCE_LIMIT {
		return 0, .Policy_Reference_Too_Large
	}
	if len(key_sign_name) != KEY_NAME_SIZE ||
	   byte_order.read_u16_big_endian(key_sign_name, 0) != TPM_ALG_SHA256 ||
	   is_all_zero(key_sign_name[2:]) {
		return 0, .Key_Name_Malformed
	}
	ticket_digest := check_ticket.digest
	if is_all_zero(ticket_digest[:]) {
		return 0, .Zero_Ticket_Digest
	}
	size := policy_authorize_size(len(policy_ref))
	if len(out) < size {
		return 0, .Buffer_Too_Small
	}
	writer := Wire_Writer{bytes = out[:size]}
	put_header(&writer, .No_Sessions, size, COMMAND_POLICY_AUTHORIZE)
	put_u32(&writer, session_handle)
	put_sized(&writer, approved[:])
	put_sized(&writer, policy_ref)
	put_sized(&writer, key_sign_name)
	put_u16(&writer, TPM_ST_VERIFIED)
	put_u32(&writer, u32(check_ticket.hierarchy))
	put_sized(&writer, ticket_digest[:])
	return size, .None
}

// hierarchy_change_auth_size gives the bytes of TPM2_HierarchyChangeAuth.
hierarchy_change_auth_size :: proc "contextless" (current_size: int, new_size: int) -> int {
	return TPM_HEADER_SIZE + 4 + 4 + (4 + 2 + 1 + 2 + current_size) + (2 + new_size)
}

// encode_hierarchy_change_auth builds TPM2_HierarchyChangeAuth, with the
// current value of the hierarchy in a password session. An empty new value
// is refused: it would remove the value that keeps the hierarchy. A value
// of zeros is refused too: it is the output of a broken generator, and a
// value that the code of another system guesses.
encode_hierarchy_change_auth :: proc "contextless" (
	auth_handle: Hierarchy,
	current_auth: []u8,
	new_auth: []u8,
	out: []u8,
) -> (count: int, refusal: Wire_Refusal) {
	if len(current_auth) > AUTHORIZATION_LIMIT || len(new_auth) > AUTHORIZATION_LIMIT {
		return 0, .Authorization_Too_Large
	}
	if len(new_auth) == 0 {
		return 0, .Empty_Authorization
	}
	if is_all_zero(new_auth) {
		return 0, .Zero_Authorization
	}
	size := hierarchy_change_auth_size(len(current_auth), len(new_auth))
	if len(out) < size {
		return 0, .Buffer_Too_Small
	}
	writer := Wire_Writer{bytes = out[:size]}
	put_header(&writer, .Sessions, size, COMMAND_HIERARCHY_CHANGE_AUTH)
	put_u32(&writer, u32(auth_handle))
	put_u32(&writer, u32(4 + 2 + 1 + 2 + len(current_auth)))
	put_u32(&writer, TPM_RS_PW)
	put_u16(&writer, 0) // No nonce.
	put_u8(&writer, 0) // No attribute.
	put_sized(&writer, current_auth)
	put_sized(&writer, new_auth)
	return size, .None
}

// decode_tpm_response_header reads the header of an answer. The size must
// be the bytes given. A failure answer is the header alone, with the tag
// of no sessions (TPM 2.0 part 1, "Response Code Details"): another form
// is refused as malformed. A failure gives its code with Response_Error.
decode_tpm_response_header :: proc "contextless" (response: []u8) -> (header: Response_Header, refusal: Wire_Refusal) {
	if len(response) < TPM_HEADER_SIZE {
		return {}, .Response_Truncated
	}
	tag, tag_ok := response_tag_of_word(u64(byte_order.read_u16_big_endian(response, 0)))
	if !tag_ok {
		return {}, .Response_Tag_Unknown
	}
	size := byte_order.read_u32_big_endian(response, 2)
	if u64(size) != u64(len(response)) {
		return {}, .Response_Size_Mismatch
	}
	header = {tag = tag, size = size, code = byte_order.read_u32_big_endian(response, 6)}
	if header.code != TPM_RC_SUCCESS {
		if tag != .No_Sessions || size != TPM_HEADER_SIZE {
			return {}, .Response_Malformed
		}
		return header, .Response_Error
	}
	return header, .None
}

// decode_policy_authorize_response reads the answer of
// TPM2_PolicyAuthorize: the header alone.
decode_policy_authorize_response :: proc "contextless" (response: []u8) -> (code: u32, refusal: Wire_Refusal) {
	header: Response_Header
	header, refusal = decode_tpm_response_header(response)
	if refusal != .None {
		return header.code, refusal
	}
	if header.tag != .No_Sessions || header.size != TPM_HEADER_SIZE {
		return header.code, .Response_Malformed
	}
	return header.code, .None
}

// decode_hierarchy_change_auth_response reads the answer of
// TPM2_HierarchyChangeAuth: no parameter, and the answer of the password
// session with no nonce and no HMAC.
decode_hierarchy_change_auth_response :: proc "contextless" (response: []u8) -> (code: u32, refusal: Wire_Refusal) {
	header: Response_Header
	header, refusal = decode_tpm_response_header(response)
	if refusal != .None {
		return header.code, refusal
	}
	if header.tag != .Sessions || header.size != HIERARCHY_CHANGE_AUTH_ANSWER_SIZE {
		return header.code, .Response_Malformed
	}
	parameter_size := byte_order.read_u32_big_endian(response, TPM_HEADER_SIZE)
	nonce_size := byte_order.read_u16_big_endian(response, TPM_HEADER_SIZE + 4)
	hmac_size := byte_order.read_u16_big_endian(response, TPM_HEADER_SIZE + 4 + 2 + 1)
	if parameter_size != 0 || nonce_size != 0 || hmac_size != 0 {
		return header.code, .Response_Malformed
	}
	return header.code, .None
}
