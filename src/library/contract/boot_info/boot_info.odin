// The record that the boot program gives to the kernel. The boot program is
// a UEFI program: it uses the services of the firmware before the kernel
// starts (docs/PROPERTIES.md, "Trusted boot").
//
// All addresses in it are physical addresses. The boot program maps all
// physical memory at DIRECT_MAP_BASE, and the kernel module at KERNEL_BASE,
// before it starts the kernel.
//
// Who uses it: the boot program writes `Boot_Info` and the boot image; the
// kernel reads them once, at its start; the build tool writes the boot
// image (`Image_Header`, `Image_Entry`); the kernel and the root service
// read the boot image to find the modules. The parts:
//
// - `Boot_Info`: the record, with `Memory_Range`, `Framebuffer` and
//   `Boot_Trust`.
// - `Boot_Trust`, `Verifier`, `Signing_Key_Kind`, `Measure_State`,
//   `Floor_State`: what the boot program verified, measured, and read of
//   the TPM floors (docs/TRUSTED_BOOT.md).
// - `Self_Test`: the tests of the kernel on itself.
// - `Image_Header`, `Image_Entry`, `image_tables`, `image_entry_bytes`: the
//   boot image.
//
// See [boot program](term:boot-program), [boot record](term:boot-record)
// and [boot image](term:boot-image).
package boot_info

import "base:intrinsics"
import "modus:contract/enum_word"

MAGIC :: u64(0x4F464E49544F4F42) // The bytes "BOOTINFO".

// The address where the boot program maps all physical memory, for the
// kernel: the physical address p is at `DIRECT_MAP_BASE + p` (`physical`).
// It is the first address of the upper half, which only the kernel uses.
DIRECT_MAP_BASE :: uintptr(0xFFFF_8000_0000_0000)
// The address of the kernel module: the last 2 GiB of the addresses.
KERNEL_BASE :: uintptr(0xFFFF_FFFF_8000_0000)
PAGE_SIZE :: 4096 // The page of the processor.
PAGE_TABLE_LEVELS :: 4 // The levels of a page table of the processor: addresses of 48 bits.
// The pages of the stack on which the boot program starts the kernel.
BOOT_STACK_PAGES :: 16
// The bound of the debug image (Boot_Info.debug_image): its pages stay taken
// from the memory of the machine for its whole run. The debug image of the
// build is 2.3 MiB, and 32 MiB is about 14 times it. The boot program reads
// no larger file, and the kernel refuses a larger range.
DEBUG_IMAGE_LIMIT :: 32 << 20

// What a range of physical memory holds, as the boot program tells the
// kernel. The kernel takes its page frames from the `Free` ranges only.
Memory_Kind :: enum u32 {
	Reserved = 0, // Not usable: firmware, devices, holes.
	Free     = 1, // Memory that the kernel can give to processes.
	Boot     = 2, // In use by what the boot program loaded: this record, the kernel, the boot image, page tables.
}

// One run of physical memory, from the memory map of the firmware.
Memory_Range :: struct {
	start:      u64, // The physical address of the first page.
	page_count: u64, // Pages of 4096 bytes.
	kind:       Memory_Kind, // What the run holds.
	reserved:   u32, // 0.
}

// The order of the bytes of one pixel of the framebuffer.
Pixel_Format :: enum u32 {
	None             = 0, // No framebuffer: the firmware gave none, or one of a format that the system does not draw.
	Blue_Green_Red_X = 1, // 4 bytes per pixel, blue first.
	Red_Green_Blue_X = 2, // 4 bytes per pixel, red first.
}

// The framebuffer that the firmware set up: the screen that the boot
// display and the compositor draw on.
Framebuffer :: struct {
	address:         u64, // The physical address of the first pixel.
	width:           u32, // Pixels.
	height:          u32, // Pixels.
	pixels_per_line: u32, // The distance between two lines, in pixels.
	format:          Pixel_Format, // The order of the bytes of a pixel.
}

