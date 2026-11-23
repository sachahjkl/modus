package build

import "core:encoding/base64"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/pointer_pictures"
import "modus:contract/release"
import "modus:contract/replacement_list"
import "modus:contract/system_description"
import crypto "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modus:cryptography/sha2"
import "modustool:foundation"
import "modustool:resources"

// The release image (src/md/infrastructure/release_image.md): the disk
// image that a release publishes, its checksum list, and the release
// signature of that list.
//
// The forms of the keys and of the signature are those of the package
// signing of gui_toolkit and of the .sig files of its package update: a
// key is 32 bytes in base64url with no padding, and a signature covers a
// context, then the bytes. The code is the Ed25519 code of the system,
// which the tool links already: the copy of the system is the code of
// core:crypto/ed25519 with only its package name and its imports changed,
// and a second Ed25519 in the tool would be a second code for one concept.

// The folder of the published files, and the folder of the disk before
// its compression.
RELEASE_OUTPUT_FOLDER :: "dist"
RELEASE_DISK_FOLDER :: foundation.BUILD_FOLDER + "/release"
// The section of the release in CHANGELOG.md, for the notes of the
// published release.
RELEASE_NOTES_FILE :: foundation.BUILD_FOLDER + "/release_notes.md"
RELEASE_CHECKSUM_FILE_NAME :: "SHA256SUMS.txt"
RELEASE_SIGNATURE_SUFFIX :: ".sig"
RELEASE_IMAGE_ARCHITECTURE :: "x86_64"
RELEASE_COMPRESSED_SUFFIX :: ".zst"
// The level of zstd: the file is compressed once and downloaded many
// times.
RELEASE_COMPRESSION_LEVEL :: "-19"
// What the release signature covers before the checksum list: a signature
// that the release signing key makes for another use is never a release
// signature.
RELEASE_SIGNATURE_CONTEXT :: "modus release checksums 1\n"
// The private key of the release signing key, in the key folder, beside
// the signing key: its 32-byte seed in base64url with no padding.
RELEASE_SIGNING_KEY_FILE_NAME :: "release_signing_key"
// The public key that a reader verifies a release with. The release
// command refuses a release signing key with another public key.
RELEASE_PUBLIC_KEY_FILE :: foundation.RESOURCE_FOLDER + "/keys/" + RELEASE_SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX
RELEASE_KEY_SIZE :: ed25519.PUBLIC_KEY_SIZE // A seed has the same size.
// The certificate of the firmware signing key of the publisher, which a
// principal enrols in the firmware for Secure Boot. The release command
// refuses a key folder with another certificate.
RELEASE_FIRMWARE_CERTIFICATE_FILE :: foundation.RESOURCE_FOLDER + "/keys/" + FIRMWARE_CERTIFICATE_FILE_NAME
// The release volume: the main boot image with its boot program signed
// for Secure Boot. Only `release image` builds it.
BOOT_VOLUME_RELEASE :: foundation.BUILD_FOLDER + "/boot_volume_release.img"
// The module that the kernel starts first, under this name in each boot
// image.
ROOT_SERVICE_MODULE :: "root"

// The four variables of `key write`: the values of the key folder, as the
// secrets of a workflow hold them. SYSTEM_SIGNING_KEY already names a
// path, so these names end with _TEXT.
SYSTEM_SIGNING_KEY_TEXT_VARIABLE :: "SYSTEM_SIGNING_KEY_TEXT"
FIRMWARE_SIGNING_KEY_TEXT_VARIABLE :: "FIRMWARE_SIGNING_KEY_TEXT"
FIRMWARE_CERTIFICATE_TEXT_VARIABLE :: "FIRMWARE_CERTIFICATE_TEXT"
RELEASE_SIGNING_KEY_TEXT_VARIABLE :: "RELEASE_SIGNING_KEY_TEXT"
KEY_TEXT_VARIABLE_COUNT :: 4
PEM_START :: "-----BEGIN "

// A line of the checksum list: 64 hexadecimal digits, two spaces, a name.
CHECKSUM_DIGIT_COUNT :: 64
CHECKSUM_SEPARATOR :: "  "

// The GPT disk around the release volume.
DISK_SECTOR_SIZE :: 512
// The partition starts at 1 MiB, and 1 MiB follows it: the alignment that
// the tools of other systems give, with room for the backup entries.
DISK_ALIGNMENT_SECTORS :: 2048
GPT_HEADER_SECTOR :: 1
GPT_ENTRIES_SECTOR :: 2
GPT_ENTRY_COUNT :: 128
GPT_ENTRY_SIZE :: 128
GPT_ENTRY_SECTORS :: GPT_ENTRY_COUNT * GPT_ENTRY_SIZE / DISK_SECTOR_SIZE
GPT_HEADER_SIZE :: 92
GPT_SIGNATURE :: "EFI PART"
GPT_REVISION :: 0x0001_0000
GPT_PARTITION_NAME :: "modus"
// The offset of the name in a partition entry: UTF-16, little-endian.
GPT_ENTRY_NAME_OFFSET :: 56
// C12A7328-F81F-11D2-BA4B-00A0C93EC93B, the EFI system partition, as a
// GPT stores it: the first three fields little-endian.
GPT_EFI_SYSTEM_PARTITION_TYPE :: [16]u8{0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B}
MBR_PARTITION_TABLE_OFFSET :: 446
MBR_PROTECTIVE_TYPE :: 0xEE
MBR_SIGNATURE_OFFSET :: 510

// The DER prefix of an Ed25519 public key in a SubjectPublicKeyInfo
// (RFC 8410): the 32 bytes of the key follow it. OpenSSL reads a public key
// in that form.
ED25519_PUBLIC_KEY_INFO_PREFIX :: [12]u8{0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00}
ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE :: 12

// Which volumes a packaging accepts. The release command gives
// Publisher_Keys_Only; only the machine test gives Test_Keys_Allowed, and
// no argument of a command selects it.
Release_Packaging :: enum {
	Publisher_Keys_Only,
	Test_Keys_Allowed,
}

// The three files of a release.
Release_Files :: struct {
	image_path:     string,
	checksum_path:  string,
	signature_path: string,
}

// One line of a checksum list.
Release_Checksum :: struct {
	digits:    string,
	file_name: string,
}

// release_image_file_name gives the name of the compressed image of a
// release: modus-0.92.0-x86_64.img.zst.
release_image_file_name :: proc(release_number: string) -> string {
	return fmt.tprintf("modus-%s-%s.img%s", release_number, RELEASE_IMAGE_ARCHITECTURE, RELEASE_COMPRESSED_SUFFIX)
}

release_files_of :: proc(folder, release_number: string) -> Release_Files {
	checksum_path := foundation.join(folder, "/", RELEASE_CHECKSUM_FILE_NAME)
	return {image_path = foundation.join(folder, "/", release_image_file_name(release_number)), checksum_path = checksum_path, signature_path = foundation.join(checksum_path, RELEASE_SIGNATURE_SUFFIX)}
}

// release_boot_volume gives the release volume: the main boot image with
// no test module (release_boot_image_of), the kernel of the tests, the boot
// program signed with the firmware signing key.
release_boot_volume :: proc() -> Boot_Volume {
	return Boot_Volume{path = BOOT_VOLUME_RELEASE, image = BOOT_IMAGE_RELEASE, kernel = "kernel", firmware_signature = .Signed}
}

