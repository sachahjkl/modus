// Multi-vCPU Linux guest ACPI MADT (Local APIC) builder and store-backed guest
// image & grant descriptor contract
// (src/md/features/guest.md, src/md/features/linux_shell.md,
// src/md/features/foreign_systems.md).
//
// Pure freestanding contract: zero kernel calls, zero host imports, and zero
// dynamic allocation.
package guest_os

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Plan value: matches the kernel's maximum guest processors per guest (32);
// at runtime guest_madt_build also caps vcpu_count by the process thread budget.
GUEST_MAX_VCPUS :: u8(32)

// Format property: architectural x86-64 Local APIC MMIO base address.
GUEST_LOCAL_APIC_DEFAULT_BASE :: u32(0xFEE0_0000)

// Format property: ACPI MADT (APIC) table header and Type 0 Local APIC sizes.
MADT_HEADER_BYTES :: 44
MADT_LOCAL_APIC_ENTRY_BYTES :: 8
MADT_ENTRY_TYPE_LOCAL_APIC :: u8(0)
MADT_LOCAL_APIC_FLAG_ENABLED :: u32(1)
MADT_FLAG_PCAT_COMPAT :: u32(1)
MADT_ACPI_REVISION :: u8(4)

// Format property: bounded private-store object name for guest kernel/initrd.
GUEST_OBJECT_NAME_CAPACITY :: 64

// Closed set of refusals returned by MADT table generation and guest store
// image specification validation. Explicit values cross transport borders.
Guest_Smp_Image_Refusal :: enum u8 {
	None                  = 0,
	Zero_Vcpus            = 1,
	Too_Many_Vcpus        = 2,
	Exceeds_Thread_Budget = 3,
	Bad_Apic_Base         = 4,
	Buffer_Too_Small      = 5,
	Zero_Kernel_Hash      = 6,
	Bad_Object_Name       = 7,
	Ambient_Host_Path     = 8,
	Bad_Flags             = 9,
}

// Closed set of explicit capability flags for a store-backed Linux guest.
Guest_Grant_Flag :: enum u8 {
	Persistent_Disk_Store = 0, // VirtIO-blk backed by an explicit modus store handle.
	Scoped_Network_Grant  = 1, // Guest networking mediated strictly by a network grant.
	Wine_Nt_Profile       = 2, // Guest runs NT processes via Wine inside Linux.
}

Guest_Grant_Flags :: bit_set[Guest_Grant_Flag; u8]

GUEST_GRANT_FLAGS_KNOWN_MASK :: u64((1 << u8(Guest_Grant_Flag.Persistent_Disk_Store)) | (1 << u8(Guest_Grant_Flag.Scoped_Network_Grant)) | (1 << u8(Guest_Grant_Flag.Wine_Nt_Profile)))

// Validated descriptor of a guest image stored in a principal's private store
// (never in the boot image and never referencing ambient host filesystem paths).
Guest_Store_Image_Spec :: struct {
	kernel_hash:        blake3.Hash,
	initrd_hash:        blake3.Hash,
	kernel_object_name: [GUEST_OBJECT_NAME_CAPACITY]u8,
	kernel_name_length: u8,
	initrd_object_name: [GUEST_OBJECT_NAME_CAPACITY]u8,
	initrd_name_length: u8,
	flags:              Guest_Grant_Flags,
}

// guest_smp_image_refusal_of_word converts a raw word into
// Guest_Smp_Image_Refusal at a border, refusing unknown values.
guest_smp_image_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Guest_Smp_Image_Refusal, ok: bool) {
	return enum_word.member_of_word(Guest_Smp_Image_Refusal, word)
}

// guest_grant_flags_of_word converts a transport bitmask into
// Guest_Grant_Flags at a border, refusing any unknown bit.
guest_grant_flags_of_word :: proc "contextless" (word: u64) -> (flags: Guest_Grant_Flags, ok: bool) {
	if word & ~GUEST_GRANT_FLAGS_KNOWN_MASK != 0 {
		return {}, false
	}
	result: Guest_Grant_Flags
	if word & (1 << u8(Guest_Grant_Flag.Persistent_Disk_Store)) != 0 {
		result += {.Persistent_Disk_Store}
	}
	if word & (1 << u8(Guest_Grant_Flag.Scoped_Network_Grant)) != 0 {
		result += {.Scoped_Network_Grant}
	}
	if word & (1 << u8(Guest_Grant_Flag.Wine_Nt_Profile)) != 0 {
		result += {.Wine_Nt_Profile}
	}
	return result, true
}

