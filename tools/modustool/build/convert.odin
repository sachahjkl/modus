package build

import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:strings"

// An import of the module that convert writes: the file of the imported module.
Import_File :: struct {
	name: string,
	file: []u8,
}

Segment_Image :: struct {
	record: module.Segment,
	data:   []u8, // The bytes of the segment from its memory_offset.
}

// The description of an export: what module.Function holds.
Export_Description :: struct {
	name:       string,
	parameters: []module.Type,
	names:      []string, // The name of each parameter.
	result:     module.Type,
	about:      string,
	text:       string, // The documentation text that the module carries: the full comment, in its Markdown.
	markdown:   string, // The full comment, as its author wrote it: the site renders it.
	// What the type of each parameter needs (module.Function.parameter_details):
	// a Record: the number of the record, from 1, in Module_Description.records;
	// a Handle: the rights that the callee needs.
	details:             []u32,
	directions:          []module.Direction, // The direction of each Table or Bytes parameter (module.Function.parameter_directions).
	optional_parameters: u16, // Bit n: a call may leave out the Enum parameter n (module.Function.optional_parameters).
	getter_names:        []string, // The name of the getter export of each Enum parameter, "" for none: describe writes it into the detail.
	result_detail:       u32,
	error_record:        u32, // Not 0: the export gives an error record, with this record (module.Function.error_record).
	// Where the source declares it: the site links each export to its line.
	file:                string,
	line:                int,
}

// The description of a record and of its fields: the records of the module
// file writer, so that the description that the source gives is the one
// that the file holds.
Record_Description :: module_file_writer.Record_Description
Field_Description :: module_file_writer.Field_Description
Enum_Description :: module_file_writer.Enum_Description
Member_Description :: module_file_writer.Member_Description
Member_Text_Description :: module_file_writer.Member_Text_Description

// The description of a module: what its source says to a reader, and its exports.
Module_Description :: struct {
	about:          string, // One line: the first sentence of the comment of the package.
	text:           string, // The documentation text that the module carries: the comment of the package, in its Markdown.
	markdown:       string, // The comment of the package, as its author wrote it: the site renders it.
	exports:        []Export_Description,
	records:        []Record_Description, // The records that the exports, the log facts and the record streams use. Record n + 1 of the module is records[n].
	enums:          []Enum_Description, // The enums that the exports take and give. Enum n + 1 of the module is enums[n].
	member_texts:   []Member_Text_Description, // The display texts of the members, in the order of the enum, the member and the language: the table Member_Texts.
	budget:         Budget_Description, // The budget that the module asks for: the table Budget.
	category:       module.Module_Category, // The category of the row of the module; None for a module from outside the repository.
	tags:           module.Module_Tags, // The tags of the row of the module.
	facts:          []Fact_Description, // The log facts that the module writes, sorted by key (facts_merge): the table Facts.
	record_outputs: []Record_Stream_Description, // The record outputs that the module declares, sorted by name (record_streams_merge): the table Record_Outputs.
	record_inputs:  []Record_Stream_Description, // The record inputs, sorted by name: the table Record_Inputs.
}

// The parts of the budget that a source states: the record
// system.Stated_Budget of the source (src/library/modus/system,
// budget_request.odin). The tool cannot import that package, so it has
// the same fields here.
Stated_Budget :: struct {
	working_memory_pages: u64,
	processes:            u64,
	threads:              u64,
	window_width:         u64, // Pixels; 0: no window.
	window_height:        u64,
	window_least_width:   u64, // The least size of a resizable window; 0: no cut of the window pages.
	window_least_height:  u64,
	wiring_pages:         u64, // The pages of the rings of its wirings; 0: half of its pages.
}

// The budget that a module asks for, as its source states it in the
// constant BUDGET_REQUEST_NAME (describe.odin). The conversion adds the
// counted parts (budget_count.odin).
Budget_Description :: struct {
	stated:       bool, // The source has the constant: the module has the table Budget.
	parts:        Stated_Budget, // A window part that named a constant holds its value.
	window_names: [4]string, // The constant that each window part names, or "": the width, the height, the least width, the least height.
	comment:      string, // The comment before the constant, in its Markdown: the reasons of the amounts.
	// Where the source declares it: the site links the budget to its line.
	file:         string,
	line:         int,
	// The memory size of each module that the module imports, at each
	// level, each one time: module_convert reads them from their files.
	import_memory_sizes: []u64,
}

// convert_fail reports a conversion refusal with the module name and returns nil, false.
convert_fail :: proc(name: string, format: string, args: ..any) -> ([]u8, bool) {
	fmt.eprintf("modustool: convert %s: ", name)
	fmt.eprintfln(format, ..args)
	return nil, false
}

