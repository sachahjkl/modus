package modustool

import "core:fmt"
import "modus:contract/blake3"
import "modus:contract/replacement_list"
import "modus:support/cryptography/ed25519"
import "modus:support/replacement_signature"

// The replacement list of a boot image (docs/MODULE_CONTRACT.md, "Who may
// replace a module"): the replacement rows that the signing key of the
// system signs. The root service writes a replacement in the table of the
// machine only for a row of this list whose signature verifies under the
// key that verified the system description.
//
// The tool writes the list when it writes the boot image of a volume
// (boot_image_signed_write), with the key that signs its system
// description, so the test machine signs with the test signing key, as its
// boot image is signed.

// One row of the build, by the names of the modules of the boot image.
Replacement_Row_Of_The_Build :: struct {
	from:                  string, // The module that an import names.
	to:                    string, // The module that a loader gives in its place.
	signed_by_another_key: bool, // The negative case of the machine test: a key that no machine trusts signs it.
}

// The rows of the build: the replacements of the demonstration of an
// import. calendar_changed (another description) and agenda (an import
// cycle) are signed so that the check of the loader can refuse them: the
// signature is consent, the load check is compatibility. calendar by
// lonely is signed by another key, so that the root service refuses it.
// A module of a row that a volume does not hold leaves its row out.
@(rodata)
replacement_rows_of_the_build := [?]Replacement_Row_Of_The_Build {
	{from = "calendar", to = "calendar_fixed"},
	{from = "calendar", to = "calendar_changed"},
	{from = "calendar", to = "agenda"},
	{from = "calendar", to = "lonely", signed_by_another_key = true},
}

// The seed of the key that no machine trusts: RFC 8032, section 7.1,
// TEST 2. It is published, so a row that it signs proves nothing anywhere.
ANOTHER_KEY_SEED :: [32]u8{0x4c, 0xcd, 0x08, 0x9b, 0x28, 0xff, 0x96, 0xda, 0x9d, 0xb6, 0xc3, 0x46, 0xec, 0x11, 0x4e, 0x0f, 0x5b, 0x8a, 0x31, 0x9f, 0x35, 0xab, 0xa6, 0x24, 0xda, 0x8c, 0xf6, 0xed, 0x4f, 0xb8, 0xa6, 0xfb}

// replacement_list_of_the_build gives the bytes of the replacement list of
// one boot image: one row for each row of the build whose two modules are
// among modules, signed by key, or by the key that no machine trusts. It
// verifies each row as the root service does before it gives the list.
replacement_list_of_the_build :: proc(modules: []Image_File, key: ^Signing_Key) -> (list: []u8, ok: bool) {
	another_key: ed25519.Private_Key
	another_seed := ANOTHER_KEY_SEED
	if !ed25519.private_key_set_bytes(&another_key, another_seed[:]) {
		fmt.eprintln("modustool: the key that no machine trusts is not an Ed25519 private key")
		return
	}
	defer ed25519.private_key_clear(&another_key)
	signed_rows := make([dynamic]replacement_list.Row, context.temp_allocator)
	for item in replacement_rows_of_the_build {
		from, from_found := image_file_hash(modules, item.from)
		to, to_found := image_file_hash(modules, item.to)
		if !from_found || !to_found {
			continue
		}
		row := replacement_list.Row{from = from, to = to, scope = u32(replacement_list.Scope.System)}
		replacement_signature.row_sign(&row, item.signed_by_another_key ? &another_key : &key.private_key)
		if replacement_signature.row_verifies(&row, key.public_key) == item.signed_by_another_key {
			fmt.eprintfln("modustool: the replacement row %s by %s does not verify as it must under the signing key of the system", item.from, item.to)
			return
		}
		append(&signed_rows, row)
	}
	list = replacement_list_encode(signed_rows[:], context.temp_allocator)
	if _, problem := replacement_list.rows(list); problem != .None {
		fmt.eprintfln("modustool: the replacement list does not follow its format: %s", replacement_list.list_problem_sentences[problem])
		return
	}
	return list, true
}

// replacement_list_encode gives the bytes of a list: the header, then the
// rows. It is tool code: a source of the system calls no allocator.
replacement_list_encode :: proc(rows: []replacement_list.Row, allocator := context.allocator) -> []u8 {
	bytes := make([]u8, size_of(replacement_list.Header) + len(rows) * size_of(replacement_list.Row), allocator)
	header := replacement_list.Header {
		magic     = replacement_list.MAGIC,
		version   = replacement_list.VERSION,
		row_count = u32(len(rows)),
	}
	copy(bytes, (cast([^]u8)&header)[:size_of(header)])
	if len(rows) > 0 {
		copy(bytes[size_of(header):], (cast([^]u8)raw_data(rows))[:len(rows) * size_of(replacement_list.Row)])
	}
	return bytes
}

// image_file_hash gives the BLAKE3 hash of the file with this name.
image_file_hash :: proc(files: []Image_File, name: string) -> (hash: [replacement_list.HASH_SIZE]u8, found: bool) {
	for item in files {
		if item.name == name {
			return blake3.hash(item.file), true
		}
	}
	return
}
