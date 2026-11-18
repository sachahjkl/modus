package modustool

import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/replacement_list"
import "modus:contract/system_description"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import crypto "modus:support/cryptography/compatibility_crypto"
import "modus:support/cryptography/ed25519"
import "modus:support/cryptography/sha2"

// The system description and its signature (docs/TRUSTED_BOOT.md).
//
// The build writes one boot image without a description
// (build_boot_image). For each boot volume, this file writes a copy of it
// with two more resources at the end: the system description of the kernel
// and of each file of that image, and its description signature, made with
// the signing key. The boot program holds the public key of the same key,
// with its key number from KEY_NUMBERS_FILE. The header of the description
// holds the security version of the repository.
//
// The signing key is the file that SYSTEM_SIGNING_KEY names: the private
// key of the publisher of the system, outside the repository. With no
// such variable, the build signs with the test signing key of
// resources/keys, whose private key is published: the machine then says
// that it is not trusted. The private key never goes into the boot volume:
// only the public key and the signature do.

SIGNING_KEY_VARIABLE :: "SYSTEM_SIGNING_KEY"
TEST_SIGNING_KEY_FILE :: RESOURCE_FOLDER + "/keys/test_signing_key"
// The key of the build, for the boot program (#load): the public key, 32
// bytes, then its key number as a little-endian u64.
SYSTEM_KEY_FILE :: BUILD_FOLDER + "/system_key.bin"
// The key number of each public key of the publisher of the system, one
// line for each: the number, one space, the 64 hexadecimal digits of the
// public key (src/md/features/rollback_floors.md). A new key after a theft
// gets the next number: the key floor of the TPM then revokes each key
// before it.
KEY_NUMBERS_FILE :: RESOURCE_FOLDER + "/keys/key_numbers"
SIGNING_KEY_FILE_NAME :: "signing_key"
SIGNING_KEY_PUBLIC_SUFFIX :: ".public"
SIGNING_KEY_SIZE :: 32

Signing_Key :: struct {
	private_key: ed25519.Private_Key,
	public_key:  [system_description.PUBLIC_KEY_SIZE]u8,
	is_test:     bool, // The test signing key: its private key is published.
	path:        string,
}

// A change of the boot image of one volume, for a test of a failure or of
// the measure. The zero value changes nothing.
Image_Change :: struct {
	// One byte of this module changes after the description is made: the
	// boot program must refuse the volume.
	module_changed_after_description:  string,
	// One byte of this module changes before the description is made: it is
	// another system, signed, whose measure must differ.
	module_changed_before_description: string,
	// One bit of the description signature changes: the boot program must
	// refuse the volume.
	signature_changed:                 bool,
	// The security version of the description is this step above the one of
	// the repository: a newer system, which raises the version floor of the
	// TPM, after which the system of the repository is refused.
	security_version_raised:           int,
	// One byte of the kernel module changes after the description is made:
	// the boot program must refuse the volume at the kernel.
	kernel_changed_after_description:  bool,
	// The boot image has no description and no signature: the boot program
	// must refuse the volume.
	description_left_out:              bool,
	// The entry of this module in the boot image states another hash, while
	// its bytes are right: the boot program must refuse the volume, because
	// the loader gives the stated hash to the process as its identity.
	stated_hash_changed_module:        string,
}

// What boot_image_signed_write made for one boot volume.
Signed_Image :: struct {
	kernel_module_path: string, // The kernel module that the boot program holds.
	signed_by_test_key: bool,
}

// The two texts of the file beside a boot volume that says which key
// signed it. The release command packages a volume only with the second.
SIGNED_BY_TEST_KEY_TEXT :: "the TEST signing key, whose private key is published: do not install this volume on a real machine\n"
SIGNED_BY_PUBLISHER_KEY_TEXT :: "the signing key of SYSTEM_SIGNING_KEY\n"

// signed_by_file_path gives the file beside a boot volume that says which
// key signed its system description. A volume that the test signing key
// signed must not be installed on a real machine: the file says so, and a
// developer sees it beside the volume before a copy.
signed_by_file_path :: proc(volume_path: string) -> string {
	return strings.concatenate({volume_path, ".signed_by"}, context.temp_allocator)
}

