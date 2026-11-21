// Self-contained SDK packager, cryptographic verifier, outside-module SDK
// builder, and language-neutral ET_REL module converter entry point
// (src/md/infrastructure/sdk.md, src/md/infrastructure/language_neutral_abi.md).
//
// An SDK directory exposes only the public surface of modus:
//   SDK_MANIFEST.txt        canonical manifest, BLAKE3 root digest, optional Ed25519 signature
//   LICENSE                 repository license
//   library/modus/          clean copy of src/library/modus/ only (never internal or modulus)
//   runtime/                freestanding memory assembly procedures
//   modules/                public module catalog and verified .module files of the release
//   examples/hello_odin/    minimal freestanding Odin outside module
//   examples/hello_c/       minimal freestanding C ET_REL + module.manifest example
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/release"
import "modus:contract/text_encoding"
import crypto "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modus:cryptography_primitives"
import "modustool:foundation"
import "modustool:resources"

SDK_FORMAT_VERSION :: 1
SDK_MANIFEST_FILE_NAME :: "SDK_MANIFEST.txt"
SDK_TARGET_TRIPLE :: "x86_64-unknown-none-elf"
// Domain separator prepended before the hexadecimal BLAKE3 root digest when
// creating or verifying an Ed25519 SDK signature so a signature created for
// another domain can never validate as an SDK manifest signature.
SDK_SIGNATURE_CONTEXT :: "modus sdk manifest 1\n"

SDK_LIBRARY_SUBDIRECTORY :: "library/modus"
SDK_INCLUDE_SUBDIRECTORY :: "include/modus"
SDK_RUNTIME_SUBDIRECTORY :: "runtime"
SDK_MODULES_SUBDIRECTORY :: "modules"
SDK_EXAMPLES_SUBDIRECTORY :: "examples"
SDK_MODULE_CATALOG_RELATIVE_PATH :: "modules/catalog.txt"
SDK_MANIFEST_SEPARATOR :: "  "
SDK_LANGUAGE_NEUTRAL_MANIFEST_NAME :: "module.manifest"

SDK_PACK_USAGE :: "modustool: sdk-pack <output-dir> [--sign-key <path>] [--modules-dir <path>]"
SDK_VERIFY_USAGE :: "modustool: sdk-verify <sdk-dir> [--public-key <path>]"
SDK_CONVERT_USAGE :: "modustool: sdk-convert <object.o> <module.manifest> <output.modus> [--sdk <sdk-dir>] [--import-dir <dir>]"

// Configuration for assembling an SDK directory.
Sdk_Build_Options :: struct {
	source_root:      string, // Repository root containing src/library/modus and src/runtime; defaults to ".".
	modules_folder:   string, // Built .module folder to export from; defaults to <source_root>/build/modules if present.
	extra_modules:    []string, // Optional extra .module file paths to include under modules/.
	release_version:  string, // Release version string; defaults to release.RELEASE_NUMBER.
	compiler_version: string, // Odin compiler version string; auto-detected from `odin version` when empty.
	signing_key_seed: [ed25519.PRIVATE_KEY_SIZE]u8,
	has_signing_key:  bool,
}

// One file entry in SDK_MANIFEST.txt, stored in ascending relative path order.
Sdk_File_Entry :: struct {
	path: string,
	hash: blake3.Hash,
}

// Parsed representation of SDK_MANIFEST.txt.
Sdk_Manifest :: struct {
	sdk_format:       int,
	release_version:  string,
	target_triple:    string,
	module_format:    int,
	compiler_version: string,
	root_digest:      blake3.Hash,
	has_signature:    bool,
	public_key:       [ed25519.PUBLIC_KEY_SIZE]u8,
	signature:        [ed25519.SIGNATURE_SIZE]u8,
	files:            []Sdk_File_Entry,
}

// Options controlling cryptographic verification in sdk_verify.
Sdk_Verify_Options :: struct {
	expected_public_key: [ed25519.PUBLIC_KEY_SIZE]u8,
	require_signature:   bool,
}

// Options for building an outside module purely against an unpacked SDK.
Sdk_Outside_Build_Options :: struct {
	verify_options:    Sdk_Verify_Options,
	extra_import_dirs: []string,
	debug_information: bool,
}

@(private = "file")
Sdk_Manifest_Header_Key :: enum {
	Sdk_Format,
	Release,
	Target,
	Module_Format,
	Compiler,
	Root_Digest,
	Public_Key,
	Signature,
}

@(private = "file")
SDK_MANIFEST_HEADER_NAMES := [Sdk_Manifest_Header_Key]string {
	.Sdk_Format    = "sdk_format",
	.Release       = "release",
	.Target        = "target",
	.Module_Format = "module_format",
	.Compiler      = "compiler",
	.Root_Digest   = "root_digest",
	.Public_Key    = "public_key",
	.Signature     = "signature",
}

// Minimal freestanding Odin example bundled in every SDK.
@(private = "file")
SDK_EXAMPLE_HELLO_ODIN_BUILD_FILE :: "name: hello_odin\n"

@(private = "file")
SDK_EXAMPLE_HELLO_ODIN_SOURCE :: `// Minimal freestanding outside module built against the modus SDK.
package hello_odin

import "modus:system"

// add_values returns the sum of two signed 64-bit integers.
@(export, link_name = "add_values")
add_values :: proc "c" (left, right: i64) -> i64 {
	return left + right
}

@(export, link_name = "entry")
entry :: proc "c" (_: ^system.Context) -> ! {
	system.stop(.Done)
}
`

// Minimal freestanding C example bundled in every SDK, using the language-neutral
// ET_REL + module.manifest conversion path with no libc dependency.
@(private = "file")
SDK_EXAMPLE_HELLO_C_SOURCE :: `typedef long long int64_t;
typedef unsigned char uint8_t;

/* Populated by the modus loader with this module's 32-byte BLAKE3 hash. */
uint8_t modus_own_hash[32];

int64_t add_numbers(int64_t left, int64_t right) {
	return left + right;
}
`

@(private = "file")
SDK_EXAMPLE_HELLO_C_MANIFEST :: `module: hello_c
about: Minimal freestanding C library module built against the modus SDK.
library: yes

export add_numbers
  about: Return the sum of two signed 64-bit integers.
  param left: integer
  param right: integer
  result: integer
`

// sdk_path_is_forbidden reports whether a relative SDK path violates path
// cleanliness or touches the private internal or kernel modulus namespaces.
sdk_path_is_forbidden :: proc(relative_path: string) -> bool {
	if len(relative_path) == 0 {
		return true
	}
	if relative_path[0] == '/' || relative_path[len(relative_path) - 1] == '/' {
		return true
	}
	if strings.contains_any(relative_path, "\\\r\n\t\x00") || strings.contains(relative_path, "//") {
		return true
	}
	if !text_encoding.text_valid(transmute([]u8)relative_path) {
		return true
	}
	rest := relative_path
	for segment in strings.split_iterator(&rest, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return true
		}
		if segment == foundation.INTERNAL_LIBRARY_NAME || segment == foundation.KERNEL_LIBRARY_NAME {
			return true
		}
	}
	return false
}

// sdk_lowercase_hex_encode encodes bytes into lowercase hexadecimal ASCII.
sdk_lowercase_hex_encode :: proc(bytes: []u8, allocator := context.temp_allocator) -> string {
	hex_digits := "0123456789abcdef"
	out := make([]u8, len(bytes) * 2, allocator)
	for value, index in bytes {
		out[2 * index] = hex_digits[value >> 4]
		out[2 * index + 1] = hex_digits[value & 0x0F]
	}
	return string(out)
}

// sdk_lowercase_hex_decode strictly decodes lowercase hexadecimal ASCII into dst.
sdk_lowercase_hex_decode :: proc(text: string, dst: []u8) -> bool {
	if len(text) != len(dst) * 2 {
		return false
	}
	nibble :: proc(character: u8) -> (value: u8, ok: bool) {
		switch character {
		case '0' ..= '9':
			return character - '0', true
		case 'a' ..= 'f':
			return character - 'a' + 10, true
		}
		return 0, false
	}
	for index in 0 ..< len(dst) {
		high, high_ok := nibble(text[2 * index])
		low, low_ok := nibble(text[2 * index + 1])
		if !high_ok || !low_ok {
			return false
		}
		dst[index] = (high << 4) | low
	}
	return true
}

// sdk_key_decode reads a 32-byte Ed25519 key (seed or public key) encoded as
// either 64 hexadecimal digits or unpadded base64url.
sdk_key_decode :: proc(text: string) -> (key: [ed25519.PUBLIC_KEY_SIZE]u8, ok: bool) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 {
		return {}, false
	}
	if len(trimmed) == 2 * ed25519.PUBLIC_KEY_SIZE {
		decoded, problem := signing_key_text_decode(trimmed)
		if problem == "" {
			return decoded, true
		}
		return {}, false
	}
	return release_key_decode(trimmed)
}