// elf_read_at reads one value of type T from elf at offset without wrapping.
elf_read_at :: proc(elf: []u8, offset: u64, $T: typeid) -> (value: T, ok: bool) {
	if offset > u64(len(elf)) || size_of(T) > u64(len(elf)) - offset {
		return {}, false
	}
	mem.copy(&value, raw_data(elf[offset:]), size_of(T))
	return value, true
}

// elf_string_at returns a NUL-terminated string inside a validated ELF string
// table section. It never scans past the end of the section or the file.
elf_string_at :: proc(elf: []u8, table: Elf_Section_Header, offset: u32) -> (value: string, ok: bool) {
	bytes, in_bounds := elf_section_bytes(elf, table)
	if !in_bounds || u64(offset) >= u64(len(bytes)) {
		return "", false
	}
	return text_until_zero(bytes, u64(offset)), true
}

// checked_add_u64 adds two u64 values and reports false on overflow.
checked_add_u64 :: proc(a, b: u64) -> (sum: u64, ok: bool) {
	total, carry := bits.add_u64(a, b, 0)
	return total, carry == 0
}

// checked_mul_u64 multiplies two u64 values and reports false on overflow.
checked_mul_u64 :: proc(a, b: u64) -> (product: u64, ok: bool) {
	high, low := bits.mul_u64(a, b)
	return low, high == 0
}

// align_forward_checked_u64 rounds value up to a power-of-two alignment and
// reports false on overflow.
align_forward_checked_u64 :: proc(value, alignment: u64) -> (aligned: u64, ok: bool) {
	if alignment <= 1 {
		return value, true
	}
	added, fits := checked_add_u64(value, alignment - 1)
	if !fits {
		return 0, false
	}
	return added & ~(alignment - 1), true
}

// write_segment_word writes 8 bytes at memory_offset in a writable,
// non-executable segment without overflowing offset arithmetic.
write_segment_word :: proc(images: []Segment_Image, memory_offset: u64, value: u64) -> bool {
	for image in images {
		if memory_offset < image.record.memory_offset {
			continue
		}
		into := memory_offset - image.record.memory_offset
		if into > u64(len(image.data)) || u64(len(image.data)) - into < 8 {
			continue
		}
		if .Write not_in image.record.flags || .Execute in image.record.flags || memory_offset % 8 != 0 {
			return false
		}
		word := value
		mem.copy(raw_data(image.data[into:]), &word, 8)
		return true
	}
	return false
}

// find_imported_export finds the 1-based (import_index, export_index) of an
// export name across the imported module files.
find_imported_export :: proc(imports: []Import_File, symbol_name: string) -> (import_index: u32, export_index: u32, found: bool) {
	if symbol_name == "" {
		return 0, 0, false
	}
	for item, index in imports {
		for candidate in 1 ..< module.count(item.file, .Exports) {
			if module_export_name(item.file, candidate) == symbol_name {
				return u32(index + 1), candidate, true
			}
		}
	}
	return 0, 0, false
}

