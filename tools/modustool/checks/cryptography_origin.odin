package checks

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import "modustool:foundation"

// The cryptography of the system is code of Odin's `core:crypto`, taken
// into src/library/modus/cryptography and changed in a listed way only
// (docs/CRYPTOGRAPHY.md). This check proves it for each file of the
// manifest: the origin file in the compiler that the flake pins has the
// BLAKE3 hash of the manifest, and the origin with the changes below gives
// the file of the repository, byte for byte. A reader audits the changes
// here, not in a diff of each file.

// The files of src/library/modus/cryptography that the system wrote itself (the
// compatibility layer, the files in the place of a hardware dispatch, the
// tests), each with its BLAKE3 hash: a change of one of them shows in the
// check and in review, as a change of a taken file does.
CRYPTOGRAPHY_SYSTEM_FILES :: foundation.CRYPTOGRAPHY_FOLDER + "/system_files.manifest"
CRYPTOGRAPHY_ORIGIN_PREFIX :: "core/crypto/"
// The word in place of a hash that the coordinator has to compute with
// `modustool cryptography-system-hashes`.
HASH_TO_COMPUTE :: "TO_COMPUTE"
CRYPTOGRAPHY_ORIGIN_RELEASE :: "dev-2026-11a" // The release of Odin that flake.nix pins.

// With the package name of the copy (cryptography_packages below), the only
// changes of a file that is taken: its imports go to the copies in
// src/library/modus/cryptography, and to the compatibility layer for the helpers of
// the origin. Order matters: the base package first, with its quote.
// The packages of the compatibility layer have their own names
// (compatibility_crypto, ...), so that a test that also imports a package of
// Odin with the name of the origin compiles; the import keeps the name of
// the origin as its alias.
@(rodata)
cryptography_import_changes := [?][2]string {
	{"\"core:crypto\"", "crypto \"modus:cryptography/compatibility_crypto\""},
	{"\"core:crypto/hash\"", "hash \"modus:cryptography/compatibility_hash\""},
	{"\"core:crypto/", "\"modus:cryptography/"},
	{"\"core:encoding/endian\"", "endian \"modus:cryptography/compatibility_endian\""},
	{"\"core:math/bits\"", "bits \"modus:cryptography/compatibility_bits\""},
	{"\"core:bytes\"", "bytes \"modus:cryptography/compatibility_bytes\""},
	{"\"core:simd\"", "simd \"modus:cryptography/compatibility_simd\""},
}

// The start of the declared name of each package of the copy; the name of
// its package in the origin follows it whole. Odin refuses two packages of
// one declared name in one program, so a host program that imports
// core:crypto and the copy needs names that core:crypto does not use. The
// name of an import comes from its path, so no import changes. One prefix keeps the name
// of the origin readable in each name, keeps `_chacha20` apart from
// `chacha20`, and is one rule for the check
// (src/md/infrastructure/cryptography_package_names.md).
CRYPTOGRAPHY_PACKAGE_PREFIX :: "modus_"

// A package of core:crypto that the copy holds: its folder under
// core/crypto, which the copy keeps under src/library/modus/cryptography,
// and the name of its package in the origin.
Cryptography_Package :: struct {
	folder:      string,
	origin_name: string,
}

// Each package of the copy. A taken file is in one of these folders; a file
// of the system in one of them declares the package of the copy too.
@(rodata)
cryptography_packages := [?]Cryptography_Package {
	{"_aes", "_aes"},
	{"_aes/ct64", "aes_ct64"},
	{"_aes/hw", "aes_hw"},
	{"_blake2", "_blake2"},
	{"_chacha20", "_chacha20"},
	{"_chacha20/ref", "chacha20_ref"},
	{"_chacha20/simd128", "chacha20_simd128"},
	{"_edwards25519", "_edwards25519"},
	{"_fiat", "fiat"},
	{"_fiat/field_curve25519", "field_curve25519"},
	{"_fiat/field_poly1305", "field_poly1305"},
	{"_fiat/field_scalar25519", "field_scalar25519"},
	{"_subtle", "_subtle"},
	{"aes", "aes"},
	{"argon2id", "argon2id"},
	{"blake2b", "blake2b"},
	{"chacha20", "chacha20"},
	{"chacha20poly1305", "chacha20poly1305"},
	{"ed25519", "ed25519"},
	{"hkdf", "hkdf"},
	{"hmac", "hmac"},
	{"poly1305", "poly1305"},
	{"sha2", "sha2"},
	{"x25519", "x25519"},
}

