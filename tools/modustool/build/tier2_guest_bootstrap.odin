// Tier 2 seed-to-Odin guest bootstrap primitives, multi-stage guest_builder
// orchestration, and chibicc multi-unit c_builder recipe constructors
// (src/md/features/bootstrap.md).
//
// Provides:
//   1. An auditable 262-byte x86-64 Linux static ELF `hex0` bootstrap seed
//      alongside its annotated `hex0_x86_64.hex0` source: when executed on
//      Linux x86-64 (host or inside `guest_builder`), `hex0` assembles
//      `hex0_x86_64.hex0` byte-for-byte into itself (`blake3(seed) == blake3(stage1)`).
//   2. A second auditable hex0-authored x86-64 Linux ELF tool (`catm_x86_64.hex0`,
//      a 191-byte streaming concatenator corresponding to stage0-posix's `catm`),
//      assembled by Stage 1 `hex0` to demonstrate chained Tier 2 execution.
//   3. Real `guest_builder` multi-stage recipe builders (`tier2_guest_bootstrap_make`)
//      producing validated `plans_recipes.Recipe_Spec`, `guest_builder.Guest_Build_Spec`,
//      content-addressed private-store objects, and deterministic expected
//      `MODTREE1` output hashes for the executable `hex0` -> `catm` stages,
//      paired with an honest readiness table for downstream upstream stages
//      (`M2-Planet` -> `mes` -> `tcc` -> `gcc` -> `LLVM 18` -> `Odin` fork).
//   4. Real `c_builder` multi-unit recipe encoding (`bootstrap_chibicc_c_builder_recipe_make`)
//      turning the 14 chibicc C sources, `self_host/jump.s`, headers, and
//      `compile_record_at` export into canonical `plans_recipes.Recipe_Spec`
//      records executed by `recipes` through `c_builder`.
package build

import "core:strings"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import gb "modus:contract/guest_builder"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// Format property: exact byte length of the auditable x86-64 Linux ELF hex0 seed
// (64-byte ELF64 header + 56-byte PT_LOAD header + 142 bytes of machine code).
TIER2_HEX0_SEED_BYTES :: 262

// Format property: exact byte length of the hex0-assembled x86-64 Linux ELF catm
// streaming utility (64-byte ELF64 header + 56-byte PT_LOAD header + 71 bytes code).
TIER2_CATM_ELF_BYTES :: 191

// Plan value: frozen epoch timestamp 0 for deterministic Tier 2 guest stages.
TIER2_FROZEN_EPOCH :: u64(0)

// Plan value: 128 MiB guest RAM and 1 MiB output disk bound for stage0 hex0/catm.
TIER2_STAGE0_MEMORY_PAGES :: u64(32_768)
TIER2_STAGE0_OUTPUT_BYTES :: u64(1024 * 1024)
TIER2_STAGE0_EXITS_MOST :: u64(200_000_000)

// Exact guest commands executed by linux_build_init for Stage 1 and Stage 2.
TIER2_STAGE1_HEX0_COMMAND :: "cp hex0 /tmp/hex0 && chmod 755 /tmp/hex0 && /tmp/hex0 < hex0_x86_64.hex0 > /outputs/hex0"
TIER2_STAGE2_CATM_COMMAND :: "cp hex0_stage1/hex0 /tmp/hex0 && chmod 755 /tmp/hex0 && /tmp/hex0 < catm_x86_64.hex0 > /outputs/catm"

// Pinned upstream commits from flake.nix for the final Tier 2 targets.
TIER2_PINNED_LLVM18_DSE_COMMIT :: "c833746c6c062677a040d18d837c7fad71939171"
TIER2_PINNED_ODIN_FORK_COMMIT :: "746fb85303f7740eb4116af35a994712043fc0e1"

// Closed set describing whether a Tier 2 bootstrap stage currently executes
// end-to-end inside guest_builder or awaits pinned upstream source archives.
Tier2_Stage_Readiness :: enum u8 {
	None                          = 0,
	Executable_In_Guest           = 1,
	Gated_Upstream_Archive_Pin    = 2,
	Gated_Multi_Hour_Guest_Budget = 3,
}

// Honest status descriptor for each stage in the Tier 2 seed-to-Odin chain.
Tier2_Stage_Status :: struct {
	name:           string,
	upstream_stage: string,
	readiness:      Tier2_Stage_Readiness,
	pinned_ref:     string,
	command:        string,
}

