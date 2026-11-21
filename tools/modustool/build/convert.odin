package build

import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// An import of the module that convert writes: the file of the imported module.
Import_File :: struct {
	name: string,
	file: []u8,
}

@(private = "file")
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
	details:       []u32,
	directions:    []module.Direction, // The direction of each Table or Bytes parameter (module.Function.parameter_directions).
	optional_parameters: u16, // Bit n: a call may leave out the Enum parameter n (module.Function.optional_parameters).
	getter_names:  []string, // The name of the getter export of each Enum parameter, "" for none: describe writes it into the detail.
	result_detail: u32,
	error_record:  u32, // Not 0: the export gives an error record, with this record (module.Function.error_record).
	// Where the source declares it: the site links each export to its line.
	file:          string,
	line:          int,
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
	about:    string, // One line: the first sentence of the comment of the package.
	text:     string, // The documentation text that the module carries: the comment of the package, in its Markdown.
	markdown: string, // The comment of the package, as its author wrote it: the site renders it.
	exports:  []Export_Description,
	records:  []Record_Description, // The records that the exports, the log facts and the record streams use. Record n + 1 of the module is records[n].
	enums:    []Enum_Description, // The enums that the exports take and give. Enum n + 1 of the module is enums[n].
	member_texts: []Member_Text_Description, // The display texts of the members, in the order of the enum, the member and the language: the table Member_Texts.
	budget:   Budget_Description, // The budget that the module asks for: the table Budget.
	facts:    []Fact_Description, // The log facts that the module writes, sorted by key (facts_merge): the table Facts.
	record_outputs: []Record_Stream_Description, // The record outputs that the module declares, sorted by name (record_streams_merge): the table Record_Outputs.
	record_inputs:  []Record_Stream_Description, // The record inputs, sorted by name: the table Record_Inputs.
}

// The parts of the budget that a source states: the record
// system.Stated_Budget of the source (src/library/support/system,
// budget_request.odin). The tool cannot import that package, so it has
// the same fields here.
Stated_Budget :: struct {
	working_memory_pages: u64,
	processes:             u64,
	threads:              u64,
	window_width:         u64, // Pixels; 0: no window.
	window_height:        u64,
}

// The budget that a module asks for, as its source states it in the
// constant BUDGET_REQUEST_NAME (describe.odin). The conversion adds the
// counted parts (budget_count.odin).
Budget_Description :: struct {
	stated:       bool, // The source has the constant: the module has the table Budget.
	parts:        Stated_Budget, // A window part that named a constant holds its value.
	window_names: [2]string, // The constant that each window part names, or "".
	comment:      string, // The comment before the constant, in its Markdown: the reasons of the amounts.
	// Where the source declares it: the site links the budget to its line.
	file:         string,
	line:         int,
	// The memory size of each module that the module imports, at each
	// level, each one time: module_convert reads them from their files.
	import_memory_sizes: []u64,
}