// convert writes a module from a shared object that lld linked.
//   exports: the descriptions of the exports. Export n + 1 is exports[n].
//   imports: the modules that the undefined symbols of the object come from.
// The module binds each import by (import index, export index). The names
// are used here only, at build time.
//   import_slot_symbols: not nil: it receives the name of the symbol of each import slot,
//            one for each import slot, for the check of the declarations of the
//            importer (import_declarations.odin).
convert :: proc(name: string, elf: []u8, description: Module_Description, imports: []Import_File, import_slot_symbols: ^[dynamic]string = nil) -> (result: []u8, ok: bool) {
	exports := description.exports
	head, head_ok := elf_read_at(elf, 0, Elf_Header)
	if !head_ok || head.magic != ELF_MAGIC || head.class != ELF_CLASS_64 || head.data != ELF_DATA_LITTLE_ENDIAN {
		return convert_fail(name, "the input is not a 64-bit little-endian ELF file")
	}
	if head.header_size < size_of(Elf_Header) {
		return convert_fail(name, "the ELF header size %d is smaller than %d bytes", head.header_size, size_of(Elf_Header))
	}
	if head.type != ELF_TYPE_SHARED || head.machine != ELF_MACHINE_X86_64 {
		return convert_fail(name, "the input is not a position-independent x86-64 shared object (type %d, machine %d)", head.type, head.machine)
	}

	if head.program_header_count > 0 && head.program_header_size < size_of(Elf_Program_Header) {
		return convert_fail(name, "the ELF program header size %d is smaller than %d bytes", head.program_header_size, size_of(Elf_Program_Header))
	}
	if head.section_header_count > 0 && head.section_header_size < size_of(Elf_Section_Header) {
		return convert_fail(name, "the ELF section header size %d is smaller than %d bytes", head.section_header_size, size_of(Elf_Section_Header))
	}

	processes := make([dynamic]Elf_Program_Header, context.temp_allocator)
	for i in 0 ..< u64(head.program_header_count) {
		stride, mul_ok := checked_mul_u64(i, u64(head.program_header_size))
		offset, add_ok := checked_add_u64(head.program_header_offset, stride)
		if !mul_ok || !add_ok {
			return convert_fail(name, "program header %d offset overflows", i)
		}
		process, read_ok := elf_read_at(elf, offset, Elf_Program_Header)
		if !read_ok {
			return convert_fail(name, "program header %d is outside the input", i)
		}
		append(&processes, process)
	}
	sections := make([dynamic]Elf_Section_Header, context.temp_allocator)
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
		append(&sections, section)
	}
	if len(sections) == 0 || head.section_name_section_index == 0 || int(head.section_name_section_index) >= len(sections) {
		return convert_fail(name, "the input has no valid section name string table")
	}
	section_names := sections[head.section_name_section_index]
	if section_names.type != ELF_SECTION_STRING_TABLE {
		return convert_fail(name, "the section name table has type %d, expected string table", section_names.type)
	}
	if _, has_names := elf_section_bytes(elf, section_names); !has_names {
		return convert_fail(name, "the section name string table is outside the input")
	}

	// Segments. A module segment is one loadable segment of the input, on its
	// own pages. Its data starts as zero; only program data is copied, so that
	// no ELF structure reaches the module.
	images := make([dynamic]Segment_Image, context.temp_allocator)
	has_relro := false
	relro_start, relro_end: u64
	for process in processes {
		switch process.type {
		case ELF_PROGRAM_INTERPRETER:
			return convert_fail(name, "a dynamic linker interpreter (PT_INTERP) is not in the module contract")
		case ELF_PROGRAM_TLS:
			if process.memory_size != 0 {
				return convert_fail(name, "thread-local data is not in the module contract")
			}
		case ELF_PROGRAM_RELRO:
			end, end_ok := checked_add_u64(process.address, process.memory_size)
			if !end_ok {
				return convert_fail(name, "PT_GNU_RELRO segment address overflows")
			}
			has_relro = true
			relro_start, relro_end = process.address, end
		}
	}
	memory_size: u64
	for process, segment_index in processes {
		if process.type != ELF_PROGRAM_LOAD {
			continue
		}
		if process.file_size > process.memory_size {
			return convert_fail(name, "load segment %d has file_size %d larger than memory_size %d", segment_index, process.file_size, process.memory_size)
		}
		if process.offset > u64(len(elf)) || process.file_size > u64(len(elf)) - process.offset {
			return convert_fail(name, "load segment %d bytes are outside the input", segment_index)
		}
		if process.memory_size == 0 {
			continue
		}
		process_end, end_ok := checked_add_u64(process.address, process.memory_size)
		if !end_ok {
			return convert_fail(name, "load segment %d address range overflows", segment_index)
		}
		start := process.address & ~u64(module.PAGE_SIZE - 1)
		end, align_ok := align_forward_checked_u64(process_end, module.PAGE_SIZE)
		if !align_ok {
			return convert_fail(name, "load segment %d page alignment overflows", segment_index)
		}
		if start < memory_size {
			return convert_fail(name, "two segments of the input share a page")
		}
		memory_size = end
		data_size, data_ok := checked_add_u64(process.address - start, process.file_size)
		if !data_ok || data_size > end - start {
			return convert_fail(name, "load segment %d data size overflows its memory size", segment_index)
		}
		image := Segment_Image {
			record = {memory_offset = start, memory_size = end - start},
			data   = make([]u8, int(data_size), context.temp_allocator),
		}
		if process.flags & ELF_PROGRAM_READ != 0 {image.record.flags += {.Read}}
		if process.flags & ELF_PROGRAM_WRITE != 0 {image.record.flags += {.Write}}
		if process.flags & ELF_PROGRAM_EXECUTE != 0 {image.record.flags += {.Execute}}
		if has_relro && .Write in image.record.flags && process.address >= relro_start && process_end <= relro_end {
			image.record.flags += {.Read_Only_After_Load}
		}
		if image.record.flags & {.Write, .Execute} == {.Write, .Execute} {
			return convert_fail(name, "a segment of the input is writable and executable")
		}
		append(&images, image)
	}

	dynamic_symbols: Elf_Section_Header
	has_dynamic_symbols := false
	for section in sections {
		section_name, name_ok := elf_string_at(elf, section_names, section.name)
		if !name_ok {
			section_name = "<unnamed>"
		}
		if section.flags & ELF_SECTION_FLAG_ALLOCATED != 0 && section.flags & ELF_SECTION_FLAG_TLS != 0 && section.size > 0 {
			return convert_fail(name, "section %s holds thread-local data, which is not in the module contract", section_name)
		}
		switch section.type {
		case ELF_SECTION_INIT_ARRAY, ELF_SECTION_FINI_ARRAY, ELF_SECTION_PREINIT_ARRAY:
			if section.size > 0 {
				return convert_fail(name, "section %s holds code that runs before the entry; a module has none", section_name)
			}
		case ELF_SECTION_REL, ELF_SECTION_RELR:
			if section.flags & ELF_SECTION_FLAG_ALLOCATED != 0 && section.size > 0 {
				return convert_fail(name, "section %s uses an unsupported relocation table format (type %d); only RELA is supported", section_name, section.type)
			}
		case ELF_SECTION_DYNAMIC_SYMBOLS:
			if has_dynamic_symbols {
				return convert_fail(name, "the input has two dynamic symbol tables")
			}
			dynamic_symbols = section
			has_dynamic_symbols = true
		case ELF_SECTION_PROGRAM_DATA:
			if section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 || strings.has_prefix(section_name, ".eh_frame") {
				continue
			}
			if section.offset > u64(len(elf)) || section.size > u64(len(elf)) - section.offset {
				return convert_fail(name, "section %s is outside the input", section_name)
			}
			if section.size == 0 {
				continue
			}
			copied := false
			for image in images {
				if section.address < image.record.memory_offset {
					continue
				}
				into := section.address - image.record.memory_offset
				if into <= u64(len(image.data)) && section.size <= u64(len(image.data)) - into {
					copy(image.data[into:], elf[section.offset:][:section.size])
					copied = true
				}
			}
			if !copied {
				return convert_fail(name, "section %s is in no segment", section_name)
			}
		}
	}
	if !has_dynamic_symbols {
		return convert_fail(name, "the input has no dynamic symbol table")
	}
	if dynamic_symbols.link == 0 || int(dynamic_symbols.link) >= len(sections) {
		return convert_fail(name, "the dynamic symbol table has no valid string table")
	}
	if dynamic_symbols.size % size_of(Elf_Symbol) != 0 {
		return convert_fail(name, "the dynamic symbol table size %d is not a multiple of %d", dynamic_symbols.size, size_of(Elf_Symbol))
	}
	if _, has_dynsym_bytes := elf_section_bytes(elf, dynamic_symbols); !has_dynsym_bytes {
		return convert_fail(name, "the dynamic symbol table is outside the input")
	}
	symbol_names := sections[dynamic_symbols.link]
	if symbol_names.type != ELF_SECTION_STRING_TABLE {
		return convert_fail(name, "the dynamic symbol string table has type %d, expected string table", symbol_names.type)
	}
	if _, has_dynstr_bytes := elf_section_bytes(elf, symbol_names); !has_dynstr_bytes {
		return convert_fail(name, "the dynamic symbol string table is outside the input")
	}
	symbol_count := dynamic_symbols.size / size_of(Elf_Symbol)

	// Exports: the code offset of each is its function symbol in the input.
	export_parts := make([dynamic]module_file_writer.Export_Part, context.temp_allocator)
	for export_description in exports {
		code_offset: u64
		found := false
		for i in 0 ..< symbol_count {
			symbol, sym_ok := elf_read_at(elf, dynamic_symbols.offset + i * size_of(Elf_Symbol), Elf_Symbol)
			if !sym_ok {
				return convert_fail(name, "dynamic symbol %d is outside the input", i)
			}
			if symbol.section_index == ELF_SECTION_INDEX_UNDEFINED || symbol.section_index >= ELF_SECTION_INDEX_RESERVED_LOW {
				continue
			}
			if symbol.info & 0xF != ELF_SYMBOL_FUNCTION {
				continue
			}
			symbol_name, str_ok := elf_string_at(elf, symbol_names, symbol.name)
			if !str_ok || symbol_name != export_description.name {
				continue
			}
			if found {
				return convert_fail(name, "export %s matches two function symbols in the input", export_description.name)
			}
			code_offset, found = symbol.value, true
		}
		if !found {
			return convert_fail(name, "export %s is not a function of the input", export_description.name)
		}
		append(&export_parts, export_part_from_description(export_description, code_offset))
	}

	// Relocations: each one becomes a rebase or an import slot.
	rebases := make([dynamic]u64, context.temp_allocator)
	import_slot_records := make([dynamic]module.Import_Slot, context.temp_allocator)
	for section in sections {
		if section.type != ELF_SECTION_RELA || section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 {
			continue
		}
		if section.size % size_of(Elf_Rela) != 0 {
			return convert_fail(name, "relocation section size %d is not a multiple of %d", section.size, size_of(Elf_Rela))
		}
		if _, has_rela_bytes := elf_section_bytes(elf, section); !has_rela_bytes {
			return convert_fail(name, "a relocation section is outside the input")
		}
		for i in 0 ..< section.size / size_of(Elf_Rela) {
			relocation, rela_ok := elf_read_at(elf, section.offset + i * size_of(Elf_Rela), Elf_Rela)
			if !rela_ok {
				return convert_fail(name, "relocation %d is outside the input", i)
			}
			relocation_type := u32(relocation.info)
			symbol_index := relocation.info >> 32
			if symbol_index >= symbol_count {
				return convert_fail(name, "relocation %d names symbol index %d outside the dynamic symbol table (%d symbols)", i, symbol_index, symbol_count)
			}
			symbol, sym_ok := elf_read_at(elf, dynamic_symbols.offset + symbol_index * size_of(Elf_Symbol), Elf_Symbol)
			if !sym_ok {
				return convert_fail(name, "dynamic symbol %d is outside the input", symbol_index)
			}
			symbol_name, _ := elf_string_at(elf, symbol_names, symbol.name)
			value: u64
			switch relocation_type {
			case ELF_RELOCATION_NONE:
				continue
			case ELF_RELOCATION_RELATIVE:
				value = u64(relocation.addend)
			case ELF_RELOCATION_64, ELF_RELOCATION_GLOBAL_DATA, ELF_RELOCATION_JUMP_SLOT:
				if symbol.section_index == ELF_SECTION_INDEX_UNDEFINED {
					if relocation_type == ELF_RELOCATION_64 && relocation.addend != 0 {
						return convert_fail(name, "import slot for %s has non-zero addend %d; an import slot binds an exact export address", symbol_name, relocation.addend)
					}
					import_index, export_index, found := find_imported_export(imports, symbol_name)
					if !found {
						return convert_fail(name, "%s is not defined, and no import exports it", symbol_name)
					}
					if !write_segment_word(images[:], relocation.offset, 0) {
						return convert_fail(name, "the import slot of %s at offset %x is not in aligned writable data", symbol_name, relocation.offset)
					}
					append(&import_slot_records, module.Import_Slot{memory_offset = relocation.offset, import_index = import_index, export_index = export_index})
					if import_slot_symbols != nil {
						append(import_slot_symbols, symbol_name)
					}
					continue
				}
				if symbol.section_index >= ELF_SECTION_INDEX_RESERVED_LOW {
					return convert_fail(name, "relocation against %s targets special section index 0x%x", symbol_name, symbol.section_index)
				}
				value = symbol.value
				if relocation_type == ELF_RELOCATION_64 {
					value += u64(relocation.addend)
				}
			case:
				if elf_relocation_is_tls(relocation_type) {
					return convert_fail(name, "thread-local relocation type %d (symbol %s) is not in the module contract", relocation_type, symbol_name)
				}
				if elf_relocation_is_forbidden_got(relocation_type) {
					return convert_fail(name, "dynamic relocation type %d (symbol %s) requires a runtime GOT or dynamic linker", relocation_type, symbol_name)
				}
				return convert_fail(name, "relocation type %d (symbol %s) has no form in a module", relocation_type, symbol_name)
			}
			if !write_segment_word(images[:], relocation.offset, value) {
				return convert_fail(name, "a rebase at offset %x is not in aligned writable data", relocation.offset)
			}
			append(&rebases, relocation.offset)
		}
	}

	// The place where a loader writes the hash of the module: the variable
	// of the support package system that log_fact copies
	// (src/md/features/log_facts.md, "The record").
	own_hash_place, has_place, own_hash_ok := own_hash_place_of_elf(elf, sections[:], images[:])
	if !own_hash_ok {
		return nil, false
	}

	output_places := make([]u64, len(description.record_outputs), context.temp_allocator)
	for item, index in description.record_outputs {
		place, _, place_ok := record_stream_place_of_elf(elf, sections[:], images[:], item.package_name, item.name)
		if !place_ok {
			return nil, false
		}
		output_places[index] = place
	}
	input_places := make([]u64, len(description.record_inputs), context.temp_allocator)
	for item, index in description.record_inputs {
		place, _, place_ok := record_stream_place_of_elf(elf, sections[:], images[:], item.package_name, item.name)
		if !place_ok {
			return nil, false
		}
		input_places[index] = place
	}

	return module_parts_finalize(
		name,
		images[:],
		memory_size,
		description,
		export_parts[:],
		imports,
		import_slot_records[:],
		rebases[:],
		own_hash_place,
		has_place,
		output_places,
		input_places,
	)
}

