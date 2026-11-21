package build

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:cryptography/ed25519"
import "modus:cryptography_primitives"
import "modustool:foundation"

@(private = "file")
sdk_test_temp_dir :: proc(t: ^testing.T, label: string) -> string {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.tprintf("%s/modus_sdk_test_%s_%d", strings.trim_right(temp_base, "/"), label, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "must create test temporary directory")
	return dir
}

@(private = "file")
sdk_test_keypair :: proc(t: ^testing.T, fill_byte: u8) -> (seed: [ed25519.PRIVATE_KEY_SIZE]u8, pub: [ed25519.PUBLIC_KEY_SIZE]u8) {
	for i in 0 ..< len(seed) {
		seed[i] = fill_byte ~ u8(i * 17 + 3)
	}
	secret_text := string(seed[:])
	pub_buf := pub[:]
	err_rec: errors.Error_Record
	count := cryptography_primitives.ed25519_public_key(&secret_text, &pub_buf, &err_rec)
	testing.expect_value(t, count, i64(ed25519.PUBLIC_KEY_SIZE))
	return seed, pub
}

@(private = "file")
sdk_test_synthetic_elf_rel_object :: proc(fn_name: string, code: []u8, import_symbol := "") -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append_bytes :: proc(buf: ^[dynamic]u8, data: []u8) -> u64 {
		off := u64(len(buf))
		append(buf, ..data)
		return off
	}
	align_buf :: proc(buf: ^[dynamic]u8, align: u64) {
		for u64(len(buf)) % align != 0 {
			append(buf, 0)
		}
	}

	strtab := make([dynamic]u8, context.temp_allocator)
	append(&strtab, 0)
	fn_off := u32(len(strtab))
	append(&strtab, ..transmute([]u8)fn_name)
	append(&strtab, 0)

	syms := make([dynamic]Elf_Symbol, context.temp_allocator)
	append(&syms, Elf_Symbol{})
	append(&syms, Elf_Symbol {
		name          = fn_off,
		info          = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION,
		section_index = 1,
		value         = 0,
		size          = u64(len(code)),
	})

	relas := make([dynamic]Elf_Rela, context.temp_allocator)
	if import_symbol != "" {
		imp_off := u32(len(strtab))
		append(&strtab, ..transmute([]u8)import_symbol)
		append(&strtab, 0)
		append(&syms, Elf_Symbol {
			name          = imp_off,
			info          = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_NO_TYPE,
			section_index = ELF_SECTION_INDEX_UNDEFINED,
		})
		// Emit a PLT32 call relocation targeting offset 1 in `code` (e8 00 00 00 00 c3).
		append(&relas, Elf_Rela {
			offset = 1,
			info   = (u64(2) << 32) | ELF_RELOCATION_PLT32,
			addend = -4,
		})
	}

	sym_bytes := make([]u8, len(syms) * size_of(Elf_Symbol), context.temp_allocator)
	for sym, idx in syms {
		s := sym
		mem.copy(raw_data(sym_bytes[idx * size_of(Elf_Symbol):]), &s, size_of(Elf_Symbol))
	}
	rela_bytes := make([]u8, len(relas) * size_of(Elf_Rela), context.temp_allocator)
	for rela, idx in relas {
		r := rela
		mem.copy(raw_data(rela_bytes[idx * size_of(Elf_Rela):]), &r, size_of(Elf_Rela))
	}

	shstr := make([dynamic]u8, context.temp_allocator)
	append(&shstr, 0)
	add_shstr :: proc(buf: ^[dynamic]u8, name: string) -> u32 {
		off := u32(len(buf))
		append(buf, ..transmute([]u8)name)
		append(buf, 0)
		return off
	}
	text_name := add_shstr(&shstr, ".text")
	rela_name := add_shstr(&shstr, ".rela.text")
	symtab_name := add_shstr(&shstr, ".symtab")
	strtab_name := add_shstr(&shstr, ".strtab")
	shstr_name := add_shstr(&shstr, ".shstrtab")

	resize(&out, size_of(Elf_Header))
	headers := make([dynamic]Elf_Section_Header, context.temp_allocator)
	append(&headers, Elf_Section_Header{})

	// 1: .text
	align_buf(&out, 16)
	text_off := append_bytes(&out, code)
	append(&headers, Elf_Section_Header {
		name      = text_name,
		type      = ELF_SECTION_PROGRAM_DATA,
		flags     = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE,
		offset    = text_off,
		size      = u64(len(code)),
		alignment = 16,
	})

	// Optional 2: .rela.text
	symtab_idx := u32(2)
	strtab_idx := u32(3)
	if len(relas) > 0 {
		symtab_idx = 3
		strtab_idx = 4
		align_buf(&out, 8)
		rela_off := append_bytes(&out, rela_bytes)
		append(&headers, Elf_Section_Header {
			name       = rela_name,
			type       = ELF_SECTION_RELA,
			offset     = rela_off,
			size       = u64(len(rela_bytes)),
			link       = symtab_idx,
			info       = 1,
			alignment  = 8,
			entry_size = size_of(Elf_Rela),
		})
	}

	// .symtab
	align_buf(&out, 8)
	sym_off := append_bytes(&out, sym_bytes)
	append(&headers, Elf_Section_Header {
		name       = symtab_name,
		type       = ELF_SECTION_SYMBOLS,
		offset     = sym_off,
		size       = u64(len(sym_bytes)),
		link       = strtab_idx,
		info       = 1,
		alignment  = 8,
		entry_size = size_of(Elf_Symbol),
	})

	// .strtab
	align_buf(&out, 8)
	str_off := append_bytes(&out, strtab[:])
	append(&headers, Elf_Section_Header {
		name      = strtab_name,
		type      = ELF_SECTION_STRING_TABLE,
		offset    = str_off,
		size      = u64(len(strtab)),
		alignment = 1,
	})

	// .shstrtab
	align_buf(&out, 8)
	shstr_index := u16(len(headers))
	shstr_off := append_bytes(&out, shstr[:])
	append(&headers, Elf_Section_Header {
		name      = shstr_name,
		type      = ELF_SECTION_STRING_TABLE,
		offset    = shstr_off,
		size      = u64(len(shstr)),
		alignment = 1,
	})

	align_buf(&out, 8)
	sh_off := u64(len(out))
	for sh in headers {
		s := sh
		append_bytes(&out, ([^]u8)(&s)[:size_of(Elf_Section_Header)])
	}

	header := Elf_Header {
		magic                      = ELF_MAGIC,
		class                      = ELF_CLASS_64,
		data                       = ELF_DATA_LITTLE_ENDIAN,
		identification_version     = 1,
		type                       = ELF_TYPE_RELOCATABLE,
		machine                    = ELF_MACHINE_X86_64,
		version                    = 1,
		section_header_offset      = sh_off,
		header_size                = size_of(Elf_Header),
		program_header_size        = size_of(Elf_Program_Header),
		section_header_size        = size_of(Elf_Section_Header),
		section_header_count       = u16(len(headers)),
		section_name_section_index = shstr_index,
	}
	mem.copy(raw_data(out[:]), &header, size_of(Elf_Header))
	return out[:]
}

