// The cache signing key: the key of the publisher of the system that signs
// the uploads and the realisations on an object cache, apart from the
// signing key and the release signing key
// (src/md/infrastructure/cache_publication.md, "The cache signing key").
package build

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/system_description"
import crypto "modus:cryptography/compatibility_crypto"
import "modustool:foundation"

// The variable of the secret of a workflow, and the variable that names the
// path of the seed, as SYSTEM_SIGNING_KEY does for the signing key.
CACHE_SIGNING_KEY_TEXT_VARIABLE :: "CACHE_SIGNING_KEY_TEXT"
CACHE_SIGNING_KEY_VARIABLE :: "CACHE_SIGNING_KEY"

// cache_signing_key_public_of gives the public key of a seed text, and
// refuses the test signing key, whose seed is published.
cache_signing_key_public_of :: proc(seed_text: string) -> (public_key: [system_description.PUBLIC_KEY_SIZE]u8, problem: string) {
	seed, decode_problem := signing_key_text_decode(seed_text)
	defer crypto.zero_explicit(&seed, size_of(seed))
	if decode_problem != "" {
		return {}, decode_problem
	}
	made: bool
	public_key, made = public_key_of_seed(seed[:])
	if !made {
		return {}, "is not an Ed25519 seed"
	}
	if public_key == system_description.TEST_PUBLIC_KEY {
		return {}, "is the test signing key, whose private key is published"
	}
	return public_key, ""
}

// cache_signing_key_committed_check compares a public key with the text of
// the committed public key. problem says what differs, or is "".
cache_signing_key_committed_check :: proc(public_key: [system_description.PUBLIC_KEY_SIZE]u8, committed_text: string, committed_found: bool) -> (problem: string) {
	digits := system_description.hexadecimal(public_key)
	if !committed_found {
		return fmt.tprintf("%s is not in the repository: commit the public key %s there, so that the deployment authorises it", foundation.CACHE_SIGNING_KEY_PUBLIC_FILE, string(digits[:]))
	}
	committed, committed_problem := signing_key_text_decode(committed_text)
	if committed_problem != "" {
		return fmt.tprintf("%s %s", foundation.CACHE_SIGNING_KEY_PUBLIC_FILE, committed_problem)
	}
	if committed != public_key {
		return fmt.tprintf("the public key %s is not the key of %s: the object cache would refuse each upload", string(digits[:]), foundation.CACHE_SIGNING_KEY_PUBLIC_FILE)
	}
	return ""
}

@(private = "file")
committed_public_text :: proc() -> (text: string, found: bool) {
	data, read_error := os.read_entire_file(foundation.CACHE_SIGNING_KEY_PUBLIC_FILE, context.temp_allocator)
	if read_error != nil {
		return "", false
	}
	return string(data), true
}

@(private = "file")
cache_signing_key_paths :: proc(folder: string) -> (private_path, public_path: string) {
	private_path = foundation.join(folder, "/", foundation.CACHE_SIGNING_KEY_FILE_NAME)
	return private_path, foundation.join(private_path, foundation.CACHE_SIGNING_KEY_PUBLIC_SUFFIX)
}

// cache_signing_key_files_write writes the seed, readable by its owner only,
// and the public key. A write that fails part of the way removes what it
// wrote.
@(private = "file")
cache_signing_key_files_write :: proc(folder: string, seed_digits: string, public_key: [system_description.PUBLIC_KEY_SIZE]u8) -> bool {
	private_path, public_path := cache_signing_key_paths(folder)
	private_text := strings.concatenate({seed_digits, "\n"}, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(private_text), len(private_text))
	if !file_create_new(private_path, transmute([]u8)private_text, 0o600) {
		return false
	}
	if !foundation.private_key_file_check(private_path) {
		_ = os.remove(private_path)
		return false
	}
	public_digits := system_description.hexadecimal(public_key)
	if !file_create_new(public_path, transmute([]u8)strings.concatenate({string(public_digits[:]), "\n"}, context.temp_allocator), 0o644) {
		_ = os.remove(private_path)
		return false
	}
	return true
}

