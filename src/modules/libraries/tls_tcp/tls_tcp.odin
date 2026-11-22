// TLS 1.3 over TCP and the wire borders of QUIC as a library module of the
// system (src/md/features/desktop_to_browser.md, src/md/api/library_modules.md).
//
// Each export calls the support packages `modus:tls_tcp` and `modus:quic`
// over bytes and tables of the caller, so a process that imports the module
// reads and writes the same bytes as a process that compiles the packages in.
//
// - **The caller supplies the memory**: the module allocates nothing and
//   keeps nothing between two calls. It has no package variable that is not
//   read-only: a library module has no data that the loader writes for one
//   base (src/md/api/library_modules.md, "The subtle points").
// - **The bytes are hostile input**: in an isolated call they are in the
//   call region, which another thread can change during the call. Each
//   export copies the few bytes that it reads into its own frame once, then
//   checks and reads the copy only.
// - **A refusal is an error record** and a negative result, and it writes
//   no byte and no record of the caller.
package tls_tcp_module

import "modus:contract/byte_order"
import "modus:contract/errors"
import "modus:quic"
import "modus:system"
import "modus:tls_tcp"

// The form of the header of a QUIC packet, from the Header Form bit of its
// first byte (RFC 9000, section 17.2).
Quic_Header_Form :: enum u8 {
	Short = 1, // The bit is clear: a 1-RTT packet, with no version field.
	Long  = 2, // The bit is set: a packet with a version and two connection identifiers.
}

// What quic_header_probe reads of a packet: its form and, for a long
// header, the 4 bytes of its version. The version is 0 for a short header,
// which has no version field, and for a Version Negotiation packet.
Quic_Header_Probe :: struct {
	form:    Quic_Header_Form,
	version: u32,
}

// One variable-length integer of QUIC as quic_variable_length_integer_read
// reads it: its value, from 0 to 2^62 - 1, and the bytes that it takes on
// the wire: 1, 2, 4 or 8.
Variable_Length_Integer :: struct {
	value: i64,
	size:  i64,
}

// The largest value of a variable-length integer of QUIC: 2^62 - 1.
QUIC_VARIABLE_LENGTH_INTEGER_LARGEST :: i64(quic.VARIABLE_LENGTH_INTEGER_LARGEST)

// The bytes that quic_header_probe reads of a long header: the first byte
// and the 4 bytes of the version.
QUIC_LONG_HEADER_PROBE_SIZE :: 5

// The largest variable-length integer takes 8 bytes on the wire.
@(private)
QUIC_VARIABLE_LENGTH_INTEGER_SIZE_MOST :: 8

// cipher_suite_supported reports whether `suite_word` names a TLS 1.3 cipher
// suite implemented by this module (1 = supported, 0 = unsupported).
@(export, link_name = "cipher_suite_supported")
cipher_suite_supported :: proc "c" (suite_word: i64, error: ^errors.Error_Record) -> i64 {
	if suite_word < 0 || suite_word > i64(max(u16)) {
		return errors.fail(error, -1, .Bad_Value, .None, 1, 0, i64(max(u16)), suite_word)
	}
	_, ok := tls_tcp.cipher_suite_of_word(u16(suite_word))
	return ok ? 1 : 0
}

// record_max_plaintext_bytes returns the RFC 8446 maximum plaintext record
// payload size in bytes (16 384).
@(export, link_name = "record_max_plaintext_bytes")
record_max_plaintext_bytes :: proc "c" () -> i64 {
	return i64(tls_tcp.MAX_PLAINTEXT_SIZE)
}

// record_max_ciphertext_bytes returns the RFC 8446 maximum encrypted record
// payload size in bytes (16 640).
@(export, link_name = "record_max_ciphertext_bytes")
record_max_ciphertext_bytes :: proc "c" () -> i64 {
	return i64(tls_tcp.MAX_CIPHERTEXT_SIZE)
}

