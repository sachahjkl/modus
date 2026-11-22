// Thin library module exposing SSH-2 client framing and validation exports so
// processes share one verified SSH-2 client implementation.
package ssh_client_module

import "modus:contract/errors"
import "modus:ssh_client"

ERROR :: -1

// client_banner writes the SSH-2 client identification banner ("SSH-2.0-modus\r\n")
// into result and returns the byte count (or the needed size if result is shorter).
@(export, link_name = "client_banner")
client_banner :: proc "c" (result: ^[]u8) -> i64 {
	needed := len(ssh_client.CLIENT_BANNER) + 2
	buf := result^
	if len(buf) < needed {
		return i64(needed)
	}
	written, status := ssh_client.banner_write(buf)
	if status != .Ok {
		return i64(needed)
	}
	return i64(written)
}

// parse_server_banner validates an SSH-2.0 server identification banner and copies
// the trimmed banner into result. Refuses SSH-1.x, NUL bytes, and oversized banners
// with an error record.
@(export, link_name = "parse_server_banner")
parse_server_banner :: proc "c" (input: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	raw := transmute([]u8)(input^)
	if len(raw) == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, 1)
	}
	banner, _, status := ssh_client.banner_parse(raw)
	if status != .Ok {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1, i64(status))
	}
	buf := result^
	if len(buf) < len(banner) {
		return i64(len(banner))
	}
	copy(buf[:len(banner)], banner)
	return i64(len(banner))
}

// parse_ed25519_host_key validates an SSH ssh-ed25519 host key blob and writes the
// 32-byte Ed25519 public key into result, failing with an error record on malformed input.
@(export, link_name = "parse_ed25519_host_key")
parse_ed25519_host_key :: proc "c" (blob: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	raw := transmute([]u8)(blob^)
	if len(raw) == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, 1)
	}
	pub, status := ssh_client.parse_ssh_ed25519_public_key(raw)
	if status != .Ok {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1, i64(status))
	}
	buf := result^
	if len(buf) < ssh_client.ED25519_PUBLIC_KEY_SIZE {
		return ssh_client.ED25519_PUBLIC_KEY_SIZE
	}
	copy(buf[:ssh_client.ED25519_PUBLIC_KEY_SIZE], pub[:])
	return ssh_client.ED25519_PUBLIC_KEY_SIZE
}