// base64url_text gives bytes in base64url with no padding: the form of a
// key and of a signature of the package signing of gui_toolkit.
base64url_text :: proc(bytes: []u8) -> string {
	return base64.encode(bytes, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
}

// base64url_bytes reads base64url with no padding, strictly: one text has
// one value. White space around it is no part of it.
base64url_bytes :: proc(text: string) -> (bytes: []u8, ok: bool) {
	decoded, decode_error := base64.decode(strings.trim_space(text), base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.Strict, .No_Padding})
	if decode_error != nil {
		return nil, false
	}
	return decoded, true
}

// release_key_decode reads a key text: a public key, or the seed of a
// private key.
release_key_decode :: proc(text: string) -> (key: [RELEASE_KEY_SIZE]u8, ok: bool) {
	decoded := base64url_bytes(text) or_return
	defer crypto.zero_explicit(raw_data(decoded), len(decoded))
	if len(decoded) != RELEASE_KEY_SIZE {
		return
	}
	copy(key[:], decoded)
	return key, true
}

// public_key_of_seed gives the Ed25519 public key of a 32-byte seed.
public_key_of_seed :: proc(seed: []u8) -> (public_key: [RELEASE_KEY_SIZE]u8, ok: bool) {
	private_key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&private_key, seed) {
		return
	}
	defer ed25519.private_key_clear(&private_key)
	ed25519.private_key_public_bytes(&private_key, public_key[:])
	return public_key, true
}

// release_signed_bytes gives what the release signature covers: the
// context, then the checksum list.
release_signed_bytes :: proc(checksum_list: []u8) -> []u8 {
	bytes := make([]u8, len(RELEASE_SIGNATURE_CONTEXT) + len(checksum_list), context.temp_allocator)
	copy(bytes, RELEASE_SIGNATURE_CONTEXT)
	copy(bytes[len(RELEASE_SIGNATURE_CONTEXT):], checksum_list)
	return bytes
}

// release_sign gives the release signature of a checksum list, in
// base64url with no padding.
release_sign :: proc(seed: []u8, checksum_list: []u8) -> (signature_text: string, ok: bool) {
	private_key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&private_key, seed) {
		return
	}
	defer ed25519.private_key_clear(&private_key)
	signature: [ed25519.SIGNATURE_SIZE]u8
	ed25519.sign(&private_key, release_signed_bytes(checksum_list), signature[:])
	return base64url_text(signature[:]), true
}

// release_signature_verifies says whether a release signature of a
// checksum list verifies with a public key.
release_signature_verifies :: proc(public_key: [RELEASE_KEY_SIZE]u8, checksum_list: []u8, signature_text: string) -> bool {
	signature, decoded := base64url_bytes(signature_text)
	if !decoded || len(signature) != ed25519.SIGNATURE_SIZE {
		return false
	}
	key := public_key
	verifier: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&verifier, key[:]) {
		return false
	}
	return ed25519.verify(&verifier, release_signed_bytes(checksum_list), signature)
}

// release_public_key_pem gives a public key in PEM, for OpenSSL.
release_public_key_pem :: proc(public_key: [RELEASE_KEY_SIZE]u8) -> string {
	prefix := ED25519_PUBLIC_KEY_INFO_PREFIX
	key := public_key
	der: [ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE + RELEASE_KEY_SIZE]u8
	copy(der[:], prefix[:])
	copy(der[ED25519_PUBLIC_KEY_INFO_PREFIX_SIZE:], key[:])
	body := base64.encode(der[:], allocator = context.temp_allocator)
	return strings.concatenate({"-----BEGIN PUBLIC KEY-----\n", body, "\n-----END PUBLIC KEY-----\n"}, context.temp_allocator)
}

// pem_body_bytes gives the bytes of the first block of a PEM text: the
// base64 lines between its line "-----BEGIN" and its line "-----END".
pem_body_bytes :: proc(text: string) -> (bytes: []u8, ok: bool) {
	body := strings.builder_make(context.temp_allocator)
	inside := false
	for raw_line in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw_line)
		if strings.has_prefix(line, PEM_START) {
			inside = true
			continue
		}
		if strings.has_prefix(line, "-----END ") {
			if !inside {
				return nil, false
			}
			decoded, decode_error := base64.decode(strings.to_string(body), allocator = context.temp_allocator)
			if decode_error != nil || len(decoded) == 0 {
				return nil, false
			}
			return decoded, true
		}
		if inside {
			strings.write_string(&body, line)
		}
	}
	return nil, false
}

// release_sha256 gives the SHA-256 hash of bytes, with the copy of the
// system (the reason is at the top of this file).
release_sha256 :: proc(data: []u8) -> (digest: [32]u8) {
	hash_state: sha2.Context_256
	sha2.init_256(&hash_state)
	sha2.update(&hash_state, data)
	sha2.final(&hash_state, digest[:])
	return
}

// release_checksum_list_text gives the checksum list of one file, in the
// form of sha256sum: the digits, two spaces, the name, an end of line.
release_checksum_list_text :: proc(file_name: string, file_bytes: []u8) -> string {
	digits := system_description.hexadecimal(release_sha256(file_bytes))
	return strings.concatenate({string(digits[:]), CHECKSUM_SEPARATOR, file_name, "\n"}, context.temp_allocator)
}

// release_checksum_list_parse reads a checksum list. Each line is 64
// lowercase hexadecimal digits, two spaces and a file name with no folder;
// the list ends with an end of line, and names each file once.
release_checksum_list_parse :: proc(text: string) -> (rows: []Release_Checksum, problem: string) {
	if !strings.has_suffix(text, "\n") {
		return nil, "the checksum list does not end with an end of line"
	}
	parsed := make([dynamic]Release_Checksum, context.temp_allocator)
	for line, index in strings.split(text[:len(text) - 1], "\n", context.temp_allocator) {
		if len(line) <= CHECKSUM_DIGIT_COUNT + len(CHECKSUM_SEPARATOR) || line[CHECKSUM_DIGIT_COUNT:][:len(CHECKSUM_SEPARATOR)] != CHECKSUM_SEPARATOR {
			return nil, fmt.tprintf("line %d of the checksum list is not 64 digits, two spaces and a name", index + 1)
		}
		digits := line[:CHECKSUM_DIGIT_COUNT]
		for position in 0 ..< len(digits) {
			switch digits[position] {
			case '0' ..= '9', 'a' ..= 'f':
			case:
				return nil, fmt.tprintf("line %d of the checksum list has a character that is not a lowercase hexadecimal digit", index + 1)
			}
		}
		name := line[CHECKSUM_DIGIT_COUNT + len(CHECKSUM_SEPARATOR):]
		if strings.contains_any(name, "/\\") || name == "." || name == ".." || strings.has_prefix(name, "*") {
			return nil, fmt.tprintf("line %d of the checksum list names %q, which is not a file name with no folder", index + 1, name)
		}
		for row in parsed {
			if row.file_name == name {
				return nil, fmt.tprintf("the checksum list names %s twice", name)
			}
		}
		append(&parsed, Release_Checksum{digits = digits, file_name = name})
	}
	return parsed[:], ""
}

// The resources that the build of a volume adds after the files of the
// boot image of the build, in this order.
RELEASE_VOLUME_RESOURCES :: [3]string{replacement_list.RESOURCE_NAME, system_description.RESOURCE_DESCRIPTION, system_description.RESOURCE_SIGNATURE}