// tls_record_header_parse reads the 5-byte header of a TLS 1.3 record (RFC 8446, section 5.1) at the start of the bytes of argument 1, and writes it into the first record of the table of argument 2: its content type, its legacy version and the length of its payload. The result is 5, the bytes of the header, or -1 with an error record: a nil place, or a nil address with bytes (Bad_Address); fewer than 5 bytes (Too_Small, argument 1: value the count, limit 5); a table with no record (Too_Small, argument 2, Records: value the count, limit 1); a content type that is not 20 to 23 (Bad_Value, argument 1: value the byte, limit 23, found 1, the number of the byte); a legacy version other than 0x0303 (Bad_Value, argument 1: value the version, limit 0x0303, found 2); a length over 16 640 for application data or over 16 384 for another type (Too_Long, argument 1: value the length, limit the most). The first ClientHello with the legacy version 0x0301 is refused too: the handshake of the package reads that one record. Nothing is written on a refusal.
@(export, link_name = "tls_record_header_parse")
tls_record_header_parse :: proc "c" (input: ^system.Bytes_To_Read, header: ^system.Table_To_Change(tls_tcp.Record_Header), error: ^errors.Error_Record) -> i64 {
	if input == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1)
	}
	if header == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, 0, 1)
	}
	input_count, header_count := input.count, header.count
	if input_count < tls_tcp.RECORD_HEADER_SIZE {
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, i64(input_count), tls_tcp.RECORD_HEADER_SIZE)
	}
	if input.bytes == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1, 0, i64(min(input_count, u64(max(i64)))))
	}
	if header_count < 1 {
		return errors.fail(error, -1, .Too_Small, .Records, 2, 0, 1)
	}
	if header.records == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, i64(min(header_count, u64(max(i64)))), 1)
	}
	// One copy: a byte that changes after the check is never read.
	copied: [tls_tcp.RECORD_HEADER_SIZE]u8
	copy(copied[:], input.bytes[:tls_tcp.RECORD_HEADER_SIZE])
	parsed, refusal := tls_tcp.record_parse_header(copied[:], false)
	if refusal != .None {
		return record_header_refusal(refusal, copied, error)
	}
	header.records[0] = parsed
	return tls_tcp.RECORD_HEADER_SIZE
}

// record_header_refusal turns a refusal of the header parser of the package
// into the error record of tls_record_header_parse, from the copied bytes.
@(private)
record_header_refusal :: proc "contextless" (refusal: tls_tcp.Tls_Refusal, copied: [tls_tcp.RECORD_HEADER_SIZE]u8, error: ^errors.Error_Record) -> i64 {
	copied := copied
	switch refusal {
	case .Invalid_Content_Type:
		return errors.fail(error, -1, .Bad_Value, .None, 1, i64(copied[0]), i64(max(tls_tcp.Tls_Content_Type)), 1)
	case .Invalid_Legacy_Version:
		return errors.fail(error, -1, .Bad_Value, .None, 1, i64(byte_order.read_u16_big_endian(copied[:], 1)), i64(tls_tcp.TLS_LEGACY_VERSION), 2)
	case .Record_Too_Large:
		length := i64(byte_order.read_u16_big_endian(copied[:], 3))
		return errors.fail(error, -1, .Too_Long, .Bytes, 1, length, record_payload_limit(copied[0]))
	case .Record_Header_Incomplete:
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, tls_tcp.RECORD_HEADER_SIZE - 1, tls_tcp.RECORD_HEADER_SIZE)
	case .None, .Invalid_Role, .Invalid_Configuration, .Invalid_State, .Invalid_Cipher_Suite, .Record_Incomplete, .Sequence_Exhausted, .Authentication_Failed, .Inner_Content_Missing, .Handshake_Incomplete, .Unexpected_Handshake_Message, .Downgrade_Refused, .Unsupported_Cipher_Suite, .Missing_Required_Extension, .Duplicate_Extension, .Invalid_Key_Share, .Invalid_Certificate, .Invalid_Certificate_Verify, .Invalid_Finished, .Malformed_Message, .Buffer_Too_Small, .Transcript_Full, .Crypto_Failed, .Peer_Closed, .Peer_Alert:
	}
	// The parser of a header gives none of the other refusals: a new one is
	// a fault of this module, and it still ends as a refusal, never as a
	// header.
	return errors.fail(error, -1, .Bad_Value, .None, 1, i64(refusal))
}

// record_payload_limit gives the most payload bytes of a record of a
// content type byte: an encrypted record holds 256 bytes more (RFC 8446,
// section 5.2).
@(private)
record_payload_limit :: proc "contextless" (content_type_byte: u8) -> i64 {
	if content_type_byte == u8(tls_tcp.Tls_Content_Type.Application_Data) {
		return tls_tcp.MAX_CIPHERTEXT_SIZE
	}
	return tls_tcp.MAX_PLAINTEXT_SIZE
}

