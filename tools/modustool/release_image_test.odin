package modustool

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/pointer_pictures"
import "modus:contract/replacement_list"
import "modus:contract/system_description"
import "modus:support/cryptography/ed25519"

// The seed of a release signing key of these tests only: 32 bytes.
@(private = "file")
TEST_SEED_TEXT :: "modus release signature test 01!"

// A seed and its public key from the tests of the package signing of
// gui_toolkit: the key text of a release has the form of that package.
@(private = "file")
TOOLKIT_SEED_TEXT :: "d3Jlbi1kZXYtbGljZW5zZS10ZXN0LXNlZWQtMDAwMSE"
@(private = "file")
TOOLKIT_SEED_BYTES :: "wren-dev-license-test-seed-0001!"
@(private = "file")
TOOLKIT_PUBLIC_TEXT :: "NLbdwv2jpoDIMu5pVxyjYBUMEu2Lvfd8StzxR0PGqs8"

// The SHA-256 of "abc" (FIPS 180-2, appendix B.1).
@(private = "file")
SHA256_OF_ABC :: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

@(private = "file")
test_seed :: proc() -> []u8 {
	seed_text: string = TEST_SEED_TEXT
	return transmute([]u8)seed_text
}

@(test)
a_release_key_has_the_text_form_of_the_signing_package_of_the_toolkit :: proc(t: ^testing.T) {
	seed, decoded := release_key_decode("  " + TOOLKIT_SEED_TEXT + "\n")
	testing.expect(t, decoded, "white space around a key is no part of it")
	testing.expect_value(t, string(seed[:]), TOOLKIT_SEED_BYTES)
	testing.expect_value(t, base64url_text(seed[:]), TOOLKIT_SEED_TEXT)
	public_key, made := public_key_of_seed(seed[:])
	testing.expect(t, made, "any 32 bytes are a seed")
	testing.expect_value(t, base64url_text(public_key[:]), TOOLKIT_PUBLIC_TEXT)
	_, padded := release_key_decode(TOOLKIT_SEED_TEXT + "=")
	testing.expect(t, !padded, "a key text has no padding")
	_, short := release_key_decode("AAAA")
	testing.expect(t, !short, "a key is 32 bytes")
	_, other_alphabet := release_key_decode("not a key!")
	testing.expect(t, !other_alphabet, "a key text is base64url")
}

@(test)
a_release_signature_verifies_and_a_changed_byte_is_refused :: proc(t: ^testing.T) {
	seed := test_seed()
	public_key, made := public_key_of_seed(seed)
	testing.expect(t, made)
	image_text: string = "the bytes of an image"
	list := release_checksum_list_text("modus-0.1.0-x86_64.img.zst", transmute([]u8)image_text)
	signature, signed := release_sign(seed, transmute([]u8)list)
	testing.expect(t, signed)
	testing.expect_value(t, len(signature), 86) // 64 bytes in base64url with no padding.
	testing.expect(t, !strings.contains(signature, "="), "a signature text has no padding")
	testing.expect(t, release_signature_verifies(public_key, transmute([]u8)list, signature), "the signature of the key verifies")
	testing.expect(t, release_signature_verifies(public_key, transmute([]u8)list, strings.concatenate({signature, "\n"}, context.temp_allocator)), "the end of line of the file is no part of the signature")

	changed_list := make([]u8, len(list), context.temp_allocator)
	copy(changed_list, list)
	changed_list[0] ~= 0x01
	testing.expect(t, !release_signature_verifies(public_key, changed_list, signature), "a changed byte of the list is refused")

	changed_signature := transmute([]u8)strings.clone(signature, context.temp_allocator)
	changed_signature[10] = changed_signature[10] == 'A' ? 'B' : 'A'
	testing.expect(t, !release_signature_verifies(public_key, transmute([]u8)list, string(changed_signature)), "a changed character of the signature is refused")

	other_seed: [RELEASE_KEY_SIZE]u8
	other_public_key, _ := public_key_of_seed(other_seed[:])
	testing.expect(t, !release_signature_verifies(other_public_key, transmute([]u8)list, signature), "another key is refused")

	// A signature of the list with no context is not a release signature:
	// the context binds the key to this one use.
	private_key: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&private_key, seed))
	signature_without_context: [ed25519.SIGNATURE_SIZE]u8
	ed25519.sign(&private_key, transmute([]u8)list, signature_without_context[:])
	ed25519.private_key_clear(&private_key)
	testing.expect(t, !release_signature_verifies(public_key, transmute([]u8)list, base64url_text(signature_without_context[:])), "a signature with no context is refused")
}