// release_test_module_problem names the first module of a boot image that
// a release does not ship (module_included_in_release_image): a module of
// the group tests, and a module that only the image of a test holds, such
// as operation_fuzzing, which holds the machine with the right Physical;
// "" when the image holds none. An image that is not a boot image is
// refused too.
release_test_module_problem :: proc(image: []u8, image_name: string) -> string {
	modules, _, valid := info.image_tables(image)
	if !valid {
		return fmt.tprintf("%s is not a boot image", image_name)
	}
	for &entry in modules {
		name := system_description.name_of(&entry.name)
		if row, found := module_row_of_name(name); found && !module_included_in_release_image(row) {
			return fmt.tprintf("%s holds the module %s, a module of a test: a release never publishes it", image_name, name)
		}
	}
	return ""
}

// release_only_in_image_problem names the first module of a boot image that
// only the one image of a test holds (a row with only_in_image), such as
// operation_fuzzing, which holds the machine with the right Physical; ""
// when the image holds none. An image that is not a boot image is refused.
release_only_in_image_problem :: proc(image: []u8, image_name: string) -> string {
	modules, _, valid := info.image_tables(image)
	if !valid {
		return fmt.tprintf("%s is not a boot image", image_name)
	}
	for &entry in modules {
		name := system_description.name_of(&entry.name)
		if row, found := module_row_of_name(name); found && row.only_in_image != "" {
			return fmt.tprintf("%s holds the module %s, which only the boot image of a test holds", image_name, name)
		}
	}
	return ""
}

// The start of the boot line of each test kernel: the counted kernel, the
// kernel with the check of the return skipped. The kernel that ships holds
// no such text, because each such line is under a setting that is false
// there (src/md/infrastructure/kernel_fuzzing.md, "The test kernel").
TEST_KERNEL_TEXT :: "kernel: TEST BUILD:"

// release_test_kernel_problem says why the bytes of a kernel module are the
// bytes of a test kernel, or gives "": they hold TEST_KERNEL_TEXT. A test
// kernel built under the name kernel has the hash that the description
// names, and is still refused.
release_test_kernel_problem :: proc(kernel_module: []u8) -> string {
	if strings.contains(string(kernel_module), TEST_KERNEL_TEXT) {
		return fmt.tprintf("the kernel module of the build holds the text \"%s\": it is a kernel of a test, such as the counted kernel, and a release never publishes it", TEST_KERNEL_TEXT)
	}
	return ""
}

// kernel_test_text_problem says why the bytes of a kernel module of the
// table break the rule of the text of the test kernels, or gives "": the
// module kernel holds no TEST_KERNEL_TEXT, and each other kernel holds it.
// The release refuses a kernel by this text, so each build proves the text
// on the real kernels, not only in a release.
kernel_test_text_problem :: proc(name: string, kernel_module: []u8) -> string {
	holds := strings.contains(string(kernel_module), TEST_KERNEL_TEXT)
	if name == system_description.KERNEL_ENTRY_NAME && holds {
		return fmt.tprintf("the kernel module %s holds the text \"%s\": a line of a test kernel is outside its setting, and the release would refuse the kernel that ships", name, TEST_KERNEL_TEXT)
	}
	if name != system_description.KERNEL_ENTRY_NAME && !holds {
		return fmt.tprintf("the kernel module %s, a kernel of a test, holds no text \"%s\": the release would not refuse it by its bytes", name, TEST_KERNEL_TEXT)
	}
	return ""
}

// kernel_test_texts_check reads the module of each kernel of the table
// after the build, and checks the text of the test kernels.
kernel_test_texts_check :: proc() -> bool {
	for row in foundation.module_builds {
		if !row.kernel {
			continue
		}
		module_bytes := foundation.read_file(foundation.module_path(row.name)) or_return
		if problem := kernel_test_text_problem(row.name, module_bytes); problem != "" {
			fmt.eprintfln("modustool: %s", problem)
			return false
		}
	}
	return true
}

// release_volume_problem says why a boot volume must not be packaged, or
// gives "". tested_image is the boot image of the build (build/boot.image),
// which the machine tests boot, with its test modules; kernel_module is the
// bytes of its kernel module, which must not be a test kernel
// (release_test_kernel_problem). tested_image must hold no module of the one
// image of a test (release_only_in_image_problem). The boot image of the
// volume must hold no test module, and each module and resource of the
// release image made again from tested_image (release_boot_image_of), with
// the same name and the same bytes, in the same order, then only the three
// resources that the build of a volume adds; its signed system description must name the
// BLAKE3 hash of kernel_module for the kernel. So the boot image of the test
// of the seal (another root service under the name root), the boot image of
// a measure run (one resource more), a module that a test changed, a
// changed kernel and the kernel of a test are refused. The check reads the
// signed boot image beside the volume, which the same build of the volume
// wrote: the boot image inside the volume is in the boot program, and the
// tool has no reader of a boot program.
release_volume_problem :: proc(volume_path: string, packaging: Release_Packaging, tested_image: []u8, kernel_module: []u8) -> string {
	if problem := release_test_kernel_problem(kernel_module); problem != "" {
		return problem
	}
	// The image that the tests booted holds the test modules, and never a
	// module of the one image of a test: the derivation below would drop
	// such a module in silence.
	if problem := release_only_in_image_problem(tested_image, "the boot image of the build"); problem != "" {
		return problem
	}
	build_image, derive_problem := release_boot_image_of(tested_image)
	if derive_problem != "" {
		return derive_problem
	}
	kernel_hash := blake3.hash(kernel_module)
	signed_by, signed_by_error := os.read_entire_file(signed_by_file_path(volume_path), context.temp_allocator)
	if signed_by_error != nil {
		return fmt.tprintf("%s has no file %s that says which key signed it", volume_path, signed_by_file_path(volume_path))
	}
	switch string(signed_by) {
	case SIGNED_BY_PUBLISHER_KEY_TEXT:
	case SIGNED_BY_TEST_KEY_TEXT:
		if packaging == .Publisher_Keys_Only {
			return fmt.tprintf("%s was signed by the test signing key, whose private key is published: a release never publishes it", volume_path)
		}
	case:
		return fmt.tprintf("%s says neither the key of the publisher nor the test signing key", signed_by_file_path(volume_path))
	}
	image, image_error := os.read_entire_file(signed_image_path(volume_path), context.temp_allocator)
	if image_error != nil {
		return fmt.tprintf("cannot read %s, the boot image of %s", signed_image_path(volume_path), volume_path)
	}
	image_path := signed_image_path(volume_path)
	modules, image_resources, valid := info.image_tables(image)
	build_modules_table, build_resources, build_valid := info.image_tables(build_image)
	if !valid || !build_valid {
		return fmt.tprintf("%s or the boot image of the build is not a boot image", image_path)
	}
	// A test module in the volume is refused by the group of its row: the
	// comparison below alone would pass it if the derivation kept it.
	if problem := release_test_module_problem(image, image_path); problem != "" {
		return problem
	}
	added := RELEASE_VOLUME_RESOURCES
	if len(modules) != len(build_modules_table) || len(image_resources) != len(build_resources) + len(added) {
		return fmt.tprintf("%s does not hold the modules and the resources of the boot image of the build: a boot image of a test, such as a measure run, is never published", image_path)
	}
	for index in 0 ..< len(modules) + len(build_resources) {
		entry := index < len(modules) ? &modules[index] : &image_resources[index - len(modules)]
		build_entry := index < len(modules) ? &build_modules_table[index] : &build_resources[index - len(modules)]
		name := system_description.name_of(&entry.name)
		bytes, inside := info.image_entry_bytes(image, entry)
		build_bytes, build_inside := info.image_entry_bytes(build_image, build_entry)
		if !inside || !build_inside {
			return fmt.tprintf("the entry %s of %s or of the boot image of the build points outside it", name, image_path)
		}
		if name != system_description.name_of(&build_entry.name) || blake3.hash(bytes) != blake3.hash(build_bytes) {
			return fmt.tprintf("the entry %s of %s is not the entry of the boot image of the build at its place: a boot image of a test, such as one with a changed module, is never published", name, image_path)
		}
	}
	for name, index in added {
		if system_description.name_of(&image_resources[len(build_resources) + index].name) != name {
			return fmt.tprintf("%s does not end with the resource %s", image_path, name)
		}
	}
	description, _, found := system_description.trust_resources(image)
	description_entries, description_valid := system_description.entries(description)
	if !found || !description_valid || len(description_entries) == 0 || description_entries[0].hash != kernel_hash {
		return fmt.tprintf("the system description of %s does not name the kernel module of the build", image_path)
	}
	// A volume of a test of the TPM floors has a raised security version:
	// once started, it would refuse each release of the repository.
	if security_version, _ := system_description.security_version_of(description); security_version != system_description.SECURITY_VERSION {
		return fmt.tprintf("the system description of %s has the security version %d, and the repository %d", image_path, security_version, system_description.SECURITY_VERSION)
	}
	// Only a published volume: the machine test packages a volume of a
	// development build, which may hold the theme of the owner.
	if packaging == .Publisher_Keys_Only {
		repository_license, license_found := repository_license_read()
		if !license_found {
			return fmt.tprintf("cannot read the license of the repository in %s", resources.REPOSITORY_LICENSE_FILE)
		}
		if problem := release_pointer_theme_problem(image_path, image, image_resources, repository_license); problem != "" {
			return problem
		}
	}
	return ""
}