// cryptography_package_of_folder gives the package of the copy whose folder
// under core/crypto is folder.
cryptography_package_of_folder :: proc(folder: string) -> (copied: Cryptography_Package, found: bool) {
	for candidate in cryptography_packages {
		if candidate.folder == folder {
			return candidate, true
		}
	}
	return {}, false
}

// cryptography_folder_of_file gives the folder of a file, from the start of
// the path to its last "/": "sha2/sha2.odin" gives "sha2".
cryptography_folder_of_file :: proc(path: string) -> string {
	end := strings.last_index_byte(path, '/')
	return end < 0 ? "" : path[:end]
}

// cryptography_package_line gives the line that declares a package of the
// copy: `package modus_<name of the origin>`.
cryptography_package_line :: proc(copied: Cryptography_Package) -> string {
	return strings.concatenate({"package ", CRYPTOGRAPHY_PACKAGE_PREFIX, copied.origin_name}, context.temp_allocator)
}

// cryptography_line_count counts the lines of text that are line whole: a
// comment line that starts with the same words is another line.
cryptography_line_count :: proc(text, line: string) -> int {
	count := 0
	for candidate in strings.split(text, "\n", context.temp_allocator) {
		if candidate == line {
			count += 1
		}
	}
	return count
}

// cryptography_package_rename gives the origin with its package line
// `package <name of the origin>` as the package line of the copy. Only the
// declared name changes: Odin names an import with no alias by the last
// element of its path, so the importing code keeps its names, and the
// declared name is the one that two packages of one program must not share.
// ok is false when the origin is in a folder that no package of the copy
// names, or has its package line other than exactly one time.
cryptography_package_rename :: proc(origin: string, origin_path: string) -> (renamed: string, ok: bool) {
	copied, found := cryptography_package_of_folder(cryptography_folder_of_file(strings.trim_prefix(origin_path, CRYPTOGRAPHY_ORIGIN_PREFIX)))
	if !found {
		fmt.eprintfln("modustool: the folder of %s is in no row of cryptography_packages: a package of the copy has its row first", origin_path)
		return "", false
	}
	origin_line := strings.concatenate({"package ", copied.origin_name}, context.temp_allocator)
	if cryptography_line_count(origin, origin_line) != 1 {
		fmt.eprintfln("modustool: %s has the line %q %d times, not 1: the origin changed; read its row of cryptography_packages again", origin_path, origin_line, cryptography_line_count(origin, origin_line))
		return "", false
	}
	lines := strings.split(origin, "\n", context.temp_allocator)
	for &line in lines {
		if line == origin_line {
			line = cryptography_package_line(copied)
		}
	}
	return strings.join(lines, "\n", context.temp_allocator), true
}

// cryptography_system_file_package_holds says if a file of the system has
// the package line of the copy when it is in a folder of the copy: a file
// that kept the name of the origin would bring the clash back. A file of
// another folder (the compatibility layer, the vectors) has names that
// core:crypto does not use.
cryptography_system_file_package_holds :: proc(path: string, text: string) -> bool {
	copied, found := cryptography_package_of_folder(cryptography_folder_of_file(strings.trim_prefix(path, foundation.CRYPTOGRAPHY_FOLDER + "/")))
	if !found || !strings.has_prefix(path, foundation.CRYPTOGRAPHY_FOLDER + "/") {
		return true
	}
	if cryptography_line_count(text, cryptography_package_line(copied)) != 1 {
		fmt.eprintfln("modustool: test failed: %s is in the folder of the package %s of the copy, and has not the line %q exactly one time", path, copied.origin_name, cryptography_package_line(copied))
		return false
	}
	return true
}