// signed_image_path gives the boot image of one boot volume.
signed_image_path :: proc(volume_path: string) -> string {
	return strings.concatenate({strings.trim_suffix(volume_path, ".img"), ".image"}, context.temp_allocator)
}

// signing_key_said: the build prints once which key signs.
signing_key_said := false

// signing_key_read reads the signing key of the build.
signing_key_read :: proc() -> (key: Signing_Key, ok: bool) {
	path := os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator)
	if path == "" {
		path = TEST_SIGNING_KEY_FILE
	} else if path_inside_repository(path) {
		fmt.eprintfln("modustool: %s names %s, inside the repository: the private key of the publisher of the system stays outside it", SIGNING_KEY_VARIABLE, path)
		return
	} else if !private_key_file_check(path) {
		return
	}
	key.path = path
	seed := signing_key_file_read(path) or_return
	defer crypto.zero_explicit(&seed, size_of(seed))
	if !ed25519.private_key_set_bytes(&key.private_key, seed[:]) {
		fmt.eprintfln("modustool: %s is not an Ed25519 private key", path)
		return
	}
	ed25519.private_key_public_bytes(&key.private_key, key.public_key[:])
	key.is_test = key.public_key == system_description.TEST_PUBLIC_KEY
	if path == TEST_SIGNING_KEY_FILE && !key.is_test {
		fmt.eprintfln("modustool: %s does not give the public key of the test signing key (" + SOURCE_FOLDER_CONTRACT + "/system_description)", path)
		return
	}
	if !signing_key_said {
		signing_key_said = true
		digits := system_description.hexadecimal(key.public_key)
		if key.is_test {
			fmt.printfln("modustool: the system is signed with the TEST signing key (%s): its private key is published, and the machine says that it is not trusted. Set %s to the private key of the publisher of the system (`modustool key new <folder>`).", path, SIGNING_KEY_VARIABLE)
		} else {
			fmt.printfln("modustool: the system is signed with the key of %s, public key %s", path, string(digits[:]))
		}
	}
	return key, true
}

// signing_key_file_read reads a key file: 64 hexadecimal digits, then an
// end of line.
signing_key_file_read :: proc(path: string) -> (bytes: [SIGNING_KEY_SIZE]u8, ok: bool) {
	data := read_file(path) or_return
	defer crypto.zero_explicit(raw_data(data), len(data))
	problem: string
	bytes, problem = signing_key_text_decode(string(data))
	if problem != "" {
		fmt.eprintfln("modustool: %s %s", path, problem)
		return
	}
	return bytes, true
}

// signing_key_text_decode reads the text of a key file: 64 hexadecimal
// digits, with white space around them. problem says what is wrong, or is
// "".
signing_key_text_decode :: proc(data: string) -> (bytes: [SIGNING_KEY_SIZE]u8, problem: string) {
	text := strings.trim_space(data)
	if len(text) != 2 * SIGNING_KEY_SIZE {
		return {}, fmt.tprintf("must hold 64 hexadecimal digits; it holds %d characters", len(text))
	}
	for index in 0 ..< SIGNING_KEY_SIZE {
		high, high_valid := signing_key_digit(text[2 * index])
		low, low_valid := signing_key_digit(text[2 * index + 1])
		if !high_valid || !low_valid {
			crypto.zero_explicit(&bytes, size_of(bytes))
			return {}, "must hold hexadecimal digits only"
		}
		bytes[index] = high << 4 | low
	}
	return bytes, ""
}

signing_key_digit :: proc(character: u8) -> (value: u8, valid: bool) {
	switch character {
	case '0' ..= '9':
		return character - '0', true
	case 'a' ..= 'f':
		return character - 'a' + 10, true
	case 'A' ..= 'F':
		return character - 'A' + 10, true
	}
	return 0, false
}

