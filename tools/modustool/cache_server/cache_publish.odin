// The publication of a release to an object cache, its check, and the
// commands cache-put and cache-get
// (src/md/infrastructure/cache_publication.md).
package cache_server

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import info "modus:contract/boot_info"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modus:contract/release"
import "modus:contract/tree_hash"
import crypto_compat "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modustool:foundation"

// The input of the cache test recipe: a constant, so its recipe hash is a
// constant and a check of a cache needs no file of a release.
CACHE_TEST_INPUT_NAME :: "cache_test"
CACHE_TEST_INPUT_TEXT :: "modus object cache test v1\n"

// One entry of a tree of one input holds far less than this.
@(private = "file")
CACHE_TEST_OUTPUT_BYTES_MOST :: 512

// The cache test recipe: a recipe of the inputs tree builder with one input.
Cache_Test_Recipe :: struct {
	input:        []u8,
	input_hash:   blake3.Hash,
	recipe_hash:  blake3.Hash,
	output_hash:  blake3.Hash,
	output_bytes: [CACHE_TEST_OUTPUT_BYTES_MOST]u8,
	output_size:  int,
	// The recipe object: the blob from which a reader computes the recipe
	// hash again (src/md/infrastructure/cache_browser.md, "A realisation
	// and its recipe").
	object:       []u8,
}

// cache_test_recipe computes the recipe, its output tree and its output hash
// with the code of the service recipes: the inputs tree builder.
cache_test_recipe :: proc() -> (recipe: Cache_Test_Recipe, ok: bool) {
	recipe.input = transmute([]u8)string(CACHE_TEST_INPUT_TEXT)
	recipe.input_hash = blake3.hash(recipe.input)
	spec := new(plans_recipes.Recipe_Spec, context.temp_allocator)
	spec.builder_hash = plans_recipes.inputs_tree_builder_hash()
	spec.output_kind = .Tree
	input, input_refusal := plans_recipes.recipe_input_make(CACHE_TEST_INPUT_NAME, .Blob, recipe.input_hash)
	if input_refusal != .None {
		return {}, false
	}
	spec.input_count = 1
	spec.inputs[0] = input
	recipe_digest, hash_refusal := plans_recipes.recipe_hash(spec)
	if hash_refusal != .None {
		return {}, false
	}
	recipe.recipe_hash = recipe_digest
	object := make([]u8, plans_recipes.MAX_RECIPE_OBJECT_BYTES, context.temp_allocator)
	object_written, object_refusal := plans_recipes.recipe_object_encode(spec, object)
	if object_refusal != .None {
		return {}, false
	}
	recipe.object = object[:object_written]
	sandbox, sandbox_refusal := plans_recipes.builder_sandbox_prepare(spec)
	if sandbox_refusal != .None {
		return {}, false
	}
	written, build_refusal := plans_recipes.inputs_tree_build(&sandbox, recipe.output_bytes[:])
	if build_refusal != .None {
		return {}, false
	}
	recipe.output_size = written
	output_digest, output_refusal := plans_recipes.recipe_hash_output(.Tree, recipe.output_bytes[:written])
	if output_refusal != .None {
		return {}, false
	}
	recipe.output_hash = output_digest
	return recipe, true
}

// One file of a boot image: a module or a resource, by the hash that its
// entry states.
Cache_Image_File :: struct {
	name:  string,
	hash:  blake3.Hash,
	bytes: []u8,
}

// cache_image_files reads the files of a boot image, each once by its hash.
// It refuses the image whole when a table, a range or a stated hash is
// wrong: a damaged image uploads nothing.
cache_image_files :: proc(image: []u8, allocator := context.temp_allocator) -> (files: []Cache_Image_File, problem: string) {
	modules, resources, valid := info.image_tables(image)
	if !valid {
		return nil, "it is not a boot image: its header or its tables are wrong"
	}
	if len(modules) + len(resources) == 0 {
		return nil, "the boot image holds no file"
	}
	result := make([dynamic]Cache_Image_File, 0, len(modules) + len(resources), allocator)
	for table in ([2][]info.Image_Entry{modules, resources}) {
		for &entry in table {
			name_bytes := entry.name[:]
			name_end := 0
			for name_end < len(name_bytes) && name_bytes[name_end] != 0 {
				name_end += 1
			}
			name := strings.clone(string(name_bytes[:name_end]), allocator)
			bytes, in_image := info.image_entry_bytes(image, &entry)
			if !in_image {
				return nil, fmt.tprintf("the entry %s points outside the image", name)
			}
			if u64(len(bytes)) > object_cache.MAX_OBJECT_BYTES {
				return nil, fmt.tprintf("the file %s holds %d bytes, more than the %d of one object", name, len(bytes), object_cache.MAX_OBJECT_BYTES)
			}
			if blake3.hash(bytes) != entry.hash {
				return nil, fmt.tprintf("the file %s does not have the hash that its entry states", name)
			}
			seen := false
			for earlier in result {
				if earlier.hash == entry.hash {
					seen = true
					break
				}
			}
			if !seen {
				append(&result, Cache_Image_File{name = name, hash = entry.hash, bytes = bytes})
			}
		}
	}
	return result[:], ""
}