// sdk_root_digest_compute computes the canonical BLAKE3 root digest covering
// all manifest metadata and every sorted file entry.
sdk_root_digest_compute :: proc(manifest: Sdk_Manifest) -> blake3.Hash {
	canonical := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&canonical, "sdk_format: %d", manifest.sdk_format)
	fmt.sbprintfln(&canonical, "release: %s", manifest.release_version)
	fmt.sbprintfln(&canonical, "target: %s", manifest.target_triple)
	fmt.sbprintfln(&canonical, "module_format: %d", manifest.module_format)
	fmt.sbprintfln(&canonical, "compiler: %s", manifest.compiler_version)
	for entry in manifest.files {
		fmt.sbprintfln(&canonical, "%s%s%s", hash_as_hexadecimal(entry.hash), SDK_MANIFEST_SEPARATOR, entry.path)
	}
	body := strings.to_string(canonical)
	return blake3.hash(transmute([]u8)body)
}

@(private = "file")
sdk_signature_message :: proc(root_digest: blake3.Hash) -> string {
	return strings.concatenate({SDK_SIGNATURE_CONTEXT, hash_as_hexadecimal(root_digest)}, context.temp_allocator)
}

// sdk_sign_root_digest derives the Ed25519 public key and signs the canonical
// SDK root digest message using modus:cryptography_primitives.
sdk_sign_root_digest :: proc(seed: [ed25519.PRIVATE_KEY_SIZE]u8, root_digest: blake3.Hash) -> (public_key: [ed25519.PUBLIC_KEY_SIZE]u8, signature: [ed25519.SIGNATURE_SIZE]u8, ok: bool) {
	seed_copy := seed
	defer crypto.zero_explicit(&seed_copy, size_of(seed_copy))

	secret_text := string(seed_copy[:])
	public_buffer := public_key[:]
	error_record: errors.Error_Record
	if cryptography_primitives.ed25519_public_key(&secret_text, &public_buffer, &error_record) != ed25519.PUBLIC_KEY_SIZE {
		return {}, {}, false
	}

	message := sdk_signature_message(root_digest)
	signature_buffer := signature[:]
	error_record = {}
	if cryptography_primitives.ed25519_sign(&secret_text, &message, &signature_buffer, &error_record) != ed25519.SIGNATURE_SIZE {
		return {}, {}, false
	}
	return public_key, signature, true
}

// sdk_verify_root_digest_signature checks an Ed25519 signature over the
// canonical SDK root digest message using modus:cryptography_primitives.
sdk_verify_root_digest_signature :: proc(public_key: [ed25519.PUBLIC_KEY_SIZE]u8, root_digest: blake3.Hash, signature: [ed25519.SIGNATURE_SIZE]u8) -> bool {
	key_copy := public_key
	sig_copy := signature
	public_text := string(key_copy[:])
	message := sdk_signature_message(root_digest)
	signature_text := string(sig_copy[:])
	error_record: errors.Error_Record
	return cryptography_primitives.ed25519_verify(&public_text, &message, &signature_text, &error_record) == 0
}

// sdk_manifest_format renders a canonical SDK_MANIFEST.txt document.
sdk_manifest_format :: proc(manifest: Sdk_Manifest, allocator := context.temp_allocator) -> string {
	out := strings.builder_make(allocator)
	fmt.sbprintfln(&out, "sdk_format: %d", manifest.sdk_format)
	fmt.sbprintfln(&out, "release: %s", manifest.release_version)
	fmt.sbprintfln(&out, "target: %s", manifest.target_triple)
	fmt.sbprintfln(&out, "module_format: %d", manifest.module_format)
	fmt.sbprintfln(&out, "compiler: %s", manifest.compiler_version)
	fmt.sbprintfln(&out, "root_digest: %s", hash_as_hexadecimal(manifest.root_digest))
	if manifest.has_signature {
		pub := manifest.public_key
		sig := manifest.signature
		fmt.sbprintfln(&out, "public_key: %s", sdk_lowercase_hex_encode(pub[:]))
		fmt.sbprintfln(&out, "signature: %s", sdk_lowercase_hex_encode(sig[:]))
	}
	strings.write_byte(&out, '\n')
	for entry in manifest.files {
		fmt.sbprintfln(&out, "%s%s%s", hash_as_hexadecimal(entry.hash), SDK_MANIFEST_SEPARATOR, entry.path)
	}
	return strings.to_string(out)
}

// sdk_manifest_parse strictly parses SDK_MANIFEST.txt, verifying every header
// field, path cleanliness, forbidden-namespace absence, ascending path order,
// and root_digest consistency.
sdk_manifest_parse :: proc(text: string, allocator := context.temp_allocator) -> (manifest: Sdk_Manifest, problem: string) {
	if len(text) == 0 {
		return {}, "SDK manifest is empty"
	}
	if !strings.has_suffix(text, "\n") {
		return {}, "SDK manifest must end with a newline"
	}

	seen: [Sdk_Manifest_Header_Key]bool
	files := make([dynamic]Sdk_File_Entry, allocator)
	in_files := false
	previous_path := ""

	body := text[:len(text) - 1]
	lines := strings.split(body, "\n", context.temp_allocator)
	for raw_line, idx in lines {
		line_number := idx + 1
		if strings.has_suffix(raw_line, "\r") {
			return {}, fmt.tprintf("line %d: carriage return is not allowed in canonical SDK manifest", line_number)
		}
		if !in_files {
			if raw_line == "" {
				in_files = true
				continue
			}
			colon := strings.index(raw_line, ": ")
			if colon <= 0 {
				return {}, fmt.tprintf("line %d: expected `key: value` header line", line_number)
			}
			written_key := raw_line[:colon]
			value := raw_line[colon + 2:]
			if len(value) == 0 || !text_encoding.text_valid(transmute([]u8)value) {
				return {}, fmt.tprintf("line %d: header `%s` has empty or invalid value", line_number, written_key)
			}
			key: Sdk_Manifest_Header_Key
			known := false
			for candidate_name, candidate in SDK_MANIFEST_HEADER_NAMES {
				if candidate_name == written_key {
					key, known = candidate, true
					break
				}
			}
			if !known {
				return {}, fmt.tprintf("line %d: unknown SDK manifest header key `%s`", line_number, written_key)
			}
			if seen[key] {
				return {}, fmt.tprintf("line %d: SDK manifest header key `%s` is repeated", line_number, written_key)
			}
			seen[key] = true

			switch key {
			case .Sdk_Format:
				parsed, parsed_ok := strconv.parse_int(value)
				if !parsed_ok || parsed != SDK_FORMAT_VERSION {
					return {}, fmt.tprintf("line %d: unsupported sdk_format `%s` (expected %d)", line_number, value, SDK_FORMAT_VERSION)
				}
				manifest.sdk_format = parsed
			case .Release:
				manifest.release_version = strings.clone(value, allocator)
			case .Target:
				manifest.target_triple = strings.clone(value, allocator)
			case .Module_Format:
				parsed, parsed_ok := strconv.parse_int(value)
				if !parsed_ok || parsed != module.VERSION {
					return {}, fmt.tprintf("line %d: incompatible module_format `%s` (expected %d)", line_number, value, module.VERSION)
				}
				manifest.module_format = parsed
			case .Compiler:
				manifest.compiler_version = strings.clone(value, allocator)
			case .Root_Digest:
				if !sdk_lowercase_hex_decode(value, manifest.root_digest[:]) {
					return {}, fmt.tprintf("line %d: root_digest must be 64 lowercase hexadecimal digits", line_number)
				}
			case .Public_Key:
				if !sdk_lowercase_hex_decode(value, manifest.public_key[:]) {
					return {}, fmt.tprintf("line %d: public_key must be 64 lowercase hexadecimal digits", line_number)
				}
			case .Signature:
				if !sdk_lowercase_hex_decode(value, manifest.signature[:]) {
					return {}, fmt.tprintf("line %d: signature must be 128 lowercase hexadecimal digits", line_number)
				}
			}
		} else {
			if raw_line == "" {
				return {}, fmt.tprintf("line %d: empty line inside file list", line_number)
			}
			if len(raw_line) <= CHECKSUM_DIGIT_COUNT + len(SDK_MANIFEST_SEPARATOR) || raw_line[CHECKSUM_DIGIT_COUNT:][:len(SDK_MANIFEST_SEPARATOR)] != SDK_MANIFEST_SEPARATOR {
				return {}, fmt.tprintf("line %d: expected `<64 lowercase hex>  <relative path>`", line_number)
			}
			digest_text := raw_line[:CHECKSUM_DIGIT_COUNT]
			rel_path := raw_line[CHECKSUM_DIGIT_COUNT + len(SDK_MANIFEST_SEPARATOR):]
			file_hash: blake3.Hash
			if !sdk_lowercase_hex_decode(digest_text, file_hash[:]) {
				return {}, fmt.tprintf("line %d: file hash must be 64 lowercase hexadecimal digits", line_number)
			}
			if rel_path == SDK_MANIFEST_FILE_NAME {
				return {}, fmt.tprintf("line %d: manifest must not list itself (`%s`)", line_number, SDK_MANIFEST_FILE_NAME)
			}
			if sdk_path_is_forbidden(rel_path) {
				return {}, fmt.tprintf("line %d: forbidden or unsafe SDK path `%s`", line_number, rel_path)
			}
			if previous_path != "" && rel_path <= previous_path {
				return {}, fmt.tprintf("line %d: SDK file paths must be strictly sorted without duplicates (`%s` after `%s`)", line_number, rel_path, previous_path)
			}
			previous_path = rel_path
			append(&files, Sdk_File_Entry{path = strings.clone(rel_path, allocator), hash = file_hash})
		}
	}

	required := [?]Sdk_Manifest_Header_Key{.Sdk_Format, .Release, .Target, .Module_Format, .Compiler, .Root_Digest}
	for key in required {
		if !seen[key] {
			return {}, fmt.tprintf("required SDK manifest header `%s` is missing", SDK_MANIFEST_HEADER_NAMES[key])
		}
	}
	if seen[.Public_Key] != seen[.Signature] {
		return {}, "SDK manifest must provide both `public_key` and `signature`, or neither"
	}
	if !in_files || len(files) == 0 {
		return {}, "SDK manifest lists no files"
	}

	manifest.has_signature = seen[.Signature]
	manifest.files = files[:]

	expected_root := sdk_root_digest_compute(manifest)
	if expected_root != manifest.root_digest {
		return {}, fmt.tprintf("SDK manifest root_digest mismatch: stated %s, computed %s", hash_as_hexadecimal(manifest.root_digest), hash_as_hexadecimal(expected_root))
	}
	return manifest, ""
}

