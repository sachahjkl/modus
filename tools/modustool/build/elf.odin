package build

// The records of the ELF format that the converter reads. ELF is a build-time
// intermediate format only (docs/MODULE_CONTRACT.md, section 7;
// src/md/infrastructure/language_neutral_abi.md).

ELF_MAGIC :: u32(0x464C457F)
ELF_CLASS_64 :: 2
ELF_DATA_LITTLE_ENDIAN :: 1
ELF_TYPE_RELOCATABLE :: 1
ELF_TYPE_EXECUTABLE :: 2
ELF_TYPE_SHARED :: 3
ELF_MACHINE_X86_64 :: 62

Elf_Header :: struct {
	magic:                      u32,
	class:                      u8,
	data:                       u8,
	identification_version:     u8,
	padding:                    [9]u8,
	type:                       u16,
	machine:                    u16,
	version:                    u32,
	entry:                      u64,
	program_header_offset:      u64,
	section_header_offset:      u64,
	flags:                      u32,
	header_size:                u16,
	program_header_size:        u16,
	program_header_count:       u16,
	section_header_size:        u16,
	section_header_count:       u16,
	section_name_section_index: u16,
}
#assert(size_of(Elf_Header) == 64)

ELF_PROGRAM_LOAD :: 1
ELF_PROGRAM_INTERPRETER :: 3
ELF_PROGRAM_TLS :: 7
ELF_PROGRAM_RELRO :: 0x6474E552
ELF_PROGRAM_EXECUTE :: 1
ELF_PROGRAM_WRITE :: 2
ELF_PROGRAM_READ :: 4

Elf_Program_Header :: struct {
	type:        u32,
	flags:       u32,
	offset:      u64,
	address:     u64,
	physical:    u64,
	file_size:   u64,
	memory_size: u64,
	alignment:   u64,
}
#assert(size_of(Elf_Program_Header) == 56)

ELF_SECTION_NULL :: 0
ELF_SECTION_PROGRAM_DATA :: 1
ELF_SECTION_SYMBOLS :: 2
ELF_SECTION_STRING_TABLE :: 3
ELF_SECTION_RELA :: 4
ELF_SECTION_NO_BITS :: 8 // A section with no bytes in the file (.bss).
ELF_SECTION_REL :: 9
ELF_SECTION_DYNAMIC_SYMBOLS :: 11
ELF_SECTION_INIT_ARRAY :: 14
ELF_SECTION_FINI_ARRAY :: 15
ELF_SECTION_PREINIT_ARRAY :: 16
ELF_SECTION_GROUP :: 17
ELF_SECTION_RELR :: 19

ELF_SECTION_FLAG_WRITE :: 0x1
ELF_SECTION_FLAG_ALLOCATED :: 0x2
ELF_SECTION_FLAG_EXECUTE :: 0x4
ELF_SECTION_FLAG_TLS :: 0x400

ELF_SECTION_INDEX_UNDEFINED :: u16(0)
ELF_SECTION_INDEX_RESERVED_LOW :: u16(0xFF00)
ELF_SECTION_INDEX_ABSOLUTE :: u16(0xFFF1)
ELF_SECTION_INDEX_COMMON :: u16(0xFFF2)

Elf_Section_Header :: struct {
	name:       u32,
	type:       u32,
	flags:      u64,
	address:    u64,
	offset:     u64,
	size:       u64,
	link:       u32,
	info:       u32,
	alignment:  u64,
	entry_size: u64,
}
#assert(size_of(Elf_Section_Header) == 64)

ELF_SYMBOL_BINDING_LOCAL :: 0
ELF_SYMBOL_BINDING_GLOBAL :: 1
ELF_SYMBOL_BINDING_WEAK :: 2

ELF_SYMBOL_NO_TYPE :: 0
ELF_SYMBOL_OBJECT :: 1
ELF_SYMBOL_FUNCTION :: 2
ELF_SYMBOL_SECTION :: 3
ELF_SYMBOL_FILE :: 4
ELF_SYMBOL_TLS :: 6