// One listed adjustment of a taken file: lines of the origin, and the lines
// in their place. The lines of the origin must be in the origin exactly one
// time: when the origin changes them, the check fails, and a developer looks
// at the adjustment again.
Cryptography_Adjustment :: struct {
	origin_path:  string,
	origin_lines: string,
	lines:        string,
}

// The listed adjustments (docs/CRYPTOGRAPHY.md, section 4, "Listed
// adjustments"). There are four groups.
//
// The adjustments of _chacha20/chacha20.odin are one correction of the
// origin, offered to Odin as its pull request 8329: the counter check of
// ChaCha20 refused the block with the last counter, which RFC 8439 allows,
// and the peer of a QUIC connection chooses that counter (the sample of the
// header protection). The check now allows a call that ends on the last
// block, refuses a call that goes past it, and refuses each call after it
// until `seek` or `init`. When the release of Odin that the flake pins has
// the correction, these lines go.
//
// The adjustments of argon2id/argon2id.odin take its allocator away: the
// caller supplies the blocks, because the code of a module, with an entry or
// not, has no allocator. A supply that is smaller than the parameters ask, or
// not aligned on 8 bytes, is the result Out_Of_Memory before any work. The
// helpers of core:mem come from the compatibility layer.
//
// The adjustments of _edwards25519 remove a package variable that holds
// the address of the table of the base point: the compiler writes such an
// address at the start of a program, which a module with an entry never
// runs (docs/MODULE_CONTRACT.md, "Package variables are constant data at
// the load"). The two calls that read it take the address of the table
// themselves, so the code depends on no start.
//
// The adjustments of _chacha20/simd128/chacha20_simd128.odin switch `core:simd`
// to `compatibility_simd`, lower the amd64 target feature attribute from
// `"sse2,ssse3"` to baseline `"sse2"` so it runs on every x86-64 processor and
// QEMU without SSSE3, and replace the runtime `core:sys/info` feature check
// with a compile-time architecture predicate (`amd64` or `arm64`).
cryptography_adjustments := [?]Cryptography_Adjustment {
	{
		"core/crypto/_edwards25519/edwards25519_table.odin",
		"\n\tGE_BASEPOINT_TABLE := &Gen_Multiply_Table_edwards25519_lo[0]\n",
		"\n",
	},
	{
		"core/crypto/_edwards25519/edwards25519_scalar_mul.odin",
		"\t\t\tmul_bp_tbl_add(&tmp, GE_BASEPOINT_TABLE, hi_b, &tmp_add, &tmp_bp_addend, true)\n",
		"\t\t\tmul_bp_tbl_add(&tmp, &Gen_Multiply_Table_edwards25519_lo[0], hi_b, &tmp_add, &tmp_bp_addend, true)\n",
	},
	{
		"core/crypto/_edwards25519/edwards25519_scalar_mul.odin",
		"\t\t\tmul_bp_tbl_add(&tmp, GE_BASEPOINT_TABLE, lo_b, &tmp_add, &tmp_bp_addend, true)\n",
		"\t\t\tmul_bp_tbl_add(&tmp, &Gen_Multiply_Table_edwards25519_lo[0], lo_b, &tmp_add, &tmp_bp_addend, true)\n",
	},
	{
		"core/crypto/argon2id/argon2id.odin",
		"import \"core:mem\"\n",
		"import mem \"modus:cryptography/compatibility_memory\"\n",
	},
	{
		"core/crypto/argon2id/argon2id.odin",
		"\tallocator := context.allocator, // Not temp as this can be large.\n",
		"\twork_memory: []byte = nil, // The caller supplies the blocks: memory_size KiB, aligned on 8 bytes.\n",
	},
	{
		"core/crypto/argon2id/argon2id.odin",
		"\tb := mem.alloc_bytes_non_zeroed(\n\t\tint(m_) * BLOCK_SIZE_BYTES,\n\t\talignment = mem.PAGE_SIZE,\n\t\tallocator = allocator,\n\t) or_return\n\tdefer delete(b, allocator)\n",
		"\tif u64(len(work_memory)) < m_ * BLOCK_SIZE_BYTES || uintptr(raw_data(work_memory)) % 8 != 0 {\n\t\treturn .Out_Of_Memory\n\t}\n\tb := work_memory[:int(m_) * BLOCK_SIZE_BYTES]\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"import \"base:intrinsics\"\n",
		"",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\t_is_initialized: bool,\n}\n",
		"\t_is_initialized: bool,\n\t_is_exhausted:   bool,\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctx._is_initialized = true\n}\n",
		"\tctx._is_initialized = true\n\tctx._is_exhausted = false\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctx._s[12] = u32(block_nr)\n\tctx._off = BLOCK_SIZE\n}\n",
		"\tctx._s[12] = u32(block_nr)\n\tctx._off = BLOCK_SIZE\n\tctx._is_exhausted = false\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctr_ok: bool\n\tif ctx._is_ietf_flavor {\n\t\tif intrinsics.unlikely(ctx._s[12] == MAX_CTR_IETF && nr_blocks > 1) {\n\t\t\t// Allow the final block.\n\t\t\tctr_ok = false\n\t\t} else {\n\t\t\tctr_ok = u64(ctx._s[12]) + u64(nr_blocks) <= MAX_CTR_IETF\n\t\t}\n\t} else {\n\t\tctr := (u64(ctx._s[13]) << 32) | u64(ctx._s[12])\n\t\tnew_ctr, carry := bits.add_u64(ctr, u64(nr_blocks), 0)\n\t\tctr_ok = carry == 0 || new_ctr != 0 // Allow the final block.\n\t}\n\n\tensure(ctr_ok, \"crypto/chacha20: maximum (X)ChaCha20 keystream per IV reached\")\n",
		"\t// The final block is the one with the maximum counter value.\n\t// The counter wraps around after it, so once it is consumed,\n\t// refuse to generate more keystream until `seek` or `init`.\n\tctr_ok, is_final: bool\n\tif ctx._is_ietf_flavor {\n\t\tnew_ctr := u64(ctx._s[12]) + u64(nr_blocks)\n\t\tctr_ok = new_ctr <= MAX_CTR_IETF + 1\n\t\tis_final = new_ctr == MAX_CTR_IETF + 1\n\t} else {\n\t\tctr := (u64(ctx._s[13]) << 32) | u64(ctx._s[12])\n\t\tnew_ctr, carry := bits.add_u64(ctr, u64(nr_blocks), 0)\n\t\tctr_ok = carry == 0 || new_ctr == 0\n\t\tis_final = carry != 0\n\t}\n\n\tensure(ctr_ok && !ctx._is_exhausted, ERR_CTR_EXHAUSTED)\n\tctx._is_exhausted = is_final\n",
	},
	{
		"core/crypto/_chacha20/simd128/chacha20_simd128.odin",
		"@(require) import \"core:sys/info\"\n",
		"",
	},
	{
		"core/crypto/_chacha20/simd128/chacha20_simd128.odin",
		"\tTARGET_SIMD_FEATURES :: \"sse2,ssse3\"\n",
		"\tTARGET_SIMD_FEATURES :: \"sse2\"\n",
	},
	{
		"core/crypto/_chacha20/simd128/chacha20_simd128.odin",
		"is_performant :: proc \"contextless\" () -> bool {\n\twhen ODIN_ARCH == .arm64 || ODIN_ARCH == .arm32 || ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 || ODIN_ARCH == .riscv64 {\n\t\twhen ODIN_ARCH == .arm64 || ODIN_ARCH == .arm32 {\n\t\t\treq_features :: info.CPU_Features{.asimd}\n\t\t} else when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 {\n\t\t\treq_features :: info.CPU_Features{.sse2, .ssse3}\n\t\t} else when ODIN_ARCH == .riscv64 {\n\t\t\treq_features :: info.CPU_Features{.V}\n\t\t}\n\n\t\treturn info.cpu_features() >= req_features\n\t} else when ODIN_ARCH == .wasm64p32 || ODIN_ARCH == .wasm32 {\n\t\treturn intrinsics.has_target_feature(\"simd128\")\n\t} else {\n\t\treturn false\n\t}\n}\n",
		"is_performant :: proc \"contextless\" () -> bool {\n\treturn ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64\n}\n",
	},
}