// The count of one publication.
Cache_Publish_Report :: struct {
	files:          int,
	put:            int,
	already_held:   int,
	bytes_put:      int,
	recipe_hash:    blake3.Hash,
	output_hash:    blake3.Hash,
	release_tree:   blake3.Hash,
	release_number: u64,
}

// The name of the release pointer of each release of the system.
CACHE_RELEASE_POINTER_NAME :: "release"

// The names of the two entries of a release tree.
CACHE_RELEASE_IMAGE_ENTRY :: "boot.image"
CACHE_RELEASE_FILES_ENTRY :: "files"

// The bits of each part of a release number in the number of its release
// pointer: 22 for the major part, 21 for the minor and the patch parts, so
// the three fill 64 bits and keep their order.
RELEASE_NUMBER_MINOR_BITS :: 21
RELEASE_NUMBER_MAJOR_BITS :: 64 - 2 * RELEASE_NUMBER_MINOR_BITS

// release_number_value gives the number of a release pointer for a release
// number a.b.c: a shifted by 42 bits, b by 21 bits, then c, so a later
// release has a higher number. Each part is digits with no leading zero; a
// is below 2^22, b and c below 2^21. The number 0 is refused: the first
// number of a pointer is 1.
release_number_value :: proc(text: string) -> (number: u64, ok: bool) {
	parts: [3]u64
	part := 0
	digits := 0
	for index in 0 ..< len(text) {
		character := text[index]
		switch {
		case character == '.':
			if digits == 0 || part == 2 {
				return 0, false
			}
			part += 1
			digits = 0
		case character >= '0' && character <= '9':
			if digits == 1 && parts[part] == 0 {
				return 0, false
			}
			// Eight digits pass each bound, so a part never overflows.
			if digits == 8 {
				return 0, false
			}
			parts[part] = parts[part] * 10 + u64(character - '0')
			digits += 1
		case:
			return 0, false
		}
	}
	if part != 2 || digits == 0 {
		return 0, false
	}
	if parts[0] >= 1 << RELEASE_NUMBER_MAJOR_BITS || parts[1] >= 1 << RELEASE_NUMBER_MINOR_BITS || parts[2] >= 1 << RELEASE_NUMBER_MINOR_BITS {
		return 0, false
	}
	number = parts[0] << (2 * RELEASE_NUMBER_MINOR_BITS) | parts[1] << RELEASE_NUMBER_MINOR_BITS | parts[2]
	return number, number > 0
}

// The two trees of a release: the files of its boot image by their names,
// and the release tree, which names the whole image and that tree.
Cache_Release_Trees :: struct {
	files:        []u8,
	files_hash:   blake3.Hash,
	release:      []u8,
	release_hash: blake3.Hash,
}