@(private = "file")
sdk_test_build_helper_library_module :: proc(t: ^testing.T, dest_path: string) -> blake3.Hash {
	// `lea (%rdi,%rdi,1), %rax; ret`
	code := [?]u8{0x48, 0x8D, 0x04, 0x3F, 0xC3}
	elf := sdk_test_synthetic_elf_rel_object("double_it", code[:])
	manifest, parse_problem := manifest_parse(`
module: helper_lib
about: Synthetic helper library for SDK import testing.
library: yes

export double_it
  about: Double the given integer.
  param value: integer
  result: integer
`)
	testing.expect_value(t, parse_problem, "")
	built, ok := convert_elf_with_manifest(elf, manifest, nil)
	testing.expect(t, ok, "helper_lib synthetic conversion must succeed")
	defer delete(built)
	testing.expect_value(t, module.validate(built), module.Error.None)
	testing.expect(t, os.write_entire_file(dest_path, built) == nil, "must write helper_lib.module")
	return blake3.hash(built)
}

// Packs two signed SDKs deterministically, verifies signatures via
// modus:cryptography_primitives, confirms exact byte determinism, and checks
// zero internal/ or modulus/ files exist in the packed tree.
@(test)
sdk_pack_and_verify_signed_round_trip :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "roundtrip")
	defer _ = os.remove_all(root)

	helper_path := foundation.join(root, "/helper_lib.module")
	helper_hash := sdk_test_build_helper_library_module(t, helper_path)

	seed, pub := sdk_test_keypair(t, 0x42)
	sdk_a := foundation.join(root, "/sdk_a")
	sdk_b := foundation.join(root, "/sdk_b")
	opts := Sdk_Build_Options {
		source_root      = ".",
		extra_modules    = {helper_path},
		compiler_version = "dev-test-sdk-1",
		signing_key_seed = seed,
		has_signing_key  = true,
	}

	manifest_a, prob_a := sdk_build(sdk_a, opts)
	testing.expect_value(t, prob_a, "")
	testing.expect(t, manifest_a.has_signature, "signed SDK must carry Ed25519 signature")
	testing.expect_value(t, manifest_a.public_key, pub)
	testing.expect(t, len(manifest_a.files) > 20, "packed SDK must include public library, runtime, modules, and examples")

	manifest_b, prob_b := sdk_build(sdk_b, opts)
	testing.expect_value(t, prob_b, "")
	testing.expect_value(t, manifest_a.root_digest, manifest_b.root_digest)
	testing.expect_value(t, manifest_a.signature, manifest_b.signature)

	raw_a, err_a := os.read_entire_file(foundation.join(sdk_a, "/", SDK_MANIFEST_FILE_NAME), context.temp_allocator)
	raw_b, err_b := os.read_entire_file(foundation.join(sdk_b, "/", SDK_MANIFEST_FILE_NAME), context.temp_allocator)
	testing.expect(t, err_a == nil && err_b == nil)
	testing.expect_value(t, string(raw_a), string(raw_b))

	// Verify with explicit pinned public key AND without explicit public key.
	_, verify_pinned := sdk_verify(sdk_a, {expected_public_key = pub, require_signature = true})
	testing.expect_value(t, verify_pinned, "")
	_, verify_embedded := sdk_verify(sdk_a)
	testing.expect_value(t, verify_embedded, "")

	// Confirm expected public layout and ZERO internal/ or modulus/ paths anywhere.
	saw_system := false
	saw_runtime := false
	saw_catalog := false
	saw_helper := false
	saw_hello_odin := false
	saw_hello_c := false
	for entry in manifest_a.files {
		testing.expectf(t, !sdk_path_is_forbidden(entry.path), "forbidden path leaked into SDK: %s", entry.path)
		testing.expectf(t, !strings.contains(entry.path, "/internal/") && !strings.has_prefix(entry.path, "internal/"), "internal path leaked: %s", entry.path)
		testing.expectf(t, !strings.contains(entry.path, "/modulus/") && !strings.has_prefix(entry.path, "modulus/"), "modulus path leaked: %s", entry.path)
		if strings.has_prefix(entry.path, "library/modus/system/") {
			saw_system = true
		}
		if entry.path == "runtime/memory.asm" {
			saw_runtime = true
		}
		if entry.path == SDK_MODULE_CATALOG_RELATIVE_PATH {
			saw_catalog = true
		}
		if entry.path == "modules/helper_lib.module" {
			saw_helper = true
			testing.expect_value(t, entry.hash, helper_hash)
		}
		if entry.path == "examples/hello_odin/main.odin" {
			saw_hello_odin = true
		}
		if entry.path == "examples/hello_c/module.manifest" {
			saw_hello_c = true
		}
	}
	testing.expect(t, saw_system, "SDK must include library/modus/system/")
	testing.expect(t, saw_runtime, "SDK must include runtime/memory.asm")
	testing.expect(t, saw_catalog, "SDK must include modules/catalog.txt")
	testing.expect(t, saw_helper, "SDK must include exported helper_lib.module")
	testing.expect(t, saw_hello_odin, "SDK must include examples/hello_odin/main.odin")
	testing.expect(t, saw_hello_c, "SDK must include examples/hello_c/module.manifest")
}