// cache_signing_key_new is `key new cache <folder>`, and a part of `key new
// <folder>`: a new cache signing key from the generator of the host.
cache_signing_key_new :: proc(folder: string) -> bool {
	private_path, public_path := cache_signing_key_paths(folder)
	if os.exists(private_path) || os.exists(public_path) {
		fmt.eprintfln("modustool: %s already holds a cache signing key: a new key does not replace one", folder)
		return false
	}
	private_folder_make(folder) or_return
	seed: [SIGNING_KEY_SIZE]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	host_random_bytes(seed[:]) or_return
	seed_digits := system_description.hexadecimal(seed)
	defer crypto.zero_explicit(&seed_digits, size_of(seed_digits))
	public_key, problem := cache_signing_key_public_of(string(seed_digits[:]))
	if problem != "" {
		fmt.eprintfln("modustool: the new cache signing key %s", problem)
		return false
	}
	cache_signing_key_files_write(folder, string(seed_digits[:]), public_key) or_return
	public_digits := system_description.hexadecimal(public_key)
	fmt.printfln("modustool: wrote %s and %s; cache signing key %s: commit a copy of %s as %s, and put the seed in the secret CACHE_SIGNING_KEY (secrets/README.md)", private_path, public_path, string(public_digits[:]), public_path, foundation.CACHE_SIGNING_KEY_PUBLIC_FILE)
	return true
}

// cache_signing_key_write is `key write cache <folder>`: the cache signing
// key from the secret of a workflow. It refuses a key whose public key is
// not the committed one: the object cache would refuse each upload.
cache_signing_key_write :: proc(folder: string) -> bool {
	text := strings.trim_space(os.get_env(CACHE_SIGNING_KEY_TEXT_VARIABLE, context.temp_allocator))
	defer crypto.zero_explicit(raw_data(text), len(text))
	committed, committed_found := committed_public_text()
	return cache_signing_key_write_text(folder, text, committed, committed_found)
}

// cache_signing_key_write_text writes the key folder from the text of the
// seed, checked against the text of the committed public key.
cache_signing_key_write_text :: proc(folder, text, committed: string, committed_found: bool) -> bool {
	if path_inside_repository(folder) {
		fmt.eprintfln("modustool: %s is inside the repository: a private key stays outside it", folder)
		return false
	}
	if text == "" {
		fmt.eprintfln("modustool: key write cache: the variable %s is empty (secrets/README.md)", CACHE_SIGNING_KEY_TEXT_VARIABLE)
		return false
	}
	public_key, problem := cache_signing_key_public_of(text)
	if problem != "" {
		fmt.eprintfln("modustool: key write cache: %s %s", CACHE_SIGNING_KEY_TEXT_VARIABLE, problem)
		return false
	}
	if committed_problem := cache_signing_key_committed_check(public_key, committed, committed_found); committed_problem != "" {
		fmt.eprintfln("modustool: key write cache: %s", committed_problem)
		return false
	}
	private_folder_make(folder) or_return
	cache_signing_key_files_write(folder, text, public_key) or_return
	public_digits := system_description.hexadecimal(public_key)
	fmt.printfln("modustool: key write cache: wrote the cache signing key in %s, public key %s", folder, string(public_digits[:]))
	return true
}

// cache_signing_key_show is `key show cache`: the public key of the seed that
// CACHE_SIGNING_KEY names, and whether it is the committed one.
cache_signing_key_show :: proc() -> bool {
	path := os.get_env(CACHE_SIGNING_KEY_VARIABLE, context.temp_allocator)
	if path == "" {
		fmt.eprintfln("modustool: key show cache: %s names no cache signing key", CACHE_SIGNING_KEY_VARIABLE)
		return false
	}
	foundation.private_key_file_check(path) or_return
	data := foundation.read_file(path) or_return
	defer crypto.zero_explicit(raw_data(data), len(data))
	public_key, problem := cache_signing_key_public_of(string(data))
	if problem != "" {
		fmt.eprintfln("modustool: key show cache: %s %s", path, problem)
		return false
	}
	digits := system_description.hexadecimal(public_key)
	committed, committed_found := committed_public_text()
	if committed_problem := cache_signing_key_committed_check(public_key, committed, committed_found); committed_problem != "" {
		fmt.printfln("%s (%s)", string(digits[:]), committed_problem)
	} else {
		fmt.printfln("%s (the key of %s)", string(digits[:]), foundation.CACHE_SIGNING_KEY_PUBLIC_FILE)
	}
	return true
}
