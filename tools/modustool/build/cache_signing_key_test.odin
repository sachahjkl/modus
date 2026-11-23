package build

import "core:strings"
import "core:testing"
import "modus:contract/system_description"

// The seed of the test signing key (RFC 8032, section 7.1, TEST 1): published.
@(private = "file")
TEST_SEED_DIGITS :: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

@(private = "file")
THROWAWAY_SEED_DIGITS :: "0101010101010101010101010101010101010101010101010101010101010101"

@(test)
a_cache_signing_key_is_refused_before_it_is_written :: proc(t: ^testing.T) {
	// The edges of the length: empty, one digit short, one digit past.
	for text in ([3]string{"", THROWAWAY_SEED_DIGITS[:63], THROWAWAY_SEED_DIGITS + "0"}) {
		_, problem := cache_signing_key_public_of(text)
		testing.expect(t, strings.contains(problem, "64 hexadecimal digits"))
	}
	_, not_digits := cache_signing_key_public_of("g" + THROWAWAY_SEED_DIGITS[1:])
	testing.expect(t, strings.contains(not_digits, "hexadecimal digits only"))
	// The seed of the test signing key is published.
	_, test_key := cache_signing_key_public_of(TEST_SEED_DIGITS)
	testing.expect(t, strings.contains(test_key, "test signing key"))

	public_key, problem := cache_signing_key_public_of(THROWAWAY_SEED_DIGITS + "\n")
	testing.expect_value(t, problem, "")
	digits := system_description.hexadecimal(public_key)

	// The committed file: absent, damaged, another key; then the same key.
	testing.expect(t, strings.contains(cache_signing_key_committed_check(public_key, "", false), "is not in the repository"))
	testing.expect(t, strings.contains(cache_signing_key_committed_check(public_key, "not a key", true), "64 hexadecimal digits"))
	other := system_description.hexadecimal(system_description.TEST_PUBLIC_KEY)
	testing.expect(t, strings.contains(cache_signing_key_committed_check(public_key, string(other[:]), true), "would refuse each upload"))
	testing.expect_value(t, cache_signing_key_committed_check(public_key, strings.concatenate({string(digits[:]), "\n"}, context.temp_allocator), true), "")
}
