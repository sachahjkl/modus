// Strict known-hosts verification table for SSH-2 host keys.
//
// No silent trust-on-first-use is permitted: an unknown host is always refused
// with Unknown_Host_Key, and a changed host key is always refused with
// Host_Key_Mismatch using constant-time key comparison.
package ssh_client

import crypto "modus:cryptography/compatibility_crypto"

MAX_KNOWN_HOSTS :: 32
MAX_HOST_NAME_LENGTH :: 128

Known_Host_Entry :: struct {
	host:       [MAX_HOST_NAME_LENGTH]u8,
	host_len:   int,
	port:       u16,
	public_key: [ED25519_PUBLIC_KEY_SIZE]u8,
	occupied:   bool,
}

Known_Hosts :: struct {
	entries: [MAX_KNOWN_HOSTS]Known_Host_Entry,
	count:   int,
}

known_hosts_init :: proc "contextless" (table: ^Known_Hosts) {
	if table == nil {
		return
	}
	table^ = {}
}

// known_hosts_add pins an Ed25519 host key for a (host, port) pair.
// Refuses empty/oversized hosts, port 0, conflicting keys for an existing host, or a full table.
known_hosts_add :: proc "contextless" (table: ^Known_Hosts, host: string, port: u16, public_key: [ED25519_PUBLIC_KEY_SIZE]u8) -> Status {
	public_key := public_key
	if table == nil || len(host) == 0 || len(host) > MAX_HOST_NAME_LENGTH || port == 0 {
		return .Invalid_Argument
	}
	host_bytes := transmute([]u8)host
	// Refuse NUL or control characters in hostnames.
	for b in host_bytes {
		if b <= 0x20 || b >= 0x7F {
			return .Invalid_Argument
		}
	}
	free_slot := -1
	for i in 0 ..< MAX_KNOWN_HOSTS {
		entry := &table.entries[i]
		if !entry.occupied {
			if free_slot < 0 {
				free_slot = i
			}
			continue
		}
		if entry.port == port && bytes_equal(entry.host[:entry.host_len], host_bytes) {
			if crypto.compare_constant_time(entry.public_key[:], public_key[:]) == 1 {
				return .Ok
			}
			return .Host_Key_Mismatch
		}
	}
	if free_slot < 0 {
		return .Table_Full
	}
	entry := &table.entries[free_slot]
	copy(entry.host[:], host_bytes)
	entry.host_len = len(host_bytes)
	entry.port = port
	entry.public_key = public_key
	entry.occupied = true
	table.count += 1
	return .Ok
}

// known_hosts_verify checks an offered Ed25519 host key against the pinned table.
known_hosts_verify :: proc "contextless" (table: ^Known_Hosts, host: string, port: u16, offered_public_key: [ED25519_PUBLIC_KEY_SIZE]u8) -> Status {
	offered_public_key := offered_public_key
	if table == nil || len(host) == 0 || len(host) > MAX_HOST_NAME_LENGTH || port == 0 {
		return .Invalid_Argument
	}
	host_bytes := transmute([]u8)host
	for i in 0 ..< MAX_KNOWN_HOSTS {
		entry := &table.entries[i]
		if !entry.occupied {
			continue
		}
		if entry.port == port && bytes_equal(entry.host[:entry.host_len], host_bytes) {
			if crypto.compare_constant_time(entry.public_key[:], offered_public_key[:]) == 1 {
				return .Ok
			}
			return .Host_Key_Mismatch
		}
	}
	return .Unknown_Host_Key
}

// known_hosts_remove deletes a pinned (host, port) entry if present.
known_hosts_remove :: proc "contextless" (table: ^Known_Hosts, host: string, port: u16) -> bool {
	if table == nil || len(host) == 0 || len(host) > MAX_HOST_NAME_LENGTH || port == 0 {
		return false
	}
	host_bytes := transmute([]u8)host
	for i in 0 ..< MAX_KNOWN_HOSTS {
		entry := &table.entries[i]
		if !entry.occupied {
			continue
		}
		if entry.port == port && bytes_equal(entry.host[:entry.host_len], host_bytes) {
			entry^ = {}
			table.count -= 1
			return true
		}
	}
	return false
}