// cryptography_adjusted says if a taken file has a listed adjustment.
cryptography_adjusted :: proc(origin_path: string) -> bool {
	for adjustment in cryptography_adjustments {
		if adjustment.origin_path == origin_path {
			return true
		}
	}
	return false
}

// cryptography_marking is the first line of each file that is taken: the
// zlib license of Odin asks that an altered source says so.
cryptography_marking :: proc(origin_path: string) -> string {
	what := cryptography_adjusted(origin_path) ? "its package name and its imports changed, and the adjustments that tools/modustool/checks/cryptography_origin.odin lists" : "only its package name and its imports changed"
	return fmt.tprintf("// Altered source: Odin %s, %s; %s (" + foundation.CRYPTOGRAPHY_MANIFEST + ", docs/CRYPTOGRAPHY.md).\n", CRYPTOGRAPHY_ORIGIN_RELEASE, origin_path, what)
}

// cryptography_file_from_origin gives the bytes that the file of the
// repository must have: the marking, then the origin with each listed
// adjustment of that file, the package name of the copy, and each import
// change. ok is false when the lines of an adjustment are not in the origin
// exactly one time, or when cryptography_package_rename refuses the origin.
cryptography_file_from_origin :: proc(origin: string, origin_path: string) -> (file: string, ok: bool) {
	text := origin
	for adjustment in cryptography_adjustments {
		if adjustment.origin_path != origin_path {
			continue
		}
		if strings.count(text, adjustment.origin_lines) != 1 {
			fmt.eprintfln("modustool: an adjustment of %s names lines that the origin has %d times, not 1: the origin changed; read the adjustment again", origin_path, strings.count(text, adjustment.origin_lines))
			return "", false
		}
		text, _ = strings.replace(text, adjustment.origin_lines, adjustment.lines, 1, context.temp_allocator)
	}
	text = cryptography_package_rename(text, origin_path) or_return
	for change in cryptography_import_changes {
		text, _ = strings.replace_all(text, change[0], change[1], context.temp_allocator)
	}
	return strings.concatenate({cryptography_marking(origin_path), text}, context.temp_allocator), true
}

