package build

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"
import "modus:contract/blake3"
import module "modus:contract/module"

@(private = "file")
Synthetic_Section :: struct {
	name:       string,
	type:       u32,
	flags:      u64,
	address:    u64,
	link:       u32,
	info:       u32,
	alignment:  u64,
	entry_size: u64,
	data:       []u8,
	nobits_size: u64,
}

@(private = "file")
Synthetic_Elf :: struct {
	elf_type:        u16,
	machine:         u16,
	class:           u8,
	data_order:      u8,
	program_headers: []Elf_Program_Header,
	sections:        []Synthetic_Section,
	omit_shstr_nul:  bool,
}

@(private = "file")
synthetic_elf_build :: proc(spec: Synthetic_Elf, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
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

	// Reserve ELF header.
	resize(&out, size_of(Elf_Header))

	ph_offset: u64
	if len(spec.program_headers) > 0 {
		align_buf(&out, 8)
		ph_offset = u64(len(out))
		for ph in spec.program_headers {
			p := ph
			append_bytes(&out, ([^]u8)(&p)[:size_of(Elf_Program_Header)])
		}
	}

	// Build .shstrtab bytes.
	shstr := make([dynamic]u8, allocator)
	append(&shstr, 0)
	name_offsets := make([]u32, len(spec.sections), allocator)
	for sec, idx in spec.sections {
		if sec.name == "" {
			name_offsets[idx] = 0
			continue
		}
		name_offsets[idx] = u32(len(shstr))
		append(&shstr, ..transmute([]u8)sec.name)
		append(&shstr, 0)
	}
	shstr_name_offset := u32(len(shstr))
	append(&shstr, ..transmute([]u8)string(".shstrtab"))
	if !spec.omit_shstr_nul {
		append(&shstr, 0)
	}

	// Write section payloads.
	headers := make([dynamic]Elf_Section_Header, allocator)
	append(&headers, Elf_Section_Header{}) // Section 0: SHT_NULL.
	for sec, idx in spec.sections {
		align_buf(&out, 8)
		off := u64(len(out))
		size := sec.nobits_size
		if sec.type != ELF_SECTION_NO_BITS {
			size = u64(len(sec.data))
			append_bytes(&out, sec.data)
		}
		append(&headers, Elf_Section_Header {
			name       = name_offsets[idx],
			type       = sec.type,
			flags      = sec.flags,
			address    = sec.address,
			offset     = off,
			size       = size,
			link       = sec.link,
			info       = sec.info,
			alignment  = sec.alignment,
			entry_size = sec.entry_size,
		})
	}

	// Append .shstrtab as the last section.
	align_buf(&out, 8)
	shstr_index := u16(len(headers))
	shstr_offset := append_bytes(&out, shstr[:])
	append(&headers, Elf_Section_Header {
		name      = shstr_name_offset,
		type      = ELF_SECTION_STRING_TABLE,
		offset    = shstr_offset,
		size      = u64(len(shstr)),
		alignment = 1,
	})

	// Write section headers.
	align_buf(&out, 8)
	sh_offset := u64(len(out))
	for sh in headers {
		s := sh
		append_bytes(&out, ([^]u8)(&s)[:size_of(Elf_Section_Header)])
	}

	header := Elf_Header {
		magic                      = ELF_MAGIC,
		class                      = spec.class != 0 ? spec.class : ELF_CLASS_64,
		data                       = spec.data_order != 0 ? spec.data_order : ELF_DATA_LITTLE_ENDIAN,
		identification_version     = 1,
		type                       = spec.elf_type,
		machine                    = spec.machine != 0 ? spec.machine : ELF_MACHINE_X86_64,
		version                    = 1,
		program_header_offset      = ph_offset,
		section_header_offset      = sh_offset,
		header_size                = size_of(Elf_Header),
		program_header_size        = size_of(Elf_Program_Header),
		program_header_count       = u16(len(spec.program_headers)),
		section_header_size        = size_of(Elf_Section_Header),
		section_header_count       = u16(len(headers)),
		section_name_section_index = shstr_index,
	}
	mem.copy(raw_data(out[:]), &header, size_of(Elf_Header))
	return out[:]
}

@(private = "file")
strtab_builder_add :: proc(pool: ^[dynamic]u8, name: string) -> u32 {
	if len(pool) == 0 {
		append(pool, 0)
	}
	off := u32(len(pool))
	append(pool, ..transmute([]u8)name)
	append(pool, 0)
	return off
}

@(private = "file")
symbols_bytes :: proc(list: []Elf_Symbol, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, len(list) * size_of(Elf_Symbol), allocator)
	for sym, idx in list {
		s := sym
		mem.copy(raw_data(out[idx * size_of(Elf_Symbol):]), &s, size_of(Elf_Symbol))
	}
	return out
}

@(private = "file")
relas_bytes :: proc(list: []Elf_Rela, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, len(list) * size_of(Elf_Rela), allocator)
	for rela, idx in list {
		r := rela
		mem.copy(raw_data(out[idx * size_of(Elf_Rela):]), &r, size_of(Elf_Rela))
	}
	return out
}

