package build

import module "modus:contract/module"
import "core:testing"

// A module of one segment, with a memory size of `memory_size` bytes.
@(private = "file")
module_of_a_test :: proc(memory_size: u64) -> []u8 {
	directory: [module.TABLE_COUNT]module.Table_Entry
	segments := [?]module.Segment{{}, {memory_size = module.PAGE_SIZE, flags = {.Read, .Write}}}
	file := make([dynamic]u8, size_of(module.Header) + size_of(directory), context.temp_allocator)
	directory[module.Table_Kind.Segments] = {offset = u64(len(file)), count = len(segments), record_size = size_of(module.Segment)}
	append(&file, ..([^]u8)(&segments)[:size_of(segments)])
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT, memory_size = memory_size}
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// The raise refuses what is not a module, a module cut in its header, a
// module of another magic, and a memory size that the raise would carry
// past the largest u64. Then the copy of a module states KERNEL_MEMORY_RAISE
// more bytes, stays valid, keeps each other byte, and leaves the module of
// the build as it was.
@(test)
the_kernel_with_its_memory_raised_is_a_valid_copy :: proc(t: ^testing.T) {
	_, ok := kernel_memory_raise(nil)
	testing.expect(t, !ok, "no bytes are taken as a module")
	whole := module_of_a_test(module.PAGE_SIZE)
	_, ok = kernel_memory_raise(whole[:size_of(module.Header) - 1])
	testing.expect(t, !ok, "a cut header is taken")
	other_magic := make([]u8, len(whole), context.temp_allocator)
	copy(other_magic, whole)
	other_magic[0] ~= 1
	_, ok = kernel_memory_raise(other_magic)
	testing.expect(t, !ok, "another magic is taken")
	// The largest memory size on pages: the raise would pass the largest u64.
	largest := max(u64) - (max(u64) % module.PAGE_SIZE)
	_, ok = kernel_memory_raise(module_of_a_test(largest))
	testing.expect(t, !ok, "a memory size that the raise carries past the largest u64 is taken")

	raised: []u8
	raised, ok = kernel_memory_raise(whole)
	testing.expect(t, ok, "a valid module is refused")
	if !ok {
		return
	}
	testing.expect_value(t, module.validate(raised), module.Error.None)
	head, error := module.header(raised)
	testing.expect_value(t, error, module.Error.None)
	testing.expect_value(t, head.memory_size, module.PAGE_SIZE + KERNEL_MEMORY_RAISE)
	original, _ := module.header(whole)
	testing.expect_value(t, original.memory_size, u64(module.PAGE_SIZE))
	testing.expect_value(t, len(raised), len(whole))
	for index in size_of(module.Header) ..< len(whole) {
		testing.expectf(t, raised[index] == whole[index], "the byte %d past the header changed", index)
	}
}