// guest_madt_size returns the exact ACPI MADT byte length for vcpu_count
// guest processors, or 0 when vcpu_count is out of [1, GUEST_MAX_VCPUS].
guest_madt_size :: proc "contextless" (vcpu_count: u8) -> int {
	if vcpu_count == 0 || vcpu_count > GUEST_MAX_VCPUS {
		return 0
	}
	return MADT_HEADER_BYTES + int(vcpu_count) * MADT_LOCAL_APIC_ENTRY_BYTES
}

// guest_madt_checksum returns the standard ACPI modulo-256 sum of bytes.
// A valid ACPI table checksums to 0.
guest_madt_checksum :: proc "contextless" (bytes: []u8) -> u8 {
	sum: u8 = 0
	for b in bytes {
		sum += b
	}
	return sum
}

// guest_madt_build writes a deterministic ACPI MADT ("APIC") table with
// Processor Local APIC entries 0 ..< vcpu_count into out, bounded by
// thread_budget_slots, and sets the ACPI checksum byte so the table sums to 0.
// Refuses 0 vCPUs, vcpu_count > GUEST_MAX_VCPUS, vcpu_count > thread_budget_slots,
// unaligned or zero local_apic_base, or a short output buffer without mutating out.
guest_madt_build :: proc "contextless" (
	vcpu_count: u8,
	thread_budget_slots: u64,
	local_apic_base: u32,
	out: []u8,
) -> (written: int, refusal: Guest_Smp_Image_Refusal) {
	if vcpu_count == 0 {
		return 0, .Zero_Vcpus
	}
	if vcpu_count > GUEST_MAX_VCPUS {
		return 0, .Too_Many_Vcpus
	}
	if u64(vcpu_count) > thread_budget_slots {
		return 0, .Exceeds_Thread_Budget
	}
	if local_apic_base == 0 || (local_apic_base & 0xFFF) != 0 {
		return 0, .Bad_Apic_Base
	}
	needed := MADT_HEADER_BYTES + int(vcpu_count) * MADT_LOCAL_APIC_ENTRY_BYTES
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}

	for i in 0 ..< needed {
		out[i] = 0
	}

	// ACPI SDT header (36 bytes).
	out[0], out[1], out[2], out[3] = 'A', 'P', 'I', 'C'
	byte_order.write_u32_little_endian(out, 4, u32(needed))
	out[8] = MADT_ACPI_REVISION
	out[9] = 0 // Checksum computed below.
	copy(out[10:16], "MODUS ")
	copy(out[16:24], "GUESTSMP")
	byte_order.write_u32_little_endian(out, 24, 1)
	copy(out[28:32], "MODU")
	byte_order.write_u32_little_endian(out, 32, 1)

	// MADT body header (8 bytes): Local APIC address + PCAT_COMPAT flags.
	byte_order.write_u32_little_endian(out, 36, local_apic_base)
	byte_order.write_u32_little_endian(out, 40, MADT_FLAG_PCAT_COMPAT)

	// Type 0 Processor Local APIC entries for vCPUs 0 ..< vcpu_count.
	for cpu in u8(0) ..< vcpu_count {
		off := MADT_HEADER_BYTES + int(cpu) * MADT_LOCAL_APIC_ENTRY_BYTES
		out[off + 0] = MADT_ENTRY_TYPE_LOCAL_APIC
		out[off + 1] = MADT_LOCAL_APIC_ENTRY_BYTES
		out[off + 2] = cpu // ACPI Processor UID.
		out[off + 3] = cpu // APIC ID.
		byte_order.write_u32_little_endian(out, off + 4, MADT_LOCAL_APIC_FLAG_ENABLED)
	}

	sum := guest_madt_checksum(out[:needed])
	out[9] = 0 - sum
	return needed, .None
}

