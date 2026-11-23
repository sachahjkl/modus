// The keys, the nonces and the tags of the encryption of the stores of a
// named principal (src/md/features/store_encryption.md).
//
// The storage key of a principal comes from its unlock key
// (principals.principal_storage_key). From it, this package derives the key
// of each store, from the principal identifier and the salt of the store;
// from the key of a store, its cipher key, its tag key and its key check;
// and the name key of the principal, which gives the name tag of each of
// its stores. A block is encrypted with XChaCha20 under the cipher key,
// with the nonce of its block number and the generation of its commit.
//
// No allocator and no kernel operation: the storage service and the host
// tests call the same procedures.
package store_encryption

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:principals"

KEY_SIZE :: 32 // Format property: a key of BLAKE3 and of XChaCha20.
SALT_SIZE :: 32 // Format property: 256 random bits, so two stores never draw one salt.
NONCE_SIZE :: 24 // Format property: the nonce of XChaCha20.
NAME_TAG_SIZE :: 32 // Format property: the name field of a cell of the store table.
NAME_LIMIT :: 255 // Format property: the longest name of a store.

Key :: [KEY_SIZE]u8
Salt :: [SALT_SIZE]u8
Nonce :: [NONCE_SIZE]u8
Name_Tag :: [NAME_TAG_SIZE]u8

// The domain texts: each derived key has its own, so no key is another.
STORE_KEY_TEXT :: "modus key of a store of a principal v1"
CIPHER_KEY_TEXT :: "modus cipher key of a store v1"
TAG_KEY_TEXT :: "modus tag key of a store v1"
KEY_CHECK_TEXT :: "modus key check of a store v1"
NAME_KEY_TEXT :: "modus name key of a principal v1"

// The keys of one store, in the memory of the storage service only.
Store_Keys :: struct {
	cipher: Key,
	tag:    Key,
	check:  Key, // Kept in clear in the store block: it tells the right key, and gives no key.
}

@(private = "file")
is_zero :: proc "contextless" (bytes: []u8) -> bool {
	for byte in bytes {
		if byte != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
keyed :: proc "contextless" (key: Key, text: string, extra: []u8 = nil) -> Key {
	material: [128]u8
	count := copy(material[:], text)
	count += copy(material[count:], extra)
	return blake3.keyed_hash(blake3.Hash(key), material[:count])
}

// store_keys_of gives the keys of a store. ok is false for a storage key,
// an identifier or a salt of zero bytes: no unlock, no creation and no
// store makes one, so such a value is a fault and opens nothing.
//
// Example: one storage key, one identifier and two salts give two stores
// with no key in common.
store_keys_of :: proc "contextless" (storage_key: Key, identifier: principals.Principal_Identifier, salt: Salt) -> (keys: Store_Keys, ok: bool) {
	storage_key, identifier, salt := storage_key, identifier, salt
	if is_zero(storage_key[:]) || is_zero(identifier[:]) || is_zero(salt[:]) {
		return {}, false
	}
	material: [principals.PRINCIPAL_IDENTIFIER_SIZE + SALT_SIZE]u8
	copy(material[:], identifier[:])
	copy(material[principals.PRINCIPAL_IDENTIFIER_SIZE:], salt[:])
	store_key := keyed(storage_key, STORE_KEY_TEXT, material[:])
	keys = {
		cipher = keyed(store_key, CIPHER_KEY_TEXT),
		tag    = keyed(store_key, TAG_KEY_TEXT),
		check  = keyed(store_key, KEY_CHECK_TEXT),
	}
	return keys, true
}

// key_check_matches says if the key check of a store block is the check of
// keys: a wrong key, or the key of another principal, refuses the store
// before any block is read.
key_check_matches :: proc "contextless" (keys: ^Store_Keys, kept: Key) -> bool {
	difference: u8
	for index in 0 ..< KEY_SIZE {
		difference |= keys.check[index] ~ kept[index]
	}
	return difference == 0
}

// name_key_of gives the name key of a principal. ok is false for a storage
// key of zero bytes.
name_key_of :: proc "contextless" (storage_key: Key) -> (name_key: Key, ok: bool) {
	storage_key := storage_key
	if is_zero(storage_key[:]) {
		return {}, false
	}
	return keyed(storage_key, NAME_KEY_TEXT), true
}

// name_tag gives the name tag of a store: the keyed BLAKE3 hash of its name
// under the name key of its principal. ok is false for an empty name and a
// name past NAME_LIMIT bytes.
//
// Example: the name "notes" of two principals gives two tags.
name_tag :: proc "contextless" (name_key: Key, name: string) -> (tag: Name_Tag, ok: bool) {
	if len(name) == 0 || len(name) > NAME_LIMIT {
		return {}, false
	}
	return Name_Tag(blake3.keyed_hash(blake3.Hash(name_key), transmute([]u8)name)), true
}

// block_nonce gives the nonce of a write of a block: its block number and
// the generation of the commit that writes it, each in 8 bytes
// little-endian, then 8 zero bytes. A commit writes a block number once,
// and the generation grows at each commit for the life of the disk, so
// two writes never share a nonce under one key. ok is false for the
// generation 0, which no commit has.
block_nonce :: proc "contextless" (block: u64, generation: u64) -> (nonce: Nonce, ok: bool) {
	if generation == 0 {
		return {}, false
	}
	byte_order.write_u64_little_endian(nonce[:], 0, block)
	byte_order.write_u64_little_endian(nonce[:], 8, generation)
	return nonce, true
}

// node_tag gives the full tag of the encrypted bytes of a node: the keyed
// BLAKE3 hash under the tag key of its store, with the block number and the
// generation, so a node moved to another place or another commit does not
// pass.
node_tag :: proc "contextless" (tag_key: Key, block: u64, generation: u64, encrypted: []u8) -> blake3.Hash {
	place: [16]u8
	byte_order.write_u64_little_endian(place[:], 0, block)
	byte_order.write_u64_little_endian(place[:], 8, generation)
	head := blake3.keyed_hash(blake3.Hash(tag_key), place[:])
	return blake3.keyed_hash(head, encrypted)
}

// node_check gives the check of a pointer to a node: the first 8 bytes of
// its tag, little-endian.
node_check :: proc "contextless" (tag_key: Key, block: u64, generation: u64, encrypted: []u8) -> u64 {
	tag := node_tag(tag_key, block, generation, encrypted)
	return byte_order.read_u64_little_endian(tag[:], 0)
}
