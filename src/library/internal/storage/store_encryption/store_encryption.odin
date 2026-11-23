// The keys, the nonces and the tags of the encryption of the stores of a
// named principal (src/md/features/store_encryption.md).
//
// The storage key of a principal comes from its unlock key
// (principals.principal_storage_key). From it, this package derives the key
// of each store, from the principal identifier and the salt of the store;
// from the key of a store, its cipher key, its tag key, its nonce key and
// its key check; and the name key of the principal, which gives the name
// tag of each of its stores.
//
// Each metadata block of an encrypted store keeps its structural pointers
// in clear so keyless open and count repair can walk the disk while
// principals are locked, encrypts its secret fields with XChaCha20 under a
// synthetic nonce derived from its block kind, block number and 128-bit SIV
// MAC, and authenticates the whole 4096-byte block with that MAC. Data
// blocks are encrypted whole under a domain-separated nonce derived from
// the block number and the plaintext value_check.
//
// No allocator and no kernel operation: the storage service and the host
// tests call the same procedures.
package store_encryption

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/store"
import "modus:cryptography_primitives"
import "modus:principals"

KEY_SIZE :: 32 // Format property: a key of BLAKE3 and of XChaCha20.
SALT_SIZE :: 32 // Format property: 256 random bits, so two stores never draw one salt.
NONCE_SIZE :: 24 // Format property: the nonce of XChaCha20.
MAC_SIZE :: store.MAC_SIZE // Format property: 128-bit SIV authentication tag.
NAME_TAG_SIZE :: 32 // Format property: the name field of a cell of the store table.
NAME_LIMIT :: 255 // Format property: the longest name of a store.

Key :: [KEY_SIZE]u8
Salt :: [SALT_SIZE]u8
Nonce :: [NONCE_SIZE]u8
Mac :: [MAC_SIZE]u8
Name_Tag :: [NAME_TAG_SIZE]u8

// Block_Kind separates MACs and nonces across on-disk block formats so a
// valid block of one kind cannot be substituted as another kind.
Block_Kind :: enum u8 {
	Store_Block   = 1,
	Tree_Node     = 2,
	Object_Node   = 3,
	Version_Index = 4,
	Version_Leaf  = 5,
	Release_List  = 6,
	Data_Block    = 7,
}

// The domain texts: each derived key has its own, so no key is another.
STORE_KEY_TEXT :: "modus key of a store of a principal v1"
CIPHER_KEY_TEXT :: "modus cipher key of a store v1"
TAG_KEY_TEXT :: "modus tag key of a store v1"
KEY_CHECK_TEXT :: "modus key check of a store v1"
NONCE_KEY_TEXT :: "modus nonce key of a store v1"
BLOCK_SIZE :: store.BLOCK_SIZE // Format property: a block of the disk.
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
mac_equal :: proc "contextless" (a, b: Mac) -> bool {
	difference: u8
	for index in 0 ..< MAC_SIZE {
		difference |= a[index] ~ b[index]
	}
	return difference == 0
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
	intrinsics.mem_zero_volatile(&store_key, size_of(store_key))
	intrinsics.mem_zero_volatile(&material, size_of(material))
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

// block_nonce gives a 24-byte nonce from two 64-bit words under the nonce
// key of a store (used with (0, 0) for the sealed name of a store).
// Metadata SIV nonces (25-byte input) and data block nonces (17-byte input)
// are domain-separated from this 16-byte input.
block_nonce :: proc "contextless" (keys: ^Store_Keys, block: u64, check: u64) -> (nonce: Nonce) {
	place: [16]u8
	byte_order.write_u64_little_endian(place[:], 0, block)
	byte_order.write_u64_little_endian(place[:], 8, check)
	hash := blake3.keyed_hash(blake3.Hash(keys.nonce), place[:])
	copy(nonce[:], hash[:NONCE_SIZE])
	return nonce
}

// xchacha20 applies the key stream of XChaCha20 to bytes, in place, for a
// field that is no block (the sealed name of a store).
xchacha20 :: proc "contextless" (key: ^Key, nonce: ^Nonce, bytes: []u8) {
	cryptography_primitives.xchacha20_xor(key, nonce, bytes)
}

// block_mac computes the 128-bit SIV authentication tag over a full
// 4096-byte plaintext metadata block whose mac field has been zeroed.
@(private = "file")
block_mac :: proc "contextless" (keys: ^Store_Keys, kind: Block_Kind, block: u64, clear_with_zero_mac: ^Block) -> (mac: Mac) {
	place: [9]u8
	place[0] = u8(kind)
	byte_order.write_u64_little_endian(place[:], 1, block)
	head := blake3.keyed_hash(blake3.Hash(keys.tag), place[:])
	tag := blake3.keyed_hash(head, clear_with_zero_mac[:])
	copy(mac[:], tag[:MAC_SIZE])
	return mac
}

// siv_nonce derives the 24-byte XChaCha20 nonce for a metadata block from
// its kind, block number and 128-bit SIV MAC.
@(private = "file")
siv_nonce :: proc "contextless" (keys: ^Store_Keys, kind: Block_Kind, block: u64, mac: Mac) -> (nonce: Nonce) {
	mac := mac
	place: [25]u8
	place[0] = u8(kind)
	byte_order.write_u64_little_endian(place[:], 1, block)
	copy(place[9:], mac[:])
	hash := blake3.keyed_hash(blake3.Hash(keys.nonce), place[:])
	copy(nonce[:], hash[:NONCE_SIZE])
	return nonce
}

// data_nonce derives the 24-byte XChaCha20 nonce for a data block from its
// block number and plaintext value_check, separated by Block_Kind.Data_Block.
data_nonce :: proc "contextless" (keys: ^Store_Keys, block: u64, data_check: u64) -> (nonce: Nonce) {
	place: [17]u8
	place[0] = u8(Block_Kind.Data_Block)
	byte_order.write_u64_little_endian(place[:], 1, block)
	byte_order.write_u64_little_endian(place[:], 9, data_check)
	hash := blake3.keyed_hash(blake3.Hash(keys.nonce), place[:])
	copy(nonce[:], hash[:NONCE_SIZE])
	return nonce
}

// data_block_encrypt encrypts a 4096-byte data block in place under the
// cipher key of its store and returns the on-disk check (store.check of
// ciphertext) to store in its Pointer.
data_block_encrypt :: proc "contextless" (keys: ^Store_Keys, block: u64, data_check: u64, bytes: ^Block) -> (cipher_check: u64) {
	nonce := data_nonce(keys, block, data_check)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, bytes[:])
	return store.check(bytes[:])
}