// cache_release_trees makes the two trees of a release. A name that is not
// a tree entry name, two files of one name, or more files than a tree
// holds, refuses the image whole.
cache_release_trees :: proc(image: []u8, allocator := context.temp_allocator) -> (trees: Cache_Release_Trees, problem: string) {
	modules, resources, valid := info.image_tables(image)
	if !valid {
		return {}, "it is not a boot image: its header or its tables are wrong"
	}
	entries := make([dynamic]tree_hash.Tree_Entry, 0, len(modules) + len(resources), allocator)
	for table in ([2][]info.Image_Entry{modules, resources}) {
		for &entry in table {
			name_end := 0
			for name_end < len(entry.name) && entry.name[name_end] != 0 {
				name_end += 1
			}
			name := string(entry.name[:name_end])
			item, refusal := tree_hash.tree_entry_make(.Object, name, entry.hash)
			if refusal != .None {
				return {}, fmt.tprintf("the file %q has a name that a tree does not take: %v", name, refusal)
			}
			append(&entries, item)
		}
	}
	if len(entries) > tree_hash.MAX_TREE_ENTRIES {
		return {}, fmt.tprintf("the boot image holds %d files, more than the %d of one tree", len(entries), tree_hash.MAX_TREE_ENTRIES)
	}
	slice.sort_by(entries[:], proc(left, right: tree_hash.Tree_Entry) -> bool {
		left_copy, right_copy := left, right
		return tree_hash.compare_name_bytes(transmute([]u8)tree_hash.tree_entry_name(&left_copy), transmute([]u8)tree_hash.tree_entry_name(&right_copy)) < 0
	})
	trees.files = make([]u8, tree_hash.tree_encoded_size(len(entries)), allocator)
	if _, refusal := tree_hash.tree_encode(entries[:], trees.files); refusal != .None {
		return {}, fmt.tprintf("the tree of the files of the boot image was refused: %v", refusal)
	}
	trees.files_hash, _ = tree_hash.tree_hash(trees.files)
	image_entry, _ := tree_hash.tree_entry_make(.Object, CACHE_RELEASE_IMAGE_ENTRY, blake3.hash(image))
	files_entry, _ := tree_hash.tree_entry_make(.Tree, CACHE_RELEASE_FILES_ENTRY, trees.files_hash)
	release_entries := [2]tree_hash.Tree_Entry{image_entry, files_entry}
	trees.release = make([]u8, tree_hash.tree_encoded_size(2), allocator)
	if _, refusal := tree_hash.tree_encode(release_entries[:], trees.release); refusal != .None {
		return {}, fmt.tprintf("the release tree was refused: %v", refusal)
	}
	trees.release_hash, _ = tree_hash.tree_hash(trees.release)
	return trees, ""
}

@(private = "file")
hash_text :: proc(value: blake3.Hash) -> string {
	digits := hash_to_hex(value)
	return strings.clone(string(digits[:]), context.temp_allocator)
}

