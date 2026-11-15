// The commands of TPM 2.0 that the TPM service sends, and the reads of their
// answers (TCG TPM 2.0 Library, part 3: Commands). The service seals a key
// to the values of PCR 7 and PCR 11 of the TPM, and unseals it
// (src/md/features/tpm_sealed_machine_key.md).
//
// Each number of a command and of an answer is big-endian. A procedure that
// builds a command writes it in the buffer of its caller and gives its
// bytes; 0 when it does not fit. A procedure that reads an answer copies no
// byte that it did not check: an answer comes from a device, and its sizes
// are checked against the bytes that came before each use.
//
// No allocator and no kernel operation: the host tests build each command
// and compare it with its bytes, and read answers that the tests build
// (tpm2_test.odin).
//
// A sealed object proves where it comes from: TPM2_Create gives its
// creation data (the digest of PCR 7 and PCR 11 at the creation) and a
// creation ticket, an HMAC of the TPM over the hash of the creation data
// and the name of the object. TPM2_CertifyCreation checks the ticket, and
// sealed_public_check checks that the policy of the object is the policy
// of those PCR values. So an object that another system made on this TPM,
// with the policy of this system, is refused: its creation data names the
// PCRs of that other system.
//
// See [TPM service](term:tpm-service) and
// [sealed by the TPM](term:sealed-by-the-tpm).
package tpm2

import "base:runtime"
import "modus:support/cryptography/sha2"

// The tags of a command and of an answer.
TAG_NO_SESSIONS :: u16(0x8001)
TAG_SESSIONS :: u16(0x8002)

// The tag of a creation ticket (TPM_ST_CREATION).
TAG_CREATION :: u16(0x8021)

// The codes of the commands that the service sends.
COMMAND_CERTIFY_CREATION :: u32(0x0000_014A)
COMMAND_CREATE_PRIMARY :: u32(0x0000_0131)
COMMAND_CREATE :: u32(0x0000_0153)
COMMAND_LOAD :: u32(0x0000_0157)
COMMAND_UNSEAL :: u32(0x0000_015E)
COMMAND_FLUSH_CONTEXT :: u32(0x0000_0165)
COMMAND_START_AUTH_SESSION :: u32(0x0000_0176)
COMMAND_POLICY_PCR :: u32(0x0000_017F)
COMMAND_POLICY_GET_DIGEST :: u32(0x0000_0189)

// The handles that the TPM defines.
HANDLE_OWNER :: u32(0x4000_0001) // The owner hierarchy: the parent of the storage key.
HANDLE_NULL :: u32(0x4000_0007) // No key and no bind for a session.
HANDLE_PASSWORD :: u32(0x4000_0009) // The session of a password: here, the empty password of the owner and of the storage key.

// The algorithms.
ALGORITHM_AES :: u16(0x0006)
ALGORITHM_KEYED_HASH :: u16(0x0008)
ALGORITHM_SHA256 :: u16(0x000B)
ALGORITHM_NULL :: u16(0x0010)
ALGORITHM_ECC :: u16(0x0023)
ALGORITHM_CFB :: u16(0x0043)
CURVE_NIST_P256 :: u16(0x0003)

// The kinds of a session.
SESSION_POLICY :: u8(0x01)
SESSION_TRIAL :: u8(0x03)

// The attributes of an object (part 2, TPMA_OBJECT).
ATTRIBUTE_FIXED_TPM :: u32(1 << 1)
ATTRIBUTE_FIXED_PARENT :: u32(1 << 4)
ATTRIBUTE_SENSITIVE_DATA_ORIGIN :: u32(1 << 5)
ATTRIBUTE_USER_WITH_AUTH :: u32(1 << 6)
ATTRIBUTE_ADMIN_WITH_POLICY :: u32(1 << 7)
ATTRIBUTE_NO_DICTIONARY_ATTACK :: u32(1 << 10)
ATTRIBUTE_RESTRICTED :: u32(1 << 16)
ATTRIBUTE_DECRYPT :: u32(1 << 17)

