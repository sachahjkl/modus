#+build !freestanding
#+build !modus
package guest_os

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/byte_order"
import op "modus:contract/operation"

// The test of a real kernel of Linux: the bzImage that Nixpkgs builds, which
// the development shell names in MODUS_LINUX_KERNEL_IMAGE (flake.nix). With
// no such image, the test says so and checks nothing: the image is about
// 13 MiB, and the host checks of the flake do not carry it.
LINUX_KERNEL_IMAGE_VARIABLE :: "MODUS_LINUX_KERNEL_IMAGE"
REAL_KERNEL_MEMORY_BYTES :: 128 * 1024 * 1024

// test_cpio_newc writes an archive of cpio in the "newc" form (the form of
// an initial archive): a header of 110 bytes of text for each file, the
// name, the data, each padded to 4 bytes, then the entry TRAILER!!!.
test_cpio_newc :: proc(names: []string, contents: []string) -> []u8 {
	builder := strings.builder_make()
	pad :: proc(builder: ^strings.Builder) {
		for strings.builder_len(builder^) % 4 != 0 {
			strings.write_byte(builder, 0)
		}
	}
	entry :: proc(builder: ^strings.Builder, inode: int, name: string, data: string, mode: u32) {
		hex :: proc(builder: ^strings.Builder, value: u32) {
			digits := "0123456789ABCDEF"
			for shift := 28; shift >= 0; shift -= 4 {
				strings.write_byte(builder, digits[value >> u32(shift) & 0xF])
			}
		}
		strings.write_string(builder, "070701")
		fields := [13]u32{u32(inode), mode, 0, 0, 1, 0, u32(len(data)), 0, 0, 0, 0, u32(len(name) + 1), 0}
		for field in fields {
			hex(builder, field)
		}
		strings.write_string(builder, name)
		strings.write_byte(builder, 0)
		pad(builder)
		strings.write_string(builder, data)
		pad(builder)
	}
	for name, index in names {
		entry(&builder, index + 1, name, contents[index], 0o100755)
	}
	entry(&builder, 0, "TRAILER!!!", "", 0)
	return builder.buf[:]
}