// repository_license_read gives the SPDX identifier of the license of the
// repository, from the first line of LICENSE, as the reuse list reads it.
repository_license_read :: proc() -> (license: string, ok: bool) {
	text, read_error := os.read_entire_file(resources.REPOSITORY_LICENSE_FILE, context.temp_allocator)
	if read_error != nil {
		return "", false
	}
	lines := foundation.lines_of_text(string(text))
	if len(lines) == 0 {
		return "", false
	}
	license = reuse_spdx_of_record_words(strings.trim_space(lines[0]))
	return license, license != ""
}

// release_pointer_theme_problem says why a boot image holds a pointer theme
// that a release must not publish, or gives "". The license of the theme of
// the owner allows no public download. Its resource is refused by its name,
// and each pointer theme file under any name by the license in its header:
// a release holds only a theme under the license of the repository.
release_pointer_theme_problem :: proc(image_path: string, image: []u8, resources: []info.Image_Entry, repository_license: string) -> string {
	for &entry in resources {
		name := system_description.name_of(&entry.name)
		if name == pointer_pictures.RESOURCE_OF_THE_OWNER {
			return fmt.tprintf("%s holds the resource %s, the pointer theme of the owner: a release image holds the pointer theme of the system only", image_path, name)
		}
		bytes, inside := info.image_entry_bytes(image, &entry)
		if !inside {
			return fmt.tprintf("the entry %s of %s points outside it", name, image_path)
		}
		if len(bytes) < size_of(u64) {
			continue
		}
		magic: u64
		for index in 0 ..< size_of(u64) {
			magic |= u64(bytes[index]) << uint(8 * index)
		}
		if magic != pointer_pictures.MAGIC {
			continue
		}
		// A copy: validate reads the file in place, and wants the alignment
		// of an allocation, which an entry inside a test image may lack.
		theme := make([]u8, len(bytes), context.temp_allocator)
		copy(theme, bytes)
		if found := pointer_pictures.validate(theme); found.kind != .None {
			return fmt.tprintf("the resource %s of %s starts as a pointer theme file and is not a valid one (%v)", name, image_path, found.kind)
		}
		license := pointer_pictures.text_of(pointer_pictures.header(theme).license[:])
		if license != repository_license {
			return fmt.tprintf("the resource %s of %s is the pointer theme \"%s\" under the license %s, not %s, the license of the repository: a release image holds the pointer theme of the system only", name, image_path, pointer_pictures.text_of(pointer_pictures.header(theme).theme_name[:]), license, repository_license)
		}
	}
	return ""
}

@(private = "file")
disk_put :: proc(bytes: []u8, offset: int, value: u64, size: int) {
	for index in 0 ..< size {
		bytes[offset + index] = u8(value >> uint(8 * index))
	}
}

@(private = "file")
disk_get :: proc(bytes: []u8, offset: int, size: int) -> (value: u64) {
	for index in 0 ..< size {
		value |= u64(bytes[offset + index]) << uint(8 * index)
	}
	return
}

// guid_version_set gives a GUID the bits of a GUID of version 4: its third
// field is little-endian, so the version is the high half of byte 7; the
// variant is the two high bits of byte 8.
@(private = "file")
guid_version_set :: proc(guid: ^[16]u8) {
	guid[7] = (guid[7] & 0x0F) | 0x40
	guid[8] = (guid[8] & 0x3F) | 0x80
}

// gpt_header_write writes one GPT header at a sector, with its check.
@(private = "file")
gpt_header_write :: proc(disk: []u8, sector, other_sector, entries_sector, first_usable, last_usable: u64, disk_guid: [16]u8, entries_check: u32) {
	header := disk[int(sector) * DISK_SECTOR_SIZE:][:GPT_HEADER_SIZE]
	copy(header[:len(GPT_SIGNATURE)], GPT_SIGNATURE)
	disk_put(header, 8, GPT_REVISION, 4)
	disk_put(header, 12, GPT_HEADER_SIZE, 4)
	disk_put(header, 24, sector, 8)
	disk_put(header, 32, other_sector, 8)
	disk_put(header, 40, first_usable, 8)
	disk_put(header, 48, last_usable, 8)
	guid := disk_guid
	copy(header[56:72], guid[:])
	disk_put(header, 72, entries_sector, 8)
	disk_put(header, 80, GPT_ENTRY_COUNT, 4)
	disk_put(header, 84, GPT_ENTRY_SIZE, 4)
	disk_put(header, 88, u64(entries_check), 4)
	// The check covers the header with its own field at zero.
	disk_put(header, 16, u64(hash.crc32(header)), 4)
}