// export_part_from_description builds a module_file_writer.Export_Part from a
// Module_Description export entry and its resolved code offset.
export_part_from_description :: proc(description: Export_Description, code_offset: u64) -> module_file_writer.Export_Part {
	return module_file_writer.Export_Part {
		name                 = description.name,
		code_offset          = code_offset,
		about                = description.about,
		text                 = description.text,
		parameters           = description.parameters,
		parameter_names      = description.names,
		parameter_details    = description.details,
		parameter_directions = description.directions,
		optional_parameters  = description.optional_parameters,
		result               = description.result,
		result_detail        = description.result_detail,
		error_record         = description.error_record,
	}
}

// module_parts_finalize checks relocation uniqueness, assembles Module_Parts,
// and writes a validated module file through module_file_writer. Both the
// linked ET_DYN converter and the freestanding ET_REL converter call this.
module_parts_finalize :: proc(
	name: string,
	images: []Segment_Image,
	memory_size: u64,
	description: Module_Description,
	export_parts: []module_file_writer.Export_Part,
	imports: []Import_File,
	import_slot_records: []module.Import_Slot,
	rebases: []u64,
	own_hash_place: u64,
	has_place: bool,
	output_places: []u64,
	input_places: []u64,
) -> (result: []u8, ok: bool) {
	// The writer takes the rebases in strictly increasing order without
	// duplicates or overlap with import slots.
	slice.sort(rebases)
	for index in 1 ..< len(rebases) {
		if rebases[index] == rebases[index - 1] {
			return convert_fail(name, "two rebases target the same offset %x", rebases[index])
		}
	}
	for slot, slot_index in import_slot_records {
		for other in import_slot_records[:slot_index] {
			if other.memory_offset == slot.memory_offset {
				return convert_fail(name, "two import slots target the same offset %x", slot.memory_offset)
			}
		}
		if _, overlap := slice.binary_search(rebases, slot.memory_offset); overlap {
			return convert_fail(name, "a rebase and an import slot both target offset %x", slot.memory_offset)
		}
	}

	if len(description.facts) > 0 && !has_place {
		return convert_fail(name, "the module writes log facts, and its object has no symbol %s: the 32-byte variable that holds the hash of the module", module.OWN_HASH_PLACE_SYMBOL)
	}

	import_hashes := make([][module.HASH_SIZE]u8, len(imports), context.temp_allocator)
	for item, index in imports {
		import_hashes[index] = blake3.hash(item.file)
	}

	fact_parts := make([]module_file_writer.Fact_Part, len(description.facts), context.temp_allocator)
	for fact, index in description.facts {
		fact_parts[index] = {key = fact.key, record_index = fact.record_index, template = fact.template, package_name = fact.package_name}
	}
	segment_parts := make([]module_file_writer.Segment_Part, len(images), context.temp_allocator)
	for image, index in images {
		segment_parts[index] = {memory_offset = image.record.memory_offset, memory_size = image.record.memory_size, flags = image.record.flags, data = image.data}
	}
	output_parts := make([]module_file_writer.Record_Output_Part, len(description.record_outputs), context.temp_allocator)
	for item, index in description.record_outputs {
		place := index < len(output_places) ? output_places[index] : 0
		output_parts[index] = {name = item.name, about = item.about, text = item.text, record_index = item.record_index, pairing = item.pairing, place = place}
	}
	input_parts := make([]module_file_writer.Record_Input_Part, len(description.record_inputs), context.temp_allocator)
	for item, index in description.record_inputs {
		place := index < len(input_places) ? input_places[index] : 0
		input_parts[index] = {name = item.name, about = item.about, text = item.text, record_index = item.record_index, terms_index = item.terms_index, wirings = item.wirings, place = place}
	}

	parts := module_file_writer.Module_Parts {
		segments           = segment_parts,
		exports            = export_parts,
		imports            = import_hashes,
		import_slots       = import_slot_records,
		rebases            = rebases,
		records            = description.records,
		enums              = description.enums,
		member_texts       = description.member_texts,
		facts              = fact_parts,
		has_own_hash_place = has_place,
		own_hash_place     = own_hash_place,
		about              = description.about,
		text               = description.text,
		record_outputs     = output_parts,
		record_inputs      = input_parts,
	}

	// The category and the tags of the row of the module (module_convert):
	// the manual reads them from the header. The start menu does not: the
	// build writes its lists from the table (start_menu_names.odin).
	parts.category, parts.tags = description.category, description.tags

	// A module whose source states no budget has no table Budget: it asks
	// for the least budget.
	if description.budget.stated {
		counted, counted_ok := budget_count(description.budget.parts, memory_size, description.budget.import_memory_sizes)
		if !counted_ok {
			return convert_fail(name, "the budget that the module asks for passes the end of 64 bits")
		}
		parts.has_budget, parts.budget = true, counted.request
	}

	size, refusal := module_file_writer.file_size_needed(parts)
	if refusal.refusal != .None {
		return convert_fail(name, "%s", module_file_refusal_text(parts, refusal))
	}
	output := make([]u8, int(size))
	_, refusal = module_file_writer.write(parts, output)
	if refusal.refusal != .None {
		delete(output)
		return convert_fail(name, "%s", module_file_refusal_text(parts, refusal))
	}
	return output, true
}

