// Strict TPM 2.0 TPMS_ATTEST remote attestation quote parser and verifier
// (src/md/features/rollback_floors.md).
//
// A valid quote proves that a TPM generated the attestation over the caller's
// fresh 32-byte nonce, with PCR 7 (Secure Boot), PCR 11 (signed system
// description), and PCR 12 (start policy) all selected in the SHA-256 bank,
// and a composite PCR digest matching SHA-256(PCR7 || PCR11 || PCR12).
package tpm_attestation

import "modus:contract/byte_order"

// TPM_GENERATED_VALUE magic identifying genuine TPM-produced attestation data.
TPM_GENERATED_VALUE :: u32(0xFF54_4347)

// TPM_ST_ATTEST_QUOTE structure tag for TPM2_Quote attestation bodies.
TPM_ST_ATTEST_QUOTE :: u16(0x8018)

// TPM_ALG_SHA256 hash algorithm identifier for the SHA-256 PCR bank.
TPM_ALG_SHA256 :: u16(0x000B)

// Fresh caller nonce length required in TPMS_ATTEST.extraData.
QUOTE_NONCE_SIZE :: 32

// Maximum TPM2B_NAME length accepted for qualifiedSigner (handles up to SHA-512).
MAX_QUALIFIED_SIGNER_SIZE :: 68

// Minimum TPM2B_NAME length (2-byte algorithm prefix or handle).
MIN_QUALIFIED_SIGNER_SIZE :: 2

// Standard TPM 2.0 PCR selection bitmap bounds (2 to 4 bytes cover PCR 0..31).
MIN_PCR_SELECT_BYTES :: 2
MAX_PCR_SELECT_BYTES :: 4

// Bitmask of the three required PCRs: PCR 7, PCR 11, and PCR 12.
REQUIRED_PCR_MASK :: u32((1 << 7) | (1 << 11) | (1 << 12))

// Closed set of refusals for TPMS_ATTEST quote parsing and verification.
Quote_Refusal :: enum u8 {
	None                       = 0,
	Truncated                  = 1,
	Trailing_Bytes             = 2,
	Bad_Magic                  = 3,
	Bad_Attest_Type            = 4,
	Bad_Qualified_Signer       = 5,
	Zero_Expected_Nonce        = 6,
	Nonce_Length_Mismatch      = 7,
	Nonce_Mismatch             = 8,
	Bad_Clock_Safe_Flag        = 9,
	Bad_Pcr_Selection_Count    = 10,
	Unsupported_Hash_Algorithm = 11,
	Bad_Pcr_Select_Size        = 12,
	Missing_Required_Pcrs      = 13,
	Unexpected_Pcr_Selected    = 14,
	Bad_Pcr_Digest_Length      = 15,
	Pcr_Digest_Mismatch        = 16,
	Missing_Verifier           = 17,
	Signature_Invalid          = 18,
	Buffer_Too_Small           = 19,
}

// Parsed TPMS_CLOCK_INFO record from TPMS_ATTEST.
Clock_Info :: struct {
	clock:         u64,
	reset_count:   u32,
	restart_count: u32,
	safe:          bool,
}

// Parsed and validated TPMS_ATTEST quote structure.
Parsed_Quote :: struct {
	qualified_signer:        [MAX_QUALIFIED_SIGNER_SIZE]u8,
	qualified_signer_length: u16,
	extra_data:              [QUOTE_NONCE_SIZE]u8,
	clock_info:              Clock_Info,
	firmware_version:        u64,
	pcr_mask:                u32,
	pcr_digest:              Digest,
}

// Expected SHA-256 values of the three measured PCRs for a signed system.
Expected_Pcr_Values :: struct {
	pcr7_secure_boot:     Digest,
	pcr11_system_measure: Digest,
	pcr12_start_policy:   Digest,
}