// The storage key: a restricted decryption key, made from the seed of the
// owner hierarchy at each command. The template is fixed, so each start
// gives the same key, and the TPM keeps no key for the system.
STORAGE_KEY_ATTRIBUTES :: ATTRIBUTE_FIXED_TPM | ATTRIBUTE_FIXED_PARENT | ATTRIBUTE_SENSITIVE_DATA_ORIGIN | ATTRIBUTE_USER_WITH_AUTH | ATTRIBUTE_NO_DICTIONARY_ATTACK | ATTRIBUTE_RESTRICTED | ATTRIBUTE_DECRYPT
// The sealed object: userWithAuth is clear, so only a policy session that
// satisfies its policy reads it; adminWithPolicy is set, so the role of
// the administrator (a change of its authorization value) needs the policy
// too; a failed policy is no try of a password, so the object does not
// count for the lockout of the TPM.
SEALED_OBJECT_ATTRIBUTES :: ATTRIBUTE_FIXED_TPM | ATTRIBUTE_FIXED_PARENT | ATTRIBUTE_ADMIN_WITH_POLICY | ATTRIBUTE_NO_DICTIONARY_ATTACK

// The session attribute continueSession: the session stays after the
// command, and the service flushes it itself, after a success as after a
// failure.
SESSION_CONTINUE :: u8(0x01)

// The bytes of a digest of SHA-256, of a sealed secret, and of the nonce
// of a session.
DIGEST_SIZE :: 32
SECRET_SIZE :: 32
NONCE_SIZE :: 16

// The PCRs of the policy: PCR 7 (the state of Secure Boot) and PCR 11 (the
// measure of the system description), as the bit map of the SHA-256 bank:
// bit n of byte n / 8 is PCR n.
PCR_SELECTION :: [3]u8{0x80, 0x08, 0x00}
PCR_SET :: u32(1 << 7 | 1 << 11) // The same PCRs, as one number: bit n is PCR n.

// The largest areas of a sealed object that the record of a key keeps, with
// their size field. A TPM with SHA-256 gives 82 bytes of the public area
// and about 130 of the private area; a larger answer is refused.
PUBLIC_AREA_LIMIT :: 128
PRIVATE_AREA_LIMIT :: 256
// The creation data of a sealed object, with its size field: 123 bytes with
// SHA-256 (swtpm). The creation ticket: its tag, its hierarchy, and a
// digest of the hash that the TPM chose for its HMAC, not of the object:
// swtpm (libtpms) gives 64 bytes of SHA-512, so 72 bytes in all. The limit
// takes the largest digest of a TPM, 64 bytes.
CREATION_DATA_LIMIT :: 256
TICKET_DIGEST_LIMIT :: 64
CREATION_TICKET_LIMIT :: 2 + 4 + 2 + TICKET_DIGEST_LIMIT // 72.

// The response codes that the service names in its log.
RESPONSE_SUCCESS :: u32(0)
// Bit 7 of a code says that it has the format 1: its bits 0 to 5 are the
// error, and bits 8 to 11 name the handle, the session or the parameter.
RESPONSE_FORMAT_ONE :: u32(0x080)
RESPONSE_POLICY_FAIL :: u32(0x01D) // The error of a format 1 code: the policy does not hold.

RESPONSE_TICKET :: u32(0x020) // The error of a format 1 code: the ticket is not the HMAC of this TPM.

// policy_fails says if a response code says that the policy of the object
// does not hold: the values of the PCRs differ from the values of the seal.
policy_fails :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & 0x3F == RESPONSE_POLICY_FAIL
}

// ticket_fails says if a response code says that a ticket is not the HMAC
// of this TPM over what it names (TPM_RC_TICKET): another code, as a lack
// of memory of the TPM, says nothing of the record.
ticket_fails :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & 0x3F == RESPONSE_TICKET
}

