#+build !freestanding
package guest_os

import "core:testing"
import "modus:contract/byte_order"
import op "modus:contract/operation"

TEST_MEMORY_BYTES :: 64 * 1024 * 1024
TEST_BZ_IMAGE_BYTES :: 0x2000

// test_bz_image writes a bzImage of protocol 2.15 with one sector of setup
// and a protected-mode part whose bytes count from 1.
test_bz_image :: proc(image: []u8) {
	for &value, index in image {
		value = u8(index)
	}
	for &value in image[:1024] {
		value = 0
	}
	image[SETUP_SECTORS] = 1
	byte_order.write_u16_little_endian(image, SETUP_BOOT_FLAG, 0xAA55)
	image[SETUP_JUMP] = 0xEB
	image[SETUP_JUMP + 1] = 0x6A // The header ends at 0x26C.
	byte_order.write_u32_little_endian(image, SETUP_HEADER_MAGIC, LINUX_BOOT_HEADER_MAGIC)
	byte_order.write_u16_little_endian(image, SETUP_VERSION, 0x020F)
	image[SETUP_LOAD_FLAGS] = LINUX_LOADED_HIGH
	byte_order.write_u32_little_endian(image, SETUP_KERNEL_ALIGNMENT, 0x20_0000)
	image[SETUP_RELOCATABLE] = 1
	byte_order.write_u16_little_endian(image, SETUP_EXTENDED_LOAD_FLAGS, LINUX_EXTENDED_KERNEL_64)
	byte_order.write_u32_little_endian(image, SETUP_COMMAND_LINE_SIZE, 2047)
	byte_order.write_u64_little_endian(image, SETUP_PREFERRED_ADDRESS, 0x100_0000)
	byte_order.write_u32_little_endian(image, SETUP_INITIAL_SIZE, 0x10_0000)
}

test_parse :: proc(image: []u8, memory_bytes: u64 = TEST_MEMORY_BYTES) -> Linux_Boot_Refusal {
	_, refusal := linux_image_parse(image, memory_bytes)
	return refusal
}