// Packaged store objects and cryptographic hashes for one executable Tier 2
// guest_builder stage.
Tier2_Guest_Stage_Bundle :: struct {
	name:            string,
	recipe_hash:     blake3.Hash,
	expected_output: blake3.Hash,
	expected_binary: []u8,
	expected_hash:   blake3.Hash,
}

// Complete multi-stage Tier 2 guest_builder bundle ready for private-store packing.
Tier2_Guest_Bootstrap_Bundle :: struct {
	objects:       [dynamic]Module_File,
	hex0_seed:     []u8,
	hex0_hash:     blake3.Hash,
	stage1_hex0:   Tier2_Guest_Stage_Bundle,
	stage2_catm:   Tier2_Guest_Stage_Bundle,
}

// Annotated hex0 source for the 262-byte x86-64 Linux static ELF `hex0` seed.
// Reads hex0 source from stdin (fd 0), skips `#`/`;` line comments and non-hex
// whitespace, packs each pair of hex digits into one byte on stdout (fd 1),
// and exits with code 0 on EOF. Assembling this text with `hex0` reproduces
// the exact 262-byte seed binary.
TIER2_HEX0_X86_64_SOURCE :: `# Auditable x86-64 Linux static ELF hex0 bootstrap seed (262 bytes)
# Base load address: 0x00400000; entry point: 0x00400078

# ---- ELF64 Header (64 bytes, 0x00..0x3F) ----
7F 45 4C 46             # e_ident[0..3]: ELF magic
02 01 01 00             # ELFCLASS64, ELFDATA2LSB, EV_CURRENT, ELFOSABI_NONE
00 00 00 00 00 00 00 00 # e_ident padding
02 00                   # e_type: ET_EXEC
3E 00                   # e_machine: EM_X86_64
01 00 00 00             # e_version: 1
78 00 40 00 00 00 00 00 # e_entry: 0x00400078
40 00 00 00 00 00 00 00 # e_phoff: 64
00 00 00 00 00 00 00 00 # e_shoff: 0
00 00 00 00             # e_flags: 0
40 00                   # e_ehsize: 64
38 00                   # e_phentsize: 56
01 00                   # e_phnum: 1
00 00 00 00 00 00       # e_shentsize, e_shnum, e_shstrndx

# ---- ELF64 Program Header (56 bytes, 0x40..0x77) ----
01 00 00 00             # p_type: PT_LOAD
05 00 00 00             # p_flags: PF_R | PF_X
00 00 00 00 00 00 00 00 # p_offset: 0
00 00 40 00 00 00 00 00 # p_vaddr: 0x00400000
00 00 40 00 00 00 00 00 # p_paddr: 0x00400000
06 01 00 00 00 00 00 00 # p_filesz: 262 (0x106)
06 01 00 00 00 00 00 00 # p_memsz: 262 (0x106)
00 10 00 00 00 00 00 00 # p_align: 0x1000

# ---- Machine Code (142 bytes, 0x78..0x105) ----
48 83 EC 10             # +00: sub $16, %rsp
45 31 E4                # +04: xor %r12d, %r12d       ; toggle = 0
45 31 ED                # +07: xor %r13d, %r13d       ; accum = 0

# loop (+0A): read 1 byte from stdin
31 C0                   # +0A: xor %eax, %eax         ; SYS_read = 0
31 FF                   # +0C: xor %edi, %edi         ; fd = 0
48 89 E6                # +0E: mov %rsp, %rsi         ; buf = rsp
BA 01 00 00 00          # +11: mov $1, %edx           ; count = 1
0F 05                   # +16: syscall
48 85 C0                # +18: test %rax, %rax
7E 68                   # +1B: jle done (+85)
0F B6 04 24             # +1D: movzbl (%rsp), %eax
3C 23                   # +21: cmp $0x23, %al         ; '#'
74 45                   # +23: je comment (+6A)
3C 3B                   # +25: cmp $0x3B, %al         ; ';'
74 41                   # +27: je comment (+6A)
2C 30                   # +29: sub $0x30, %al         ; '0'..'9'
3C 0A                   # +2B: cmp $10, %al
72 0E                   # +2D: jb got_nibble (+3D)
2C 11                   # +2F: sub $0x11, %al         ; 'A'..'F'
3C 06                   # +31: cmp $6, %al
72 06                   # +33: jb got_alpha (+3B)
2C 20                   # +35: sub $0x20, %al         ; 'a'..'f'
3C 06                   # +37: cmp $6, %al
73 CF                   # +39: jae loop (+0A)

# got_alpha (+3B)
04 0A                   # +3B: add $10, %al

# got_nibble (+3D)
41 C1 E5 04             # +3D: shl $4, %r13d
41 09 C5                # +41: or %eax, %r13d
41 83 F4 01             # +44: xor $1, %r12d
75 C0                   # +48: jnz loop (+0A)
44 88 6C 24 01          # +4A: mov %r13b, 1(%rsp)
B8 01 00 00 00          # +4F: mov $1, %eax           ; SYS_write = 1
BF 01 00 00 00          # +54: mov $1, %edi           ; fd = 1
48 8D 74 24 01          # +59: lea 1(%rsp), %rsi
BA 01 00 00 00          # +5E: mov $1, %edx
0F 05                   # +63: syscall
45 31 ED                # +65: xor %r13d, %r13d
EB A0                   # +68: jmp loop (+0A)

# comment (+6A): skip bytes until '\n' (0x0A) or EOF
31 C0                   # +6A: xor %eax, %eax
31 FF                   # +6C: xor %edi, %edi
48 89 E6                # +6E: mov %rsp, %rsi
BA 01 00 00 00          # +71: mov $1, %edx
0F 05                   # +76: syscall
48 85 C0                # +78: test %rax, %rax
7E 08                   # +7B: jle done (+85)
80 3C 24 0A             # +7D: cmpb $0x0A, (%rsp)
75 E7                   # +81: jne comment (+6A)
EB 85                   # +83: jmp loop (+0A)

# done (+85): exit(0)
B8 3C 00 00 00          # +85: mov $60, %eax          ; SYS_exit = 60
31 FF                   # +8A: xor %edi, %edi
0F 05                   # +8C: syscall
`