// module_file_refusal_text says why the module file writer refused the
// parts of a module, with the name of the part when it has one.
module_file_refusal_text :: proc(parts: module_file_writer.Module_Parts, refusal: module_file_writer.Refusal_Record) -> string {
	part := ""
	switch refusal.table {
	case .Exports, .Functions:
		if refusal.index < u64(len(parts.exports)) {
			part = fmt.tprintf(" (export %s)", parts.exports[refusal.index].name)
		}
	case .Records, .Fields:
		if refusal.index < u64(len(parts.records)) {
			part = fmt.tprintf(" (record %s)", parts.records[refusal.index].name)
		}
	case .Record_Outputs:
		// The last check names a row from 1; the checks of the parts an
		// index from 0.
		index := refusal.refusal == .Record_Streams_Not_Valid ? refusal.index - 1 : refusal.index
		if refusal.index != 0 || refusal.refusal != .Record_Streams_Not_Valid {
			if index < u64(len(parts.record_outputs)) {
				part = fmt.tprintf(" (record output %s)", parts.record_outputs[index].name)
			}
		}
	case .Record_Inputs:
		index := refusal.refusal == .Record_Streams_Not_Valid ? refusal.index - 1 : refusal.index
		if refusal.index != 0 || refusal.refusal != .Record_Streams_Not_Valid {
			if index < u64(len(parts.record_inputs)) {
				part = fmt.tprintf(" (record input %s)", parts.record_inputs[index].name)
			}
		}
	case .Enums, .Members:
		if refusal.index < u64(len(parts.enums)) {
			part = fmt.tprintf(" (enum %s)", parts.enums[refusal.index].name)
		}
	case .Member_Texts:
		if refusal.index < u64(len(parts.member_texts)) {
			part = fmt.tprintf(" (display text \"%s\")", parts.member_texts[refusal.index].text)
		}
	case .None, .Segments, .Imports, .Import_Slots, .Rebases, .Strings, .Documentation, .Budget, .Facts, .Own_Hash:
	}
	return fmt.tprintf("the module file writer refuses the module: %v in the table %v, part %d%s, value %d (src/library/modus/contract/module_file_writer)", refusal.refusal, refusal.table, refusal.index, part, refusal.value)
}

