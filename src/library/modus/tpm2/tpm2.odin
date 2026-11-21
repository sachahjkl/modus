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
// A sealed object can also have an authorization value: the keys of a
// named principal (src/md/features/tpm_sealed_principal_keys.md). Its
// policy is then TPM2_PolicyPCR followed by TPM2_PolicyPassword, and its
// attribute noDA is clear: the TPM counts each wrong value, and refuses
// each try for a time after too many.
//
// The TPM floors are indices of the TPM that only gain bits: the boot
// program reads them through the firmware, refuses an older system or a
// revoked key, then defines and raises them before its measure
// (src/md/features/rollback_floors.md). The commands of the indices and
// the checks of their answers are at the end of this file.
//
// See [TPM service](term:tpm-service),
// [sealed by the TPM](term:sealed-by-the-tpm) and
// [TPM floor](term:tpm-floor).
package tpm2

import "base:runtime"
import info "modus:contract/boot_info"
import "modus:contract/byte_order"
import "modus:cryptography/sha2"

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
COMMAND_POLICY_PASSWORD :: u32(0x0000_018C)
COMMAND_SHUTDOWN :: u32(0x0000_0145)
COMMAND_HIERARCHY_CHANGE_AUTH :: u32(0x0000_0129)
COMMAND_GET_CAPABILITY :: u32(0x0000_017A)
// The service never sends it: it resets the count of the wrong
// authorization values. The tool sends it from the host, as another system
// on the machine can, to show that the TPM refuses it.
COMMAND_DICTIONARY_ATTACK_LOCK_RESET :: u32(0x0000_0139)
// TPM2_PolicyPassword extends the policy with the code of
// TPM2_PolicyAuthValue, not with its own code: either command then
// satisfies the same policy (TPM 2.0 part 3, TPM2_PolicyPassword).
COMMAND_POLICY_AUTH_VALUE :: u32(0x0000_016B)
// The commands of the indices of the TPM floors: the boot program reads,
// defines and raises them through the firmware.
COMMAND_NV_UNDEFINE_SPACE :: u32(0x0000_0122)
COMMAND_NV_DEFINE_SPACE :: u32(0x0000_012A)
COMMAND_NV_SET_BITS :: u32(0x0000_0135)
COMMAND_NV_READ :: u32(0x0000_014E)
COMMAND_NV_READ_PUBLIC :: u32(0x0000_0169)
// The commands of the measure of a start policy: the TPM service extends
// PCR 12, then reads it back for the line of the root service.
COMMAND_PCR_EXTEND :: u32(0x0000_0182)
COMMAND_PCR_READ :: u32(0x0000_017E)

// The kind of TPM2_Shutdown: the next TPM2_Startup is a reset, as the
// firmware starts the TPM with TPM2_Startup(CLEAR) at each start.
SHUTDOWN_CLEAR :: u16(0x0000)

// The handles that the TPM defines.
HANDLE_OWNER :: u32(0x4000_0001) // The owner hierarchy: the parent of the storage key.
HANDLE_NULL :: u32(0x4000_0007) // No key and no bind for a session.
HANDLE_PASSWORD :: u32(0x4000_0009) // The session of a password: here, the empty password of the owner and of the storage key.
HANDLE_LOCKOUT :: u32(0x4000_000A) // The lockout hierarchy: its value guards the count of the wrong authorization values.

// The capability of the properties of the TPM (TPM_CAP_TPM_PROPERTIES), and
// the properties that the service reads (part 2, TPM_PT).
CAPABILITY_TPM_PROPERTIES :: u32(0x0000_0006)
PROPERTY_PERMANENT :: u32(0x0000_0200) // The bits of TPMA_PERMANENT.
// Four properties in a row: the failures counted now, the failures before
// a lockout, the seconds after which the TPM forgives one failure, and the
// seconds that the lockout hierarchy waits after a wrong value of its own.
PROPERTY_LOCKOUT_COUNTER :: u32(0x0000_020E)
PROPERTY_MAXIMUM_AUTHORIZATION_FAILURES :: u32(0x0000_020F)
PROPERTY_LOCKOUT_INTERVAL :: u32(0x0000_0210)
PROPERTY_LOCKOUT_RECOVERY :: u32(0x0000_0211)
COUNT_LIMIT_PROPERTIES :: int(PROPERTY_LOCKOUT_RECOVERY - PROPERTY_LOCKOUT_COUNTER + 1)

// The bit lockoutAuthSet of TPMA_PERMANENT: the lockout hierarchy has an
// authorization value that is not empty.
PERMANENT_LOCKOUT_AUTHORIZATION_SET :: u32(1 << 2)