// Annotated hex0 source for a minimal 191-byte x86-64 Linux static ELF
// streaming copy/concatenation utility (`catm`), assembled by Stage 1 `hex0`.
// Copies stdin to stdout in 1 KiB chunks (handling short writes) and exits 0.
TIER2_CATM_X86_64_SOURCE :: `# Auditable x86-64 Linux static ELF catm stream utility (191 bytes)
# Base load address: 0x00400000; entry point: 0x00400078

# ---- ELF64 Header (64 bytes, 0x00..0x3F) ----
7F 45 4C 46 02 01 01 00 00 00 00 00 00 00 00 00
02 00 3E 00 01 00 00 00
78 00 40 00 00 00 00 00 # e_entry: 0x00400078
40 00 00 00 00 00 00 00 # e_phoff: 64
00 00 00 00 00 00 00 00
00 00 00 00
40 00 38 00 01 00 00 00 00 00 00 00

# ---- ELF64 Program Header (56 bytes, 0x40..0x77) ----
01 00 00 00 05 00 00 00
00 00 00 00 00 00 00 00
00 00 40 00 00 00 00 00
00 00 40 00 00 00 00 00
BF 00 00 00 00 00 00 00 # p_filesz: 191 (0xBF)
BF 00 00 00 00 00 00 00 # p_memsz: 191 (0xBF)
00 10 00 00 00 00 00 00

# ---- Machine Code (71 bytes, 0x78..0xBE) ----
48 81 EC 00 04 00 00    # +00: sub $1024, %rsp

# copy_loop (+07): read(0, rsp, 1024)
31 C0                   # +07: xor %eax, %eax         ; SYS_read = 0
31 FF                   # +09: xor %edi, %edi         ; fd = 0
48 89 E6                # +0B: mov %rsp, %rsi
BA 00 04 00 00          # +0E: mov $1024, %edx
0F 05                   # +13: syscall
48 85 C0                # +15: test %rax, %rax
7E 24                   # +18: jle done (+3E)
49 89 C4                # +1A: mov %rax, %r12         ; remaining
48 89 E6                # +1D: mov %rsp, %rsi

# write_loop (+20): write(1, rsi, r12)
B8 01 00 00 00          # +20: mov $1, %eax           ; SYS_write = 1
BF 01 00 00 00          # +25: mov $1, %edi           ; fd = 1
4C 89 E2                # +2A: mov %r12, %rdx
0F 05                   # +2D: syscall
48 85 C0                # +2F: test %rax, %rax
7E 0A                   # +32: jle done (+3E)
48 01 C6                # +34: add %rax, %rsi
49 29 C4                # +37: sub %rax, %r12
75 E4                   # +3A: jnz write_loop (+20)
EB C9                   # +3C: jmp copy_loop (+07)

# done (+3E): exit(0)
B8 3C 00 00 00          # +3E: mov $60, %eax          ; SYS_exit = 60
31 FF                   # +43: xor %edi, %edi
0F 05                   # +45: syscall
`

