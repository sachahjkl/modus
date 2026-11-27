// The writer of the machine test of the mapping of the script font set
// (src/md/features/script_fonts.md, "The chosen form"). The storage service
// serves the verified set read-only at "fonts/script_fonts"; this process maps
// it through storage.map_object and writes one byte of it, the byte that it
// reads, so the set stays whole even if the write passed. The kernel must stop
// it on the page fault, with a stop report whose address is the first byte of
// the mapped set.
//
// **Start**: `start("script_fonts_writer")` in the console, on a machine whose
// script font set is published. **What a reader sees**: no window;
// "script_fonts_writer: writes the byte at ..." then the line of the kernel
// that stops it on a page fault. A line "script_fonts_writer: WRONG: ..."
// says that no set was mapped, or that the write passed: a fault of the
// storage service, the root service, or the kernel.
package script_fonts_writer

import "base:intrinsics"
import "modus:contract/font_outlines"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:system"

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	client, opened := storage.open_of_handles(
		ctx.handles[storage.GRANT_RING],
		ctx.handles[storage.GRANT_REGION],
		ctx.handles[storage.GRANT_SERVICE],
		ctx.values[storage.VALUE_FILE_SIZE],
	)
	if !opened {
		system.log_fact(.Error, Not_Mapped{})
		system.stop(.Failed)
	}
	mapped, _, status, _ := storage.map_object(&client, font_outlines.SCRIPT_FONTS_OBJECT_PATH)
	storage.close(&client)
	if status != .Ok || len(mapped.bytes) == 0 {
		system.log_fact(.Error, Not_Mapped{})
		system.stop(.Failed)
	}
	address := u64(uintptr(raw_data(mapped.bytes)))
	place := (^u8)(uintptr(address))
	system.log_fact(.Info, Writes{address = value_kinds.Hexadecimal_Sixteen_Digits(address)})
	value := intrinsics.volatile_load(place)
	intrinsics.volatile_store(place, value)
	system.log_fact(.Error, Write_Did_Not_Stop{})
	system.stop(.Failed)
}