// repository_root gives the folder of the repository: the nearest folder
// at or above the working folder that holds flake.nix, resolved. The tool
// can run from a subfolder; the rule on keys holds from there too.
repository_root :: proc() -> (root: string, found: bool) {
	working, working_error := os.get_working_directory(context.temp_allocator)
	if working_error != nil {
		return "", false
	}
	folder := working
	for {
		if os.exists(strings.concatenate({folder, "/", ROOT_MARK}, context.temp_allocator)) {
			resolved, resolve_error := os.get_absolute_path(folder, context.temp_allocator)
			return resolved, resolve_error == nil
		}
		slash := strings.last_index_byte(folder, '/')
		if slash <= 0 {
			return "", false
		}
		folder = folder[:slash]
	}
}

// path_inside_repository says if a path is in the folder of the repository,
// where a commit or a build can take it. Both paths are resolved: a
// symbolic link to the repository is inside it. The path can name a file or
// a folder that does not exist yet: its nearest folder that exists decides.
path_inside_repository :: proc(path: string) -> bool {
	repository, found := repository_root()
	if !found {
		return true // Not known: refused.
	}
	existing := path
	for !os.exists(existing) {
		slash := strings.last_index_byte(existing, '/')
		if slash < 0 {
			existing = "." // A relative name: in the working directory.
			break
		}
		if slash == 0 {
			existing = "/"
			break
		}
		existing = existing[:slash]
	}
	absolute, absolute_error := os.get_absolute_path(existing, context.temp_allocator)
	if absolute_error != nil {
		return true // Not known: refused.
	}
	return absolute == repository || strings.has_prefix(absolute, strings.concatenate({repository, "/"}, context.temp_allocator))
}

// private_key_file_check refuses a private key file that another user owns,
// or that the group or the others can read, write or run: such a key can be
// copied by someone who is not the publisher of the system.
private_key_file_check :: proc(path: string) -> bool {
	information, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		fmt.eprintfln("modustool: cannot read the mode of %s: %v", path, stat_error)
		return false
	}
	shared := os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
	if information.mode & shared != {} {
		fmt.eprintfln("modustool: the private key %s can be read by other users of this computer: run `chmod 600 %s`, then make a new key if another user can have copied it", path, path)
		return false
	}
	record: linux.Stat
	path_text := strings.clone_to_cstring(path, context.temp_allocator)
	if linux.stat(path_text, &record) != .NONE || record.uid != linux.getuid() {
		fmt.eprintfln("modustool: the private key %s belongs to another user", path)
		return false
	}
	return true
}

// file_create_new writes a new file with this mode. It refuses a path that
// exists, also a symbolic link: the creation is exclusive, so a link that
// someone placed there is never followed.
file_create_new :: proc(path: string, data: []u8, mode: int) -> bool {
	file, open_error := os.open(path, {.Write, .Create, .Excl}, os.perm(mode))
	if open_error != nil {
		fmt.eprintfln("modustool: cannot create %s, which must not exist: %v", path, open_error)
		return false
	}
	written, write_error := os.write(file, data)
	close_error := os.close(file)
	if write_error != nil || close_error != nil || written != len(data) {
		fmt.eprintfln("modustool: cannot write %s", path)
		return false
	}
	return true
}