// Tampering with 1 byte of any packed SDK file must be refused with the exact
// relative file path reported in the error message.
@(test)
sdk_verify_refuses_tampered_file :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "tamper_file")
	defer _ = os.remove_all(root)

	seed, pub := sdk_test_keypair(t, 0x11)
	sdk_dir := foundation.join(root, "/sdk")
	_, build_prob := sdk_build(sdk_dir, {source_root = ".", compiler_version = "dev-test", signing_key_seed = seed, has_signing_key = true})
	testing.expect_value(t, build_prob, "")

	targets := [?]string {
		"library/modus/contract/release/release.odin",
		"examples/hello_c/hello_c.c",
	}
	for rel_path in targets {
		full := foundation.join(sdk_dir, "/", rel_path)
		original, read_err := os.read_entire_file(full, context.temp_allocator)
		testing.expect(t, read_err == nil && len(original) > 0)

		tampered := make([]u8, len(original), context.temp_allocator)
		copy(tampered, original)
		tampered[len(tampered) / 2] ~= 0x01
		testing.expect(t, os.write_entire_file(full, tampered) == nil)

		_, problem := sdk_verify(sdk_dir, {expected_public_key = pub, require_signature = true})
		testing.expectf(t, problem != "", "tampering 1 byte of %s must fail verification", rel_path)
		testing.expectf(t, strings.contains(problem, rel_path), "refusal %q must name exact tampered path %q", problem, rel_path)

		// Restore original bytes and confirm verification recovers.
		testing.expect(t, os.write_entire_file(full, original) == nil)
		_, clean_problem := sdk_verify(sdk_dir, {expected_public_key = pub, require_signature = true})
		testing.expect_value(t, clean_problem, "")
	}
}

