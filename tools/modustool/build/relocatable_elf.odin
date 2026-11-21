// Freestanding relocatable ELF (ET_REL, .o) converter for language-neutral
// modus modules (src/md/infrastructure/language_neutral_abi.md).
//
// Any compiler that emits a freestanding System V AMD64 ET_REL object (C,
// Rust, Zig, Odin, assembly) pairs its .o file with a Module_Manifest and
// converts directly into a validated modus module file without an external
// dynamic linker.
package build

import "core:fmt"
import "core:mem"
import "core:strings"
import module "modus:contract/module"
import "modus:contract/module_file_writer"

@(private = "file")
Relocatable_Segment_Kind :: enum {
	None,
	Code,
	Read_Only,
	Read_Only_After_Load,
	Writable_Data,
	Writable_Bss,
}

@(private = "file")
Synthetic_Import_Slot :: struct {
	import_index: u32,
	export_index: u32,
	symbol_name:  string,
	needs_stub:   bool,
	slot_address: u64,
	stub_address: u64,
}

@(private = "file")
Synthetic_Defined_Slot :: struct {
	section_index: u16,
	symbol_value:  u64,
	slot_address:  u64,
}

// The x86-64 indirect jump instruction `jmpq *disp32(%rip)` is 6 bytes:
// opcode FF /4 (FF 25) followed by a signed 32-bit RIP-relative displacement.
@(private = "file")
IMPORT_STUB_SIZE :: u64(6)