@(test)
the_checksum_list_has_the_form_of_sha256sum :: proc(t: ^testing.T) {
	abc: string = "abc"
	list := release_checksum_list_text("a.img.zst", transmute([]u8)abc)
	testing.expect_value(t, list, SHA256_OF_ABC + "  a.img.zst\n")
	rows, problem := release_checksum_list_parse(list)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].digits, SHA256_OF_ABC)
		testing.expect_value(t, rows[0].file_name, "a.img.zst")
	}
	refused := []string {
		strings.trim_suffix(list, "\n"),
		SHA256_OF_ABC + " a.img.zst\n",
		strings.concatenate({strings.to_upper(SHA256_OF_ABC, context.temp_allocator), "  a.img.zst\n"}, context.temp_allocator),
		SHA256_OF_ABC + "  folder/a.img.zst\n",
		SHA256_OF_ABC + "  *a.img.zst\n",
		SHA256_OF_ABC + "  \n",
		"\n",
		strings.concatenate({list, list}, context.temp_allocator),
	}
	for text in refused {
		_, refusal := release_checksum_list_parse(text)
		testing.expectf(t, refusal != "", "the checksum list %q is refused", text)
	}
}

// The files of the boot image of the build in the test below: two modules,
// then one resource.
@(private = "file")
RELEASE_TEST_MODULE_COUNT :: 2

@(private = "file")
release_test_files :: proc(root_text, console_text: string, resource_name: string) -> []Image_File {
	files := make([]Image_File, RELEASE_TEST_MODULE_COUNT + 1, context.temp_allocator)
	files[0] = Image_File{name = ROOT_SERVICE_MODULE, file = transmute([]u8)root_text}
	files[1] = Image_File{name = "console", file = transmute([]u8)console_text}
	files[2] = Image_File{name = resource_name, file = transmute([]u8)resource_name}
	return files
}

// release_test_volume_write writes the files beside a volume: the boot
// image of the volume (the files, then the three resources that the build
// of a volume adds, with a system description that names the kernel) and
// the file that says who signed it.
@(private = "file")
release_test_volume_write :: proc(volume, signed_by: string, files: []Image_File, kernel_text: string) {
	header := system_description.Header{magic = system_description.MAGIC, version = system_description.VERSION, entry_count = 1, security_version = system_description.SECURITY_VERSION}
	kernel_entry := description_entry(system_description.KERNEL_ENTRY_NAME, .Kernel, transmute([]u8)kernel_text)
	description := make([dynamic]u8, context.temp_allocator)
	append(&description, ..mem.ptr_to_bytes(&header))
	append(&description, ..mem.ptr_to_bytes(&kernel_entry))
	signature: [ed25519.SIGNATURE_SIZE]u8
	replacement_rows: string = "replacement rows"
	all_files := make([dynamic]Image_File, context.temp_allocator)
	append(&all_files, ..files)
	append(&all_files, Image_File{name = replacement_list.RESOURCE_NAME, file = transmute([]u8)replacement_rows})
	append(&all_files, Image_File{name = system_description.RESOURCE_DESCRIPTION, file = description[:]})
	append(&all_files, Image_File{name = system_description.RESOURCE_SIGNATURE, file = signature[:]})
	_ = os.write_entire_file(signed_image_path(volume), boot_image_encode(all_files[:], RELEASE_TEST_MODULE_COUNT))
	_ = os.write_entire_file(signed_by_file_path(volume), transmute([]u8)signed_by)
}