// The boot record: what the boot program found and loaded, given to the
// kernel at its entry. All addresses are physical.
//
// The boot program writes it once; the kernel reads it at its start, keeps
// what it needs in its `op.Boot_Report`, and gives the boot image, the
// framebuffer and the debug image to the root service as memory objects.
Boot_Info :: struct {
	magic:              u64, // `MAGIC`: the kernel stops when it is not.
	memory_ranges:      u64, // Address of an array of Memory_Range.
	memory_range_count: u64, // The records at `memory_ranges`.
	direct_map_size:    u64, // Bytes of physical memory that are mapped at DIRECT_MAP_BASE.
	page_table:         u64, // Address of the top level page table that the boot program built.
	kernel_address:     u64, // Where the kernel module is in physical memory.
	kernel_size:        u64, // The bytes of the kernel module in memory: its `memory_size`.
	kernel_file:        u64, // The kernel module file.
	kernel_file_size:   u64, // The bytes of the kernel module file.
	boot_image:         u64, // The boot image: the modules of the first processes.
	boot_image_size:    u64, // The bytes of the boot image.
	framebuffer:        Framebuffer, // The screen. `format` None: no screen.
	acpi_root:          u64, // The root record of the ACPI tables of the firmware ("RSD PTR "). 0: none.
	// The cycle counter of the processor at two moments of the boot program.
	// The counter is 0 when the machine starts.
	cycles_start:       u64, // The boot program starts.
	cycles_loaded:      u64, // The kernel and the boot image are in memory.
	firmware_vendor:    [32]u8, // Zero bytes after the name.
	firmware_revision:  u64, // The revision of the firmware, as the firmware gives it.
	self_test:          u64, // The word of a Self_Test (self_test_of_word). None for a normal boot. Another value: the kernel does that test on itself and stops.
	trust:              Boot_Trust, // What the boot program verified and measured.
	// The debug image: the debug objects of the modules, a file of the boot
	// volume beside the boot program (docs/MODULE_CONTRACT.md, "Debug
	// information"). 0: the volume has none, or the boot program could not
	// read it. It is data for a reader of names: the boot program does not
	// verify it, and no code comes from it.
	debug_image:        u64,
	debug_image_size:   u64, // At most `DEBUG_IMAGE_LIMIT`.
	// The start policy that the root service starts: the word of a
	// Start_Request, and the word of the Start_Request_Source that asked
	// for it (start_request_of_words).
	start_request:        u64,
	start_request_source: u64,
}

// The start policy that the boot program asks the root service for
// (src/md/features/start_policy.md, "The rescue key").
Start_Request :: enum u64 {
	Chosen = 0, // The start policy of the choice of principal 0, or the default one.
	Rescue = 1, // The rescue start policy, in place of the chosen one, for this start only.
}

// What asked for the start request: the root service names it in its line.
// The key R and the boot entry give the same Rescue.
Start_Request_Source :: enum u64 {
	None       = 0, // Nothing asked: the request is Chosen.
	Key        = 1, // The key R, held while the machine started.
	Boot_Entry = 2, // The load options of the boot entry "modus (rescue)".
}

// start_request_of_words is the border of the two words of the boot
// record: a word that names no member is
// refused, and so is a pair that does not agree (Rescue with no source,
// Chosen with one). The root service then starts the rescue start policy,
// with its line: a record that it cannot read never chooses a start policy
// that no principal chose.
start_request_of_words :: proc "contextless" (request_word, source_word: u64) -> (request: Start_Request, source: Start_Request_Source, ok: bool) {
	read_request, request_known := enum_word.member_of_word(Start_Request, request_word)
	read_source, source_known := enum_word.member_of_word(Start_Request_Source, source_word)
	if !request_known || !source_known {
		return .Chosen, .None, false
	}
	if (read_request == .Rescue) != (read_source != .None) {
		return .Chosen, .None, false
	}
	return read_request, read_source, true
}

// The load options of the boot entry "modus (rescue)": one record of 16
// bytes, the tag, the version and the word of a Start_Request. The boot
// program writes it as the optional data of the entry, and reads it from
// the load options of its loaded image.
LOAD_OPTIONS_TAG :: "MODUSOPT"
LOAD_OPTIONS_VERSION :: 1
LOAD_OPTIONS_SIZE :: 16

Load_Options_Record :: struct #packed {
	tag:     [8]u8,
	version: u32,
	request: u32, // The word of a Start_Request.
}
#assert(size_of(Load_Options_Record) == LOAD_OPTIONS_SIZE)