// Each field of the setup header that the boot reads is checked, and a cut
// image is refused at each length up to the end of its setup part.
@(test)
bz_image_refusals :: proc(t: ^testing.T) {
	image: [TEST_BZ_IMAGE_BYTES]u8
	test_bz_image(image[:])
	for length in ([?]int{0, 1, 0x1FE, 0x200, 0x205, 0x263, 0x3FF, 0x400}) {
		refusal := test_parse(image[:length])
		testing.expectf(t, refusal == .Truncated || refusal == .Unknown_Format, "a cut at %v is refused, got %v", length, refusal)
	}
	testing.expect_value(t, test_parse(image[:0x400]), Linux_Boot_Refusal.Truncated)
	cases := [?]struct {
		offset: int,
		value:  u8,
		want:   Linux_Boot_Refusal,
	} {
		{SETUP_BOOT_FLAG, 0x00, .Unknown_Format},
		{SETUP_HEADER_MAGIC, 'X', .Unknown_Format},
		{SETUP_VERSION, 0x0B, .Old_Protocol}, // 2.11
		{SETUP_EXTENDED_LOAD_FLAGS, 0x02, .Not_Sixty_Four_Bit},
		{SETUP_LOAD_FLAGS, 0x00, .Not_Loaded_High},
		{SETUP_KERNEL_ALIGNMENT + 2, 0x30, .Bad_Alignment}, // 0x30_0000: not a power of two.
		{SETUP_JUMP + 1, 0x10, .Truncated}, // The header ends before the initial size.
		{SETUP_SECTORS, 15, .Truncated}, // A setup part past the end of the image.
	}
	for entry in cases {
		changed := image
		changed[entry.offset] = entry.value
		testing.expectf(t, test_parse(changed[:]) == entry.want, "offset %x value %x gives %v", entry.offset, entry.value, test_parse(changed[:]))
	}
	zero_alignment := image
	byte_order.write_u32_little_endian(zero_alignment[:], SETUP_KERNEL_ALIGNMENT, 0)
	testing.expect_value(t, test_parse(zero_alignment[:]), Linux_Boot_Refusal.Bad_Alignment)
	fixed := image
	fixed[SETUP_RELOCATABLE] = 0
	byte_order.write_u64_little_endian(fixed[:], SETUP_PREFERRED_ADDRESS, 0x100_1000)
	testing.expect_value(t, test_parse(fixed[:]), Linux_Boot_Refusal.Bad_Alignment)
	huge := image
	byte_order.write_u32_little_endian(huge[:], SETUP_INITIAL_SIZE, max(u32))
	testing.expect_value(t, test_parse(huge[:]), Linux_Boot_Refusal.Memory_Too_Small)
	far := image
	byte_order.write_u64_little_endian(far[:], SETUP_PREFERRED_ADDRESS, 0xFFFF_FFFF_FFE0_0000)
	testing.expect_value(t, test_parse(far[:]), Linux_Boot_Refusal.Memory_Too_Small)
	// The round up of a relocatable kernel near the top of the addresses
	// wraps to 0: refused, not loaded at 0.
	for preferred in ([?]u64{0xFFFF_FFFF_FFE0_0001, 0xFFFF_FFFF_FFFF_F000, max(u64)}) {
		wrapping := image
		byte_order.write_u64_little_endian(wrapping[:], SETUP_PREFERRED_ADDRESS, preferred)
		testing.expectf(t, test_parse(wrapping[:]) == .Bad_Alignment, "preferred %x gives %v", preferred, test_parse(wrapping[:]))
		testing.expectf(t, test_parse(wrapping[:], max(u64)) == .Bad_Alignment, "preferred %x with all the memory gives %v", preferred, test_parse(wrapping[:], max(u64)))
	}
	testing.expect_value(t, test_parse(image[:], TEST_MEMORY_BYTES - 1), Linux_Boot_Refusal.Memory_Too_Small)
	testing.expect_value(t, test_parse(image[:0x400 + 0x200]), Linux_Boot_Refusal.Entry_Outside)
	// The successful case last: a preferred address below 1 MiB goes to
	// 16 MiB, a misaligned one of a relocatable kernel is aligned up.
	low := image
	byte_order.write_u64_little_endian(low[:], SETUP_PREFERRED_ADDRESS, 0x8000)
	parsed, refusal := linux_image_parse(low[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	testing.expect_value(t, parsed.load_address, LINUX_KERNEL_ADDRESS)
	moved := image
	byte_order.write_u64_little_endian(moved[:], SETUP_PREFERRED_ADDRESS, 0x110_0000)
	parsed, refusal = linux_image_parse(moved[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, parsed.load_address, u64(0x120_0000))
	parsed, refusal = linux_image_parse(image[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	testing.expect_value(t, parsed.kind, Linux_Image_Kind.Compressed)
	testing.expect_value(t, parsed.setup_bytes, u64(1024))
	testing.expect_value(t, parsed.setup_header_end, u64(0x26C))
	testing.expect_value(t, parsed.entry_address, u64(0x100_0200))
	testing.expect_value(t, parsed.load_end, u64(0x110_0000))
	testing.expect_value(t, parsed.command_line_bytes_most, u64(2047))
}

// The whole start of a bzImage: the kernel at its place, the zero page, the
// command line, the descriptors at 0, a page table that maps the low
// memory at its own address and at the higher half, and a record that the
// kernel accepts.
@(test)
bz_image_boot_prepare :: proc(t: ^testing.T) {
	image: [TEST_BZ_IMAGE_BYTES]u8
	test_bz_image(image[:])
	bytes := make([]u8, TEST_MEMORY_BYTES)
	defer delete(bytes)
	for &value in bytes[0x100_0000:0x120_0000] {
		value = 0xEE // Old bytes in the working space: the load clears them.
	}
	memory := Guest_Memory{bytes}
	parsed, _ := linux_image_parse(image[:], TEST_MEMORY_BYTES)
	places := linux_machine_places()
	command := "make -C /inputs/src install DESTDIR=/outputs"
	registers, refusal := linux_boot_prepare(memory, image[:], parsed, places[:], transmute([]u8)command, nil, TEST_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	_, record_refusal := op.guest_registers_check(registers)
	testing.expect_value(t, record_refusal, op.Guest_Registers_Refusal.None)
	testing.expect_value(t, registers.rip, u64(0x100_0200))
	testing.expect_value(t, registers.rsi, LINUX_ZERO_PAGE_ADDRESS)
	testing.expect_value(t, registers.mode_load, u8(op.Guest_Mode_Load.Long_64))
	testing.expect_value(t, registers.code_selector, LINUX_CODE_SELECTOR)
	testing.expect_value(t, registers.rflags & op.GUEST_FLAGS_INTERRUPT, u64(0))
	// The protected-mode part, then zeros to the end of the working space.
	testing.expect(t, bytes[0x100_0000] == image[1024] && bytes[0x100_0000 + 0x1BFF] == image[0x1FFF])
	testing.expect_value(t, bytes[0x100_0000 + 0x1C00], u8(0))
	testing.expect_value(t, bytes[0x10F_FFFF], u8(0))
	testing.expect_value(t, bytes[0x110_0000], u8(0xEE)) // Past the working space: not touched.
	// The descriptors of the protocol at 0x10 and 0x18.
	value, _ := guest_memory_read_u64(memory, 0x10)
	testing.expect_value(t, value, u64(0x00AF_9B00_0000_FFFF))
	value, _ = guest_memory_read_u64(memory, 0x18)
	testing.expect_value(t, value, u64(0x00CF_9300_0000_FFFF))
	// The zero page: the copied header, the loader, the command line, the map.
	page := bytes[LINUX_ZERO_PAGE_ADDRESS:][:ZERO_PAGE_BYTES]
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_HEADER_MAGIC), LINUX_BOOT_HEADER_MAGIC)
	testing.expect_value(t, byte_order.read_u16_little_endian(page, SETUP_VERSION), u16(0x020F))
	testing.expect_value(t, page[SETUP_LOADER_TYPE], LINUX_LOADER_UNDEFINED)
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_COMMAND_LINE_ADDRESS), u32(LINUX_COMMAND_LINE_ADDRESS))
	testing.expect_value(t, page[ZERO_PAGE_MEMORY_MAP_COUNT], u8(3))
	testing.expect_value(t, byte_order.read_u64_little_endian(page, ZERO_PAGE_MEMORY_MAP + 40), u64(0x10_0000))
	testing.expect_value(t, byte_order.read_u64_little_endian(page, ZERO_PAGE_MEMORY_MAP + 48), u64(TEST_MEMORY_BYTES - 0x10_0000))
	testing.expect_value(t, byte_order.read_u32_little_endian(page, ZERO_PAGE_MEMORY_MAP + 56), u32(E820_Type.Ram))
	// Nothing of the header past its end.
	testing.expect_value(t, page[0x26C], u8(0))
	line := string(bytes[LINUX_COMMAND_LINE_ADDRESS:][:LINUX_COMMAND_LINE_BYTES_MOST])
	EXPECTED_START :: LINUX_COMMAND_LINE_START + " virtio_mmio.device=4K@0xd0000000:5 virtio_mmio.device=4K@0xd0001000:10 virtio_mmio.device=4K@0xd0002000:11 -- "
	testing.expect_value(t, line[:len(EXPECTED_START)], EXPECTED_START)
	testing.expect_value(t, line[len(EXPECTED_START):][:len(command)], command)
	testing.expect_value(t, line[len(EXPECTED_START) + len(command)], 0)
	// The page table.
	for address in ([?]u64{0, 0x7000, 0x100_0200, 0xD000_0000, 0xFEE0_0000, 0xFFFF_FFFF}) {
		physical, mapped := guest_linear_to_physical(memory, registers, address)
		testing.expectf(t, mapped && physical == address, "%x maps at its own address", address)
	}
	physical, mapped := guest_linear_to_physical(memory, registers, LINUX_HIGHER_HALF + 0x100_0200)
	testing.expect(t, mapped && physical == 0x100_0200)
	physical, mapped = guest_linear_to_physical(memory, registers, LINUX_HIGHER_HALF + 0x7FFF_FFFF)
	testing.expect(t, mapped && physical == 0x7FFF_FFFF)
	_, mapped = guest_linear_to_physical(memory, registers, 0x1_0000_0000)
	testing.expect(t, !mapped)
	_, mapped = guest_linear_to_physical(memory, registers, 0x0000_7FFF_FFFF_F000)
	testing.expect(t, !mapped)
}

// The command line refuses a command with a control byte or text that is
// not valid, and a line past the size that the kernel reads; nothing
// reaches the memory then.
@(test)
command_line_refusals :: proc(t: ^testing.T) {
	places := linux_machine_places()
	out: [LINUX_COMMAND_LINE_BYTES_MOST]u8
	for command in ([?]string{"echo\x00", "a\nb", "tab\there", "del\x7f", "\xff\xfe"}) {
		_, refusal := linux_command_line_write(out[:], places[:], transmute([]u8)command, 2047)
		testing.expectf(t, refusal == .Command_Line_Not_Text, "%q is refused", command)
	}
	count, refusal := linux_command_line_write(out[:], places[:], nil, 2047)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	_, refusal = linux_command_line_write(out[:], places[:], nil, u64(count - 1))
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Command_Line_Too_Long)
	_, refusal = linux_command_line_write(out[:count - 1], places[:], nil, 2047)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Command_Line_Too_Long)
	long: [LINUX_COMMAND_LINE_BYTES_MOST]u8
	for &value in long {
		value = 'a'
	}
	_, refusal = linux_command_line_write(out[:], places[:], long[:], 2047)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Command_Line_Too_Long)
	// The successful case last: exactly the size that the kernel reads.
	_, refusal = linux_command_line_write(out[:], places[:], nil, u64(count))
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	image: [TEST_BZ_IMAGE_BYTES]u8
	test_bz_image(image[:])
	byte_order.write_u32_little_endian(image[:], SETUP_COMMAND_LINE_SIZE, 64)
	bytes := make([]u8, TEST_MEMORY_BYTES)
	defer delete(bytes)
	parsed, _ := linux_image_parse(image[:], TEST_MEMORY_BYTES)
	_, prepare_refusal := linux_boot_prepare({bytes}, image[:], parsed, places[:], nil, nil, TEST_MEMORY_BYTES)
	testing.expect_value(t, prepare_refusal, Linux_Boot_Refusal.Command_Line_Too_Long)
}