// data_block_decrypt verifies the on-disk ciphertext check, then decrypts
// the 4096-byte data block in place. If the check does not match, bytes are
// erased before returning false. The caller checks the decrypted plaintext
// against the authenticated object hash tree or Entry.data_check.
data_block_decrypt :: proc "contextless" (keys: ^Store_Keys, block: u64, cipher_check: u64, data_check: u64, bytes: ^Block) -> (ok: bool) {
	if store.check(bytes[:]) != cipher_check {
		intrinsics.mem_zero_volatile(bytes, size_of(Block))
		return false
	}
	nonce := data_nonce(keys, block, data_check)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, bytes[:])
	return true
}

// store_block_seal computes and writes the 128-bit MAC of an owned
// Store_Block and returns its on-disk check. Refuses a zero store_generation
// or missing owner fields.
store_block_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, sb: ^store.Store_Block) -> (check: u64, ok: bool) {
	if sb.store_generation == 0 || is_zero(sb.owner[:]) || is_zero(sb.salt[:]) || is_zero(sb.key_check[:]) {
		return 0, false
	}
	sb.mac = {}
	sb.mac = block_mac(keys, .Store_Block, block, (^Block)(sb))
	return store.check(([^]u8)(sb)[:BLOCK_SIZE]), true
}

// store_block_verify checks the on-disk check, rollback floor
// (1 <= min_generation <= store_generation <= max_generation), key check,
// and 128-bit MAC of an owned Store_Block. Erases sb on any refusal.
store_block_verify :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, min_generation: u64, max_generation: u64, sb: ^store.Store_Block) -> bool {
	if store.check(([^]u8)(sb)[:BLOCK_SIZE]) != expected_check {
		intrinsics.mem_zero_volatile(sb, size_of(store.Store_Block))
		return false
	}
	if sb.store_generation == 0 || sb.store_generation < min_generation || sb.store_generation > max_generation {
		intrinsics.mem_zero_volatile(sb, size_of(store.Store_Block))
		return false
	}
	if !key_check_matches(keys, sb.key_check) {
		intrinsics.mem_zero_volatile(sb, size_of(store.Store_Block))
		return false
	}
	kept := sb.mac
	sb.mac = {}
	expected := block_mac(keys, .Store_Block, block, (^Block)(sb))
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(sb, size_of(store.Store_Block))
		return false
	}
	return true
}