// tls_record_header_write writes the 5-byte header of a TLS 1.3 record (RFC 8446, section 5.1) at the start of the bytes of argument 3: the content type, the legacy version 0x0303, and the payload length, the most significant byte first. The result is 5, or -1 with an error record: a content type that is not 20 to 23 (Bad_Value, argument 1: value the word, limit 23); a negative length (Bad_Value, argument 2: value the length, limit the most); a length over 16 640 for application data or over 16 384 for another type (Too_Long, argument 2: value the length, limit the most); a nil place, or a nil address with bytes (Bad_Address, argument 3, found 1); fewer than 5 bytes (Too_Small, argument 3: value the count, limit 5). Nothing is written on a refusal.
@(export, link_name = "tls_record_header_write")
tls_record_header_write :: proc "c" (content_type_word: i64, payload_length: i64, output: ^system.Bytes_To_Change, error: ^errors.Error_Record) -> i64 {
	largest_content_type := i64(max(tls_tcp.Tls_Content_Type))
	if content_type_word < 0 || content_type_word > i64(max(u8)) {
		return errors.fail(error, -1, .Bad_Value, .None, 1, content_type_word, largest_content_type)
	}
	content_type, known := tls_tcp.content_type_of_word(u8(content_type_word))
	if !known {
		return errors.fail(error, -1, .Bad_Value, .None, 1, content_type_word, largest_content_type)
	}
	limit := record_payload_limit(u8(content_type))
	if payload_length < 0 {
		return errors.fail(error, -1, .Bad_Value, .Bytes, 2, payload_length, limit)
	}
	if payload_length > limit {
		return errors.fail(error, -1, .Too_Long, .Bytes, 2, payload_length, limit)
	}
	if output == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 3, 0, 0, 1)
	}
	output_count := output.count
	if output_count < tls_tcp.RECORD_HEADER_SIZE {
		return errors.fail(error, -1, .Too_Small, .Bytes, 3, i64(output_count), tls_tcp.RECORD_HEADER_SIZE)
	}
	if output.bytes == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 3, 0, i64(min(output_count, u64(max(i64)))), 1)
	}
	written := output.bytes[:tls_tcp.RECORD_HEADER_SIZE]
	written[0] = u8(content_type)
	byte_order.write_u16_big_endian(written, 1, tls_tcp.TLS_LEGACY_VERSION)
	byte_order.write_u16_big_endian(written, 3, u16(payload_length))
	return tls_tcp.RECORD_HEADER_SIZE
}

// quic_variable_length_integer_read reads the variable-length integer of QUIC (RFC 9000, section 16) at the start of the bytes of argument 1, and writes its value and its size into the first record of the table of argument 2. The result is the bytes that it takes, 1, 2, 4 or 8, or -1 with an error record: a nil place, or a nil address with bytes (Bad_Address); no byte (Too_Small, argument 1: value 0, limit 1); fewer bytes than the two high bits of the first byte name (Too_Small, argument 1: value the count, limit the size); a table with no record (Too_Small, argument 2, Records: value the count, limit 1). It accepts an encoding longer than the shortest, as RFC 9000 does outside a frame type. Nothing is written on a refusal.
@(export, link_name = "quic_variable_length_integer_read")
quic_variable_length_integer_read :: proc "c" (input: ^system.Bytes_To_Read, integer: ^system.Table_To_Change(Variable_Length_Integer), error: ^errors.Error_Record) -> i64 {
	if input == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1)
	}
	if integer == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, 0, 1)
	}
	input_count, integer_count := input.count, integer.count
	if input_count < 1 {
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, 0, 1)
	}
	if input.bytes == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1, 0, i64(min(input_count, u64(max(i64)))))
	}
	if integer_count < 1 {
		return errors.fail(error, -1, .Too_Small, .Records, 2, 0, 1)
	}
	if integer.records == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, i64(min(integer_count, u64(max(i64)))), 1)
	}
	// One copy of at most 8 bytes: the size comes from the first byte of
	// the copy, so a byte that changes after the check is never read.
	copied: [QUIC_VARIABLE_LENGTH_INTEGER_SIZE_MOST]u8
	available := int(min(input_count, QUIC_VARIABLE_LENGTH_INTEGER_SIZE_MOST))
	copy(copied[:available], input.bytes[:available])
	size := 1 << (copied[0] >> 6)
	value, read_size, ok := quic.variable_length_integer_read(copied[:available], 0)
	if !ok || read_size != size {
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, i64(available), i64(size))
	}
	integer.records[0] = {value = i64(value), size = i64(size)}
	return i64(size)
}