// cache_publish_release puts each file of a boot image that the cache does
// not hold, then the input, the output and the signed realisation of the
// cache test recipe. problem says what was not put and why, or is "".
cache_publish_release :: proc(client: ^Cache_Client, signer: ^ed25519.Private_Key, image: []u8) -> (report: Cache_Publish_Report, problem: string) {
	files, image_problem := cache_image_files(image)
	if image_problem != "" {
		return {}, fmt.tprintf("the boot image was not published: %s", image_problem)
	}
	report.files = len(files)
	for first := 0; first < len(files); first += object_cache.MAX_HAS_HASHES {
		last := min(first + object_cache.MAX_HAS_HASHES, len(files))
		hashes: [object_cache.MAX_HAS_HASHES]blake3.Hash
		for index in first ..< last {
			hashes[index - first] = files[index].hash
		}
		present, has_outcome := cache_client_has(client, hashes[:last - first])
		if has_outcome != .Done {
			return report, fmt.tprintf("the object cache did not say which files it holds: %s", cache_client_outcome_text(has_outcome, client.server_status))
		}
		for index in first ..< last {
			if present & (u64(1) << u64(index - first)) != 0 {
				report.already_held += 1
				continue
			}
			_, put_outcome := cache_client_put_object(client, signer, .Blob, files[index].bytes)
			if put_outcome != .Done {
				return report, fmt.tprintf("the file %s (%s) was not put: %s", files[index].name, hash_text(files[index].hash), cache_client_outcome_text(put_outcome, client.server_status))
			}
			report.put += 1
			report.bytes_put += len(files[index].bytes)
		}
	}
	recipe, recipe_ok := cache_test_recipe()
	if !recipe_ok {
		return report, "the cache test recipe was not computed"
	}
	report.recipe_hash = recipe.recipe_hash
	report.output_hash = recipe.output_hash
	if _, outcome := cache_client_put_object(client, signer, .Blob, recipe.input); outcome != .Done {
		return report, fmt.tprintf("the input of the cache test recipe was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	if _, outcome := cache_client_put_object(client, signer, .Blob, recipe.object); outcome != .Done {
		return report, fmt.tprintf("the recipe object of the cache test recipe was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	if _, outcome := cache_client_put_object(client, signer, .Tree, recipe.output_bytes[:recipe.output_size]); outcome != .Done {
		return report, fmt.tprintf("the output of the cache test recipe was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	record, signed := cache_client_realisation_sign(signer, recipe.recipe_hash, recipe.output_hash, .Tree)
	if !signed {
		return report, "the realisation of the cache test recipe was not signed"
	}
	if outcome := cache_client_put_realisation(client, record); outcome != .Done {
		return report, fmt.tprintf("the realisation of the cache test recipe was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	// The trees of the release, then its pointer last: a reader who finds
	// the pointer finds the trees that it names.
	trees, trees_problem := cache_release_trees(image)
	if trees_problem != "" {
		return report, fmt.tprintf("the release tree was not made: %s", trees_problem)
	}
	if _, outcome := cache_client_put_object(client, signer, .Tree, trees.files); outcome != .Done {
		return report, fmt.tprintf("the tree of the files of the boot image was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	if _, outcome := cache_client_put_object(client, signer, .Tree, trees.release); outcome != .Done {
		return report, fmt.tprintf("the release tree was not put: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	number, number_ok := release_number_value(release.RELEASE_NUMBER)
	if !number_ok {
		return report, fmt.tprintf("the release number %s gives no number of a release pointer", release.RELEASE_NUMBER)
	}
	if pointer_problem := cache_publish_release_pointer(client, signer, number, trees.release_hash); pointer_problem != "" {
		return report, pointer_problem
	}
	report.release_tree = trees.release_hash
	report.release_number = number
	return report, ""
}

// cache_publish_release_pointer puts the release pointer of a release. A
// pointer of the same signer with a higher number on the cache means that a
// later release is published: a run of the job of an older release is then
// done, as cache_verify_release_pointer accepts it, and puts nothing.
cache_publish_release_pointer :: proc(client: ^Cache_Client, signer: ^ed25519.Private_Key, number: u64, release_tree: blake3.Hash) -> (problem: string) {
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(signer, public_key[:])
	held, held_outcome := cache_client_get_release_pointer(client, public_key, CACHE_RELEASE_POINTER_NAME)
	switch held_outcome {
	case .Done:
		if held.number > number {
			return ""
		}
	case .Not_Found:
	case .Bad_Request, .Unreachable, .Damaged_Answer, .Server_Refused, .Hash_Mismatch, .Untrusted_Signer, .Bad_Signature, .Too_Large, .Deadline_Passed:
		return fmt.tprintf("the release pointer on the cache was not read: %s", cache_client_outcome_text(held_outcome, client.server_status))
	}
	pointer, signed_pointer := cache_client_release_pointer_sign(signer, CACHE_RELEASE_POINTER_NAME, number, release_tree)
	if !signed_pointer {
		return "the release pointer was not signed"
	}
	if outcome := cache_client_put_release_pointer(client, pointer); outcome != .Done {
		return fmt.tprintf("the release pointer %d was not put: %s", number, cache_client_outcome_text(outcome, client.server_status))
	}
	return ""
}

// cache_verify_test_recipe gets the realisation of the cache test recipe,
// checks it against the trusted signer and against the tree computed again
// here, then gets its output and its input and checks their hashes.
cache_verify_test_recipe :: proc(client: ^Cache_Client, trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8) -> (recipe: Cache_Test_Recipe, problem: string) {
	recipe_ok: bool
	recipe, recipe_ok = cache_test_recipe()
	if !recipe_ok {
		return {}, "the cache test recipe was not computed"
	}
	record, outcome := cache_client_get_realisation(client, recipe.recipe_hash, trusted_signer)
	if outcome != .Done {
		return recipe, fmt.tprintf("the realisation of the cache test recipe (%s) was not taken: %s", hash_text(recipe.recipe_hash), cache_client_outcome_text(outcome, client.server_status))
	}
	if record.output_kind != .Tree || record.output_hash != recipe.output_hash {
		return recipe, fmt.tprintf("the realisation of the cache test recipe names the output %s, and the inputs tree builder gives %s here", hash_text(record.output_hash), hash_text(recipe.output_hash))
	}
	output, output_outcome := cache_client_get_object(client, .Tree, recipe.output_hash, context.temp_allocator)
	if output_outcome != .Done {
		return recipe, fmt.tprintf("the output of the cache test recipe (%s) was not taken: %s", hash_text(recipe.output_hash), cache_client_outcome_text(output_outcome, client.server_status))
	}
	_ = output
	if _, input_outcome := cache_client_get_object(client, .Blob, recipe.input_hash, context.temp_allocator); input_outcome != .Done {
		return recipe, fmt.tprintf("the input of the cache test recipe (%s) was not taken: %s", hash_text(recipe.input_hash), cache_client_outcome_text(input_outcome, client.server_status))
	}
	return recipe, ""
}

// cache_verify_release gets each file of a boot image and checks its hash,
// then checks the cache test recipe.
cache_verify_release :: proc(client: ^Cache_Client, trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8, image: []u8) -> (files: int, problem: string) {
	image_files, image_problem := cache_image_files(image)
	if image_problem != "" {
		return 0, fmt.tprintf("the boot image was not checked: %s", image_problem)
	}
	for file in image_files {
		_, outcome := cache_client_verify_object(client, .Blob, file.hash)
		if outcome != .Done {
			return files, fmt.tprintf("the file %s (%s) was not taken: %s", file.name, hash_text(file.hash), cache_client_outcome_text(outcome, client.server_status))
		}
		files += 1
	}
	if _, recipe_problem := cache_verify_test_recipe(client, trusted_signer); recipe_problem != "" {
		return files, recipe_problem
	}
	if pointer_problem := cache_verify_release_pointer(client, trusted_signer, image); pointer_problem != "" {
		return files, pointer_problem
	}
	return files, ""
}

// cache_verify_release_pointer gets the release pointer of the trusted
// signer and checks it against the release tree computed again from the
// image. A pointer of a later release is no fault: the cache moved on.
cache_verify_release_pointer :: proc(client: ^Cache_Client, trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8, image: []u8) -> (problem: string) {
	trees, trees_problem := cache_release_trees(image)
	if trees_problem != "" {
		return fmt.tprintf("the release tree was not made: %s", trees_problem)
	}
	number, number_ok := release_number_value(release.RELEASE_NUMBER)
	if !number_ok {
		return fmt.tprintf("the release number %s gives no number of a release pointer", release.RELEASE_NUMBER)
	}
	pointer, outcome := cache_client_get_release_pointer(client, trusted_signer, CACHE_RELEASE_POINTER_NAME)
	if outcome != .Done {
		return fmt.tprintf("the release pointer was not taken: %s", cache_client_outcome_text(outcome, client.server_status))
	}
	if pointer.number < number {
		return fmt.tprintf("the release pointer has the number %d, lower than the %d of this release", pointer.number, number)
	}
	if pointer.number == number && pointer.tree_hash != trees.release_hash {
		return fmt.tprintf("the release pointer %d names the tree %s, and this image gives %s", number, hash_text(pointer.tree_hash), hash_text(trees.release_hash))
	}
	for tree in ([2]blake3.Hash{trees.release_hash, trees.files_hash}) {
		payload, get_outcome := cache_client_get_object(client, .Tree, tree, context.temp_allocator)
		_ = payload
		if get_outcome != .Done {
			return fmt.tprintf("the tree %s of the release was not taken: %s", hash_text(tree), cache_client_outcome_text(get_outcome, client.server_status))
		}
	}
	return ""
}

// read_signer_private_key_file reads a seed file of 64 hexadecimal digits
// that only its owner can read, and gives its key. The caller clears it.
read_signer_private_key_file :: proc(path: string) -> (private_key: ed25519.Private_Key, ok: bool) {
	if !foundation.private_key_file_check(path) {
		return {}, false
	}
	raw, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: the key %s was not read: %v", path, read_error)
		return {}, false
	}
	defer crypto_compat.zero_explicit(raw_data(raw), len(raw))
	seed, decode_ok := decode_hex_32(string(raw))
	defer crypto_compat.zero_explicit(&seed, size_of(seed))
	if !decode_ok {
		fmt.eprintfln("modustool: %s must hold 64 hexadecimal digits", path)
		return {}, false
	}
	if !ed25519.private_key_set_bytes(&private_key, seed[:]) {
		fmt.eprintfln("modustool: %s is not an Ed25519 key", path)
		return {}, false
	}
	return private_key, true
}

@(private = "file")
hash_argument :: proc(text: string) -> (value: blake3.Hash, ok: bool) {
	if !hex_hash_valid(text) {
		return {}, false
	}
	return decode_hex_32(text)
}

@(private = "file")
cache_connect_or_say :: proc(command, endpoint: string) -> (client: Cache_Client, ok: bool) {
	outcome: Cache_Client_Outcome
	client, outcome = cache_client_connect(endpoint)
	switch outcome {
	case .Done:
		return client, true
	case .Bad_Request:
		fmt.eprintfln("modustool: %s: %s is not host:port", command, endpoint)
	case .Unreachable, .Damaged_Answer, .Not_Found, .Server_Refused, .Hash_Mismatch, .Untrusted_Signer, .Bad_Signature, .Too_Large, .Deadline_Passed, .Out_Of_Range, .Local_File_Fault, .Busy:
		fmt.eprintfln("modustool: %s: no connection to %s", command, endpoint)
	}
	return {}, false
}

CACHE_PUT_USAGE :: "modustool: cache-put <host:port> --key <seed file> blob <file>... | cache-put <host:port> --key <seed file> release <boot image>"

// run_cache_put is the command cache-put.
run_cache_put :: proc(args: []string) -> int {
	if len(args) < 4 || args[1] != "--key" {
		fmt.eprintln(CACHE_PUT_USAGE)
		return foundation.EXIT_USAGE
	}
	endpoint, key_path, form := args[0], args[2], args[3]
	operands := args[4:]
	switch form {
	case "blob":
		if len(operands) == 0 {
			fmt.eprintln(CACHE_PUT_USAGE)
			return foundation.EXIT_USAGE
		}
	case "release":
		if len(operands) != 1 {
			fmt.eprintln(CACHE_PUT_USAGE)
			return foundation.EXIT_USAGE
		}
	case:
		fmt.eprintln(CACHE_PUT_USAGE)
		return foundation.EXIT_USAGE
	}
	signer, key_ok := read_signer_private_key_file(key_path)
	if !key_ok {
		return foundation.EXIT_FAILURE
	}
	defer ed25519.private_key_clear(&signer)
	client, connected := cache_connect_or_say("cache-put", endpoint)
	if !connected {
		return foundation.EXIT_FAILURE
	}
	defer cache_client_close(&client)
	if form == "blob" {
		for path in operands {
			object_hash, _, outcome := cache_client_put_file(&client, &signer, path)
			if outcome != .Done {
				fmt.eprintfln("modustool: cache-put: %s was not put on %s: %s", path, endpoint, cache_client_outcome_text(outcome, client.server_status))
				return foundation.EXIT_FAILURE
			}
			fmt.printfln("%s  %s", hash_text(object_hash), path)
		}
		return 0
	}
	image, read_error := os.read_entire_file(operands[0], context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cache-put: the boot image %s was not read: %v", operands[0], read_error)
		return foundation.EXIT_FAILURE
	}
	defer delete(image)
	report, problem := cache_publish_release(&client, &signer, image)
	if problem != "" {
		fmt.eprintfln("modustool: cache-put: %s on %s: %s", operands[0], endpoint, problem)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: cache-put: %d files of %s on %s: %d put (%d bytes), %d held already; the realisation of the cache test recipe %s gives %s", report.files, operands[0], endpoint, report.put, report.bytes_put, report.already_held, hash_text(report.recipe_hash), hash_text(report.output_hash))
	return 0
}

CACHE_GET_USAGE :: "modustool: cache-get <host:port> blob <hash> [<output file>] | cache-get <host:port> realisation <recipe hash> --signer <public key file> | cache-get <host:port> release <boot image> [--signer <public key file>] | cache-get <host:port> test-recipe [--signer <public key file>]"

// run_cache_get is the command cache-get.
run_cache_get :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.eprintln(CACHE_GET_USAGE)
		return foundation.EXIT_USAGE
	}
	endpoint, form := args[0], args[1]
	operands := make([dynamic]string, context.temp_allocator)
	signer_path := ""
	for index := 2; index < len(args); index += 1 {
		if args[index] == "--signer" {
			if index + 1 >= len(args) || signer_path != "" {
				fmt.eprintln(CACHE_GET_USAGE)
				return foundation.EXIT_USAGE
			}
			index += 1
			signer_path = args[index]
			continue
		}
		append(&operands, args[index])
	}
	switch form {
	case "blob":
		if len(operands) < 1 || len(operands) > 2 || signer_path != "" {
			fmt.eprintln(CACHE_GET_USAGE)
			return foundation.EXIT_USAGE
		}
	case "realisation":
		if len(operands) != 1 || signer_path == "" {
			fmt.eprintln(CACHE_GET_USAGE)
			return foundation.EXIT_USAGE
		}
	case "release":
		if len(operands) != 1 {
			fmt.eprintln(CACHE_GET_USAGE)
			return foundation.EXIT_USAGE
		}
	case "test-recipe":
		if len(operands) != 0 {
			fmt.eprintln(CACHE_GET_USAGE)
			return foundation.EXIT_USAGE
		}
	case:
		fmt.eprintln(CACHE_GET_USAGE)
		return foundation.EXIT_USAGE
	}
	asked_hash: blake3.Hash
	if form == "blob" || form == "realisation" {
		hash_ok: bool
		asked_hash, hash_ok = hash_argument(operands[0])
		if !hash_ok {
			fmt.eprintfln("modustool: cache-get: %s is not a hash of 64 lowercase hexadecimal digits", operands[0])
			return foundation.EXIT_USAGE
		}
	}
	trusted_signer: [object_cache.PUBLIC_KEY_SIZE]u8
	if form != "blob" {
		if signer_path == "" {
			signer_path = foundation.CACHE_SIGNING_KEY_PUBLIC_FILE
			if !os.exists(signer_path) {
				fmt.eprintfln("modustool: cache-get: no --signer names the trusted key, and %s is not in this folder: start the command at the root of the repository, or give --signer <public key file>", signer_path)
				return foundation.EXIT_USAGE
			}
		}
		key_ok: bool
		trusted_signer, key_ok = read_public_key_file("cache-get", signer_path)
		if !key_ok {
			return foundation.EXIT_FAILURE
		}
	}
	client, connected := cache_connect_or_say("cache-get", endpoint)
	if !connected {
		return foundation.EXIT_FAILURE
	}
	defer cache_client_close(&client)
	switch form {
	case "blob":
		if len(operands) == 2 {
			object_size, _, outcome := cache_client_get_file(&client, asked_hash, operands[1])
			if outcome != .Done {
				fmt.eprintfln("modustool: cache-get: the blob %s was not taken from %s: %s", operands[0], endpoint, cache_client_outcome_text(outcome, client.server_status))
				return foundation.EXIT_FAILURE
			}
			fmt.printfln("modustool: cache-get: the blob %s, %d bytes, has its hash", operands[0], object_size)
		} else {
			object_size, outcome := cache_client_verify_object(&client, .Blob, asked_hash)
			if outcome != .Done {
				fmt.eprintfln("modustool: cache-get: the blob %s was not taken from %s: %s", operands[0], endpoint, cache_client_outcome_text(outcome, client.server_status))
				return foundation.EXIT_FAILURE
			}
			fmt.printfln("modustool: cache-get: the blob %s, %d bytes, has its hash", operands[0], object_size)
		}
	case "realisation":
		record, outcome := cache_client_get_realisation(&client, asked_hash, trusted_signer)
		if outcome != .Done {
			fmt.eprintfln("modustool: cache-get: the realisation of %s was not taken from %s: %s", operands[0], endpoint, cache_client_outcome_text(outcome, client.server_status))
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: cache-get: the recipe %s gave the %v %s, signed by %s", operands[0], record.output_kind, hash_text(record.output_hash), hash_text(record.signer_public_key))
	case "release":
		image, read_error := os.read_entire_file(operands[0], context.allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: cache-get: the boot image %s was not read: %v", operands[0], read_error)
			return foundation.EXIT_FAILURE
		}
		defer delete(image)
		files, problem := cache_verify_release(&client, trusted_signer, image)
		if problem != "" {
			fmt.eprintfln("modustool: cache-get: %s on %s: %s", operands[0], endpoint, problem)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: cache-get: the %d files of %s on %s have their hashes, and the realisation of the cache test recipe verifies with %s", files, operands[0], endpoint, signer_path)
	case "test-recipe":
		recipe, problem := cache_verify_test_recipe(&client, trusted_signer)
		if problem != "" {
			fmt.eprintfln("modustool: cache-get: %s: %s", endpoint, problem)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: cache-get: on %s, the cache test recipe %s gave the tree %s, signed by the key of %s, and the tree and its input have their hashes", endpoint, hash_text(recipe.recipe_hash), hash_text(recipe.output_hash), signer_path)
	}
	return 0
}
