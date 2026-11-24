package storage

import "modus:contract/builder"
import module "modus:contract/module"
import "modus:system"

// builder_stores_open opens the two stores of a builder
// (src/md/features/recipes.md, "The builder"): the input store, a share
// that reads only, and the store "out", a share that changes, both in the
// context that the service recipes gives the call host of the builder
// (modus:contract/builder). ok is false when a handle is missing or the
// file of the storage service is not mapped: the process is no builder.
builder_stores_open :: proc "contextless" (ctx: ^system.Context) -> (input, output: Client, ok: bool) {
	service := ctx.handles[builder.GRANT_STORAGE_SERVICE]
	size := ctx.values[builder.VALUE_STORAGE_FILE_SIZE]
	if service == 0 || size == 0 {
		return {}, {}, false
	}
	file_address := uintptr(FILE_ADDRESS)
	file := ([^]u8)(file_address)[:size]
	if module.validate(file) != .None {
		return {}, {}, false
	}
	// Both stores are shares that the storage service mapped before it gave
	// them (system.connection_make), with no ready completion.
	if input, ok = open_mapped(ctx.handles[builder.GRANT_INPUT_RING], ctx.handles[builder.GRANT_INPUT_REGION], service, file); !ok {
		return {}, {}, false
	}
	if output, ok = open_mapped(ctx.handles[builder.GRANT_OUTPUT_RING], ctx.handles[builder.GRANT_OUTPUT_REGION], service, file); !ok {
		system.ring_close(&input.calls)
		system.memory_unmap(raw_data(input.region))
		return {}, {}, false
	}
	return input, output, true
}