// The bytes of one command, in a buffer of the caller. A write past its end
// marks it as overflowed, and the command gives 0 bytes.
Command_Writer :: struct {
	buffer:     []u8,
	count:      int,
	overflowed: bool,
}

@(private)
put_bytes :: proc "contextless" (command_writer: ^Command_Writer, bytes: []u8) {
	if command_writer.overflowed || len(bytes) > len(command_writer.buffer) - command_writer.count {
		command_writer.overflowed = true
		return
	}
	copy(command_writer.buffer[command_writer.count:], bytes)
	command_writer.count += len(bytes)
}

@(private)
put_u8 :: proc "contextless" (command_writer: ^Command_Writer, value: u8) {
	bytes := [1]u8{value}
	put_bytes(command_writer, bytes[:])
}

@(private)
put_u16 :: proc "contextless" (command_writer: ^Command_Writer, value: u16) {
	bytes := [2]u8{u8(value >> 8), u8(value)}
	put_bytes(command_writer, bytes[:])
}

@(private)
put_u32 :: proc "contextless" (command_writer: ^Command_Writer, value: u32) {
	bytes := [4]u8{u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}
	put_bytes(command_writer, bytes[:])
}

// put_sized puts a sized buffer of the TPM (a TPM2B): its bytes as a u16,
// then the bytes.
@(private)
put_sized :: proc "contextless" (command_writer: ^Command_Writer, bytes: []u8) {
	if len(bytes) > 0xFFFF {
		command_writer.overflowed = true
		return
	}
	put_u16(command_writer, u16(len(bytes)))
	put_bytes(command_writer, bytes)
}

// set_u16_at and set_u32_at write a number at a place that the writer
// passed: a size that is known only after the bytes that it counts.
@(private)
set_u16_at :: proc "contextless" (command_writer: ^Command_Writer, place: int, value: u16) {
	if command_writer.overflowed || place + 2 > command_writer.count {
		return
	}
	command_writer.buffer[place], command_writer.buffer[place + 1] = u8(value >> 8), u8(value)
}

@(private)
set_u32_at :: proc "contextless" (command_writer: ^Command_Writer, place: int, value: u32) {
	if command_writer.overflowed || place + 4 > command_writer.count {
		return
	}
	command_writer.buffer[place], command_writer.buffer[place + 1], command_writer.buffer[place + 2], command_writer.buffer[place + 3] = u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)
}

// begin writes the header of a command: the tag, the size that end writes,
// and the code.
@(private)
begin :: proc "contextless" (buffer: []u8, tag: u16, code: u32) -> (command_writer: Command_Writer) {
	command_writer.buffer = buffer
	put_u16(&command_writer, tag)
	put_u32(&command_writer, 0)
	put_u32(&command_writer, code)
	return
}

// end writes the size of the command in its header, and gives its bytes: 0
// when it did not fit.
@(private)
end :: proc "contextless" (command_writer: ^Command_Writer) -> int {
	if command_writer.overflowed {
		return 0
	}
	set_u32_at(command_writer, 2, u32(command_writer.count))
	return command_writer.count
}

// put_password_session puts the authorization area of one session of the
// empty password: the owner hierarchy and the storage key have no
// authorization value.
@(private)
put_password_session :: proc "contextless" (command_writer: ^Command_Writer) {
	put_u32(command_writer, 9) // The bytes of the area: one session of 9 bytes.
	put_u32(command_writer, HANDLE_PASSWORD)
	put_u16(command_writer, 0) // No nonce.
	put_u8(command_writer, 0) // No attribute.
	put_u16(command_writer, 0) // The empty password.
}