// The algorithms.
ALGORITHM_AES :: u16(0x0006)
ALGORITHM_KEYED_HASH :: u16(0x0008)
ALGORITHM_SHA256 :: u16(0x000B)
ALGORITHM_NULL :: u16(0x0010)
ALGORITHM_ECC :: u16(0x0023)
ALGORITHM_CFB :: u16(0x0043)
CURVE_NIST_P256 :: u16(0x0003)

// The kinds of a session that this system starts (part 2, TPM_SE): the
// values of the TPM, written in a command and never read back.
Session_Kind :: enum u8 {
	Policy = 0x01,
	Trial  = 0x03,
}

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
// The sealed object with an authorization value: noDA is clear, so each
// wrong value is a failure that the TPM counts, and after too many the TPM
// refuses each try for a time (TPM_RC_LOCKOUT). A copy of the disk then
// allows no tries without limit.
AUTHORIZED_SEALED_OBJECT_ATTRIBUTES :: ATTRIBUTE_FIXED_TPM | ATTRIBUTE_FIXED_PARENT | ATTRIBUTE_ADMIN_WITH_POLICY

// The bytes of an authorization value: at most the digest of the hash of
// the name of the object, SHA-256.
AUTHORIZATION_VALUE_SIZE :: 32

// sealed_object_attributes gives the attributes of a sealed object with an
// authorization value, or with none.
sealed_object_attributes :: proc "contextless" (authorized: bool) -> u32 {
	return authorized ? AUTHORIZED_SEALED_OBJECT_ATTRIBUTES : SEALED_OBJECT_ATTRIBUTES
}

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

// The register of the start policy: PCR 12, which the seal never selects,
// so a new start policy changes no unseal
// (src/md/features/start_policy.md, "The measure of the start policy").
START_POLICY_PCR :: u32(12)
// PCR 12 in the bit map of the SHA-256 bank: bit 4 of byte 1.
START_POLICY_PCR_SELECTION :: [3]u8{0x00, 0x10, 0x00}
#assert(PCR_SET & (1 << START_POLICY_PCR) == 0)

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
// The error of a format 1 code: a wrong authorization value of an object
// that the TPM protects from a dictionary attack. The TPM counted it.
RESPONSE_AUTHORIZATION_FAIL :: u32(0x00E)
// The codes of format 0 that the service names: the TPM refuses each try of
// an authorization value for a time, as it counted too many failures; and
// the TPM asks for the same command again.
RESPONSE_LOCKOUT :: u32(0x921)
RESPONSE_RETRY :: u32(0x922)
RESPONSE_ERROR_MASK :: u32(0x3F) // The bits of the error of a format 1 code.
// The error of a format 1 code: the handle names nothing. TPM2_NV_ReadPublic
// answers it for an index that is not defined.
RESPONSE_HANDLE :: u32(0x00B)

// policy_fails says if a response code says that the policy of the object
// does not hold: the values of the PCRs differ from the values of the seal.
policy_fails :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & RESPONSE_ERROR_MASK == RESPONSE_POLICY_FAIL
}

// authorization_fails says if a response code says that the authorization
// value is wrong, and that the TPM counted the failure (TPM_RC_AUTH_FAIL).
// A failure that the TPM does not count is TPM_RC_BAD_AUTH: another code.
authorization_fails :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & RESPONSE_ERROR_MASK == RESPONSE_AUTHORIZATION_FAIL
}

// locked_out says if a response code says that the TPM refuses each try of
// an authorization value for now (TPM_RC_LOCKOUT).
locked_out :: proc "contextless" (code: u32) -> bool {
	return code == RESPONSE_LOCKOUT
}

// retry_asked says if the TPM asks for the same command again
// (TPM_RC_RETRY). The reference code of the TPM answers it at the first use
// of an object that it protects from a dictionary attack after a start,
// once it wrote that use to its memory.
retry_asked :: proc "contextless" (code: u32) -> bool {
	return code == RESPONSE_RETRY
}

// handle_absent says if a response code says that a handle names nothing
// (TPM_RC_HANDLE): for TPM2_NV_ReadPublic, an index that is not defined.
handle_absent :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & RESPONSE_ERROR_MASK == RESPONSE_HANDLE
}

// ticket_fails says if a response code says that a ticket is not the HMAC
// of this TPM over what it names (TPM_RC_TICKET): another code, as a lack
// of memory of the TPM, says nothing of the record.
ticket_fails :: proc "contextless" (code: u32) -> bool {
	return code & RESPONSE_FORMAT_ONE != 0 && code & RESPONSE_ERROR_MASK == RESPONSE_TICKET
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
	bytes: [2]u8
	byte_order.write_u16_big_endian(bytes[:], 0, value)
	put_bytes(command_writer, bytes[:])
}

