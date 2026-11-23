package build

import "core:strings"

// The boot volume: a FAT32 file system in a file, with no partition table.
// The firmware reads the boot program from it. The tool writes the volume
// itself: the machine then has a plain disk, and no third-party program
// takes part.
//
// Layout: 32 reserved sectors, two tables, then the clusters. A cluster is
// one sector. A folder is one cluster: at most 16 entries. The size of the
// volume is computed from its files (volume_layout_of): at least
// VOLUME_SECTORS_LEAST, and more when the files need more, so a boot image
// and a debug image of any size fit.

VOLUME_SECTOR :: 512 // Format property: the sector of the disk.
// Format property: FAT32 needs at least 65525 clusters. 64 MiB holds them
// with its tables, and a volume of small files keeps this layout.
VOLUME_SECTORS_LEAST :: 131072
VOLUME_TABLE_SECTORS_LEAST :: 1024 // The tables of VOLUME_SECTORS_LEAST: 128 entries in a sector, one for each cluster.
VOLUME_TABLE_ENTRIES_OF_A_SECTOR :: VOLUME_SECTOR / 4 // Format property: an entry of FAT32 has 4 bytes.
VOLUME_RESERVED :: 32
VOLUME_TABLES :: 2
VOLUME_FIRST_CLUSTER :: 2
VOLUME_FOLDER_ENTRIES :: VOLUME_SECTOR / 32
VOLUME_CHAIN_END :: 0x0FFF_FFFF
VOLUME_ATTRIBUTE_FOLDER :: 0x10
VOLUME_ATTRIBUTE_FILE :: 0x20
VOLUME_DATE :: 0x0021 // 1980-01-01: the volume does not depend on the time of the build.

Volume_File :: struct {
	path: string, // Names in capitals, 8 characters and 3 for the extension, with '/' between them.
	data: []u8,
}

@(private = "file")
Folder :: struct {
	path:    string,
	cluster: u32,
	count:   int,
}

@(private = "file")
put :: proc(image: []u8, offset: int, value: u64, size: int) {
	for i in 0 ..< size {
		image[offset + i] = u8(value >> uint(8 * i))
	}
}

// volume_name gives the 11 bytes of a name in a folder entry.
volume_name :: proc(name: string) -> (short: [11]u8, ok: bool) {
	short = ' '
	base, extension := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		base, extension = name[:dot], name[dot + 1:]
	}
	if len(base) == 0 || len(base) > 8 || len(extension) > 3 {
		return short, false
	}
	for part, start in ([2]string{base, extension}) {
		for i in 0 ..< len(part) {
			character := part[i]
			switch character {
			case 'A' ..= 'Z', '0' ..= '9', '_', '-':
				short[start * 8 + i] = character
			case:
				return short, false
			}
		}
	}
	return short, true
}

// The sectors of a volume and of each of its tables.
Volume_Layout :: struct {
	sectors:       int,
	table_sectors: int,
}

// volume_layout_of gives the layout of a volume that holds the files: the
// layout of VOLUME_SECTORS_LEAST when they fit it, else the clusters that
// they need, with one folder for each slash of each path, and the tables of
// those clusters.
volume_layout_of :: proc(files: []Volume_File) -> Volume_Layout {
	clusters := 1 // The root folder.
	for file in files {
		clusters += strings.count(file.path, "/") + (len(file.data) + VOLUME_SECTOR - 1) / VOLUME_SECTOR
	}
	least := Volume_Layout{sectors = VOLUME_SECTORS_LEAST, table_sectors = VOLUME_TABLE_SECTORS_LEAST}
	if clusters <= volume_clusters_of(least) {
		return least
	}
	// The tables never shrink below those of the least volume, so a volume
	// that holds more clusters is always larger.
	table_sectors := max((clusters + VOLUME_FIRST_CLUSTER + VOLUME_TABLE_ENTRIES_OF_A_SECTOR - 1) / VOLUME_TABLE_ENTRIES_OF_A_SECTOR, VOLUME_TABLE_SECTORS_LEAST)
	return {sectors = VOLUME_RESERVED + VOLUME_TABLES * table_sectors + clusters, table_sectors = table_sectors}
}

// volume_clusters_of gives the clusters of the data of a layout.
volume_clusters_of :: proc(layout: Volume_Layout) -> int {
	return layout.sectors - VOLUME_RESERVED - VOLUME_TABLES * layout.table_sectors
}

volume_cluster_offset :: proc(layout: Volume_Layout, cluster: u32) -> int {
	return (VOLUME_RESERVED + VOLUME_TABLES * layout.table_sectors + int(cluster) - VOLUME_FIRST_CLUSTER) * VOLUME_SECTOR
}