@(private = "file")
tree_header_valid :: proc "contextless" (header: ^store.Tree_Header) -> bool {
	if header.magic != store.NODE_MAGIC || header.reserved != 0 || header.level > store.TREE_DEPTH_LIMIT {
		return false
	}
	limit := header.level == 0 ? u32(store.LEAF_CAPACITY) : u32(store.BRANCH_CAPACITY)
	return header.count >= 1 && header.count <= limit
}

// tree_node_xor_secret packs all secret ranges of a B+ tree leaf or branch
// into one buffer, runs one XChaCha20 pass, unpacks them back, and erases
// the buffer.
@(private = "file")
tree_node_xor_secret :: proc "contextless" (keys: ^Store_Keys, nonce: ^Nonce, bytes: ^Block, header: ^store.Tree_Header) {
	scratch: Block
	count := int(header.count)
	length := 0
	if header.level == 0 {
		stride :: size_of(store.Entry_Name) + size_of(store.Entry)
		secret_offset :: size_of(store.Entry_Name) + int(offset_of(store.Entry, generation))
		secret_size :: int(offset_of(store.Entry, pointer)) - int(offset_of(store.Entry, generation))
		#assert(secret_size == 64)
		for index in 0 ..< count {
			base := store.TREE_HEADER_SIZE + index * stride
			copy(scratch[length:], bytes[base : base + size_of(store.Entry_Name)])
			length += size_of(store.Entry_Name)
			copy(scratch[length:], bytes[base + secret_offset : base + secret_offset + secret_size])
			length += secret_size
		}
		cryptography_primitives.xchacha20_xor(&keys.cipher, nonce, scratch[:length])
		offset := 0
		for index in 0 ..< count {
			base := store.TREE_HEADER_SIZE + index * stride
			copy(bytes[base : base + size_of(store.Entry_Name)], scratch[offset : offset + size_of(store.Entry_Name)])
			offset += size_of(store.Entry_Name)
			copy(bytes[base + secret_offset : base + secret_offset + secret_size], scratch[offset : offset + secret_size])
			offset += secret_size
		}
	} else {
		stride :: size_of(store.Entry_Name) + size_of(store.Pointer)
		for index in 0 ..< count {
			base := store.TREE_HEADER_SIZE + index * stride
			copy(scratch[length:], bytes[base : base + size_of(store.Entry_Name)])
			length += size_of(store.Entry_Name)
		}
		cryptography_primitives.xchacha20_xor(&keys.cipher, nonce, scratch[:length])
		offset := 0
		for index in 0 ..< count {
			base := store.TREE_HEADER_SIZE + index * stride
			copy(bytes[base : base + size_of(store.Entry_Name)], scratch[offset : offset + size_of(store.Entry_Name)])
			offset += size_of(store.Entry_Name)
		}
	}
	intrinsics.mem_zero_volatile(&scratch, size_of(scratch))
}

// tree_node_seal authenticates a B+ tree node (leaf or branch), encrypts
// its secret fields in place, writes the 128-bit MAC, and returns the
// on-disk check.
tree_node_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, bytes: ^Block) -> (check: u64, ok: bool) {
	header := (^store.Tree_Header)(bytes)
	if !tree_header_valid(header) {
		return 0, false
	}
	header.mac = {}
	mac := block_mac(keys, .Tree_Node, block, bytes)
	nonce := siv_nonce(keys, .Tree_Node, block, mac)
	tree_node_xor_secret(keys, &nonce, bytes, header)
	header.mac = mac
	return store.check(bytes[:]), true
}

// tree_node_open checks the on-disk check and header bounds of a B+ tree
// node, decrypts its secret fields, and verifies its 128-bit MAC. On any
// refusal, bytes are erased before returning false.
tree_node_open :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, bytes: ^Block) -> bool {
	if store.check(bytes[:]) != expected_check {
		intrinsics.mem_zero_volatile(bytes, size_of(Block))
		return false
	}
	header := (^store.Tree_Header)(bytes)
	if !tree_header_valid(header) {
		intrinsics.mem_zero_volatile(bytes, size_of(Block))
		return false
	}
	kept := header.mac
	header.mac = {}
	nonce := siv_nonce(keys, .Tree_Node, block, kept)
	tree_node_xor_secret(keys, &nonce, bytes, header)
	expected := block_mac(keys, .Tree_Node, block, bytes)
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(bytes, size_of(Block))
		return false
	}
	return true
}

@(private = "file")
object_node_header_valid :: proc "contextless" (node: ^store.Object_Node) -> bool {
	if node.header.magic != store.OBJECT_NODE_MAGIC || node.header.reserved != 0 {
		return false
	}
	if node.header.level == 0 || node.header.level > store.OBJECT_LEVEL_LIMIT {
		return false
	}
	if node.header.count == 0 || node.header.count > store.OBJECT_FANOUT {
		return false
	}
	non_holes: u32
	for child in node.children {
		if child.block != 0 {
			non_holes += 1
		}
	}
	return non_holes == node.header.count
}