// convert_elf_with_manifest converts a freestanding x86-64 relocatable ELF
// object (ET_REL) paired with a language-neutral Module_Manifest into a
// validated modus module file. It refuses ET_DYN, ET_EXEC, non-x86-64
// architectures, PT_INTERP, TLS, runtime GOT relocations, unresolved symbols,
// and mismatched export symbols.
convert_elf_with_manifest :: proc(
	elf: []u8,
	manifest: Module_Manifest,
	imports: []Import_File,
	import_slot_symbols: ^[dynamic]string = nil,
) -> (result: []u8, ok: bool) {
	name := manifest.name
	if !module_name_is_valid(name) {
		return convert_fail(name, "the manifest has an invalid module name `%s`", name)
	}
	if len(manifest.imports) != len(imports) {
		return convert_fail(name, "the manifest lists %d imports, but %d import files were supplied", len(manifest.imports), len(imports))
	}
	for expected_name, index in manifest.imports {
		if imports[index].name != expected_name {
			return convert_fail(name, "import %d is `%s`, expected `%s` from the manifest", index + 1, imports[index].name, expected_name)
		}
		if load_error := module.validate(imports[index].file); load_error != .None {
			return convert_fail(name, "import `%s` is not a valid module file (%v)", expected_name, load_error)
		}
	}

	head, head_ok := elf_read_at(elf, 0, Elf_Header)
	if !head_ok || head.magic != ELF_MAGIC || head.class != ELF_CLASS_64 || head.data != ELF_DATA_LITTLE_ENDIAN {
		return convert_fail(name, "the input is not a 64-bit little-endian ELF file")
	}
	if head.header_size < size_of(Elf_Header) {
		return convert_fail(name, "the ELF header size %d is smaller than %d bytes", head.header_size, size_of(Elf_Header))
	}
	if head.machine != ELF_MACHINE_X86_64 {
		return convert_fail(name, "the input has ELF machine %d; only x86-64 (%d) is supported", head.machine, ELF_MACHINE_X86_64)
	}
	if head.type == ELF_TYPE_SHARED {
		return convert_fail(name, "ELF shared objects (ET_DYN) are refused; pass a freestanding relocatable object (ET_REL, .o)")
	}
	if head.type != ELF_TYPE_RELOCATABLE {
		return convert_fail(name, "ELF type %d is refused; expected a relocatable object (ET_REL = %d)", head.type, ELF_TYPE_RELOCATABLE)
	}
	if head.program_header_count > 0 {
		for i in 0 ..< u64(head.program_header_count) {
			stride, mul_ok := checked_mul_u64(i, u64(head.program_header_size))
			offset, add_ok := checked_add_u64(head.program_header_offset, stride)
			if mul_ok && add_ok {
				if ph, ph_ok := elf_read_at(elf, offset, Elf_Program_Header); ph_ok && ph.type == ELF_PROGRAM_INTERPRETER {
					return convert_fail(name, "a dynamic linker interpreter (PT_INTERP) is not in the module contract")
				}
			}
		}
		return convert_fail(name, "a relocatable object (ET_REL) must not carry program headers (found %d)", head.program_header_count)
	}
	if head.section_header_count == 0 {
		return convert_fail(name, "the relocatable object has no section headers")
	}
	if head.section_header_size < size_of(Elf_Section_Header) {
		return convert_fail(name, "the ELF section header size %d is smaller than %d bytes", head.section_header_size, size_of(Elf_Section_Header))
	}

	sections := make([]Elf_Section_Header, int(head.section_header_count), context.temp_allocator)
	for i in 0 ..< u64(head.section_header_count) {
		stride, mul_ok := checked_mul_u64(i, u64(head.section_header_size))
		offset, add_ok := checked_add_u64(head.section_header_offset, stride)
		if !mul_ok || !add_ok {
			return convert_fail(name, "section header %d offset overflows", i)
		}
		section, read_ok := elf_read_at(elf, offset, Elf_Section_Header)
		if !read_ok {
			return convert_fail(name, "section header %d is outside the input", i)
		}
		sections[i] = section
	}
	if head.section_name_section_index == 0 || int(head.section_name_section_index) >= len(sections) {
		return convert_fail(name, "the object has no valid section name string table")
	}
	section_names := sections[head.section_name_section_index]
	if section_names.type != ELF_SECTION_STRING_TABLE {
		return convert_fail(name, "the section name table has type %d, expected string table", section_names.type)
	}
	if _, has_shstrtab := elf_section_bytes(elf, section_names); !has_shstrtab {
		return convert_fail(name, "the section name string table is outside the input")
	}

	// Find the single symbol table (.symtab) and its string table (.strtab).
	symtab_index := -1
	for section, index in sections {
		if section.type == ELF_SECTION_SYMBOLS {
			if symtab_index >= 0 {
				return convert_fail(name, "the object has two symbol tables")
			}
			symtab_index = index
		}
	}
	if symtab_index < 0 {
		return convert_fail(name, "the object has no symbol table (.symtab)")
	}
	symtab := sections[symtab_index]
	if symtab.size % size_of(Elf_Symbol) != 0 {
		return convert_fail(name, "the symbol table size %d is not a multiple of %d", symtab.size, size_of(Elf_Symbol))
	}
	symtab_bytes, has_symtab := elf_section_bytes(elf, symtab)
	if !has_symtab {
		return convert_fail(name, "the symbol table is outside the input")
	}
	if symtab.link == 0 || int(symtab.link) >= len(sections) {
		return convert_fail(name, "the symbol table has no valid string table")
	}
	strtab := sections[symtab.link]
	if strtab.type != ELF_SECTION_STRING_TABLE {
		return convert_fail(name, "the symbol string table has type %d, expected string table", strtab.type)
	}
	if _, has_strtab := elf_section_bytes(elf, strtab); !has_strtab {
		return convert_fail(name, "the symbol string table is outside the input")
	}

	symbol_count := len(symtab_bytes) / size_of(Elf_Symbol)
	symbols := make([]Elf_Symbol, symbol_count, context.temp_allocator)
	for i in 0 ..< symbol_count {
		mem.copy(&symbols[i], raw_data(symtab_bytes[i * size_of(Elf_Symbol):]), size_of(Elf_Symbol))
		if symbols[i].section_index == ELF_SECTION_INDEX_COMMON {
			sym_name, _ := elf_string_at(elf, strtab, symbols[i].name)
			return convert_fail(name, "common symbol `%s` (SHN_COMMON) is refused; compile with -fno-common", sym_name)
		}
	}

	// Classify sections and validate alignment, bounds, COMDAT groups, and forbidden sections.
	section_kinds := make([]Relocatable_Segment_Kind, len(sections), context.temp_allocator)
	for section, index in sections {
		if index == 0 || section.type == ELF_SECTION_NULL {
			continue
		}
		section_name, name_ok := elf_string_at(elf, section_names, section.name)
		if !name_ok {
			return convert_fail(name, "section %d name offset %d is outside the section string table", index, section.name)
		}

		// Validate COMDAT section groups (SHT_GROUP) without copying their metadata.
		if section.type == ELF_SECTION_GROUP {
			group_bytes, group_ok := elf_section_bytes(elf, section)
			if !group_ok || len(group_bytes) < 4 || len(group_bytes) % 4 != 0 {
				return convert_fail(name, "section group %s is malformed or outside the input", section_name)
			}
			for at := 4; at < len(group_bytes); at += 4 {
				member: u32
				mem.copy(&member, raw_data(group_bytes[at:]), 4)
				if int(member) >= len(sections) {
					return convert_fail(name, "section group %s names section %d outside the section table", section_name, member)
				}
			}
			continue
		}

		if section.flags & ELF_SECTION_FLAG_ALLOCATED != 0 && section.flags & ELF_SECTION_FLAG_TLS != 0 && section.size > 0 {
			return convert_fail(name, "section %s holds thread-local data (SHF_TLS), which is not in the module contract", section_name)
		}
		switch section.type {
		case ELF_SECTION_INIT_ARRAY, ELF_SECTION_FINI_ARRAY, ELF_SECTION_PREINIT_ARRAY:
			if section.size > 0 {
				return convert_fail(name, "section %s holds code that runs before the entry; a module has none", section_name)
			}
			continue
		case ELF_SECTION_REL, ELF_SECTION_RELR:
			if section.size > 0 && int(section.info) < len(sections) && sections[section.info].flags & ELF_SECTION_FLAG_ALLOCATED != 0 {
				return convert_fail(name, "section %s uses unsupported relocation format type %d; x86-64 objects must use SHT_RELA", section_name, section.type)
			}
			continue
		}

		if section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 || strings.has_prefix(section_name, ".eh_frame") {
			continue
		}
		if section.type != ELF_SECTION_PROGRAM_DATA && section.type != ELF_SECTION_NO_BITS {
			continue
		}

		align := max(section.alignment, u64(1))
		if align & (align - 1) != 0 || align > module.PAGE_SIZE {
			return convert_fail(name, "section %s has alignment %d; alignment must be a power of two up to %d", section_name, section.alignment, module.PAGE_SIZE)
		}
		if section.type == ELF_SECTION_PROGRAM_DATA {
			if _, has_bytes := elf_section_bytes(elf, section); !has_bytes {
				return convert_fail(name, "section %s is outside the input", section_name)
			}
		}

		is_write := section.flags & ELF_SECTION_FLAG_WRITE != 0
		is_exec := section.flags & ELF_SECTION_FLAG_EXECUTE != 0
		if is_write && is_exec {
			return convert_fail(name, "section %s is both writable and executable", section_name)
		}
		switch {
		case is_exec:
			if section.type == ELF_SECTION_NO_BITS && section.size > 0 {
				return convert_fail(name, "executable section %s has type SHT_NOBITS", section_name)
			}
			section_kinds[index] = .Code
		case !is_write:
			section_kinds[index] = .Read_Only
		case section_name == ".data.rel.ro" || strings.has_prefix(section_name, ".data.rel.ro."):
			section_kinds[index] = .Read_Only_After_Load
		case section.type == ELF_SECTION_NO_BITS:
			section_kinds[index] = .Writable_Bss
		case:
			section_kinds[index] = .Writable_Data
		}
	}

	// Pass 1: Validate all SHT_RELA sections targeting laid-out sections and
	// discover synthetic import slots, call stubs, and defined GOT slots.
	synthetic_imports := make([dynamic]Synthetic_Import_Slot, context.temp_allocator)
	synthetic_defined := make([dynamic]Synthetic_Defined_Slot, context.temp_allocator)

	find_or_add_import_slot :: proc(list: ^[dynamic]Synthetic_Import_Slot, import_index, export_index: u32, symbol_name: string, needs_stub: bool) -> int {
		for &item, idx in list {
			if item.import_index == import_index && item.export_index == export_index {
				if needs_stub {
					item.needs_stub = true
				}
				return idx
			}
		}
		append(list, Synthetic_Import_Slot{import_index = import_index, export_index = export_index, symbol_name = symbol_name, needs_stub = needs_stub})
		return len(list) - 1
	}

	find_or_add_defined_slot :: proc(list: ^[dynamic]Synthetic_Defined_Slot, section_index: u16, symbol_value: u64) -> int {
		for item, idx in list {
			if item.section_index == section_index && item.symbol_value == symbol_value {
				return idx
			}
		}
		append(list, Synthetic_Defined_Slot{section_index = section_index, symbol_value = symbol_value})
		return len(list) - 1
	}

	for section in sections {
		if section.type != ELF_SECTION_RELA {
			continue
		}
		section_name, _ := elf_string_at(elf, section_names, section.name)
		if int(section.info) >= len(sections) {
			return convert_fail(name, "relocation section %s targets section %d outside the section table", section_name, section.info)
		}
		target_kind := section_kinds[section.info]
		if target_kind == .None {
			continue
		}
		target := sections[section.info]
		if target.type == ELF_SECTION_NO_BITS {
			return convert_fail(name, "relocation section %s targets SHT_NOBITS section %d", section_name, section.info)
		}
		if int(section.link) != symtab_index {
			return convert_fail(name, "relocation section %s links to section %d instead of .symtab (%d)", section_name, section.link, symtab_index)
		}
		if section.size % size_of(Elf_Rela) != 0 {
			return convert_fail(name, "relocation section %s size %d is not a multiple of %d", section_name, section.size, size_of(Elf_Rela))
		}
		rela_bytes, has_rela := elf_section_bytes(elf, section)
		if !has_rela {
			return convert_fail(name, "relocation section %s is outside the input", section_name)
		}
		for i := 0; i < len(rela_bytes) / size_of(Elf_Rela); i += 1 {
			rela: Elf_Rela
			mem.copy(&rela, raw_data(rela_bytes[i * size_of(Elf_Rela):]), size_of(Elf_Rela))
			reloc_type := u32(rela.info)
			sym_index := rela.info >> 32
			if sym_index >= u64(len(symbols)) {
				return convert_fail(name, "relocation %d in %s names symbol index %d outside .symtab (%d symbols)", i, section_name, sym_index, len(symbols))
			}
			sym := symbols[sym_index]
			sym_name, _ := elf_string_at(elf, strtab, sym.name)

			if reloc_type == ELF_RELOCATION_NONE {
				continue
			}
			if elf_relocation_is_tls(reloc_type) {
				return convert_fail(name, "thread-local relocation type %d (symbol `%s`) in %s is not in the module contract", reloc_type, sym_name, section_name)
			}
			if elf_relocation_is_forbidden_got(reloc_type) {
				return convert_fail(name, "forbidden GOT or dynamic relocation type %d (symbol `%s`) in %s requires a runtime GOT or dynamic linker", reloc_type, sym_name, section_name)
			}

			patch_size: u64
			switch reloc_type {
			case ELF_RELOCATION_64, ELF_RELOCATION_PC64:
				patch_size = 8
			case ELF_RELOCATION_PC32, ELF_RELOCATION_PLT32, ELF_RELOCATION_GOTPCREL, ELF_RELOCATION_GOTPCRELX, ELF_RELOCATION_REX_GOTPCRELX:
				patch_size = 4
			case ELF_RELOCATION_32, ELF_RELOCATION_32S, ELF_RELOCATION_16, ELF_RELOCATION_PC16, ELF_RELOCATION_8, ELF_RELOCATION_PC8:
				return convert_fail(name, "non-PIC relocation type %d (symbol `%s`) in %s is refused; compile with -fPIC", reloc_type, sym_name, section_name)
			case:
				return convert_fail(name, "unsupported relocation type %d (symbol `%s`) in %s", reloc_type, sym_name, section_name)
			}

			if rela.offset > target.size || patch_size > target.size - rela.offset {
				return convert_fail(name, "relocation %d in %s at offset %x exceeds target section size %x", i, section_name, rela.offset, target.size)
			}

			if sym.section_index == ELF_SECTION_INDEX_UNDEFINED {
				import_index, export_index, found := find_imported_export(imports, sym_name)
				if !found {
					return convert_fail(name, "unresolved undefined symbol `%s` in %s: no import exports it", sym_name, section_name)
				}
				switch reloc_type {
				case ELF_RELOCATION_64:
					if target_kind != .Read_Only_After_Load && target_kind != .Writable_Data {
						return convert_fail(name, "text or read-only relocation against imported symbol `%s` in %s is forbidden", sym_name, section_name)
					}
					if rela.addend != 0 {
						return convert_fail(name, "import slot for `%s` in %s has non-zero addend %d; an import slot binds an exact export address", sym_name, section_name, rela.addend)
					}
				case ELF_RELOCATION_PLT32:
					if rela.addend != -4 {
						return convert_fail(name, "PLT32 call to imported symbol `%s` in %s has addend %d, expected -4", sym_name, section_name, rela.addend)
					}
					find_or_add_import_slot(&synthetic_imports, import_index, export_index, sym_name, true)
				case ELF_RELOCATION_GOTPCREL, ELF_RELOCATION_GOTPCRELX, ELF_RELOCATION_REX_GOTPCRELX:
					if rela.addend != -4 {
						return convert_fail(name, "indirect slot relocation to imported symbol `%s` in %s has addend %d, expected -4", sym_name, section_name, rela.addend)
					}
					find_or_add_import_slot(&synthetic_imports, import_index, export_index, sym_name, false)
				case ELF_RELOCATION_PC32, ELF_RELOCATION_PC64:
					return convert_fail(name, "PC-relative relocation type %d against imported symbol `%s` in %s cannot be bound directly", reloc_type, sym_name, section_name)
				}
			} else {
				if sym.section_index >= ELF_SECTION_INDEX_RESERVED_LOW || int(sym.section_index) >= len(sections) {
					return convert_fail(name, "relocation in %s against symbol `%s` names invalid section index 0x%x", section_name, sym_name, sym.section_index)
				}
				if section_kinds[sym.section_index] == .None {
					return convert_fail(name, "relocation in %s against symbol `%s` targets non-allocated section %d", section_name, sym_name, sym.section_index)
				}
				if sym.value > sections[sym.section_index].size {
					return convert_fail(name, "symbol `%s` offset %x exceeds its section size %x", sym_name, sym.value, sections[sym.section_index].size)
				}
				switch reloc_type {
				case ELF_RELOCATION_64:
					if target_kind != .Read_Only_After_Load && target_kind != .Writable_Data {
						return convert_fail(name, "text or read-only absolute relocation (R_X86_64_64) for `%s` in %s is forbidden", sym_name, section_name)
					}
				case ELF_RELOCATION_GOTPCREL, ELF_RELOCATION_GOTPCRELX, ELF_RELOCATION_REX_GOTPCRELX:
					if rela.addend != -4 {
						return convert_fail(name, "GOTPCREL relocation for `%s` in %s has addend %d, expected -4", sym_name, section_name, rela.addend)
					}
					find_or_add_defined_slot(&synthetic_defined, sym.section_index, sym.value)
				}
			}
		}
	}

	// Pass 2: Assign deterministic page-aligned segment layout.
	section_offsets := make([]u64, len(sections), context.temp_allocator)
	images := make([dynamic]Segment_Image, context.temp_allocator)
	memory_cursor: u64 = 0

	layout_sections_of_kind :: proc(sections: []Elf_Section_Header, kinds: []Relocatable_Segment_Kind, target: Relocatable_Segment_Kind, base: u64, cursor: ^u64, section_offsets: []u64) -> bool {
		for section, index in sections {
			if kinds[index] != target {
				continue
			}
			align := max(section.alignment, u64(1))
			aligned, align_ok := align_forward_checked_u64(cursor^, align)
			if !align_ok {
				return false
			}
			section_offsets[index] = base + aligned
			next, add_ok := checked_add_u64(aligned, section.size)
			if !add_ok {
				return false
			}
			cursor^ = next
		}
		return true
	}

	// 1. Code segment (Read, Execute).
	code_segment_index := -1
	{
		code_base := memory_cursor
		code_size: u64 = 0
		if !layout_sections_of_kind(sections, section_kinds, .Code, code_base, &code_size, section_offsets) {
			return convert_fail(name, "code segment layout overflows 64 bits")
		}
		stub_count := 0
		for item in synthetic_imports {
			if item.needs_stub {
				stub_count += 1
			}
		}
		if stub_count > 0 {
			aligned, align_ok := align_forward_checked_u64(code_size, 8)
			if !align_ok {
				return convert_fail(name, "code stub alignment overflows 64 bits")
			}
			code_size = aligned
			for &item in synthetic_imports {
				if !item.needs_stub {
					continue
				}
				item.stub_address = code_base + code_size
				next, add_ok := checked_add_u64(code_size, IMPORT_STUB_SIZE)
				if !add_ok {
					return convert_fail(name, "code stub size overflows 64 bits")
				}
				code_size = next
			}
		}
		if code_size > 0 {
			mem_size, mem_ok := align_forward_checked_u64(code_size, module.PAGE_SIZE)
			if !mem_ok {
				return convert_fail(name, "code segment memory size overflows")
			}
			code_segment_index = len(images)
			append(&images, Segment_Image {
				record = {memory_offset = code_base, memory_size = mem_size, flags = {.Read, .Execute}},
				data   = make([]u8, int(code_size), context.temp_allocator),
			})
			next_cursor, cur_ok := checked_add_u64(code_base, mem_size)
			if !cur_ok {
				return convert_fail(name, "module memory size overflows")
			}
			memory_cursor = next_cursor
		}
	}

	// 2. Read-only data segment (Read).
	ro_segment_index := -1
	{
		ro_base := memory_cursor
		ro_size: u64 = 0
		if !layout_sections_of_kind(sections, section_kinds, .Read_Only, ro_base, &ro_size, section_offsets) {
			return convert_fail(name, "read-only segment layout overflows 64 bits")
		}
		if ro_size > 0 {
			mem_size, mem_ok := align_forward_checked_u64(ro_size, module.PAGE_SIZE)
			if !mem_ok {
				return convert_fail(name, "read-only segment memory size overflows")
			}
			ro_segment_index = len(images)
			append(&images, Segment_Image {
				record = {memory_offset = ro_base, memory_size = mem_size, flags = {.Read}},
				data   = make([]u8, int(ro_size), context.temp_allocator),
			})
			next_cursor, cur_ok := checked_add_u64(ro_base, mem_size)
			if !cur_ok {
				return convert_fail(name, "module memory size overflows")
			}
			memory_cursor = next_cursor
		}
	}

	// 3. Read-only-after-load segment (Read, Write, Read_Only_After_Load).
	relro_segment_index := -1
	{
		relro_base := memory_cursor
		relro_size: u64 = 0
		if !layout_sections_of_kind(sections, section_kinds, .Read_Only_After_Load, relro_base, &relro_size, section_offsets) {
			return convert_fail(name, "relro segment layout overflows 64 bits")
		}
		if len(synthetic_imports) > 0 || len(synthetic_defined) > 0 {
			aligned, align_ok := align_forward_checked_u64(relro_size, 8)
			if !align_ok {
				return convert_fail(name, "synthetic slot alignment overflows 64 bits")
			}
			relro_size = aligned
			for &item in synthetic_imports {
				item.slot_address = relro_base + relro_size
				next, add_ok := checked_add_u64(relro_size, 8)
				if !add_ok {
					return convert_fail(name, "import slot layout overflows 64 bits")
				}
				relro_size = next
			}
			for &item in synthetic_defined {
				item.slot_address = relro_base + relro_size
				next, add_ok := checked_add_u64(relro_size, 8)
				if !add_ok {
					return convert_fail(name, "rebased slot layout overflows 64 bits")
				}
				relro_size = next
			}
		}
		if relro_size > 0 {
			mem_size, mem_ok := align_forward_checked_u64(relro_size, module.PAGE_SIZE)
			if !mem_ok {
				return convert_fail(name, "relro segment memory size overflows")
			}
			relro_segment_index = len(images)
			append(&images, Segment_Image {
				record = {memory_offset = relro_base, memory_size = mem_size, flags = {.Read, .Write, .Read_Only_After_Load}},
				data   = make([]u8, int(relro_size), context.temp_allocator),
			})
			next_cursor, cur_ok := checked_add_u64(relro_base, mem_size)
			if !cur_ok {
				return convert_fail(name, "module memory size overflows")
			}
			memory_cursor = next_cursor
		}
	}

	// 4. Writable data + BSS segment (Read, Write).
	data_segment_index := -1
	{
		data_base := memory_cursor
		data_file_size: u64 = 0
		if !layout_sections_of_kind(sections, section_kinds, .Writable_Data, data_base, &data_file_size, section_offsets) {
			return convert_fail(name, "writable data segment layout overflows 64 bits")
		}
		total_data_size := data_file_size
		if !layout_sections_of_kind(sections, section_kinds, .Writable_Bss, data_base, &total_data_size, section_offsets) {
			return convert_fail(name, "bss segment layout overflows 64 bits")
		}
		if total_data_size > 0 {
			mem_size, mem_ok := align_forward_checked_u64(total_data_size, module.PAGE_SIZE)
			if !mem_ok {
				return convert_fail(name, "writable data segment memory size overflows")
			}
			data_segment_index = len(images)
			append(&images, Segment_Image {
				record = {memory_offset = data_base, memory_size = mem_size, flags = {.Read, .Write}},
				data   = make([]u8, int(data_file_size), context.temp_allocator),
			})
			next_cursor, cur_ok := checked_add_u64(data_base, mem_size)
			if !cur_ok {
				return convert_fail(name, "module memory size overflows")
			}
			memory_cursor = next_cursor
		}
	}

	segment_for_kind :: proc(kind: Relocatable_Segment_Kind, code_i, ro_i, relro_i, data_i: int) -> int {
		switch kind {
		case .None:
			return -1
		case .Code:
			return code_i
		case .Read_Only:
			return ro_i
		case .Read_Only_After_Load:
			return relro_i
		case .Writable_Data, .Writable_Bss:
			return data_i
		}
		return -1
	}

	// Pass 3: Copy section bytes into their segment images.
	for section, index in sections {
		kind := section_kinds[index]
		if kind == .None || section.type != ELF_SECTION_PROGRAM_DATA || section.size == 0 {
			continue
		}
		seg_index := segment_for_kind(kind, code_segment_index, ro_segment_index, relro_segment_index, data_segment_index)
		seg := &images[seg_index]
		into := section_offsets[index] - seg.record.memory_offset
		copy(seg.data[into:], elf[section.offset:][:section.size])
	}

	// Emit synthetic import slots, call stubs, and defined rebased slots.
	rebases := make([dynamic]u64, context.temp_allocator)
	import_slot_records := make([dynamic]module.Import_Slot, context.temp_allocator)

	for item in synthetic_imports {
		append(&import_slot_records, module.Import_Slot {
			memory_offset = item.slot_address,
			import_index  = item.import_index,
			export_index  = item.export_index,
		})
		if import_slot_symbols != nil {
			append(import_slot_symbols, item.symbol_name)
		}
		if item.needs_stub {
			disp := i64(item.slot_address) - i64(item.stub_address + IMPORT_STUB_SIZE)
			if disp < i64(min(i32)) || disp > i64(max(i32)) {
				return convert_fail(name, "import stub for `%s` exceeds 32-bit RIP-relative range", item.symbol_name)
			}
			disp32 := i32(disp)
			code_seg := &images[code_segment_index]
			into := item.stub_address - code_seg.record.memory_offset
			code_seg.data[into + 0] = 0xFF
			code_seg.data[into + 1] = 0x25
			mem.copy(raw_data(code_seg.data[into + 2:]), &disp32, 4)
		}
	}
	for item in synthetic_defined {
		target_address := section_offsets[item.section_index] + item.symbol_value
		if !write_segment_word(images[:], item.slot_address, target_address) {
			return convert_fail(name, "cannot write rebased slot at offset %x", item.slot_address)
		}
		append(&rebases, item.slot_address)
	}

	// Apply all section relocations.
	for section in sections {
		if section.type != ELF_SECTION_RELA {
			continue
		}
		target_kind := section_kinds[section.info]
		if target_kind == .None {
			continue
		}
		section_name, _ := elf_string_at(elf, section_names, section.name)
		target_seg_index := segment_for_kind(target_kind, code_segment_index, ro_segment_index, relro_segment_index, data_segment_index)
		target_seg := &images[target_seg_index]
		rela_bytes, _ := elf_section_bytes(elf, section)

		for i := 0; i < len(rela_bytes) / size_of(Elf_Rela); i += 1 {
			rela: Elf_Rela
			mem.copy(&rela, raw_data(rela_bytes[i * size_of(Elf_Rela):]), size_of(Elf_Rela))
			reloc_type := u32(rela.info)
			if reloc_type == ELF_RELOCATION_NONE {
				continue
			}
			sym := symbols[rela.info >> 32]
			sym_name, _ := elf_string_at(elf, strtab, sym.name)
			patch_address := section_offsets[section.info] + rela.offset
			patch_in_seg := patch_address - target_seg.record.memory_offset

			if sym.section_index == ELF_SECTION_INDEX_UNDEFINED {
				import_index, export_index, _ := find_imported_export(imports, sym_name)
				switch reloc_type {
				case ELF_RELOCATION_64:
					if !write_segment_word(images[:], patch_address, 0) {
						return convert_fail(name, "import slot for `%s` at offset %x is not aligned in writable data", sym_name, patch_address)
					}
					append(&import_slot_records, module.Import_Slot{memory_offset = patch_address, import_index = import_index, export_index = export_index})
					if import_slot_symbols != nil {
						append(import_slot_symbols, sym_name)
					}
				case ELF_RELOCATION_PLT32:
					slot_idx := find_or_add_import_slot(&synthetic_imports, import_index, export_index, sym_name, true)
					stub_address := synthetic_imports[slot_idx].stub_address
					delta := i64(stub_address) + rela.addend - i64(patch_address)
					if delta < i64(min(i32)) || delta > i64(max(i32)) {
						return convert_fail(name, "PLT32 displacement to `%s` in %s overflows 32 bits", sym_name, section_name)
					}
					delta32 := i32(delta)
					mem.copy(raw_data(target_seg.data[patch_in_seg:]), &delta32, 4)
				case ELF_RELOCATION_GOTPCREL, ELF_RELOCATION_GOTPCRELX, ELF_RELOCATION_REX_GOTPCRELX:
					slot_idx := find_or_add_import_slot(&synthetic_imports, import_index, export_index, sym_name, false)
					slot_address := synthetic_imports[slot_idx].slot_address
					delta := i64(slot_address) + rela.addend - i64(patch_address)
					if delta < i64(min(i32)) || delta > i64(max(i32)) {
						return convert_fail(name, "GOTPCREL displacement to `%s` in %s overflows 32 bits", sym_name, section_name)
					}
					delta32 := i32(delta)
					mem.copy(raw_data(target_seg.data[patch_in_seg:]), &delta32, 4)
				}
			} else {
				sym_address := section_offsets[sym.section_index] + sym.value
				switch reloc_type {
				case ELF_RELOCATION_64:
					value := u64(i64(sym_address) + rela.addend)
					if !write_segment_word(images[:], patch_address, value) {
						return convert_fail(name, "rebase for `%s` at offset %x is not aligned in writable data", sym_name, patch_address)
					}
					append(&rebases, patch_address)
				case ELF_RELOCATION_PC32, ELF_RELOCATION_PLT32:
					delta := i64(sym_address) + rela.addend - i64(patch_address)
					if delta < i64(min(i32)) || delta > i64(max(i32)) {
						return convert_fail(name, "PC32/PLT32 displacement to `%s` in %s overflows 32 bits", sym_name, section_name)
					}
					delta32 := i32(delta)
					mem.copy(raw_data(target_seg.data[patch_in_seg:]), &delta32, 4)
				case ELF_RELOCATION_PC64:
					delta64 := i64(sym_address) + rela.addend - i64(patch_address)
					mem.copy(raw_data(target_seg.data[patch_in_seg:]), &delta64, 8)
				case ELF_RELOCATION_GOTPCREL, ELF_RELOCATION_GOTPCRELX, ELF_RELOCATION_REX_GOTPCRELX:
					slot_idx := find_or_add_defined_slot(&synthetic_defined, sym.section_index, sym.value)
					slot_address := synthetic_defined[slot_idx].slot_address
					delta := i64(slot_address) + rela.addend - i64(patch_address)
					if delta < i64(min(i32)) || delta > i64(max(i32)) {
						return convert_fail(name, "GOTPCREL displacement to `%s` in %s overflows 32 bits", sym_name, section_name)
					}
					delta32 := i32(delta)
					mem.copy(raw_data(target_seg.data[patch_in_seg:]), &delta32, 4)
				}
			}
		}
	}

	// Pass 4: Resolve exports from .symtab (must be global/weak STT_FUNC in a .Code section).
	export_parts := make([dynamic]module_file_writer.Export_Part, context.temp_allocator)
	for export_description in manifest.description.exports {
		code_offset: u64
		found := false
		for sym in symbols {
			if sym.section_index == ELF_SECTION_INDEX_UNDEFINED || sym.section_index >= ELF_SECTION_INDEX_RESERVED_LOW {
				continue
			}
			sym_name, str_ok := elf_string_at(elf, strtab, sym.name)
			if !str_ok || sym_name != export_description.name {
				continue
			}
			binding := sym.info >> 4
			sym_type := sym.info & 0xF
			if binding == ELF_SYMBOL_BINDING_LOCAL {
				return convert_fail(name, "export `%s` matches a local symbol; exported functions must have global visibility", export_description.name)
			}
			if sym_type != ELF_SYMBOL_FUNCTION {
				return convert_fail(name, "export `%s` is not a function symbol (ELF symbol type %d)", export_description.name, sym_type)
			}
			if int(sym.section_index) >= len(sections) || section_kinds[sym.section_index] != .Code {
				return convert_fail(name, "export `%s` is not in an executable code section", export_description.name)
			}
			if sym.value >= sections[sym.section_index].size {
				return convert_fail(name, "export `%s` offset %x is past the end of its code section (%x)", export_description.name, sym.value, sections[sym.section_index].size)
			}
			if found {
				return convert_fail(name, "export `%s` matches two global function symbols", export_description.name)
			}
			code_offset = section_offsets[sym.section_index] + sym.value
			found = true
		}
		if !found {
			return convert_fail(name, "export `%s` is not defined as a global function in the object", export_description.name)
		}
		append(&export_parts, export_part_from_description(export_description, code_offset))
	}

	// Resolve optional own-hash place (`modus_own_hash`).
	own_hash_place: u64
	has_own_hash := false
	for sym in symbols {
		if sym.section_index == ELF_SECTION_INDEX_UNDEFINED || sym.section_index >= ELF_SECTION_INDEX_RESERVED_LOW {
			continue
		}
		sym_name, str_ok := elf_string_at(elf, strtab, sym.name)
		if !str_ok || sym_name != module.OWN_HASH_PLACE_SYMBOL {
			continue
		}
		if has_own_hash {
			return convert_fail(name, "the object defines `%s` twice; one module has one own-hash place", module.OWN_HASH_PLACE_SYMBOL)
		}
		if sym.size != module.HASH_SIZE {
			return convert_fail(name, "symbol `%s` has %d bytes; the own-hash place requires %d bytes", module.OWN_HASH_PLACE_SYMBOL, sym.size, module.HASH_SIZE)
		}
		kind := int(sym.section_index) < len(sections) ? section_kinds[sym.section_index] : .None
		if kind != .Writable_Data && kind != .Writable_Bss && kind != .Read_Only_After_Load {
			return convert_fail(name, "symbol `%s` is not in a writable non-executable section", module.OWN_HASH_PLACE_SYMBOL)
		}
		if sym.value > sections[sym.section_index].size || module.HASH_SIZE > sections[sym.section_index].size - sym.value {
			return convert_fail(name, "symbol `%s` extends past the end of its section", module.OWN_HASH_PLACE_SYMBOL)
		}
		own_hash_place = section_offsets[sym.section_index] + sym.value
		has_own_hash = true
	}

	// Resolve record stream places if any were declared.
	output_places := make([]u64, len(manifest.description.record_outputs), context.temp_allocator)
	for item, index in manifest.description.record_outputs {
		place, place_ok := relocatable_record_stream_place(name, elf, strtab, symbols, sections, section_kinds, section_offsets, item.package_name, item.name)
		if !place_ok {
			return nil, false
		}
		output_places[index] = place
	}
	input_places := make([]u64, len(manifest.description.record_inputs), context.temp_allocator)
	for item, index in manifest.description.record_inputs {
		place, place_ok := relocatable_record_stream_place(name, elf, strtab, symbols, sections, section_kinds, section_offsets, item.package_name, item.name)
		if !place_ok {
			return nil, false
		}
		input_places[index] = place
	}

	// Fill import memory sizes for budget accounting when not pre-populated.
	description := manifest.description
	if description.budget.stated && len(description.budget.import_memory_sizes) == 0 && len(imports) > 0 {
		import_sizes := make([]u64, len(imports), context.temp_allocator)
		for item, index in imports {
			import_head, _ := module.header(item.file)
			import_sizes[index] = import_head.memory_size
		}
		description.budget.import_memory_sizes = import_sizes
	}

	output := module_parts_finalize(
		name,
		images[:],
		memory_cursor,
		description,
		export_parts[:],
		imports,
		import_slot_records[:],
		rebases[:],
		own_hash_place,
		has_own_hash,
		output_places,
		input_places,
	) or_return

	if manifest.library && !module_is_a_library_check(name, output) {
		delete(output)
		return nil, false
	}
	return output, true
}

