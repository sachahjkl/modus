package build

import "core:testing"

// A reader that follows the tables of the volume, written apart from the
// encoder: it finds a file by its path and gives its bytes.
@(private = "file")
volume_read :: proc(image: []u8, path: string) -> (data: []u8, ok: bool) {
	get :: proc(image: []u8, offset: int, size: int) -> (value: u32) {
		for i in 0 ..< size {
			value |= u32(image[offset + i]) << uint(8 * i)
		}
		return value
	}
	sector := int(get(image, 11, 2))
	reserved := int(get(image, 14, 2))
	first_data := reserved + int(image[16]) * int(get(image, 36, 4))
	cluster := get(image, 44, 4)
	rest := path
	for {
		name := rest
		last := true
		for i in 0 ..< len(rest) {
			if rest[i] == '/' {
				name, rest, last = rest[:i], rest[i + 1:], false
				break
			}
		}
		short := volume_name(name) or_return
		found := false
		size: u32
		for entry in 0 ..< sector / 32 {
			offset := (first_data + int(cluster) - 2) * sector + entry * 32
			if string(image[offset:][:11]) == string(short[:]) {
				cluster = get(image, offset + 20, 2) << 16 | get(image, offset + 26, 2)
				size = get(image, offset + 28, 4)
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
		if !last {
			continue
		}
		out := make([dynamic]u8, context.temp_allocator)
		for len(out) < int(size) {
			if cluster < 2 || cluster >= 0x0FFF_FFF8 {
				return nil, false
			}
			append(&out, ..image[(first_data + int(cluster) - 2) * sector:][:sector])
			cluster = get(image, reserved * sector + int(cluster) * 4, 4)
		}
		return out[:size], true
	}
}

@(test)
volume_round_trip :: proc(t: ^testing.T) {
	large := make([]u8, 700_001, context.temp_allocator)
	for &value, index in large {
		value = u8(index * 31 >> 3)
	}
	files := [?]Volume_File {
		{path = "EFI/BOOT/BOOTX64.EFI", data = large},
		{path = "EFI/BOOT/SMALL.TXT", data = {1, 2, 3}},
		{path = "EFI/EMPTY", data = nil},
		{path = "ROOT.BIN", data = large[:513]},
	}
	image, ok := volume_encode(files[:], context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(image), VOLUME_SECTORS_LEAST * VOLUME_SECTOR)
	testing.expect_value(t, image[510], 0x55)
	testing.expect_value(t, image[511], 0xAA)
	for file in files {
		data, found := volume_read(image, file.path)
		testing.expect(t, found, file.path)
		testing.expect_value(t, len(data), len(file.data))
		testing.expect(t, string(data) == string(file.data), file.path)
	}
	_, missing := volume_read(image, "EFI/BOOT/NONE.EFI")
	testing.expect(t, !missing)
}

// A volume sized to its files: files that fill the least volume exactly
// keep its layout; one byte and one sector more give a larger volume, whose
// file reads back whole; and two files that together pass the least
// volume, as a boot program and a debug image do.
@(test)
volume_grows_with_its_files :: proc(t: ^testing.T) {
	least := Volume_Layout{sectors = VOLUME_SECTORS_LEAST, table_sectors = VOLUME_TABLE_SECTORS_LEAST}
	// The root folder takes one cluster.
	fill := (volume_clusters_of(least) - 1) * VOLUME_SECTOR
	full := make([]u8, fill + VOLUME_SECTOR, context.temp_allocator)
	for &value, index in full {
		value = u8(index * 7 >> 2)
	}
	exact, exact_ok := volume_encode({{path = "FULL.BIN", data = full[:fill]}}, context.temp_allocator)
	testing.expect(t, exact_ok)
	testing.expect_value(t, len(exact), VOLUME_SECTORS_LEAST * VOLUME_SECTOR)
	for size in ([2]int{fill + 1, fill + VOLUME_SECTOR}) {
		image, ok := volume_encode({{path = "FULL.BIN", data = full[:size]}}, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect(t, len(image) > VOLUME_SECTORS_LEAST * VOLUME_SECTOR, "a volume past the least grows")
		data, found := volume_read(image, "FULL.BIN")
		testing.expect(t, found && string(data) == string(full[:size]), "the file of a larger volume reads back whole")
	}
	twice := make([]u8, 2 * fill, context.temp_allocator)
	twice[len(twice) - 1] = 0xA5
	files := [2]Volume_File{{path = "EFI/BOOT/BOOTX64.EFI", data = twice}, {path = "DEBUG.IMG", data = full}}
	image, ok := volume_encode(files[:], context.temp_allocator)
	testing.expect(t, ok)
	for file in files {
		data, found := volume_read(image, file.path)
		testing.expect(t, found && string(data) == string(file.data), file.path)
	}
}

@(test)
volume_refuses_bad_names :: proc(t: ^testing.T) {
	for path in ([]string{"lower.efi", "NAMETOOLONG.EFI", "A.LONG", "EFI/BO OT/A", ""}) {
		_, ok := volume_encode({{path = path}}, context.temp_allocator)
		testing.expect(t, !ok, path)
	}
}
