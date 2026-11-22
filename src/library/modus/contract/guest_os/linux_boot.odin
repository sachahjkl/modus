package guest_os

import "modus:contract/byte_order"
import op "modus:contract/operation"
import "modus:contract/text_encoding"

// The 64-bit boot protocol of Linux on x86 (Documentation/arch/x86/boot.rst,
// "64-bit Boot Protocol"): the process loads the kernel, writes the zero
// page (`boot_params`) with the setup header of the image, the memory map
// and the command line, builds a page table that maps the low memory at
// its own address, and enters the kernel in long mode with `rsi` at the
// zero page. No firmware runs. Each value of the image is checked before a
// byte of it is copied: the image is data from a store, its hash names it,
// and nothing makes it right.

// The guest physical layout of a Linux guest, below 1 MiB.
LINUX_DESCRIPTOR_TABLE_ADDRESS :: u64(0x0) // A new guest processor has its descriptor table at 0, limit 0xFFFF.
LINUX_ZERO_PAGE_ADDRESS :: u64(0x7000)
LINUX_STACK_TOP :: u64(0x7000)
LINUX_PAGE_TABLES_ADDRESS :: u64(0x9000)
LINUX_PAGE_TABLE_PAGES :: 7 // The top table, two tables of the third level, and four directories of 1 GiB.
LINUX_COMMAND_LINE_ADDRESS :: u64(0x2_0000)
LINUX_COMMAND_LINE_BYTES_MOST :: 2048
LINUX_LOW_MEMORY_END :: u64(0x10_0000)
LINUX_KERNEL_ADDRESS :: u64(0x100_0000) // 16 MiB: where an image that names no place goes.
LINUX_IDENTITY_GIBIBYTES :: 4
LINUX_HIGHER_HALF :: u64(0xFFFF_FFFF_8000_0000) // The kernel map of Linux: the low 2 GiB again.
LINUX_CODE_SELECTOR :: u16(0x10) // __BOOT_CS
LINUX_DATA_SELECTOR :: u16(0x18) // __BOOT_DS
LINUX_ELF_SEGMENTS_MOST :: 16
LINUX_MEMORY_BYTES_LEAST :: u64(64 * 1024 * 1024)

// The places of the setup header and of the zero page.
SETUP_SECTORS :: 0x1F1
SETUP_BOOT_FLAG :: 0x1FE
SETUP_JUMP :: 0x200
SETUP_HEADER_MAGIC :: 0x202
SETUP_VERSION :: 0x206
SETUP_LOADER_TYPE :: 0x210
SETUP_LOAD_FLAGS :: 0x211
SETUP_RAMDISK_ADDRESS :: 0x218
SETUP_RAMDISK_SIZE :: 0x21C
SETUP_INITIAL_ARCHIVE_ADDRESS_MOST :: 0x22C // The highest byte that the initial archive may hold.
SETUP_COMMAND_LINE_ADDRESS :: 0x228
SETUP_KERNEL_ALIGNMENT :: 0x230
SETUP_RELOCATABLE :: 0x234
SETUP_EXTENDED_LOAD_FLAGS :: 0x236
SETUP_COMMAND_LINE_SIZE :: 0x238
SETUP_PREFERRED_ADDRESS :: 0x258
SETUP_INITIAL_SIZE :: 0x260
SETUP_HEADER_END_LEAST :: 0x264 // Through the initial size, which the protocol 2.10 added.
SETUP_HEADER_END_MOST :: u64(0x290) // Below the memory map of the zero page at 0x2D0: a header never writes over it.
ZERO_PAGE_BYTES :: 4096
ZERO_PAGE_EXTENDED_RAMDISK_ADDRESS :: 0x0C0
ZERO_PAGE_EXTENDED_RAMDISK_SIZE :: 0x0C4
ZERO_PAGE_EXTENDED_COMMAND_LINE :: 0x0C8
ZERO_PAGE_MEMORY_MAP_COUNT :: 0x1E8
ZERO_PAGE_MEMORY_MAP :: 0x2D0
ZERO_PAGE_MEMORY_MAP_ENTRIES_MOST :: 128
LINUX_PROTOCOL_LEAST :: u16(0x020C) // 2.12: the extended load flags that say the kernel has a 64-bit entry.
LINUX_LOADED_HIGH :: u8(0x01)
LINUX_EXTENDED_KERNEL_64 :: u16(0x0001)
LINUX_EXTENDED_INITIAL_ARCHIVE_ABOVE_4G :: u16(0x0002) // The initial archive may lie anywhere: the kernel reads the extended fields.
LINUX_INITIAL_ARCHIVE_ALIGNMENT :: u64(4096)
LINUX_LOADER_UNDEFINED :: u8(0xFF)
LINUX_ENTRY_64_OFFSET :: u64(0x200) // startup_64 is 0x200 past the start of the protected-mode kernel.

