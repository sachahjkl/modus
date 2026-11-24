package plans_recipes

// The content-addressed objects of the recipes service by their hashes
// (src/md/features/recipes.md, "The local store of the realisations").

import "modus:contract/blake3"

// blob_object_name gives the exact 64 lowercase hexadecimal digits of a
// content hash, so all content-addressed objects (blobs, canonical trees,
// builder outputs frozen by storage.freeze_tree, put/put_memory inputs,
// guest kernels/archives, and remote cache objects) share one layout at the
// root of the private store without colliding with prefixed metadata objects
// (realisation_*, recipe_*) or the temporary build tree.
blob_object_name :: proc "contextless" (digest: blake3.Hash) -> (name: Private_Object_Name) {
	private_object_name_append_hash(&name, digest, 2 * blake3.HASH_SIZE)
	return name
}

// hash_of_blob_object_name parses a 64-character lowercase hexadecimal object
// name back into its 32-byte BLAKE3 hash. Any prefix, uppercase digit, wrong
// length, or non-hex byte is refused.
hash_of_blob_object_name :: proc "contextless" (text: string) -> (hash: blake3.Hash, ok: bool) {
	if len(text) != 2 * blake3.HASH_SIZE {
		return {}, false
	}
	return hash_of_hexadecimal(transmute([]u8)text)
}
