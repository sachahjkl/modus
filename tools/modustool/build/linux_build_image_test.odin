#+build !freestanding
package build

import "core:strconv"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// The names of the entries of an archive, in order, as a reader of the
// form newc reads them.
@(private = "file")
archive_names :: proc(archive: []u8) -> (names: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	at := 0
	for at + 110 <= len(archive) && string(archive[at:][:6]) == "070701" {
		field :: proc(header: []u8, index: int) -> int {
			value, _ := strconv.parse_u64_of_base(string(header[6 + index * 8:][:8]), 16)
			return int(value)
		}
		header := archive[at:][:110]
		name_size, data_size := field(header, 11), field(header, 6)
		name := string(archive[at + 110:][:name_size - 1])
		if name == "TRAILER!!!" {
			return names, true
		}
		append(&names, name)
		at = ((at + 110 + name_size + 3) &~ 3 + data_size + 3) &~ 3
	}
	return names, false
}

// The archive of a guest build: the init at /init, busybox and its shell,
// the modules of the disks and not the console, the folders of the
// protocol, and the console node; the same inputs give the same bytes.
@(test)
linux_build_initial_archive_layout :: proc(t: ^testing.T) {
	init := []u8{0x7F, 'E', 'L', 'F', 9}
	busybox := []u8{0x7F, 'E', 'L', 'F', 7}
	modules: [Linux_Guest_Module][]u8
	for &module, index in modules {
		module = []u8{0x7F, 'E', 'L', 'F', u8(index)}
	}
	archive := linux_build_initial_archive(init, busybox, modules)
	again := linux_build_initial_archive(init, busybox, modules)
	testing.expect(t, string(archive) == string(again), "the archive is deterministic")
	names, ok := archive_names(archive)
	testing.expect(t, ok)
	has :: proc(names: []string, name: string) -> bool {
		for candidate in names {
			if candidate == name {
				return true
			}
		}
		return false
	}
	for name in ([?]string{"init", "bin/busybox", "bin/sh", "dev/console", "inputs", "outputs", "proc", "sys", "lib/modules/virtio_ring.ko", "lib/modules/virtio.ko", "lib/modules/virtio_mmio.ko", "lib/modules/virtio_blk.ko"}) {
		testing.expectf(t, has(names[:], name), "the archive holds %s", name)
	}
	testing.expect(t, !has(names[:], "lib/modules/virtio_console.ko"), "a build loads no console")
}

// The recipe of the machine test: two makes give one recipe hash and one
// expected output; the store holds the kernel, the archive, the input and
// the recipe by their names; the expected output is the tree of the two
// files that the command writes.
@(test)
guest_build_test_recipe_is_stable :: proc(t: ^testing.T) {
	kernel := []u8{'k', 'e', 'r', 'n', 'e', 'l'}
	archive := []u8{'0', '7', '0', '7', '0', '1'}
	first, first_ok := guest_build_test_make(kernel, archive)
	second, second_ok := guest_build_test_make(kernel, archive)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.recipe_hash, second.recipe_hash)
	testing.expect_value(t, first.expected_output, second.expected_output)
	testing.expect(t, first.expected_output != blake3.Hash{}, "the expected output has a hash")
	testing.expect_value(t, len(first.objects), 4)
	kernel_name := pr.blob_object_name(blake3.hash(kernel))
	recipe_name := pr.recipe_object_name(first.recipe_hash)
	names: [dynamic]string
	defer delete(names)
	for object in first.objects {
		append(&names, object.name)
	}
	testing.expect(t, strings.contains(strings.join(names[:], " ", context.temp_allocator), pr.private_object_name_text(&kernel_name)))
	testing.expect(t, strings.contains(strings.join(names[:], " ", context.temp_allocator), pr.private_object_name_text(&recipe_name)))
	// The recipe object decodes to the recipe hash, as the service reads it.
	for object in first.objects {
		if object.name == pr.private_object_name_text(&recipe_name) {
			spec: pr.Recipe_Spec
			testing.expect_value(t, pr.decode_recipe_object(object.bytes, &spec), pr.Recipe_Refusal.None)
			decoded, _ := pr.recipe_hash(&spec)
			testing.expect_value(t, decoded, first.recipe_hash)
		}
	}
}