Linux_Image_Kind :: enum u8 {
	Compressed = 1, // bzImage: a setup part, then the protected-mode kernel that decompresses itself.
	Elf        = 2, // vmlinux: an ELF64 file whose segments name their physical addresses.
}

Linux_Boot_Refusal :: enum u8 {
	None                  = 0,
	Truncated             = 1, // The image ends inside a header or a segment.
	Unknown_Format        = 2, // Neither a bzImage nor an ELF64 executable for x86-64.
	Old_Protocol          = 3, // A boot protocol older than 2.12.
	Not_Sixty_Four_Bit    = 4, // The image has no 64-bit entry.
	Not_Loaded_High       = 5, // The protected-mode kernel does not load at 1 MiB or above.
	Bad_Alignment         = 6, // The alignment of the kernel is not a power of two, or its place does not keep it.
	Bad_Segment           = 7, // A segment of the ELF file overlaps another, lies below 1 MiB, or is bigger in the file than in memory.
	Entry_Outside         = 8, // The entry is in no loaded byte.
	Memory_Too_Small      = 9, // The kernel, its working space or the memory map does not fit the memory.
	Command_Line_Too_Long = 10, // Past the size that the kernel reads, or past LINUX_COMMAND_LINE_BYTES_MOST.
	Command_Line_Not_Text = 11, // Not valid text, or a byte 0 or a control byte inside.
	Initial_Archive_Too_Large = 12, // The initial archive does not fit between the kernel and its highest address.
}

Linux_Elf_Segment :: struct {
	file_offset:      u64,
	file_bytes:       u64,
	physical_address: u64,
	memory_bytes:     u64,
}

// What the boot needs of an image, checked.
Linux_Image :: struct {
	kind:                 Linux_Image_Kind,
	protocol_version:     u16,
	setup_bytes:          u64, // A bzImage: the setup part, which the process does not run.
	setup_header_end:     u64, // A bzImage: the end of its setup header, which goes into the zero page.
	load_address:         u64, // The lowest physical address of the kernel.
	load_end:             u64, // The end of the memory that the kernel uses while it starts.
	entry_address:        u64,
	command_line_bytes_most: u64,
	initial_archive_address_most: u64, // The highest byte that an initial archive may hold.
	segments:             [LINUX_ELF_SEGMENTS_MOST]Linux_Elf_Segment,
	segment_count:        int,
}