// create_primary_command builds TPM2_CreatePrimary of the storage key under
// the owner hierarchy: an ECC P-256 key that decrypts with AES-128 in CFB
// mode, restricted, with no unique bytes.
create_primary_command :: proc "contextless" (buffer: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_CREATE_PRIMARY)
	put_u32(&command_writer, HANDLE_OWNER)
	put_password_session(&command_writer)
	// The sensitive part: no authorization value and no data.
	put_u16(&command_writer, 4)
	put_u16(&command_writer, 0)
	put_u16(&command_writer, 0)
	// The public part, with its size first.
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	put_u16(&command_writer, ALGORITHM_ECC)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_u32(&command_writer, STORAGE_KEY_ATTRIBUTES)
	put_u16(&command_writer, 0) // No policy.
	put_u16(&command_writer, ALGORITHM_AES)
	put_u16(&command_writer, 128)
	put_u16(&command_writer, ALGORITHM_CFB)
	put_u16(&command_writer, ALGORITHM_NULL) // The scheme of a restricted decryption key.
	put_u16(&command_writer, CURVE_NIST_P256)
	put_u16(&command_writer, ALGORITHM_NULL) // No key derivation function.
	put_u16(&command_writer, 0) // The unique point: x empty,
	put_u16(&command_writer, 0) // and y empty.
	set_u16_at(&command_writer, size_place, u16(command_writer.count - size_place - 2))
	put_u16(&command_writer, 0) // No outside information.
	put_u32(&command_writer, 0) // No PCR in the creation data.
	return end(&command_writer)
}

// start_session_command builds TPM2_StartAuthSession of a session with no
// key, no bind, no salt and no symmetric algorithm: its session key is
// empty, so the TPM takes an empty HMAC. kind is SESSION_TRIAL, to compute
// a policy, or SESSION_POLICY, to satisfy one. The nonce of the caller is
// 16 zero bytes: a session with an empty key computes no HMAC from it.
start_session_command :: proc "contextless" (buffer: []u8, kind: u8) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_START_AUTH_SESSION)
	put_u32(&command_writer, HANDLE_NULL)
	put_u32(&command_writer, HANDLE_NULL)
	nonce: [NONCE_SIZE]u8
	put_sized(&command_writer, nonce[:])
	put_u16(&command_writer, 0) // No salt.
	put_u8(&command_writer, kind)
	put_u16(&command_writer, ALGORITHM_NULL)
	put_u16(&command_writer, ALGORITHM_SHA256)
	return end(&command_writer)
}

// policy_pcr_command builds TPM2_PolicyPCR with PCR 7 and PCR 11 of the
// SHA-256 bank and no digest: the TPM takes the values of the PCRs now.
policy_pcr_command :: proc "contextless" (buffer: []u8, session: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_POLICY_PCR)
	put_u32(&command_writer, session)
	put_u16(&command_writer, 0) // No digest.
	put_pcr_selection(&command_writer)
	return end(&command_writer)
}

// policy_get_digest_command builds TPM2_PolicyGetDigest of a session.
policy_get_digest_command :: proc "contextless" (buffer: []u8, session: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_POLICY_GET_DIGEST)
	put_u32(&command_writer, session)
	return end(&command_writer)
}

// create_sealed_command builds TPM2_Create of a keyed-hash object under the
// storage key that holds the secret, with the policy as its policy.
create_sealed_command :: proc "contextless" (buffer: []u8, parent: u32, secret: ^[SECRET_SIZE]u8, policy: ^[DIGEST_SIZE]u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_CREATE)
	put_u32(&command_writer, parent)
	put_password_session(&command_writer)
	// The sensitive part: no authorization value, and the secret as data.
	put_u16(&command_writer, 2 + 2 + SECRET_SIZE)
	put_u16(&command_writer, 0)
	put_sized(&command_writer, secret^[:])
	// The public part.
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	put_u16(&command_writer, ALGORITHM_KEYED_HASH)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_u32(&command_writer, SEALED_OBJECT_ATTRIBUTES)
	put_sized(&command_writer, policy^[:])
	put_u16(&command_writer, ALGORITHM_NULL) // No scheme: a sealed object signs nothing.
	put_u16(&command_writer, 0) // No unique bytes: the TPM computes them.
	set_u16_at(&command_writer, size_place, u16(command_writer.count - size_place - 2))
	put_u16(&command_writer, 0) // No outside information.
	// PCR 7 and PCR 11 in the creation data: the TPM writes their digest at
	// the creation, and the creation ticket covers it.
	put_pcr_selection(&command_writer)
	return end(&command_writer)
}

