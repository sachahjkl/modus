// The port of a private store over the storage client: the services of the
// declarations (plans, recipes, projects) keep their records through
// plans_recipes.Private_Store_Port, and this package binds that port to the
// private store that the root service gave the process
// (src/md/features/declarations.md, "Storage").
package storage_port

import pr "modus:contract/plans_recipes"
import "modus:storage"
import "modus:system"

// The connection to the private store of the process.
store_client: storage.Client

// bind opens the private store that the root service gave in the context,
// and gives its port: whole objects of any size, the size of an object,
// ranges, removes, the listing and the counts (large_objects.odin). ok is
// false for a process with no grant Store: the port then has no procedure,
// and each access fails.
bind :: proc "contextless" (ctx: ^system.Context) -> (port: pr.Private_Store_Port, ok: bool) {
	store_client, ok = storage.open(ctx)
	if !ok {
		return {}, false
	}
	return {user = &store_client, read = port_read, write = port_write, write_range = port_write_range, rename = port_rename, size = port_size, read_range = port_read_range, remove = port_remove, list = port_list, usage = port_usage}, true
}