// release_disk_encode gives a GPT disk whose one partition, the EFI system
// partition, is the volume. The GUIDs come from the hash of the volume, so
// one volume gives one disk.
release_disk_encode :: proc(volume: []u8) -> (disk: []u8, ok: bool) {
	if len(volume) == 0 || len(volume) % DISK_SECTOR_SIZE != 0 {
		return nil, false
	}
	volume_sectors := u64(len(volume) / DISK_SECTOR_SIZE)
	first_partition_sector := u64(DISK_ALIGNMENT_SECTORS)
	last_partition_sector := first_partition_sector + volume_sectors - 1
	sector_count := first_partition_sector + volume_sectors + DISK_ALIGNMENT_SECTORS
	last_sector := sector_count - 1
	disk = make([]u8, int(sector_count) * DISK_SECTOR_SIZE, context.temp_allocator)

	// The protective MBR: a reader that knows no GPT sees one partition of
	// an unknown type over the disk, and writes nothing to it.
	mbr_entry := MBR_PARTITION_TABLE_OFFSET
	disk[mbr_entry + 2] = 0x02 // The start in cylinders, heads and sectors: sector 2, the sector 1 of the disk.
	disk[mbr_entry + 4] = MBR_PROTECTIVE_TYPE
	disk[mbr_entry + 5] = 0xFF
	disk[mbr_entry + 6] = 0xFF
	disk[mbr_entry + 7] = 0xFF
	disk_put(disk, mbr_entry + 8, GPT_HEADER_SECTOR, 4)
	disk_put(disk, mbr_entry + 12, min(last_sector, 0xFFFF_FFFF), 4)
	disk[MBR_SIGNATURE_OFFSET] = 0x55
	disk[MBR_SIGNATURE_OFFSET + 1] = 0xAA

	identity := blake3.hash(volume)
	disk_guid, partition_guid: [16]u8
	copy(disk_guid[:], identity[:16])
	copy(partition_guid[:], identity[16:])
	guid_version_set(&disk_guid)
	guid_version_set(&partition_guid)

	entries := make([]u8, GPT_ENTRY_COUNT * GPT_ENTRY_SIZE, context.temp_allocator)
	partition_type := GPT_EFI_SYSTEM_PARTITION_TYPE
	copy(entries[0:16], partition_type[:])
	copy(entries[16:32], partition_guid[:])
	disk_put(entries, 32, first_partition_sector, 8)
	disk_put(entries, 40, last_partition_sector, 8)
	name: string = GPT_PARTITION_NAME
	for index in 0 ..< len(name) {
		entries[GPT_ENTRY_NAME_OFFSET + 2 * index] = name[index]
	}
	entries_check := hash.crc32(entries)
	backup_entries_sector := last_sector - GPT_ENTRY_SECTORS
	copy(disk[GPT_ENTRIES_SECTOR * DISK_SECTOR_SIZE:], entries)
	copy(disk[int(backup_entries_sector) * DISK_SECTOR_SIZE:], entries)
	copy(disk[int(first_partition_sector) * DISK_SECTOR_SIZE:], volume)
	first_usable := u64(GPT_ENTRIES_SECTOR + GPT_ENTRY_SECTORS)
	last_usable := backup_entries_sector - 1
	gpt_header_write(disk, GPT_HEADER_SECTOR, last_sector, GPT_ENTRIES_SECTOR, first_usable, last_usable, disk_guid, entries_check)
	gpt_header_write(disk, last_sector, GPT_HEADER_SECTOR, backup_entries_sector, first_usable, last_usable, disk_guid, entries_check)
	return disk, true
}

// gpt_header_read checks the GPT header at a sector and its entries, and
// gives the entries.
@(private = "file")
gpt_header_read :: proc(disk: []u8, sector, other_sector: u64) -> (entries: []u8, problem: string) {
	header := make([]u8, GPT_HEADER_SIZE, context.temp_allocator)
	copy(header, disk[int(sector) * DISK_SECTOR_SIZE:])
	if string(header[:len(GPT_SIGNATURE)]) != GPT_SIGNATURE || disk_get(header, 12, 4) != GPT_HEADER_SIZE {
		return nil, fmt.tprintf("sector %d is not a GPT header", sector)
	}
	if disk_get(header, 24, 8) != sector || disk_get(header, 32, 8) != other_sector {
		return nil, fmt.tprintf("the GPT header of sector %d does not name its own sector and the sector of the other header", sector)
	}
	stated_check := u32(disk_get(header, 16, 4))
	disk_put(header, 16, 0, 4)
	if hash.crc32(header) != stated_check {
		return nil, fmt.tprintf("the GPT header of sector %d has a wrong check", sector)
	}
	if disk_get(header, 80, 4) != GPT_ENTRY_COUNT || disk_get(header, 84, 4) != GPT_ENTRY_SIZE {
		return nil, fmt.tprintf("the GPT header of sector %d states another table of entries", sector)
	}
	entries_sector := disk_get(header, 72, 8)
	if entries_sector < GPT_ENTRIES_SECTOR || entries_sector >= u64(len(disk) / DISK_SECTOR_SIZE) {
		return nil, fmt.tprintf("the entries of the GPT header of sector %d are outside the disk", sector)
	}
	entries_end := entries_sector * DISK_SECTOR_SIZE + GPT_ENTRY_COUNT * GPT_ENTRY_SIZE
	if entries_end > u64(len(disk)) {
		return nil, fmt.tprintf("the entries of the GPT header of sector %d are outside the disk", sector)
	}
	entries = disk[int(entries_sector) * DISK_SECTOR_SIZE:int(entries_end)]
	if hash.crc32(entries) != u32(disk_get(header, 88, 4)) {
		return nil, fmt.tprintf("the entries of the GPT header of sector %d have a wrong check", sector)
	}
	return entries, ""
}

// release_disk_partition reads a disk that release_disk_encode wrote: the
// protective MBR, the two headers and their entries, and the one EFI
// system partition, whose bytes it gives. The release command reads the
// disk back before it writes it.
release_disk_partition :: proc(disk: []u8) -> (partition: []u8, problem: string) {
	if len(disk) % DISK_SECTOR_SIZE != 0 || len(disk) < (2 * DISK_ALIGNMENT_SECTORS + 1) * DISK_SECTOR_SIZE {
		return nil, "the disk is not a whole count of sectors, or is smaller than its two alignments"
	}
	last_sector := u64(len(disk) / DISK_SECTOR_SIZE) - 1
	if disk[MBR_SIGNATURE_OFFSET] != 0x55 || disk[MBR_SIGNATURE_OFFSET + 1] != 0xAA || disk[MBR_PARTITION_TABLE_OFFSET + 4] != MBR_PROTECTIVE_TYPE {
		return nil, "sector 0 is not a protective MBR"
	}
	entries, primary_problem := gpt_header_read(disk, GPT_HEADER_SECTOR, last_sector)
	if primary_problem != "" {
		return nil, primary_problem
	}
	backup_entries, backup_problem := gpt_header_read(disk, last_sector, GPT_HEADER_SECTOR)
	if backup_problem != "" {
		return nil, backup_problem
	}
	if string(entries) != string(backup_entries) {
		return nil, "the two tables of entries differ"
	}
	partition_type := GPT_EFI_SYSTEM_PARTITION_TYPE
	if string(entries[0:16]) != string(partition_type[:]) {
		return nil, "the first partition is not an EFI system partition"
	}
	for value in entries[GPT_ENTRY_SIZE:] {
		if value != 0 {
			return nil, "the disk has more than one partition"
		}
	}
	header := disk[GPT_HEADER_SECTOR * DISK_SECTOR_SIZE:]
	first_usable, last_usable := disk_get(header, 40, 8), disk_get(header, 48, 8)
	first, last := disk_get(entries, 32, 8), disk_get(entries, 40, 8)
	if last_usable >= last_sector || first < first_usable || last > last_usable || last < first {
		return nil, "the partition is outside the usable sectors"
	}
	return disk[int(first) * DISK_SECTOR_SIZE:int(last + 1) * DISK_SECTOR_SIZE], ""
}