// Adding an unlisted stray file, deleting a listed file, creating an empty
// forbidden internal/ or modulus/ directory, or planting a symbolic link must
// all be refused by sdk_verify.
@(test)
sdk_verify_refuses_stray_missing_forbidden_and_symlink :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "stray_missing")
	defer _ = os.remove_all(root)

	sdk_dir := foundation.join(root, "/sdk")
	_, build_prob := sdk_build(sdk_dir, {source_root = ".", compiler_version = "dev-test"})
	testing.expect_value(t, build_prob, "")

	// 1. Unlisted stray file at root.
	stray_root := foundation.join(sdk_dir, "/stray_payload.txt")
	testing.expect(t, os.write_entire_file(stray_root, "unexpected") == nil)
	_, prob := sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "stray_payload.txt"), "stray file must be refused with exact path, got %q", prob)
	_ = os.remove(stray_root)

	// 2. Unlisted stray Odin file inside library/modus/.
	stray_lib := foundation.join(sdk_dir, "/library/modus/injected_backdoor.odin")
	testing.expect(t, os.write_entire_file(stray_lib, "package injected\n") == nil)
	_, prob = sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "library/modus/injected_backdoor.odin"), "stray library file must be refused with exact path, got %q", prob)
	_ = os.remove(stray_lib)

	// 3. Missing listed file.
	missing_target := foundation.join(sdk_dir, "/examples/hello_c/hello_c.c")
	saved, read_err := os.read_entire_file(missing_target, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect(t, os.remove(missing_target) == nil)
	_, prob = sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "examples/hello_c/hello_c.c"), "missing file must be refused with exact path, got %q", prob)
	testing.expect(t, os.write_entire_file(missing_target, saved) == nil)

	// 4. Empty forbidden directory `library/internal` and `modulus`.
	forbidden_internal := foundation.join(sdk_dir, "/library/internal")
	testing.expect(t, os.make_directory_all(forbidden_internal) == nil)
	_, prob = sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "internal"), "forbidden internal directory must be refused, got %q", prob)
	_ = os.remove_all(forbidden_internal)

	forbidden_modulus := foundation.join(sdk_dir, "/modulus")
	testing.expect(t, os.make_directory_all(forbidden_modulus) == nil)
	_, prob = sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "modulus"), "forbidden modulus directory must be refused, got %q", prob)
	_ = os.remove_all(forbidden_modulus)

	// 5. Symbolic link inside SDK directory.
	link_path := foundation.join(sdk_dir, "/escape_link")
	testing.expect(t, os.symlink("/etc/passwd", link_path) == nil)
	_, prob = sdk_verify(sdk_dir)
	testing.expectf(t, strings.contains(prob, "symbolic link"), "symlink inside SDK must be refused, got %q", prob)
	_ = os.remove(link_path)

	// Clean again after cleanup.
	_, clean := sdk_verify(sdk_dir)
	testing.expect_value(t, clean, "")
}

