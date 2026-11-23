// The keys, the nonces and the tags of the encryption of the stores of a
// named principal (src/md/features/store_encryption.md).
//
// The storage key of a principal comes from its unlock key
// (principals.principal_storage_key). From it, this package derives the key
// of each store, from the principal identifier and the salt of the store;
// from the key of a store, its cipher key, its tag key and its key check;
// and the name key of the principal, which gives the name tag of each of
// its stores. A block is encrypted with XChaCha20 under the cipher key,
// with a synthetic nonce: the keyed hash of its block number and of the
// check of its pointer, which comes from its clear bytes (src/md/features/store_encryption.md,
// "The nonce").
//
// No allocator and no kernel operation: the storage service and the host
// tests call the same procedures.
package store_encryption

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:cryptography_primitives"
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
NONCE_KEY_TEXT :: "modus nonce key of a store v1"
BLOCK_SIZE :: 4096 // Format property: a block of the disk.
Block :: [BLOCK_SIZE]u8
NAME_KEY_TEXT :: "modus name key of a principal v1"

// The keys of one store, in the memory of the storage service only.
Store_Keys :: struct {
	cipher: Key,
	tag:    Key,
	nonce:  Key,
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
		nonce  = keyed(store_key, NONCE_KEY_TEXT),
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

// block_nonce gives the nonce of a block: the first 24 bytes of the keyed
// BLAKE3 hash, under the nonce key of its store, of its block number and
// of the check of its pointer, each in 8 bytes little-endian. The check
// comes from the clear bytes, so two writes share a nonce only when they
// write the same bytes to the same block: the same text, the same
// cipher text, and nothing told.
//
// Example: the block 10 with the check 4 and the block 10 with the check
// 5 have two nonces.
block_nonce :: proc "contextless" (keys: ^Store_Keys, block: u64, check: u64) -> (nonce: Nonce) {
	place: [16]u8
	byte_order.write_u64_little_endian(place[:], 0, block)
	byte_order.write_u64_little_endian(place[:], 8, check)
	hash := blake3.keyed_hash(blake3.Hash(keys.nonce), place[:])
	copy(nonce[:], hash[:NONCE_SIZE])
	return nonce
}

// data_encrypt encrypts a block of data in place. check is the check of
// its pointer: the first 8 bytes of the value of its clear bytes
// (store.value_check), which the tree of the object keeps and checks after
// the decryption. data_decrypt is the same procedure.
data_encrypt :: proc "contextless" (keys: ^Store_Keys, block: u64, check: u64, bytes: ^Block) {
	nonce := block_nonce(keys, block, check)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, bytes[:])
}

data_decrypt :: data_encrypt

// xchacha20 applies the key stream of XChaCha20 to bytes, in place, for a
// field that is no block (the sealed name of a store).
xchacha20 :: proc "contextless" (key: ^Key, nonce: ^Nonce, bytes: []u8) {
	cryptography_primitives.xchacha20_xor(key, nonce, bytes)
}

// node_check gives the check of the pointer to a node: the first 8 bytes,
// little-endian, of the keyed BLAKE3 hash of its block number and its clear
// bytes under the tag key of its store. A node moved to another block, or
// changed by one bit, does not pass.
node_check :: proc "contextless" (keys: ^Store_Keys, block: u64, clear: ^Block) -> u64 {
	place: [8]u8
	byte_order.write_u64_little_endian(place[:], 0, block)
	head := blake3.keyed_hash(blake3.Hash(keys.tag), place[:])
	tag := blake3.keyed_hash(head, clear[:])
	return byte_order.read_u64_little_endian(tag[:], 0)
}

// node_seal encrypts a node in place, and gives the check of its pointer.
node_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, bytes: ^Block) -> (check: u64) {
	check = node_check(keys, block, bytes)
	nonce := block_nonce(keys, block, check)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, bytes[:])
	return check
}

// node_open decrypts a node in place and checks it against the check of
// its pointer. ok is false for a node that the key did not seal, moved or
// changed; its bytes are then erased, so no clear byte of a forgery is
// read.
node_open :: proc "contextless" (keys: ^Store_Keys, block: u64, check: u64, bytes: ^Block) -> (ok: bool) {
	nonce := block_nonce(keys, block, check)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, bytes[:])
	if node_check(keys, block, bytes) != check {
		bytes^ = {}
		return false
	}
	return true
}