@(private = "file")
sdk_detect_compiler_version :: proc() -> string {
	state, stdout_bytes, _, err := os.process_exec({command = {"odin", "version"}}, context.temp_allocator)
	if err != nil || !state.exited || !state.success {
		return "unknown"
	}
	text := strings.trim_space(string(stdout_bytes))
	if nl := strings.index_byte(text, '\n'); nl >= 0 {
		text = strings.trim_space(text[:nl])
	}
	text = strings.trim_prefix(text, "odin version ")
	if text == "" || !text_encoding.text_valid(transmute([]u8)text) {
		return "unknown"
	}
	return text
}

// sdk_copy_clean_tree recursively copies regular files from source_dir into
// target_dir in deterministic sorted order, refusing symbolic links and any
// relative path touching forbidden namespaces.
@(private = "file")
sdk_copy_clean_tree :: proc(source_dir, target_dir, relative_prefix: string) -> string {
	entries, read_error := os.read_all_directory_by_path(source_dir, context.temp_allocator)
	if read_error != nil {
		return fmt.tprintf("cannot read source directory `%s`: %v", source_dir, read_error)
	}
	names := make([]string, len(entries), context.temp_allocator)
	for entry, idx in entries {
		names[idx] = entry.name
	}
	slice.sort(names)

	if !foundation.make_folder(target_dir) {
		return fmt.tprintf("cannot create SDK directory `%s`", target_dir)
	}
	for name in names {
		if strings.has_prefix(name, ".") {
			continue
		}
		src_path := foundation.join(source_dir, "/", name)
		dst_path := foundation.join(target_dir, "/", name)
		rel_path := relative_prefix == "" ? name : foundation.join(relative_prefix, "/", name)
		if sdk_path_is_forbidden(rel_path) {
			return fmt.tprintf("refusing forbidden path `%s` during SDK packaging", rel_path)
		}
		info, stat_error := os.lstat(src_path, context.temp_allocator)
		if stat_error != nil {
			return fmt.tprintf("cannot inspect `%s`: %v", src_path, stat_error)
		}
		switch info.type {
		case .Directory:
			if problem := sdk_copy_clean_tree(src_path, dst_path, rel_path); problem != "" {
				return problem
			}
		case .Regular:
			if !foundation.file_copy_as_new(dst_path, src_path) {
				return fmt.tprintf("cannot copy `%s` into SDK at `%s`", src_path, dst_path)
			}
		case .Symlink, .Named_Pipe, .Socket, .Character_Device, .Block_Device, .Undetermined:
			return fmt.tprintf("refusing non-regular file `%s` (%v) during SDK packaging", src_path, info.type)
		}
	}
	return ""
}

// sdk_walk_directory collects every regular file in sdk_dir (excluding
// SDK_MANIFEST.txt), refusing any symbolic link, special file, or forbidden
// directory/file path touching `internal` or `modulus`.
@(private = "file")
sdk_walk_directory :: proc(sdk_dir, relative_dir: string, files: ^[dynamic]string) -> string {
	current_dir := relative_dir == "" ? sdk_dir : foundation.join(sdk_dir, "/", relative_dir)
	entries, read_error := os.read_all_directory_by_path(current_dir, context.temp_allocator)
	if read_error != nil {
		return fmt.tprintf("cannot read SDK directory `%s`: %v", current_dir, read_error)
	}
	names := make([]string, len(entries), context.temp_allocator)
	for entry, idx in entries {
		names[idx] = entry.name
	}
	slice.sort(names)

	for name in names {
		rel_path := relative_dir == "" ? name : foundation.join(relative_dir, "/", name)
		full_path := foundation.join(sdk_dir, "/", rel_path)
		info, stat_error := os.lstat(full_path, context.temp_allocator)
		if stat_error != nil {
			return fmt.tprintf("cannot inspect `%s`: %v", rel_path, stat_error)
		}
		if info.type == .Symlink {
			return fmt.tprintf("symbolic link `%s` is forbidden inside an SDK", rel_path)
		}
		if rel_path == SDK_MANIFEST_FILE_NAME {
			if info.type != .Regular {
				return fmt.tprintf("`%s` must be a regular file", SDK_MANIFEST_FILE_NAME)
			}
			continue
		}
		if sdk_path_is_forbidden(rel_path) {
			return fmt.tprintf("forbidden path `%s` is not allowed inside an SDK", rel_path)
		}
		switch info.type {
		case .Directory:
			if problem := sdk_walk_directory(sdk_dir, rel_path, files); problem != "" {
				return problem
			}
		case .Regular:
			append(files, rel_path)
		case .Symlink, .Named_Pipe, .Socket, .Character_Device, .Block_Device, .Undetermined:
			return fmt.tprintf("non-regular file `%s` (%v) is forbidden inside an SDK", rel_path, info.type)
		}
	}
	return ""
}