@(private)
put_u32 :: proc "contextless" (command_writer: ^Command_Writer, value: u32) {
	bytes: [4]u8
	byte_order.write_u32_big_endian(bytes[:], 0, value)
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
	byte_order.write_u16_big_endian(command_writer.buffer, place, value)
}

@(private)
set_u32_at :: proc "contextless" (command_writer: ^Command_Writer, place: int, value: u32) {
	if command_writer.overflowed || place + 4 > command_writer.count {
		return
	}
	byte_order.write_u32_big_endian(command_writer.buffer, place, value)
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
// empty, so the TPM takes an empty HMAC. kind is .Trial, to compute a
// policy, or .Policy, to satisfy one. The nonce of the caller is 16 zero
// bytes: a session with an empty key computes no HMAC from it.
start_session_command :: proc "contextless" (buffer: []u8, kind: Session_Kind) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_START_AUTH_SESSION)
	put_u32(&command_writer, HANDLE_NULL)
	put_u32(&command_writer, HANDLE_NULL)
	nonce: [NONCE_SIZE]u8
	put_sized(&command_writer, nonce[:])
	put_u16(&command_writer, 0) // No salt.
	put_u8(&command_writer, u8(kind))
	put_u16(&command_writer, ALGORITHM_NULL)
	put_u16(&command_writer, ALGORITHM_SHA256)
	return end(&command_writer)
}

// policy_pcr_command builds TPM2_PolicyPCR with PCR 7 and PCR 11 of the
// SHA-256 bank and no digest: the TPM takes the values of the PCRs now. The
// policy of a sealed object and of a TPM floor.
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

// policy_password_command builds TPM2_PolicyPassword: the use of the
// object then needs its authorization value, sent in the session as a
// password.
policy_password_command :: proc "contextless" (buffer: []u8, session: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_POLICY_PASSWORD)
	put_u32(&command_writer, session)
	return end(&command_writer)
}

// shutdown_command builds TPM2_Shutdown(CLEAR): the TPM writes its state,
// and the next start is orderly. The TPM goes on to take commands after it.
shutdown_command :: proc "contextless" (buffer: []u8) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_SHUTDOWN)
	put_u16(&command_writer, SHUTDOWN_CLEAR)
	return end(&command_writer)
}

// properties_command builds TPM2_GetCapability of count properties of the
// TPM from the property first.
properties_command :: proc "contextless" (buffer: []u8, first: u32, count: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_GET_CAPABILITY)
	put_u32(&command_writer, CAPABILITY_TPM_PROPERTIES)
	put_u32(&command_writer, first)
	put_u32(&command_writer, count)
	return end(&command_writer)
}

// lockout_authorization_change_command builds TPM2_HierarchyChangeAuth of
// the lockout hierarchy, with the empty value in the password session: the
// service sends it only when the bit lockoutAuthSet is clear. new_value has
// 1 to AUTHORIZATION_VALUE_SIZE bytes: an empty one changes nothing, and a
// TPM takes no value longer than the digest of its hash.
lockout_authorization_change_command :: proc "contextless" (buffer: []u8, new_value: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_HIERARCHY_CHANGE_AUTH)
	if len(new_value) == 0 || len(new_value) > AUTHORIZATION_VALUE_SIZE {
		return 0
	}
	put_u32(&command_writer, HANDLE_LOCKOUT)
	put_password_session(&command_writer)
	put_sized(&command_writer, new_value)
	return end(&command_writer)
}

// dictionary_attack_lock_reset_command builds
// TPM2_DictionaryAttackLockReset with the empty value of the lockout
// hierarchy. See COMMAND_DICTIONARY_ATTACK_LOCK_RESET: only the tool sends
// it.
dictionary_attack_lock_reset_command :: proc "contextless" (buffer: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_DICTIONARY_ATTACK_LOCK_RESET)
	put_u32(&command_writer, HANDLE_LOCKOUT)
	put_password_session(&command_writer)
	return end(&command_writer)
}

// lockout_authorization_set says if the bits of TPM_PT_PERMANENT say that
// the lockout hierarchy has an authorization value.
lockout_authorization_set :: proc "contextless" (permanent: u32) -> bool {
	return permanent & PERMANENT_LOCKOUT_AUTHORIZATION_SET != 0
}

