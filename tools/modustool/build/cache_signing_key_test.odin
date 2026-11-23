package build

import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/system_description"
import "modustool:foundation"

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

@(private = "file")
expect_private_file :: proc(t: ^testing.T, path: string) {
	information, stat_error := os.stat(path, context.temp_allocator)
	testing.expect_value(t, stat_error, nil)
	testing.expect_value(t, information.mode, os.perm(0o600))
}

@(test)
the_key_commands_of_the_cache_signing_key :: proc(t: ^testing.T) {
	// The forms that the command refuses: no folder must not become
	// `key new` of a folder named cache.
	testing.expect_value(t, run_key({"new", "cache"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_key({"write", "cache"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_key({"show", "cache", "more"}), foundation.EXIT_USAGE)
	testing.expect(t, !os.exists("cache"))

	public_key, _ := cache_signing_key_public_of(THROWAWAY_SEED_DIGITS)
	public_digits := system_description.hexadecimal(public_key)
	public_text := strings.concatenate({string(public_digits[:]), "\n"}, context.temp_allocator)

	// A folder inside the repository.
	inside := "build/cache_signing_key_test_folder"
	testing.expect_value(t, run_key({"new", "cache", inside}), foundation.EXIT_USAGE)
	testing.expect(t, !cache_signing_key_write_text(inside, THROWAWAY_SEED_DIGITS, public_text, true))
	testing.expect(t, !os.exists(inside))

	folder, folder_error := os.make_directory_temp("", "modus_cache_key_test_*", context.temp_allocator)
	testing.expect_value(t, folder_error, nil)
	defer os.remove_all(folder)

	// An empty variable.
	_ = os.unset_env(CACHE_SIGNING_KEY_TEXT_VARIABLE)
	empty_folder := strings.concatenate({folder, "/empty"}, context.temp_allocator)
	testing.expect_value(t, run_key({"write", "cache", empty_folder}), foundation.EXIT_FAILURE)
	testing.expect(t, !cache_signing_key_write_text(empty_folder, "", public_text, true))
	testing.expect(t, !os.exists(empty_folder))

	// A seed whose public key is not the committed one, and no committed file.
	other_digits := system_description.hexadecimal(system_description.TEST_PUBLIC_KEY)
	other_folder := strings.concatenate({folder, "/other"}, context.temp_allocator)
	testing.expect(t, !cache_signing_key_write_text(other_folder, THROWAWAY_SEED_DIGITS, string(other_digits[:]), true))
	testing.expect(t, !cache_signing_key_write_text(other_folder, THROWAWAY_SEED_DIGITS, "", false))
	testing.expect(t, !os.exists(other_folder))

	// The write, then a second write over the file that exists.
	written_folder := strings.concatenate({folder, "/written"}, context.temp_allocator)
	testing.expect(t, cache_signing_key_write_text(written_folder, THROWAWAY_SEED_DIGITS, public_text, true))
	expect_private_file(t, strings.concatenate({written_folder, "/", foundation.CACHE_SIGNING_KEY_FILE_NAME}, context.temp_allocator))
	written_public, _ := os.read_entire_file(strings.concatenate({written_folder, "/", foundation.CACHE_SIGNING_KEY_FILE_NAME, foundation.CACHE_SIGNING_KEY_PUBLIC_SUFFIX}, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(written_public), public_text)
	testing.expect(t, !cache_signing_key_write_text(written_folder, THROWAWAY_SEED_DIGITS, public_text, true))

	// key new cache: a new key, then a refusal of a second one.
	new_folder := strings.concatenate({folder, "/new"}, context.temp_allocator)
	testing.expect_value(t, run_key({"new", "cache", new_folder}), 0)
	expect_private_file(t, strings.concatenate({new_folder, "/", foundation.CACHE_SIGNING_KEY_FILE_NAME}, context.temp_allocator))
	testing.expect_value(t, run_key({"new", "cache", new_folder}), foundation.EXIT_FAILURE)
}