// put_pcr_selection puts the selection of PCR 7 and PCR 11 of the SHA-256
// bank, as one list of one selection.
@(private)
put_pcr_selection :: proc "contextless" (command_writer: ^Command_Writer) {
	put_u32(command_writer, 1)
	put_u16(command_writer, ALGORITHM_SHA256)
	selection := PCR_SELECTION
	put_u8(command_writer, u8(len(selection)))
	put_bytes(command_writer, selection[:])
}

// certify_creation_command builds TPM2_CertifyCreation of a loaded object
// with no signing key (the handle NULL, with the empty password): the TPM
// checks that the ticket is its own HMAC over the creation hash and the
// name of the object, and signs nothing. A ticket that is not answers
// TPM_RC_TICKET.
certify_creation_command :: proc "contextless" (buffer: []u8, object: u32, creation_hash: ^[DIGEST_SIZE]u8, ticket: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_CERTIFY_CREATION)
	put_u32(&command_writer, HANDLE_NULL)
	put_u32(&command_writer, object)
	put_password_session(&command_writer)
	put_u16(&command_writer, 0) // No qualifying data.
	put_sized(&command_writer, creation_hash^[:])
	put_u16(&command_writer, ALGORITHM_NULL) // No scheme: no signature.
	put_bytes(&command_writer, ticket)
	return end(&command_writer)
}

// load_command builds TPM2_Load of a sealed object under the storage key.
// The two areas are the sized buffers that TPM2_Create gave, with their
// size fields.
load_command :: proc "contextless" (buffer: []u8, parent: u32, public_area: []u8, private_area: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_LOAD)
	put_u32(&command_writer, parent)
	put_password_session(&command_writer)
	put_bytes(&command_writer, private_area)
	put_bytes(&command_writer, public_area)
	return end(&command_writer)
}

// unseal_command builds TPM2_Unseal of a loaded object with a policy
// session: no nonce and an empty HMAC, as the session has an empty key.
unseal_command :: proc "contextless" (buffer: []u8, item: u32, session: u32) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_UNSEAL)
	put_u32(&command_writer, item)
	put_u32(&command_writer, 9)
	put_u32(&command_writer, session)
	put_u16(&command_writer, 0)
	put_u8(&command_writer, SESSION_CONTINUE)
	put_u16(&command_writer, 0)
	return end(&command_writer)
}

// flush_command builds TPM2_FlushContext of a session or of a loaded
// object.
flush_command :: proc "contextless" (buffer: []u8, handle: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_FLUSH_CONTEXT)
	put_u32(&command_writer, handle)
	return end(&command_writer)
}

// The read of one answer: each read checks the bytes that are left first.
Answer_Reader :: struct {
	bytes:  []u8,
	place:  int,
	failed: bool,
}

@(private)
take_bytes :: proc "contextless" (reader: ^Answer_Reader, count: int) -> []u8 {
	if reader.failed || count < 0 || count > len(reader.bytes) - reader.place {
		reader.failed = true
		return nil
	}
	taken := reader.bytes[reader.place:][:count]
	reader.place += count
	return taken
}

@(private)
take_u16 :: proc "contextless" (reader: ^Answer_Reader) -> u16 {
	bytes := take_bytes(reader, 2)
	if bytes == nil {
		return 0
	}
	return u16(bytes[0]) << 8 | u16(bytes[1])
}