// A volume that the test signing key signed, a boot image with another
// build of the root service, a boot image of a measure run, a changed
// module and a changed kernel are never packaged for a release.
@(test)
a_volume_of_a_test_is_never_packaged :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "release_image_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	defer os.remove_all(folder)
	volume := join(folder, "/boot_volume_test.img")
	root_text, console_text, kernel_text: string = "the module root of the build", "the module console of the build", "the kernel of the build"
	kernel_hash := blake3.hash(transmute([]u8)kernel_text)
	build_files := release_test_files(root_text, console_text, "fonts")
	build_image := boot_image_encode(build_files, RELEASE_TEST_MODULE_COUNT)

	release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, build_files, kernel_text)
	testing.expect_value(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash), "")

	release_test_volume_write(volume, SIGNED_BY_TEST_KEY_TEXT, build_files, kernel_text)
	testing.expect(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash) != "", "the test signing key is refused")
	testing.expect_value(t, release_volume_problem(volume, .Test_Keys_Allowed, build_image, kernel_hash), "")

	release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, release_test_files("a root service of another build", console_text, "fonts"), kernel_text)
	testing.expect(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash) != "", "another root service is refused")
	testing.expect(t, release_volume_problem(volume, .Test_Keys_Allowed, build_image, kernel_hash) != "", "another root service is refused in a test too")

	release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, release_test_files(root_text, "a console that a test changed", "fonts"), kernel_text)
	testing.expect(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash) != "", "a changed module is refused")

	measure_files := make([dynamic]Image_File, context.temp_allocator)
	append(&measure_files, ..build_files)
	measure_run_text: string = MEASURE_RUN_RESOURCE_NAME
	append(&measure_files, Image_File{name = MEASURE_RUN_RESOURCE_NAME, file = transmute([]u8)measure_run_text})
	release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, measure_files[:], kernel_text)
	testing.expect(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash) != "", "the boot image of a measure run is refused")

	release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, build_files, "a kernel that a test changed")
	testing.expect(t, release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash) != "", "a changed kernel is refused")

	release_test_volume_write(volume, "another text\n", build_files, kernel_text)
	testing.expect(t, release_volume_problem(volume, .Test_Keys_Allowed, build_image, kernel_hash) != "", "an unknown signer is refused")

	_ = os.remove(signed_by_file_path(volume))
	testing.expect(t, release_volume_problem(volume, .Test_Keys_Allowed, build_image, kernel_hash) != "", "a volume that does not say who signed it is refused")
}

// release_test_pointer_theme makes a pointer theme file of one shape under
// a license, as the build makes one from a manifest.
@(private = "file")
release_test_pointer_theme :: proc(t: ^testing.T, license: string) -> []u8 {
	text := fmt.tprintf("theme Small\nlicense %s\nattribution a theme of a test\nsizes 12\nshape arrow hot 0 0\n|X\n", license)
	manifest, problem := manifest_parse("release_test.manifest", text)
	testing.expect_value(t, problem, "")
	file, _, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	return file
}