// create_sealed_command builds TPM2_Create of a keyed-hash object under the
// storage key that holds the secret, with the policy as its policy. With an
// authorization value (not empty), the object has it, with the attributes
// AUTHORIZED_SEALED_OBJECT_ATTRIBUTES; with none, SEALED_OBJECT_ATTRIBUTES.
create_sealed_command :: proc "contextless" (buffer: []u8, parent: u32, secret: ^[SECRET_SIZE]u8, policy: ^[DIGEST_SIZE]u8, authorization: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_CREATE)
	if len(authorization) > AUTHORIZATION_VALUE_SIZE {
		return 0
	}
	put_u32(&command_writer, parent)
	put_password_session(&command_writer)
	// The sensitive part: the authorization value, and the secret as data.
	put_u16(&command_writer, u16(2 + len(authorization) + 2 + SECRET_SIZE))
	put_sized(&command_writer, authorization)
	put_sized(&command_writer, secret^[:])
	// The public part.
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	put_u16(&command_writer, ALGORITHM_KEYED_HASH)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_u32(&command_writer, sealed_object_attributes(len(authorization) > 0))
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
// session and no nonce. With no authorization value the HMAC is empty, as
// the session has an empty key. With one, the session ran
// TPM2_PolicyPassword: the field of the HMAC holds the value itself, which
// the TPM compares with the value of the object.
unseal_command :: proc "contextless" (buffer: []u8, item: u32, session: u32, authorization: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_UNSEAL)
	if len(authorization) > AUTHORIZATION_VALUE_SIZE {
		return 0
	}
	put_u32(&command_writer, item)
	put_u32(&command_writer, u32(4 + 2 + 1 + 2 + len(authorization)))
	put_u32(&command_writer, session)
	put_u16(&command_writer, 0)
	put_u8(&command_writer, SESSION_CONTINUE)
	put_sized(&command_writer, authorization)
	return end(&command_writer)
}

// flush_command builds TPM2_FlushContext of a session or of a loaded
// object.
flush_command :: proc "contextless" (buffer: []u8, handle: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_FLUSH_CONTEXT)
	put_u32(&command_writer, handle)
	return end(&command_writer)
}

// start_policy_pcr_selection puts the selection of PCR 12 of the SHA-256
// bank, as one list of one selection.
@(private)
start_policy_pcr_selection :: proc "contextless" (command_writer: ^Command_Writer) {
	put_u32(command_writer, 1)
	put_u16(command_writer, ALGORITHM_SHA256)
	selection := START_POLICY_PCR_SELECTION
	put_u8(command_writer, u8(len(selection)))
	put_bytes(command_writer, selection[:])
}

// pcr_extend_command builds TPM2_PCR_Extend of the register of the start
// policy, in the SHA-256 bank, with one digest. A PCR below 16 has the
// empty authorization value at locality 0: the password session is empty.
pcr_extend_command :: proc "contextless" (buffer: []u8, digest: ^[DIGEST_SIZE]u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_PCR_EXTEND)
	put_u32(&command_writer, START_POLICY_PCR) // The handle of a PCR is its number.
	put_password_session(&command_writer)
	put_u32(&command_writer, 1) // One digest.
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_bytes(&command_writer, digest^[:])
	return end(&command_writer)
}

// pcr_read_command builds TPM2_PCR_Read of the register of the start
// policy in the SHA-256 bank.
pcr_read_command :: proc "contextless" (buffer: []u8) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_PCR_READ)
	start_policy_pcr_selection(&command_writer)
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
	return byte_order.read_u16_big_endian(bytes, 0)
}

@(private)
take_u32 :: proc "contextless" (reader: ^Answer_Reader) -> u32 {
	bytes := take_bytes(reader, 4)
	if bytes == nil {
		return 0
	}
	return byte_order.read_u32_big_endian(bytes, 0)
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
	code: [4]u8
	byte_order.write_u32_big_endian(code[:], 0, COMMAND_POLICY_PCR)
	selection_bytes: [10]u8
	command_writer := Command_Writer{buffer = selection_bytes[:]}
	put_pcr_selection(&command_writer)
	return sha256_of(empty[:], code[:], selection_bytes[:command_writer.count], pcr_digest^[:])
}

// policy_with_password_digest gives the policy that follows a policy with
// TPM2_PolicyPassword: SHA-256 of the policy and the code of
// TPM2_PolicyAuthValue (TPM 2.0 part 3, TPM2_PolicyPassword).
policy_with_password_digest :: proc "contextless" (policy: ^[DIGEST_SIZE]u8) -> [DIGEST_SIZE]u8 {
	code: [4]u8
	byte_order.write_u32_big_endian(code[:], 0, COMMAND_POLICY_AUTH_VALUE)
	return sha256_of(policy^[:], code[:])
}

