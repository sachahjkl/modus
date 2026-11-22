// Per-principal AEAD store page encryption and TPM NV anti-rollback helper
// bindings for storage_service (contract-level wiring pending disk-engine cutover).
package storage_service

import "modus:contract/store_crypto"

storage_grant_floor: store_crypto.Grant_Table_Floor

storage_page_seal_for_principal :: proc "contextless" (
	principal_master_key: [store_crypto.KEY_BYTES]u8,
	principal_id, store_id, page_index, version: u64,
	plain, out_sealed: []u8,
) -> (written: int, ok: bool) {
	subkey := store_crypto.derive_store_key(principal_master_key, principal_id, store_id)
	n, refusal := store_crypto.seal_page(subkey, page_index, version, plain, out_sealed)
	return n, refusal == .None
}

storage_page_open_for_principal :: proc "contextless" (
	principal_master_key: [store_crypto.KEY_BYTES]u8,
	principal_id, store_id, page_index, min_version: u64,
	sealed, out_plain: []u8,
) -> (written: int, version: u64, ok: bool) {
	subkey := store_crypto.derive_store_key(principal_master_key, principal_id, store_id)
	n, ver, refusal := store_crypto.open_page(subkey, page_index, min_version, sealed, out_plain)
	return n, ver, refusal == .None
}

storage_accept_grant_epoch :: proc "contextless" (epoch: u64, signature_verified: bool) -> bool {
	return store_crypto.grant_table_accept_epoch(&storage_grant_floor, epoch, signature_verified) == .None
}
