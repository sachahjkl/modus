// A library module that no boot image holds: the test of an import of a disk process from the store `module_files` (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// **What it is for.** The module `store_importer` imports it by its hash. The modus tool writes both files in the store `module_files` of the disk of the test part `disk_processes`; the root service finds this file by the hash of its bytes, with no name, and gives it to the loader beside the boot image.
//
// Example, on a machine with that disk: `start_from_disk("store_importer", hash)`; the log gets the line of the root service that names the entry `store_library`, then the line of the process with the result of `triple(14)`.
package store_library

// triple gives three times a number. The process `store_importer` calls it through its import slot, and checks the result.
@(export, link_name = "triple")
triple :: proc "c" (value: i64) -> i64 {
	return 3 * value
}