// Flipping 1 bit of the Ed25519 signature, pinning a different public key,
// presenting an unsigned SDK when a signature is required, or mutating header
// metadata must all be refused.
@(test)
sdk_verify_refuses_tampered_signature_wrong_key_and_unsigned :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "sig_tamper")
	defer _ = os.remove_all(root)

	seed_a, pub_a := sdk_test_keypair(t, 0x7A)
	_, pub_b := sdk_test_keypair(t, 0x9C)

	sdk_dir := foundation.join(root, "/sdk_signed")
	_, build_prob := sdk_build(sdk_dir, {source_root = ".", compiler_version = "dev-test", signing_key_seed = seed_a, has_signing_key = true})
	testing.expect_value(t, build_prob, "")

	// Wrong public key must be refused.
	_, wrong_key_prob := sdk_verify(sdk_dir, {expected_public_key = pub_b, require_signature = true})
	testing.expect(t, wrong_key_prob != "", "wrong public key must be refused")

	// Flip 1 bit of the Ed25519 signature inside SDK_MANIFEST.txt.
	manifest_path := foundation.join(sdk_dir, "/", SDK_MANIFEST_FILE_NAME)
	orig_bytes, err := os.read_entire_file(manifest_path, context.temp_allocator)
	testing.expect(t, err == nil)
	orig_text := string(orig_bytes)
	sig_marker := "signature: "
	sig_at := strings.index(orig_text, sig_marker)
	testing.expect(t, sig_at >= 0)
	flip_pos := sig_at + len(sig_marker) + 10
	tampered := make([]u8, len(orig_bytes), context.temp_allocator)
	copy(tampered, orig_bytes)
	// Flip the least-significant bit of one lowercase hex nibble.
	tampered[flip_pos] = tampered[flip_pos] == '0' ? '1' : '0'
	testing.expect(t, os.write_entire_file(manifest_path, tampered) == nil)

	_, prob_pinned := sdk_verify(sdk_dir, {expected_public_key = pub_a, require_signature = true})
	testing.expect(t, prob_pinned != "", "1-bit flipped signature must fail pinned verification")
	_, prob_embedded := sdk_verify(sdk_dir)
	testing.expect(t, prob_embedded != "", "1-bit flipped signature must fail embedded verification too")

	// Tampering with release header line without updating root_digest must fail.
	mutated_header, _ := strings.replace(orig_text, "compiler: dev-test", "compiler: dev-evil", 1, context.temp_allocator)
	testing.expect(t, os.write_entire_file(manifest_path, mutated_header) == nil)
	_, prob_header := sdk_verify(sdk_dir, {expected_public_key = pub_a, require_signature = true})
	testing.expect(t, prob_header != "", "tampered header must fail root_digest verification")

	// Restore manifest and verify again.
	testing.expect(t, os.write_entire_file(manifest_path, orig_bytes) == nil)
	_, ok_again := sdk_verify(sdk_dir, {expected_public_key = pub_a, require_signature = true})
	testing.expect_value(t, ok_again, "")

	// Unsigned SDK must be refused when require_signature is true.
	sdk_unsigned := foundation.join(root, "/sdk_unsigned")
	_, unsigned_build := sdk_build(sdk_unsigned, {source_root = ".", compiler_version = "dev-test"})
	testing.expect_value(t, unsigned_build, "")
	_, prob_unsigned := sdk_verify(sdk_unsigned, {expected_public_key = pub_a, require_signature = true})
	testing.expect(t, prob_unsigned != "", "unsigned SDK must be refused when signature is required")
}

// Exhaustive edge-case tests for sdk_path_is_forbidden, sdk_key_decode, and
// sdk_manifest_parse: boundaries 0, 1, wrong format versions, missing/duplicate
// headers, ordering violations, path traversals, and forbidden namespaces.
@(test)
sdk_manifest_parser_and_path_adversarial_edges :: proc(t: ^testing.T) {
	forbidden_paths := [?]string {
		"",
		"/",
		"/etc/passwd",
		"library/modus/",
		"library//modus/a.odin",
		".",
		"..",
		"../escape",
		"library/../escape",
		"library/./a.odin",
		"library\\modus\\a.odin",
		"library/modus/bad\x01name",
		"internal",
		"internal/storage/storage_tree.odin",
		"library/internal/storage/storage_tree.odin",
		"src/library/internal/a.odin",
		"modulus",
		"modulus/iommu/iommu.odin",
		"src/modulus/main.odin",
		"examples/modulus/x.odin",
		"examples/internal/x.odin",
	}
	for path in forbidden_paths {
		testing.expectf(t, sdk_path_is_forbidden(path), "path %q must be forbidden", path)
	}
	allowed_paths := [?]string {
		"LICENSE",
		"library/modus/system/system.odin",
		"runtime/memory.asm",
		"modules/catalog.txt",
		"examples/hello_c/module.manifest",
	}
	for path in allowed_paths {
		testing.expectf(t, !sdk_path_is_forbidden(path), "path %q must be allowed", path)
	}

	// Key decoding boundaries: hex and base64url.
	seed, _ := sdk_test_keypair(t, 0x55)
	hex_key := sdk_lowercase_hex_encode(seed[:])
	dec_hex, ok_hex := sdk_key_decode(hex_key)
	testing.expect(t, ok_hex && dec_hex == seed)
	b64_key := base64url_text(seed[:])
	dec_b64, ok_b64 := sdk_key_decode(b64_key)
	testing.expect(t, ok_b64 && dec_b64 == seed)

	bad_keys := [?]string {
		"",
		"   ",
		hex_key[:63],
		foundation.join(hex_key, "0"),
		strings.concatenate({"z", hex_key[1:]}, context.temp_allocator),
		foundation.join(b64_key, "="),
		"short",
	}
	for bad in bad_keys {
		_, ok := sdk_key_decode(bad)
		testing.expectf(t, !ok, "invalid key %q must be refused", bad)
	}

	// Build a valid minimal manifest to mutate systematically.
	sample_hash := blake3.hash(transmute([]u8)string("sample"))
	valid_manifest := Sdk_Manifest {
		sdk_format       = SDK_FORMAT_VERSION,
		release_version  = "0.96.0",
		target_triple    = SDK_TARGET_TRIPLE,
		module_format    = module.VERSION,
		compiler_version = "dev-test",
		files            = {{path = "library/modus/a.odin", hash = sample_hash}},
	}
	valid_manifest.root_digest = sdk_root_digest_compute(valid_manifest)
	valid_text := sdk_manifest_format(valid_manifest)
	_, ok_prob := sdk_manifest_parse(valid_text)
	testing.expect_value(t, ok_prob, "")

	zero_hex := strings.repeat("0", 64, context.temp_allocator)
	bad_manifests := [?]string {
		"",
		strings.trim_suffix(valid_text, "\n"),
		strings.concatenate({"sdk_format: 0\n", valid_text[len("sdk_format: 1\n"):]}, context.temp_allocator),
		strings.concatenate({"sdk_format: 2\n", valid_text[len("sdk_format: 1\n"):]}, context.temp_allocator),
		strings.concatenate({"sdk_format: -1\n", valid_text[len("sdk_format: 1\n"):]}, context.temp_allocator),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: 0\ncompiler: dev\nroot_digest: %s\n\n%s  a.odin\n", SDK_TARGET_TRIPLE, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nunknown_key: x\nroot_digest: %s\n\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\npublic_key: %s\n\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  b.odin\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  a.odin\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  SDK_MANIFEST.txt\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  library/internal/x.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  ../outside.odin\n", SDK_TARGET_TRIPLE, module.VERSION, zero_hex, zero_hex),
		fmt.tprintf("sdk_format: 1\nrelease: 0.96.0\ntarget: %s\nmodule_format: %d\ncompiler: dev\nroot_digest: %s\n\n%s  a.odin\n", SDK_TARGET_TRIPLE, module.VERSION, strings.repeat("A", 64, context.temp_allocator), zero_hex),
	}
	for bad, idx in bad_manifests {
		_, prob := sdk_manifest_parse(bad)
		testing.expectf(t, prob != "", "bad manifest case %d must be refused", idx)
	}
}

