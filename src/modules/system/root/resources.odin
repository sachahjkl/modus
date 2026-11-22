package root

import "modus:contract/pointer_pictures"
import "modus:contract/value_kinds"
import "modus:system"

// The resources of the boot image (docs/ARCHITECTURE.md, U2b): files that
// are not modules, each with its name and the hash of its bytes. This
// service gives one to a process as a read-only mapping.

// resource_mapping finds the resource with this name and gives the
// read-only mapping of its pages at an address of the process that
// receives it, with its size. It gives false for a resource that the image
// does not have. It computes no hash: the image check of this service
// (trust_check) hashed each resource before the first start, and no
// process can write the pages of the image after it.
resource_mapping :: proc "contextless" (name: string, address: u64, receiver: string) -> (mapping: system.Mapping, size: u64, ok: bool) {
	entry := system.image_resource_find(image, name)
	if entry == nil {
		return {}, 0, false
	}
	system.log_fact(.Info, Resource_Given{resource_size = value_kinds.Size_In_Bytes(entry.size), resource = text_field(name, 32), receiver = module_name_field(receiver)})
	// No flag: the mapping has the right Read only.
	return {memory = image_memory, address = address, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}, entry.size, true
}

// pointer_theme_choice gives the names of the pointer theme files that the
// compositor receives, in order: the theme of the owner when the build had
// its input, then the theme of the system (docs/POINTERS.md, section 5).
// The setting "pointer_theme" of the system (modus:contract/settings)
// chooses between them while the compositor runs: "owner" is the first one
// that the image has, "system" the last.
pointer_theme_choice :: proc "contextless" () -> []string {
	return pointer_pictures.RESOURCE_PREFERENCE[:]
}