@(private = "file")
relocatable_record_stream_place :: proc(
	module_name: string,
	elf: []u8,
	strtab: Elf_Section_Header,
	symbols: []Elf_Symbol,
	sections: []Elf_Section_Header,
	section_kinds: []Relocatable_Segment_Kind,
	section_offsets: []u64,
	package_name: string,
	stream_name: string,
) -> (place: u64, ok: bool) {
	found := false
	for sym in symbols {
		if sym.section_index == ELF_SECTION_INDEX_UNDEFINED || sym.section_index >= ELF_SECTION_INDEX_RESERVED_LOW {
			continue
		}
		sym_name, str_ok := elf_string_at(elf, strtab, sym.name)
		if !str_ok {
			continue
		}
		matched := sym_name == stream_name
		if !matched && package_name != "" {
			for sep in RECORD_STREAM_SYMBOL_SEPARATORS {
				if sym_name == strings.concatenate({package_name, sep, stream_name}, context.temp_allocator) {
					matched = true
					break
				}
			}
		}
		if !matched {
			continue
		}
		if found {
			fmt.eprintfln("modustool: convert %s: record stream `%s` matches two symbols", module_name, stream_name)
			return 0, false
		}
		kind := int(sym.section_index) < len(sections) ? section_kinds[sym.section_index] : .None
		if kind != .Writable_Data && kind != .Writable_Bss {
			fmt.eprintfln("modustool: convert %s: record stream `%s` is not in a writable data segment", module_name, stream_name)
			return 0, false
		}
		address := section_offsets[sym.section_index] + sym.value
		if sym.size < module.RECORD_STREAM_PLACE_SIZE || address % module.RECORD_STREAM_PLACE_SIZE != 0 {
			fmt.eprintfln("modustool: convert %s: record stream `%s` must be aligned to and at least %d bytes", module_name, stream_name, module.RECORD_STREAM_PLACE_SIZE)
			return 0, false
		}
		place, found = address, true
	}
	return place, true
}