// End-to-end Odin outside module build purely against an unpacked SDK:
// 1. examples/hello_odin builds into a module accepted by module.validate;
// 2. An outside Odin module importing `internal:storage/storage_tree` MUST FAIL;
// 3. An outside Odin module importing `modulus:iommu` MUST FAIL;
// 4. Building against a tampered SDK MUST FAIL before invoking the compiler.
@(test)
sdk_outside_odin_module_build_and_internal_refusal :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "odin_outside")
	defer _ = os.remove_all(root)

	seed, pub := sdk_test_keypair(t, 0x33)
	sdk_dir := foundation.join(root, "/sdk")
	_, build_prob := sdk_build(sdk_dir, {source_root = ".", compiler_version = "dev-test", signing_key_seed = seed, has_signing_key = true})
	testing.expect_value(t, build_prob, "")

	// 1. Build the bundled hello_odin example purely against the signed SDK.
	hello_out := foundation.join(root, "/out/hello_odin.modus")
	hello_prob := sdk_build_outside_module(
		sdk_dir,
		foundation.join(sdk_dir, "/examples/hello_odin"),
		hello_out,
		{verify_options = {expected_public_key = pub, require_signature = true}},
	)
	testing.expect_value(t, hello_prob, "")

	hello_bytes, read_err := os.read_entire_file(hello_out, context.temp_allocator)
	testing.expect(t, read_err == nil && len(hello_bytes) > 0)
	testing.expect_value(t, module.validate(hello_bytes), module.Error.None)

	saw_add_values := false
	saw_entry := false
	for export_idx in 1 ..< module.count(hello_bytes, .Exports) {
		exp_name := module_export_name(hello_bytes, export_idx)
		if exp_name == "add_values" {
			saw_add_values = true
		}
		if exp_name == "entry" {
			saw_entry = true
		}
	}
	testing.expect(t, saw_add_values, "hello_odin must export add_values")
	testing.expect(t, saw_entry, "hello_odin must export entry")

	// 2. An outside Odin module importing `internal:storage/storage_tree` MUST FAIL.
	bad_internal_dir := foundation.join(root, "/bad_internal")
	testing.expect(t, os.make_directory_all(bad_internal_dir) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(bad_internal_dir, "/module.txt"), "name: bad_internal\n") == nil)
	testing.expect(t, os.write_entire_file(foundation.join(bad_internal_dir, "/main.odin"), `// Attempts to import private internal library.
package bad_internal

import "internal:storage/storage_tree"

@(export, link_name = "probe")
probe :: proc "c" () -> i64 {
	_ = storage_tree.PAGE_SIZE
	return 1
}
`) == nil)
	internal_prob := sdk_build_outside_module(sdk_dir, bad_internal_dir, foundation.join(root, "/out/bad_internal.modus"))
	testing.expect(t, internal_prob != "", "outside module importing internal:storage/storage_tree must fail against SDK")

	// 3. An outside Odin module importing `modulus:iommu` MUST FAIL.
	bad_modulus_dir := foundation.join(root, "/bad_modulus")
	testing.expect(t, os.make_directory_all(bad_modulus_dir) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(bad_modulus_dir, "/module.txt"), "name: bad_modulus\n") == nil)
	testing.expect(t, os.write_entire_file(foundation.join(bad_modulus_dir, "/main.odin"), `// Attempts to import private kernel library.
package bad_modulus

import "modulus:iommu"

@(export, link_name = "probe")
probe :: proc "c" () -> i64 {
	_ = size_of(iommu.Unit)
	return 1
}
`) == nil)
	modulus_prob := sdk_build_outside_module(sdk_dir, bad_modulus_dir, foundation.join(root, "/out/bad_modulus.modus"))
	testing.expect(t, modulus_prob != "", "outside module importing modulus:iommu must fail against SDK")

	// 4. Tampering with the SDK must block sdk_build_outside_module.
	testing.expect(t, os.write_entire_file(foundation.join(sdk_dir, "/stray.txt"), "x") == nil)
	tampered_prob := sdk_build_outside_module(sdk_dir, foundation.join(sdk_dir, "/examples/hello_odin"), foundation.join(root, "/out/should_not_build.modus"))
	testing.expect(t, tampered_prob != "", "tampered SDK must refuse outside module build")
}

