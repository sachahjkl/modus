package plans_recipes

// The objects of the recipes service by their hashes
// (src/md/features/recipes.md, "The local store").

import "modus:contract/blake3"

// blob_object_name gives "blob_" and the first 52 hexadecimal digits of a
// content hash, so content-addressed blobs (inputs, outputs, guest kernels,
// initial archives) live in the private store without colliding with other
// objects.
blob_object_name :: proc "contextless" (digest: blake3.Hash) -> (name: Private_Object_Name) {
	private_object_name_append(&name, "blob_")
	private_object_name_append_hash(&name, digest, REALISATION_NAME_HASH_DIGITS)
	return name
}
