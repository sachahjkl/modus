package root

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/system"

// The debug image (docs/MODULE_CONTRACT.md, "Debug information"): the
// debug objects of the modules, which the boot program read from the boot
// volume and the kernel gave this service. This service maps it read-only
// into each process with the grant Debug_Image, which names the procedures
// and the lines of a stop report. It reads none of it.

debug_image_memory: system.Handle
debug_image_size: u64

debug_image_take :: proc "contextless" (ctx: ^system.Context) {
	debug_image_memory = ctx.handles[op.ROOT_DEBUG_IMAGE]
	debug_image_size = ctx.values[op.ROOT_VALUE_DEBUG_IMAGE_SIZE]
	if debug_image_memory == 0 || debug_image_size == 0 || debug_image_size > fixed_addresses.RANGE_SPAN {
		debug_image_memory, debug_image_size = 0, 0
		system.log(.Info, "root: no debug image: a stop report names each frame by its module and its offset")
		return
	}
	system.log_fact(.Info, Debug_Image_Found{debug_image_size = value_kinds.Size_In_Bytes(debug_image_size)})
}

// debug_image_give adds the debug image, read-only, to the mappings of a
// process, and sets its size and its bit in the values. A machine with no
// debug image gives nothing: the process shows offsets.
debug_image_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if debug_image_memory == 0 {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the debug image", len(mappings))
		return
	}
	mappings[count^] = {memory = debug_image_memory, address = fixed_addresses.DEBUG_IMAGE_ADDRESS, first = 0, page_count = (debug_image_size + system.PAGE_SIZE - 1) / system.PAGE_SIZE, flags = {}}
	count^ += 1
	system.value_put(values, op.CONTEXT_VALUE_DEBUG_IMAGE_SIZE, debug_image_size)
	system.range_mapped_put(values, .Debug_Image)
}
