package modustool

import "core:fmt"
import "core:mem"
import "core:slice"
import info "modus:contract/boot_info"
import "modus:contract/system_description"
import "modustool:foundation"
import "modustool:build"

// The fuzz targets of the system description and the boot image
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"): the
// boot program and the root service read them before the kernel and the
// first process start. The raw target reads a description: one system has
// one description, so a description that `entries` accepts is the one that
// its writer gives for its entries. The generated target builds a boot
// image, its kernel and its description, then changes one byte: a changed
// byte of a file, or of the description outside its security version,
// fails a check.

// fuzz_description_write gives the bytes of a description, as the build
// writes it: the header, then each entry.
@(private = "file")
fuzz_description_write :: proc(security_version: u32, entries: []system_description.Entry) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	header := system_description.Header {
		magic            = system_description.MAGIC,
		version          = system_description.VERSION,
		entry_count      = u32(len(entries)),
		security_version = security_version,
	}
	append(&bytes, ..mem.ptr_to_bytes(&header))
	for &entry in entries {
		append(&bytes, ..mem.ptr_to_bytes(&entry))
	}
	return bytes[:]
}

// fuzz_system_description_execute: a description that entries accepts is
// the bytes that its writer gives for its entries, its security version
// is in its bounds, and the check of a kernel compares entry 0. A refused
// description fails each check as Not_Valid.
fuzz_system_description_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	list, valid := system_description.entries(input)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "entries changed the bytes of the description")
	}
	security_version, version_valid := system_description.security_version_of(input)
	if version_valid != valid {
		return fuzz_broken(.Two_Readers, "security_version_of and entries differ on the format")
	}
	if !valid {
		if security_version != 0 || len(list) != 0 {
			return fuzz_broken(.Contract, "a refused description gives entries or a security version")
		}
		if system_description.kernel_check(input, nil).fault != .Not_Valid || system_description.image_check(input, nil).fault != .Not_Valid {
			return fuzz_broken(.Contract, "a check of a refused description does not give Not_Valid")
		}
		return FUZZ_PASSED
	}
	if security_version == 0 || security_version > system_description.SECURITY_VERSION_LIMIT {
		return fuzz_broken(.Contract, "the security version %d is out of its bounds", security_version)
	}
	// The one form: the writer of the description gives the same bytes
	// from the name, the kind, the size and the hash of each entry.
	written := make([]system_description.Entry, len(list), context.temp_allocator)
	for &entry, index in list {
		copy(written[index].name[:system_description.NAME_SIZE - 1], system_description.name_of(&entry.name))
		written[index].kind = entry.kind
		written[index].size = entry.size
		written[index].hash = entry.hash
	}
	if !slice.equal(fuzz_description_write(u32(security_version), written), input) {
		return fuzz_broken(.Round_Trip, "the description is not the bytes that its writer gives for its entries")
	}
	check := system_description.kernel_check(input, nil)
	switch check.fault {
	case .None:
		if list[0].size != 0 {
			return fuzz_broken(.Contract, "kernel_check accepts an empty kernel for an entry of %d bytes", list[0].size)
		}
	case .Size_Differs, .Hash_Differs:
	case .Not_Valid, .Image_Not_Valid, .Count_Differs, .Name_Differs, .Kind_Differs, .Stated_Hash_Differs, .Outside_Image:
		return fuzz_broken(.Contract, "kernel_check gives %v", check.fault)
	}
	if image_result := system_description.image_check(input, nil); image_result.fault != .Image_Not_Valid {
		return fuzz_broken(.Contract, "image_check with no image gives %v", image_result.fault)
	}
	return FUZZ_PASSED
}

fuzz_system_description_seeds :: proc(seeds: ^[dynamic][]u8) {
	kernel := system_description.Entry{kind = .Kernel}
	copy(kernel.name[:], system_description.KERNEL_ENTRY_NAME)
	kernel.size = 4096
	kernel.hash[0] = 1
	entries := make([dynamic]system_description.Entry, context.temp_allocator)
	append(&entries, kernel)
	append(seeds, slice.clone(fuzz_description_write(system_description.SECURITY_VERSION, entries[:])))
	for index in 0 ..< 4 {
		entry := system_description.Entry{kind = index < 2 ? system_description.Entry_Kind.Module : system_description.Entry_Kind.Resource, size = u64(index * 100)}
		copy(entry.name[:system_description.NAME_SIZE - 1], fmt.tprintf("file_%d", index))
		entry.hash[31] = u8(index)
		append(&entries, entry)
	}
	append(seeds, slice.clone(fuzz_description_write(system_description.SECURITY_VERSION_LIMIT, entries[:])))
	// Two entries with one name, and a module after a resource.
	twice := slice.clone(entries[:], context.temp_allocator)
	twice[2].name = twice[1].name
	append(seeds, slice.clone(fuzz_description_write(system_description.SECURITY_VERSION, twice)))
	after := slice.clone(entries[:], context.temp_allocator)
	after[4].kind = .Module
	append(seeds, slice.clone(fuzz_description_write(system_description.SECURITY_VERSION, after)))
	append(seeds, make([]u8, size_of(system_description.Header) - 1))
}