// Honest readiness table for the full Tier 2 seed-to-Odin chain.
@(rodata)
TIER2_BOOTSTRAP_STAGES := [?]Tier2_Stage_Status {
	{
		name           = "hex0_self_host",
		upstream_stage = "hex0_seed",
		readiness      = .Executable_In_Guest,
		pinned_ref     = "auditable-262B-x86_64-elf-seed",
		command        = TIER2_STAGE1_HEX0_COMMAND,
	},
	{
		name           = "stage0_catm",
		upstream_stage = "hex0_self_host",
		readiness      = .Executable_In_Guest,
		pinned_ref     = "auditable-191B-x86_64-elf-catm",
		command        = TIER2_STAGE2_CATM_COMMAND,
	},
	{
		name           = "m2_planet",
		upstream_stage = "stage0_catm",
		readiness      = .Gated_Upstream_Archive_Pin,
		pinned_ref     = "stage0-posix/M2-Planet (pending flake.nix source archive pin)",
		command        = "/inputs/stage0/M2-Planet --architecture amd64",
	},
	{
		name           = "mes",
		upstream_stage = "m2_planet",
		readiness      = .Gated_Upstream_Archive_Pin,
		pinned_ref     = "gnu-mes (pending flake.nix source archive pin)",
		command        = "/inputs/m2_planet/M2-Planet --build-mes",
	},
	{
		name           = "tcc",
		upstream_stage = "mes",
		readiness      = .Gated_Upstream_Archive_Pin,
		pinned_ref     = "tinycc (pending flake.nix source archive pin)",
		command        = "/inputs/mes/mescc --build-tcc",
	},
	{
		name           = "gcc",
		upstream_stage = "tcc",
		readiness      = .Gated_Multi_Hour_Guest_Budget,
		pinned_ref     = "gcc-4.7 -> gcc-14 (pending flake.nix archive pin and multi-hour guest budget)",
		command        = "/inputs/tcc/tcc --build-gcc-chain",
	},
	{
		name           = "llvm_18",
		upstream_stage = "gcc",
		readiness      = .Gated_Multi_Hour_Guest_Budget,
		pinned_ref     = "llvm-18 + DSE commit " + TIER2_PINNED_LLVM18_DSE_COMMIT,
		command        = "/inputs/gcc/g++ --build-llvm18-pinned",
	},
	{
		name           = "odin_fork",
		upstream_stage = "llvm_18",
		readiness      = .Gated_Multi_Hour_Guest_Budget,
		pinned_ref     = "sachahjkl/Odin@" + TIER2_PINNED_ODIN_FORK_COMMIT,
		command        = "/inputs/llvm_18/clang++ --build-odin-fork",
	},
}

// Pure reference hex0 decoder used on the host to verify the auditable seed
// source matches its binary byte-for-byte. Refuses empty input or an odd nibble.
tier2_hex0_assemble_reference :: proc(source: string, allocator := context.allocator) -> (output: []u8, ok: bool) {
	out := make([dynamic]u8, allocator)
	in_comment := false
	has_high := false
	high: u8 = 0

	for i in 0 ..< len(source) {
		ch := source[i]
		if in_comment {
			if ch == '\n' {
				in_comment = false
			}
			continue
		}
		if ch == '#' || ch == ';' {
			in_comment = true
			continue
		}
		nibble: u8
		is_hex := false
		switch ch {
		case '0' ..= '9':
			nibble = ch - '0'
			is_hex = true
		case 'A' ..= 'F':
			nibble = ch - 'A' + 10
			is_hex = true
		case 'a' ..= 'f':
			nibble = ch - 'a' + 10
			is_hex = true
		}
		if !is_hex {
			continue
		}
		if !has_high {
			high = nibble
			has_high = true
		} else {
			append(&out, (high << 4) | nibble)
			has_high = false
		}
	}
	if has_high || len(out) == 0 {
		delete(out)
		return nil, false
	}
	return out[:], true
}