// sdk_export_public_modules populates <output_dir>/modules/ with verified
// .module files of public system and library modules (plus any extra_modules)
// and writes a deterministic modules/catalog.txt index.
@(private = "file")
sdk_export_public_modules :: proc(output_dir: string, modules_source_dir: string, extra_modules: []string) -> string {
	modules_dst := foundation.join(output_dir, "/", SDK_MODULES_SUBDIRECTORY)
	if !foundation.make_folder(modules_dst) {
		return fmt.tprintf("cannot create SDK modules directory `%s`", modules_dst)
	}

	Catalog_Row :: struct {
		name:    string,
		group:   string,
		library: bool,
		imports: []string,
		hash:    string,
		built:   bool,
	}
	rows := make([dynamic]Catalog_Row, context.temp_allocator)
	seen_names := make(map[string]bool, context.temp_allocator)

	for build in foundation.module_builds {
		if build.kernel || build.disk || build.only_in_image != "" {
			continue
		}
		group, has_group := foundation.module_group_of_source(build.source)
		if !has_group || (group != .Libraries && group != .System) {
			continue
		}
		group_name := group == .Libraries ? "libraries" : "system"
		row := Catalog_Row {
			name    = build.name,
			group   = group_name,
			library = build.library,
			imports = build.imports,
			hash    = "unbuilt",
		}
		if modules_source_dir != "" {
			candidate := foundation.join(modules_source_dir, "/", build.name, ".module")
			if os.exists(candidate) {
				bytes, read_err := os.read_entire_file(candidate, context.temp_allocator)
				if read_err != nil {
					return fmt.tprintf("cannot read module `%s`: %v", candidate, read_err)
				}
				if load_err := module.validate(bytes); load_err != .None {
					return fmt.tprintf("refusing invalid module file `%s` (%v)", candidate, load_err)
				}
				dst_path := foundation.join(modules_dst, "/", build.name, ".module")
				if write_err := os.write_entire_file(dst_path, bytes); write_err != nil {
					return fmt.tprintf("cannot write SDK module `%s`: %v", dst_path, write_err)
				}
				row.hash = hash_as_hexadecimal(blake3.hash(bytes))
				row.built = true
			}
		}
		seen_names[build.name] = true
		append(&rows, row)
	}

	for extra_path in extra_modules {
		bytes, read_err := os.read_entire_file(extra_path, context.temp_allocator)
		if read_err != nil {
			return fmt.tprintf("cannot read extra module `%s`: %v", extra_path, read_err)
		}
		if load_err := module.validate(bytes); load_err != .None {
			return fmt.tprintf("refusing invalid extra module `%s` (%v)", extra_path, load_err)
		}
		base := extra_path
		if slash := strings.last_index_byte(base, '/'); slash >= 0 {
			base = base[slash + 1:]
		}
		mod_name := strings.trim_suffix(base, ".module")
		mod_name = strings.trim_suffix(mod_name, ".modus")
		if !module_name_is_valid(mod_name) {
			return fmt.tprintf("extra module `%s` has invalid module name `%s`", extra_path, mod_name)
		}
		dst_path := foundation.join(modules_dst, "/", mod_name, ".module")
		if write_err := os.write_entire_file(dst_path, bytes); write_err != nil {
			return fmt.tprintf("cannot write extra SDK module `%s`: %v", dst_path, write_err)
		}
		digest := hash_as_hexadecimal(blake3.hash(bytes))
		if mod_name in seen_names {
			for &row in rows {
				if row.name == mod_name {
					row.hash = digest
					row.built = true
					break
				}
			}
		} else {
			seen_names[mod_name] = true
			append(&rows, Catalog_Row{name = mod_name, group = "libraries", library = true, hash = digest, built = true})
		}
	}

	slice.sort_by(rows[:], proc(a, b: Catalog_Row) -> bool {
		return a.name < b.name
	})

	catalog := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&catalog, "# modus SDK public module catalog")
	fmt.sbprintln(&catalog, "# format: <name> <group> library=<yes|no> hash=<blake3|unbuilt> imports=<comma-list|none>")
	for row in rows {
		imports_text := len(row.imports) == 0 ? "none" : strings.join(row.imports, ",", context.temp_allocator)
		fmt.sbprintfln(&catalog, "%s %s library=%s hash=%s imports=%s", row.name, row.group, row.library ? "yes" : "no", row.hash, imports_text)
	}
	catalog_path := foundation.join(output_dir, "/", SDK_MODULE_CATALOG_RELATIVE_PATH)
	if write_err := os.write_entire_file(catalog_path, strings.to_string(catalog)); write_err != nil {
		return fmt.tprintf("cannot write SDK module catalog `%s`: %v", catalog_path, write_err)
	}
	return ""
}

// sdk_write_examples writes the minimal freestanding Odin and C examples into
// <output_dir>/examples/.
@(private = "file")
sdk_write_examples :: proc(output_dir: string) -> string {
	hello_odin_dir := foundation.join(output_dir, "/", SDK_EXAMPLES_SUBDIRECTORY, "/hello_odin")
	hello_c_dir := foundation.join(output_dir, "/", SDK_EXAMPLES_SUBDIRECTORY, "/hello_c")
	if !foundation.make_folder(hello_odin_dir) || !foundation.make_folder(hello_c_dir) {
		return "cannot create SDK example directories"
	}
	Example_File :: struct {
		path: string,
		body: string,
	}
	files := [?]Example_File {
		{foundation.join(hello_odin_dir, "/", MODULE_BUILD_FILE_NAME), SDK_EXAMPLE_HELLO_ODIN_BUILD_FILE},
		{foundation.join(hello_odin_dir, "/main.odin"), SDK_EXAMPLE_HELLO_ODIN_SOURCE},
		{foundation.join(hello_c_dir, "/hello_c.c"), SDK_EXAMPLE_HELLO_C_SOURCE},
		{foundation.join(hello_c_dir, "/", SDK_LANGUAGE_NEUTRAL_MANIFEST_NAME), SDK_EXAMPLE_HELLO_C_MANIFEST},
	}
	for item in files {
		if err := os.write_entire_file(item.path, item.body); err != nil {
			return fmt.tprintf("cannot write SDK example `%s`: %v", item.path, err)
		}
	}
	return ""
}

// sdk_build assembles a deterministic, self-contained SDK directory at
// output_dir, writes SDK_MANIFEST.txt (with BLAKE3 root digest and optional
// Ed25519 signature), and verifies the completed SDK before returning.
sdk_build :: proc(output_dir: string, options := Sdk_Build_Options{}) -> (manifest: Sdk_Manifest, problem: string) {
	if strings.trim_space(output_dir) == "" {
		return {}, "output directory path is empty"
	}
	source_root := options.source_root != "" ? strings.trim_right(options.source_root, "/") : "."
	public_src := foundation.join(source_root, "/", foundation.SOURCE_FOLDER_PUBLIC)
	runtime_src := foundation.join(source_root, "/", foundation.SOURCE_FOLDER_RUNTIME)
	if !os.is_dir(public_src) {
		return {}, fmt.tprintf("public library folder `%s` does not exist", public_src)
	}
	if !os.is_dir(runtime_src) {
		return {}, fmt.tprintf("runtime folder `%s` does not exist", runtime_src)
	}

	if !foundation.reset_folder(output_dir) {
		return {}, fmt.tprintf("cannot prepare SDK output directory `%s`", output_dir)
	}

	// Copy ONLY src/library/modus/ into <output_dir>/library/modus/.
	if copy_problem := sdk_copy_clean_tree(public_src, foundation.join(output_dir, "/", SDK_LIBRARY_SUBDIRECTORY), SDK_LIBRARY_SUBDIRECTORY); copy_problem != "" {
		return {}, copy_problem
	}
	// Copy src/runtime/ into <output_dir>/runtime/.
	if copy_problem := sdk_copy_clean_tree(runtime_src, foundation.join(output_dir, "/", SDK_RUNTIME_SUBDIRECTORY), SDK_RUNTIME_SUBDIRECTORY); copy_problem != "" {
		return {}, copy_problem
	}
	// Copy repository LICENSE when present.
	license_src := foundation.join(source_root, "/", resources.REPOSITORY_LICENSE_FILE)
	if os.is_file(license_src) {
		if !foundation.file_copy_as_new(foundation.join(output_dir, "/", resources.REPOSITORY_LICENSE_FILE), license_src) {
			return {}, fmt.tprintf("cannot copy `%s` into SDK", license_src)
		}
	}

	// Export public module catalog and any built public .module files.
	modules_source := options.modules_folder
	if modules_source == "" {
		default_modules := foundation.join(source_root, "/", foundation.MODULE_BUILD_FOLDER)
		if os.is_dir(default_modules) {
			modules_source = default_modules
		}
	}
	if mod_problem := sdk_export_public_modules(output_dir, modules_source, options.extra_modules); mod_problem != "" {
		return {}, mod_problem
	}

	// Generate deterministic C11 contract headers under <output_dir>/include/modus/.
	if header_problem := c_headers_generate(foundation.join(output_dir, "/", SDK_INCLUDE_SUBDIRECTORY)); header_problem != "" {
		return {}, header_problem
	}

	// Bundle minimal freestanding Odin and C examples.
	if example_problem := sdk_write_examples(output_dir); example_problem != "" {
		return {}, example_problem
	}

	// Enumerate every packed file deterministically and hash it with BLAKE3.
	rel_paths := make([dynamic]string, context.temp_allocator)
	if walk_problem := sdk_walk_directory(output_dir, "", &rel_paths); walk_problem != "" {
		return {}, walk_problem
	}
	slice.sort(rel_paths[:])

	entries := make([]Sdk_File_Entry, len(rel_paths), context.temp_allocator)
	for rel_path, idx in rel_paths {
		full_path := foundation.join(output_dir, "/", rel_path)
		bytes, read_err := os.read_entire_file(full_path, context.temp_allocator)
		if read_err != nil {
			return {}, fmt.tprintf("cannot read packed SDK file `%s`: %v", rel_path, read_err)
		}
		entries[idx] = Sdk_File_Entry{path = rel_path, hash = blake3.hash(bytes)}
	}

	release_version := options.release_version != "" ? options.release_version : release.RELEASE_NUMBER
	compiler_version := options.compiler_version != "" ? options.compiler_version : sdk_detect_compiler_version()

	manifest = Sdk_Manifest {
		sdk_format       = SDK_FORMAT_VERSION,
		release_version  = release_version,
		target_triple    = SDK_TARGET_TRIPLE,
		module_format    = module.VERSION,
		compiler_version = compiler_version,
		files            = entries,
	}
	manifest.root_digest = sdk_root_digest_compute(manifest)

	verify_opts := Sdk_Verify_Options{}
	if options.has_signing_key {
		pub, sig, signed := sdk_sign_root_digest(options.signing_key_seed, manifest.root_digest)
		if !signed {
			return {}, "failed to sign SDK manifest with Ed25519 key"
		}
		manifest.has_signature = true
		manifest.public_key = pub
		manifest.signature = sig
		verify_opts.require_signature = true
		verify_opts.expected_public_key = pub
	}

	manifest_text := sdk_manifest_format(manifest)
	manifest_path := foundation.join(output_dir, "/", SDK_MANIFEST_FILE_NAME)
	if write_err := os.write_entire_file(manifest_path, manifest_text); write_err != nil {
		return {}, fmt.tprintf("cannot write `%s`: %v", manifest_path, write_err)
	}

	// Self-verify the assembled SDK before returning so a broken pack never ships.
	verified, verify_problem := sdk_verify(output_dir, verify_opts)
	if verify_problem != "" {
		return {}, fmt.tprintf("packed SDK failed self-verification: %s", verify_problem)
	}
	return verified, ""
}