// boot_image_signed_write writes the boot image of one boot volume: the
// image of the build at base_path with, as its two last resources, the
// system description of kernel_name and of each file of the image, and its
// description signature. The tool checks the result with the code of the
// boot program before it writes it.
boot_image_signed_write :: proc(base_path, kernel_name, output_path: string, change: Image_Change) -> (signed: Signed_Image, ok: bool) {
	base := read_file(base_path) or_return
	modules, resources, valid := info.image_tables(base)
	if !valid {
		fmt.eprintfln("modustool: %s is not a boot image", base_path)
		return
	}
	files := make([dynamic]Image_File, context.temp_allocator)
	for &entry in modules {
		bytes, inside := info.image_entry_bytes(base, &entry)
		if !inside {
			fmt.eprintfln("modustool: an entry of %s points outside it", base_path)
			return
		}
		append(&files, Image_File{name = strings.clone(system_description.name_of(&entry.name), context.temp_allocator), file = bytes})
	}
	module_count := len(files)
	for &entry in resources {
		bytes, inside := info.image_entry_bytes(base, &entry)
		if !inside {
			fmt.eprintfln("modustool: an entry of %s points outside it", base_path)
			return
		}
		append(&files, Image_File{name = strings.clone(system_description.name_of(&entry.name), context.temp_allocator), file = bytes})
	}
	if change.module_changed_before_description != "" {
		image_file_change(files[:module_count], change.module_changed_before_description) or_return
	}
	kernel := read_file(module_path(kernel_name)) or_return

	key := signing_key_read() or_return
	// The private key leaves the memory of the tool after its uses: the
	// replacement rows, then the description.
	defer ed25519.private_key_clear(&key.private_key)
	// The replacement list is a resource before the description, so the
	// description lists it, and its rows are signed by the same key.
	replacement_rows := replacement_list_of_the_build(files[:module_count], &key) or_return
	append(&files, Image_File{name = replacement_list.RESOURCE_NAME, file = replacement_rows})

	description := make([dynamic]u8, context.temp_allocator)
	header := system_description.Header {
		magic            = system_description.MAGIC,
		version          = system_description.VERSION,
		entry_count      = u32(1 + len(files)),
		security_version = u32(system_description.SECURITY_VERSION + change.security_version_raised),
	}
	append(&description, ..mem.ptr_to_bytes(&header))
	kernel_entry := description_entry(system_description.KERNEL_ENTRY_NAME, .Kernel, kernel)
	append(&description, ..mem.ptr_to_bytes(&kernel_entry))
	for item, index in files {
		kind := index < module_count ? system_description.Entry_Kind.Module : system_description.Entry_Kind.Resource
		entry := description_entry(item.name, kind, item.file)
		append(&description, ..mem.ptr_to_bytes(&entry))
	}
	if _, description_valid := system_description.entries(description[:]); !description_valid {
		fmt.eprintfln("modustool: the system description of %s does not follow its format", output_path)
		return
	}

	message := system_description.signed_message(description[:])
	signature: [system_description.SIGNATURE_SIZE]u8
	ed25519.sign(&key.private_key, message[:], signature[:])
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, key.public_key[:]) || !ed25519.verify(&public_key, message[:], signature[:]) {
		fmt.eprintfln("modustool: the signature of the system description of %s does not verify", output_path)
		return
	}
	if change.signature_changed {
		signature[17] ~= 0x04
	}
	if change.module_changed_after_description != "" {
		image_file_change(files[:module_count], change.module_changed_after_description) or_return
	}
	if !change.description_left_out {
		append(&files, Image_File{name = system_description.RESOURCE_DESCRIPTION, file = description[:]}, Image_File{name = system_description.RESOURCE_SIGNATURE, file = signature[:]})
	}
	image := boot_image_encode(files[:], module_count)
	if change.stated_hash_changed_module != "" {
		image_stated_hash_change(image, change.stated_hash_changed_module) or_return
	}
	signed.kernel_module_path = module_path(kernel_name)
	kernel_held := kernel
	if change.kernel_changed_after_description {
		kernel_held = make([]u8, len(kernel), context.temp_allocator)
		copy(kernel_held, kernel)
		kernel_held[len(kernel_held) - 1] ~= 0x01
		signed.kernel_module_path = strings.concatenate({strings.trim_suffix(output_path, ".image"), "_kernel.module"}, context.temp_allocator)
		if err := os.write_entire_file(signed.kernel_module_path, kernel_held); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", signed.kernel_module_path, err)
			return
		}
	}

	// The checks of the boot program, on the host: a fault of the format is
	// found here, and a test volume fails for the reason that it is made for.
	expected_image_fault := system_description.Check_Fault.None
	if change.module_changed_after_description != "" {
		expected_image_fault = .Hash_Differs
	} else if change.stated_hash_changed_module != "" {
		expected_image_fault = .Stated_Hash_Differs
	}
	expected_kernel_fault := change.kernel_changed_after_description ? system_description.Check_Fault.Hash_Differs : system_description.Check_Fault.None
	written_description, _, found := system_description.trust_resources(image)
	checks_as_made := found != change.description_left_out
	if found {
		checks_as_made &&= system_description.kernel_check(written_description, kernel_held).fault == expected_kernel_fault
		checks_as_made &&= system_description.image_check(written_description, image).fault == expected_image_fault
	}
	if !checks_as_made {
		fmt.eprintfln("modustool: the boot image %s does not pass the checks of the boot program as it must", output_path)
		return
	}
	if err := os.write_entire_file(output_path, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", output_path, err)
		return
	}
	signed.signed_by_test_key = key.is_test
	return signed, true
}

