#+build !freestanding
package guest_os

import "core:testing"
import "modus:contract/byte_order"

@(test)
linux_guest_boot_and_nt_pe64_compat_contracts :: proc(t: ^testing.T) {
	_, bad_vm := vm_exit_kind_of_word(99)
	testing.expect(t, !bad_vm)

	cfg := Linux_Boot_Config{ram_bytes = 512 * 1024 * 1024, vcpu_count = 2, virtio_gpu = true, virtio_net = true}
	e820: [8]E820_Entry
	n, ok := build_linux_e820(cfg, e820[:])
	testing.expect(t, ok && n == 3)
	testing.expect_value(t, e820[2].addr, u64(0x100000))

	bz: [0x300]u8
	byte_order.write_u16_little_endian(bz[:], 0x1FE, 0xAA55)
	byte_order.write_u32_little_endian(bz[:], 0x202, LINUX_BOOT_HEADER_MAGIC)
	byte_order.write_u16_little_endian(bz[:], 0x206, 0x020F)
	ver, bok := linux_bzimage_valid(bz[:])
	testing.expect(t, bok && ver == 0x020F)

	// Minimal valid PE32+ header.
	pe: [256]u8
	byte_order.write_u16_little_endian(pe[:], 0, PE_DOS_MAGIC)
	byte_order.write_u32_little_endian(pe[:], 0x3C, 0x40)
	byte_order.write_u32_little_endian(pe[:], 0x40, PE_NT_SIGNATURE)
	byte_order.write_u16_little_endian(pe[:], 0x44, PE_MACHINE_AMD64)
	byte_order.write_u16_little_endian(pe[:], 0x46, 2)
	byte_order.write_u16_little_endian(pe[:], 0x54, 112)
	opt := 0x40 + 24
	byte_order.write_u16_little_endian(pe[:], opt, PE_OPT_MAGIC_PE32_PLUS)
	byte_order.write_u32_little_endian(pe[:], opt + 16, 0x1000)
	byte_order.write_u64_little_endian(pe[:], opt + 24, 0x140000000)
	byte_order.write_u32_little_endian(pe[:], opt + 56, 0x8000)
	byte_order.write_u16_little_endian(pe[:], opt + 68, 3) // CUI
	info, pok := parse_pe64_header(pe[:])
	testing.expect(t, pok && info.entry_rva == 0x1000 && info.section_count == 2)
	testing.expect_value(t, nt_translate_syscall(0x0018), Nt_Syscall_Action.Map_Virtual_Memory)
	testing.expect_value(t, nt_translate_syscall(0x9999), Nt_Syscall_Action.Refuse)
}
