// Live mark-and-sweep module_files garbage collector and idempotent request
// serial deduplication log integrated into the storage service
// (src/md/features/declarations.md) and (src/md/features/supervision.md).
package storage_service

import "internal:storage/module_gc"
import "modus:contract/blake3"
import "modus:contract/supervision"

storage_gc_state: module_gc.Collector_State
storage_serial_log: supervision.Request_Serial_Log

// storage_module_gc_sweep runs mark-and-sweep reachability collection over
// stored module_files hashes from the given live roots (kept plans, signed
// system, disk grants).
storage_module_gc_sweep :: proc "contextless" (
	roots: []module_gc.Root,
	stored: []blake3.Hash,
	reader: ^module_gc.Object_Reader,
	sweep_scratch: []blake3.Hash,
	del_cb: module_gc.Delete_Callback,
	user_data: rawptr,
) -> (result: module_gc.Collect_Result, deleted_count: int) {
	return module_gc.collect_and_sweep(&storage_gc_state, roots, stored, reader, sweep_scratch, del_cb, user_data)
}

// storage_request_check_duplicate inspects whether (client_id, serial) was
// already committed so retried calls after a service restart produce no double effect.
storage_request_check_duplicate :: proc "contextless" (client_id, serial: u64) -> (status: supervision.Serial_Lookup_Status, cached_result: u64) {
	return supervision.request_serial_log_check(&storage_serial_log, client_id, serial)
}

// storage_request_commit_serial records a completed mutating storage operation
// in the per-client idempotency window.
storage_request_commit_serial :: proc "contextless" (client_id, serial, result_word: u64) -> supervision.Serial_Commit_Refusal {
	return supervision.request_serial_log_commit(&storage_serial_log, client_id, serial, result_word)
}