@(private = "file")
object_node_xor_secret :: proc "contextless" (keys: ^Store_Keys, nonce: ^Nonce, node: ^store.Object_Node) {
	scratch: [store.OBJECT_FANOUT * size_of(store.Block_Value)]u8
	length := 0
	for &child in node.children {
		if child.block != 0 {
			value_bytes := ([^]u8)(&child.value)[:size_of(store.Block_Value)]
			copy(scratch[length:], value_bytes)
			length += size_of(store.Block_Value)
		}
	}
	cryptography_primitives.xchacha20_xor(&keys.cipher, nonce, scratch[:length])
	offset := 0
	for &child in node.children {
		if child.block != 0 {
			value_bytes := ([^]u8)(&child.value)[:size_of(store.Block_Value)]
			copy(value_bytes, scratch[offset : offset + size_of(store.Block_Value)])
			offset += size_of(store.Block_Value)
		}
	}
	intrinsics.mem_zero_volatile(&scratch, size_of(scratch))
}

// object_node_seal authenticates an Object_Node, encrypts child.value for
// each non-hole child, writes the 128-bit MAC, and returns its on-disk check.
object_node_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, node: ^store.Object_Node) -> (check: u64, ok: bool) {
	if !object_node_header_valid(node) {
		return 0, false
	}
	node.header.mac = {}
	mac := block_mac(keys, .Object_Node, block, (^Block)(node))
	nonce := siv_nonce(keys, .Object_Node, block, mac)
	object_node_xor_secret(keys, &nonce, node)
	node.header.mac = mac
	return store.check(([^]u8)(node)[:BLOCK_SIZE]), true
}

// object_node_open checks the on-disk check and header bounds of an
// Object_Node, decrypts non-hole child values, and verifies its 128-bit MAC.
// Erases node on any refusal.
object_node_open :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, node: ^store.Object_Node) -> bool {
	if store.check(([^]u8)(node)[:BLOCK_SIZE]) != expected_check {
		intrinsics.mem_zero_volatile(node, size_of(store.Object_Node))
		return false
	}
	if !object_node_header_valid(node) {
		intrinsics.mem_zero_volatile(node, size_of(store.Object_Node))
		return false
	}
	kept := node.header.mac
	node.header.mac = {}
	nonce := siv_nonce(keys, .Object_Node, block, kept)
	object_node_xor_secret(keys, &nonce, node)
	expected := block_mac(keys, .Object_Node, block, (^Block)(node))
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(node, size_of(store.Object_Node))
		return false
	}
	return true
}

// version_index_seal authenticates a Version_Index, encrypts version_count
// and retention_time in place, writes the 128-bit MAC, and returns its
// on-disk check.
version_index_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, index: ^store.Version_Index) -> (check: u64, ok: bool) {
	if index.leaf_count > store.VERSION_INDEX_CAPACITY || index.reserved != 0 {
		return 0, false
	}
	index.mac = {}
	mac := block_mac(keys, .Version_Index, block, (^Block)(index))
	nonce := siv_nonce(keys, .Version_Index, block, mac)
	secret_offset :: int(offset_of(store.Version_Index, version_count))
	secret_size :: int(offset_of(store.Version_Index, reserved)) - secret_offset
	#assert(secret_size == 16)
	raw := ([^]u8)(index)
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, raw[secret_offset : secret_offset + secret_size])
	index.mac = mac
	return store.check(raw[:BLOCK_SIZE]), true
}

// version_index_open checks the on-disk check and bounds of a Version_Index,
// decrypts version_count and retention_time, and verifies its 128-bit MAC.
// Erases index on any refusal.
version_index_open :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, index: ^store.Version_Index) -> bool {
	raw := ([^]u8)(index)
	if store.check(raw[:BLOCK_SIZE]) != expected_check {
		intrinsics.mem_zero_volatile(index, size_of(store.Version_Index))
		return false
	}
	if index.leaf_count > store.VERSION_INDEX_CAPACITY || index.reserved != 0 {
		intrinsics.mem_zero_volatile(index, size_of(store.Version_Index))
		return false
	}
	kept := index.mac
	index.mac = {}
	nonce := siv_nonce(keys, .Version_Index, block, kept)
	secret_offset :: int(offset_of(store.Version_Index, version_count))
	secret_size :: int(offset_of(store.Version_Index, reserved)) - secret_offset
	cryptography_primitives.xchacha20_xor(&keys.cipher, &nonce, raw[secret_offset : secret_offset + secret_size])
	expected := block_mac(keys, .Version_Index, block, (^Block)(index))
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(index, size_of(store.Version_Index))
		return false
	}
	return true
}