// sealed_object_policy gives the policy of a sealed object whose PCR 7 and
// PCR 11 had the digest pcr_digest at its creation: TPM2_PolicyPCR, then
// TPM2_PolicyPassword when the object has an authorization value.
sealed_object_policy :: proc "contextless" (pcr_digest: ^[DIGEST_SIZE]u8, authorized: bool) -> [DIGEST_SIZE]u8 {
	policy := policy_pcr_digest(pcr_digest)
	if authorized {
		policy = policy_with_password_digest(&policy)
	}
	return policy
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
// size field: a keyed-hash object of SHA-256 with exactly the attributes
// given (SEALED_OBJECT_ATTRIBUTES or AUTHORIZED_SEALED_OBJECT_ATTRIBUTES:
// no userWithAuth, adminWithPolicy), the policy given, no scheme, and no
// byte after its fields. Its policy must be the policy of the PCR values of
// its creation data: then the object opens only while the PCRs hold the
// values that they held when the TPM made it. The exact attributes also
// keep an object with noDA set from passing as an object whose wrong
// authorization values the TPM counts.
sealed_public_check :: proc "contextless" (public_area: []u8, policy: ^[DIGEST_SIZE]u8, wanted_attributes: u32) -> bool {
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
	return kind == ALGORITHM_KEYED_HASH && name_hash == ALGORITHM_SHA256 && attributes == wanted_attributes && scheme == ALGORITHM_NULL && len(unique) == DIGEST_SIZE && string(object_policy) == string(policy^[:])
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
// TPM2_PolicyPCR, TPM2_PolicyPassword, TPM2_FlushContext and
// TPM2_Shutdown.
status_answer :: proc "contextless" (answer: []u8) -> (code: u32, problem: Answer_Problem) {
	_, code, problem = answer_begin(answer)
	return
}

// pcr_read_answer reads the answer of TPM2_PCR_Read of the register of the
// start policy: the selection that the TPM gives back must be the one
// asked, with one digest of SHA-256, and no byte after it. A TPM with no
// SHA-256 bank gives an empty selection, which is refused: a value of
// another register or bank is never taken for PCR 12. The counts come from
// the device: they are compared, never used as a bound.
pcr_read_answer :: proc "contextless" (answer: []u8) -> (value: [DIGEST_SIZE]u8, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return {}, code, problem
	}
	_ = take_u32(&reader) // The update counter of the PCRs.
	selection := START_POLICY_PCR_SELECTION
	selection_count := take_u32(&reader)
	bank := take_u16(&reader)
	select_size := take_bytes(&reader, 1)
	if reader.failed || selection_count != 1 || bank != ALGORITHM_SHA256 || select_size[0] != u8(len(selection)) {
		return {}, code, .Malformed
	}
	selected := take_bytes(&reader, len(selection))
	digest_count := take_u32(&reader)
	_, data := take_sized(&reader)
	if reader.failed || string(selected) != string(selection[:]) || digest_count != 1 || len(data) != DIGEST_SIZE || reader.place != len(answer) {
		return {}, code, .Malformed
	}
	copy(value[:], data)
	return value, code, .None
}

// start_policy_event_digest gives the digest that one start policy extends
// PCR 12 with: SHA-256 of the hash of its module and the hash of its list,
// 32 zero bytes for a start policy from the disk, which has no list
// (src/md/features/start_policy.md, "The measure of the start policy").
start_policy_event_digest :: proc "contextless" (module_hash: ^[DIGEST_SIZE]u8, list_hash: ^[DIGEST_SIZE]u8) -> [DIGEST_SIZE]u8 {
	return sha256_of(module_hash^[:], list_hash^[:])
}

// pcr_extended gives the value of a PCR of the SHA-256 bank after an
// extend: SHA-256 of its value before and of the digest. An attestor and
// the tool compute the value of PCR 12 with it.
pcr_extended :: proc "contextless" (before: ^[DIGEST_SIZE]u8, digest: ^[DIGEST_SIZE]u8) -> [DIGEST_SIZE]u8 {
	return sha256_of(before^[:], digest^[:])
}

// properties_answer reads the answer of TPM2_GetCapability of the
// properties of the TPM: the values of the properties first, first + 1, and
// so on, one for each place of values. The TPM gives the properties that it
// has from first on, in order. Each property asked must be in its place,
// the list must hold no other one, and no byte may follow it; else no value
// is given. The count of the list comes from the device: it is compared,
// never used as a bound.
properties_answer :: proc "contextless" (answer: []u8, first: u32, values: []u32) -> (code: u32, problem: Answer_Problem) {
	for &value in values {
		value = 0
	}
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return code, problem
	}
	// The command has no session, so the answer has none: no size of the
	// parameters comes before them.
	more_data := take_bytes(&reader, 1)
	capability := take_u32(&reader)
	count := take_u32(&reader)
	if reader.failed || answer[0] != u8(TAG_NO_SESSIONS >> 8) || answer[1] != u8(TAG_NO_SESSIONS & 0xFF) || more_data[0] > 1 || capability != CAPABILITY_TPM_PROPERTIES || u64(count) != u64(len(values)) {
		return code, .Malformed
	}
	for index in 0 ..< len(values) {
		property := take_u32(&reader)
		value := take_u32(&reader)
		if reader.failed || property != first + u32(index) {
			for &item in values {
				item = 0
			}
			return code, .Malformed
		}
		values[index] = value
	}
	if reader.place != len(answer) {
		for &item in values {
			item = 0
		}
		return code, .Malformed
	}
	return code, .None
}