// sdk_verify validates an unpacked SDK directory against its SDK_MANIFEST.txt:
// strict manifest parsing, BLAKE3 root digest check, Ed25519 signature check,
// complete filesystem walk with zero stray or missing files, zero symbolic
// links, zero internal/ or modulus/ paths, and exact per-file BLAKE3 hashes.
sdk_verify :: proc(sdk_dir: string, options := Sdk_Verify_Options{}) -> (manifest: Sdk_Manifest, problem: string) {
	if strings.trim_space(sdk_dir) == "" || !os.is_dir(sdk_dir) {
		return {}, fmt.tprintf("SDK directory `%s` does not exist", sdk_dir)
	}
	manifest_path := foundation.join(sdk_dir, "/", SDK_MANIFEST_FILE_NAME)
	manifest_info, stat_err := os.lstat(manifest_path, context.temp_allocator)
	if stat_err != nil {
		return {}, fmt.tprintf("SDK manifest `%s` is missing: %v", manifest_path, stat_err)
	}
	if manifest_info.type != .Regular {
		return {}, fmt.tprintf("SDK manifest `%s` must be a regular file", manifest_path)
	}
	manifest_bytes, read_err := os.read_entire_file(manifest_path, context.temp_allocator)
	if read_err != nil {
		return {}, fmt.tprintf("cannot read SDK manifest `%s`: %v", manifest_path, read_err)
	}

	parsed, parse_problem := sdk_manifest_parse(string(manifest_bytes), context.temp_allocator)
	if parse_problem != "" {
		return {}, fmt.tprintf("invalid SDK manifest `%s`: %s", manifest_path, parse_problem)
	}

	if options.require_signature {
		if !parsed.has_signature {
			return {}, "SDK manifest is unsigned, but a verified Ed25519 signature is required"
		}
		if parsed.public_key != options.expected_public_key {
			stated := parsed.public_key
			expected := options.expected_public_key
			return {}, fmt.tprintf("SDK manifest public key %s does not match expected key %s", sdk_lowercase_hex_encode(stated[:]), sdk_lowercase_hex_encode(expected[:]))
		}
		if !sdk_verify_root_digest_signature(options.expected_public_key, parsed.root_digest, parsed.signature) {
			return {}, "SDK manifest Ed25519 signature is invalid"
		}
	} else if parsed.has_signature {
		if !sdk_verify_root_digest_signature(parsed.public_key, parsed.root_digest, parsed.signature) {
			return {}, "SDK manifest embedded Ed25519 signature is invalid"
		}
	}

	disk_files := make([dynamic]string, context.temp_allocator)
	if walk_problem := sdk_walk_directory(sdk_dir, "", &disk_files); walk_problem != "" {
		return {}, walk_problem
	}
	slice.sort(disk_files[:])

	// Compare the sorted manifest file list and sorted disk file list in lockstep
	// so every missing file and every stray unlisted file is named explicitly.
	m_idx := 0
	d_idx := 0
	has_public_library_file := false
	for m_idx < len(parsed.files) && d_idx < len(disk_files) {
		m_entry := parsed.files[m_idx]
		d_path := disk_files[d_idx]
		switch {
		case m_entry.path < d_path:
			return {}, fmt.tprintf("missing file listed in SDK manifest: `%s`", m_entry.path)
		case d_path < m_entry.path:
			return {}, fmt.tprintf("unlisted stray file found in SDK: `%s`", d_path)
		case:
			full_path := foundation.join(sdk_dir, "/", d_path)
			file_bytes, file_err := os.read_entire_file(full_path, context.temp_allocator)
			if file_err != nil {
				return {}, fmt.tprintf("cannot read SDK file `%s`: %v", d_path, file_err)
			}
			actual_hash := blake3.hash(file_bytes)
			if actual_hash != m_entry.hash {
				return {}, fmt.tprintf("SDK file `%s` failed BLAKE3 verification: expected %s, got %s", d_path, hash_as_hexadecimal(m_entry.hash), hash_as_hexadecimal(actual_hash))
			}
			if strings.has_prefix(d_path, SDK_LIBRARY_SUBDIRECTORY + "/") {
				has_public_library_file = true
			}
			m_idx += 1
			d_idx += 1
		}
	}
	if m_idx < len(parsed.files) {
		return {}, fmt.tprintf("missing file listed in SDK manifest: `%s`", parsed.files[m_idx].path)
	}
	if d_idx < len(disk_files) {
		return {}, fmt.tprintf("unlisted stray file found in SDK: `%s`", disk_files[d_idx])
	}
	if !has_public_library_file {
		return {}, fmt.tprintf("SDK contains no files under `%s/`", SDK_LIBRARY_SUBDIRECTORY)
	}
	return parsed, ""
}

// sdk_resolve_import_files loads each declared import module by searching
// import_dirs in order for `<name>.module` or `<name>.modus`, validating each
// loaded file with module.validate.
@(private = "file")
sdk_resolve_import_files :: proc(import_names: []string, import_dirs: []string) -> (files: []Import_File, problem: string) {
	if len(import_names) == 0 {
		return nil, ""
	}
	list := make([]Import_File, len(import_names), context.temp_allocator)
	for imp_name, idx in import_names {
		found_path := ""
		for dir in import_dirs {
			if dir == "" {
				continue
			}
			for ext in ([2]string{".module", ".modus"}) {
				candidate := foundation.join(strings.trim_right(dir, "/"), "/", imp_name, ext)
				if os.is_file(candidate) {
					found_path = candidate
					break
				}
			}
			if found_path != "" {
				break
			}
		}
		if found_path == "" {
			return nil, fmt.tprintf("cannot find imported module `%s` in any import directory", imp_name)
		}
		bytes, read_err := os.read_entire_file(found_path, context.temp_allocator)
		if read_err != nil {
			return nil, fmt.tprintf("cannot read imported module `%s`: %v", found_path, read_err)
		}
		if load_err := module.validate(bytes); load_err != .None {
			return nil, fmt.tprintf("imported module `%s` (%s) failed validation (%v)", imp_name, found_path, load_err)
		}
		list[idx] = Import_File{name = imp_name, file = bytes}
	}
	return list, ""
}

// sdk_ensure_parent_folder ensures the parent directory of output_path exists.
@(private = "file")
sdk_ensure_parent_folder :: proc(output_path: string) -> bool {
	if slash := strings.last_index_byte(output_path, '/'); slash > 0 {
		return foundation.make_folder(output_path[:slash])
	}
	return true
}