// release_files_write packages one boot volume as the three files of a
// release in output_folder: the GPT disk around the volume, compressed,
// the checksum list, and its release signature with the seed. The disk
// before its compression stays in disk_folder.
release_files_write :: proc(volume_path, release_number, disk_folder, output_folder: string, release_seed: []u8, packaging: Release_Packaging) -> (files: Release_Files, ok: bool) {
	// The volume is compared with the release image made again from the
	// boot image that the tests booted: no other image can pass.
	tested_image := foundation.read_file(BOOT_IMAGE) or_return
	kernel_module := foundation.read_file(foundation.module_path(system_description.KERNEL_ENTRY_NAME)) or_return
	if problem := release_volume_problem(volume_path, packaging, tested_image, kernel_module); problem != "" {
		fmt.eprintfln("modustool: release: %s", problem)
		return
	}
	volume := foundation.read_file(volume_path) or_return
	disk, encoded := release_disk_encode(volume)
	if !encoded {
		fmt.eprintfln("modustool: release: %s is not a whole count of sectors of %d bytes", volume_path, DISK_SECTOR_SIZE)
		return
	}
	partition, disk_problem := release_disk_partition(disk)
	if disk_problem != "" || string(partition) != string(volume) {
		fmt.eprintfln("modustool: release: the disk of %s does not read back as the volume: %s", volume_path, disk_problem)
		return
	}
	foundation.make_folder(disk_folder) or_return
	// The folder is emptied: the workflow publishes each file of it, and a
	// file of an older release must not go with this one.
	foundation.reset_folder(output_folder) or_return
	image_name := release_image_file_name(release_number)
	disk_path := foundation.join(disk_folder, "/", strings.trim_suffix(image_name, RELEASE_COMPRESSED_SUFFIX))
	if err := os.write_entire_file(disk_path, disk); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", disk_path, err)
		return
	}
	files = release_files_of(output_folder, release_number)
	foundation.run([]string{"zstd", RELEASE_COMPRESSION_LEVEL, "-T0", "-q", "-o", files.image_path, disk_path}) or_return
	compressed := foundation.read_file(files.image_path) or_return
	checksum_list := release_checksum_list_text(image_name, compressed)
	signature_text := release_sign(release_seed, transmute([]u8)checksum_list) or_return
	public_key := public_key_of_seed(release_seed) or_return
	if !release_signature_verifies(public_key, transmute([]u8)checksum_list, signature_text) {
		fmt.eprintfln("modustool: release: the release signature of %s does not verify", files.checksum_path)
		return
	}
	if err := os.write_entire_file(files.checksum_path, transmute([]u8)checksum_list); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", files.checksum_path, err)
		return
	}
	signature_line := strings.concatenate({signature_text, "\n"}, context.temp_allocator)
	if err := os.write_entire_file(files.signature_path, transmute([]u8)signature_line); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", files.signature_path, err)
		return
	}
	fmt.printfln("modustool: release: wrote %s (%d bytes; the disk %s, %d bytes), %s and %s, signed by the release signing key %s", files.image_path, len(compressed), disk_path, len(disk), files.checksum_path, files.signature_path, base64url_text(public_key[:]))
	return files, true
}

// release_files_verify verifies the release signature of a checksum list
// with a public key, then the SHA-256 of the image against its line. The
// signature comes first: no line of an unsigned list is read. It gives the
// digits of the image.
release_files_verify :: proc(image_path, checksum_path: string, public_key: [RELEASE_KEY_SIZE]u8) -> (digits: string, problem: string) {
	checksum_list, list_error := os.read_entire_file(checksum_path, context.temp_allocator)
	if list_error != nil {
		return "", fmt.tprintf("cannot read %s: %v", checksum_path, list_error)
	}
	signature_path := strings.concatenate({checksum_path, RELEASE_SIGNATURE_SUFFIX}, context.temp_allocator)
	signature_text, signature_error := os.read_entire_file(signature_path, context.temp_allocator)
	if signature_error != nil {
		return "", fmt.tprintf("cannot read %s, the release signature of %s: %v", signature_path, checksum_path, signature_error)
	}
	key := public_key
	if !release_signature_verifies(key, checksum_list, string(signature_text)) {
		return "", fmt.tprintf("%s is not the release signature of %s with the release signing key %s: do not use the image", signature_path, checksum_path, base64url_text(key[:]))
	}
	rows, parse_problem := release_checksum_list_parse(string(checksum_list))
	if parse_problem != "" {
		return "", parse_problem
	}
	name := image_path[strings.last_index_byte(image_path, '/') + 1:]
	for row in rows {
		if row.file_name != name {
			continue
		}
		image, image_error := os.read_entire_file(image_path, context.temp_allocator)
		if image_error != nil {
			return "", fmt.tprintf("cannot read %s: %v", image_path, image_error)
		}
		found := system_description.hexadecimal(release_sha256(image))
		if string(found[:]) != row.digits {
			return "", fmt.tprintf("the SHA-256 of %s is %s; the signed checksum list says %s: do not use the image", image_path, string(found[:]), row.digits)
		}
		return row.digits, ""
	}
	return "", fmt.tprintf("the signed checksum list %s names no file %s", checksum_path, name)
}

// release_tag_problem says why a tag is not the tag of the release, or
// gives "".
release_tag_problem :: proc(tag, release_number: string) -> string {
	expected := strings.concatenate({"v", release_number}, context.temp_allocator)
	if tag != expected {
		return fmt.tprintf("the tag %s is not %s: the tag of a release is v, then the release number of %s", tag, expected, RELEASE_NUMBER_SOURCE)
	}
	return ""
}

// key_folder_of gives the key folder of the path of a signing key: the
// folder of the file.
key_folder_of :: proc(signing_key_path: string) -> string {
	slash := strings.last_index_byte(signing_key_path, '/')
	return slash < 0 ? "." : signing_key_path[:max(slash, 1)]
}

// release_signing_key_read reads the seed of the release signing key in
// the key folder of SYSTEM_SIGNING_KEY, with the rules of a private key
// file.
release_signing_key_read :: proc() -> (seed: [RELEASE_KEY_SIZE]u8, ok: bool) {
	path := foundation.join(key_folder_of(os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator)), "/", RELEASE_SIGNING_KEY_FILE_NAME)
	if path_inside_repository(path) {
		fmt.eprintfln("modustool: release: %s is inside the repository: the private key of the publisher of the system stays outside it", path)
		return
	}
	if !os.exists(path) {
		fmt.eprintfln("modustool: release: the key folder has no release signing key %s: `modustool key new <folder>` writes one in a new key folder", path)
		return
	}
	if !foundation.private_key_file_check(path) {
		return
	}
	data := foundation.read_file(path) or_return
	defer crypto.zero_explicit(raw_data(data), len(data))
	decoded, valid := release_key_decode(string(data))
	if !valid {
		fmt.eprintfln("modustool: release: %s must hold the 32 bytes of a seed in base64url with no padding", path)
		return
	}
	return decoded, true
}

// release_repository_public_key_read reads the public key of the release
// signing key that the repository holds.
release_repository_public_key_read :: proc() -> (public_key: [RELEASE_KEY_SIZE]u8, ok: bool) {
	data, read_error := os.read_entire_file(RELEASE_PUBLIC_KEY_FILE, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s, the public key of the release signing key: `modustool key new` writes it as %s%s in the key folder, and it is committed here", RELEASE_PUBLIC_KEY_FILE, RELEASE_SIGNING_KEY_FILE_NAME, SIGNING_KEY_PUBLIC_SUFFIX)
		return
	}
	public_key, ok = release_key_decode(string(data))
	if !ok {
		fmt.eprintfln("modustool: %s must hold the 32 bytes of a public key in base64url with no padding", RELEASE_PUBLIC_KEY_FILE)
	}
	return
}