// area_fits checks an area that a record of a key keeps and that the
// service gives to TPM2_Load: a size field whose count is the bytes that
// follow it, within its limit. The record is data from the disk.
area_fits :: proc "contextless" (area: []u8, limit: int) -> bool {
	if len(area) < 2 || len(area) > limit {
		return false
	}
	return int(byte_order.read_u16_big_endian(area, 0)) == len(area) - 2
}

// The attributes of an index (TPM 2.0 part 2, TPMA_NV).
NV_POLICY_WRITE :: u32(1 << 3) // Only a policy session writes it.
NV_TYPE_MASK :: u32(0xF << 4) // The bits of the type of the index.
NV_TYPE_BITS :: u32(2 << 4) // TPM_NT_BITS: 64 bits that TPM2_NV_SetBits adds to and never clears.
NV_AUTHORIZATION_READ :: u32(1 << 18) // A read with the authorization value of the index.
NV_NO_DICTIONARY_ATTACK :: u32(1 << 25) // A wrong value is no failure that the TPM counts.
NV_WRITTEN :: u32(1 << 29) // The TPM sets it at the first write.
// The attributes of a TPM floor, NV_WRITTEN aside. The index has an empty
// authorization value: the boot program reads it and holds no secret. Only
// a policy session writes it. Its policy is PCR 7 with Secure Boot on and
// PCR 11 before the measure (32 zero bytes): only a boot program that the
// certificate of the publisher verified, before it measures the system,
// raises it, and no kernel or process after the measure can. The owner
// hierarchy defined it: the TPM refuses TPMA_NV_POLICY_DELETE for an index
// of that hierarchy.
FLOOR_ATTRIBUTES :: NV_POLICY_WRITE | NV_TYPE_BITS | NV_AUTHORIZATION_READ | NV_NO_DICTIONARY_ATTACK
FLOOR_DATA_SIZE :: 8 // The bytes of the data of a floor: its 64 bits.
// The largest policy of an index: a digest of SHA-512. A foreign index can
// have a policy of another hash.
NV_POLICY_LIMIT :: 64
// The errors of the codes that say that the TPM refused the authorization
// of a read: TPM_RC_BAD_AUTH and TPM_RC_AUTH_FAIL of format 1, and
// TPM_RC_NV_AUTHORIZATION of format 0.
RESPONSE_BAD_AUTHORIZATION :: u32(0x022)
RESPONSE_NV_AUTHORIZATION :: u32(0x149)

// The public area of an index, as TPM2_NV_ReadPublic gives it.
Nv_Public :: struct {
	index:          u32, // The handle of the index.
	name_algorithm: u16, // The hash of its name and of its policy.
	attributes:     u32, // TPMA_NV.
	policy:         [NV_POLICY_LIMIT]u8, // policy_size bytes of it are the policy.
	policy_size:    int,
	data_size:      u16, // The bytes of its data.
}

// nv_read_public_command builds TPM2_NV_ReadPublic of an index: it needs no
// authorization.
nv_read_public_command :: proc "contextless" (buffer: []u8, index: u32) -> int {
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_NV_READ_PUBLIC)
	put_u32(&command_writer, index)
	return end(&command_writer)
}

// nv_read_command builds TPM2_NV_Read of the 8 bytes of a floor, with the
// index as its own authorization and the empty password.
nv_read_command :: proc "contextless" (buffer: []u8, index: u32) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_READ)
	put_u32(&command_writer, index) // The authorization: the index.
	put_u32(&command_writer, index)
	put_password_session(&command_writer)
	put_u16(&command_writer, FLOOR_DATA_SIZE)
	put_u16(&command_writer, 0) // From its first byte.
	return end(&command_writer)
}

// floor_define_command builds TPM2_NV_DefineSpace of a floor under the
// owner hierarchy with its empty password: no authorization value of the
// index, FLOOR_ATTRIBUTES, the policy given, and 8 bytes.
floor_define_command :: proc "contextless" (buffer: []u8, index: u32, policy: ^[DIGEST_SIZE]u8) -> int {
	return floor_area_define_command(buffer, index, policy, nil)
}