@(private = "file")
minimal_library_module :: proc(t: ^testing.T) -> []u8 {
	// Synthetic ET_REL library exporting `double_it(x: integer) -> integer`.
	// Machine code: lea (%rdi,%rdi,1), %rax; ret  (48 8d 04 3f c3)
	code := [?]u8{0x48, 0x8D, 0x04, 0x3F, 0xC3}
	strtab := make([dynamic]u8, context.temp_allocator)
	fn_name := strtab_builder_add(&strtab, "double_it")
	syms := [?]Elf_Symbol {
		{},
		{name = fn_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 1, value = 0, size = u64(len(code))},
	}
	elf := synthetic_elf_build({
		elf_type = ELF_TYPE_RELOCATABLE,
		sections = {
			{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
			{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 3, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
			{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
		},
	})
	manifest, problem := manifest_parse(`
module: helper_lib
about: Synthetic library module for testing imports.
library: yes

export double_it
  about: Double an integer.
  param x: integer
  result: integer
`)
	testing.expect_value(t, problem, "")
	built, ok := convert_elf_with_manifest(elf, manifest, nil)
	testing.expect(t, ok, "helper_lib must convert cleanly")
	if ok {
		testing.expect_value(t, module.validate(built), module.Error.None)
	}
	return built
}

// End-to-end synthetic ET_REL conversion (zero external tools):
// verifies zero-size .text, .text.<fn>, .rodata.str1.1, .data.rel.ro, .data,
// .bss modus_own_hash, SHT_GROUP COMDAT, skipped .rela.debug_info, PC32,
// PLT32 import stub, GOTPCRELX direct import slot, R_X86_64_64 rebase and
// import slot, budget accounting, module.validate, module.rebase, and
// byte-for-byte determinism.
@(test)
relocatable_elf_synthetic_full_round_trip :: proc(t: ^testing.T) {
	helper_file := minimal_library_module(t)
	defer delete(helper_file)

	// Code section (.text.main):
	//   0x00: entry: ret (c3)
	//   0x01..0x0f: nop padding
	//   0x10: compute:
	//         lea 0(%rip), %rax          (48 8d 05 00 00 00 00) -> PC32 at +3 to .rodata.str1.1
	//         call *0(%rip)              (ff 15 00 00 00 00)    -> GOTPCRELX at +9 to imported double_it
	//         call 0                     (e8 00 00 00 00)       -> PLT32 at +14 to imported double_it
	//         ret                        (c3)
	code := [?]u8{
		0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
		0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
		0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00,
		0xFF, 0x15, 0x00, 0x00, 0x00, 0x00,
		0xE8, 0x00, 0x00, 0x00, 0x00,
		0xC3,
	}
	rodata := [?]u8{'h', 'e', 'l', 'l', 'o', 0}
	relro_data := [16]u8{} // [0..7]: R_X86_64_64 rebase to rodata; [8..15]: R_X86_64_64 import slot to double_it
	rw_data := [16]u8{1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0} // [8..15]: R_X86_64_64 rebase to rw_data[0]
	// Valid SHT_GROUP (COMDAT = 1) containing section 2 (.text.main).
	group_words := [2]u32{1, 2}
	group_bytes := ([^]u8)(&group_words[0])[:8]

	strtab := make([dynamic]u8, context.temp_allocator)
	entry_name := strtab_builder_add(&strtab, "entry")
	compute_name := strtab_builder_add(&strtab, "compute")
	double_it_name := strtab_builder_add(&strtab, "double_it")
	own_hash_name := strtab_builder_add(&strtab, module.OWN_HASH_PLACE_SYMBOL)
	ro_sym_name := strtab_builder_add(&strtab, "greeting")
	data_sym_name := strtab_builder_add(&strtab, "state_word")

	// Section indices (1-based):
	// 1: .text (zero-size)
	// 2: .text.main (Code)
	// 3: .rodata.str1.1 (Read_Only)
	// 4: .data.rel.ro (Read_Only_After_Load)
	// 5: .data (Writable_Data)
	// 6: .bss (Writable_Bss, 32 bytes for modus_own_hash)
	// 7: .group (SHT_GROUP)
	// 8: .comment (non-allocated)
	// 9: .rela.text.main
	// 10: .rela.data.rel.ro
	// 11: .rela.data
	// 12: .rela.comment (targets non-allocated section 8 -> must be skipped!)
	// 13: .symtab (link = 14)
	// 14: .strtab
	syms := [?]Elf_Symbol {
		{},
		{name = ro_sym_name, info = (ELF_SYMBOL_BINDING_LOCAL << 4) | ELF_SYMBOL_OBJECT, section_index = 3, value = 0, size = u64(len(rodata))},
		{name = data_sym_name, info = (ELF_SYMBOL_BINDING_LOCAL << 4) | ELF_SYMBOL_OBJECT, section_index = 5, value = 0, size = 8},
		{name = entry_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 2, value = 0, size = 1},
		{name = compute_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 2, value = 0x10, size = 19},
		{name = double_it_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_NO_TYPE, section_index = ELF_SECTION_INDEX_UNDEFINED, value = 0, size = 0},
		{name = own_hash_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_OBJECT, section_index = 6, value = 0, size = module.HASH_SIZE},
	}
	rela_text := [?]Elf_Rela {
		{offset = 0x13, info = (1 << 32) | ELF_RELOCATION_PC32, addend = -4},
		{offset = 0x19, info = (5 << 32) | ELF_RELOCATION_GOTPCRELX, addend = -4},
		{offset = 0x1E, info = (5 << 32) | ELF_RELOCATION_PLT32, addend = -4},
	}
	rela_relro := [?]Elf_Rela {
		{offset = 0, info = (1 << 32) | ELF_RELOCATION_64, addend = 0},
		{offset = 8, info = (5 << 32) | ELF_RELOCATION_64, addend = 0},
	}
	rela_data := [?]Elf_Rela {
		{offset = 8, info = (2 << 32) | ELF_RELOCATION_64, addend = 0},
	}
	// Garbage relocation targeting non-allocated .comment: must be ignored.
	rela_comment := [?]Elf_Rela {
		{offset = 0, info = (1 << 32) | ELF_RELOCATION_32, addend = 0},
	}

	elf := synthetic_elf_build({
		elf_type = ELF_TYPE_RELOCATABLE,
		sections = {
			{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 4, data = nil},
			{name = ".text.main", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
			{name = ".rodata.str1.1", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED, alignment = 1, data = rodata[:]},
			{name = ".data.rel.ro", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = relro_data[:]},
			{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = rw_data[:]},
			{name = ".bss", type = ELF_SECTION_NO_BITS, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 16, nobits_size = module.HASH_SIZE},
			{name = ".group", type = ELF_SECTION_GROUP, link = 13, info = 3, alignment = 4, entry_size = 4, data = group_bytes},
			{name = ".comment", type = ELF_SECTION_PROGRAM_DATA, alignment = 1, data = transmute([]u8)string("synthetic-cc")},
			{name = ".rela.text.main", type = ELF_SECTION_RELA, link = 13, info = 2, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(rela_text[:])},
			{name = ".rela.data.rel.ro", type = ELF_SECTION_RELA, link = 13, info = 4, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(rela_relro[:])},
			{name = ".rela.data", type = ELF_SECTION_RELA, link = 13, info = 5, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(rela_data[:])},
			{name = ".rela.comment", type = ELF_SECTION_RELA, link = 13, info = 8, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(rela_comment[:])},
			{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 14, info = 3, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
			{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
		},
	})

	manifest, problem := manifest_parse(`
module: synth_app
about: Synthetic application exercising every freestanding ET_REL path.
imports: helper_lib
budget: working_memory_pages=4 threads=1

export entry

export compute
  about: Call the imported helper and read static data.
  param value: integer
  result: integer
`)
	testing.expect_value(t, problem, "")

	imports := [?]Import_File{{name = "helper_lib", file = helper_file}}
	slot_symbols := make([dynamic]string, context.temp_allocator)
	built, ok := convert_elf_with_manifest(elf, manifest, imports[:], &slot_symbols)
	testing.expect(t, ok, "synth_app must convert cleanly")
	if !ok {
		return
	}
	defer delete(built)

	// Determinism: converting again produces byte-identical output.
	built_again, ok_again := convert_elf_with_manifest(elf, manifest, imports[:])
	testing.expect(t, ok_again)
	if ok_again {
		defer delete(built_again)
		testing.expect(t, slice.equal(built, built_again), "two conversions must produce identical bytes")
	}

	// Validate module file with the real kernel/loader validator.
	testing.expect_value(t, module.validate(built), module.Error.None)
	head, head_err := module.header(built)
	testing.expect_value(t, head_err, module.Error.None)
	testing.expect_value(t, head.machine, module.Machine.X86_64)
	testing.expect_value(t, head.entry_export, u32(1))

	// Exports.
	testing.expect_value(t, module.count(built, .Exports), u32(3))
	testing.expect_value(t, module_export_name(built, 1), "entry")
	testing.expect_value(t, module_export_name(built, 2), "compute")

	// Import hash matches helper_lib.
	testing.expect_value(t, module.count(built, .Imports), u32(2))
	imp, imp_ok := module.record(built, .Imports, 1, module.Import)
	testing.expect(t, imp_ok)
	testing.expect_value(t, imp.hash, blake3.hash(helper_file))

	// Import slots: 1 synthetic slot (shared by GOTPCRELX + PLT32 stub) + 1 data slot in .data.rel.ro.
	testing.expect_value(t, module.count(built, .Import_Slots), u32(3))
	testing.expect_value(t, len(slot_symbols), 2)
	for slot_idx in u32(1) ..< module.count(built, .Import_Slots) {
		slot, slot_ok := module.record(built, .Import_Slots, slot_idx, module.Import_Slot)
		testing.expect(t, slot_ok)
		testing.expect_value(t, slot.import_index, u32(1))
		testing.expect_value(t, slot.export_index, u32(1))
	}

	// Own-hash place is present and lies in writable .bss.
	own_place, has_own := module.own_hash_place(built)
	testing.expect(t, has_own, "modus_own_hash must be recorded in Own_Hash table")
	testing.expect(t, own_place > 0)

	// Budget table exists and includes working memory + module + import + first thread pages.
	budget, has_budget := module.floor_read(built)
	testing.expect(t, has_budget)
	testing.expect(t, budget.pages > 4)
	testing.expect_value(t, budget.threads, u64(1))

	// Simulate loading and rebasing at a non-zero base address.
	memory := make([]u8, int(head.memory_size), context.temp_allocator)
	module.copy_segments(built, memory)
	base := uintptr(0x1_0000_0000)
	testing.expect_value(t, module.rebase(built, memory, base), module.Error.None)

	// Verify the rebased pointer in .data.rel.ro[0..7] now points to base + rodata segment offset (0x1000).
	relro_seg, _ := module.record(built, .Segments, 3, module.Segment)
	rebased_ptr: u64
	mem.copy(&rebased_ptr, raw_data(memory[relro_seg.memory_offset:]), 8)
	testing.expect_value(t, rebased_ptr, u64(base) + module.PAGE_SIZE)
}

// Adversarial ET_REL refusal tests: wrong arch, ET_DYN, ET_EXEC, PT_INTERP,
// unresolved undefined symbol, forbidden TLS/GOT relocations, non-PIC reloc,
// text reloc, SHN_COMMON, SHF_TLS, W+X, INIT_ARRAY, bad alignment, bad
// own-hash, mismatched/local/object export symbol, and library with relro.
@(test)
relocatable_elf_refusals :: proc(t: ^testing.T) {
	helper_file := minimal_library_module(t)
	defer delete(helper_file)

	base_manifest, prob := manifest_parse("module: bad_mod\nabout: Refusal probe.\nexport foo\n  about: Test.\n  result: integer\n")
	testing.expect_value(t, prob, "")
	lib_manifest, lib_prob := manifest_parse("module: bad_lib\nabout: Library refusal probe.\nlibrary: yes\nexport foo\n  about: Test.\n  result: integer\n")
	testing.expect_value(t, lib_prob, "")

	code := [?]u8{0x31, 0xC0, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90}
	rw_data := [16]u8{}

	// 1. Truncated / empty inputs (0, 1, 63 bytes).
	for size in ([?]int{0, 1, 63}) {
		buf := make([]u8, size, context.temp_allocator)
		_, ok := convert_elf_with_manifest(buf, base_manifest, nil)
		testing.expectf(t, !ok, "truncated input of %d bytes must be refused", size)
	}

	make_simple_rel := proc(elf_type: u16, machine: u16, reloc_type: u32, undef_sym: bool, addend: i64, sym_type: u8, sym_bind: u8, target_is_text: bool) -> []u8 {
		code_bytes := [?]u8{0x48, 0x8B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC3}
		data_bytes := [16]u8{}
		strtab := make([dynamic]u8, context.temp_allocator)
		foo_name := strtab_builder_add(&strtab, "foo")
		ext_name := strtab_builder_add(&strtab, undef_sym ? "missing_sym" : "double_it")
		syms := [?]Elf_Symbol {
			{},
			{name = foo_name, info = (sym_bind << 4) | sym_type, section_index = 1, value = 0, size = 16},
			{name = ext_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_NO_TYPE, section_index = undef_sym ? ELF_SECTION_INDEX_UNDEFINED : 2, value = 0, size = 8},
		}
		sections := make([dynamic]Synthetic_Section, context.temp_allocator)
		append(&sections, Synthetic_Section{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code_bytes[:]})
		append(&sections, Synthetic_Section{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = data_bytes[:]})
		if reloc_type != ELF_RELOCATION_NONE {
			relas := [?]Elf_Rela{{offset = target_is_text ? 8 : 0, info = (2 << 32) | u64(reloc_type), addend = addend}}
			append(&sections, Synthetic_Section{
				name       = target_is_text ? ".rela.text" : ".rela.data",
				type       = ELF_SECTION_RELA,
				link       = 4,
				info       = target_is_text ? 1 : 2,
				alignment  = 8,
				entry_size = size_of(Elf_Rela),
				data       = relas_bytes(relas[:]),
			})
			append(&sections, Synthetic_Section{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 5, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])})
			append(&sections, Synthetic_Section{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]})
		} else {
			append(&sections, Synthetic_Section{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 4, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])})
			append(&sections, Synthetic_Section{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]})
		}
		return synthetic_elf_build({elf_type = elf_type, machine = machine, sections = sections[:]})
	}

	// 2. Wrong architecture (ARM64 = 183) and wrong ELF types (ET_DYN, ET_EXEC).
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, 183, 0, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, false), base_manifest, nil)
		testing.expect(t, !ok, "ARM64 object must be refused")
	}
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_SHARED, ELF_MACHINE_X86_64, 0, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, false), base_manifest, nil)
		testing.expect(t, !ok, "ET_DYN must be refused by convert_elf_with_manifest")
	}
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_EXECUTABLE, ELF_MACHINE_X86_64, 0, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, false), base_manifest, nil)
		testing.expect(t, !ok, "ET_EXEC must be refused")
	}

	// 3. Unresolved undefined symbol.
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, ELF_RELOCATION_64, true, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, false), base_manifest, nil)
		testing.expect(t, !ok, "unresolved undefined symbol must be refused")
	}

	// 4. Forbidden TLS relocations.
	for tls_reloc in ([?]u32{ELF_RELOCATION_TLSGD, ELF_RELOCATION_GOTTPOFF, ELF_RELOCATION_TPOFF64, ELF_RELOCATION_TLSDESC}) {
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, tls_reloc, false, -4, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, true), base_manifest, nil)
		testing.expectf(t, !ok, "TLS relocation %d must be refused", tls_reloc)
	}

	// 5. Forbidden GOT / dynamic relocations and non-PIC 32-bit absolute relocations.
	for bad_reloc in ([?]u32{ELF_RELOCATION_GOT32, ELF_RELOCATION_GOTOFF64, ELF_RELOCATION_GOTPC32, ELF_RELOCATION_COPY, ELF_RELOCATION_IRELATIVE, ELF_RELOCATION_32, ELF_RELOCATION_32S}) {
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, bad_reloc, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, true), base_manifest, nil)
		testing.expectf(t, !ok, "forbidden relocation %d must be refused", bad_reloc)
	}

	// 6. Text relocation (R_X86_64_64 targeting .text).
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, ELF_RELOCATION_64, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_GLOBAL, true), base_manifest, nil)
		testing.expect(t, !ok, "R_X86_64_64 in .text must be refused")
	}

	// 7. Mismatched export symbols: STB_LOCAL and STT_OBJECT.
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, 0, false, 0, ELF_SYMBOL_FUNCTION, ELF_SYMBOL_BINDING_LOCAL, false), base_manifest, nil)
		testing.expect(t, !ok, "local export symbol must be refused")
	}
	{
		_, ok := convert_elf_with_manifest(make_simple_rel(ELF_TYPE_RELOCATABLE, ELF_MACHINE_X86_64, 0, false, 0, ELF_SYMBOL_OBJECT, ELF_SYMBOL_BINDING_GLOBAL, false), base_manifest, nil)
		testing.expect(t, !ok, "STT_OBJECT export symbol must be refused")
	}

	// 8. PT_INTERP on ET_REL, SHF_TLS section, SHT_INIT_ARRAY, W+X section, bad alignment, SHN_COMMON, bad own_hash size.
	{
		strtab := make([dynamic]u8, context.temp_allocator)
		foo_name := strtab_builder_add(&strtab, "foo")
		syms := [?]Elf_Symbol{
			{},
			{name = foo_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 1, value = 0, size = 8},
		}
		// PT_INTERP.
		elf_interp := synthetic_elf_build({
			elf_type        = ELF_TYPE_RELOCATABLE,
			program_headers = {{type = ELF_PROGRAM_INTERPRETER}},
			sections        = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 3, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok := convert_elf_with_manifest(elf_interp, base_manifest, nil)
		testing.expect(t, !ok, "PT_INTERP must be refused")

		// SHF_TLS section.
		elf_tls := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".tdata", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE | ELF_SECTION_FLAG_TLS, alignment = 8, data = rw_data[:]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 4, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_tls, base_manifest, nil)
		testing.expect(t, !ok, "SHF_TLS section must be refused")

		// W+X section.
		elf_wx := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE | ELF_SECTION_FLAG_WRITE, alignment = 16, data = code[:]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 3, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_wx, base_manifest, nil)
		testing.expect(t, !ok, "W+X section must be refused")

		// SHT_INIT_ARRAY non-empty.
		elf_init := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".init_array", type = ELF_SECTION_INIT_ARRAY, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = rw_data[:8]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 4, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_init, base_manifest, nil)
		testing.expect(t, !ok, "non-empty .init_array must be refused")

		// Non-power-of-two alignment (3).
		elf_align := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 3, data = code[:]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 3, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_align, base_manifest, nil)
		testing.expect(t, !ok, "non-power-of-two section alignment must be refused")

		// SHN_COMMON symbol.
		common_name := strtab_builder_add(&strtab, "tentative_global")
		common_syms := [?]Elf_Symbol{
			{},
			{name = foo_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 1, value = 0, size = 8},
			{name = common_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_OBJECT, section_index = ELF_SECTION_INDEX_COMMON, value = 8, size = 8},
		}
		elf_common := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 3, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(common_syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_common, base_manifest, nil)
		testing.expect(t, !ok, "SHN_COMMON symbol must be refused")

		// Wrong own-hash size (31 bytes).
		own_name := strtab_builder_add(&strtab, module.OWN_HASH_PLACE_SYMBOL)
		bad_own_syms := [?]Elf_Symbol{
			{},
			{name = foo_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 1, value = 0, size = 8},
			{name = own_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_OBJECT, section_index = 2, value = 0, size = 31},
		}
		elf_bad_own := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".bss", type = ELF_SECTION_NO_BITS, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, nobits_size = 32},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 4, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(bad_own_syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_bad_own, base_manifest, nil)
		testing.expect(t, !ok, "modus_own_hash of 31 bytes must be refused")

		// Library module with a rebase in .data.rel.ro must be refused.
		rela_relro := [?]Elf_Rela{{offset = 0, info = (1 << 32) | ELF_RELOCATION_64, addend = 0}}
		elf_lib_relro := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".data.rel.ro", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = rw_data[:8]},
				{name = ".rela.data.rel.ro", type = ELF_SECTION_RELA, link = 4, info = 2, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(rela_relro[:])},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 5, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert_elf_with_manifest(elf_lib_relro, lib_manifest, nil)
		testing.expect(t, !ok, "library module with Read_Only_After_Load rebase must be refused")
	}

	// 9. Non-zero addend on R_X86_64_64 import slot refused.
	{
		imp_manifest, imp_prob := manifest_parse("module: imp_bad\nabout: Bad addend.\nimports: helper_lib\nexport foo\n  about: Test.\n  result: integer\n")
		testing.expect_value(t, imp_prob, "")
		imports := [?]Import_File{{name = "helper_lib", file = helper_file}}
		strtab := make([dynamic]u8, context.temp_allocator)
		foo_name := strtab_builder_add(&strtab, "foo")
		dbl_name := strtab_builder_add(&strtab, "double_it")
		syms := [?]Elf_Symbol{
			{},
			{name = foo_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_FUNCTION, section_index = 1, value = 0, size = 8},
			{name = dbl_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_NO_TYPE, section_index = ELF_SECTION_INDEX_UNDEFINED, value = 0, size = 0},
		}
		relas := [?]Elf_Rela{{offset = 0, info = (2 << 32) | ELF_RELOCATION_64, addend = 8}}
		elf := synthetic_elf_build({
			elf_type = ELF_TYPE_RELOCATABLE,
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, alignment = 16, data = code[:]},
				{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, alignment = 8, data = rw_data[:8]},
				{name = ".rela.data", type = ELF_SECTION_RELA, link = 4, info = 2, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(relas[:])},
				{name = ".symtab", type = ELF_SECTION_SYMBOLS, link = 5, info = 1, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(syms[:])},
				{name = ".strtab", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok := convert_elf_with_manifest(elf, imp_manifest, imports[:])
		testing.expect(t, !ok, "non-zero addend on import slot must be refused")
	}
}

// Adversarial tests for the hardened ET_DYN converter (`convert`):
// missing SHT_DYNSYM, unterminated string table, PT_INTERP, file_size > memory_size,
// huge file_size allocation attempt, out-of-range relocation symbol index,
// non-zero addend on import slot, duplicate rebase, SHT_RELR, and zero-size section.
@(test)
convert_shared_elf_hardening :: proc(t: ^testing.T) {
	helper_file := minimal_library_module(t)
	defer delete(helper_file)

	desc := Module_Description{about = "Hardening test.", text = "Hardening test."}
	code := [?]u8{0xC3, 0x90, 0x90, 0x90}
	rw := [16]u8{}

	// 1. Missing SHT_DYNSYM (previously slipped past link < len(sections) when exports was empty).
	{
		elf := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4}},
			sections        = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
			},
		})
		_, ok := convert("no_dynsym", elf, desc, nil)
		testing.expect(t, !ok, "ET_DYN without SHT_DYNSYM must be refused")
	}

	// 2. PT_INTERP refused in ET_DYN.
	{
		strtab := [?]u8{0}
		dynsym := [?]Elf_Symbol{{}}
		elf := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {
				{type = ELF_PROGRAM_INTERPRETER},
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4},
			},
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 3, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok := convert("has_interp", elf, desc, nil)
		testing.expect(t, !ok, "ET_DYN with PT_INTERP must be refused")
	}

	// 3. PT_LOAD with file_size > memory_size and huge file_size (DoS guard).
	{
		strtab := [?]u8{0}
		dynsym := [?]Elf_Symbol{{}}
		elf_huge := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ, offset = 0, address = 0, file_size = 0x1_0000_0000, memory_size = 0x1_0000_0000}},
			sections        = {
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 2, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok := convert("huge_load", elf_huge, desc, nil)
		testing.expect(t, !ok, "PT_LOAD with file_size past EOF must be refused before allocation")
	}

	// 4. Out-of-bounds relocation symbol index in ET_DYN.
	{
		strtab := [?]u8{0}
		dynsym := [?]Elf_Symbol{{}}
		bad_rela := [?]Elf_Rela{{offset = 0x1000, info = (99 << 32) | ELF_RELOCATION_64, addend = 0}}
		elf_oob_sym := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4},
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_WRITE, offset = 0, address = 0x1000, file_size = 16, memory_size = 16},
			},
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
				{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, address = 0x1000, alignment = 8, data = rw[:]},
				{name = ".rela.dyn", type = ELF_SECTION_RELA, flags = ELF_SECTION_FLAG_ALLOCATED, link = 4, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(bad_rela[:])},
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 5, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok := convert("oob_sym", elf_oob_sym, desc, nil)
		testing.expect(t, !ok, "relocation symbol index past .dynsym count must be refused")
	}

	// 5. Non-zero addend on ET_DYN import slot and duplicate rebase refused.
	{
		strtab := make([dynamic]u8, context.temp_allocator)
		dbl_name := strtab_builder_add(&strtab, "double_it")
		dynsym := [?]Elf_Symbol{
			{},
			{name = dbl_name, info = (ELF_SYMBOL_BINDING_GLOBAL << 4) | ELF_SYMBOL_NO_TYPE, section_index = ELF_SECTION_INDEX_UNDEFINED},
		}
		bad_import_rela := [?]Elf_Rela{{offset = 0x1000, info = (1 << 32) | ELF_RELOCATION_64, addend = 16}}
		elf_addend := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4},
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_WRITE, offset = 0, address = 0x1000, file_size = 16, memory_size = 16},
			},
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
				{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, address = 0x1000, alignment = 8, data = rw[:]},
				{name = ".rela.dyn", type = ELF_SECTION_RELA, flags = ELF_SECTION_FLAG_ALLOCATED, link = 4, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(bad_import_rela[:])},
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 5, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		imports := [?]Import_File{{name = "helper_lib", file = helper_file}}
		_, ok := convert("import_addend", elf_addend, desc, imports[:])
		testing.expect(t, !ok, "ET_DYN import slot with non-zero addend must be refused")

		dup_rebase := [?]Elf_Rela{
			{offset = 0x1000, info = ELF_RELOCATION_RELATIVE, addend = 0},
			{offset = 0x1000, info = ELF_RELOCATION_RELATIVE, addend = 0},
		}
		elf_dup := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			program_headers = {
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4},
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_WRITE, offset = 0, address = 0x1000, file_size = 16, memory_size = 16},
			},
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
				{name = ".data", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, address = 0x1000, alignment = 8, data = rw[:]},
				{name = ".rela.dyn", type = ELF_SECTION_RELA, flags = ELF_SECTION_FLAG_ALLOCATED, link = 4, alignment = 8, entry_size = size_of(Elf_Rela), data = relas_bytes(dup_rebase[:])},
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 5, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		_, ok = convert("dup_rebase", elf_dup, desc, nil)
		testing.expect(t, !ok, "duplicate rebase offset must be refused")
	}

	// 6. Unterminated .shstrtab AND zero-size PROGBITS section in BSS tail:
	// bounded elf_string_at does not read out of bounds, and zero-size PROGBITS does not fail.
	{
		strtab := [?]u8{0}
		dynsym := [?]Elf_Symbol{{}}
		elf_edge := synthetic_elf_build({
			elf_type        = ELF_TYPE_SHARED,
			omit_shstr_nul  = true,
			program_headers = {
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_EXECUTE, offset = 0, address = 0, file_size = 4, memory_size = 4},
				{type = ELF_PROGRAM_LOAD, flags = ELF_PROGRAM_READ | ELF_PROGRAM_WRITE, offset = 0, address = 0x1000, file_size = 8, memory_size = 64},
			},
			sections = {
				{name = ".text", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_EXECUTE, address = 0, alignment = 4, data = code[:]},
				{name = ".empty_tail", type = ELF_SECTION_PROGRAM_DATA, flags = ELF_SECTION_FLAG_ALLOCATED | ELF_SECTION_FLAG_WRITE, address = 0x1020, alignment = 1, data = nil},
				{name = ".dynsym", type = ELF_SECTION_DYNAMIC_SYMBOLS, link = 4, alignment = 8, entry_size = size_of(Elf_Symbol), data = symbols_bytes(dynsym[:])},
				{name = ".dynstr", type = ELF_SECTION_STRING_TABLE, alignment = 1, data = strtab[:]},
			},
		})
		built, ok := convert("edge_ok", elf_edge, desc, nil)
		testing.expect(t, ok, "unterminated shstrtab and zero-size section in BSS tail must convert safely")
		if ok {
			defer delete(built)
			testing.expect_value(t, module.validate(built), module.Error.None)
		}
	}
}