// volume_encode gives the bytes of a volume that holds the files.
volume_encode :: proc(files: []Volume_File, allocator := context.allocator) -> (image: []u8, ok: bool) {
	layout := volume_layout_of(files)
	image = make([]u8, layout.sectors * VOLUME_SECTOR, allocator)
	next: u32 = VOLUME_FIRST_CLUSTER
	limit := u32(volume_clusters_of(layout)) + VOLUME_FIRST_CLUSTER

	table_set :: proc(image: []u8, layout: Volume_Layout, cluster: u32, value: u32) {
		for table in 0 ..< VOLUME_TABLES {
			put(image, (VOLUME_RESERVED + table * layout.table_sectors) * VOLUME_SECTOR + int(cluster) * 4, u64(value), 4)
		}
	}
	// allocate takes a run of clusters and links them.
	allocate :: proc(image: []u8, layout: Volume_Layout, next: ^u32, limit: u32, count: u32) -> (first: u32, ok: bool) {
		if count == 0 {
			return 0, true
		}
		if limit - next^ < count {
			return 0, false
		}
		first = next^
		for i in 0 ..< count {
			table_set(image, layout, first + i, i + 1 == count ? VOLUME_CHAIN_END : first + i + 1)
		}
		next^ += count
		return first, true
	}
	entry_add :: proc(image: []u8, layout: Volume_Layout, folder: ^Folder, short: [11]u8, attribute: u8, cluster: u32, size: int) -> bool {
		if folder.count == VOLUME_FOLDER_ENTRIES {
			return false
		}
		offset := volume_cluster_offset(layout, folder.cluster) + folder.count * 32
		short := short
		copy(image[offset:], short[:])
		image[offset + 11] = attribute
		put(image, offset + 16, VOLUME_DATE, 2) // Creation.
		put(image, offset + 18, VOLUME_DATE, 2) // Last access.
		put(image, offset + 20, u64(cluster >> 16), 2)
		put(image, offset + 24, VOLUME_DATE, 2) // Last write.
		put(image, offset + 26, u64(cluster & 0xFFFF), 2)
		put(image, offset + 28, u64(size), 4)
		folder.count += 1
		return true
	}

	// The boot sector, and its copy at sector 6.
	for sector in ([2]int{0, 6}) {
		boot := image[sector * VOLUME_SECTOR:][:VOLUME_SECTOR]
		copy(boot, []u8{0xEB, 0x58, 0x90})
		copy(boot[3:], "KERNEL  ")
		put(boot, 11, VOLUME_SECTOR, 2)
		boot[13] = 1 // Sectors in a cluster.
		put(boot, 14, VOLUME_RESERVED, 2)
		boot[16] = VOLUME_TABLES
		boot[21] = 0xF8 // A fixed disk.
		put(boot, 24, 63, 2)
		put(boot, 26, 255, 2)
		put(boot, 32, u64(layout.sectors), 4)
		put(boot, 36, u64(layout.table_sectors), 4)
		put(boot, 44, VOLUME_FIRST_CLUSTER, 4) // The root folder.
		put(boot, 48, 1, 2) // The information sector.
		put(boot, 50, 6, 2) // The copy of the boot sector.
		boot[64] = 0x80
		boot[66] = 0x29
		put(boot, 67, 0x4B45_524E, 4)
		copy(boot[71:], "KERNEL     ")
		copy(boot[82:], "FAT32   ")
		put(boot, 510, 0xAA55, 2)
		// The information sector: the free count and the next free cluster are not known.
		information := image[(sector + 1) * VOLUME_SECTOR:][:VOLUME_SECTOR]
		put(information, 0, 0x4161_5252, 4)
		put(information, 484, 0x6141_7272, 4)
		put(information, 488, 0xFFFF_FFFF, 4)
		put(information, 492, 0xFFFF_FFFF, 4)
		put(information, 508, 0xAA55_0000, 4)
	}
	table_set(image, layout, 0, 0x0FFF_FFF8)
	table_set(image, layout, 1, VOLUME_CHAIN_END)

	folders := make([dynamic]Folder, context.temp_allocator)
	root, _ := allocate(image, layout, &next, limit, 1)
	append(&folders, Folder{cluster = root})

	for file in files {
		parent := 0
		rest := file.path
		for {
			slash := strings.index_byte(rest, '/')
			if slash < 0 {
				break
			}
			path := file.path[:len(file.path) - len(rest) + slash]
			found := -1
			for folder, index in folders {
				if folder.path == path {
					found = index
				}
			}
			if found < 0 {
				short := volume_name(rest[:slash]) or_return
				cluster := allocate(image, layout, &next, limit, 1) or_return
				entry_add(image, layout, &folders[parent], short, VOLUME_ATTRIBUTE_FOLDER, cluster, 0) or_return
				folder := Folder{path = path, cluster = cluster}
				// The two first entries of a folder: itself, and its parent. 0 names the root.
				dot: [11]u8 = ' '
				dot[0] = '.'
				entry_add(image, layout, &folder, dot, VOLUME_ATTRIBUTE_FOLDER, cluster, 0)
				dot[1] = '.'
				entry_add(image, layout, &folder, dot, VOLUME_ATTRIBUTE_FOLDER, parent == 0 ? 0 : folders[parent].cluster, 0)
				append(&folders, folder)
				found = len(folders) - 1
			}
			parent = found
			rest = rest[slash + 1:]
		}
		short := volume_name(rest) or_return
		cluster := allocate(image, layout, &next, limit, u32((len(file.data) + VOLUME_SECTOR - 1) / VOLUME_SECTOR)) or_return
		entry_add(image, layout, &folders[parent], short, VOLUME_ATTRIBUTE_FILE, cluster, len(file.data)) or_return
		if cluster != 0 {
			copy(image[volume_cluster_offset(layout, cluster):], file.data)
		}
	}
	return image, true
}
