// Live per-principal AEAD store page encryption and TPM NV anti-rollback
// epoch guard integrated into the storage service.
package storage_service

import "modus:contract/store_crypto"

storage_grant_floor: store_crypto.Grant_Table_Floor

storage_page_seal_for_principal :: proc "contextless" (
	principal_master_key: [store_crypto.KEY_BYTES]u8,
	principal_id, store_id, page_index: u64,
	nonce: [store_crypto.NONCE_BYTES]u8,
	plain, out_sealed: []u8,
) -> (written: int, ok: bool) {
	subkey := store_crypto.derive_store_key(principal_master_key, principal_id, store_id)
	n, refusal := store_crypto.seal_page(subkey, page_index, nonce, plain, out_sealed)
	return n, refusal == .None
}

storage_page_open_for_principal :: proc "contextless" (
	principal_master_key: [store_crypto.KEY_BYTES]u8,
	principal_id, store_id, page_index: u64,
	sealed, out_plain: []u8,
) -> (written: int, ok: bool) {
	subkey := store_crypto.derive_store_key(principal_master_key, principal_id, store_id)
	n, refusal := store_crypto.open_page(subkey, page_index, sealed, out_plain)
	return n, refusal == .None
}

storage_accept_grant_epoch :: proc "contextless" (epoch: u64) -> bool {
	return store_crypto.grant_table_accept_epoch(&storage_grant_floor, epoch) == .None
}
