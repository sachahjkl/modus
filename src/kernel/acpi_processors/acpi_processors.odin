// The list of the processors in the ACPI table APIC (the MADT of the ACPI
// specification): the kernel reads it at its start to find the processors
// that it starts. It is a kernel part: the firmware writes the table, and
// the kernel alone compiles in its reader. The reader is pure: it reads the bytes of the table and gives identifiers, so
// a host test and a fuzz target read the bytes that the kernel reads
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value").
//
// This package allocates no memory and calls no kernel operation.
package acpi_processors

import "modus:contract/byte_order"

// The table APIC: the ACPI header of 36 bytes, the address of the local
// controllers (4 bytes), the flags (4 bytes), then the entries. Each entry
// starts with its kind (1 byte) and its length (1 byte), the two bytes
// included.
ENTRIES_START :: 44
ENTRY_HEADER_SIZE :: 2

// The kinds of an entry that name a processor.
ENTRY_LOCAL_CONTROLLER :: 0 // A processor whose controller has an identifier of 8 bits.
ENTRY_LOCAL_CONTROLLER_EXTENDED :: 9 // A processor whose controller has an identifier of 32 bits (x2APIC).

// The bytes of each entry that names a processor, and the places of its
// fields. A shorter entry of one of these kinds names no processor.
LOCAL_CONTROLLER_SIZE :: 8 // The kind, the length, the processor of ACPI, the identifier (1 byte), the flags (4 bytes).
LOCAL_CONTROLLER_IDENTIFIER :: 3
LOCAL_CONTROLLER_FLAGS :: 4
LOCAL_CONTROLLER_EXTENDED_SIZE :: 16 // The kind, the length, 2 reserved bytes, the identifier (4 bytes), the flags (4 bytes), the processor of ACPI (4 bytes).
LOCAL_CONTROLLER_EXTENDED_IDENTIFIER :: 4
LOCAL_CONTROLLER_EXTENDED_FLAGS :: 8

// The flag Enabled of an entry: the processor can run. A processor without
// it is not started.
FLAG_ENABLED :: u32(1)

// processors_read writes the identifier of each processor that the table
// lists as usable into `identifiers`, in the order of the table, and gives
// their count: at most len(identifiers). An entry of an identifier of 32
// bits counts only when the controller of the processor that reads is in
// the mode of such identifiers (`extended_identifiers`): the other mode
// cannot name it. The walk stops at an entry whose length is below its
// header or past the end of the table. A table shorter than ENTRIES_START
// gives 0 and writes nothing.
processors_read :: proc "contextless" (table: []u8, extended_identifiers: bool, identifiers: []u32) -> (count: int) {
	offset := ENTRIES_START
	for offset + ENTRY_HEADER_SIZE <= len(table) {
		kind := table[offset]
		length := int(table[offset + 1])
		if length < ENTRY_HEADER_SIZE || length > len(table) - offset {
			break
		}
		identifier, flags: u32
		switch {
		case kind == ENTRY_LOCAL_CONTROLLER && length >= LOCAL_CONTROLLER_SIZE:
			identifier = u32(table[offset + LOCAL_CONTROLLER_IDENTIFIER])
			flags = byte_order.read_u32_little_endian(table, offset + LOCAL_CONTROLLER_FLAGS)
		case kind == ENTRY_LOCAL_CONTROLLER_EXTENDED && length >= LOCAL_CONTROLLER_EXTENDED_SIZE && extended_identifiers:
			identifier = byte_order.read_u32_little_endian(table, offset + LOCAL_CONTROLLER_EXTENDED_IDENTIFIER)
			flags = byte_order.read_u32_little_endian(table, offset + LOCAL_CONTROLLER_EXTENDED_FLAGS)
		}
		if flags & FLAG_ENABLED != 0 && count < len(identifiers) {
			identifiers[count] = identifier
			count += 1
		}
		offset += length
	}
	return count
}