// system_key_write writes the public key of the signing key of the build,
// with its key number, in the file that every boot program loads. The
// process that leads the build writes it one time, before the first boot
// volume is built: two volume builds at the same time never write a file
// that a compiler of the other reads.
system_key_write :: proc() -> bool {
	key := signing_key_read() or_return
	// The private key leaves the memory of the tool after this one use.
	defer ed25519.private_key_clear(&key.private_key)
	key_number := key_number_read(key.public_key) or_return
	bytes: [system_description.PUBLIC_KEY_SIZE + 8]u8
	copy(bytes[:], key.public_key[:])
	for index in 0 ..< 8 {
		bytes[system_description.PUBLIC_KEY_SIZE + index] = u8(key_number >> (8 * u64(index)))
	}
	if err := os.write_entire_file(SYSTEM_KEY_FILE, bytes[:]); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", SYSTEM_KEY_FILE, err)
		return false
	}
	return true
}

// key_number_read gives the key number of a public key from KEY_NUMBERS_FILE.
// A key with no line is refused: its boot program would have no number for
// the key floor of the TPM.
key_number_read :: proc(public_key: [system_description.PUBLIC_KEY_SIZE]u8) -> (key_number: u64, ok: bool) {
	data := read_file(KEY_NUMBERS_FILE) or_return
	problem: string
	key_number, problem = key_number_of(string(data), public_key)
	if problem != "" {
		digits := system_description.hexadecimal(public_key)
		fmt.eprintfln("modustool: %s: %s (the public key %s; src/md/features/rollback_floors.md)", KEY_NUMBERS_FILE, problem, string(digits[:]))
		return 0, false
	}
	return key_number, true
}

// key_number_of reads the text of the file of the key numbers and gives the
// number of the public key. Each line is a number from 1 to 64, one space,
// and 64 lowercase hexadecimal digits; no number and no key comes twice.
// problem says what is wrong, or is "".
key_number_of :: proc(text: string, public_key: [system_description.PUBLIC_KEY_SIZE]u8) -> (key_number: u64, problem: string) {
	wanted := system_description.hexadecimal(public_key)
	numbers_seen: [info.FLOOR_LIMIT + 1]bool
	keys_seen := make([dynamic]string, context.temp_allocator)
	remaining := text
	line_number := 0
	for line in strings.split_lines_iterator(&remaining) {
		line_number += 1
		space := strings.index_byte(line, ' ')
		if space <= 0 || len(line) - space - 1 != 2 * system_description.PUBLIC_KEY_SIZE {
			return 0, fmt.tprintf("line %d is not a number, one space and 64 hexadecimal digits", line_number)
		}
		number: u64
		for character in line[:space] {
			if character < '0' || character > '9' || number > info.FLOOR_LIMIT {
				return 0, fmt.tprintf("line %d does not start with a key number from 1 to %d", line_number, info.FLOOR_LIMIT)
			}
			number = number * 10 + u64(character - '0')
		}
		if number == 0 || number > info.FLOOR_LIMIT {
			return 0, fmt.tprintf("line %d does not start with a key number from 1 to %d", line_number, info.FLOOR_LIMIT)
		}
		digits := line[space + 1:]
		for index in 0 ..< len(digits) {
			if !(digits[index] >= '0' && digits[index] <= '9' || digits[index] >= 'a' && digits[index] <= 'f') {
				return 0, fmt.tprintf("line %d does not end with 64 lowercase hexadecimal digits", line_number)
			}
		}
		if numbers_seen[number] {
			return 0, fmt.tprintf("line %d gives the key number %d a second time", line_number, number)
		}
		numbers_seen[number] = true
		for earlier in keys_seen {
			if earlier == digits {
				return 0, fmt.tprintf("line %d gives a key a second number", line_number)
			}
		}
		append(&keys_seen, digits)
		if digits == string(wanted[:]) {
			key_number = number
		}
	}
	if key_number == 0 {
		return 0, "no line gives the signing key of the build its key number: add the line \"<the next number> <its public key>\""
	}
	return key_number, ""
}