hex_text :: proc(bytes: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte in bytes {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

// odin_files_of_a_folder gives each .odin file under a folder and its
// subfolders: Odin compiles each .odin file of a package folder, so each one
// must be in a list. A symbolic link is refused (a folder of a copy that
// points elsewhere would bring files that no list names), and so is a file
// that is not a .odin file, a license or one of the two manifests (a #load
// or a foreign import could read it, and its bytes have no hash). The lists
// are a tripwire, not a proof of review: whoever changes a file of the
// system also writes its new hash; the review reads the change.
odin_files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", folder, err)
		return false
	}
	for entry in entries {
		path := foundation.join(folder, "/", entry.name)
		switch {
		case entry.type == .Symlink:
			fmt.eprintfln("modustool: test failed: %s is a symbolic link: the files of " + foundation.CRYPTOGRAPHY_FOLDER + " are in its folders", path)
			return false
		case entry.type == .Directory:
			odin_files_of_a_folder(path, files) or_return
		case strings.has_suffix(entry.name, ".odin"):
			append(files, path)
		case strings.has_prefix(entry.name, "LICENSE.") && folder == foundation.CRYPTOGRAPHY_FOLDER, path == foundation.CRYPTOGRAPHY_MANIFEST, path == CRYPTOGRAPHY_SYSTEM_FILES:
		case:
			fmt.eprintfln("modustool: test failed: %s is not a .odin file, a license or a manifest: no list can name it", path)
			return false
		}
	}
	return true
}