// linux_image_parse checks an image of a kernel against the memory of the
// guest, and gives where each part goes.
linux_image_parse :: proc "contextless" (image: []u8, memory_bytes: u64) -> (parsed: Linux_Image, refusal: Linux_Boot_Refusal) {
	if memory_bytes < LINUX_MEMORY_BYTES_LEAST {
		return {}, .Memory_Too_Small
	}
	if len(image) >= 4 && image[0] == 0x7F && image[1] == 'E' && image[2] == 'L' && image[3] == 'F' {
		return linux_elf_parse(image, memory_bytes)
	}
	if len(image) < SETUP_HEADER_END_LEAST {
		if len(image) > SETUP_HEADER_MAGIC + 4 && byte_order.read_u32_little_endian(image, SETUP_HEADER_MAGIC) == LINUX_BOOT_HEADER_MAGIC {
			return {}, .Truncated
		}
		return {}, .Unknown_Format
	}
	if byte_order.read_u16_little_endian(image, SETUP_BOOT_FLAG) != 0xAA55 || byte_order.read_u32_little_endian(image, SETUP_HEADER_MAGIC) != LINUX_BOOT_HEADER_MAGIC {
		return {}, .Unknown_Format
	}
	parsed.kind = .Compressed
	parsed.protocol_version = byte_order.read_u16_little_endian(image, SETUP_VERSION)
	if parsed.protocol_version < LINUX_PROTOCOL_LEAST {
		return {}, .Old_Protocol
	}
	if byte_order.read_u16_little_endian(image, SETUP_EXTENDED_LOAD_FLAGS) & LINUX_EXTENDED_KERNEL_64 == 0 {
		return {}, .Not_Sixty_Four_Bit
	}
	if image[SETUP_LOAD_FLAGS] & LINUX_LOADED_HIGH == 0 {
		return {}, .Not_Loaded_High
	}
	sectors := u64(image[SETUP_SECTORS])
	if sectors == 0 {
		sectors = 4 // The protocol: 0 means 4.
	}
	parsed.setup_bytes = (sectors + 1) * 512
	if parsed.setup_bytes >= u64(len(image)) {
		return {}, .Truncated
	}
	// The header ends where the jump at 0x200 lands: 0x202 plus its byte.
	parsed.setup_header_end = min(u64(SETUP_HEADER_MAGIC) + u64(image[SETUP_JUMP + 1]), u64(len(image)), SETUP_HEADER_END_MOST)
	if parsed.setup_header_end < SETUP_HEADER_END_LEAST {
		return {}, .Truncated
	}
	alignment := u64(byte_order.read_u32_little_endian(image, SETUP_KERNEL_ALIGNMENT))
	if alignment == 0 || alignment & (alignment - 1) != 0 {
		return {}, .Bad_Alignment
	}
	preferred := byte_order.read_u64_little_endian(image, SETUP_PREFERRED_ADDRESS)
	parsed.load_address = preferred >= LINUX_LOW_MEMORY_END ? preferred : LINUX_KERNEL_ADDRESS
	if parsed.load_address & (alignment - 1) != 0 {
		if image[SETUP_RELOCATABLE] == 0 {
			return {}, .Bad_Alignment
		}
		aligned := (parsed.load_address + alignment - 1) &~ (alignment - 1)
		// A preferred address near the top of the addresses wraps to a low
		// one. With no wrap, the round up only moves the kernel up, so it
		// stays at 1 MiB or above.
		if aligned < parsed.load_address {
			return {}, .Bad_Alignment
		}
		parsed.load_address = aligned
	}
	payload := u64(len(image)) - parsed.setup_bytes
	working := max(payload, u64(byte_order.read_u32_little_endian(image, SETUP_INITIAL_SIZE)))
	if parsed.load_address > memory_bytes || working > memory_bytes - parsed.load_address {
		return {}, .Memory_Too_Small
	}
	parsed.load_end = parsed.load_address + working
	parsed.entry_address = parsed.load_address + LINUX_ENTRY_64_OFFSET
	if LINUX_ENTRY_64_OFFSET >= payload {
		return {}, .Entry_Outside
	}
	parsed.command_line_bytes_most = min(u64(byte_order.read_u32_little_endian(image, SETUP_COMMAND_LINE_SIZE)), LINUX_COMMAND_LINE_BYTES_MOST - 1)
	parsed.initial_archive_address_most = u64(byte_order.read_u32_little_endian(image, SETUP_INITIAL_ARCHIVE_ADDRESS_MOST))
	if byte_order.read_u16_little_endian(image, SETUP_EXTENDED_LOAD_FLAGS) & LINUX_EXTENDED_INITIAL_ARCHIVE_ABOVE_4G != 0 {
		parsed.initial_archive_address_most = max(u64)
	}
	return parsed, .None
}