// own_hash_place_of_elf gives the memory offset of the own-hash place: the
// symbol module.OWN_HASH_PLACE_SYMBOL of the symbol table of the linked
// file, an object of module.HASH_SIZE bytes in a segment that the loader
// can write. found is false for a file with no such symbol: no code of the
// module reads the place, and the link dropped it. ok is false for a
// symbol that breaks a rule, which it prints.
@(private = "file")
own_hash_place_of_elf :: proc(elf: []u8, sections: []Elf_Section_Header, images: []Segment_Image) -> (memory_offset: u64, found: bool, ok: bool) {
	for section in sections {
		if section.type != ELF_SECTION_SYMBOLS || int(section.link) >= len(sections) {
			continue
		}
		symbols, has_symbols := elf_section_bytes(elf, section)
		names, has_names := elf_section_bytes(elf, sections[section.link])
		if !has_symbols || !has_names {
			continue
		}
		for at := 0; at + size_of(Elf_Symbol) <= len(symbols); at += size_of(Elf_Symbol) {
			symbol: Elf_Symbol
			mem.copy(&symbol, raw_data(symbols[at:]), size_of(symbol))
			if symbol.section_index == ELF_SECTION_INDEX_UNDEFINED || symbol.section_index >= ELF_SECTION_INDEX_RESERVED_LOW || u64(symbol.name) >= u64(len(names)) {
				continue
			}
			if text_until_zero(names, u64(symbol.name)) != module.OWN_HASH_PLACE_SYMBOL {
				continue
			}
			if found {
				fmt.eprintfln("modustool: convert: the linked file has two symbols %s: one module has one own-hash place", module.OWN_HASH_PLACE_SYMBOL)
				return 0, false, false
			}
			if symbol.size != module.HASH_SIZE {
				fmt.eprintfln("modustool: convert: the symbol %s has %d bytes; the own-hash place has %d", module.OWN_HASH_PLACE_SYMBOL, symbol.size, module.HASH_SIZE)
				return 0, false, false
			}
			writable := false
			for image in images {
				segment := image.record
				if .Write in segment.flags && .Execute not_in segment.flags && symbol.value >= segment.memory_offset && symbol.value - segment.memory_offset <= segment.memory_size && module.HASH_SIZE <= segment.memory_size - (symbol.value - segment.memory_offset) {
					writable = true
				}
			}
			if !writable {
				fmt.eprintfln("modustool: convert: the symbol %s at %x is not in a segment that the loader can write", module.OWN_HASH_PLACE_SYMBOL, symbol.value)
				return 0, false, false
			}
			memory_offset, found = symbol.value, true
		}
	}
	return memory_offset, found, true
}

