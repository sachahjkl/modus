package build

import info "modus:contract/boot_info"
import "modus:contract/system_description"
import "modus:support/cryptography/ed25519"
import "core:fmt"
import "core:strings"
import "core:testing"

// The test signing key of the repository is the key of RFC 8032, section
// 7.1, TEST 1, and its public key is the one that the boot program knows as
// the test key.
@(test)
the_test_signing_key_is_the_published_one :: proc(t: ^testing.T) {
	seed, ok := signing_key_file_read(TEST_SIGNING_KEY_FILE)
	testing.expect(t, ok)
	private_key: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&private_key, seed[:]))
	public: [system_description.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&private_key, public[:])
	testing.expect(t, public == system_description.TEST_PUBLIC_KEY)
	// A signature of a signed message verifies with the public key, and
	// not after one bit of the message changed.
	message: [system_description.SIGNED_MESSAGE_SIZE]u8
	message[3] = 7
	signature: [system_description.SIGNATURE_SIZE]u8
	ed25519.sign(&private_key, message[:], signature[:])
	public_key: ed25519.Public_Key
	testing.expect(t, ed25519.public_key_set_bytes(&public_key, public[:]))
	testing.expect(t, ed25519.verify(&public_key, message[:], signature[:]))
	message[40] ~= 1
	testing.expect(t, !ed25519.verify(&public_key, message[:], signature[:]))
}

@(test)
a_private_key_stays_outside_the_repository :: proc(t: ^testing.T) {
	testing.expect(t, path_inside_repository(TEST_SIGNING_KEY_FILE))
	testing.expect(t, path_inside_repository("tools/signing_key"))
	testing.expect(t, path_inside_repository("."))
	testing.expect(t, !path_inside_repository("/nonexistent_folder_of_a_test/signing_key"))
}

@(test)
a_key_file_is_64_hexadecimal_digits :: proc(t: ^testing.T) {
	for character in "0123456789abcdefABCDEF" {
		_, valid := signing_key_digit(u8(character))
		testing.expect(t, valid)
	}
	for character in "g /x" {
		_, valid := signing_key_digit(u8(character))
		testing.expect(t, !valid)
	}
}

// The file of the key numbers of the repository gives the test signing key
// a number that the key floor holds.
@(test)
the_test_signing_key_has_a_key_number :: proc(t: ^testing.T) {
	key_number, ok := key_number_read(system_description.TEST_PUBLIC_KEY)
	testing.expect(t, ok)
	testing.expect(t, key_number >= 1 && key_number <= info.FLOOR_LIMIT)
	// The key of the publisher of the system has a line too, with a number
	// above the test key: a release build finds its number.
	publisher_key: [system_description.PUBLIC_KEY_SIZE]u8
	publisher_text := "5524fa42ae11f279428be205c8f379c1366257121472ab033978e683f7bcdba2"
	for index in 0 ..< system_description.PUBLIC_KEY_SIZE {
		high, _ := signing_key_digit(publisher_text[2 * index])
		low, _ := signing_key_digit(publisher_text[2 * index + 1])
		publisher_key[index] = high << 4 | low
	}
	publisher_number, publisher_found := key_number_read(publisher_key)
	testing.expect(t, publisher_found)
	testing.expect(t, publisher_number > key_number)
}

// The reader of the key numbers takes each line whole, and refuses a line
// that is not a number from 1 to the limit, one space and 64 lowercase
// digits, a number or a key that comes twice, and a key with no line.
@(test)
the_key_numbers_have_one_form :: proc(t: ^testing.T) {
	key := system_description.TEST_PUBLIC_KEY
	digits := system_description.hexadecimal(key)
	other_key := key
	other_key[0] ~= 1
	other_digits := system_description.hexadecimal(other_key)
	key_text := string(digits[:])
	other_text := string(other_digits[:])

	key_number, problem := key_number_of(fmt.tprintf("1 %s\n2 %s\n", other_text, key_text), key)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, key_number, 2)
	key_number, problem = key_number_of(fmt.tprintf("%d %s", info.FLOOR_LIMIT, key_text), key)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, key_number, u64(info.FLOOR_LIMIT))

	refused := [?]string {
		fmt.tprintf("1 %s\n", other_text), // No line for the key.
		fmt.tprintf("0 %s\n", key_text), // The number 0.
		fmt.tprintf("%d %s\n", info.FLOOR_LIMIT + 1, key_text), // Above the limit of the floor.
		fmt.tprintf("99999999999999999999999 %s\n", key_text), // A number that does not fit.
		fmt.tprintf("1 %s\n1 %s\n", other_text, key_text), // One number twice.
		fmt.tprintf("1 %s\n2 %s\n", key_text, key_text), // One key twice.
		fmt.tprintf("1  %s\n", key_text), // Two spaces.
		fmt.tprintf("1 %s\n", strings.to_upper(key_text, context.temp_allocator)), // Upper case digits.
		fmt.tprintf("1 %s\n", key_text[:63]), // 63 digits.
		fmt.tprintf("x1 %s\n", key_text), // A number that is not one.
		fmt.tprintf("\n1 %s\n", key_text), // An empty line.
		"",
	}
	for text in refused {
		key_number, problem = key_number_of(text, key)
		testing.expectf(t, problem != "" && key_number == 0, "the file of the key numbers %q is taken", text)
	}
}

// The value of the measure register depends on each byte of the
// description: one changed byte gives another value.
@(test)
the_measure_depends_on_the_description :: proc(t: ^testing.T) {
	description := []u8{1, 2, 3, 4}
	changed := []u8{1, 2, 3, 5}
	testing.expect(t, measure_expected(description) == measure_expected(description))
	testing.expect(t, measure_expected(description) != measure_expected(changed))
	zero: [32]u8
	testing.expect(t, measure_expected(description) != zero)
}