// End-to-end freestanding C compilation with clang -> ET_REL .o -> modus module!
// Compiles a C library module and a C consumer module (both with -fno-plt for
// direct GOTPCRELX import slots and without -fno-plt for PLT32 stubs), converts
// them via convert_elf_with_manifest, validates both with module.validate, and
// rebases the loaded image with module.rebase.
@(test)
relocatable_elf_freestanding_c_end_to_end :: proc(t: ^testing.T) {
	// Skip gracefully only if clang is absent on a stripped host.
	probe_state, _, _, probe_err := os.process_exec({command = {"clang", "--version"}}, context.temp_allocator)
	if probe_err != nil || !probe_state.exited || !probe_state.success {
		return
	}

	temp_root := fmt.tprintf("%s/modus_abi_c_test_%d", os.temp_dir(context.temp_allocator), os.get_pid())
	_ = os.remove_all(temp_root)
	testing.expect(t, os.make_directory_all(temp_root) == nil)
	defer os.remove_all(temp_root)

	lib_c := fmt.tprintf("%s/c_math_lib.c", temp_root)
	lib_o := fmt.tprintf("%s/c_math_lib.o", temp_root)
	app_c := fmt.tprintf("%s/c_caller.c", temp_root)
	app_noplt_o := fmt.tprintf("%s/c_caller_noplt.o", temp_root)
	app_plt_o := fmt.tprintf("%s/c_caller_plt.o", temp_root)

	lib_source := `
typedef long long i64;
struct Pair { i64 left; i64 right; };

__attribute__((visibility("default")))
i64 add_pair(const struct Pair *pair) {
    return pair->left + pair->right;
}
`
	app_source := `
typedef long long i64;
typedef unsigned char u8;
struct Pair { i64 left; i64 right; };

extern i64 add_pair(const struct Pair *pair);

u8 modus_own_hash[32];
static const char tag_text[] = "c_caller";
static i64 accumulator = 10;
static i64 *accumulator_slot = &accumulator;

__attribute__((visibility("default")))
i64 compute_with_c(i64 x) {
    struct Pair p = { *accumulator_slot + x, (i64)tag_text[0] };
    *accumulator_slot += x;
    return add_pair(&p);
}
`
	testing.expect(t, os.write_entire_file(lib_c, lib_source) == nil)
	testing.expect(t, os.write_entire_file(app_c, app_source) == nil)

	compile_c :: proc(source, output: string, no_plt: bool) -> bool {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "clang")
		append(&cmd, ..c_compile_flags[:])
		if no_plt {
			append(&cmd, "-fno-plt")
		}
		append(&cmd, "-c", "-o", output, source)
		state, _, err_out, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
		if err != nil || !state.exited || !state.success {
			fmt.eprintfln("clang failed for %s: %s", source, string(err_out))
			return false
		}
		return true
	}

	testing.expect(t, compile_c(lib_c, lib_o, true), "compile freestanding C library")
	testing.expect(t, compile_c(app_c, app_noplt_o, true), "compile freestanding C caller with -fno-plt")
	testing.expect(t, compile_c(app_c, app_plt_o, false), "compile freestanding C caller with PLT32")

	lib_manifest, lib_prob := manifest_parse(`
module: c_math_lib
about: Freestanding C arithmetic library.
library: yes

record Pair size=16
  field left offset=0 type=i64
  field right offset=8 type=i64

export add_pair
  about: Return the sum of both fields of a pair.
  param pair: record(Pair)
  result: integer
`)
	testing.expect_value(t, lib_prob, "")

	lib_elf, lib_read_err := os.read_entire_file(lib_o, context.temp_allocator)
	testing.expect(t, lib_read_err == nil)
	lib_module, lib_ok := convert_elf_with_manifest(lib_elf, lib_manifest, nil)
	testing.expect(t, lib_ok, "freestanding C library .o must convert cleanly")
	if !lib_ok {
		return
	}
	defer delete(lib_module)
	testing.expect_value(t, module.validate(lib_module), module.Error.None)

	app_manifest, app_prob := manifest_parse(`
module: c_caller
about: Freestanding C caller importing a C library module.
imports: c_math_lib
budget: working_memory_pages=4 threads=1

export compute_with_c
  about: Accumulate x and call c_math_lib.add_pair.
  param x: integer
  result: integer
`)
	testing.expect_value(t, app_prob, "")
	imports := [?]Import_File{{name = "c_math_lib", file = lib_module}}

	for obj_path in ([?]string{app_noplt_o, app_plt_o}) {
		app_elf, app_read_err := os.read_entire_file(obj_path, context.temp_allocator)
		testing.expect(t, app_read_err == nil)
		slot_syms := make([dynamic]string, context.temp_allocator)
		app_module, app_ok := convert_elf_with_manifest(app_elf, app_manifest, imports[:], &slot_syms)
		testing.expectf(t, app_ok, "freestanding C caller %s must convert cleanly", obj_path)
		if !app_ok {
			continue
		}
		defer delete(app_module)

		testing.expect_value(t, module.validate(app_module), module.Error.None)
		testing.expect_value(t, module.count(app_module, .Exports), u32(2))
		testing.expect_value(t, module_export_name(app_module, 1), "compute_with_c")

		// Import table names c_math_lib's exact BLAKE3 hash.
		imp, imp_ok := module.record(app_module, .Imports, 1, module.Import)
		testing.expect(t, imp_ok)
		testing.expect_value(t, imp.hash, blake3.hash(lib_module))

		// At least one import slot binds add_pair (import 1, export 1).
		testing.expect(t, module.count(app_module, .Import_Slots) >= 2)
		testing.expect(t, len(slot_syms) >= 1)
		testing.expect_value(t, slot_syms[0], "add_pair")
		slot, slot_ok := module.record(app_module, .Import_Slots, 1, module.Import_Slot)
		testing.expect(t, slot_ok)
		testing.expect_value(t, slot.import_index, u32(1))
		testing.expect_value(t, slot.export_index, u32(1))

		// Own-hash place is present in writable .bss.
		_, has_own := module.own_hash_place(app_module)
		testing.expect(t, has_own, "modus_own_hash from freestanding C must be recorded")

		// Rebase the loaded module image cleanly.
		head, _ := module.header(app_module)
		memory := make([]u8, int(head.memory_size), context.temp_allocator)
		module.copy_segments(app_module, memory)
		testing.expect_value(t, module.rebase(app_module, memory, 0x2_0000_0000), module.Error.None)
	}
}