// convert writes a module from a shared object that lld linked.
//   exports: the descriptions of the exports. Export n + 1 is exports[n].
//   imports: the modules that the undefined symbols of the object come from.
// The module binds each import by (import index, export index). The names
// are used here only, at build time.
//   slot_symbols: not nil: it receives the name of the symbol of each slot,
//            one for each slot, for the check of the declarations of the
//            importer (import_declarations.odin).
convert :: proc(name: string, elf: []u8, description: Module_Description, imports: []Import_File, slot_symbols: ^[dynamic]string = nil) -> (result: []u8, ok: bool) {
	exports := description.exports
	fail :: proc(name: string, format: string, args: ..any) -> ([]u8, bool) {
		fmt.eprintf("modustool: convert %s: ", name)
		fmt.eprintfln(format, ..args)
		return nil, false
	}
	at :: proc(elf: []u8, offset: u64, $T: typeid) -> (value: T, ok: bool) {
		if offset > u64(len(elf)) || size_of(T) > u64(len(elf)) - offset {
			return {}, false
		}
		mem.copy(&value, raw_data(elf[offset:]), size_of(T))
		return value, true
	}
	text :: proc(elf: []u8, table: Elf_Section_Header, offset: u32) -> string {
		start := table.offset + u64(offset)
		if start >= u64(len(elf)) {
			return ""
		}
		return string(cstring(raw_data(elf[start:])))
	}

	head, head_ok := at(elf, 0, Elf_Header)
	if !head_ok || head.magic != ELF_MAGIC || head.class != ELF_CLASS_64 || head.data != ELF_DATA_LITTLE_ENDIAN {
		return fail(name, "the input is not a 64-bit little-endian ELF file")
	}
	if head.type != ELF_TYPE_SHARED || head.machine != ELF_MACHINE_X86_64 {
		return fail(name, "the input is not a position-independent x86-64 object")
	}

	processes := make([dynamic]Elf_Program_Header, context.temp_allocator)
	for i in 0 ..< u64(head.program_header_count) {
		process := at(elf, head.program_header_offset + i * u64(head.program_header_size), Elf_Program_Header) or_return
		append(&processes, process)
	}
	sections := make([dynamic]Elf_Section_Header, context.temp_allocator)
	for i in 0 ..< u64(head.section_header_count) {
		section := at(elf, head.section_header_offset + i * u64(head.section_header_size), Elf_Section_Header) or_return
		append(&sections, section)
	}
	if int(head.section_name_section_index) >= len(sections) {
		return fail(name, "the input has no section names")
	}
	section_names := sections[head.section_name_section_index]

	// Segments. A module segment is one loadable segment of the input, on its
	// own pages. Its data starts as zero; only program data is copied, so that
	// no ELF structure reaches the module.
	images := make([dynamic]Segment_Image, context.temp_allocator)
	relro_start, relro_end: u64
	for process in processes {
		switch process.type {
		case ELF_PROGRAM_TLS:
			if process.memory_size != 0 {
				return fail(name, "thread-local data is not in the module contract")
			}
		case ELF_PROGRAM_RELRO:
			relro_start, relro_end = process.address, process.address + process.memory_size
		}
	}
	memory_size: u64
	for process in processes {
		if process.type != ELF_PROGRAM_LOAD {
			continue
		}
		start := mem.align_backward_uint(uint(process.address), module.PAGE_SIZE)
		end := mem.align_forward_uint(uint(process.address + process.memory_size), module.PAGE_SIZE)
		if u64(start) < memory_size {
			return fail(name, "two segments of the input share a page")
		}
		memory_size = u64(end)
		image := Segment_Image {
			record = {memory_offset = u64(start), memory_size = u64(end - start)},
			data = make([]u8, process.address - u64(start) + process.file_size, context.temp_allocator),
		}
		if process.flags & ELF_PROGRAM_READ != 0 {image.record.flags += {.Read}}
		if process.flags & ELF_PROGRAM_WRITE != 0 {image.record.flags += {.Write}}
		if process.flags & ELF_PROGRAM_EXECUTE != 0 {image.record.flags += {.Execute}}
		if .Write in image.record.flags && process.address >= relro_start && process.address + process.memory_size <= relro_end {
			image.record.flags += {.Read_Only_After_Load}
		}
		if image.record.flags & {.Write, .Execute} == {.Write, .Execute} {
			return fail(name, "a segment of the input is writable and executable")
		}
		append(&images, image)
	}

	// write_word writes 8 bytes at a memory offset, in a writable segment.
	write_word :: proc(images: []Segment_Image, memory_offset: u64, value: u64) -> bool {
		for image in images {
			if memory_offset < image.record.memory_offset || memory_offset - image.record.memory_offset + 8 > u64(len(image.data)) {
				continue
			}
			if .Write not_in image.record.flags || memory_offset % 8 != 0 {
				return false
			}
			word := value
			mem.copy(raw_data(image.data[memory_offset - image.record.memory_offset:]), &word, 8)
			return true
		}
		return false
	}

	dynamic_symbols: Elf_Section_Header
	for section in sections {
		section_name := text(elf, section_names, section.name)
		switch section.type {
		case ELF_SECTION_INIT_ARRAY, ELF_SECTION_FINI_ARRAY, ELF_SECTION_PREINIT_ARRAY:
			return fail(name, "section %s holds code that runs before the entry; a module has none", section_name)
		case ELF_SECTION_DYNAMIC_SYMBOLS:
			dynamic_symbols = section
		case ELF_SECTION_PROGRAM_DATA:
			if section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 || strings.has_prefix(section_name, ".eh_frame") {
				continue
			}
			if section.offset > u64(len(elf)) || section.size > u64(len(elf)) - section.offset {
				return fail(name, "section %s is outside the input", section_name)
			}
			copied := false
			for image in images {
				if section.address >= image.record.memory_offset && section.address - image.record.memory_offset + section.size <= u64(len(image.data)) {
					copy(image.data[section.address - image.record.memory_offset:], elf[section.offset:][:section.size])
					copied = true
				}
			}
			if !copied {
				return fail(name, "section %s is in no segment", section_name)
			}
		}
	}
	if int(dynamic_symbols.link) >= len(sections) {
		return fail(name, "the input has no dynamic symbols")
	}
	symbol_names := sections[dynamic_symbols.link]
	symbol_count := dynamic_symbols.size / size_of(Elf_Symbol)

	// Exports: the code offset of each is its function symbol in the input.
	export_parts := make([dynamic]module_file_writer.Export_Part, context.temp_allocator)
	for description in exports {
		code_offset: u64
		found := false
		for i in 0 ..< symbol_count {
			symbol := at(elf, dynamic_symbols.offset + i * size_of(Elf_Symbol), Elf_Symbol) or_return
			if symbol.section_index == 0 || symbol.info & 0xF != ELF_SYMBOL_FUNCTION || text(elf, symbol_names, symbol.name) != description.name {
				continue
			}
			code_offset, found = symbol.value, true
			break
		}
		if !found {
			return fail(name, "export %s is not a function of the input", description.name)
		}
		append(&export_parts, module_file_writer.Export_Part {
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
		})
	}

	// Imports.
	import_hashes := make([dynamic][module.HASH_SIZE]u8, context.temp_allocator)
	for item in imports {
		append(&import_hashes, blake3.hash(item.file))
	}

	// Relocations: each one becomes a rebase or a slot.
	rebases := make([dynamic]u64, context.temp_allocator)
	slot_records := make([dynamic]module.Slot, context.temp_allocator)
	for section in sections {
		if section.type != ELF_SECTION_RELA || section.flags & ELF_SECTION_FLAG_ALLOCATED == 0 {
			continue
		}
		for i in 0 ..< section.size / size_of(Elf_Rela) {
			relocation := at(elf, section.offset + i * size_of(Elf_Rela), Elf_Rela) or_return
			type := u32(relocation.info)
			symbol := at(elf, dynamic_symbols.offset + (relocation.info >> 32) * size_of(Elf_Symbol), Elf_Symbol) or_return
			symbol_name := text(elf, symbol_names, symbol.name)
			value: u64
			switch type {
			case ELF_RELOCATION_RELATIVE:
				value = u64(relocation.addend)
			case ELF_RELOCATION_64, ELF_RELOCATION_GLOBAL_DATA, ELF_RELOCATION_JUMP_SLOT:
				if symbol.section_index == 0 {
					slot := module.Slot{memory_offset = relocation.offset}
					find: for item, import_index in imports {
						for export_index in 1 ..< module.count(item.file, .Exports) {
							if module_export_name(item.file, export_index) == symbol_name {
								slot.import_index = u32(import_index + 1)
								slot.export_index = export_index
								break find
							}
						}
					}
					if slot.import_index == 0 {
						return fail(name, "%s is not defined, and no import exports it", symbol_name)
					}
					if !write_word(images[:], relocation.offset, 0) {
						return fail(name, "the slot of %s is not in writable data", symbol_name)
					}
					append(&slot_records, slot)
					if slot_symbols != nil {
						append(slot_symbols, symbol_name)
					}
					continue
				}
				value = symbol.value
				if type == ELF_RELOCATION_64 {
					value += u64(relocation.addend)
				}
			case:
				return fail(name, "relocation type %d (symbol %s) has no form in a module", type, symbol_name)
			}
			if !write_word(images[:], relocation.offset, value) {
				return fail(name, "a rebase at offset %x is not in writable data", relocation.offset)
			}
			append(&rebases, relocation.offset)
		}
	}
	// The writer takes the rebases in order; the relocations of the input
	// come in the order of their sections.
	slice.sort(rebases[:])

	// The place where a loader writes the hash of the module: the variable
	// of the support package system that log_fact copies
	// (src/md/features/log_facts.md, "The record").
	own_hash_place, has_place := own_hash_place_of_elf(elf, sections[:], images[:]) or_return
	if len(description.facts) > 0 && !has_place {
		return fail(name, "the module writes log facts, and its linked file has no symbol %s: the variable of the support package system that holds the hash of the module", module.OWN_HASH_PLACE_SYMBOL)
	}
	fact_parts := make([]module_file_writer.Fact_Part, len(description.facts), context.temp_allocator)
	for fact, index in description.facts {
		fact_parts[index] = {key = fact.key, record_index = fact.record_index, template = fact.template, package_name = fact.package_name}
	}
	segment_parts := make([]module_file_writer.Segment_Part, len(images), context.temp_allocator)
	for image, index in images {
		segment_parts[index] = {memory_offset = image.record.memory_offset, memory_size = image.record.memory_size, flags = image.record.flags, data = image.data}
	}
	parts := module_file_writer.Module_Parts {
		segments           = segment_parts,
		exports            = export_parts[:],
		imports            = import_hashes[:],
		slots              = slot_records[:],
		rebases            = rebases[:],
		records            = description.records,
		enums              = description.enums,
		member_texts       = description.member_texts,
		facts              = fact_parts,
		has_own_hash_place = has_place,
		own_hash_place     = own_hash_place,
		about              = description.about,
		text               = description.text,
	}
	// The record outputs and the record inputs, sorted by name, each with
	// the place of its variable that the linked file gives: the writer
	// writes their tables and checks them.
	output_parts := make([]module_file_writer.Record_Output_Part, len(description.record_outputs), context.temp_allocator)
	for item, index in description.record_outputs {
		place, _ := record_stream_place_of_elf(elf, sections[:], images[:], item.package_name, item.name) or_return
		output_parts[index] = {name = item.name, about = item.about, text = item.text, record_index = item.record_index, pairing = item.pairing, place = place}
	}
	input_parts := make([]module_file_writer.Record_Input_Part, len(description.record_inputs), context.temp_allocator)
	for item, index in description.record_inputs {
		place, _ := record_stream_place_of_elf(elf, sections[:], images[:], item.package_name, item.name) or_return
		input_parts[index] = {name = item.name, about = item.about, text = item.text, record_index = item.record_index, terms_index = item.terms_index, wirings = item.wirings, place = place}
	}
	parts.record_outputs, parts.record_inputs = output_parts, input_parts
	// A module whose source states no budget has no table Budget: it asks
	// for the least budget.
	if description.budget.stated {
		counted, counted_ok := budget_count(description.budget.parts, memory_size, description.budget.import_memory_sizes)
		if !counted_ok {
			return fail(name, "the budget that the module asks for passes the end of 64 bits")
		}
		parts.has_budget, parts.budget = true, counted.request
	}

	size, refusal := module_file_writer.file_size_needed(parts)
	if refusal.refusal != .None {
		return fail(name, "%s", module_file_refusal_text(parts, refusal))
	}
	output := make([]u8, int(size))
	_, refusal = module_file_writer.write(parts, output)
	if refusal.refusal != .None {
		delete(output)
		return fail(name, "%s", module_file_refusal_text(parts, refusal))
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
	case .None, .Segments, .Imports, .Slots, .Rebases, .Strings, .Documentation, .Budget, .Facts, .Own_Hash:
	}
	return fmt.tprintf("the module file writer refuses the module: %v in the table %v, part %d%s, value %d (src/library/contract/module_file_writer)", refusal.refusal, refusal.table, refusal.index, part, refusal.value)
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
			if symbol.section_index == 0 || text_until_zero(names, u64(symbol.name)) != module.OWN_HASH_PLACE_SYMBOL {
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
				if .Write in segment.flags && .Execute not_in segment.flags && symbol.value >= segment.memory_offset && symbol.value - segment.memory_offset + module.HASH_SIZE <= segment.memory_size {
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
			if symbol.section_index == 0 || symbol.section_index >= 0xFF00 || u64(symbol.name) >= u64(len(names)) {
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
				if .Write in segment.flags && .Execute not_in segment.flags && symbol.value >= segment.memory_offset && symbol.value - segment.memory_offset + module.RECORD_STREAM_PLACE_SIZE <= segment.memory_size {
					writable = true
				}
			}
			if !writable {
				fmt.eprintfln("modustool: convert: the variable %s at %x is not in a segment that the loader can write", symbol_name, symbol.value)
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