Elf_Symbol :: struct {
	name:          u32,
	info:          u8,
	other:         u8,
	section_index: u16,
	value:         u64,
	size:          u64,
}
#assert(size_of(Elf_Symbol) == 24)

// x86-64 ELF relocation types (System V AMD64 ABI, section 4.4.1).
ELF_RELOCATION_NONE :: 0
ELF_RELOCATION_64 :: 1
ELF_RELOCATION_PC32 :: 2
ELF_RELOCATION_GOT32 :: 3
ELF_RELOCATION_PLT32 :: 4
ELF_RELOCATION_COPY :: 5
ELF_RELOCATION_GLOBAL_DATA :: 6
ELF_RELOCATION_JUMP_SLOT :: 7
ELF_RELOCATION_RELATIVE :: 8
ELF_RELOCATION_GOTPCREL :: 9
ELF_RELOCATION_32 :: 10
ELF_RELOCATION_32S :: 11
ELF_RELOCATION_16 :: 12
ELF_RELOCATION_PC16 :: 13
ELF_RELOCATION_8 :: 14
ELF_RELOCATION_PC8 :: 15
ELF_RELOCATION_DTPMOD64 :: 16
ELF_RELOCATION_DTPOFF64 :: 17
ELF_RELOCATION_TPOFF64 :: 18
ELF_RELOCATION_TLSGD :: 19
ELF_RELOCATION_TLSLD :: 20
ELF_RELOCATION_DTPOFF32 :: 21
ELF_RELOCATION_GOTTPOFF :: 22
ELF_RELOCATION_TPOFF32 :: 23
ELF_RELOCATION_PC64 :: 24
ELF_RELOCATION_GOTOFF64 :: 25
ELF_RELOCATION_GOTPC32 :: 26
ELF_RELOCATION_GOT64 :: 27
ELF_RELOCATION_GOTPCREL64 :: 28
ELF_RELOCATION_GOTPC64 :: 29
ELF_RELOCATION_GOTPLT64 :: 30
ELF_RELOCATION_PLTOFF64 :: 31
ELF_RELOCATION_GOTPC32_TLSDESC :: 34
ELF_RELOCATION_TLSDESC_CALL :: 35
ELF_RELOCATION_TLSDESC :: 36
ELF_RELOCATION_IRELATIVE :: 37
ELF_RELOCATION_GOTPCRELX :: 41
ELF_RELOCATION_REX_GOTPCRELX :: 42

Elf_Rela :: struct {
	offset: u64,
	info:   u64,
	addend: i64,
}
#assert(size_of(Elf_Rela) == 24)

// elf_relocation_is_tls reports whether an x86-64 relocation type uses
// thread-local storage, which modus modules do not support.
elf_relocation_is_tls :: proc(relocation_type: u32) -> bool {
	switch relocation_type {
	case ELF_RELOCATION_DTPMOD64,
		ELF_RELOCATION_DTPOFF64,
		ELF_RELOCATION_TPOFF64,
		ELF_RELOCATION_TLSGD,
		ELF_RELOCATION_TLSLD,
		ELF_RELOCATION_DTPOFF32,
		ELF_RELOCATION_GOTTPOFF,
		ELF_RELOCATION_TPOFF32,
		ELF_RELOCATION_GOTPC32_TLSDESC,
		ELF_RELOCATION_TLSDESC_CALL,
		ELF_RELOCATION_TLSDESC:
		return true
	}
	return false
}

// elf_relocation_is_forbidden_got reports whether an x86-64 relocation type
// requires a runtime global offset table base or dynamic linker mechanism.
elf_relocation_is_forbidden_got :: proc(relocation_type: u32) -> bool {
	switch relocation_type {
	case ELF_RELOCATION_GOT32,
		ELF_RELOCATION_COPY,
		ELF_RELOCATION_GOTOFF64,
		ELF_RELOCATION_GOTPC32,
		ELF_RELOCATION_GOT64,
		ELF_RELOCATION_GOTPCREL64,
		ELF_RELOCATION_GOTPC64,
		ELF_RELOCATION_GOTPLT64,
		ELF_RELOCATION_PLTOFF64,
		ELF_RELOCATION_IRELATIVE:
		return true
	}
	return false
}