// Compute the canonical MODTREE1 output tree hash produced by guest_builder
// when a guest stage writes `files` into `/outputs` under TIER2_FROZEN_EPOCH.
tier2_expected_output_tree_hash :: proc(files: []gb.Disk_File_Input) -> (root_hash: blake3.Hash, ok: bool) {
	image := make([]u8, 16 * 1024, context.temp_allocator)
	if _, refusal := gb.pack_disk_image(.Output_Writable, files, TIER2_FROZEN_EPOCH, image); refusal != .None {
		return {}, false
	}
	workspace := new(gb.Disk_Unpack_Workspace, context.temp_allocator)
	tree := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES, context.temp_allocator)
	_, unpacked, refusal := gb.unpack_output_disk(image, u64(len(image)), workspace, tree)
	return unpacked, refusal == .None
}

// Build the canonical multi-stage Tier 2 guest_builder recipes (Stage 1
// hex0 self-assembly -> Stage 2 catm assembly) and their content-addressed
// store objects for execution in `recipes` / `guest_builder`.
tier2_guest_bootstrap_make :: proc(kernel: []u8, archive: []u8, allocator := context.temp_allocator) -> (bundle: Tier2_Guest_Bootstrap_Bundle, ok: bool) {
	if len(kernel) == 0 || len(archive) == 0 {
		return {}, false
	}
	hex0_bin, hex0_ok := tier2_hex0_assemble_reference(TIER2_HEX0_X86_64_SOURCE, allocator)
	if !hex0_ok || len(hex0_bin) != TIER2_HEX0_SEED_BYTES {
		return {}, false
	}
	catm_bin, catm_ok := tier2_hex0_assemble_reference(TIER2_CATM_X86_64_SOURCE, allocator)
	if !catm_ok || len(catm_bin) != TIER2_CATM_ELF_BYTES {
		return {}, false
	}

	bundle.objects = make([dynamic]Module_File, allocator)
	bundle.hex0_seed = hex0_bin
	bundle.hex0_hash = blake3.hash(hex0_bin)

	seen := make(map[string]bool, 16, context.temp_allocator)
	blob_add :: proc(bundle: ^Tier2_Guest_Bootstrap_Bundle, seen: ^map[string]bool, bytes: []u8, alloc := context.temp_allocator) -> blake3.Hash {
		h := blake3.hash(bytes)
		name_rec := pr.blob_object_name(h)
		name := strings.clone(pr.private_object_name_text(&name_rec), alloc)
		if !seen[name] {
			seen[name] = true
			append(&bundle.objects, Module_File{name = name, bytes = bytes})
		}
		return h
	}

	kernel_hash := blob_add(&bundle, &seen, kernel, allocator)
	_ = blob_add(&bundle, &seen, archive, allocator)
	hex0_src_bytes := transmute([]u8)string(TIER2_HEX0_X86_64_SOURCE)
	catm_src_bytes := transmute([]u8)string(TIER2_CATM_X86_64_SOURCE)
	hex0_bin_hash := blob_add(&bundle, &seen, hex0_bin, allocator)
	hex0_src_hash := blob_add(&bundle, &seen, hex0_src_bytes, allocator)
	catm_src_hash := blob_add(&bundle, &seen, catm_src_bytes, allocator)

	// Stage 1: hex0 seed assembles hex0_x86_64.hex0 into /outputs/hex0.
	stage1_out_files := [1]gb.Disk_File_Input{{path = "hex0", content = hex0_bin}}
	stage1_expected_tree := tier2_expected_output_tree_hash(stage1_out_files[:]) or_return

	make_stage_recipe :: proc(
		bundle: ^Tier2_Guest_Bootstrap_Bundle,
		seen: ^map[string]bool,
		kernel_hash: blake3.Hash,
		archive: []u8,
		command: string,
		inputs: []pr.Recipe_Input,
		alloc := context.temp_allocator,
	) -> (recipe_hash: blake3.Hash, ok: bool) {
		guest: gb.Guest_Build_Spec
		guest.kernel_hash = kernel_hash
		guest.root_image_hash = kernel_hash
		guest.frozen_epoch_seconds = TIER2_FROZEN_EPOCH
		guest.memory_pages = TIER2_STAGE0_MEMORY_PAGES
		guest.output_size_bound = TIER2_STAGE0_OUTPUT_BYTES
		guest.max_guest_exits = TIER2_STAGE0_EXITS_MOST
		guest.allow_network = false
		guest.allow_real_clock = false
		guest.allow_writable_inputs = false
		if gb.build_spec_set_command(&guest, command) != .None {
			return {}, false
		}
		if gb.build_spec_set_initial_archive(&guest, archive) != .None {
			return {}, false
		}

		spec := new(pr.Recipe_Spec, context.temp_allocator)
		spec.builder_hash = pr.guest_builder_hash()
		spec.output_kind = .Tree
		spec.source_date_unix = TIER2_FROZEN_EPOCH
		spec.output_block_limit = TIER2_STAGE0_OUTPUT_BYTES / gb.GUEST_PAGE_BYTES
		spec.input_count = u32(len(inputs))
		for inp, idx in inputs {
			spec.inputs[idx] = inp
		}
		written, spec_refusal := gb.encode_build_spec(&guest, spec.arguments[:])
		if spec_refusal != .None {
			return {}, false
		}
		spec.arguments_length = u32(written)
		rh, hash_ref := pr.recipe_hash(spec)
		if hash_ref != .None {
			return {}, false
		}
		recipe_buf := make([]u8, pr.MAX_RECIPE_OBJECT_BYTES, alloc)
		rec_written, enc_ref := pr.recipe_object_encode(spec, recipe_buf)
		if enc_ref != .None {
			return {}, false
		}
		rec_name_rec := pr.recipe_object_name(rh)
		rec_name := strings.clone(pr.private_object_name_text(&rec_name_rec), alloc)
		if !seen[rec_name] {
			seen[rec_name] = true
			append(&bundle.objects, Module_File{name = rec_name, bytes = recipe_buf[:rec_written]})
		}
		return rh, true
	}

	s1_in0, r0 := pr.recipe_input_make("hex0", .Blob, hex0_bin_hash)
	s1_in1, r1 := pr.recipe_input_make("hex0_x86_64.hex0", .Blob, hex0_src_hash)
	if r0 != .None || r1 != .None {
		return {}, false
	}
	s1_inputs := [2]pr.Recipe_Input{s1_in0, s1_in1}
	s1_recipe_hash := make_stage_recipe(&bundle, &seen, kernel_hash, archive, TIER2_STAGE1_HEX0_COMMAND, s1_inputs[:], allocator) or_return

	bundle.stage1_hex0 = Tier2_Guest_Stage_Bundle{
		name            = "hex0_self_host",
		recipe_hash     = s1_recipe_hash,
		expected_output = stage1_expected_tree,
		expected_binary = hex0_bin,
		expected_hash   = blake3.hash(hex0_bin),
	}

	// Stage 2: Stage 1's output tree (cryptographically bound by stage1_expected_tree)
	// assembles catm_x86_64.hex0 into /outputs/catm.
	stage2_out_files := [1]gb.Disk_File_Input{{path = "catm", content = catm_bin}}
	stage2_expected_tree := tier2_expected_output_tree_hash(stage2_out_files[:]) or_return

	s2_in0, r2 := pr.recipe_input_make("hex0_stage1", .Tree, stage1_expected_tree)
	s2_in1, r3 := pr.recipe_input_make("catm_x86_64.hex0", .Blob, catm_src_hash)
	if r2 != .None || r3 != .None {
		return {}, false
	}
	s2_inputs := [2]pr.Recipe_Input{s2_in0, s2_in1}
	s2_recipe_hash := make_stage_recipe(&bundle, &seen, kernel_hash, archive, TIER2_STAGE2_CATM_COMMAND, s2_inputs[:], allocator) or_return

	bundle.stage2_catm = Tier2_Guest_Stage_Bundle{
		name            = "stage0_catm",
		recipe_hash     = s2_recipe_hash,
		expected_output = stage2_expected_tree,
		expected_binary = catm_bin,
		expected_hash   = blake3.hash(catm_bin),
	}
	return bundle, true
}