// sdk_convert_object_to_module converts a freestanding x86-64 relocatable ELF
// object (.o) paired with a language-neutral module.manifest into a verified
// modus module file at output_path.
sdk_convert_object_to_module :: proc(object_path, manifest_path, output_path: string, import_dirs: []string = nil) -> (problem: string) {
	object_bytes, obj_err := os.read_entire_file(object_path, context.temp_allocator)
	if obj_err != nil {
		return fmt.tprintf("cannot read object file `%s`: %v", object_path, obj_err)
	}
	manifest_bytes, man_err := os.read_entire_file(manifest_path, context.temp_allocator)
	if man_err != nil {
		return fmt.tprintf("cannot read module manifest `%s`: %v", manifest_path, man_err)
	}
	manifest, parse_problem := manifest_parse(string(manifest_bytes))
	if parse_problem != "" {
		return fmt.tprintf("invalid module manifest `%s`: %s", manifest_path, parse_problem)
	}
	imports, import_problem := sdk_resolve_import_files(manifest.imports, import_dirs)
	if import_problem != "" {
		return import_problem
	}
	module_bytes, converted := convert_elf_with_manifest(object_bytes, manifest, imports)
	if !converted {
		return fmt.tprintf("failed to convert `%s` with manifest `%s`", object_path, manifest_path)
	}
	defer delete(module_bytes)

	if load_err := module.validate(module_bytes); load_err != .None {
		return fmt.tprintf("converted module failed module.validate (%v)", load_err)
	}
	if !sdk_ensure_parent_folder(output_path) {
		return fmt.tprintf("cannot create parent directory for `%s`", output_path)
	}
	if write_err := os.write_entire_file(output_path, module_bytes); write_err != nil {
		return fmt.tprintf("cannot write module output `%s`: %v", output_path, write_err)
	}
	return ""
}

// sdk_build_outside_module builds an outside module purely against a verified
// SDK directory, with no repository checkout and no internal/ or modulus/
// collection flags. Supports both:
//   - Language-neutral ET_REL modules (`module.manifest` + `.o` or `.c`)
//   - Freestanding Odin outside modules (`module.txt` + `.odin`)
sdk_build_outside_module :: proc(sdk_dir, source_dir, output_path: string, options := Sdk_Outside_Build_Options{}) -> (problem: string) {
	if _, verify_problem := sdk_verify(sdk_dir, options.verify_options); verify_problem != "" {
		return fmt.tprintf("SDK verification failed: %s", verify_problem)
	}
	abs_sdk, sdk_abs_err := os.get_absolute_path(sdk_dir, context.temp_allocator)
	if sdk_abs_err != nil {
		return fmt.tprintf("cannot resolve SDK directory `%s`: %v", sdk_dir, sdk_abs_err)
	}
	abs_source, src_abs_err := os.get_absolute_path(source_dir, context.temp_allocator)
	if src_abs_err != nil || !os.is_dir(abs_source) {
		return fmt.tprintf("outside module folder `%s` is not a directory", source_dir)
	}
	abs_sdk = strings.trim_right(abs_sdk, "/")
	abs_source = strings.trim_right(abs_source, "/")

	import_dirs := make([dynamic]string, context.temp_allocator)
	append(&import_dirs, foundation.join(abs_sdk, "/", SDK_MODULES_SUBDIRECTORY))
	for extra_dir in options.extra_import_dirs {
		append(&import_dirs, extra_dir)
	}

	// Path A: Language-neutral ET_REL object + module.manifest.
	lang_manifest_path := foundation.join(abs_source, "/", SDK_LANGUAGE_NEUTRAL_MANIFEST_NAME)
	if os.is_file(lang_manifest_path) {
		include_dir := foundation.join(abs_sdk, "/", SDK_INCLUDE_SUBDIRECTORY)
		return sdk_build_outside_language_neutral(abs_source, lang_manifest_path, output_path, import_dirs[:], include_dir)
	}

	// Path B: Freestanding Odin outside module (module.txt + .odin sources).
	odin_build_file := foundation.join(abs_source, "/", MODULE_BUILD_FILE_NAME)
	if os.is_file(odin_build_file) {
		return sdk_build_outside_odin(abs_sdk, abs_source, odin_build_file, output_path, import_dirs[:], options.debug_information)
	}

	return fmt.tprintf("outside module folder `%s` contains neither `%s` nor `%s`", source_dir, MODULE_BUILD_FILE_NAME, SDK_LANGUAGE_NEUTRAL_MANIFEST_NAME)
}