// release_notes_text gives the notes of a release: what the command
// `changelog notes <release number>` of this tool prints, so the section of
// a release has one writer.
release_notes_text :: proc(release_number: string) -> (text: string, ok: bool) {
	tool_path := foundation.tool_executable_path() or_return
	command := [?]string{tool_path, "changelog", "notes", release_number}
	state, standard_output, standard_error, start_error := os.process_exec({command = command[:]}, context.temp_allocator)
	if start_error != nil || !state.exited || !state.success || len(standard_output) == 0 {
		fmt.eprintfln("modustool: release: `changelog notes %s` gave no notes: %s", release_number, string(standard_error))
		return
	}
	return string(standard_output), true
}

// release_image_command is the command `release image`: the keys of the
// publisher, a whole build, the release volume, then the files of the
// release in dist/ and the notes of the release.
release_image_command :: proc() -> int {
	release_number: string = release.RELEASE_NUMBER
	// The keys first: a refusal costs no build. The build never falls back
	// to the test keys here.
	if os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator) == "" {
		fmt.eprintfln("modustool: release: %s names no signing key: a release is signed by the keys of the publisher of the system, never by the test keys", SIGNING_KEY_VARIABLE)
		return foundation.EXIT_FAILURE
	}
	signing_key, signing_key_found := signing_key_read()
	if !signing_key_found {
		return foundation.EXIT_FAILURE
	}
	// is_test compares the public key with the test public key, whatever
	// the path: a copy of the test seed in a key folder is refused too.
	signed_by_test_key := signing_key.is_test
	ed25519.private_key_clear(&signing_key.private_key)
	if signed_by_test_key {
		fmt.eprintfln("modustool: release: %s is the test signing key, whose private key is published: a release never uses it", signing_key.path)
		return foundation.EXIT_FAILURE
	}
	firmware_key, firmware_key_found := firmware_signing_key_find()
	if !firmware_key_found {
		return foundation.EXIT_FAILURE
	}
	if firmware_key.is_test {
		fmt.eprintfln("modustool: release: %s is the test firmware signing key, whose private key is published: a release never uses it", firmware_key.key_path)
		return foundation.EXIT_FAILURE
	}
	// The certificate that a principal enrols must be the one that signs.
	key_folder_certificate, key_folder_certificate_read := foundation.read_file(firmware_key.certificate_path)
	repository_certificate, repository_certificate_error := os.read_entire_file(RELEASE_FIRMWARE_CERTIFICATE_FILE, context.temp_allocator)
	if !key_folder_certificate_read {
		return foundation.EXIT_FAILURE
	}
	// is_test of the firmware signing key says only where the key was
	// found: a copy of the test pair in a key folder is found by its bytes.
	test_certificate := foundation.read_file(TEST_FIRMWARE_CERTIFICATE_FILE) or_else nil
	test_firmware_key := foundation.read_file(TEST_FIRMWARE_SIGNING_KEY_FILE) or_else nil
	key_folder_firmware_key, key_folder_firmware_key_read := foundation.read_file(firmware_key.key_path)
	defer crypto.zero_explicit(raw_data(key_folder_firmware_key), len(key_folder_firmware_key))
	if !key_folder_firmware_key_read || test_certificate == nil || test_firmware_key == nil {
		return foundation.EXIT_FAILURE
	}
	if string(key_folder_certificate) == string(test_certificate) || string(key_folder_firmware_key) == string(test_firmware_key) {
		fmt.eprintfln("modustool: release: %s holds a copy of the test firmware signing key, whose private key is published: a release never uses it", key_folder_of(firmware_key.key_path))
		return foundation.EXIT_FAILURE
	}
	if repository_certificate_error != nil || string(repository_certificate) != string(key_folder_certificate) {
		fmt.eprintfln("modustool: release: %s is not %s: a principal could not enrol the certificate that signs the boot program; commit a copy of the certificate of the key folder", RELEASE_FIRMWARE_CERTIFICATE_FILE, firmware_key.certificate_path)
		return foundation.EXIT_FAILURE
	}
	release_seed, release_seed_found := release_signing_key_read()
	if !release_seed_found {
		return foundation.EXIT_FAILURE
	}
	defer crypto.zero_explicit(&release_seed, size_of(release_seed))
	public_key, public_key_made := public_key_of_seed(release_seed[:])
	repository_key, repository_key_found := release_repository_public_key_read()
	if !public_key_made || !repository_key_found {
		return foundation.EXIT_FAILURE
	}
	if public_key != repository_key {
		fmt.eprintfln("modustool: release: the release signing key of the key folder has the public key %s, and %s holds %s: no reader could verify the release", base64url_text(public_key[:]), RELEASE_PUBLIC_KEY_FILE, base64url_text(repository_key[:]))
		return foundation.EXIT_FAILURE
	}
	notes, notes_found := release_notes_text(release_number)
	if !notes_found {
		return foundation.EXIT_FAILURE
	}

	// A whole build with the checks of the kernel: the build that the
	// machine tests boot. A kept module could come from another state of the
	// work tree.
	build_whole = true
	test_build_checks = true
	// The theme of the system only, whatever the environment names: the
	// license of the theme of the owner allows no public download.
	resources.build_pointer_theme_of_the_owner = false
	build_measure_start()
	if !build_modules() || !release_boot_image_write() {
		return foundation.EXIT_FAILURE
	}
	volume := release_boot_volume()
	if problem := boot_volume_release_problem(volume); problem != "" {
		fmt.eprintfln("modustool: release: %s: a release never ships it", problem)
		return foundation.EXIT_FAILURE
	}
	if !foundation.make_folder(BOOT_OBJECT_FOLDER) || !system_key_write() || !boot_volume_build(volume) {
		return foundation.EXIT_FAILURE
	}
	build_measure_print()
	if _, written := release_files_write(volume.path, release_number, RELEASE_DISK_FOLDER, RELEASE_OUTPUT_FOLDER, release_seed[:], .Publisher_Keys_Only); !written {
		return foundation.EXIT_FAILURE
	}
	if err := os.write_entire_file(RELEASE_NOTES_FILE, transmute([]u8)notes); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", RELEASE_NOTES_FILE, err)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: release: the release %s is in %s, and its notes in %s", release_number, RELEASE_OUTPUT_FOLDER, RELEASE_NOTES_FILE)
	return 0
}

// run_release is the command `release`.
run_release :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "image" {
		return release_image_command()
	}
	if len(args) == 2 && args[0] == "tag-check" {
		if problem := release_tag_problem(args[1], release.RELEASE_NUMBER); problem != "" {
			fmt.eprintfln("modustool: release: %s", problem)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: release: the tag %s names the release %s", args[1], release.RELEASE_NUMBER)
		return 0
	}
	fmt.eprintln("modustool: release image | release tag-check <tag>")
	return foundation.EXIT_USAGE
}