// image_stated_hash_change changes one bit of the hash that the entry of
// this module states in an encoded boot image; its bytes stay.
image_stated_hash_change :: proc(image: []u8, name: string) -> bool {
	modules, _, valid := info.image_tables(image)
	if valid {
		for &entry in modules {
			if system_description.name_of(&entry.name) == name {
				entry.hash[0] ~= 0x01
				return true
			}
		}
	}
	fmt.eprintfln("modustool: the boot image has no module %s whose stated hash can change", name)
	return false
}

// description_entry gives the entry of one file in the system description.
description_entry :: proc(name: string, kind: system_description.Entry_Kind, file: []u8) -> (entry: system_description.Entry) {
	copy(entry.name[:system_description.NAME_SIZE - 1], name)
	entry.kind = kind
	entry.size = u64(len(file))
	entry.hash = blake3.hash(file)
	return
}

// image_file_change changes the last byte of the module with this name, in
// a copy of its bytes.
image_file_change :: proc(files: []Image_File, name: string) -> bool {
	for &item in files {
		if item.name == name && len(item.file) > 0 {
			changed := make([]u8, len(item.file), context.temp_allocator)
			copy(changed, item.file)
			changed[len(changed) - 1] ~= 0x01
			item.file = changed
			return true
		}
	}
	fmt.eprintfln("modustool: the boot image has no module %s to change", name)
	return false
}

// image_description_read gives the system description of the boot image
// of a boot volume.
image_description_read :: proc(volume_path: string) -> (description: []u8, ok: bool) {
	image := read_file(signed_image_path(volume_path)) or_return
	found: bool
	description, _, found = system_description.trust_resources(image)
	if !found {
		fmt.eprintfln("modustool: %s has no system description", signed_image_path(volume_path))
		return nil, false
	}
	return description, true
}

// measure_expected gives the value that the measure register must hold
// after the measure, in the SHA-256 bank: the register starts at 32 zero
// bytes, and one extension makes it SHA-256(register || SHA-256(data)). No
// other part of the boot of the first machine extends this register.
measure_expected :: proc(description: []u8) -> (value: [32]u8) {
	digest: [32]u8
	hash_state: sha2.Context_256
	sha2.init_256(&hash_state)
	sha2.update(&hash_state, description)
	sha2.final(&hash_state, digest[:])
	start: [32]u8
	sha2.init_256(&hash_state)
	sha2.update(&hash_state, start[:])
	sha2.update(&hash_state, digest[:])
	sha2.final(&hash_state, value[:])
	return
}