// A published volume holds the pointer theme of the system only: the
// resource of the theme of the owner is refused by its name, and a pointer
// theme file under another license by its header, whatever its name. A
// volume of the machine test, a development build, may hold them.
@(test)
a_release_holds_the_pointer_theme_of_the_system_only :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "release_image_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	defer os.remove_all(folder)
	volume := join(folder, "/boot_volume_test.img")
	root_text, console_text, kernel_text: string = "the module root of the build", "the module console of the build", "the kernel of the build"
	kernel_hash := blake3.hash(transmute([]u8)kernel_text)
	repository_license, license_found := repository_license_read()
	testing.expect(t, license_found, "LICENSE names an SPDX identifier")
	owner_text: string = "any bytes under the name of the theme of the owner"

	cases := []struct {
		resource_name: string,
		file:          []u8,
		accepted:      bool,
		about:         string,
	} {
		{pointer_pictures.RESOURCE_OF_THE_SYSTEM, release_test_pointer_theme(t, repository_license), true, "a theme under the license of the repository"},
		{pointer_pictures.RESOURCE_OF_THE_OWNER, transmute([]u8)owner_text, false, "the name of the theme of the owner"},
		{pointer_pictures.RESOURCE_OF_THE_SYSTEM, release_test_pointer_theme(t, "CC-BY-NC-4.0"), false, "a theme of others under the name of the theme of the system"},
		{"pointers_renamed", release_test_pointer_theme(t, "CC-BY-NC-4.0"), false, "a theme of others under a new name"},
	}
	for item in cases {
		files := make([]Image_File, RELEASE_TEST_MODULE_COUNT + 1, context.temp_allocator)
		files[0] = Image_File{name = ROOT_SERVICE_MODULE, file = transmute([]u8)root_text}
		files[1] = Image_File{name = "console", file = transmute([]u8)console_text}
		files[2] = Image_File{name = item.resource_name, file = item.file}
		build_image := boot_image_encode(files, RELEASE_TEST_MODULE_COUNT)
		release_test_volume_write(volume, SIGNED_BY_PUBLISHER_KEY_TEXT, files, kernel_text)
		problem := release_volume_problem(volume, .Publisher_Keys_Only, build_image, kernel_hash)
		testing.expectf(t, (problem == "") == item.accepted, "%s: accepted is %v, the problem is \"%s\"", item.about, item.accepted, problem)
		release_test_volume_write(volume, SIGNED_BY_TEST_KEY_TEXT, files, kernel_text)
		testing.expect_value(t, release_volume_problem(volume, .Test_Keys_Allowed, build_image, kernel_hash), "")
	}
}

@(test)
the_release_disk_is_a_gpt_disk_around_the_volume :: proc(t: ^testing.T) {
	volume_sectors :: 64
	volume := make([]u8, volume_sectors * DISK_SECTOR_SIZE, context.temp_allocator)
	for index in 0 ..< len(volume) {
		volume[index] = u8(index * 7 + 3)
	}
	disk, encoded := release_disk_encode(volume)
	testing.expect(t, encoded)
	testing.expect_value(t, len(disk), (2 * DISK_ALIGNMENT_SECTORS + volume_sectors) * DISK_SECTOR_SIZE)
	partition, problem := release_disk_partition(disk)
	testing.expect_value(t, problem, "")
	testing.expect(t, string(partition) == string(volume), "the partition is the volume, byte for byte")
	testing.expect_value(t, disk[MBR_PARTITION_TABLE_OFFSET + 4], u8(MBR_PROTECTIVE_TYPE))
	testing.expect_value(t, string(disk[GPT_HEADER_SECTOR * DISK_SECTOR_SIZE:][:len(GPT_SIGNATURE)]), GPT_SIGNATURE)
	disk_guid := disk[GPT_HEADER_SECTOR * DISK_SECTOR_SIZE + 56:][:16]
	testing.expect_value(t, disk_guid[7] >> 4, u8(4))
	testing.expect_value(t, disk_guid[8] >> 6, u8(2))
	again, _ := release_disk_encode(volume)
	testing.expect(t, string(again) == string(disk), "one volume gives one disk")

	// One changed byte of the primary header, of the entries and of the
	// backup header is found.
	changed_places := []int{GPT_HEADER_SECTOR * DISK_SECTOR_SIZE + 40, GPT_ENTRIES_SECTOR * DISK_SECTOR_SIZE + 33, len(disk) - DISK_SECTOR_SIZE + 40}
	for place in changed_places {
		changed := make([]u8, len(disk), context.temp_allocator)
		copy(changed, disk)
		changed[place] ~= 0x01
		_, changed_problem := release_disk_partition(changed)
		testing.expectf(t, changed_problem != "", "a changed byte at %d is found", place)
	}
	_, part_of_a_sector := release_disk_encode(volume[:DISK_SECTOR_SIZE + 1])
	testing.expect(t, !part_of_a_sector, "a volume is a whole count of sectors")
}

