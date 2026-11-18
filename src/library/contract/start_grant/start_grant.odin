// The start grants: the list of what the root service gives a program by
// its name, and the name of each one.
//
// The root service decides the start grants of a program
// (`program_roles` in `src/modules/system/root/roles.odin`). The list is a contract because
// a second party reads it: the root service puts the number of a start
// grant in an error record when that grant refuses the debug access to a
// program (errors.Unit.Debug_Access), and the reader of the record writes
// the name of the grant in its sentence (`src/library/support/sentence`). The names have
// one source: the log of the root service and the sentence write the same
// word.
//
// **The name of a start grant** is the name of its member, with its capital
// letters: `Store`, `System_Part`. The site, the guides and the log write
// it so. A name in lower case (`store`, `machine`) is another thing: a
// recorded grant (`system.Root_Grant`), which `grants` shows and `revoke`
// takes in the console. A start grant says what the role of a program
// gives; a recorded grant says which handles the root service gave and can
// end. Several start grants are one recorded grant (`Inspect`, `Stop`,
// `Schedule`, `Events` and `Counters` are rights of the one handle
// `machine`), and a
// start grant such as `Serve` has no recorded grant.
//
// **The number of a start grant** is written beside each member and does
// not change: a new start grant takes the next number, at the end.
//
// See [start grant](term:start-grant).
package start_grant

import "modus:contract/enum_word"

// What a program receives, by name. A program that is not here receives a
// ring to the compositor and nothing else.
Grant :: enum i64 {
	Root_Ring          = 0, // Start and stop programs.
	Inspect            = 1, // The machine, with the right Inspect.
	Stop               = 2, // The machine, with the right Stop.
	Image              = 3, // Read the boot image.
	Log_Records        = 4, // Read the records of the log.
	Serve              = 5, // A service: other programs call its exports through connections.
	Terminal           = 6, // The program has no surface: it writes records to a terminal, and reads keys from it.
	Store              = 7, // A private store in the storage service: a connection to it names the program, with a limit of blocks.
	Acts_For_Principal = 8, // The program acts for the principal of its session: a service shows it what it holds for all callers.
	Data_Disk          = 9, // A block service of the data disk, and its block ring.
	Scratch_Disk       = 10, // A block service of the disk of the measures, and its block ring.
	Replacements       = 11, // Read the replacement table of the machine.
	Replace            = 12, // Change the replacement table of the machine (Root_Command.Replace).
	Network            = 13, // An endpoint in the network service, with the grant of endpoint_of: datagrams, or segments of TCP.
	Network_Device     = 14, // The frame service of the network device and its frame ring, and a control ring from the root service.
	Connect            = 15, // A ring to the root service that serves Connect and Disconnect only, to the services of its role (program_roles in src/modules/system/root/roles.odin).
	Schedule           = 16, // The machine, with the right Schedule: change the scheduling strategy of the machine.
	Settings           = 17, // The settings page with Write (modus:contract/settings): the one writer of the settings of the machine.
	Clock              = 18, // The date page with Write and the two ports of the real-time clock (modus:contract/date): the one writer of the date.
	History_Store      = 19, // A store of its own in the storage service for the line history of the program, apart from its private store (Root_Command.Connect_History).
	Events             = 20, // The machine, with the right Events: give the event table of the machine (kernel events of every program).
	Principals         = 21, // A ring to the root service for Principal_Record, Principal_Unlock and Machine_Key only: the program that keeps the records of the named principals (docs/PRINCIPALS.md).
	Debug_Image        = 22, // The debug image, read-only: the names of the procedures and the source lines of a stop report (src/modules/system/root/debug_image.odin).
	Debugger           = 23, // A ring to the root service for Debug only: the service that debugs a program on behalf of a caller of its connections (Root_Command.Debug).
	Palette            = 24, // The palette provider of the desktop: the entry table with Write and the ring to the compositor (Root_Command.Palette_Provide).
	System_Part        = 25, // A part of the system that the root service starts by itself, with handles that no other grant names: the screen and the input ring (the compositor), a device (a device service), the text of another program (a terminal). No program asks for it and no caller holds it.
	Tpm                = 26, // The ring and the region of the TPM service (modus:contract/tpm_service): seal a key to the measure of the system, and unseal it. The program that keeps the machine key (docs/PRINCIPALS.md).
	Versions_Erase     = 27, // End the versions of an object of its private store, with zeros over their blocks (isolated.CALLER_ERASES_VERSIONS): the program that keeps a secret that an earlier version must not keep (docs/STORAGE.md, "4.8 The erase of versions").
	Counters           = 28, // The machine, with the right Counters: count the events of the processor for the code of its own threads (docs/ARCHITECTURE.md, "The counters of a thread").
	Remote_Clients     = 29, // The client table, read-only (modus:contract/remote, Client_Table), and a Connect for one of its rows that acts for the principal of that row: the program that takes calls from another machine (docs/PRINCIPALS.md, "The client keys of remote").
	Sound_Device       = 30, // The sound service of the sound device and its stream ring (modus:contract/timed_stream): the one program that plays sound (docs/SOUND.md).
}

// The name of each start grant, as the log of the root service and the
// sentence of an error record write it: the name of the member.
@(rodata)
GRANT_NAMES := [Grant]string {
	.Root_Ring          = "Root_Ring",
	.Inspect            = "Inspect",
	.Stop               = "Stop",
	.Image              = "Image",
	.Log_Records        = "Log_Records",
	.Serve              = "Serve",
	.Terminal           = "Terminal",
	.Store              = "Store",
	.Acts_For_Principal = "Acts_For_Principal",
	.Data_Disk          = "Data_Disk",
	.Scratch_Disk       = "Scratch_Disk",
	.Replacements       = "Replacements",
	.Replace            = "Replace",
	.Network            = "Network",
	.Network_Device     = "Network_Device",
	.Connect            = "Connect",
	.Schedule           = "Schedule",
	.Settings           = "Settings",
	.Clock              = "Clock",
	.History_Store      = "History_Store",
	.Events             = "Events",
	.Principals         = "Principals",
	.Debug_Image        = "Debug_Image",
	.Debugger           = "Debugger",
	.Palette            = "Palette",
	.System_Part        = "System_Part",
	.Tpm                = "Tpm",
	.Versions_Erase     = "Versions_Erase",
	.Counters           = "Counters",
	.Remote_Clients     = "Remote_Clients",
	.Sound_Device       = "Sound_Device",
}

// grant_name gives the name of the start grant with a number, and says if
// the number names one. The number comes from an error record, which
// another program wrote, and that program can be of a later build with one
// more start grant: a reader calls this before it writes a name.
//
// Example: `grant_name(7)` is `"Store", true`; `grant_name(99)` is `"",
// false`.
grant_name :: proc "contextless" (number: i64) -> (name: string, known: bool) {
	grant := enum_word.member_of_word(Grant, u64(number)) or_return
	return GRANT_NAMES[grant], true
}