@(private)
take_u32 :: proc "contextless" (reader: ^Answer_Reader) -> u32 {
	bytes := take_bytes(reader, 4)
	if bytes == nil {
		return 0
	}
	return u32(bytes[0]) << 24 | u32(bytes[1]) << 16 | u32(bytes[2]) << 8 | u32(bytes[3])
}

// take_sized takes a sized buffer of the TPM: its size, then its bytes.
// whole gives the bytes with the size field; data the bytes after it.
@(private)
take_sized :: proc "contextless" (reader: ^Answer_Reader) -> (whole: []u8, data: []u8) {
	start := reader.place
	count := int(take_u16(reader))
	data = take_bytes(reader, count)
	if reader.failed {
		return nil, nil
	}
	return reader.bytes[start:reader.place], data
}

// Why an answer is not taken.
Answer_Problem :: enum u8 {
	None, // The answer is a success, and its fields fit.
	Malformed, // The header, a size or a field does not fit the bytes that came.
	Refused, // The TPM answered a response code that is not a success: `code` has it.
}

// answer_begin checks the header of an answer: its size is the count of the
// bytes that came, and its code is a success. With the tag of the
// sessions, the size of the parameters follows the handles: the caller
// takes the handles, then calls parameters_begin.
answer_begin :: proc "contextless" (answer: []u8) -> (reader: Answer_Reader, code: u32, problem: Answer_Problem) {
	reader.bytes = answer
	tag := take_u16(&reader)
	size := take_u32(&reader)
	code = take_u32(&reader)
	if reader.failed || int(size) != len(answer) || tag != TAG_NO_SESSIONS && tag != TAG_SESSIONS {
		return reader, code, .Malformed
	}
	if code != RESPONSE_SUCCESS {
		return reader, code, .Refused
	}
	return reader, code, .None
}

// parameters_begin takes the size of the parameters of an answer with the
// tag of the sessions, and checks that they fit.
@(private)
parameters_begin :: proc "contextless" (reader: ^Answer_Reader) {
	if reader.failed || reader.bytes[0] != u8(TAG_SESSIONS >> 8 & 0xFF) || reader.bytes[1] != u8(TAG_SESSIONS & 0xFF) {
		return
	}
	size := take_u32(reader)
	if int(size) > len(reader.bytes) - reader.place {
		reader.failed = true
	}
}

// handle_answer reads the answer of TPM2_CreatePrimary, of TPM2_Load or of
// TPM2_StartAuthSession: the handle that the TPM gave.
handle_answer :: proc "contextless" (answer: []u8) -> (handle: u32, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return 0, code, problem
	}
	handle = take_u32(&reader)
	parameters_begin(&reader)
	if reader.failed {
		return 0, code, .Malformed
	}
	return handle, code, .None
}

// digest_answer reads the answer of TPM2_PolicyGetDigest: a digest of
// SHA-256.
digest_answer :: proc "contextless" (answer: []u8) -> (digest: [DIGEST_SIZE]u8, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return {}, code, problem
	}
	_, data := take_sized(&reader)
	if reader.failed || len(data) != DIGEST_SIZE {
		return {}, code, .Malformed
	}
	copy(digest[:], data)
	return digest, code, .None
}

// The parts of a sealed object that the answer of TPM2_Create gives and
// that the record keeps, each as the bytes of the answer.
Created_Object :: struct {
	private_area:    []u8, // With its size field, as TPM2_Load takes it.
	public_area:     []u8, // With its size field, as TPM2_Load takes it.
	creation_data:   []u8, // With its size field: the digest of PCR 7 and PCR 11 at the creation.
	creation_ticket: []u8, // The whole ticket: its tag, its hierarchy and its digest.
}