// Caller-provided signature verifier invoked over the exact TPMS_ATTEST bytes
// and their SHA-256 digest.
Quote_Signature_Verify_Proc :: #type proc "contextless" (
	attest_bytes: []u8,
	attest_digest: Digest,
	signature: []u8,
	user_data: rawptr,
) -> bool

// compute_expected_pcr_digest computes SHA-256(PCR7 || PCR11 || PCR12),
// matching the ascending PCR index order specified by TPM 2.0 TPM2_Quote.
compute_expected_pcr_digest :: proc "contextless" (expected: Expected_Pcr_Values) -> Digest {
	p7 := expected.pcr7_secure_boot
	p11 := expected.pcr11_system_measure
	p12 := expected.pcr12_start_policy
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update(&ctx, p7[:])
	sha256_update(&ctx, p11[:])
	sha256_update(&ctx, p12[:])
	return sha256_final(&ctx)
}

// build_tpms_attest_quote encodes a canonical TPMS_ATTEST quote buffer into
// destination. Returns written byte count and .None on success.
build_tpms_attest_quote :: proc "contextless" (
	qualified_signer: []u8,
	extra_data: [QUOTE_NONCE_SIZE]u8,
	clock_info: Clock_Info,
	firmware_version: u64,
	pcr_mask: u32,
	pcr_select_size: int,
	pcr_digest: Digest,
	destination: []u8,
) -> (written: int, refusal: Quote_Refusal) {
	if len(qualified_signer) < MIN_QUALIFIED_SIGNER_SIZE || len(qualified_signer) > MAX_QUALIFIED_SIGNER_SIZE {
		return 0, .Bad_Qualified_Signer
	}
	if pcr_select_size < MIN_PCR_SELECT_BYTES || pcr_select_size > MAX_PCR_SELECT_BYTES {
		return 0, .Bad_Pcr_Select_Size
	}
	// Fixed fields: magic(4) + type(2) + qs_len(2) + qs + ed_len(2) + ed(32)
	// + clock(8+4+4+1) + fw(8) + sel_count(4) + hash(2) + sel_size(1) + sel
	// + dig_len(2) + dig(32).
	total := 4 + 2 + 2 + len(qualified_signer) + 2 + QUOTE_NONCE_SIZE + 17 + 8 + 4 + 2 + 1 + pcr_select_size + 2 + SHA256_SIZE
	if len(destination) < total {
		return 0, .Buffer_Too_Small
	}

	pos := 0
	byte_order.write_u32_big_endian(destination, pos, TPM_GENERATED_VALUE)
	pos += 4
	byte_order.write_u16_big_endian(destination, pos, TPM_ST_ATTEST_QUOTE)
	pos += 2

	byte_order.write_u16_big_endian(destination, pos, u16(len(qualified_signer)))
	pos += 2
	copy(destination[pos:pos + len(qualified_signer)], qualified_signer)
	pos += len(qualified_signer)

	ed := extra_data
	byte_order.write_u16_big_endian(destination, pos, QUOTE_NONCE_SIZE)
	pos += 2
	copy(destination[pos:pos + QUOTE_NONCE_SIZE], ed[:])
	pos += QUOTE_NONCE_SIZE

	byte_order.write_u64_big_endian(destination, pos, clock_info.clock)
	pos += 8
	byte_order.write_u32_big_endian(destination, pos, clock_info.reset_count)
	pos += 4
	byte_order.write_u32_big_endian(destination, pos, clock_info.restart_count)
	pos += 4
	destination[pos] = clock_info.safe ? 1 : 0
	pos += 1

	byte_order.write_u64_big_endian(destination, pos, firmware_version)
	pos += 8

	// TPML_PCR_SELECTION with 1 SHA-256 bank.
	byte_order.write_u32_big_endian(destination, pos, 1)
	pos += 4
	byte_order.write_u16_big_endian(destination, pos, TPM_ALG_SHA256)
	pos += 2
	destination[pos] = u8(pcr_select_size)
	pos += 1
	for b in 0 ..< pcr_select_size {
		destination[pos + b] = u8((pcr_mask >> uint(b * 8)) & 0xFF)
	}
	pos += pcr_select_size

	dig := pcr_digest
	byte_order.write_u16_big_endian(destination, pos, SHA256_SIZE)
	pos += 2
	copy(destination[pos:pos + SHA256_SIZE], dig[:])
	pos += SHA256_SIZE

	return pos, .None
}