// quic_variable_length_integer_write writes a value as a variable-length integer of QUIC (RFC 9000, section 16), in its shortest encoding, at the start of the bytes of argument 2. The result is the bytes written, 1, 2, 4 or 8, or -1 with an error record: a negative value or a value over 2^62 - 1 (Bad_Value, argument 1: value the value, limit 2^62 - 1); a nil place, or a nil address with bytes (Bad_Address, argument 2, found 1); fewer bytes than the encoding takes (Too_Small, argument 2: value the count, limit the size). Nothing is written on a refusal.
@(export, link_name = "quic_variable_length_integer_write")
quic_variable_length_integer_write :: proc "c" (value: i64, output: ^system.Bytes_To_Change, error: ^errors.Error_Record) -> i64 {
	if value < 0 || value > QUIC_VARIABLE_LENGTH_INTEGER_LARGEST {
		return errors.fail(error, -1, .Bad_Value, .None, 1, value, QUIC_VARIABLE_LENGTH_INTEGER_LARGEST)
	}
	if output == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 2, 0, 0, 1)
	}
	size := quic.variable_length_integer_size(u64(value))
	output_count := output.count
	if output_count < u64(size) {
		return errors.fail(error, -1, .Too_Small, .Bytes, 2, i64(output_count), i64(size))
	}
	if output.bytes == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 2, 0, i64(min(output_count, u64(max(i64)))), 1)
	}
	return i64(quic.variable_length_integer_write(output.bytes[:size], 0, u64(value), size))
}

// quic_header_probe reads the form of the header of a QUIC packet at the start of the bytes of argument 1 and, for a long header, its version (RFC 9000, sections 17.2 and 17.3), into the first record of the table of argument 2. It is the first look of a receiver, before it chooses a connection: it reads no connection identifier and no length. The result is the bytes read, 1 for a short header and 5 for a long header, or -1 with an error record: a nil place, or a nil address with bytes (Bad_Address); no byte, or a long header of fewer than 5 bytes (Too_Small, argument 1: value the count, limit 1 or 5); a table with no record (Too_Small, argument 2, Records: value the count, limit 1); the Fixed Bit clear in a short header or in a long header of version 1 (Bad_Value, argument 1: value the first byte, limit 0x40, found 1, the number of the byte). A long header of another version, Version Negotiation (version 0) included, has no Fixed Bit to check. Nothing is written on a refusal.
@(export, link_name = "quic_header_probe")
quic_header_probe :: proc "c" (packet: ^system.Bytes_To_Read, probe: ^system.Table_To_Change(Quic_Header_Probe), error: ^errors.Error_Record) -> i64 {
	if packet == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1)
	}
	if probe == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, 0, 1)
	}
	packet_count, probe_count := packet.count, probe.count
	if packet_count < 1 {
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, 0, 1)
	}
	if packet.bytes == nil {
		return errors.fail(error, -1, .Bad_Address, .Bytes, 1, 0, i64(min(packet_count, u64(max(i64)))))
	}
	if probe_count < 1 {
		return errors.fail(error, -1, .Too_Small, .Records, 2, 0, 1)
	}
	if probe.records == nil {
		return errors.fail(error, -1, .Bad_Address, .Records, 2, 0, i64(min(probe_count, u64(max(i64)))), 1)
	}
	copied: [QUIC_LONG_HEADER_PROBE_SIZE]u8
	available := int(min(packet_count, QUIC_LONG_HEADER_PROBE_SIZE))
	copy(copied[:available], packet.bytes[:available])
	first := copied[0]
	if first & quic.LONG_HEADER_FORM == 0 {
		if first & quic.FIXED_BIT == 0 {
			return errors.fail(error, -1, .Bad_Value, .None, 1, i64(first), quic.FIXED_BIT, 1)
		}
		probe.records[0] = {form = .Short, version = 0}
		return 1
	}
	if available < QUIC_LONG_HEADER_PROBE_SIZE {
		return errors.fail(error, -1, .Too_Small, .Bytes, 1, i64(available), QUIC_LONG_HEADER_PROBE_SIZE)
	}
	version := byte_order.read_u32_big_endian(copied[:], 1)
	// Only version 1 gives the Fixed Bit a meaning: a Version Negotiation
	// packet and an unknown version keep the invariants of RFC 8999 only.
	if version == quic.QUIC_VERSION_1 && first & quic.FIXED_BIT == 0 {
		return errors.fail(error, -1, .Bad_Value, .None, 1, i64(first), quic.FIXED_BIT, 1)
	}
	probe.records[0] = {form = .Long, version = version}
	return QUIC_LONG_HEADER_PROBE_SIZE
}
