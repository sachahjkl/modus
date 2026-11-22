// TLS 1.3 over TCP as a library module of the system
// (src/md/features/desktop_to_browser.md).
//
// Exposes the RFC 8446 TLS 1.3 record framing and cipher-suite checks from
// the support package `modus:tls_tcp` so processes can share one audited TLS
// implementation over TCP streams.
package tls_tcp_module

import "modus:contract/errors"
import "modus:tls_tcp"

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