@(private = "file")
sdk_build_outside_language_neutral :: proc(abs_source, manifest_path, output_path: string, import_dirs: []string, include_dir := "") -> string {
	object_files, obj_ok := foundation.files_with_suffix(abs_source, ".o")
	if !obj_ok {
		return fmt.tprintf("cannot list object files in `%s`", abs_source)
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	work_dir := fmt.tprintf("%s/modus_sdk_c_build_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(work_dir)
	if !foundation.make_folder(work_dir) {
		return fmt.tprintf("cannot create temporary build directory `%s`", work_dir)
	}
	defer _ = os.remove_all(work_dir)

	collected_objects := make([dynamic]string, context.temp_allocator)
	for obj in object_files {
		append(&collected_objects, obj)
	}
	if len(collected_objects) == 0 {
		c_files, c_ok := foundation.files_with_suffix(abs_source, ".c")
		if !c_ok || len(c_files) == 0 {
			return fmt.tprintf("outside module `%s` has `%s` but no `.o` or `.c` files", abs_source, SDK_LANGUAGE_NEUTRAL_MANIFEST_NAME)
		}
		for c_file, idx in c_files {
			obj_out := fmt.tprintf("%s/obj_%d.o", work_dir, idx)
			cmd := make([dynamic]string, context.temp_allocator)
			append(&cmd, "clang")
			append(&cmd, ..c_compile_flags[:])
			if include_dir != "" && os.is_dir(include_dir) {
				append(&cmd, "-I", include_dir)
			}
			append(&cmd, "-fno-plt", "-c", "-o", obj_out, c_file)
			state, _, stderr_bytes, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
			if err != nil || !state.exited || !state.success {
				return fmt.tprintf("clang failed compiling `%s`: %s", c_file, strings.trim_space(string(stderr_bytes)))
			}
			append(&collected_objects, obj_out)
		}
	}

	target_object := collected_objects[0]
	if len(collected_objects) > 1 {
		merged := foundation.join(work_dir, "/merged.o")
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "ld.lld", "-r", "-o", merged)
		for obj in collected_objects {
			append(&cmd, obj)
		}
		state, _, stderr_bytes, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
		if err != nil || !state.exited || !state.success {
			return fmt.tprintf("ld.lld -r failed combining objects: %s", strings.trim_space(string(stderr_bytes)))
		}
		target_object = merged
	}
	return sdk_convert_object_to_module(target_object, manifest_path, output_path, import_dirs)
}

@(private = "file")
sdk_build_outside_odin :: proc(abs_sdk, abs_source, build_file_path, output_path: string, import_dirs: []string, with_debug_info: bool) -> string {
	build_file_bytes, read_err := os.read_entire_file(build_file_path, context.temp_allocator)
	if read_err != nil {
		return fmt.tprintf("cannot read `%s`: %v", build_file_path, read_err)
	}
	described, parse_problem := module_build_file_parse(string(build_file_bytes))
	if parse_problem != "" {
		return fmt.tprintf("invalid `%s`: %s", build_file_path, parse_problem)
	}
	imports, import_problem := sdk_resolve_import_files(described.imports, import_dirs)
	if import_problem != "" {
		return import_problem
	}

	sdk_public_dir := foundation.join(abs_sdk, "/", SDK_LIBRARY_SUBDIRECTORY)
	sdk_runtime_memory := foundation.join(abs_sdk, "/", SDK_RUNTIME_SUBDIRECTORY, "/memory.asm")
	sdk_system_dir := foundation.join(sdk_public_dir, "/system")
	if !os.is_file(sdk_runtime_memory) {
		return fmt.tprintf("SDK runtime assembly `%s` is missing", sdk_runtime_memory)
	}

	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	work_dir := fmt.tprintf("%s/modus_sdk_odin_build_%d_%s", strings.trim_right(temp_base, "/"), os.get_pid(), described.name)
	_ = os.remove_all(work_dir)
	llvm_ir_dir := foundation.join(work_dir, "/llvm_ir")
	objects_dir := foundation.join(work_dir, "/objects")
	if !foundation.make_folder(llvm_ir_dir) || !foundation.make_folder(objects_dir) {
		return fmt.tprintf("cannot create temporary SDK build directory `%s`", work_dir)
	}
	defer _ = os.remove_all(work_dir)

	dependency_file := foundation.join(work_dir, "/", DEPENDENCY_FILE_NAME)

	// Compile purely against `-collection:modus=<sdk>/library/modus`.
	// Never pass `-collection:internal` or `-collection:modulus`.
	compile_cmd := make([dynamic]string, context.temp_allocator)
	append(
		&compile_cmd,
		"odin",
		"build",
		abs_source,
		"-target:freestanding_amd64_sysv",
		"-build-mode:llvm-ir",
		"-reloc-mode:pic",
		"-no-entry-point",
		"-default-to-nil-allocator",
		"-o:speed",
		"-vet",
		"-source-code-locations:filename",
		"-export-dependencies:json",
		foundation.join("-export-dependencies-file:", dependency_file),
		foundation.join("-collection:", foundation.SOURCE_LIBRARY_NAME, "=", sdk_public_dir),
		foundation.CUSTOM_ATTRIBUTES_FLAG,
		foundation.join("-out:", llvm_ir_dir),
	)
	if with_debug_info {
		append(&compile_cmd, "-debug-info:same-code")
	}
	for define in described.defines {
		append(&compile_cmd, foundation.join("-define:", define))
	}
	compile_state, _, compile_stderr, compile_err := os.process_exec({command = compile_cmd[:]}, context.temp_allocator)
	if compile_err != nil || !compile_state.exited || !compile_state.success {
		return fmt.tprintf("odin compile failed for `%s`: %s", described.name, strings.trim_space(string(compile_stderr)))
	}

	// Enforce the rule of three places: every source read by the compiler must
	// reside inside abs_source, <sdk>/library/modus, or the compiler libraries.
	dep_files, _, dep_ok := dependency_list_read(dependency_file)
	if !dep_ok {
		return fmt.tprintf("cannot read compiler dependency list `%s`", dependency_file)
	}
	compiler_folder := odin_root()
	fact_sources := make([dynamic]Fact_Source, context.temp_allocator)
	source_prefix := foundation.join(abs_source, "/")
	sdk_public_prefix := foundation.join(sdk_public_dir, "/")
	for dep_path in dep_files {
		if !outside_module_source_has_a_place(dep_path, abs_source, sdk_public_dir, compiler_folder) {
			return fmt.tprintf("outside module `%s` referenced forbidden source `%s` outside module folder, SDK public library, and compiler libraries", described.name, dep_path)
		}
		if strings.contains(dep_path, "/" + foundation.INTERNAL_LIBRARY_NAME + "/") || strings.contains(dep_path, "/" + foundation.KERNEL_LIBRARY_NAME + "/") {
			return fmt.tprintf("outside module `%s` referenced forbidden namespace in `%s`", described.name, dep_path)
		}
		if !strings.has_suffix(dep_path, "_test.odin") && (strings.has_prefix(dep_path, source_prefix) || strings.has_prefix(dep_path, sdk_public_prefix)) {
			src_bytes, src_err := os.read_entire_file(dep_path, context.temp_allocator)
			if src_err != nil {
				return fmt.tprintf("cannot read source `%s`: %v", dep_path, src_err)
			}
			append(&fact_sources, Fact_Source{path = dep_path, source = string(src_bytes)})
		}
	}

	// Locate the single emitted LLVM IR file and strip compile timestamps.
	ir_files, ir_ok := foundation.files_with_suffix(llvm_ir_dir, ".ll")
	if !ir_ok || len(ir_files) != 1 {
		return fmt.tprintf("expected 1 LLVM IR file for `%s`, found %d", described.name, len(ir_files))
	}
	ir_path := foundation.join(work_dir, "/", described.name, ".ll")
	if move_err := foundation.file_move(ir_files[0], ir_path); move_err != nil {
		return fmt.tprintf("cannot move LLVM IR for `%s`: %v", described.name, move_err)
	}
	ir_bytes, ir_read_err := os.read_entire_file(ir_path, context.temp_allocator)
	if ir_read_err != nil {
		return fmt.tprintf("cannot read LLVM IR `%s`: %v", ir_path, ir_read_err)
	}
	ir_text := string(ir_bytes)
	if without_time, changed := llvm_ir_without_compile_time(ir_text, context.temp_allocator); changed > 0 {
		if write_err := os.write_entire_file(ir_path, without_time); write_err != nil {
			return fmt.tprintf("cannot write LLVM IR `%s`: %v", ir_path, write_err)
		}
		ir_text = without_time
	}

	// Lower LLVM IR to a PIC x86-64 object with frame pointers preserved.
	main_object := foundation.join(objects_dir, "/", described.name, ".o")
	llc_cmd := [?]string {
		"llc",
		"-O3",
		"-misched-topdown",
		"--frame-pointer=all",
		"-relocation-model=pic",
		"--function-sections",
		"--data-sections",
		"-filetype=obj",
		"-o",
		main_object,
		ir_path,
	}
	llc_state, _, llc_stderr, llc_err := os.process_exec({command = llc_cmd[:]}, context.temp_allocator)
	if llc_err != nil || !llc_state.exited || !llc_state.success {
		return fmt.tprintf("llc failed for `%s`: %s", described.name, strings.trim_space(string(llc_stderr)))
	}
	objcopy_cmd := [?]string{"llvm-objcopy", "--remove-section=.eh_frame", "--remove-section=.rela.eh_frame", main_object}
	objcopy_state, _, objcopy_stderr, objcopy_err := os.process_exec({command = objcopy_cmd[:]}, context.temp_allocator)
	if objcopy_err != nil || !objcopy_state.exited || !objcopy_state.success {
		return fmt.tprintf("llvm-objcopy failed for `%s`: %s", described.name, strings.trim_space(string(objcopy_stderr)))
	}

	// Assemble runtime memory routines, SDK system assembly, and module assembly.
	asm_files := make([dynamic]string, context.temp_allocator)
	append(&asm_files, sdk_runtime_memory)
	if own_asm, own_ok := foundation.files_with_suffix(abs_source, ".asm"); own_ok {
		append(&asm_files, ..own_asm)
	}
	if os.is_dir(sdk_system_dir) {
		if sys_asm, sys_ok := foundation.files_with_suffix(sdk_system_dir, ".asm"); sys_ok {
			append(&asm_files, ..sys_asm)
		}
	}
	for asm_path, idx in asm_files {
		asm_obj := fmt.tprintf("%s/asm_%d.o", objects_dir, idx)
		nasm_cmd := [?]string{"nasm", "-f", "elf64", "-o", asm_obj, asm_path}
		nasm_state, _, nasm_stderr, nasm_err := os.process_exec({command = nasm_cmd[:]}, context.temp_allocator)
		if nasm_err != nil || !nasm_state.exited || !nasm_state.success {
			return fmt.tprintf("nasm failed on `%s`: %s", asm_path, strings.trim_space(string(nasm_stderr)))
		}
	}

	// Redirect public library lookup to <sdk>/library/modus so describe_package
	// and fact extraction work completely outside any repository checkout.
	previous_public_folder := foundation.source_library_public_folder
	foundation.source_library_public_folder = sdk_public_dir
	defer foundation.source_library_public_folder = previous_public_folder

	description, described_ok := describe_package(abs_source)
	if !described_ok {
		return fmt.tprintf("failed to describe exports of outside module `%s`", described.name)
	}
	if all_facts, facts_ok := facts_of_sources(fact_sources[:]); facts_ok {
		reached, reach_problem := facts_reached(ir_text, all_facts, abs_source)
		if reach_problem != "" {
			return fmt.tprintf("log facts of `%s`: %s", described.name, reach_problem)
		}
		if !facts_merge(&description, reached) {
			return fmt.tprintf("failed to merge log facts of `%s`", described.name)
		}
	} else {
		return fmt.tprintf("failed to extract log facts of `%s`", described.name)
	}
	stream_outputs, stream_inputs, streams_ok := record_streams_of_sources(abs_source, fact_sources[:])
	if !streams_ok || !record_streams_merge(&description, stream_outputs, stream_inputs) {
		return fmt.tprintf("failed to extract record streams of `%s`", described.name)
	}
	if description.budget.stated && len(imports) > 0 {
		import_sizes := make([]u64, len(imports), context.temp_allocator)
		for imp, idx in imports {
			imp_head, _ := module.header(imp.file)
			import_sizes[idx] = imp_head.memory_size
		}
		description.budget.import_memory_sizes = import_sizes
	}

	// Link only described exports as global symbols.
	version_script := strings.builder_make(context.temp_allocator)
	strings.write_string(&version_script, "{ global: ")
	for exp in description.exports {
		fmt.sbprintf(&version_script, "%s; ", exp.name)
	}
	strings.write_string(&version_script, "local: *; };\n")
	script_path := foundation.join(work_dir, "/exports.version")
	if err := os.write_entire_file(script_path, strings.to_string(version_script)); err != nil {
		return fmt.tprintf("cannot write version script `%s`: %v", script_path, err)
	}

	linked_elf := foundation.join(work_dir, "/linked.elf")
	all_objects, obj_list_ok := foundation.files_with_suffix(objects_dir, ".o")
	if !obj_list_ok || len(all_objects) == 0 {
		return fmt.tprintf("no compiled objects found for `%s`", described.name)
	}
	link_cmd := make([dynamic]string, context.temp_allocator)
	append(
		&link_cmd,
		"ld.lld",
		"-shared",
		"-nostdlib",
		"-Bsymbolic",
		"--gc-sections",
		"--build-id=none",
		"-z",
		"now",
		"-z",
		"relro",
		foundation.join("--version-script=", script_path),
		"-o",
		linked_elf,
	)
	append(&link_cmd, ..all_objects)
	link_state, _, link_stderr, link_err := os.process_exec({command = link_cmd[:]}, context.temp_allocator)
	if link_err != nil || !link_state.exited || !link_state.success {
		return fmt.tprintf("ld.lld failed linking `%s`: %s", described.name, strings.trim_space(string(link_stderr)))
	}

	elf_bytes, elf_err := os.read_entire_file(linked_elf, context.temp_allocator)
	if elf_err != nil {
		return fmt.tprintf("cannot read linked ELF `%s`: %v", linked_elf, elf_err)
	}
	import_slot_symbols := make([dynamic]string, context.temp_allocator)
	module_bytes, converted := convert(described.name, elf_bytes, description, imports, &import_slot_symbols)
	if !converted {
		return fmt.tprintf("conversion failed for outside module `%s`", described.name)
	}
	defer delete(module_bytes)

	if described.library && !module_is_a_library_check(described.name, module_bytes) {
		return fmt.tprintf("outside library module `%s` failed library module check", described.name)
	}
	if load_err := module.validate(module_bytes); load_err != .None {
		return fmt.tprintf("outside module `%s` failed module.validate (%v)", described.name, load_err)
	}
	if !sdk_ensure_parent_folder(output_path) {
		return fmt.tprintf("cannot create parent directory for `%s`", output_path)
	}
	if write_err := os.write_entire_file(output_path, module_bytes); write_err != nil {
		return fmt.tprintf("cannot write module `%s`: %v", output_path, write_err)
	}
	return ""
}

// run_sdk_pack implements `modustool sdk-pack <output-dir> [--sign-key <path>] [--modules-dir <path>]`.
run_sdk_pack :: proc(args: []string) -> int {
	output_dir := ""
	sign_key_path := ""
	modules_dir := ""
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch {
		case arg == "--sign-key" || arg == "--modules-dir":
			if index + 1 >= len(args) {
				fmt.eprintln(SDK_PACK_USAGE)
				return foundation.EXIT_USAGE
			}
			if arg == "--sign-key" {
				sign_key_path = args[index + 1]
			} else {
				modules_dir = args[index + 1]
			}
			index += 1
		case strings.has_prefix(arg, "--") || output_dir != "":
			fmt.eprintln(SDK_PACK_USAGE)
			return foundation.EXIT_USAGE
		case:
			output_dir = arg
		}
	}
	if output_dir == "" {
		fmt.eprintln(SDK_PACK_USAGE)
		return foundation.EXIT_USAGE
	}

	options := Sdk_Build_Options{modules_folder = modules_dir}
	defer crypto.zero_explicit(&options.signing_key_seed, size_of(options.signing_key_seed))

	if sign_key_path != "" {
		key_bytes, read_ok := foundation.read_file(sign_key_path)
		if !read_ok {
			return foundation.EXIT_FAILURE
		}
		defer crypto.zero_explicit(raw_data(key_bytes), len(key_bytes))
		seed, decoded := sdk_key_decode(string(key_bytes))
		if !decoded {
			fmt.eprintfln("modustool: sdk-pack: `%s` must hold a 32-byte Ed25519 private key seed in 64 hexadecimal digits or unpadded base64url", sign_key_path)
			return foundation.EXIT_FAILURE
		}
		options.signing_key_seed = seed
		options.has_signing_key = true
	}

	manifest, problem := sdk_build(output_dir, options)
	if problem != "" {
		fmt.eprintfln("modustool: sdk-pack: %s", problem)
		return foundation.EXIT_FAILURE
	}
	if manifest.has_signature {
		pub := manifest.public_key
		fmt.printfln("modustool: sdk-pack: wrote verified signed SDK %s at %s (%d files, root_digest %s, public_key %s)", manifest.release_version, output_dir, len(manifest.files), hash_as_hexadecimal(manifest.root_digest), sdk_lowercase_hex_encode(pub[:]))
	} else {
		fmt.printfln("modustool: sdk-pack: wrote verified unsigned SDK %s at %s (%d files, root_digest %s)", manifest.release_version, output_dir, len(manifest.files), hash_as_hexadecimal(manifest.root_digest))
	}
	return 0
}