// Encode the canonical declaration_eval argument record consumed by
// `src/modules/system/c_builder` in multi-unit mode (`assembly`, `exports`,
// `headers`, `units` in sorted field order) for a real multi-file C program such as chibicc.
c_builder_multi_unit_arguments_encode :: proc(
	program: C_Program,
	out_buffer: []u8,
) -> (written: int, ok: bool) {
	if len(program.sources) == 0 {
		return 0, false
	}
	exp_b := strings.builder_make(context.temp_allocator)
	for exp, idx in program.export_names {
		if idx > 0 {
			strings.write_byte(&exp_b, ' ')
		}
		strings.write_string(&exp_b, string(exp))
	}

	w := declaration_eval.Output_Writer{buffer = out_buffer}
	declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&w, 4)

	// Fields written in canonical ascending lexicographical order:
	// "assembly", "exports", "headers", "units".
	declaration_eval.output_write_string(&w, "assembly")
	declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&w, u32(len(program.assembly)))
	for unit in program.assembly {
		declaration_eval.output_write_text(&w, unit.name)
	}

	declaration_eval.output_write_string(&w, "exports")
	declaration_eval.output_write_text(&w, strings.to_string(exp_b))

	declaration_eval.output_write_string(&w, "headers")
	declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&w, u32(len(program.headers)))
	for hdr in program.headers {
		declaration_eval.output_write_text(&w, string(hdr.name))
	}

	declaration_eval.output_write_string(&w, "units")
	declaration_eval.output_write_u8(&w, u8(declaration_eval.Value_Tag.List))
	declaration_eval.output_write_u32(&w, u32(len(program.sources)))
	for src in program.sources {
		declaration_eval.output_write_text(&w, src.name)
	}

	if w.overflow || w.written == 0 {
		return 0, false
	}
	return w.written, true
}