// linux_elf_parse checks a vmlinux: an ELF64 executable for x86-64 whose
// segments name the physical addresses where they load, and whose entry is
// a physical address of a loaded byte (phys_startup_64).
linux_elf_parse :: proc "contextless" (image: []u8, memory_bytes: u64) -> (parsed: Linux_Image, refusal: Linux_Boot_Refusal) {
	ELF_HEADER_BYTES :: 64
	ELF_PROGRAM_HEADER_BYTES :: 56
	ELF_LOAD :: 1
	if len(image) < ELF_HEADER_BYTES {
		return {}, .Truncated
	}
	// Class 64, little-endian, version 1, an executable, x86-64.
	if image[4] != 2 || image[5] != 1 || image[6] != 1 || byte_order.read_u16_little_endian(image, 16) != 2 || byte_order.read_u16_little_endian(image, 18) != 0x3E {
		return {}, .Unknown_Format
	}
	parsed.kind = .Elf
	parsed.protocol_version = 0x020F
	entry := byte_order.read_u64_little_endian(image, 0x18)
	table := byte_order.read_u64_little_endian(image, 0x20)
	entry_bytes := byte_order.read_u16_little_endian(image, 0x36)
	count := u64(byte_order.read_u16_little_endian(image, 0x38))
	if entry_bytes != ELF_PROGRAM_HEADER_BYTES {
		return {}, .Unknown_Format
	}
	if table > u64(len(image)) || count * ELF_PROGRAM_HEADER_BYTES > u64(len(image)) - table {
		return {}, .Truncated
	}
	lowest, highest := max(u64), u64(0)
	for index in 0 ..< count {
		at := int(table + index * ELF_PROGRAM_HEADER_BYTES)
		if byte_order.read_u32_little_endian(image, at) != ELF_LOAD {
			continue
		}
		segment := Linux_Elf_Segment {
			file_offset      = byte_order.read_u64_little_endian(image, at + 0x08),
			physical_address = byte_order.read_u64_little_endian(image, at + 0x18),
			file_bytes       = byte_order.read_u64_little_endian(image, at + 0x20),
			memory_bytes     = byte_order.read_u64_little_endian(image, at + 0x28),
		}
		if segment.memory_bytes == 0 {
			continue
		}
		if parsed.segment_count == LINUX_ELF_SEGMENTS_MOST || segment.file_bytes > segment.memory_bytes || segment.physical_address < LINUX_LOW_MEMORY_END {
			return {}, .Bad_Segment
		}
		if segment.file_offset > u64(len(image)) || segment.file_bytes > u64(len(image)) - segment.file_offset {
			return {}, .Truncated
		}
		if segment.physical_address > memory_bytes || segment.memory_bytes > memory_bytes - segment.physical_address {
			return {}, .Memory_Too_Small
		}
		end := segment.physical_address + segment.memory_bytes
		for earlier in parsed.segments[:parsed.segment_count] {
			if segment.physical_address < earlier.physical_address + earlier.memory_bytes && earlier.physical_address < end {
				return {}, .Bad_Segment
			}
		}
		parsed.segments[parsed.segment_count] = segment
		parsed.segment_count += 1
		lowest = min(lowest, segment.physical_address)
		highest = max(highest, end)
	}
	if parsed.segment_count == 0 {
		return {}, .Bad_Segment
	}
	inside := false
	for segment in parsed.segments[:parsed.segment_count] {
		if entry >= segment.physical_address && entry - segment.physical_address < segment.file_bytes {
			inside = true
		}
	}
	if !inside {
		return {}, .Entry_Outside
	}
	parsed.load_address = lowest
	parsed.load_end = highest
	parsed.entry_address = entry
	parsed.command_line_bytes_most = LINUX_COMMAND_LINE_BYTES_MOST - 1
	// A vmlinux starts at startup_64 and reads the extended fields of the
	// zero page: the initial archive may lie anywhere.
	parsed.initial_archive_address_most = max(u64)
	return parsed, .None
}

// linux_image_load copies the kernel of a parsed image to its place in the
// memory of the guest, and clears the rest of the memory that it uses while
// it starts (the bss of each segment, the working space of a bzImage).
linux_image_load :: proc "contextless" (memory: Guest_Memory, image: []u8, parsed: Linux_Image) -> Linux_Boot_Refusal {
	switch parsed.kind {
	case .Compressed:
		target, inside := guest_memory_range(memory, parsed.load_address, parsed.load_end - parsed.load_address)
		if !inside {
			return .Memory_Too_Small
		}
		copied := copy(target, image[parsed.setup_bytes:])
		for &value in target[copied:] {
			value = 0
		}
	case .Elf:
		for index in 0 ..< parsed.segment_count {
			segment := parsed.segments[index]
			target, inside := guest_memory_range(memory, segment.physical_address, segment.memory_bytes)
			if !inside {
				return .Memory_Too_Small
			}
			copy(target, image[segment.file_offset:][:segment.file_bytes])
			for &value in target[segment.file_bytes:] {
				value = 0
			}
		}
	}
	return .None
}

// The flat descriptors of the protocol: a code segment of 64 bits at 0x10
// and a data segment at 0x18.
LINUX_DESCRIPTORS :: [4]u64{0, 0, 0x00AF_9B00_0000_FFFF, 0x00CF_9300_0000_FFFF}