// ---------------------------------------------------------------------
// The boot image, its kernel and its description.

// What the generated target changed after the build of the image.
@(private = "file")
Fuzz_Boot_Change :: enum u8 {
	None,
	Kernel, // A byte of the kernel file.
	File, // A byte of a file of the image that the description lists.
	Description, // A byte of the description that the checks read.
}

// fuzz_boot_image_generated_execute builds the files of a boot image from
// the choices, the description of the kernel and of each file, and the
// image with the description and a signature as its two last resources.
// With no change, the checks of the boot program pass, and trust_resources
// finds the description.
fuzz_boot_image_generated_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input)
	kernel := make([]u8, fuzz_choice_below(&choices, 65), context.temp_allocator)
	fuzz_choice_fill(&choices, kernel)
	files := make([dynamic]build.Image_File, context.temp_allocator)
	module_count := fuzz_choice_below(&choices, 4)
	file_count := module_count + fuzz_choice_below(&choices, 3)
	for index in 0 ..< file_count {
		bytes := make([]u8, fuzz_choice_below(&choices, 65), context.temp_allocator)
		fuzz_choice_fill(&choices, bytes)
		append(&files, build.Image_File{name = fmt.tprintf("file_%d", index), file = bytes})
	}
	entries := make([dynamic]system_description.Entry, context.temp_allocator)
	append(&entries, build.description_entry(system_description.KERNEL_ENTRY_NAME, .Kernel, kernel))
	for item, index in files {
		kind := index < module_count ? system_description.Entry_Kind.Module : system_description.Entry_Kind.Resource
		append(&entries, build.description_entry(item.name, kind, item.file))
	}
	security_version := u32(fuzz_choice_range(&choices, 1, system_description.SECURITY_VERSION_LIMIT))
	description := fuzz_description_write(security_version, entries[:])
	signature := make([]u8, system_description.SIGNATURE_SIZE, context.temp_allocator)
	all := slice.clone_to_dynamic(files[:], context.temp_allocator)
	append(&all, build.Image_File{name = system_description.RESOURCE_DESCRIPTION, file = description}, build.Image_File{name = system_description.RESOURCE_SIGNATURE, file = signature})
	image := build.boot_image_encode(all[:], module_count)

	description_in_image := description
	change := foundation.enum_member_at(Fuzz_Boot_Change, fuzz_choice_below(&choices, len(Fuzz_Boot_Change)))
	changed_index := -1 // The entry of the description whose file changed.
	// The signature covers the security version; the checks do not compare
	// it with a file, so a change there can pass them.
	security_version_changed := false
	switch change {
	case .None:
	case .Kernel:
		if len(kernel) == 0 {
			change = .None
			break
		}
		kernel[fuzz_choice_below(&choices, len(kernel))] ~= u8(1 + fuzz_choice_below(&choices, 255))
	case .File:
		modules, resources, _ := info.image_tables(image)
		listed := len(modules) + len(resources) - 2
		if listed <= 0 {
			change = .None
			break
		}
		position := fuzz_choice_below(&choices, listed)
		entry := position < len(modules) ? &modules[position] : &resources[position - len(modules)]
		if entry.size == 0 {
			change = .None
			break
		}
		image[int(entry.offset) + fuzz_choice_below(&choices, int(entry.size))] ~= u8(1 + fuzz_choice_below(&choices, 255))
		changed_index = position + 1
	case .Description:
		place := fuzz_choice_below(&choices, len(description))
		description = slice.clone(description, context.temp_allocator)
		description[place] ~= u8(1 + fuzz_choice_below(&choices, 255))
		version_start := int(offset_of(system_description.Header, security_version))
		security_version_changed = place >= version_start && place < version_start + size_of(u32)
	}

	found_description, found_signature, found := system_description.trust_resources(image)
	if !found || len(found_signature) != system_description.SIGNATURE_SIZE {
		return fuzz_broken(.Contract, "trust_resources does not find the two last resources of the image")
	}
	if !slice.equal(found_description, description_in_image) {
		return fuzz_broken(.Contract, "trust_resources gives other bytes than the description of the image")
	}
	kernel_result := system_description.kernel_check(description, kernel)
	image_result := system_description.image_check(description, image)
	switch change {
	case .None:
		if kernel_result.fault != .None || image_result.fault != .None {
			return fuzz_broken(.Contract, "the checks of an image as built give %v and %v", kernel_result.fault, image_result.fault)
		}
	case .Kernel:
		if kernel_result.fault != .Hash_Differs {
			return fuzz_broken(.Contract, "the check of a changed kernel gives %v", kernel_result.fault)
		}
	case .File:
		if image_result.fault != .Hash_Differs || int(image_result.index) != changed_index {
			return fuzz_broken(.Contract, "the check of a changed file of the entry %d gives %v at %d", changed_index, image_result.fault, image_result.index)
		}
	case .Description:
		if !security_version_changed && kernel_result.fault == .None && image_result.fault == .None {
			return fuzz_broken(.Contract, "the checks pass with a changed byte of the description")
		}
	}
	return FUZZ_PASSED
}