// What the read of the load options found.
Load_Options_Reading :: enum u8 {
	Not_Tagged     = 0, // They do not start with the tag: not a flag of this system. Chosen, with no line.
	Read           = 1, // A whole record: its request.
	Wrong_Size     = 2, // The tag, and not 16 bytes.
	Wrong_Version  = 3,
	Unknown_Word   = 4, // A word that names no Start_Request.
}

// load_options_read reads a copy of the load options. Bytes that do not
// start with the tag are a normal start: some firmware gives the
// description of the entry, or a device path, to a normal start. A tagged
// record is the one form that this system writes, so a damaged one is a
// fault to read: each other reading stops the boot program. word is the
// word of the record, for the line of an Unknown_Word.
load_options_read :: proc "contextless" (bytes: []u8) -> (request: Start_Request, reading: Load_Options_Reading, word: u32) {
	if len(bytes) < len(LOAD_OPTIONS_TAG) || string(bytes[:len(LOAD_OPTIONS_TAG)]) != LOAD_OPTIONS_TAG {
		return .Chosen, .Not_Tagged, 0
	}
	if len(bytes) != LOAD_OPTIONS_SIZE {
		return .Chosen, .Wrong_Size, 0
	}
	record: Load_Options_Record
	intrinsics.mem_copy_non_overlapping(&record, raw_data(bytes), LOAD_OPTIONS_SIZE)
	if record.version != LOAD_OPTIONS_VERSION {
		return .Chosen, .Wrong_Version, 0
	}
	read, known := enum_word.member_of_word(Start_Request, u64(record.request))
	if !known {
		return .Chosen, .Unknown_Word, record.request
	}
	return read, .Read, record.request
}

// load_options_write gives the record of a request.
load_options_write :: proc "contextless" (request: Start_Request) -> (record: Load_Options_Record) {
	tag := LOAD_OPTIONS_TAG
	intrinsics.mem_copy_non_overlapping(&record.tag[0], raw_data(tag), len(tag))
	record.version = LOAD_OPTIONS_VERSION
	record.request = u32(request)
	return record
}

// The trust record (docs/TRUSTED_BOOT.md): what the boot program verified
// and measured before it started the kernel. The kernel copies it into the
// boot record and does not read it. All zero: nothing was verified.
//
// The last seven fields are the TPM floors
// (src/md/features/rollback_floors.md): the two numbers that the boot
// program compared, and the two floors that it read before it raised them:
// the key floor, and the version floor of its key number.
Boot_Trust :: struct {
	verifier:            Verifier, // Who verified the system description.
	key_kind:            Signing_Key_Kind, // The kind of the key that signed it.
	public_key:          [32]u8, // The Ed25519 public key that verified the description signature.
	description_hash:    [32]u8, // The BLAKE3 hash of the system description.
	entry_count:         u64, // The entries of the system description, the kernel included.
	check_cycles:        u64, // The cycles of the check of the signature and of every hash.
	measure:             Measure_State, // What the measure into the TPM gave.
	measure_register:    u64, // The register of the TPM that the boot program extended.
	measure_value:       [32]u8, // The value of the register in the SHA-256 bank, read back from the TPM.
	measure_status:      u64, // The status of the firmware, or the response code of the TPM, when measure is Refused or Not_Read.
	measure_tries:       u64, // The tries of the extension: 1 when the first one worked.
	security_version:    u64, // The security version of the system description.
	key_number:          u64, // The key number that the boot program holds beside the public key.
	version_floor:       u64, // The lowest security version that the TPM lets start with this key number. 0: none.
	version_floor_state: u64, // What the read of the version floor of this key number found: the word of a Floor_State (floor_state_of_word).
	key_floor:           u64, // The lowest key number that the TPM lets start. 0: none.
	key_floor_state:     u64, // What the read of the key floor found: the word of a Floor_State (floor_state_of_word).
	floor_status:        u64, // The status of the firmware, or the response code of the TPM, of the first read that failed.
}