// linux_page_tables_write writes the page table of the start: the first
// LINUX_IDENTITY_GIBIBYTES GiB at their own address, and the first 2 GiB
// again at LINUX_HIGHER_HALF, in pages of 2 MiB. It gives the value of cr3.
linux_page_tables_write :: proc "contextless" (memory: Guest_Memory, base: u64) -> (top: u64, ok: bool) {
	PRESENT_WRITE :: PAGE_ENTRY_PRESENT | PAGE_ENTRY_WRITE
	tables := guest_memory_range(memory, base, LINUX_PAGE_TABLE_PAGES * 4096) or_return
	for &value in tables {
		value = 0
	}
	top_table := base
	low_third := base + 0x1000
	high_third := base + 0x2000
	directories := base + 0x3000
	byte_order.write_u64_little_endian(tables, 0, low_third | PRESENT_WRITE)
	byte_order.write_u64_little_endian(tables, int(LINUX_HIGHER_HALF >> 39 & 0x1FF) * 8, high_third | PRESENT_WRITE)
	for gibibyte in 0 ..< u64(LINUX_IDENTITY_GIBIBYTES) {
		directory := directories + gibibyte * 0x1000
		byte_order.write_u64_little_endian(tables, int(0x1000 + gibibyte * 8), directory | PRESENT_WRITE)
		for entry in 0 ..< u64(512) {
			physical := gibibyte << 30 | entry << 21
			byte_order.write_u64_little_endian(tables, int(directory - base + entry * 8), physical | PRESENT_WRITE | PAGE_ENTRY_LARGE)
		}
	}
	higher_index := LINUX_HIGHER_HALF >> 30 & 0x1FF
	for gibibyte in 0 ..< u64(2) {
		byte_order.write_u64_little_endian(tables, int(0x2000 + (higher_index + gibibyte) * 8), (directories + gibibyte * 0x1000) | PRESENT_WRITE)
	}
	return top_table, true
}

// The parts of the command line that the machine of a build needs: the
// serial console from the first message, no firmware tables (acpi=off), no
// PCI bus, no I/O APIC (noapic) and no local APIC (nolapic: cpuid offers
// none, and the word keeps Linux from a probe of its registers), no random
// place of the kernel (nokaslr: the place then depends on no entropy and
// stays inside the memory that the parse checked), the time stamp counter
// as the clock with no check against the timer, and the three virtio
// devices with their windows and their lines
// (CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES). After `--`, the words go to init
// as its arguments.
LINUX_COMMAND_LINE_START :: "console=ttyS0 earlyprintk=serial,ttyS0,115200 acpi=off pci=off noapic nolapic nokaslr panic=-1 tsc=reliable no_timer_check"

// linux_command_line_write writes the command line: the fixed start, one
// virtio_mmio.device for each device, then `--` and the command of the
// build. The command is text with no control byte; the whole line must fit
// the size that the kernel reads.
linux_command_line_write :: proc "contextless" (out: []u8, devices: []Machine_Device_Place, command: []u8, bytes_most: u64) -> (count: int, refusal: Linux_Boot_Refusal) {
	if !text_encoding.text_valid(command) {
		return 0, .Command_Line_Not_Text
	}
	for value in command {
		if value < 0x20 || value == 0x7F {
			return 0, .Command_Line_Not_Text
		}
	}
	writer := Text_Writer{out = out}
	text_write(&writer, LINUX_COMMAND_LINE_START)
	for device in devices {
		text_write(&writer, " virtio_mmio.device=4K@0x")
		text_write_hex(&writer, device.base)
		text_write(&writer, ":")
		text_write_decimal(&writer, u64(device.interrupt_line))
	}
	if len(command) > 0 {
		text_write(&writer, " -- ")
		text_write(&writer, string(command))
	}
	if writer.overflow || u64(writer.count) > bytes_most {
		return 0, .Command_Line_Too_Long
	}
	return writer.count, .None
}

Text_Writer :: struct {
	out:      []u8,
	count:    int,
	overflow: bool,
}

text_write :: proc "contextless" (writer: ^Text_Writer, text: string) {
	for index in 0 ..< len(text) {
		if writer.count >= len(writer.out) {
			writer.overflow = true
			return
		}
		writer.out[writer.count] = text[index]
		writer.count += 1
	}
}