// Language-neutral sdk-convert and freestanding C outside-module build tests:
// 1. Converts a synthetic ET_REL .o + module.manifest (with an import resolved
//    from <sdk>/modules/) into a .modus module validated by module.validate;
// 2. Builds bundled <sdk>/examples/hello_c via clang + convert_elf_with_manifest;
// 3. Refuses missing/malformed inputs and missing import modules.
@(test)
sdk_convert_and_outside_c_module_build :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "c_convert")
	defer _ = os.remove_all(root)

	helper_path := foundation.join(root, "/helper_lib.module")
	helper_hash := sdk_test_build_helper_library_module(t, helper_path)

	sdk_dir := foundation.join(root, "/sdk")
	_, build_prob := sdk_build(sdk_dir, {source_root = ".", extra_modules = {helper_path}, compiler_version = "dev-test"})
	testing.expect_value(t, build_prob, "")

	// 1. Synthetic ET_REL object calling imported `double_it` via PLT32.
	// Machine code: call rel32 (e8 00 00 00 00); ret (c3)
	caller_code := [?]u8{0xE8, 0x00, 0x00, 0x00, 0x00, 0xC3}
	caller_elf := sdk_test_synthetic_elf_rel_object("call_double", caller_code[:], "double_it")
	caller_obj_path := foundation.join(root, "/caller.o")
	caller_manifest_path := foundation.join(root, "/caller.manifest")
	caller_out_path := foundation.join(root, "/out/caller.modus")
	testing.expect(t, os.write_entire_file(caller_obj_path, caller_elf) == nil)
	testing.expect(t, os.write_entire_file(caller_manifest_path, `
module: sdk_caller
about: Synthetic ET_REL consumer calling helper_lib through SDK modules.
imports: helper_lib

export call_double
  about: Call imported double_it.
  param value: integer
  result: integer
`) == nil)

	sdk_modules_dir := foundation.join(sdk_dir, "/", SDK_MODULES_SUBDIRECTORY)
	conv_prob := sdk_convert_object_to_module(caller_obj_path, caller_manifest_path, caller_out_path, {sdk_modules_dir})
	testing.expect_value(t, conv_prob, "")

	converted_bytes, read_err := os.read_entire_file(caller_out_path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(converted_bytes) > 0)
	testing.expect_value(t, module.validate(converted_bytes), module.Error.None)
	testing.expect_value(t, module.count(converted_bytes, .Imports), u32(2))
	imp_rec, imp_ok := module.record(converted_bytes, .Imports, 1, module.Import)
	testing.expect(t, imp_ok)
	testing.expect_value(t, imp_rec.hash, helper_hash)

	// 2. Refusal cases for sdk_convert_object_to_module.
	testing.expect(t, sdk_convert_object_to_module(foundation.join(root, "/missing.o"), caller_manifest_path, caller_out_path, {sdk_modules_dir}) != "")
	testing.expect(t, sdk_convert_object_to_module(caller_obj_path, foundation.join(root, "/missing.manifest"), caller_out_path, {sdk_modules_dir}) != "")
	// Missing import directory -> cannot resolve helper_lib.
	testing.expect(t, sdk_convert_object_to_module(caller_obj_path, caller_manifest_path, foundation.join(root, "/out/no_imp.modus"), nil) != "")
	// Non-ELF payload refused.
	bad_obj := foundation.join(root, "/not_elf.o")
	testing.expect(t, os.write_entire_file(bad_obj, "NOT AN ELF OBJECT") == nil)
	testing.expect(t, sdk_convert_object_to_module(bad_obj, caller_manifest_path, foundation.join(root, "/out/bad.modus"), {sdk_modules_dir}) != "")

	// 3. Freestanding C end-to-end build of bundled examples/hello_c via clang.
	probe_state, _, _, probe_err := os.process_exec({command = {"clang", "--version"}}, context.temp_allocator)
	if probe_err == nil && probe_state.exited && probe_state.success {
		hello_c_out := foundation.join(root, "/out/hello_c.modus")
		c_prob := sdk_build_outside_module(sdk_dir, foundation.join(sdk_dir, "/examples/hello_c"), hello_c_out)
		testing.expect_value(t, c_prob, "")
		c_bytes, c_err := os.read_entire_file(hello_c_out, context.temp_allocator)
		testing.expect(t, c_err == nil && len(c_bytes) > 0)
		testing.expect_value(t, module.validate(c_bytes), module.Error.None)
		testing.expect_value(t, module.count(c_bytes, .Exports), u32(2))
		testing.expect_value(t, module_export_name(c_bytes, 1), "add_numbers")
		_, has_own_hash := module.own_hash_place(c_bytes)
		testing.expect(t, has_own_hash, "hello_c must declare modus_own_hash own-hash place")
	}
}