// The two forms of the symbol of a package variable that the compiler
// writes in the linked file: the package and the name, with "." or "::"
// between them. The tool takes either, and refuses a file with both.
RECORD_STREAM_SYMBOL_SEPARATORS :: [2]string{".", "::"}

// record_stream_place_of_elf gives the memory offset of the package
// variable of one record stream: the object symbol `package.name` of the
// symbol table of the linked file, of at least
// module.RECORD_STREAM_PLACE_SIZE bytes, on a multiple of that size, in a
// segment that the loader can write. found is false for no such symbol:
// no code uses the variable, and the link dropped it; the row then has the
// place 0. ok is false for a symbol that breaks a rule, which it prints.
@(private = "file")
record_stream_place_of_elf :: proc(elf: []u8, sections: []Elf_Section_Header, images: []Segment_Image, package_name: string, name: string) -> (memory_offset: u64, found: bool, ok: bool) {
	wanted: [2]string
	separators := RECORD_STREAM_SYMBOL_SEPARATORS
	for separator, index in separators {
		wanted[index] = strings.concatenate({package_name, separator, name}, context.temp_allocator)
	}
	for section in sections {
		if section.type != ELF_SECTION_SYMBOLS || int(section.link) >= len(sections) {
			continue
		}
		symbols, has_symbols := elf_section_bytes(elf, section)
		names, has_names := elf_section_bytes(elf, sections[section.link])
		if !has_symbols || !has_names {
			continue
		}
		for at := 0; at + size_of(Elf_Symbol) <= len(symbols); at += size_of(Elf_Symbol) {
			symbol: Elf_Symbol
			mem.copy(&symbol, raw_data(symbols[at:]), size_of(symbol))
			if symbol.section_index == ELF_SECTION_INDEX_UNDEFINED || symbol.section_index >= ELF_SECTION_INDEX_RESERVED_LOW || u64(symbol.name) >= u64(len(names)) {
				continue
			}
			symbol_name := text_until_zero(names, u64(symbol.name))
			if symbol_name != wanted[0] && symbol_name != wanted[1] {
				continue
			}
			if found {
				fmt.eprintfln("modustool: convert: the linked file has two symbols of the record stream %s: one variable has one place", wanted[0])
				return 0, false, false
			}
			if symbol.size < module.RECORD_STREAM_PLACE_SIZE || symbol.value % module.RECORD_STREAM_PLACE_SIZE != 0 {
				fmt.eprintfln("modustool: convert: the symbol %s has %d bytes at %x; the place of a record stream has %d bytes, aligned", symbol_name, symbol.size, symbol.value, module.RECORD_STREAM_PLACE_SIZE)
				return 0, false, false
			}
			writable := false
			for image in images {
				segment := image.record
				if .Write in segment.flags && .Execute not_in segment.flags && .Read_Only_After_Load not_in segment.flags && symbol.value >= segment.memory_offset && symbol.value - segment.memory_offset <= segment.memory_size && module.RECORD_STREAM_PLACE_SIZE <= segment.memory_size - (symbol.value - segment.memory_offset) {
					writable = true
				}
			}
			if !writable {
				fmt.eprintfln("modustool: convert: the variable %s at %x is not in a writable data segment that stays writable after load", symbol_name, symbol.value)
				return 0, false, false
			}
			memory_offset, found = symbol.value, true
		}
	}
	return memory_offset, found, true
}

// module_export_name gives the name of an export of a module file.
module_export_name :: proc(file: []u8, export_index: u32) -> string {
	function, _ := module.function(file, export_index)
	return module.string_at(file, function.name_offset, function.name_count)
}