// run_key: `key new <folder>` writes a new signing key: <folder>/signing_key
// (the private key, readable by its owner only, in a folder that only its
// owner can open) and <folder>/signing_key.public, then the firmware signing
// key and the release signing key in the same folder (secure_boot.odin,
// release_image.odin). `key write <folder>` writes such a folder from the
// secrets of a workflow. `key show` prints the public key that the build
// uses. `key test-firmware-new` writes the test firmware signing key of the
// repository.
run_key :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "show" {
		key, ok := signing_key_read()
		if !ok {
			return EXIT_FAILURE
		}
		digits := system_description.hexadecimal(key.public_key)
		fmt.printfln("%s%s", string(digits[:]), key.is_test ? " (the test signing key: not trusted)" : "")
		key_number, ok_number := key_number_read(key.public_key)
		if !ok_number {
			return EXIT_FAILURE
		}
		fmt.printfln("key number %d", key_number)
		return 0
	}
	// The test firmware signing key of the repository: made once, then
	// committed beside the test signing key. Its private key is published.
	if len(args) == 1 && args[0] == "test-firmware-new" {
		return firmware_signing_key_new(RESOURCE_FOLDER + "/keys", true) ? 0 : EXIT_FAILURE
	}
	if len(args) == 2 && args[0] == "write" {
		return key_folder_write(args[1]) ? 0 : EXIT_FAILURE
	}
	if len(args) != 2 || args[0] != "new" {
		fmt.eprintln("modustool: key new <folder outside the repository> | key write <folder outside the repository> | key show | key test-firmware-new")
		return EXIT_USAGE
	}
	folder := args[1]
	if path_inside_repository(folder) {
		fmt.eprintfln("modustool: %s is inside the repository: a private key stays outside it", folder)
		return EXIT_USAGE
	}
	private_path := strings.concatenate({folder, "/", SIGNING_KEY_FILE_NAME}, context.temp_allocator)
	public_path := strings.concatenate({private_path, SIGNING_KEY_PUBLIC_SUFFIX}, context.temp_allocator)
	firmware_key_path := strings.concatenate({folder, "/", FIRMWARE_SIGNING_KEY_FILE_NAME}, context.temp_allocator)
	firmware_certificate_path := strings.concatenate({folder, "/", FIRMWARE_CERTIFICATE_FILE_NAME}, context.temp_allocator)
	release_key_path := strings.concatenate({folder, "/", RELEASE_SIGNING_KEY_FILE_NAME}, context.temp_allocator)
	release_public_path := strings.concatenate({release_key_path, SIGNING_KEY_PUBLIC_SUFFIX}, context.temp_allocator)
	if os.exists(private_path) || os.exists(public_path) || os.exists(firmware_key_path) || os.exists(firmware_certificate_path) || os.exists(release_key_path) || os.exists(release_public_path) {
		fmt.eprintfln("modustool: %s already holds a signing key: a new key does not replace one", folder)
		return EXIT_FAILURE
	}
	if !os.exists(folder) {
		if err := os.make_directory(folder, os.perm(0o700)); err != nil {
			fmt.eprintfln("modustool: cannot create %s: %v", folder, err)
			return EXIT_FAILURE
		}
	}
	if err := os.change_mode(folder, os.perm(0o700)); err != nil {
		fmt.eprintfln("modustool: cannot make %s private: %v", folder, err)
		return EXIT_FAILURE
	}
	// The seed of the key comes from the generator of the host. The
	// cryptography of the system has no source of its own: in the system the
	// root service seeds each process.
	seed: [SIGNING_KEY_SIZE]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	random_file, open_error := os.open("/dev/urandom")
	if open_error != nil {
		fmt.eprintfln("modustool: this host gives no random bytes: %v", open_error)
		return EXIT_FAILURE
	}
	read_count, read_error := os.read(random_file, seed[:])
	os.close(random_file)
	if read_error != nil || read_count != len(seed) {
		fmt.eprintln("modustool: this host gives no random bytes")
		return EXIT_FAILURE
	}
	private_key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&private_key, seed[:]) {
		fmt.eprintln("modustool: cannot make a key")
		return EXIT_FAILURE
	}
	defer ed25519.private_key_clear(&private_key)
	public: [system_description.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&private_key, public[:])
	seed_digits := system_description.hexadecimal(seed)
	defer crypto.zero_explicit(&seed_digits, size_of(seed_digits))
	public_digits := system_description.hexadecimal(public)
	private_text := strings.concatenate({string(seed_digits[:]), "\n"}, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(private_text), len(private_text))
	if !file_create_new(private_path, transmute([]u8)private_text, 0o600) || !private_key_file_check(private_path) {
		return EXIT_FAILURE
	}
	if !file_create_new(public_path, transmute([]u8)strings.concatenate({string(public_digits[:]), "\n"}, context.temp_allocator), 0o644) {
		return EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s and %s; public key %s", private_path, public_path, string(public_digits[:]))
	fmt.printfln("modustool: add the line \"<the next key number> %s\" to %s before a build with this key: the key floor of the TPM then refuses each key with a lower number (docs/TRUSTED_BOOT.md, \"10. The TPM floors\")", string(public_digits[:]), KEY_NUMBERS_FILE)
	// The firmware signing key, for Secure Boot, in the same folder.
	if !firmware_signing_key_new(folder, false) {
		return EXIT_FAILURE
	}
	// The release signing key, for the files of a release, in the same
	// folder.
	if !release_signing_key_new(folder) {
		return EXIT_FAILURE
	}
	fmt.printfln("modustool: keep a copy of %s on a second medium, offline; then set %s=%s for each build (docs/TRUSTED_BOOT.md, \"The signing key\")", private_path, SIGNING_KEY_VARIABLE, private_path)
	return 0
}