// parse_tpms_attest_quote strictly parses TPMS_ATTEST bytes for a quote,
// verifying magic, type, qualifiedSigner bounds, exact 32-byte fresh nonce,
// clockInfo safe flag, SHA-256 PCR selection covering PCR 7, 11, and 12,
// 32-byte pcrDigest, and absence of trailing bytes.
parse_tpms_attest_quote :: proc "contextless" (
	attest_bytes: []u8,
	expected_nonce: [QUOTE_NONCE_SIZE]u8,
) -> (quote: Parsed_Quote, refusal: Quote_Refusal) {
	exp_nonce := expected_nonce
	if is_all_zero(exp_nonce[:]) {
		return {}, .Zero_Expected_Nonce
	}

	pos := 0
	if len(attest_bytes) < 6 {
		return {}, .Truncated
	}
	magic := byte_order.read_u32_big_endian(attest_bytes, pos)
	pos += 4
	if magic != TPM_GENERATED_VALUE {
		return {}, .Bad_Magic
	}
	attest_type := byte_order.read_u16_big_endian(attest_bytes, pos)
	pos += 2
	if attest_type != TPM_ST_ATTEST_QUOTE {
		return {}, .Bad_Attest_Type
	}

	// qualifiedSigner (TPM2B_NAME)
	if pos + 2 > len(attest_bytes) {
		return {}, .Truncated
	}
	qs_len := int(byte_order.read_u16_big_endian(attest_bytes, pos))
	pos += 2
	if qs_len < MIN_QUALIFIED_SIGNER_SIZE || qs_len > MAX_QUALIFIED_SIGNER_SIZE {
		return {}, .Bad_Qualified_Signer
	}
	if pos + qs_len > len(attest_bytes) {
		return {}, .Truncated
	}
	parsed: Parsed_Quote
	parsed.qualified_signer_length = u16(qs_len)
	copy(parsed.qualified_signer[:qs_len], attest_bytes[pos:pos + qs_len])
	pos += qs_len

	// extraData (TPM2B_DATA): must equal the caller's 32-byte fresh nonce.
	if pos + 2 > len(attest_bytes) {
		return {}, .Truncated
	}
	ed_len := int(byte_order.read_u16_big_endian(attest_bytes, pos))
	pos += 2
	if pos + ed_len > len(attest_bytes) {
		return {}, .Truncated
	}
	if ed_len != QUOTE_NONCE_SIZE {
		return {}, .Nonce_Length_Mismatch
	}
	if !constant_time_equal(attest_bytes[pos:pos + QUOTE_NONCE_SIZE], exp_nonce[:]) {
		return {}, .Nonce_Mismatch
	}
	copy(parsed.extra_data[:], attest_bytes[pos:pos + QUOTE_NONCE_SIZE])
	pos += QUOTE_NONCE_SIZE

	// clockInfo (TPMS_CLOCK_INFO: 17 bytes)
	if pos + 17 > len(attest_bytes) {
		return {}, .Truncated
	}
	parsed.clock_info.clock = byte_order.read_u64_big_endian(attest_bytes, pos)
	pos += 8
	parsed.clock_info.reset_count = byte_order.read_u32_big_endian(attest_bytes, pos)
	pos += 4
	parsed.clock_info.restart_count = byte_order.read_u32_big_endian(attest_bytes, pos)
	pos += 4
	safe_byte := attest_bytes[pos]
	pos += 1
	if safe_byte != 0 && safe_byte != 1 {
		return {}, .Bad_Clock_Safe_Flag
	}
	parsed.clock_info.safe = safe_byte == 1

	// firmwareVersion (8 bytes)
	if pos + 8 > len(attest_bytes) {
		return {}, .Truncated
	}
	parsed.firmware_version = byte_order.read_u64_big_endian(attest_bytes, pos)
	pos += 8

	// TPMS_QUOTE_INFO.pcrSelect (TPML_PCR_SELECTION)
	if pos + 4 > len(attest_bytes) {
		return {}, .Truncated
	}
	selection_count := byte_order.read_u32_big_endian(attest_bytes, pos)
	pos += 4
	if selection_count != 1 {
		return {}, .Bad_Pcr_Selection_Count
	}
	if pos + 3 > len(attest_bytes) {
		return {}, .Truncated
	}
	hash_alg := byte_order.read_u16_big_endian(attest_bytes, pos)
	pos += 2
	if hash_alg != TPM_ALG_SHA256 {
		return {}, .Unsupported_Hash_Algorithm
	}
	select_size := int(attest_bytes[pos])
	pos += 1
	if select_size < MIN_PCR_SELECT_BYTES || select_size > MAX_PCR_SELECT_BYTES {
		return {}, .Bad_Pcr_Select_Size
	}
	if pos + select_size > len(attest_bytes) {
		return {}, .Truncated
	}
	pcr_mask: u32 = 0
	for b in 0 ..< select_size {
		pcr_mask |= u32(attest_bytes[pos + b]) << uint(b * 8)
	}
	pos += select_size
	if (pcr_mask & REQUIRED_PCR_MASK) != REQUIRED_PCR_MASK {
		return {}, .Missing_Required_Pcrs
	}
	if pcr_mask != REQUIRED_PCR_MASK {
		return {}, .Unexpected_Pcr_Selected
	}
	parsed.pcr_mask = pcr_mask

	// TPMS_QUOTE_INFO.pcrDigest (TPM2B_DIGEST)
	if pos + 2 > len(attest_bytes) {
		return {}, .Truncated
	}
	digest_len := int(byte_order.read_u16_big_endian(attest_bytes, pos))
	pos += 2
	if pos + digest_len > len(attest_bytes) {
		return {}, .Truncated
	}
	if digest_len != SHA256_SIZE {
		return {}, .Bad_Pcr_Digest_Length
	}
	copy(parsed.pcr_digest[:], attest_bytes[pos:pos + SHA256_SIZE])
	pos += SHA256_SIZE

	if pos != len(attest_bytes) {
		return {}, .Trailing_Bytes
	}
	return parsed, .None
}