@(test)
the_files_of_a_release_verify_and_a_changed_file_is_refused :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "release_image_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	defer os.remove_all(folder)
	seed := test_seed()
	public_key, _ := public_key_of_seed(seed)
	files := release_files_of(folder, "0.1.0")
	image_text: string = "the compressed bytes of a disk"
	image := transmute([]u8)image_text
	list := release_checksum_list_text(release_image_file_name("0.1.0"), image)
	signature, _ := release_sign(seed, transmute([]u8)list)
	_ = os.write_entire_file(files.image_path, image)
	_ = os.write_entire_file(files.checksum_path, transmute([]u8)list)
	_ = os.write_entire_file(files.signature_path, transmute([]u8)strings.concatenate({signature, "\n"}, context.temp_allocator))

	digits, problem := release_files_verify(files.image_path, files.checksum_path, public_key)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, digits, list[:CHECKSUM_DIGIT_COUNT])

	other_seed: [RELEASE_KEY_SIZE]u8
	other_public_key, _ := public_key_of_seed(other_seed[:])
	_, other_key_problem := release_files_verify(files.image_path, files.checksum_path, other_public_key)
	testing.expect(t, other_key_problem != "", "another release signing key is refused")

	changed_image := make([]u8, len(image), context.temp_allocator)
	copy(changed_image, image)
	changed_image[len(changed_image) - 1] ~= 0x01
	_ = os.write_entire_file(files.image_path, changed_image)
	_, image_problem := release_files_verify(files.image_path, files.checksum_path, public_key)
	testing.expect(t, image_problem != "", "a changed byte of the image is refused")

	_ = os.write_entire_file(files.image_path, image)
	other_list := release_checksum_list_text(release_image_file_name("0.1.0"), changed_image)
	_ = os.write_entire_file(files.checksum_path, transmute([]u8)other_list)
	_, list_problem := release_files_verify(files.image_path, files.checksum_path, public_key)
	testing.expect(t, list_problem != "", "a checksum list that the key did not sign is refused")
}

