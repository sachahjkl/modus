package module_files

// The client of the storage service of this service, as the calls of the
// write of a file (module_files_core, file_stream.odin).

import "internal:module_files/module_files_core"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:storage"

// The calls of the client of this service.
client_file_store := module_files_core.File_Store {
	write_range = proc "contextless" (user: rawptr, name: string, offset: u64, bytes: []u8, error: ^errors.Error_Record) -> storage_status.Status {
		_, status := storage.write_range(&store_client, storage.ROOT, name, offset, bytes, error)
		return status
	},
	set_size = proc "contextless" (user: rawptr, name: string, size: u64, error: ^errors.Error_Record) -> storage_status.Status {
		return storage.set_size(&store_client, storage.ROOT, name, size, error)
	},
	commit = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
		_, status := storage.commit(&store_client, storage.ROOT, name, error)
		return status
	},
	clone = proc "contextless" (user: rawptr, name: string, new_name: string, error: ^errors.Error_Record) -> storage_status.Status {
		_, status := storage.clone(&store_client, storage.ROOT, name, new_name, error)
		return status
	},
	remove = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
		_, status := storage.remove(&store_client, storage.ROOT, name, error)
		return status
	},
	drop_pending = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
		return storage.drop_pending(&store_client, storage.ROOT, name, error)
	},
}
