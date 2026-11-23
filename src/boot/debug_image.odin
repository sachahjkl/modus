package boot

import "base:intrinsics"

// The debug image (docs/MODULE_CONTRACT.md, "Debug information"): the debug
// objects of the modules, one file of the boot volume beside the boot
// program, apart from the boot image. Its bound is computed: the memory
// that the firmware gives for it. A fixed bound refused the debug image of
// the build once it grew past it, and the machine lost its names. The boot program and the boot image
// are the same bytes with and without it, so a debug object changes no
// measure and no signature. It is data for a reader of names: no code
// comes from it, and each reader checks each debug object before it uses
// it. A volume with no such file starts as before.

DEBUG_IMAGE_PATH :: "\\DEBUG\\OBJECTS.IMG"

// debug_image_read reads the debug image of the volume of the boot program
// into pages of its own, up to `limit` bytes (computed from free physical
// memory and capped at fixed_addresses.RANGE_SPAN, so an unsigned or oversized
// file never exhausts memory needed by the kernel and root service). It gives
// 0 and 0 when the volume has no such file, when the file is empty or over
// `limit`, or when the firmware refuses a step. It runs after the last
// allocation of the start that stops the machine when it fails, and it never
// stops the machine itself: a start never fails for the debug image. A failed
// read gives its pages back.
debug_image_read :: proc "contextless" (limit: u64) -> (address: u64, size: u64) {
	services := system.boot_services
	loaded_guid := EFI_LOADED_IMAGE_GUID
	file_system_guid := EFI_SIMPLE_FILE_SYSTEM_GUID
	loaded: rawptr
	if services.handle_protocol(image_handle, &loaded_guid, &loaded) != 0 || loaded == nil {
		return 0, 0
	}
	file_system: rawptr
	if services.handle_protocol((^Efi_Loaded_Image)(loaded).device_handle, &file_system_guid, &file_system) != 0 || file_system == nil {
		return 0, 0
	}
	volume: ^Efi_File
	if (^Efi_Simple_File_System)(file_system).open_volume((^Efi_Simple_File_System)(file_system), &volume) != 0 || volume == nil {
		return 0, 0
	}
	defer volume.close(volume)
	// UTF-16, with a zero at the end. A constant string is not indexed with
	// a variable: the loop reads a string value.
	path_text := DEBUG_IMAGE_PATH
	path: [len(DEBUG_IMAGE_PATH) + 1]u16
	for index in 0 ..< len(path_text) {
		path[index] = u16(path_text[index])
	}
	file: ^Efi_File
	if volume.open(volume, &file, raw_data(path[:]), EFI_FILE_MODE_READ, 0) != 0 || file == nil {
		print("boot program: the volume has no debug image\r\n")
		return 0, 0
	}
	defer file.close(file)
	// The size: the position at the end of the file.
	if file.set_position(file, max(u64)) != 0 || file.get_position(file, &size) != 0 || file.set_position(file, 0) != 0 {
		return 0, 0
	}
	if size == 0 {
		print("boot program: the debug image is empty: not read\r\n")
		return 0, 0
	}
	// Computed bound: at most limit (one quarter of free physical memory,
	// capped at fixed_addresses.RANGE_SPAN), and never past u64 page rounding.
	if limit == 0 || size > limit || size > max(u64) - PAGE_SIZE {
		print("boot program: the debug image is larger than the computed bound: not read\r\n")
		return 0, 0
	}
	page_count := (size + PAGE_SIZE - 1) / PAGE_SIZE
	if services.allocate_pages(.Any, .Loader_Data, uint(page_count), &address) != 0 {
		print("boot program: no memory for the debug image: not read\r\n")
		return 0, 0
	}
	intrinsics.mem_zero(rawptr(uintptr(address)), int(page_count * PAGE_SIZE))
	done := u64(0)
	for done < size {
		count := uint(size - done)
		if file.read(file, &count, rawptr(uintptr(address + done))) != 0 || count == 0 || u64(count) > size - done {
			// Pages of the kind Loader_Data that the firmware keeps are memory
			// of the boot for the kernel, which never frees it: they go back.
			services.free_pages(address, uint(page_count))
			print("boot program: the read of the debug image failed: not read\r\n")
			return 0, 0
		}
		done += u64(count)
	}
	print("boot program: the debug image is in memory\r\n")
	return address, size
}