@(private = "file")
version_leaf_xor_secret :: proc "contextless" (keys: ^Store_Keys, nonce: ^Nonce, leaf: ^store.Version_Leaf) {
	secret_offset :: int(offset_of(store.Version_Entry, generation))
	secret_size :: size_of(store.Version_Entry) - secret_offset
	#assert(secret_size == 32)
	scratch: [store.VERSION_LEAF_CAPACITY * secret_size]u8
	count := int(leaf.count)
	length := 0
	for index in 0 ..< count {
		raw := ([^]u8)(&leaf.entries[index])
		copy(scratch[length:], raw[secret_offset : secret_offset + secret_size])
		length += secret_size
	}
	cryptography_primitives.xchacha20_xor(&keys.cipher, nonce, scratch[:length])
	offset := 0
	for index in 0 ..< count {
		raw := ([^]u8)(&leaf.entries[index])
		copy(raw[secret_offset : secret_offset + secret_size], scratch[offset : offset + secret_size])
		offset += secret_size
	}
	intrinsics.mem_zero_volatile(&scratch, size_of(scratch))
}

// version_leaf_seal authenticates a Version_Leaf, encrypts the secret fields
// of its entries in place, writes the 128-bit MAC, and returns its on-disk
// check.
version_leaf_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, leaf: ^store.Version_Leaf) -> (check: u64, ok: bool) {
	if leaf.count == 0 || leaf.count > store.VERSION_LEAF_CAPACITY || leaf.reserved != 0 {
		return 0, false
	}
	leaf.mac = {}
	mac := block_mac(keys, .Version_Leaf, block, (^Block)(leaf))
	nonce := siv_nonce(keys, .Version_Leaf, block, mac)
	version_leaf_xor_secret(keys, &nonce, leaf)
	leaf.mac = mac
	return store.check(([^]u8)(leaf)[:BLOCK_SIZE]), true
}

// version_leaf_open checks the on-disk check and bounds of a Version_Leaf,
// decrypts the secret fields of its entries, and verifies its 128-bit MAC.
// Erases leaf on any refusal.
version_leaf_open :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, leaf: ^store.Version_Leaf) -> bool {
	if store.check(([^]u8)(leaf)[:BLOCK_SIZE]) != expected_check {
		intrinsics.mem_zero_volatile(leaf, size_of(store.Version_Leaf))
		return false
	}
	if leaf.count == 0 || leaf.count > store.VERSION_LEAF_CAPACITY || leaf.reserved != 0 {
		intrinsics.mem_zero_volatile(leaf, size_of(store.Version_Leaf))
		return false
	}
	kept := leaf.mac
	leaf.mac = {}
	nonce := siv_nonce(keys, .Version_Leaf, block, kept)
	version_leaf_xor_secret(keys, &nonce, leaf)
	expected := block_mac(keys, .Version_Leaf, block, (^Block)(leaf))
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(leaf, size_of(store.Version_Leaf))
		return false
	}
	return true
}

// release_list_seal authenticates a Release_List with a 128-bit MAC and
// returns its on-disk check.
release_list_seal :: proc "contextless" (keys: ^Store_Keys, block: u64, list: ^store.Release_List) -> (check: u64, ok: bool) {
	if !store.release_list_valid(list) {
		return 0, false
	}
	list.mac = {}
	list.mac = block_mac(keys, .Release_List, block, (^Block)(list))
	return store.check(([^]u8)(list)[:BLOCK_SIZE]), true
}

// release_list_open checks the on-disk check, format rules, and 128-bit MAC
// of a Release_List. Erases list on any refusal.
release_list_open :: proc "contextless" (keys: ^Store_Keys, block: u64, expected_check: u64, list: ^store.Release_List) -> bool {
	if store.check(([^]u8)(list)[:BLOCK_SIZE]) != expected_check {
		intrinsics.mem_zero_volatile(list, size_of(store.Release_List))
		return false
	}
	if !store.release_list_valid(list) {
		intrinsics.mem_zero_volatile(list, size_of(store.Release_List))
		return false
	}
	kept := list.mac
	list.mac = {}
	expected := block_mac(keys, .Release_List, block, (^Block)(list))
	if !mac_equal(kept, expected) {
		intrinsics.mem_zero_volatile(list, size_of(store.Release_List))
		return false
	}
	return true
}