TEST_ELF_BYTES :: 0x3000

// test_elf writes a vmlinux with two loaded segments: text at 16 MiB from
// the file offset 0x1000, and data with a bss at 18 MiB.
test_elf :: proc(image: []u8) {
	for &value, index in image {
		value = u8(index * 7)
	}
	for &value in image[:0x200] {
		value = 0
	}
	copy(image, []u8{0x7F, 'E', 'L', 'F', 2, 1, 1})
	byte_order.write_u16_little_endian(image, 16, 2)
	byte_order.write_u16_little_endian(image, 18, 0x3E)
	byte_order.write_u64_little_endian(image, 0x18, 0x100_0000)
	byte_order.write_u64_little_endian(image, 0x20, 0x40)
	byte_order.write_u16_little_endian(image, 0x36, 56)
	byte_order.write_u16_little_endian(image, 0x38, 3)
	segment :: proc(image: []u8, at: int, kind: u32, offset, physical, file_bytes, memory_bytes: u64) {
		byte_order.write_u32_little_endian(image, at, kind)
		byte_order.write_u64_little_endian(image, at + 0x08, offset)
		byte_order.write_u64_little_endian(image, at + 0x10, physical | 0xFFFF_FFFF_8000_0000)
		byte_order.write_u64_little_endian(image, at + 0x18, physical)
		byte_order.write_u64_little_endian(image, at + 0x20, file_bytes)
		byte_order.write_u64_little_endian(image, at + 0x28, memory_bytes)
	}
	segment(image, 0x40, 1, 0x1000, 0x100_0000, 0x1000, 0x1000)
	segment(image, 0x40 + 56, 4, 0, 0, 0x10, 0x10) // A note: not loaded.
	segment(image, 0x40 + 112, 1, 0x2000, 0x120_0000, 0x800, 0x4000)
}