// cryptography_system_files_check reads the list of the files that the
// system wrote: "<file of the repository> <BLAKE3 of the file>". Each file
// must have that hash.
cryptography_system_files_check :: proc(listed: ^map[string]string) -> bool {
	lines := foundation.manifest_lines(CRYPTOGRAPHY_SYSTEM_FILES) or_return
	for parts in lines {
		if len(parts) != 2 {
			fmt.eprintfln("modustool: test failed: a line of %s does not have 2 parts: %v", CRYPTOGRAPHY_SYSTEM_FILES, parts)
			return false
		}
		if parts[0] in listed {
			fmt.eprintfln("modustool: test failed: %s is in two lists", parts[0])
			return false
		}
		listed[parts[0]] = CRYPTOGRAPHY_SYSTEM_FILES
		bytes, err := os.read_entire_file(parts[0], context.temp_allocator)
		if err != nil {
			fmt.eprintfln("modustool: test failed: no file %s: %v", parts[0], err)
			return false
		}
		hash := blake3.hash(bytes)
		if parts[1] == HASH_TO_COMPUTE {
			fmt.eprintfln("modustool: test failed: %s has no hash in %s yet: `modustool cryptography-system-hashes` prints the lines", parts[0], CRYPTOGRAPHY_SYSTEM_FILES)
			return false
		}
		if hex_text(hash[:]) != parts[1] {
			fmt.eprintfln("modustool: test failed: %s has the hash %s, not %s: a file of the system changed; review it, then write its new hash", parts[0], hex_text(hash[:]), parts[1])
			return false
		}
		if !cryptography_system_file_package_holds(parts[0], string(bytes)) {
			return false
		}
	}
	return true
}

// run_cryptography_system_hashes prints the line of the list of the files of
// the system for each .odin file of src/library/modus/cryptography that the manifest of
// the origin does not name: the coordinator checks the files, then puts the
// lines in src/library/modus/cryptography/system_files.manifest.
run_cryptography_system_hashes :: proc(args: []string) -> int {
	taken := make(map[string]bool, context.temp_allocator)
	lines, ok := foundation.manifest_lines(foundation.CRYPTOGRAPHY_MANIFEST)
	if !ok {
		return foundation.EXIT_FAILURE
	}
	for parts in lines {
		if len(parts) > 0 {
			taken[parts[0]] = true
		}
	}
	files := make([dynamic]string, context.temp_allocator)
	if !odin_files_of_a_folder(foundation.CRYPTOGRAPHY_FOLDER, &files) {
		return foundation.EXIT_FAILURE
	}
	slice.sort(files[:])
	for file in files {
		if file in taken {
			continue
		}
		bytes, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", file, err)
			return foundation.EXIT_FAILURE
		}
		hash := blake3.hash(bytes)
		fmt.printfln("%s %s", file, hex_text(hash[:]))
	}
	return 0
}