@(test)
a_release_public_key_in_pem_is_the_key_information_of_rfc_8410 :: proc(t: ^testing.T) {
	public_key, _ := public_key_of_seed(test_seed())
	lines := strings.split(strings.trim_space(release_public_key_pem(public_key)), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	if len(lines) != 3 {
		return
	}
	testing.expect_value(t, lines[0], "-----BEGIN PUBLIC KEY-----")
	testing.expect_value(t, lines[2], "-----END PUBLIC KEY-----")
	information, decode_error := base64.decode(lines[1], allocator = context.temp_allocator)
	testing.expect(t, decode_error == nil)
	testing.expect_value(t, len(information), ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE + RELEASE_KEY_SIZE)
	if len(information) == ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE + RELEASE_KEY_SIZE {
		prefix := ED25519_PUBLIC_KEY_INFO_PREFIX
		testing.expect(t, string(information[:ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE]) == string(prefix[:]))
		testing.expect(t, string(information[ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE:]) == string(public_key[:]))
	}
	// The reader of a PEM block, which gives the DER form of the
	// certificate on the site, reads the same bytes back.
	body, body_read := pem_body_bytes(release_public_key_pem(public_key))
	testing.expect(t, body_read)
	testing.expect(t, string(body) == string(information), "the PEM block reads back as its bytes")
	_, no_end := pem_body_bytes("-----BEGIN PUBLIC KEY-----\nAAAA\n")
	testing.expect(t, !no_end, "a block with no end is refused")
}

@(test)
the_tag_of_a_release_is_its_number :: proc(t: ^testing.T) {
	testing.expect_value(t, release_tag_problem("v0.92.0", "0.92.0"), "")
	testing.expect(t, release_tag_problem("0.92.0", "0.92.0") != "", "a tag starts with v")
	testing.expect(t, release_tag_problem("v0.92.1", "0.92.0") != "", "a tag of another number is refused")
}

// `key write` writes the key folder of `key new` from the four variables
// of the secrets of a workflow, and refuses a value of another form.
@(test)
a_key_folder_is_written_from_the_secrets_of_a_workflow :: proc(t: ^testing.T) {
	folder, error := os.make_directory_temp("", "release_image_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	defer os.remove_all(folder)
	seed := test_seed()
	system_text := strings.repeat("ab", SIGNING_KEY_SIZE, context.temp_allocator)
	_ = os.set_env(SYSTEM_SIGNING_KEY_TEXT_VARIABLE, system_text)
	_ = os.set_env(FIRMWARE_SIGNING_KEY_TEXT_VARIABLE, "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n")
	_ = os.set_env(FIRMWARE_CERTIFICATE_TEXT_VARIABLE, "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
	_ = os.set_env(RELEASE_SIGNING_KEY_TEXT_VARIABLE, base64url_text(seed))
	defer {
		_ = os.unset_env(SYSTEM_SIGNING_KEY_TEXT_VARIABLE)
		_ = os.unset_env(FIRMWARE_SIGNING_KEY_TEXT_VARIABLE)
		_ = os.unset_env(FIRMWARE_CERTIFICATE_TEXT_VARIABLE)
		_ = os.unset_env(RELEASE_SIGNING_KEY_TEXT_VARIABLE)
	}
	key_folder := join(folder, "/keys")
	testing.expect(t, key_folder_write(key_folder), "the folder is written")
	system_seed, system_read := signing_key_file_read(join(key_folder, "/", SIGNING_KEY_FILE_NAME))
	testing.expect(t, system_read)
	testing.expect_value(t, system_seed[0], u8(0xAB))
	release_data, release_error := os.read_entire_file(join(key_folder, "/", RELEASE_SIGNING_KEY_FILE_NAME), context.temp_allocator)
	testing.expect_value(t, release_error, nil)
	release_seed, release_read := release_key_decode(string(release_data))
	testing.expect(t, release_read)
	testing.expect(t, string(release_seed[:]) == string(seed), "the release signing key is the value of its variable")
	for name in ([]string{SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX, FIRMWARE_SIGNING_KEY_FILE_NAME, FIRMWARE_CERTIFICATE_FILE_NAME, RELEASE_SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX}) {
		testing.expectf(t, os.exists(join(key_folder, "/", name)), "%s is in the key folder", name)
	}
	testing.expect(t, !key_folder_write(key_folder), "a key folder is never written over")

	// A write that fails part of the way removes what it wrote: here the
	// third file exists already, so the first two are written, then removed.
	partial_folder := join(folder, "/partial_keys")
	testing.expect_value(t, os.make_directory(partial_folder), nil)
	_ = os.write_entire_file(join(partial_folder, "/", FIRMWARE_SIGNING_KEY_FILE_NAME), "a file that was there\n")
	testing.expect(t, !key_folder_write(partial_folder), "a file that exists stops the write")
	testing.expect(t, !os.exists(join(partial_folder, "/", SIGNING_KEY_FILE_NAME)), "the files of a failed write are removed")
	testing.expect(t, !os.exists(join(partial_folder, "/", SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX)), "the files of a failed write are removed")
	testing.expect(t, os.exists(join(partial_folder, "/", FIRMWARE_SIGNING_KEY_FILE_NAME)), "a file that was there stays")

	_ = os.set_env(RELEASE_SIGNING_KEY_TEXT_VARIABLE, "AAAA")
	testing.expect(t, !key_folder_write(join(folder, "/other_keys")), "a release signing key of another form is refused")
}