// create_answer reads the answer of TPM2_Create: the two areas of the
// sealed object, its creation data and its creation ticket. Each one must
// fit its limit, and the creation data and the ticket must have their form.
create_answer :: proc "contextless" (answer: []u8) -> (created: Created_Object, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return {}, code, problem
	}
	// The parameters end where their size says; the area of the sessions
	// follows them, and is no parameter.
	parameters_size := int(take_u32(&reader))
	parameters_end := reader.place + parameters_size
	if reader.failed || parameters_size > len(reader.bytes) - reader.place {
		return {}, code, .Malformed
	}
	created.private_area, _ = take_sized(&reader)
	created.public_area, _ = take_sized(&reader)
	created.creation_data, _ = take_sized(&reader)
	_, _ = take_sized(&reader) // The creation hash: the service computes it again from the creation data.
	ticket_start := reader.place
	_ = take_u16(&reader)
	_ = take_u32(&reader)
	_, _ = take_sized(&reader)
	if reader.failed || reader.place != parameters_end {
		return {}, code, .Malformed
	}
	created.creation_ticket = reader.bytes[ticket_start:reader.place]
	if len(created.private_area) > PRIVATE_AREA_LIMIT || len(created.public_area) > PUBLIC_AREA_LIMIT || !ticket_fits(created.creation_ticket) {
		return {}, code, .Malformed
	}
	if _, ok := creation_data_pcr_digest(created.creation_data); !ok {
		return {}, code, .Malformed
	}
	return created, code, .None
}

// sha256_of gives the SHA-256 hash of the parts, one after the other.
@(private)
sha256_of :: proc "contextless" (parts: ..[]u8) -> (digest: [DIGEST_SIZE]u8) {
	// The hash allocates nothing; the empty context only satisfies the
	// calling convention of the package.
	context = runtime.Context{}
	hash: sha2.Context_256
	sha2.init_256(&hash)
	for part in parts {
		sha2.update(&hash, part)
	}
	sha2.final(&hash, digest[:])
	return digest
}

// creation_hash gives the creation hash of a creation data with its size
// field: SHA-256 of the bytes after the size field, as the TPM computes it.
creation_hash :: proc "contextless" (creation_data: []u8) -> [DIGEST_SIZE]u8 {
	if len(creation_data) < 2 {
		return {}
	}
	return sha256_of(creation_data[2:])
}

// policy_pcr_digest gives the policy of a sealed object whose PCR 7 and PCR
// 11 had the digest pcr_digest: TPM2_PolicyPCR from an empty policy,
// SHA-256 of 32 zero bytes, the code of the command, the selection and the
// digest (TPM 2.0 part 3, TPM2_PolicyPCR).
policy_pcr_digest :: proc "contextless" (pcr_digest: ^[DIGEST_SIZE]u8) -> [DIGEST_SIZE]u8 {
	empty: [DIGEST_SIZE]u8
	code := [4]u8{u8(COMMAND_POLICY_PCR >> 24), u8(COMMAND_POLICY_PCR >> 16 & 0xFF), u8(COMMAND_POLICY_PCR >> 8 & 0xFF), u8(COMMAND_POLICY_PCR & 0xFF)}
	selection_bytes: [10]u8
	command_writer := Command_Writer{buffer = selection_bytes[:]}
	put_pcr_selection(&command_writer)
	return sha256_of(empty[:], code[:], selection_bytes[:command_writer.count], pcr_digest^[:])
}

