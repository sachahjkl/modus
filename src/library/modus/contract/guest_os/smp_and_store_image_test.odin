#+build !freestanding
#+build !modus
package guest_os

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(private = "file")
make_guest_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	for i in 0 ..< len(h) {
		h[i] = tag + u8(i) + 1
	}
	return h
}

@(test)
guest_madt_builder_refusals_and_exact_acpi_output :: proc(t: ^testing.T) {
	// Enum and flag border checks.
	ref, ok := guest_smp_image_refusal_of_word(u64(Guest_Smp_Image_Refusal.Bad_Flags))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Guest_Smp_Image_Refusal.Bad_Flags)
	_, bad_ref := guest_smp_image_refusal_of_word(u64(Guest_Smp_Image_Refusal.Bad_Flags) + 1)
	testing.expect(t, !bad_ref)

	flags, f_ok := guest_grant_flags_of_word(GUEST_GRANT_FLAGS_KNOWN_MASK)
	testing.expect(t, f_ok)
	testing.expect_value(t, flags, Guest_Grant_Flags{.Persistent_Disk_Store, .Scoped_Network_Grant, .Wine_Nt_Profile})
	_, bad_flags := guest_grant_flags_of_word(1 << 3)
	testing.expect(t, !bad_flags)
	_, bad_flags_max := guest_grant_flags_of_word(max(u64))
	testing.expect(t, !bad_flags_max)

	buf: [512]u8
	buf[0] = 0xAA

	// Refusals: 0 vCPUs, > GUEST_MAX_VCPUS, exceeds thread budget, bad APIC base, short buffer.
	_, r := guest_madt_build(0, 8, GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Zero_Vcpus)

	_, r = guest_madt_build(GUEST_MAX_VCPUS + 1, 64, GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Too_Many_Vcpus)

	_, r = guest_madt_build(4, 3, GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Exceeds_Thread_Budget)

	_, r = guest_madt_build(2, 4, 0, buf[:])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Bad_Apic_Base)
	_, r = guest_madt_build(2, 4, GUEST_LOCAL_APIC_DEFAULT_BASE + 1, buf[:])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Bad_Apic_Base)

	exact_4 := guest_madt_size(4)
	testing.expect_value(t, exact_4, MADT_HEADER_BYTES + 4 * MADT_LOCAL_APIC_ENTRY_BYTES)
	_, r = guest_madt_build(4, 4, GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:exact_4 - 1])
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Buffer_Too_Small)
	testing.expect_value(t, buf[0], u8(0xAA)) // Zero mutation on refusal.

	// Valid 4-vCPU MADT: verify signature, length, APIC base, checksum == 0, and entries 0..3.
	written, r_ok := guest_madt_build(4, 4, GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:])
	testing.expect_value(t, r_ok, Guest_Smp_Image_Refusal.None)
	testing.expect_value(t, written, exact_4)
	testing.expect_value(t, string(buf[0:4]), "APIC")
	testing.expect_value(t, byte_order.read_u32_little_endian(buf[:], 4), u32(exact_4))
	testing.expect_value(t, byte_order.read_u32_little_endian(buf[:], 36), GUEST_LOCAL_APIC_DEFAULT_BASE)
	testing.expect_value(t, guest_madt_checksum(buf[:written]), u8(0))

	for cpu in u8(0) ..< 4 {
		off := MADT_HEADER_BYTES + int(cpu) * MADT_LOCAL_APIC_ENTRY_BYTES
		testing.expect_value(t, buf[off + 0], MADT_ENTRY_TYPE_LOCAL_APIC)
		testing.expect_value(t, buf[off + 1], MADT_LOCAL_APIC_ENTRY_BYTES)
		testing.expect_value(t, buf[off + 2], cpu)
		testing.expect_value(t, buf[off + 3], cpu)
		testing.expect_value(t, byte_order.read_u32_little_endian(buf[:], off + 4), MADT_LOCAL_APIC_FLAG_ENABLED)
	}

	// Maximum 32 vCPUs fits and checksums cleanly.
	max_size := guest_madt_size(GUEST_MAX_VCPUS)
	written32, r32 := guest_madt_build(GUEST_MAX_VCPUS, u64(GUEST_MAX_VCPUS), GUEST_LOCAL_APIC_DEFAULT_BASE, buf[:])
	testing.expect_value(t, r32, Guest_Smp_Image_Refusal.None)
	testing.expect_value(t, written32, max_size)
	testing.expect_value(t, guest_madt_checksum(buf[:written32]), u8(0))
}

@(test)
guest_store_image_refuses_zero_hash_and_ambient_host_paths :: proc(t: ^testing.T) {
	zero: blake3.Hash
	khash := make_guest_hash(0x10)
	ihash := make_guest_hash(0x50)

	// Zero kernel hash refused.
	_, r := guest_store_image_make(zero, "kernel", ihash, "initial_archive", {.Persistent_Disk_Store})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Zero_Kernel_Hash)

	// Ambient host paths refused for both kernel and initrd.
	_, r = guest_store_image_make(khash, "/boot/vmlinuz", zero, "", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Ambient_Host_Path)
	_, r = guest_store_image_make(khash, "C:\\kernel.img", zero, "", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Ambient_Host_Path)
	_, r = guest_store_image_make(khash, "../kernel", zero, "", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Ambient_Host_Path)
	_, r = guest_store_image_make(khash, "kernel", ihash, "sub/initrd.cpio", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Ambient_Host_Path)

	// Empty kernel name or mismatched initrd name/hash refused.
	_, r = guest_store_image_make(khash, "", zero, "", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Bad_Object_Name)
	_, r = guest_store_image_make(khash, "kernel", ihash, "", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Bad_Object_Name)
	_, r = guest_store_image_make(khash, "kernel", zero, "initial_archive", {})
	testing.expect_value(t, r, Guest_Smp_Image_Refusal.Bad_Object_Name)

	// Valid store-backed Wine/NT + persistent disk + scoped network spec passes.
	spec, r_ok := guest_store_image_make(khash, "kernel", ihash, "initial_archive", {.Persistent_Disk_Store, .Scoped_Network_Grant, .Wine_Nt_Profile})
	testing.expect_value(t, r_ok, Guest_Smp_Image_Refusal.None)
	testing.expect_value(t, guest_store_image_validate(&spec), Guest_Smp_Image_Refusal.None)
	testing.expect(t, .Persistent_Disk_Store in spec.flags)
	testing.expect(t, .Scoped_Network_Grant in spec.flags)
	testing.expect(t, .Wine_Nt_Profile in spec.flags)

	// Nil spec and corrupted length refused on border re-validation.
	testing.expect_value(t, guest_store_image_validate(nil), Guest_Smp_Image_Refusal.Bad_Object_Name)
	bad_spec := spec
	bad_spec.kernel_name_length = GUEST_OBJECT_NAME_CAPACITY + 1
	testing.expect_value(t, guest_store_image_validate(&bad_spec), Guest_Smp_Image_Refusal.Bad_Object_Name)
}