@(private = "file")
hash_is_zero :: proc "contextless" (h: blake3.Hash) -> bool {
	accum: u8
	for b in h {
		accum |= b
	}
	return accum == 0
}

// guest_store_object_name_valid validates a flat object name inside a guest's
// private store, refusing ambient host filesystem paths (`/`, `\`, `:`, `..`)
// and control characters.
guest_store_object_name_valid :: proc "contextless" (name: string) -> Guest_Smp_Image_Refusal {
	if len(name) == 0 || len(name) > GUEST_OBJECT_NAME_CAPACITY {
		return .Bad_Object_Name
	}
	if name == "." || name == ".." {
		return .Ambient_Host_Path
	}
	for i in 0 ..< len(name) {
		b := name[i]
		if b == '/' || b == '\\' || b == ':' {
			return .Ambient_Host_Path
		}
		if b < 0x20 || b == 0x7F {
			return .Bad_Object_Name
		}
		if b == '.' && i + 1 < len(name) && name[i + 1] == '.' {
			return .Ambient_Host_Path
		}
	}
	return .None
}

// guest_store_image_make constructs and validates a Guest_Store_Image_Spec.
// Requires a non-zero kernel BLAKE3 hash and a clean store object name; an
// optional initrd requires both a valid object name and a non-zero hash.
guest_store_image_make :: proc "contextless" (
	kernel_hash: blake3.Hash,
	kernel_name: string,
	initrd_hash: blake3.Hash,
	initrd_name: string,
	flags: Guest_Grant_Flags,
) -> (spec: Guest_Store_Image_Spec, refusal: Guest_Smp_Image_Refusal) {
	if hash_is_zero(kernel_hash) {
		return {}, .Zero_Kernel_Hash
	}
	if name_ref := guest_store_object_name_valid(kernel_name); name_ref != .None {
		return {}, name_ref
	}
	has_initrd_name := len(initrd_name) > 0
	has_initrd_hash := !hash_is_zero(initrd_hash)
	if has_initrd_name != has_initrd_hash {
		return {}, .Bad_Object_Name
	}
	if has_initrd_name {
		if initrd_ref := guest_store_object_name_valid(initrd_name); initrd_ref != .None {
			return {}, initrd_ref
		}
	}
	spec.kernel_hash = kernel_hash
	spec.initrd_hash = initrd_hash
	copy(spec.kernel_object_name[:], kernel_name)
	spec.kernel_name_length = u8(len(kernel_name))
	if has_initrd_name {
		copy(spec.initrd_object_name[:], initrd_name)
		spec.initrd_name_length = u8(len(initrd_name))
	}
	spec.flags = flags
	return spec, .None
}

// guest_store_image_validate re-validates a decoded or stored
// Guest_Store_Image_Spec at a border.
guest_store_image_validate :: proc "contextless" (spec: ^Guest_Store_Image_Spec) -> Guest_Smp_Image_Refusal {
	if spec == nil {
		return .Bad_Object_Name
	}
	if hash_is_zero(spec.kernel_hash) {
		return .Zero_Kernel_Hash
	}
	if int(spec.kernel_name_length) == 0 || int(spec.kernel_name_length) > GUEST_OBJECT_NAME_CAPACITY {
		return .Bad_Object_Name
	}
	if name_ref := guest_store_object_name_valid(string(spec.kernel_object_name[:spec.kernel_name_length])); name_ref != .None {
		return name_ref
	}
	if int(spec.initrd_name_length) > GUEST_OBJECT_NAME_CAPACITY {
		return .Bad_Object_Name
	}
	has_initrd_name := spec.initrd_name_length > 0
	has_initrd_hash := !hash_is_zero(spec.initrd_hash)
	if has_initrd_name != has_initrd_hash {
		return .Bad_Object_Name
	}
	if has_initrd_name {
		if initrd_ref := guest_store_object_name_valid(string(spec.initrd_object_name[:spec.initrd_name_length])); initrd_ref != .None {
			return initrd_ref
		}
	}
	return .None
}