@(test)
elf_refusals_and_load :: proc(t: ^testing.T) {
	image: [TEST_ELF_BYTES]u8
	test_elf(image[:])
	testing.expect_value(t, test_parse(image[:63]), Linux_Boot_Refusal.Truncated)
	edits := [?]struct {
		offset: int,
		value:  u64,
		bytes:  int,
		want:   Linux_Boot_Refusal,
	} {
		{4, 1, 1, .Unknown_Format}, // 32-bit.
		{5, 2, 1, .Unknown_Format}, // Big-endian.
		{18, 0x03, 2, .Unknown_Format}, // i386.
		{16, 3, 2, .Unknown_Format}, // A shared object.
		{0x36, 32, 2, .Unknown_Format},
		{0x20, TEST_ELF_BYTES - 56, 8, .Truncated}, // The program table past the end.
		{0x20, max(u64) - 8, 8, .Truncated},
		{0x40 + 0x08, TEST_ELF_BYTES - 0x800, 8, .Truncated}, // The text past the end of the file.
		{0x40 + 0x08, max(u64), 8, .Truncated},
		{0x40 + 0x18, 0xF_F000, 8, .Bad_Segment}, // Below 1 MiB.
		{0x40 + 0x20, 0x1001, 8, .Bad_Segment}, // Bigger in the file than in memory.
		{0x40 + 0x28, max(u64), 8, .Memory_Too_Small},
		{0x40 + 0x18, TEST_MEMORY_BYTES - 0x800, 8, .Memory_Too_Small},
		{0x40 + 112 + 0x18, 0x100_0800, 8, .Bad_Segment}, // The data overlaps the text.
		{0x18, 0x100_1000, 8, .Entry_Outside}, // Past the text.
		{0x18, 0x120_0900, 8, .Entry_Outside}, // In the bss: not a loaded byte.
		{0x18, 0xFFFF_FFFF_8100_0000, 8, .Entry_Outside}, // A virtual address.
		{0x40, 2, 4, .Bad_Segment}, // The text is no more loaded: then the entry is in nothing.
	}
	for edit in edits {
		changed := image
		for index in 0 ..< edit.bytes {
			changed[edit.offset + index] = u8(edit.value >> (u64(index) * 8))
		}
		refusal := test_parse(changed[:])
		want := edit.want
		if edit.offset == 0x40 && edit.value == 2 {
			want = .Entry_Outside
		}
		testing.expectf(t, refusal == want, "offset %x value %x gives %v, not %v", edit.offset, edit.value, refusal, want)
	}
	none := image
	byte_order.write_u16_little_endian(none[:], 0x38, 0)
	testing.expect_value(t, test_parse(none[:]), Linux_Boot_Refusal.Bad_Segment)
	// The successful case last: the text and the data at their places, the
	// bss cleared, the note not loaded.
	parsed, refusal := linux_image_parse(image[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.None)
	testing.expect_value(t, parsed.segment_count, 2)
	testing.expect_value(t, parsed.load_address, u64(0x100_0000))
	testing.expect_value(t, parsed.load_end, u64(0x120_4000))
	bytes := make([]u8, TEST_MEMORY_BYTES)
	defer delete(bytes)
	for &value in bytes[0x120_0000:0x120_4000] {
		value = 0xEE
	}
	places := linux_machine_places()
	registers, prepare_refusal := linux_boot_prepare({bytes}, image[:], parsed, places[:], nil, nil, TEST_MEMORY_BYTES)
	testing.expect_value(t, prepare_refusal, Linux_Boot_Refusal.None)
	testing.expect_value(t, registers.rip, u64(0x100_0000))
	testing.expect(t, bytes[0x100_0000] == image[0x1000] && bytes[0x100_0FFF] == image[0x1FFF])
	testing.expect(t, bytes[0x120_0000] == image[0x2000] && bytes[0x120_07FF] == image[0x27FF])
	testing.expect_value(t, bytes[0x120_0800], u8(0))
	testing.expect_value(t, bytes[0x120_3FFF], u8(0))
	page := bytes[LINUX_ZERO_PAGE_ADDRESS:][:ZERO_PAGE_BYTES]
	testing.expect_value(t, byte_order.read_u16_little_endian(page, SETUP_BOOT_FLAG), u16(0xAA55))
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_HEADER_MAGIC), LINUX_BOOT_HEADER_MAGIC)
}