// run_sdk_verify implements `modustool sdk-verify <sdk-dir> [--public-key <path>]`.
run_sdk_verify :: proc(args: []string) -> int {
	sdk_dir := ""
	public_key_path := ""
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch {
		case arg == "--public-key":
			if index + 1 >= len(args) {
				fmt.eprintln(SDK_VERIFY_USAGE)
				return foundation.EXIT_USAGE
			}
			public_key_path = args[index + 1]
			index += 1
		case strings.has_prefix(arg, "--") || sdk_dir != "":
			fmt.eprintln(SDK_VERIFY_USAGE)
			return foundation.EXIT_USAGE
		case:
			sdk_dir = arg
		}
	}
	if sdk_dir == "" {
		fmt.eprintln(SDK_VERIFY_USAGE)
		return foundation.EXIT_USAGE
	}

	verify_options := Sdk_Verify_Options{}
	if public_key_path != "" {
		key_bytes, read_ok := foundation.read_file(public_key_path)
		if !read_ok {
			return foundation.EXIT_FAILURE
		}
		pub_key, decoded := sdk_key_decode(string(key_bytes))
		if !decoded {
			fmt.eprintfln("modustool: sdk-verify: `%s` must hold a 32-byte Ed25519 public key in 64 hexadecimal digits or unpadded base64url", public_key_path)
			return foundation.EXIT_FAILURE
		}
		verify_options.expected_public_key = pub_key
		verify_options.require_signature = true
	}

	manifest, problem := sdk_verify(sdk_dir, verify_options)
	if problem != "" {
		fmt.eprintfln("modustool: sdk-verify: %s", problem)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: sdk-verify: ok (%s, %d files, root_digest %s, signed=%v)", manifest.release_version, len(manifest.files), hash_as_hexadecimal(manifest.root_digest), manifest.has_signature)
	return 0
}

// run_sdk_convert implements `modustool sdk-convert <object.o> <module.manifest> <output.modus> [--sdk <sdk-dir>] [--import-dir <dir>]`.
run_sdk_convert :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	import_dirs := make([dynamic]string, context.temp_allocator)
	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch {
		case arg == "--sdk" || arg == "--import-dir":
			if index + 1 >= len(args) {
				fmt.eprintln(SDK_CONVERT_USAGE)
				return foundation.EXIT_USAGE
			}
			dir := args[index + 1]
			if arg == "--sdk" {
				if _, verify_problem := sdk_verify(dir); verify_problem != "" {
					fmt.eprintfln("modustool: sdk-convert: SDK `%s` failed verification: %s", dir, verify_problem)
					return foundation.EXIT_FAILURE
				}
				append(&import_dirs, foundation.join(strings.trim_right(dir, "/"), "/", SDK_MODULES_SUBDIRECTORY))
			} else {
				append(&import_dirs, dir)
			}
			index += 1
		case strings.has_prefix(arg, "--"):
			fmt.eprintln(SDK_CONVERT_USAGE)
			return foundation.EXIT_USAGE
		case:
			append(&positional, arg)
		}
	}
	if len(positional) != 3 {
		fmt.eprintln(SDK_CONVERT_USAGE)
		return foundation.EXIT_USAGE
	}
	if os.is_dir(foundation.MODULE_BUILD_FOLDER) {
		append(&import_dirs, foundation.MODULE_BUILD_FOLDER)
	}
	object_path, manifest_path, output_path := positional[0], positional[1], positional[2]
	if problem := sdk_convert_object_to_module(object_path, manifest_path, output_path, import_dirs[:]); problem != "" {
		fmt.eprintfln("modustool: sdk-convert: %s", problem)
		return foundation.EXIT_FAILURE
	}
	written, read_ok := foundation.read_file(output_path)
	if !read_ok {
		return foundation.EXIT_FAILURE
	}
	export_count := int(module.count(written, .Exports)) - 1
	fmt.printfln("modustool: sdk-convert: wrote %s (%d bytes, %d exports, hash %s)", output_path, len(written), max(export_count, 0), hash_as_hexadecimal(blake3.hash(written)))
	return 0
}