// What the boot program found at the index of a TPM floor. In each state but
// Held, the floor is 0: the boot program refuses nothing for it. With
// Secure Boot on, the boot program removes the index of the states Foreign,
// Never_Written and Read_Refused, and defines its own.
Floor_State :: enum u64 {
	None          = 0, // The boot program did not read it: the firmware has no TPM.
	Absent        = 1, // The TPM has no index there: no system defined the floor yet, or a clear removed it.
	Held          = 2, // The index has the attributes and the policy of a floor of this system, and holds bits: they are the floor.
	Foreign       = 3, // An index is there with other attributes or another policy: another system defined it, or PCR 7 changed.
	Not_Read      = 4, // The firmware or the TPM refused a read for another reason: floor_status has the code.
	Never_Written = 5, // The area of a floor that was never written. This system writes each floor that it defines at once, so another system planted it: it can hold an authorization value that refuses each later read.
	Read_Refused  = 6, // The area of a floor whose read the TPM refuses for its authorization: another system planted it with an authorization value.
}

// floor_state_of_word is the border of a floor state of the trust record
// (Boot_Trust.key_floor_state, version_floor_state): the member, or false
// for a word that names no state. The record reaches a process through the
// boot report of the kernel, so its reader never casts the word.
floor_state_of_word :: proc "contextless" (word: u64) -> (state: Floor_State, ok: bool) {
	for member in Floor_State {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// The TPM floors: indices of the TPM in the range of the owner of the
// registry of the TCG (0x01800000 to 0x01BFFFFF). Each is a field of 64
// bits that only gains bits; the floor is the place of its highest set bit
// plus one (src/md/features/rollback_floors.md). There is one key floor,
// and one version floor for each key number: a system that a stolen key
// signed then raises only the version floor of that key.
KEY_FLOOR_INDEX :: u32(0x0180_6D00) // The lowest key number of a boot program.
// The version floor of the key number n is the index VERSION_FLOOR_BASE_INDEX + n,
// for n from 1 to FLOOR_LIMIT (version_floor_index).
VERSION_FLOOR_BASE_INDEX :: u32(0x0180_6D00)
// The highest number that a floor holds: one bit of the field for each. A
// security version and a key number are 1 to FLOOR_LIMIT.
FLOOR_LIMIT :: 64

// version_floor_index gives the index of the version floor of a key
// number from 1 to FLOOR_LIMIT; 0 for another number.
//
// Example: the key number 2 has its version floor at 0x01806D02.
version_floor_index :: proc "contextless" (key_number: u64) -> u32 {
	if key_number == 0 || key_number > FLOOR_LIMIT {
		return 0
	}
	return VERSION_FLOOR_BASE_INDEX + u32(key_number)
}

// Who verified the system description. A boot program that the firmware
// did not verify can be replaced by anyone who can write the boot volume,
// so the record says which of the two cases holds.
Verifier :: enum u64 {
	None                      = 0, // Nothing verified the system description.
	Boot_Program              = 1, // The boot program verified it. The firmware did not verify the boot program.
	Firmware_And_Boot_Program = 2, // Secure Boot was on: the firmware verified the boot program, then the boot program verified the description.
}

// The kind of the key that signed the system description.
Signing_Key_Kind :: enum u64 {
	None   = 0, // No key: nothing verified the description.
	Test   = 1, // The test signing key: its private key is published, so the system is not trusted.
	Person = 2, // Any other key: the signing key of the publisher of the system.
}

// What the boot program did with the measure of the system into the TPM
// (docs/TRUSTED_BOOT.md, "The measure").
Measure_State :: enum u64 {
	None     = 0, // The boot program did not try.
	Measured = 1, // The register holds the measure; measure_value is its value.
	No_Tpm   = 2, // The firmware has no TPM protocol.
	Refused  = 3, // The firmware refused the extension at each try: the TPM is there, the system is not measured.
	Not_Read = 4, // The extension was done; the read of the register failed.
}

// The register of the measure: PCR 11. The rules of the TCG for PC
// firmware leave PCR 8 to 15 to the operating system; the conventions of
// Linux give PCR 11 to the whole system image that a boot stage measures
// before the kernel starts, and the firmware of the first machine does not
// write it (docs/TRUSTED_BOOT.md, "The measure").
MEASURE_REGISTER :: 11

// A test of the kernel on itself. The kernel does one thing that the
// processor must refuse. For a test of the page tables, the machine stops
// with the report of the fault. For the register trial, the kernel goes on
// after the refusal, says so and stops the machine with the code 0. The
// modus tool builds one boot program for each test.
Self_Test :: enum u64 {
	None             = 0, // No test: a normal boot.
	Stack_Overflow   = 1, // Use more than the kernel stack.
	Write_Code       = 2, // Write to the code of the kernel.
	Write_Code_View  = 3, // Write to the code of the kernel through the direct map.
	Execute_Data     = 4, // Execute the data of the kernel.
	Read_Process     = 5, // Read the memory of a process, outside a copy.
	Execute_Process  = 6, // Execute the code of a process.
	Register_Refused = 7, // Write an address that is not canonical to a register in a register trial.
}

// self_test_of_word is the border of the self test of the boot record
// (Boot_Info.self_test): the member, or false for a word that names no
// test. The kernel stops on such a word: it never runs a test, nor a normal
// boot, that the boot program did not name.
self_test_of_word :: proc "contextless" (word: u64) -> (test: Self_Test, ok: bool) {
	for member in Self_Test {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// physical gives a pointer to physical memory, through the direct map. Only
// the kernel and the boot program, which have the direct map, call it.
//
// Example: `info.physical(boot.memory_ranges, info.Memory_Range)`.
physical :: #force_inline proc "contextless" (address: u64, $T: typeid) -> ^T {
	return (^T)(DIRECT_MAP_BASE + uintptr(address))
}

// physical_slice gives count records of physical memory, through the direct map.
physical_slice :: #force_inline proc "contextless" (address: u64, count: u64, $T: typeid) -> []T {
	return ([^]T)(DIRECT_MAP_BASE + uintptr(address))[:count]
}

// The boot image: the module files that the first process needs, and the
// resources (files that are not modules: the pointer theme files), in one
// block.
//
//   Image_Header
//   Image_Entry, header.count times: the modules
//   Image_Entry, header.resource_count times: the resources
//   the files; each one starts on a page boundary of the image
//
// A reader of modules reads the first table only: a resource is never
// taken for a module.
IMAGE_MAGIC :: u64(0x4547414D49544F42) // The bytes "BOTIMAGE".
IMAGE_NAME_SIZE :: 32 // The bytes of the name of an entry, with zero bytes after the name.

// The first 16 bytes of the boot image. The build tool writes it.
Image_Header :: struct {
	magic:          u64, // `IMAGE_MAGIC`.
	count:          u32, // The modules.
	resource_count: u32, // The resources, after the modules. 0: none.
}

// One file of the boot image: a module or a resource. A reader checks the
// range with `image_entry_bytes` before it reads a byte, and finds a module
// by its hash, never by its name.
//
// Example: the entry of the console is `{name = "console", hash = <BLAKE3 of
// its file>, offset = <a multiple of 4096>, size = <its bytes>}`.
Image_Entry :: struct {
	name:   [IMAGE_NAME_SIZE]u8, // Zero bytes after the name. A name is for a reader; the hash is the identity.
	hash:   [32]u8, // The BLAKE3 hash of the file.
	offset: u64, // From the start of the image.
	size:   u64, // The bytes of the file.
}

// image_tables gives the table of the modules and the table of the
// resources of a boot image. valid is false when the header is wrong or
// the tables do not fit in the image.
image_tables :: proc "contextless" (image: []u8) -> (modules, resources: []Image_Entry, valid: bool) {
	if len(image) < size_of(Image_Header) {
		return
	}
	header := (^Image_Header)(raw_data(image))^
	if header.magic != IMAGE_MAGIC {
		return
	}
	total := int(header.count) + int(header.resource_count)
	if size_of(Image_Header) + total * size_of(Image_Entry) > len(image) {
		return
	}
	all := ([^]Image_Entry)(raw_data(image[size_of(Image_Header):]))[:total]
	return all[:header.count], all[header.count:], true
}

// image_entry_bytes gives the bytes of the file of one entry. valid is
// false when the entry points outside the image.
image_entry_bytes :: proc "contextless" (image: []u8, entry: ^Image_Entry) -> (bytes: []u8, valid: bool) {
	offset, size := entry.offset, entry.size
	if offset > u64(len(image)) || size > u64(len(image)) - offset {
		return nil, false
	}
	return image[offset:][:size], true
}