// floor_area_define_command builds TPM2_NV_DefineSpace of an index with the
// area of a floor and the authorization value given. The system defines
// each floor with none (floor_define_command); the tool defines one with a
// value to plant an index as another system can.
floor_area_define_command :: proc "contextless" (buffer: []u8, index: u32, policy: ^[DIGEST_SIZE]u8, authorization: []u8) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_DEFINE_SPACE)
	if len(authorization) > AUTHORIZATION_VALUE_SIZE {
		return 0
	}
	put_u32(&command_writer, HANDLE_OWNER)
	put_password_session(&command_writer)
	put_sized(&command_writer, authorization)
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	put_u32(&command_writer, index)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_u32(&command_writer, FLOOR_ATTRIBUTES)
	put_sized(&command_writer, policy^[:])
	put_u16(&command_writer, FLOOR_DATA_SIZE)
	set_u16_at(&command_writer, size_place, u16(command_writer.count - size_place - 2))
	return end(&command_writer)
}

// nv_undefine_command builds TPM2_NV_UndefineSpace of an index under the
// owner hierarchy with its empty password: the boot program removes with it
// an index at the place of a floor that is not a floor that it can read.
nv_undefine_command :: proc "contextless" (buffer: []u8, index: u32) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_UNDEFINE_SPACE)
	put_u32(&command_writer, HANDLE_OWNER)
	put_u32(&command_writer, index)
	put_password_session(&command_writer)
	return end(&command_writer)
}

// floor_set_bits_command builds TPM2_NV_SetBits of a floor, in a policy
// session that ran policy_pcr_command: the TPM adds the bits to the
// field. The session has no key, so its HMAC is empty.
floor_set_bits_command :: proc "contextless" (buffer: []u8, index: u32, session: u32, bits: u64) -> int {
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_SET_BITS)
	put_u32(&command_writer, index) // The authorization: the index, through its policy.
	put_u32(&command_writer, index)
	put_u32(&command_writer, 9) // The bytes of the area: one session of 9 bytes.
	put_u32(&command_writer, session)
	put_u16(&command_writer, 0) // No nonce.
	put_u8(&command_writer, SESSION_CONTINUE)
	put_u16(&command_writer, 0) // The empty HMAC.
	put_u32(&command_writer, u32(bits >> 32))
	put_u32(&command_writer, u32(bits & 0xFFFF_FFFF))
	return end(&command_writer)
}

// nv_public_answer reads the answer of TPM2_NV_ReadPublic: the public area
// of the index, then its name. Each field must fit its sized buffer, and no
// byte may follow. A policy longer than the largest digest is refused: no
// TPM gives one.
nv_public_answer :: proc "contextless" (answer: []u8) -> (public: Nv_Public, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return {}, code, problem
	}
	// The command has no session, so the answer has none: no size of the
	// parameters comes before them.
	_, area := take_sized(&reader)
	_, _ = take_sized(&reader) // The name.
	if reader.failed || reader.place != len(answer) || answer[0] != u8(TAG_NO_SESSIONS >> 8) || answer[1] != u8(TAG_NO_SESSIONS & 0xFF) {
		return {}, code, .Malformed
	}
	area_reader := Answer_Reader{bytes = area}
	public.index = take_u32(&area_reader)
	public.name_algorithm = take_u16(&area_reader)
	public.attributes = take_u32(&area_reader)
	_, policy := take_sized(&area_reader)
	public.data_size = take_u16(&area_reader)
	if area_reader.failed || area_reader.place != len(area) || len(policy) > NV_POLICY_LIMIT {
		return {}, code, .Malformed
	}
	copy(public.policy[:], policy)
	public.policy_size = len(policy)
	return public, code, .None
}

// floor_public_check says if a public area is the area of a TPM floor of
// this system at the index given: SHA-256, FLOOR_ATTRIBUTES with
// NV_WRITTEN set or not, the policy given, and 8 bytes. Any other area is a
// foreign index: another system defined it, or PCR 7 changed since its
// definition. A foreign index with another type, a write by another
// authorization, or a policy that another system satisfies could go down,
// or rise for another system: its value is never a floor.
floor_public_check :: proc "contextless" (public: ^Nv_Public, index: u32, policy: ^[DIGEST_SIZE]u8) -> bool {
	if public.index != index || public.name_algorithm != ALGORITHM_SHA256 || public.attributes & ~NV_WRITTEN != FLOOR_ATTRIBUTES || public.data_size != FLOOR_DATA_SIZE {
		return false
	}
	return public.policy_size == DIGEST_SIZE && string(public.policy[:DIGEST_SIZE]) == string(policy^[:])
}

// nv_read_answer reads the answer of TPM2_NV_Read of a floor: its 8 bytes,
// big-endian, as the bits of the field.
nv_read_answer :: proc "contextless" (answer: []u8) -> (bits: u64, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return 0, code, problem
	}
	parameters_begin(&reader)
	_, data := take_sized(&reader)
	if reader.failed || len(data) != FLOOR_DATA_SIZE {
		return 0, code, .Malformed
	}
	for value in data {
		bits = bits << 8 | u64(value)
	}
	return bits, code, .None
}