// End-to-end CLI tests for run_sdk_pack, run_sdk_verify, and run_sdk_convert,
// including usage refusals, signed pack + pinned verify, tampered refusal, and
// language-neutral conversion with --sdk import resolution.
@(test)
sdk_cli_commands_end_to_end :: proc(t: ^testing.T) {
	root := sdk_test_temp_dir(t, "cli_e2e")
	defer _ = os.remove_all(root)

	// Usage errors must return EXIT_USAGE.
	testing.expect_value(t, run_sdk_pack(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_sdk_pack({"--sign-key"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_sdk_verify(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_sdk_verify({"--public-key"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_sdk_convert(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_sdk_convert({"only_one_arg"}), foundation.EXIT_USAGE)

	// Write Ed25519 signing seed and public key files.
	seed, pub := sdk_test_keypair(t, 0x2B)
	seed_path := foundation.join(root, "/sdk_seed.key")
	pub_path := foundation.join(root, "/sdk_pub.key")
	testing.expect(t, os.write_entire_file(seed_path, foundation.join(sdk_lowercase_hex_encode(seed[:]), "\n")) == nil)
	testing.expect(t, os.write_entire_file(pub_path, foundation.join(base64url_text(pub[:]), "\n")) == nil)

	// Pack signed SDK via CLI.
	sdk_dir := foundation.join(root, "/packed_sdk")
	testing.expect_value(t, run_sdk_pack({sdk_dir, "--sign-key", seed_path}), 0)

	// Verify signed SDK via CLI (both with pinned public key and without).
	testing.expect_value(t, run_sdk_verify({sdk_dir, "--public-key", pub_path}), 0)
	testing.expect_value(t, run_sdk_verify({sdk_dir}), 0)

	// Convert synthetic ET_REL object + manifest via CLI.
	code := [?]u8{0x48, 0x8D, 0x04, 0x3F, 0xC3}
	obj_path := foundation.join(root, "/cli_lib.o")
	man_path := foundation.join(root, "/cli_lib.manifest")
	out_path := foundation.join(root, "/cli_lib.modus")
	testing.expect(t, os.write_entire_file(obj_path, sdk_test_synthetic_elf_rel_object("double_it", code[:])) == nil)
	testing.expect(t, os.write_entire_file(man_path, `
module: cli_lib
about: Synthetic library converted via sdk-convert CLI.
library: yes

export double_it
  about: Double the input integer.
  param x: integer
  result: integer
`) == nil)
	testing.expect_value(t, run_sdk_convert({obj_path, man_path, out_path, "--sdk", sdk_dir}), 0)

	out_bytes, read_err := os.read_entire_file(out_path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(out_bytes) > 0)
	testing.expect_value(t, module.validate(out_bytes), module.Error.None)

	// Tampering with SDK causes sdk-verify and sdk-convert --sdk to return EXIT_FAILURE.
	testing.expect(t, os.write_entire_file(foundation.join(sdk_dir, "/stray_cli.txt"), "tamper") == nil)
	testing.expect_value(t, run_sdk_verify({sdk_dir, "--public-key", pub_path}), foundation.EXIT_FAILURE)
	testing.expect_value(t, run_sdk_convert({obj_path, man_path, out_path, "--sdk", sdk_dir}), foundation.EXIT_FAILURE)
}
