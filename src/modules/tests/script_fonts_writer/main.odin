// The writer of the machine test of the mapping of the script font set
// (src/md/features/script_fonts.md, "The chosen form"). The root
// service maps the set read-only into each process that gets the font
// outlines; this process writes one byte of it, the byte that it reads, so
// the set stays whole even if the write passed. The kernel must stop it on
// the page fault, with a stop report whose address is the first byte of
// the set: the scenario reads that address in the line of the kernel.
//
// **Start**: `start("script_fonts_writer")` in the console, on a machine whose
// script font set is mapped. **What a reader sees**: no window;
// "script_fonts_writer: writes the byte at ..." then the line of the kernel
// that stops it on a page fault. A line "script_fonts_writer: WRONG: ..."
// says that no set is mapped, or that the write passed: a fault of the
// root service or of the kernel.
package script_fonts_writer

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import "modus:contract/value_kinds"
import "modus:system"

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if .Script_Fonts not_in fixed_addresses.ranges_mapped(&ctx.values) {
		system.log_fact(.Error, Not_Mapped{})
		system.stop(.Failed)
	}
	place := (^u8)(uintptr(fixed_addresses.SCRIPT_FONTS_ADDRESS))
	system.log_fact(.Info, Writes{address = value_kinds.Hexadecimal_Sixteen_Digits(fixed_addresses.SCRIPT_FONTS_ADDRESS)})
	value := intrinsics.volatile_load(place)
	intrinsics.volatile_store(place, value)
	system.log_fact(.Error, Write_Did_Not_Stop{})
	system.stop(.Failed)
}
