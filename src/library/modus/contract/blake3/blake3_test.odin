#+build !freestanding
#+build !modus
package blake3

import "core:encoding/hex"
import "core:testing"

// The official test vectors of BLAKE3 (test_vectors/test_vectors.json in
// github.com/BLAKE3-team/BLAKE3): the input size, and the first 32 bytes of
// the hash. Byte i of the input is i modulo 251.
@(private = "file")
Vector :: struct {
	size: int,
	hash: string,
}

@(private = "file")
vectors := [?]Vector {
	{0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
	{1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"},
	{2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"},
	{3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"},
	{4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32"},
	{5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2"},
	{6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844"},
	{7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe"},
	{8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb"},
	{63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"},
	{64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"},
	{65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"},
	{127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d"},
	{128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef"},
	{129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12"},
	{1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"},
	{1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"},
	{1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"},
	{2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"},
	{2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"},
	{3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"},
	{3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3"},
	{4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"},
	{4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"},
	{5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833"},
	{5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff"},
	{6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205"},
	{6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f"},
	{7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a"},
	{7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817"},
	{8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"},
	{8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"},
	{16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"},
	{31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"},
	{102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"},
}

@(test)
official_vectors :: proc(t: ^testing.T) {
	input := make([]u8, 102400)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	for vector in vectors {
		result := hash(input[:vector.size])
		text := string(hex.encode(result[:], context.temp_allocator))
		testing.expectf(t, text == vector.hash, "size %d: got %s, want %s", vector.size, text, vector.hash)
		// Verify that root_words_with_key with INITIAL_VALUE and no domain
		// flags reproduces every official plain BLAKE3 vector.
		keyed_plain := words_to_hash(root_words_with_key(input[:vector.size], INITIAL_VALUE, {}))
		testing.expect_value(t, keyed_plain, result)
	}
}

// The keyed vectors of the same official file: key is the 32 bytes of
// "whats the Elvish word for friend".
@(private = "file")
keyed_vectors := [?]Vector {
	{0, "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"},
	{1, "6d7878dfff2f485635d39013278ae14f1454b8c0a3a2d34bc1ab38228a80c95b"},
	{1023, "c951ecdf03288d0fcc96ee3413563d8a6d3589547f2c2fb36d9786470f1b9d6e"},
	{1025, "357dc55de0c7e382c900fd6e320acc04146be01db6a8ce7210b7189bd664ea69"},
	{3073, "68dede9bef00ba89e43f31a6825f4cf433389fedae75c04ee9f0cf16a427c95a"},
}

@(test)
official_keyed_vectors :: proc(t: ^testing.T) {
	input := make([]u8, 3073)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	key: Hash
	key_text := "whats the Elvish word for friend"
	for index in 0 ..< HASH_SIZE {
		key[index] = key_text[index]
	}
	for vector in keyed_vectors {
		result := keyed_hash(key, input[:vector.size])
		text := string(hex.encode(result[:], context.temp_allocator))
		testing.expectf(t, text == vector.hash, "size %d: got %s, want %s", vector.size, text, vector.hash)
	}
	// A different key gives a different tag for the same input.
	other_key := key
	other_key[0] ~= 1
	testing.expect(t, keyed_hash(other_key, input[:64]) != keyed_hash(key, input[:64]))
	testing.expect(t, keyed_hash(key, input[:64]) != hash(input[:64]))
}

@(test)
derive_key_domain_separation :: proc(t: ^testing.T) {
	sizes := [?]int{0, 1, 63, 64, 65, 1024, 1025, 4096, 8193}
	input := make([]u8, 8193)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	for size in sizes {
		slice := input[:size]
		plain := hash(slice)
		derived_a := derive_key("modus tree v1", slice)
		derived_b := derive_key("modus object v1", slice)
		derived_a_again := derive_key("modus tree v1", slice)
		testing.expectf(t, derived_a != plain, "size %d: derive_key collided with plain hash", size)
		testing.expectf(t, derived_a != derived_b, "size %d: distinct contexts collided", size)
		testing.expect_value(t, derived_a, derived_a_again)
	}
	// Multi-chunk context string (> 1024 bytes) works and differs from short context.
	long_context := make([]u8, 2049)
	defer delete(long_context)
	for &b, i in long_context {
		b = u8('a' + (i % 26))
	}
	long_derived := derive_key(string(long_context), input[:128])
	short_derived := derive_key("modus tree v1", input[:128])
	testing.expect(t, long_derived != short_derived)
	testing.expect(t, long_derived != hash(input[:128]))
}

@(test)
chaining_value_bytes_roundtrip_and_tree_root_match :: proc(t: ^testing.T) {
	input := make([]u8, 8 * CHUNK_SIZE + 37)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	left := subtree_chaining_value(input[:8 * CHUNK_SIZE], 0)
	right := subtree_chaining_value(input[8 * CHUNK_SIZE:], 8)
	left_bytes := chaining_value_bytes(left)
	right_bytes := chaining_value_bytes(right)
	testing.expect_value(t, chaining_value_of_bytes(left_bytes), left)
	testing.expect_value(t, chaining_value_of_bytes(right_bytes), right)
	testing.expect_value(t, root_of_children(chaining_value_of_bytes(left_bytes), chaining_value_of_bytes(right_bytes)), hash(input))
}