text_write_hex :: proc "contextless" (writer: ^Text_Writer, value: u64) {
	hex_digits := "0123456789abcdef"
	digits: [16]u8
	count := 0
	for remaining := value; count == 0 || remaining != 0; remaining >>= 4 {
		digits[15 - count] = hex_digits[remaining & 0xF]
		count += 1
	}
	text_write(writer, string(digits[16 - count:]))
}

text_write_decimal :: proc "contextless" (writer: ^Text_Writer, value: u64) {
	digits: [20]u8
	count := 0
	for remaining := value; count == 0 || remaining != 0; remaining /= 10 {
		digits[19 - count] = u8('0' + remaining % 10)
		count += 1
	}
	text_write(writer, string(digits[20 - count:]))
}

// linux_initial_archive_place gives the guest physical address of an
// initial archive of initial_archive_bytes bytes: the highest page-aligned
// place whose end is at most the ceiling and past no byte that the header
// allows, and whose start is at or above the end of the kernel and its
// working space. Linux takes an initial archive anywhere in its memory; the
// top keeps it away from the kernel, which decompresses itself upward.
linux_initial_archive_place :: proc "contextless" (parsed: Linux_Image, initial_archive_bytes: u64, ceiling: u64) -> (address: u64, refusal: Linux_Boot_Refusal) {
	if initial_archive_bytes == 0 {
		return 0, .None
	}
	end := ceiling
	if parsed.initial_archive_address_most < max(u64) {
		end = min(end, parsed.initial_archive_address_most + 1)
	}
	if initial_archive_bytes > end {
		return 0, .Initial_Archive_Too_Large
	}
	address = (end - initial_archive_bytes) &~ (LINUX_INITIAL_ARCHIVE_ALIGNMENT - 1)
	if address < parsed.load_end || address < LINUX_LOW_MEMORY_END {
		return 0, .Initial_Archive_Too_Large
	}
	return address, .None
}

// linux_zero_page_write writes the zero page: the setup header of a
// bzImage (or the fields that a vmlinux needs), the loader, the command
// line and the memory map.
linux_zero_page_write :: proc "contextless" (page: []u8, image: []u8, parsed: Linux_Image, command_line_address: u64, memory_map: []E820_Entry) -> Linux_Boot_Refusal {
	if len(page) < ZERO_PAGE_BYTES || len(memory_map) > ZERO_PAGE_MEMORY_MAP_ENTRIES_MOST {
		return .Memory_Too_Small
	}
	for &value in page[:ZERO_PAGE_BYTES] {
		value = 0
	}
	switch parsed.kind {
	case .Compressed:
		copy(page[SETUP_SECTORS:parsed.setup_header_end], image[SETUP_SECTORS:parsed.setup_header_end])
	case .Elf:
		byte_order.write_u16_little_endian(page, SETUP_BOOT_FLAG, 0xAA55)
		byte_order.write_u32_little_endian(page, SETUP_HEADER_MAGIC, LINUX_BOOT_HEADER_MAGIC)
		byte_order.write_u16_little_endian(page, SETUP_VERSION, parsed.protocol_version)
	}
	page[SETUP_LOADER_TYPE] = LINUX_LOADER_UNDEFINED
	page[SETUP_LOAD_FLAGS] = LINUX_LOADED_HIGH
	byte_order.write_u32_little_endian(page, SETUP_RAMDISK_ADDRESS, 0)
	byte_order.write_u32_little_endian(page, SETUP_RAMDISK_SIZE, 0)
	byte_order.write_u32_little_endian(page, SETUP_COMMAND_LINE_ADDRESS, u32(command_line_address))
	byte_order.write_u32_little_endian(page, ZERO_PAGE_EXTENDED_COMMAND_LINE, u32(command_line_address >> 32))
	page[ZERO_PAGE_MEMORY_MAP_COUNT] = u8(len(memory_map))
	for entry, index in memory_map {
		at := ZERO_PAGE_MEMORY_MAP + index * size_of(E820_Entry)
		byte_order.write_u64_little_endian(page, at, entry.addr)
		byte_order.write_u64_little_endian(page, at + 8, entry.size)
		byte_order.write_u32_little_endian(page, at + 16, entry.type)
	}
	return .None
}