// creation_data_pcr_digest reads a creation data with its size field: its
// selection must be PCR 7 and PCR 11 of SHA-256, and its fields must end at
// its end. It gives the digest of those PCRs at the creation.
creation_data_pcr_digest :: proc "contextless" (creation_data: []u8) -> (digest: [DIGEST_SIZE]u8, ok: bool) {
	if !area_fits(creation_data, CREATION_DATA_LIMIT) {
		return {}, false
	}
	reader := Answer_Reader{bytes = creation_data, place = 2}
	count := take_u32(&reader)
	bank := take_u16(&reader)
	selection := PCR_SELECTION
	select_size := take_bytes(&reader, 1)
	if reader.failed || count != 1 || bank != ALGORITHM_SHA256 || select_size[0] != u8(len(selection)) {
		return {}, false
	}
	selected := take_bytes(&reader, len(selection))
	_, pcr_digest := take_sized(&reader)
	_ = take_bytes(&reader, 1) // The locality.
	_ = take_u16(&reader) // The hash of the name of the parent.
	_, _ = take_sized(&reader) // The name of the parent.
	_, _ = take_sized(&reader) // The qualified name of the parent.
	_, _ = take_sized(&reader) // The outside information.
	if reader.failed || reader.place != len(creation_data) || string(selected) != string(selection[:]) || len(pcr_digest) != DIGEST_SIZE {
		return {}, false
	}
	copy(digest[:], pcr_digest)
	return digest, true
}

// ticket_fits checks the form of a creation ticket: the tag of a creation,
// a hierarchy, a digest, and no byte after it, within its limit. The TPM
// checks its digest.
ticket_fits :: proc "contextless" (ticket: []u8) -> bool {
	if len(ticket) > CREATION_TICKET_LIMIT {
		return false
	}
	reader := Answer_Reader{bytes = ticket}
	tag := take_u16(&reader)
	_ = take_u32(&reader)
	_, _ = take_sized(&reader)
	return !reader.failed && tag == TAG_CREATION && reader.place == len(ticket)
}

// sealed_public_check checks the public area of a sealed object, with its
// size field: a keyed-hash object of SHA-256 with exactly the attributes of
// SEALED_OBJECT_ATTRIBUTES (no userWithAuth, adminWithPolicy), the policy
// given, no scheme, and no byte after its fields. Its policy must be the
// policy of the PCR values of its creation data: then the object opens
// only while the PCRs hold the values that they held when the TPM made it.
sealed_public_check :: proc "contextless" (public_area: []u8, policy: ^[DIGEST_SIZE]u8) -> bool {
	if !area_fits(public_area, PUBLIC_AREA_LIMIT) {
		return false
	}
	reader := Answer_Reader{bytes = public_area, place = 2}
	kind := take_u16(&reader)
	name_hash := take_u16(&reader)
	attributes := take_u32(&reader)
	_, object_policy := take_sized(&reader)
	scheme := take_u16(&reader)
	_, unique := take_sized(&reader)
	if reader.failed || reader.place != len(public_area) {
		return false
	}
	return kind == ALGORITHM_KEYED_HASH && name_hash == ALGORITHM_SHA256 && attributes == SEALED_OBJECT_ATTRIBUTES && scheme == ALGORITHM_NULL && len(unique) == DIGEST_SIZE && string(object_policy) == string(policy^[:])
}

// unseal_answer reads the answer of TPM2_Unseal: the secret, which must
// have SECRET_SIZE bytes.
unseal_answer :: proc "contextless" (answer: []u8) -> (secret: []u8, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return nil, code, problem
	}
	parameters_begin(&reader)
	_, data := take_sized(&reader)
	if reader.failed || len(data) != SECRET_SIZE {
		return nil, code, .Malformed
	}
	return data, code, .None
}

// status_answer reads an answer with no field that the service needs:
// TPM2_PolicyPCR and TPM2_FlushContext.
status_answer :: proc "contextless" (answer: []u8) -> (code: u32, problem: Answer_Problem) {
	_, code, problem = answer_begin(answer)
	return
}

// area_fits checks an area that a record of a key keeps and that the
// service gives to TPM2_Load: a size field whose count is the bytes that
// follow it, within its limit. The record is data from the disk.
area_fits :: proc "contextless" (area: []u8, limit: int) -> bool {
	if len(area) < 2 || len(area) > limit {
		return false
	}
	return int(u16(area[0]) << 8 | u16(area[1])) == len(area) - 2
}
