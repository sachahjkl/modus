// Read-only mapped-object cache and durable pin-accounting state owned by the
// storage service (src/md/features/objects_by_hash.md).
package storage_service

import object_cache "internal:storage/object_cache"
import "modus:contract/blake3"

storage_object_cache: object_cache.Cache
storage_object_pins: object_cache.Pin_Table

// storage_object_cache_init initializes the split read-only object cache and
// durable pin table with plan defaults.
storage_object_cache_init :: proc "contextless" () {
	object_cache.cache_init(&storage_object_cache, object_cache.default_cache_config())
	object_cache.pin_table_init(&storage_object_pins)
}

// storage_object_is_pinned reports whether any principal holds a durable pin on
// (store_index, hash), blocking collect_garbage and erase_versions.
storage_object_is_pinned :: proc "contextless" (store_index: u32, hash: blake3.Hash) -> bool {
	return object_cache.is_pinned(&storage_object_pins, store_index, hash)
}