// linux_boot_prepare loads a parsed image and writes each structure of the
// start in the memory of the guest, then gives the record of the first
// run: long mode, the kernel entry in rip, the zero page in rsi, and the
// selectors of the protocol. The structures below 64 KiB stay in the
// memory map as memory: Linux reserves its first 64 KiB, and copies the
// zero page and the command line before it gives a page. An initial
// archive (an archive of cpio, possibly compressed, which Linux unpacks as
// its first tree of files) goes below initial_archive_ceiling, which keeps
// it out of memory that the caller still uses (the copy of the image); nil
// gives none.
linux_boot_prepare :: proc "contextless" (memory: Guest_Memory, image: []u8, parsed: Linux_Image, devices: []Machine_Device_Place, command: []u8, initial_archive: []u8, initial_archive_ceiling: u64) -> (registers: op.Guest_Registers, refusal: Linux_Boot_Refusal) {
	memory_bytes := u64(len(memory.bytes))
	if memory_bytes < LINUX_MEMORY_BYTES_LEAST || parsed.load_end > memory_bytes {
		return {}, .Memory_Too_Small
	}
	// Each check before a byte of the guest changes.
	initial_archive_address, initial_archive_refusal := linux_initial_archive_place(parsed, u64(len(initial_archive)), min(initial_archive_ceiling, memory_bytes))
	if initial_archive_refusal != .None {
		return {}, initial_archive_refusal
	}
	if load_refusal := linux_image_load(memory, image, parsed); load_refusal != .None {
		return {}, load_refusal
	}
	descriptors := LINUX_DESCRIPTORS
	for descriptor, index in descriptors {
		_ = guest_memory_write_u64(memory, LINUX_DESCRIPTOR_TABLE_ADDRESS + u64(index) * 8, descriptor)
	}
	top, tables_written := linux_page_tables_write(memory, LINUX_PAGE_TABLES_ADDRESS)
	if !tables_written {
		return {}, .Memory_Too_Small
	}
	line_bytes, _ := guest_memory_range(memory, LINUX_COMMAND_LINE_ADDRESS, LINUX_COMMAND_LINE_BYTES_MOST)
	for &value in line_bytes {
		value = 0
	}
	if _, line_refusal := linux_command_line_write(line_bytes[:LINUX_COMMAND_LINE_BYTES_MOST - 1], devices, command, parsed.command_line_bytes_most); line_refusal != .None {
		return {}, line_refusal
	}
	memory_map: [E820_MAX_ENTRIES]E820_Entry
	map_count, map_ok := build_linux_e820({ram_bytes = memory_bytes, vcpu_count = 1}, memory_map[:])
	if !map_ok {
		return {}, .Memory_Too_Small
	}
	page, _ := guest_memory_range(memory, LINUX_ZERO_PAGE_ADDRESS, ZERO_PAGE_BYTES)
	if zero_refusal := linux_zero_page_write(page, image, parsed, LINUX_COMMAND_LINE_ADDRESS, memory_map[:map_count]); zero_refusal != .None {
		return {}, zero_refusal
	}
	// The initial archive last: the header of the image is in the zero page now.
	if len(initial_archive) > 0 {
		target, _ := guest_memory_range(memory, initial_archive_address, u64(len(initial_archive)))
		copy(target, initial_archive)
		byte_order.write_u32_little_endian(page, SETUP_RAMDISK_ADDRESS, u32(initial_archive_address))
		byte_order.write_u32_little_endian(page, SETUP_RAMDISK_SIZE, u32(len(initial_archive)))
		byte_order.write_u32_little_endian(page, ZERO_PAGE_EXTENDED_RAMDISK_ADDRESS, u32(initial_archive_address >> 32))
		byte_order.write_u32_little_endian(page, ZERO_PAGE_EXTENDED_RAMDISK_SIZE, u32(u64(len(initial_archive)) >> 32))
	}
	registers = {
		rip           = parsed.entry_address,
		rsi           = LINUX_ZERO_PAGE_ADDRESS,
		rsp           = LINUX_STACK_TOP,
		rflags        = 0x2,
		cr0           = op.GUEST_CONTROL_0_PROTECTION | op.GUEST_CONTROL_0_EXTENSION_TYPE | u64(1) << 5 | op.GUEST_CONTROL_0_PAGING, // PE, ET, NE, PG.
		cr3           = top,
		cr4           = op.GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION,
		efer          = op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_LONG_MODE_ACTIVE,
		mode_load     = u8(op.Guest_Mode_Load.Long_64),
		code_selector = LINUX_CODE_SELECTOR,
		data_selector = LINUX_DATA_SELECTOR,
	}
	return registers, .None
}