// verify_attestation_quote performs full remote attestation quote verification:
// parses TPMS_ATTEST, checks PCR 7/11/12 digest against expected signed system
// values, and invokes the caller's signature verifier over attest_bytes and
// its SHA-256 digest. Returns zeroed Parsed_Quote on any refusal.
verify_attestation_quote :: proc "contextless" (
	attest_bytes: []u8,
	signature: []u8,
	expected_nonce: [QUOTE_NONCE_SIZE]u8,
	expected_pcrs: Expected_Pcr_Values,
	verify_signature: Quote_Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> (quote: Parsed_Quote, refusal: Quote_Refusal) {
	if verify_signature == nil {
		return {}, .Missing_Verifier
	}
	if len(signature) == 0 {
		return {}, .Signature_Invalid
	}
	parsed, parse_refusal := parse_tpms_attest_quote(attest_bytes, expected_nonce)
	if parse_refusal != .None {
		return {}, parse_refusal
	}
	expected_digest := compute_expected_pcr_digest(expected_pcrs)
	if !constant_time_equal(parsed.pcr_digest[:], expected_digest[:]) {
		return {}, .Pcr_Digest_Mismatch
	}
	attest_digest := sha256_sum(attest_bytes)
	if !verify_signature(attest_bytes, attest_digest, signature, user_data) {
		return {}, .Signature_Invalid
	}
	return parsed, .None
}