// floor_policy_digest gives the policy of a TPM floor for a value of PCR
// 7: TPM2_PolicyPCR from an empty policy, with the selection of PCR 7 and
// PCR 11, and the SHA-256 of the value of PCR 7 then of 32 zero bytes, the
// value of PCR 11 before the measure. The boot program computes it from
// PCR 7 now, with no session.
floor_policy_digest :: proc "contextless" (pcr_7_value: ^[DIGEST_SIZE]u8) -> [DIGEST_SIZE]u8 {
	pcr_11_before_the_measure: [DIGEST_SIZE]u8
	pcr_digest := sha256_of(pcr_7_value^[:], pcr_11_before_the_measure[:])
	return policy_pcr_digest(&pcr_digest)
}

// authorization_refused says if a response code of TPM2_NV_Read says that
// the TPM refused the authorization of the read: the index has another
// authorization value than the empty one.
authorization_refused :: proc "contextless" (code: u32) -> bool {
	if code == RESPONSE_NV_AUTHORIZATION {
		return true
	}
	return code & RESPONSE_FORMAT_ONE != 0 && (code & RESPONSE_ERROR_MASK == RESPONSE_BAD_AUTHORIZATION || code & RESPONSE_ERROR_MASK == RESPONSE_AUTHORIZATION_FAIL)
}

// floor_state_of_public decides the state of a floor from the answer of
// TPM2_NV_ReadPublic of its index (src/md/features/rollback_floors.md):
// Absent, Foreign, Never_Written, Not_Read, or Held when the bytes must be
// read. An index with the area of a floor that was never written is not
// trusted: the boot program writes each floor at once when it defines it,
// so such an index was planted, and it can hold an authorization value that
// refuses each later read. Its floor is 0 anyway.
floor_state_of_public :: proc "contextless" (problem: Answer_Problem, code: u32, public: ^Nv_Public, index: u32, policy: ^[DIGEST_SIZE]u8) -> info.Floor_State {
	switch {
	case problem == .Refused && handle_absent(code):
		return .Absent
	case problem != .None:
		return .Not_Read
	case !floor_public_check(public, index, policy):
		return .Foreign
	case public.attributes & NV_WRITTEN == 0:
		return .Never_Written
	}
	return .Held
}

// floor_state_of_read decides the state of a floor of the state Held from
// the answer of TPM2_NV_Read of its bytes: Held with its floor, Read_Refused
// when the TPM refuses the authorization (an index that another system
// planted with an authorization value), or Not_Read.
floor_state_of_read :: proc "contextless" (problem: Answer_Problem, code: u32, bits: u64) -> (state: info.Floor_State, floor: u64) {
	switch {
	case problem == .None:
		return .Held, floor_of_bits(bits)
	case problem == .Refused && authorization_refused(code):
		return .Read_Refused, 0
	}
	return .Not_Read, 0
}

// The step that a start with Secure Boot on takes for one floor before its
// raise, from the state that the boot program read.
Floor_Step :: enum u8 {
	Nothing, // The floor could not be read: it stays as it is.
	Raise, // The index is a floor of this system: set the bit of the number when it is above the floor.
	Define_Then_Raise, // No index: define it, then set the bit.
	Remove_Then_Define_Then_Raise, // An index that is not a floor that this system can read: remove it, define it, then set the bit.
}

// floor_step_of gives the step of a floor in a given state.
floor_step_of :: proc "contextless" (state: info.Floor_State) -> Floor_Step {
	switch state {
	case .Held:
		return .Raise
	case .Absent:
		return .Define_Then_Raise
	case .Foreign, .Never_Written, .Read_Refused:
		return .Remove_Then_Define_Then_Raise
	case .None, .Not_Read:
	}
	return .Nothing
}

// floor_of_bits gives the floor that the field of an index holds: the
// place of its highest set bit plus one; 0 with no bit set.
floor_of_bits :: proc "contextless" (bits: u64) -> u64 {
	floor: u64
	for place in u64(0) ..< 64 {
		if bits & (u64(1) << place) != 0 {
			floor = place + 1
		}
	}
	return floor
}

// floor_bit gives the bit that raises a floor to a number: bit number - 1.
// A number out of 1 to boot_info.FLOOR_LIMIT gives 0, which raises nothing.
floor_bit :: proc "contextless" (number: u64) -> u64 {
	if number == 0 || number > info.FLOOR_LIMIT {
		return 0
	}
	return u64(1) << (number - 1)
}
