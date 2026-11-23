// Pure freestanding full-system guest VM contracts (Linux bzImage boot
// protocol, e820 memory map, VM-exit dispatch for Linux and the Wren browser
// in a guest) and NT PE32+ user-process compatibility layer contracts.
package guest_os

import "modus:contract/byte_order"
import "modus:contract/enum_word"

LINUX_BOOT_HEADER_MAGIC :: u32(0x53726448) // "HdrS"
E820_MAX_ENTRIES :: 16
PE_DOS_MAGIC :: u16(0x5A4D)                // "MZ"
PE_NT_SIGNATURE :: u32(0x00004550)         // "PE00"
PE_MACHINE_AMD64 :: u16(0x8664)
PE_OPT_MAGIC_PE32_PLUS :: u16(0x020B)

E820_Type :: enum u32 {
	Ram      = 1,
	Reserved = 2,
	Acpi     = 3,
}

Vm_Exit_Kind :: enum u8 {
	Hlt       = 1,
	Io_In     = 2,
	Io_Out    = 3,
	Mmio_Read = 4,
	Mmio_Write = 5,
	Cpuid     = 6,
	Virtio_Kick = 7,
}

vm_exit_kind_of_word :: proc "contextless" (word: u64) -> (k: Vm_Exit_Kind, ok: bool) {
	return enum_word.member_of_word(Vm_Exit_Kind, word)
}

E820_Entry :: struct #packed {
	addr: u64,
	size: u64,
	type: u32,
}
#assert(size_of(E820_Entry) == 20)

Linux_Boot_Config :: struct {
	ram_bytes:     u64,
	kernel_load:   u64,
	initrd_load:   u64,
	initrd_size:   u64,
	cmdline_addr:  u64,
	vcpu_count:    u8,
	virtio_gpu:    bool,
	virtio_net:    bool,
	virtio_blk:    bool,
}

// build_linux_e820 constructs a clean non-overlapping e820 map for a Linux
// guest (low conventional RAM, EBDA/BIOS hole, high RAM above 1 MiB).
build_linux_e820 :: proc "contextless" (cfg: Linux_Boot_Config, out: []E820_Entry) -> (count: int, ok: bool) {
	if cfg.ram_bytes < 64 * 1024 * 1024 || cfg.vcpu_count == 0 || cfg.vcpu_count > 32 || len(out) < 3 {
		return 0, false
	}
	out[0] = {addr = 0x0000_0000, size = 0x0009_FC00, type = u32(E820_Type.Ram)}
	out[1] = {addr = 0x0009_FC00, size = 0x0006_0400, type = u32(E820_Type.Reserved)}
	out[2] = {addr = 0x0010_0000, size = cfg.ram_bytes - 0x0010_0000, type = u32(E820_Type.Ram)}
	return 3, true
}

// linux_bzimage_valid validates the x86 Linux boot protocol header magic and
// minimum protocol version (2.06+) before loading a guest kernel.
linux_bzimage_valid :: proc "contextless" (image: []u8) -> (protocol_version: u16, ok: bool) {
	if len(image) < 0x260 {
		return 0, false
	}
	if byte_order.read_u16_little_endian(image, 0x1FE) != 0xAA55 {
		return 0, false
	}
	if byte_order.read_u32_little_endian(image, 0x202) != LINUX_BOOT_HEADER_MAGIC {
		return 0, false
	}
	ver := byte_order.read_u16_little_endian(image, 0x206)
	if ver < 0x0206 {
		return 0, false
	}
	return ver, true
}

// ============================================================================
// NT Process Compatibility: PE32+ (AMD64) header validation & syscall mapping
// ============================================================================

Nt_Syscall_Action :: enum u8 {
	Refuse              = 0,
	Map_Virtual_Memory  = 1,
	Free_Virtual_Memory = 2,
	Terminate_Process   = 3,
	Delay_Execution     = 4,
	Write_File_Console  = 5,
}

Pe64_Info :: struct {
	entry_rva:        u32,
	image_base:       u64,
	size_of_image:    u32,
	section_count:    u16,
	subsystem:        u16,
}

// parse_pe64_header validates an AMD64 PE32+ executable header strictly within
// buffer bounds before instantiating an isolated NT compatibility process.
parse_pe64_header :: proc "contextless" (bytes: []u8) -> (info: Pe64_Info, ok: bool) {
	if len(bytes) < 0x40 {
		return {}, false
	}
	if byte_order.read_u16_little_endian(bytes, 0) != PE_DOS_MAGIC {
		return {}, false
	}
	pe_off := int(byte_order.read_u32_little_endian(bytes, 0x3C))
	if pe_off < 0x40 || pe_off + 24 + 112 > len(bytes) {
		return {}, false
	}
	if byte_order.read_u32_little_endian(bytes, pe_off) != PE_NT_SIGNATURE {
		return {}, false
	}
	machine := byte_order.read_u16_little_endian(bytes, pe_off + 4)
	sections := byte_order.read_u16_little_endian(bytes, pe_off + 6)
	opt_size := byte_order.read_u16_little_endian(bytes, pe_off + 20)
	if machine != PE_MACHINE_AMD64 || sections == 0 || sections > 64 || opt_size < 112 {
		return {}, false
	}
	opt := pe_off + 24
	if byte_order.read_u16_little_endian(bytes, opt) != PE_OPT_MAGIC_PE32_PLUS {
		return {}, false
	}
	info = {
		entry_rva     = byte_order.read_u32_little_endian(bytes, opt + 16),
		image_base    = byte_order.read_u64_little_endian(bytes, opt + 24),
		size_of_image = byte_order.read_u32_little_endian(bytes, opt + 56),
		section_count = sections,
		subsystem     = byte_order.read_u16_little_endian(bytes, opt + 68),
	}
	if info.size_of_image == 0 || info.entry_rva >= info.size_of_image {
		return {}, false
	}
	return info, true
}

// nt_translate_syscall maps core Windows NT x64 service numbers onto bounded
// modus kernel/service operations, refusing every ungranted/unknown syscall.
nt_translate_syscall :: proc "contextless" (nt_number: u32) -> Nt_Syscall_Action {
	switch nt_number {
	case 0x0008: return .Write_File_Console  // NtWriteFile (stdout/stderr only)
	case 0x0018: return .Map_Virtual_Memory  // NtAllocateVirtualMemory
	case 0x001E: return .Free_Virtual_Memory // NtFreeVirtualMemory
	case 0x002C: return .Terminate_Process   // NtTerminateProcess
	case 0x0034: return .Delay_Execution     // NtDelayExecution
	}
	return .Refuse
}
