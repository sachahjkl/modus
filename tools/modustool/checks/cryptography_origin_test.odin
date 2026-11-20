package checks

import "core:strings"
import "core:testing"
// The two packages of one name before the copy had its own names: this test
// package compiles only when the names differ.
import origin_sha2 "core:crypto/sha2"
import copy_sha2 "modus:support/cryptography/sha2"
import "modustool:foundation"

@(private = "file")
CRYPTOGRAPHY_TEST_ORIGIN_PATH :: CRYPTOGRAPHY_ORIGIN_PREFIX + "sha2/sha2.odin"

// An origin with a comment line that starts as the package line, an import
// of the base package, two imports of the copy with no alias, whose import
// names come from their paths and stay, one with an alias, and two imports
// of the compatibility layer.
@(private = "file")
CRYPTOGRAPHY_TEST_ORIGIN :: "/*\npackage sha2 implements the SHA2 hash algorithms.\n*/\npackage sha2\n\nimport \"core:crypto\"\nimport \"core:crypto/_aes\"\nimport \"core:crypto/_aes/ct64\"\nimport subtle \"core:crypto/_subtle\"\nimport \"core:crypto/hash\"\nimport \"core:math/bits\"\n"

@(private = "file")
CRYPTOGRAPHY_TEST_COPY :: "/*\npackage sha2 implements the SHA2 hash algorithms.\n*/\npackage modus_sha2\n\nimport crypto \"modus:support/cryptography/compatibility_crypto\"\nimport \"modus:support/cryptography/_aes\"\nimport \"modus:support/cryptography/_aes/ct64\"\nimport subtle \"modus:support/cryptography/_subtle\"\nimport hash \"modus:support/cryptography/compatibility_hash\"\nimport bits \"modus:support/cryptography/compatibility_bits\"\n"

// An origin outside each folder of the copy has no name in the copy.
@(test)
cryptography_origin_refuses_a_folder_of_no_package :: proc(t: ^testing.T) {
	origin_paths := [?]string{CRYPTOGRAPHY_ORIGIN_PREFIX + "sha3/sha3.odin", CRYPTOGRAPHY_ORIGIN_PREFIX + "sha2.odin", CRYPTOGRAPHY_ORIGIN_PREFIX + "sha2/inner/sha2.odin", "sha2.odin"}
	for origin_path in origin_paths {
		file, ok := cryptography_file_from_origin("package sha2\n", origin_path)
		testing.expectf(t, !ok, "the origin %s has no package of the copy", origin_path)
		testing.expect_value(t, file, "")
	}
}

// The package line of the origin must be the whole line, exactly one time,
// with the name of the row of its folder.
@(test)
cryptography_origin_refuses_a_package_line_that_is_not_one :: proc(t: ^testing.T) {
	origins := [?]string {
		"",
		"// package sha2\n",
		"package sha2 implements SHA-2.\n",
		" package sha2\n",
		"package sha2 \n",
		"package sha3\n",
		"package modus_sha2\n",
		"package sha2\npackage sha2\n",
	}
	for origin in origins {
		file, ok := cryptography_file_from_origin(origin, CRYPTOGRAPHY_TEST_ORIGIN_PATH)
		testing.expectf(t, !ok, "the origin %q has no single package line sha2", origin)
		testing.expect_value(t, file, "")
	}
	// The last line with no line end is a whole line too.
	file, ok := cryptography_file_from_origin("package sha2", CRYPTOGRAPHY_TEST_ORIGIN_PATH)
	testing.expect(t, ok)
	testing.expect_value(t, file, strings.concatenate({cryptography_marking(CRYPTOGRAPHY_TEST_ORIGIN_PATH), "package modus_sha2"}, context.temp_allocator))
}

// A file of the system in a folder of the copy declares the package of the
// copy, exactly one time: the name of the origin would bring the clash back.
@(test)
cryptography_system_file_refuses_the_name_of_the_origin :: proc(t: ^testing.T) {
	path := foundation.CRYPTOGRAPHY_FOLDER + "/_aes/hw/no_hardware.odin"
	texts := [?]string{"", "package aes_hw\n", "// package modus_aes_hw\n", "package modus_aes\n", "package modus_aes_hw\npackage modus_aes_hw\n"}
	for text in texts {
		testing.expectf(t, !cryptography_system_file_package_holds(path, text), "%q is not the package of the copy", text)
	}
	testing.expect(t, cryptography_system_file_package_holds(path, "#+build !freestanding\npackage modus_aes_hw\n"))
	// The compatibility layer is in no folder of the origin: its names are its own.
	testing.expect(t, cryptography_system_file_package_holds(foundation.CRYPTOGRAPHY_FOLDER + "/compatibility_crypto/crypto.odin", "package compatibility_crypto\n"))
}

// Two rows of one folder, or of one name, would make the package of a
// folder depend on the order of the rows, or give two folders one declared
// name.
@(test)
cryptography_packages_have_one_row_each :: proc(t: ^testing.T) {
	for first, first_index in cryptography_packages {
		testing.expect(t, first.folder != "" && first.origin_name != "")
		testing.expect(t, !strings.has_prefix(first.origin_name, CRYPTOGRAPHY_PACKAGE_PREFIX))
		for second, second_index in cryptography_packages {
			if first_index != second_index {
				testing.expectf(t, first.folder != second.folder, "two rows of the folder %s", first.folder)
				testing.expectf(t, first.origin_name != second.origin_name, "two rows of the name %s", first.origin_name)
			}
		}
	}
}

// The origin with the package line of the copy and the import changes,
// after the marking; nothing else. No import gets an alias that its origin
// has not.
@(test)
cryptography_origin_gives_the_package_name_of_the_copy :: proc(t: ^testing.T) {
	file, ok := cryptography_file_from_origin(CRYPTOGRAPHY_TEST_ORIGIN, CRYPTOGRAPHY_TEST_ORIGIN_PATH)
	testing.expect(t, ok)
	testing.expect_value(t, file, strings.concatenate({cryptography_marking(CRYPTOGRAPHY_TEST_ORIGIN_PATH), CRYPTOGRAPHY_TEST_COPY}, context.temp_allocator))
	testing.expect(t, strings.has_prefix(file, "// Altered source: Odin "))
	testing.expect(t, strings.contains(file, "only its package name and its imports changed"))
	testing.expect(t, !strings.contains(file, "\npackage sha2\n"))
	testing.expect(t, !strings.contains(file, "\"core:"))
	testing.expect(t, !strings.contains(file, "import aes_ct64 "))
	testing.expect(t, !strings.contains(file, "import _aes "))
}

// The copy and core:crypto in one program compute one SHA-256: FIPS 180-2,
// appendix B.1, the message "abc".
@(test)
cryptography_copy_and_core_library_in_one_program :: proc(t: ^testing.T) {
	EXPECTED_DIGEST :: [32]u8{0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad}
	message := "abc"
	origin_digest, copy_digest: [32]u8
	origin_context: origin_sha2.Context_256
	origin_sha2.init_256(&origin_context)
	origin_sha2.update(&origin_context, transmute([]u8)message)
	origin_sha2.final(&origin_context, origin_digest[:])
	copy_context: copy_sha2.Context_256
	copy_sha2.init_256(&copy_context)
	copy_sha2.update(&copy_context, transmute([]u8)message)
	copy_sha2.final(&copy_context, copy_digest[:])
	testing.expect(t, origin_digest == EXPECTED_DIGEST)
	testing.expect(t, copy_digest == origin_digest)
}