// cryptography_origin_check reads the manifest: one file on each line, as
// "<file of the repository> <file under the root of Odin> <BLAKE3 of the
// origin>"; a line that starts with # is a comment. Then it reads the list
// of the files of the system, and walks the folders of src/library/modus/cryptography:
// each .odin file must be in one list. It gives false at the first file that
// does not agree.
cryptography_origin_check :: proc() -> bool {
	listed := make(map[string]string, context.temp_allocator)
	manifest, err := os.read_entire_file(foundation.CRYPTOGRAPHY_MANIFEST, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", foundation.CRYPTOGRAPHY_MANIFEST, err)
		return false
	}
	files := 0
	for line in strings.split_lines(string(manifest), context.temp_allocator) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 3 {
			fmt.eprintfln("modustool: test failed: a line of %s does not have 3 parts: %q", foundation.CRYPTOGRAPHY_MANIFEST, line)
			return false
		}
		// An origin is a file of core:crypto, by a path with no "..": a line
		// cannot take a file of another part of Odin, or of the host.
		if !strings.has_prefix(parts[1], CRYPTOGRAPHY_ORIGIN_PREFIX) || strings.contains(parts[1], "..") || !strings.has_prefix(parts[0], foundation.CRYPTOGRAPHY_FOLDER + "/") || strings.contains(parts[0], "..") {
			fmt.eprintfln("modustool: test failed: a line of %s names %s from %s: an origin starts with %s, a file with %s/, and neither has \"..\"", foundation.CRYPTOGRAPHY_MANIFEST, parts[0], parts[1], CRYPTOGRAPHY_ORIGIN_PREFIX, foundation.CRYPTOGRAPHY_FOLDER)
			return false
		}
		if parts[0] in listed {
			fmt.eprintfln("modustool: test failed: %s is in %s two times", parts[0], foundation.CRYPTOGRAPHY_MANIFEST)
			return false
		}
		listed[parts[0]] = foundation.CRYPTOGRAPHY_MANIFEST
		origin_path := strings.concatenate({ODIN_ROOT, parts[1]}, context.temp_allocator)
		origin, origin_error := os.read_entire_file(origin_path, context.temp_allocator)
		if origin_error != nil {
			fmt.eprintfln("modustool: test failed: no origin %s: %v", origin_path, origin_error)
			return false
		}
		hash := blake3.hash(origin)
		if hex_text(hash[:]) != parts[2] {
			fmt.eprintfln("modustool: test failed: the origin %s has the hash %s, not %s: the compiler of the flake changed", parts[1], hex_text(hash[:]), parts[2])
			return false
		}
		taken, taken_error := os.read_entire_file(parts[0], context.temp_allocator)
		if taken_error != nil {
			fmt.eprintfln("modustool: test failed: no file %s: %v", parts[0], taken_error)
			return false
		}
		wanted, adjusted := cryptography_file_from_origin(string(origin), parts[1])
		if !adjusted {
			return false
		}
		if string(taken) != wanted {
			at := 0
			for at < min(len(taken), len(wanted)) && taken[at] == wanted[at] {
				at += 1
			}
			fmt.eprintfln("modustool: test failed: %s is not its origin %s with the listed changes: the first other byte is at %d", parts[0], parts[1], at)
			return false
		}
		files += 1
	}
	if !cryptography_system_files_check(&listed) {
		return false
	}
	found := make([dynamic]string, context.temp_allocator)
	if !odin_files_of_a_folder(foundation.CRYPTOGRAPHY_FOLDER, &found) {
		return false
	}
	for file in found {
		if file not_in listed {
			fmt.eprintfln("modustool: test failed: %s is in no list: a file of the origin goes in %s, a file of the system in %s", file, foundation.CRYPTOGRAPHY_MANIFEST, CRYPTOGRAPHY_SYSTEM_FILES)
			return false
		}
	}
	for file in listed {
		found_it := false
		for other in found {
			found_it ||= other == file
		}
		if !found_it {
			fmt.eprintfln("modustool: test failed: %s is in a list, and is not in %s", file, foundation.CRYPTOGRAPHY_FOLDER)
			return false
		}
	}
	foundation.test_passed_print("each of the %d .odin files of %s is in a list; %d files of the system have the hash of their list", len(found), foundation.CRYPTOGRAPHY_FOLDER, len(listed) - files)
	foundation.test_passed_print("%d files of " + foundation.CRYPTOGRAPHY_FOLDER + " are their origin in Odin %s (each with the BLAKE3 hash of the manifest) with the package names of the %d packages of the copy, the %d listed import changes, the %d listed adjustments, and nothing else", files, CRYPTOGRAPHY_ORIGIN_RELEASE, len(cryptography_packages), len(cryptography_import_changes), len(cryptography_adjustments))
	return true
}

// run_cryptography_take writes a file of the repository from its origin,
// with the listed changes, and prints the line of the manifest for it:
// `cryptography-take <file under the root of Odin> <file of the repository>`.
run_cryptography_take :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("modustool: cryptography-take <file under the root of Odin> <file of the repository>")
		return foundation.EXIT_USAGE
	}
	origin, err := os.read_entire_file(strings.concatenate({ODIN_ROOT, args[0]}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read the origin %s: %v", args[0], err)
		return foundation.EXIT_FAILURE
	}
	file, adjusted := cryptography_file_from_origin(string(origin), args[0])
	if !adjusted {
		return foundation.EXIT_FAILURE
	}
	if write_error := os.write_entire_file(args[1], transmute([]u8)file); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", args[1], write_error)
		return foundation.EXIT_FAILURE
	}
	hash := blake3.hash(origin)
	fmt.printfln("%s %s %s", args[1], args[0], hex_text(hash[:]))
	return 0
}

run_cryptography_origin :: proc(args: []string) -> int {
	return cryptography_origin_check() ? 0 : foundation.EXIT_FAILURE
}
