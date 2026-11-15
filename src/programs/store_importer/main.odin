// A disk program that imports a library module of the store `programs`:
// the test of the import scan (docs/MODULE_CONTRACT.md, "A program from a
// disk").
//
// **What it is for.** Its import names the hash of the module
// `store_library`, which no boot image holds. The root service finds that
// file in the store `programs` of the principal by the hash of its bytes,
// and the loader binds the import slot to it. This program calls the
// export and writes the result.
//
// **Start**: `start_from_disk("store_importer", hash)` in the console, on a
// machine whose data disk holds the store `programs` with this file and the
// file of `store_library`. The modus tool writes that disk for the test
// part `disk_programs`, and prints the hashes.
//
// **Grants**: none by its name, as each disk program.
//
// **What a reader sees.** One line on the log: the result of `triple(14)`
// from the module of the store. It opens no window.
package store_importer

import "modus:support/system"

foreign _ {
	triple :: proc "c" (value: i64) -> i64 ---
}

// The entry of store_importer: it calls the import one time, writes the
// line, then sleeps until it is stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	result := triple(14)
	if result == 42 {
		system.log("store_importer: triple(14) of the module store_library of the store programs gives 42: as it must")
	} else {
		system.log("store_importer: triple(14) gives ", u64(result), ", and 42 is the answer: WRONG")
	}
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}