// run_verify is the command `verify <image> <checksum list>`, with the
// public key of the repository.
run_verify :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintfln("modustool: verify <%s> <%s>: the release signature %s%s must be beside the checksum list", release_image_file_name("<release number>"), RELEASE_CHECKSUM_FILE_NAME, RELEASE_CHECKSUM_FILE_NAME, RELEASE_SIGNATURE_SUFFIX)
		return foundation.EXIT_USAGE
	}
	public_key, found := release_repository_public_key_read()
	if !found {
		return foundation.EXIT_FAILURE
	}
	digits, problem := release_files_verify(args[0], args[1], public_key)
	if problem != "" {
		fmt.eprintfln("modustool: verify: %s", problem)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: verify: %s carries the release signature of the release signing key %s, and %s has the SHA-256 that it names: %s", args[1], base64url_text(public_key[:]), args[0], digits)
	return 0
}

// host_random_bytes fills bytes from the generator of the host. The
// cryptography of the system has no source of its own.
host_random_bytes :: proc(bytes: []u8) -> bool {
	random_file, open_error := os.open("/dev/urandom")
	if open_error != nil {
		fmt.eprintfln("modustool: this host gives no random bytes: %v", open_error)
		return false
	}
	read_count, read_error := os.read(random_file, bytes)
	os.close(random_file)
	if read_error != nil || read_count != len(bytes) {
		fmt.eprintln("modustool: this host gives no random bytes")
		return false
	}
	return true
}

// release_signing_key_new writes a new release signing key in a key
// folder: the seed, readable by its owner only, and the public key.
release_signing_key_new :: proc(folder: string) -> bool {
	private_path := foundation.join(folder, "/", RELEASE_SIGNING_KEY_FILE_NAME)
	public_path := foundation.join(private_path, SIGNING_KEY_PUBLIC_SUFFIX)
	seed: [RELEASE_KEY_SIZE]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	host_random_bytes(seed[:]) or_return
	public_key := public_key_of_seed(seed[:]) or_return
	seed_text := strings.concatenate({base64url_text(seed[:]), "\n"}, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(seed_text), len(seed_text))
	if !file_create_new(private_path, transmute([]u8)seed_text, 0o600) || !foundation.private_key_file_check(private_path) {
		return false
	}
	public_text := base64url_text(public_key[:])
	if !file_create_new(public_path, transmute([]u8)strings.concatenate({public_text, "\n"}, context.temp_allocator), 0o644) {
		return false
	}
	fmt.printfln("modustool: wrote %s and %s; release signing key %s: commit a copy of %s as %s, and of the certificate %s/%s as %s", private_path, public_path, public_text, public_path, RELEASE_PUBLIC_KEY_FILE, folder, FIRMWARE_CERTIFICATE_FILE_NAME, RELEASE_FIRMWARE_CERTIFICATE_FILE)
	return true
}

// private_folder_make makes a folder that only its owner can open.
private_folder_make :: proc(folder: string) -> bool {
	if !os.exists(folder) {
		if err := os.make_directory(folder, os.perm(0o700)); err != nil {
			fmt.eprintfln("modustool: cannot create %s: %v", folder, err)
			return false
		}
	}
	if err := os.change_mode(folder, os.perm(0o700)); err != nil {
		fmt.eprintfln("modustool: cannot make %s private: %v", folder, err)
		return false
	}
	return true
}

// key_folder_write is the command `key write <folder>`: it writes a key
// folder, in the form of `key new`, from the four variables of the
// secrets of a workflow. It checks the form of each value and prints no
// value of a private key.
key_folder_write :: proc(folder: string) -> bool {
	if path_inside_repository(folder) {
		fmt.eprintfln("modustool: %s is inside the repository: a private key stays outside it", folder)
		return false
	}
	variables := [KEY_TEXT_VARIABLE_COUNT]string{SYSTEM_SIGNING_KEY_TEXT_VARIABLE, FIRMWARE_SIGNING_KEY_TEXT_VARIABLE, FIRMWARE_CERTIFICATE_TEXT_VARIABLE, RELEASE_SIGNING_KEY_TEXT_VARIABLE}
	values: [KEY_TEXT_VARIABLE_COUNT]string
	for variable, index in variables {
		values[index] = strings.trim_space(os.get_env(variable, context.temp_allocator))
		if values[index] == "" {
			fmt.eprintfln("modustool: key write: the variable %s is empty (secrets/README.md)", variable)
			return false
		}
	}
	system_text, firmware_key_text, firmware_certificate_text, release_text := values[0], values[1], values[2], values[3]
	defer {
		for value in values {
			crypto.zero_explicit(raw_data(value), len(value))
		}
	}
	system_seed, system_problem := signing_key_text_decode(system_text)
	defer crypto.zero_explicit(&system_seed, size_of(system_seed))
	if system_problem != "" {
		fmt.eprintfln("modustool: key write: %s %s", SYSTEM_SIGNING_KEY_TEXT_VARIABLE, system_problem)
		return false
	}
	release_seed, release_valid := release_key_decode(release_text)
	defer crypto.zero_explicit(&release_seed, size_of(release_seed))
	if !release_valid {
		fmt.eprintfln("modustool: key write: %s must hold the 32 bytes of a seed in base64url with no padding", RELEASE_SIGNING_KEY_TEXT_VARIABLE)
		return false
	}
	if !strings.has_prefix(firmware_key_text, PEM_START) || !strings.has_prefix(firmware_certificate_text, PEM_START) {
		fmt.eprintfln("modustool: key write: %s and %s must each hold a PEM file", FIRMWARE_SIGNING_KEY_TEXT_VARIABLE, FIRMWARE_CERTIFICATE_TEXT_VARIABLE)
		return false
	}
	system_public := public_key_of_seed(system_seed[:]) or_return
	release_public := public_key_of_seed(release_seed[:]) or_return
	system_public_digits := system_description.hexadecimal(system_public)
	folder_existed := os.exists(folder)
	private_folder_make(folder) or_return
	// A write that fails part of the way removes what it wrote: a second
	// run then finds no file that it must not write over.
	written_paths := make([dynamic]string, context.temp_allocator)
	complete := false
	defer if !complete {
		for path in written_paths {
			_ = os.remove(path)
		}
		if !folder_existed {
			_ = os.remove(folder)
		}
	}
	Key_File :: struct {
		name: string,
		text: string,
		mode: int,
	}
	key_files := [?]Key_File {
		{SIGNING_KEY_FILE_NAME, system_text, 0o600},
		{SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX, string(system_public_digits[:]), 0o644},
		{FIRMWARE_SIGNING_KEY_FILE_NAME, firmware_key_text, 0o600},
		{FIRMWARE_CERTIFICATE_FILE_NAME, firmware_certificate_text, 0o644},
		{RELEASE_SIGNING_KEY_FILE_NAME, release_text, 0o600},
		{RELEASE_SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX, base64url_text(release_public[:]), 0o644},
	}
	for key_file in key_files {
		path := foundation.join(folder, "/", key_file.name)
		line := strings.concatenate({key_file.text, "\n"}, context.temp_allocator)
		written := file_create_new(path, transmute([]u8)line, key_file.mode)
		crypto.zero_explicit(raw_data(line), len(line))
		if written {
			append(&written_paths, path)
		}
		if !written || (key_file.mode == 0o600 && !foundation.private_key_file_check(path)) {
			return false
		}
	}
	complete = true
	fmt.printfln("modustool: key write: wrote the key folder %s: the signing key, public key %s; the firmware signing key and its certificate; the release signing key, public key %s", folder, string(system_public_digits[:]), base64url_text(release_public[:]))
	return true
}

RELEASE_NUMBER_SOURCE :: foundation.SOURCE_FOLDER_CONTRACT + "/release/release.odin"