// The place of an initial archive: the top of the memory under the ceiling and the
// highest address of the header, page-aligned, above the kernel; nothing
// changes in the memory when it does not fit.
@(test)
initial_archive_place_and_refusals :: proc(t: ^testing.T) {
	image: [TEST_BZ_IMAGE_BYTES]u8
	test_bz_image(image[:])
	byte_order.write_u32_little_endian(image[:], SETUP_INITIAL_ARCHIVE_ADDRESS_MOST, 0x37FF_FFFF)
	parsed, _ := linux_image_parse(image[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, parsed.initial_archive_address_most, u64(0x37FF_FFFF))
	// The kernel and its working space end at 0x110_0000.
	room := u64(TEST_MEMORY_BYTES) - parsed.load_end
	refusals := [?]struct {
		bytes:   u64,
		ceiling: u64,
	} {
		{room + 1, TEST_MEMORY_BYTES}, // One byte past the room.
		{max(u64), TEST_MEMORY_BYTES},
		{1, parsed.load_end}, // No room under the ceiling.
		{1, 0},
		{0x1000, parsed.load_end + 0xFFF}, // The page-aligned place falls inside the kernel.
	}
	for entry in refusals {
		_, refusal := linux_initial_archive_place(parsed, entry.bytes, entry.ceiling)
		testing.expectf(t, refusal == .Initial_Archive_Too_Large, "%x bytes under %x give %v", entry.bytes, entry.ceiling, refusal)
	}
	// The highest address of the header bounds the place, not only the
	// ceiling.
	low := parsed
	low.initial_archive_address_most = parsed.load_end + 0x1FFF
	address, refusal := linux_initial_archive_place(low, 0x2000, TEST_MEMORY_BYTES)
	testing.expect(t, refusal == .None && address == parsed.load_end)
	_, refusal = linux_initial_archive_place(low, 0x2001, TEST_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Initial_Archive_Too_Large)
	// The flag of an initial archive above 4 GiB lifts the bound of the header.
	above := image
	byte_order.write_u16_little_endian(above[:], SETUP_EXTENDED_LOAD_FLAGS, LINUX_EXTENDED_KERNEL_64 | LINUX_EXTENDED_INITIAL_ARCHIVE_ABOVE_4G)
	byte_order.write_u32_little_endian(above[:], SETUP_INITIAL_ARCHIVE_ADDRESS_MOST, 0)
	parsed_above, _ := linux_image_parse(above[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, parsed_above.initial_archive_address_most, max(u64))
	// A header that allows no initial archive: refused, and the memory is unchanged.
	none := image
	byte_order.write_u32_little_endian(none[:], SETUP_INITIAL_ARCHIVE_ADDRESS_MOST, 0)
	parsed_none, _ := linux_image_parse(none[:], TEST_MEMORY_BYTES)
	bytes := make([]u8, TEST_MEMORY_BYTES)
	defer delete(bytes)
	places := linux_machine_places()
	initial_archive := [?]u8{'0', '7', '0', '7', '0', '1'}
	_, prepare_refusal := linux_boot_prepare({bytes}, none[:], parsed_none, places[:], nil, initial_archive[:], TEST_MEMORY_BYTES)
	testing.expect_value(t, prepare_refusal, Linux_Boot_Refusal.Initial_Archive_Too_Large)
	for value in bytes {
		if value != 0 {
			testing.fail_now(t, "a refused initial archive changed the memory")
		}
	}
	// The successful case last: an initial archive of 5000 bytes under a ceiling of
	// 60 MiB, its fields in the zero page.
	ceiling := u64(60 * 1024 * 1024)
	archive := make([]u8, 5000)
	defer delete(archive)
	for &value, index in archive {
		value = u8(index * 13 + 1)
	}
	registers: op.Guest_Registers
	registers, prepare_refusal = linux_boot_prepare({bytes}, image[:], parsed, places[:], nil, archive, ceiling)
	testing.expect_value(t, prepare_refusal, Linux_Boot_Refusal.None)
	testing.expect_value(t, registers.rsi, LINUX_ZERO_PAGE_ADDRESS)
	want := (ceiling - 5000) &~ 0xFFF
	page := bytes[LINUX_ZERO_PAGE_ADDRESS:][:ZERO_PAGE_BYTES]
	testing.expect_value(t, u64(byte_order.read_u32_little_endian(page, SETUP_RAMDISK_ADDRESS)), want)
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_RAMDISK_SIZE), u32(5000))
	testing.expect_value(t, byte_order.read_u32_little_endian(page, ZERO_PAGE_EXTENDED_RAMDISK_ADDRESS), u32(0))
	testing.expect_value(t, byte_order.read_u32_little_endian(page, ZERO_PAGE_EXTENDED_RAMDISK_SIZE), u32(0))
	testing.expect(t, string(bytes[want:][:5000]) == string(archive))
	testing.expect_value(t, bytes[want + 5000], u8(0))
	// The header of the image is still in the zero page.
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_HEADER_MAGIC), LINUX_BOOT_HEADER_MAGIC)
}