// Construct a real `plans_recipes.Recipe_Spec` targeting `c_builder` in
// multi-unit mode for compiling `program` (e.g., chibicc Stage 1 or Stage 2).
bootstrap_chibicc_c_builder_recipe_make :: proc(
	spec: ^pr.Recipe_Spec,
	c_builder_module_hash: blake3.Hash,
	source_tree_hash: blake3.Hash,
	compiler_module_hash: blake3.Hash,
	assembler_module_hash: blake3.Hash,
	host_module_hash: blake3.Hash,
	program: C_Program,
) -> (recipe_hash: blake3.Hash, ok: bool) {
	spec^ = {}
	if bootstrap_hash_is_zero(c_builder_module_hash) ||
		bootstrap_hash_is_zero(source_tree_hash) ||
		bootstrap_hash_is_zero(compiler_module_hash) ||
		bootstrap_hash_is_zero(assembler_module_hash) ||
		bootstrap_hash_is_zero(host_module_hash) {
		return {}, false
	}
	arg_len, encoded_ok := c_builder_multi_unit_arguments_encode(program, spec.arguments[:])
	if !encoded_ok {
		return {}, false
	}
	in_src, r0 := pr.recipe_input_make("source", .Tree, source_tree_hash)
	in_cc, r1 := pr.recipe_input_make("compiler", .Blob, compiler_module_hash)
	in_asm, r2 := pr.recipe_input_make("assembler", .Blob, assembler_module_hash)
	in_host, r3 := pr.recipe_input_make("host", .Blob, host_module_hash)
	if r0 != .None || r1 != .None || r2 != .None || r3 != .None {
		spec^ = {}
		return {}, false
	}
	spec.builder_hash = c_builder_module_hash
	spec.output_kind = .Tree
	spec.source_date_unix = TIER2_FROZEN_EPOCH
	spec.output_block_limit = 4096
	spec.input_count = 4
	spec.inputs[0] = in_src
	spec.inputs[1] = in_cc
	spec.inputs[2] = in_asm
	spec.inputs[3] = in_host
	spec.arguments_length = u32(arg_len)

	if val_ref, _ := pr.recipe_validate(spec); val_ref != .None {
		spec^ = {}
		return {}, false
	}
	rh, hash_ref := pr.recipe_hash(spec)
	if hash_ref != .None {
		spec^ = {}
		return {}, false
	}
	return rh, true
}