@(test)
real_linux_bz_image_boot_prepare :: proc(t: ^testing.T) {
	path := os.get_env(LINUX_KERNEL_IMAGE_VARIABLE, context.temp_allocator)
	if path == "" {
		log.infof("%v is not set: no real kernel to check", LINUX_KERNEL_IMAGE_VARIABLE)
		return
	}
	image, read_error := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, read_error == nil, "read %v: %v", path, read_error) {
		return
	}
	defer delete(image)
	log.infof("%v: %v bytes", path, len(image))

	// The header, as the kernel states it.
	sectors := u64(image[SETUP_SECTORS])
	protocol := byte_order.read_u16_little_endian(image, SETUP_VERSION)
	extended := byte_order.read_u16_little_endian(image, SETUP_EXTENDED_LOAD_FLAGS)
	preferred := byte_order.read_u64_little_endian(image, SETUP_PREFERRED_ADDRESS)
	initial := u64(byte_order.read_u32_little_endian(image, SETUP_INITIAL_SIZE))
	log.infof("protocol %x, setup sectors %v, extended load flags %x, preferred %x, initial size %x", protocol, sectors, extended, preferred, initial)

	// The refusals first, on the real bytes: a memory under the initial
	// size, a protocol of 2.11, no 64-bit entry, a cut image.
	_, refusal := linux_image_parse(image, preferred + initial - 1)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Memory_Too_Small)
	changed := make([]u8, len(image))
	defer delete(changed)
	copy(changed, image)
	byte_order.write_u16_little_endian(changed, SETUP_VERSION, 0x020B)
	_, refusal = linux_image_parse(changed, REAL_KERNEL_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Old_Protocol)
	copy(changed, image)
	byte_order.write_u16_little_endian(changed, SETUP_EXTENDED_LOAD_FLAGS, extended &~ LINUX_EXTENDED_KERNEL_64)
	_, refusal = linux_image_parse(changed, REAL_KERNEL_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Not_Sixty_Four_Bit)
	_, refusal = linux_image_parse(image[:(sectors + 1) * 512], REAL_KERNEL_MEMORY_BYTES)
	testing.expect_value(t, refusal, Linux_Boot_Refusal.Truncated)

	parsed: Linux_Image
	parsed, refusal = linux_image_parse(image, REAL_KERNEL_MEMORY_BYTES)
	if !testing.expect_value(t, refusal, Linux_Boot_Refusal.None) {
		return
	}
	testing.expect_value(t, parsed.kind, Linux_Image_Kind.Compressed)
	testing.expect(t, parsed.protocol_version >= LINUX_PROTOCOL_LEAST && parsed.protocol_version == protocol)
	testing.expect_value(t, parsed.setup_bytes, (sectors + 1) * 512)
	testing.expect_value(t, parsed.setup_header_end, min(u64(SETUP_HEADER_MAGIC) + u64(image[SETUP_JUMP + 1]), SETUP_HEADER_END_MOST))
	testing.expect_value(t, parsed.load_address, preferred)
	testing.expect_value(t, parsed.entry_address, preferred + LINUX_ENTRY_64_OFFSET)
	testing.expect_value(t, parsed.load_end, preferred + max(initial, u64(len(image)) - parsed.setup_bytes))
	testing.expect_value(t, parsed.command_line_bytes_most, min(u64(byte_order.read_u32_little_endian(image, SETUP_COMMAND_LINE_SIZE)), LINUX_COMMAND_LINE_BYTES_MOST - 1))
	if extended & LINUX_EXTENDED_INITIAL_ARCHIVE_ABOVE_4G != 0 {
		testing.expect_value(t, parsed.initial_archive_address_most, max(u64))
	} else {
		testing.expect_value(t, parsed.initial_archive_address_most, u64(byte_order.read_u32_little_endian(image, SETUP_INITIAL_ARCHIVE_ADDRESS_MOST)))
	}

	// A tiny initial archive whose init is a script, and the command of a build.
	initial_archive := test_cpio_newc({"init"}, {"#!/bin/sh\nexec /inputs/build\n"})
	defer delete(initial_archive)
	testing.expect_value(t, len(initial_archive) % 4, 0)
	memory_bytes := make([]u8, REAL_KERNEL_MEMORY_BYTES)
	defer delete(memory_bytes)
	memory := Guest_Memory{memory_bytes}
	places := linux_machine_places()
	command := "make -C /inputs install"
	registers: op.Guest_Registers
	registers, refusal = linux_boot_prepare(memory, image, parsed, places[:], transmute([]u8)command, initial_archive, REAL_KERNEL_MEMORY_BYTES)
	if !testing.expect_value(t, refusal, Linux_Boot_Refusal.None) {
		return
	}
	_, record_refusal := op.guest_registers_check(registers)
	testing.expect_value(t, record_refusal, op.Guest_Registers_Refusal.None)
	testing.expect_value(t, registers.mode_load, u8(op.Guest_Mode_Load.Long_64))
	testing.expect_value(t, registers.rip, parsed.entry_address)
	testing.expect_value(t, registers.rsi, LINUX_ZERO_PAGE_ADDRESS)
	testing.expect(t, registers.code_selector == LINUX_CODE_SELECTOR && registers.data_selector == LINUX_DATA_SELECTOR)
	testing.expect_value(t, registers.rflags & op.GUEST_FLAGS_INTERRUPT, u64(0))

	// The protected-mode kernel at its place, then zeros to the end of its
	// working space. startup_64 of the decompressor starts with cld; cli.
	payload := image[parsed.setup_bytes:]
	testing.expect(t, string(memory_bytes[parsed.load_address:][:len(payload)]) == string(payload))
	entry_bytes: [2]u8
	testing.expect_value(t, guest_instruction_fetch(memory, registers, registers.rip, entry_bytes[:]), 2)
	testing.expect(t, entry_bytes == [2]u8{0xFC, 0xFA})
	for address := parsed.load_address + u64(len(payload)); address < parsed.load_end; address += 4096 {
		if memory_bytes[address] != 0 {
			testing.fail_now(t, "the working space of the kernel is not cleared")
		}
	}

	// The zero page: the header of the image, with the fields of the loader.
	page := memory_bytes[LINUX_ZERO_PAGE_ADDRESS:][:ZERO_PAGE_BYTES]
	loader_fields := [?]struct {
		offset: int,
		bytes:  int,
	}{{SETUP_LOADER_TYPE, 1}, {SETUP_LOAD_FLAGS, 1}, {SETUP_RAMDISK_ADDRESS, 8}, {SETUP_COMMAND_LINE_ADDRESS, 4}}
	for offset in SETUP_SECTORS ..< int(parsed.setup_header_end) {
		written_by_loader := false
		for field in loader_fields {
			if offset >= field.offset && offset < field.offset + field.bytes {
				written_by_loader = true
			}
		}
		if !written_by_loader && page[offset] != image[offset] {
			testing.fail_now(t, "the zero page does not hold the header of the image")
		}
	}
	testing.expect_value(t, page[SETUP_LOADER_TYPE], LINUX_LOADER_UNDEFINED)
	testing.expect(t, page[SETUP_LOAD_FLAGS] & LINUX_LOADED_HIGH != 0)
	testing.expect_value(t, page[0x1EF], u8(0)) // The sentinel: a loader that copies the header whole leaves it 0.
	// The memory map: low memory, the hole of the firmware, and the rest.
	testing.expect_value(t, page[ZERO_PAGE_MEMORY_MAP_COUNT], u8(3))
	map_entry :: proc(page: []u8, index: int) -> (address: u64, size: u64, kind: u32) {
		at := ZERO_PAGE_MEMORY_MAP + index * size_of(E820_Entry)
		return byte_order.read_u64_little_endian(page, at), byte_order.read_u64_little_endian(page, at + 8), byte_order.read_u32_little_endian(page, at + 16)
	}
	map_address, map_size, map_kind := map_entry(page, 0)
	testing.expect(t, map_address == 0 && map_size == 0x9_FC00 && map_kind == u32(E820_Type.Ram))
	map_address, map_size, map_kind = map_entry(page, 1)
	testing.expect(t, map_address == 0x9_FC00 && map_address + map_size == LINUX_LOW_MEMORY_END && map_kind == u32(E820_Type.Reserved))
	map_address, map_size, map_kind = map_entry(page, 2)
	testing.expect(t, map_address == LINUX_LOW_MEMORY_END && map_address + map_size == REAL_KERNEL_MEMORY_BYTES && map_kind == u32(E820_Type.Ram))
	testing.expect(t, parsed.load_end <= REAL_KERNEL_MEMORY_BYTES)

	// The initial archive: page-aligned at the top, above the kernel, its bytes and
	// its fields in place.
	initial_archive_address := u64(byte_order.read_u32_little_endian(page, SETUP_RAMDISK_ADDRESS)) | u64(byte_order.read_u32_little_endian(page, ZERO_PAGE_EXTENDED_RAMDISK_ADDRESS)) << 32
	testing.expect_value(t, byte_order.read_u32_little_endian(page, SETUP_RAMDISK_SIZE), u32(len(initial_archive)))
	testing.expect_value(t, initial_archive_address % LINUX_INITIAL_ARCHIVE_ALIGNMENT, u64(0))
	testing.expect(t, initial_archive_address >= parsed.load_end && initial_archive_address + u64(len(initial_archive)) <= REAL_KERNEL_MEMORY_BYTES)
	testing.expect(t, string(memory_bytes[initial_archive_address:][:len(initial_archive)]) == string(initial_archive))
	testing.expect(t, string(memory_bytes[initial_archive_address:][:6]) == "070701")

	// The command line: the console, no firmware tables, no random place,
	// the three devices, then the command for init.
	line_end := LINUX_COMMAND_LINE_ADDRESS
	for memory_bytes[line_end] != 0 {
		line_end += 1
	}
	line := string(memory_bytes[LINUX_COMMAND_LINE_ADDRESS:line_end])
	log.infof("command line: %v", line)
	testing.expect(t, u64(len(line)) <= parsed.command_line_bytes_most)
	for word in ([?]string{"console=ttyS0", "acpi=off", "noapic", "nolapic", "nokaslr", "virtio_mmio.device=4K@0xd0000000:5", "virtio_mmio.device=4K@0xd0001000:10", "virtio_mmio.device=4K@0xd0002000:11"}) {
		testing.expectf(t, strings.contains(line, word), "the command line holds %v", word)
	}
	testing.expect(t, strings.has_suffix(line, " -- make -C /inputs install"))

	// The page table maps the entry, the zero page, the initial archive and the
	// windows of the devices at their own address, and the kernel again at
	// the higher half.
	for address in ([?]u64{registers.rip, LINUX_ZERO_PAGE_ADDRESS, LINUX_COMMAND_LINE_ADDRESS, initial_archive_address, 0xD000_2FFC}) {
		physical, mapped := guest_linear_to_physical(memory, registers, address)
		testing.expectf(t, mapped && physical == address, "%x maps at its own address", address)
	}
	physical, mapped := guest_linear_to_physical(memory, registers, LINUX_HIGHER_HALF + parsed.load_address)
	testing.expect(t, mapped && physical == parsed.load_address)
}
