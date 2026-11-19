// A start policy that is not in the boot image: the test of a start policy
// from the disk (src/md/features/start_policy.md, "A start policy from the
// disk").
//
// **What it is for.** Principal 0 chooses it with
// `start_policy_choose("tiny", hash)`, and the next start of the machine
// runs it in place of the default start policy, with the start grant
// Start_Policy only, after the TPM measured it into PCR 12. It holds its
// order in its code, and reads no start list: the root service maps none
// for a start policy from the disk.
//
// **Start**: the root service starts it at the start of the machine, from
// the store `module_files` of principal 0. The modus tool writes it on the
// disk of the test part `start_policy`. No line of the console starts it.
//
// **Grants**: the start grant Start_Policy: a root ring for Start, Stop and
// Machine_Usable, and the machine parts page, read-only. It has no row in
// `process_roles`.
//
// **What a reader sees.** No window. The log has "disk_start_policy: ok",
// the handles of its context, the refusal of a start of the start policy
// of the boot image and of four commands of the console, one line for each
// process that it starts, then
// "disk_start_policy: the console runs: the machine is usable".
package disk_start_policy

import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/start_list"
import "modus:support/system"

// One thread; the working memory pays its root ring, the machine parts
// page and their page tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 32, processes = 1, threads = 1}

// The order of this start policy: the input service and the compositor
// when the machine has a screen, then the console, which makes the machine
// usable.
ORDER :: [3]string{"input", "compositor", "console"}

requests: ring.Ring
next_tag: u32 = 1

// Each stop before Machine_Usable writes its line first and stops with
// Failed: the root service then starts the rescue start policy.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("disk_start_policy: ok, a start policy from the disk: its order is in its code")
	ring_status: system.Status
	requests, ring_status = system.ring_open(ctx.handles[system.GRANT_ROOT])
	if ring_status != .Ok {
		system.log("disk_start_policy: the root ring does not open: status ", ring_status)
		system.stop(.Failed)
	}
	// Its one grant: the root ring and the log, and no window, no store and
	// no right of the machine.
	other := 0
	for handle, index in ctx.handles {
		if handle != 0 && index != system.GRANT_ROOT && index != op.CONTEXT_LOG && index != op.CONTEXT_BUDGET {
			other += 1
		}
	}
	if other == 0 && ctx.values[start_list.VALUE_LIST_SIZE] == 0 {
		system.log("disk_start_policy: the context holds the log, the budget and the root ring, no other handle and no start list: as it must")
	} else {
		system.log("disk_start_policy: the context holds ", u64(other), " other handles and a list of ", ctx.values[start_list.VALUE_LIST_SIZE], " bytes: WRONG")
	}
	parts, _, _, page_read := start_list.parts_page_read(rawptr(uintptr(start_list.MACHINE_PARTS_PAGE_ADDRESS)))
	if !page_read {
		system.log("disk_start_policy: the machine parts page is refused: it starts the console only")
	}
	// A start policy never starts a start policy: the root service starts
	// it alone.
	if status, _ := command_call(.Start, "start_policy"); status != .Ok {
		system.log("disk_start_policy: a start of the start policy of the boot image is refused with the status ", status, ": as it must")
	} else {
		system.log("disk_start_policy: a start of the start policy of the boot image is taken: WRONG")
	}
	// Its root ring sends Start, Stop and Machine_Usable only: each command
	// of the console is refused with No_Right, before it runs.
	refused := [4]root_ring.Root_Command{.Start_Policy_Choice, .Start_From_Disk, .Disk_Grant, .Connect}
	taken := 0
	for command in refused {
		if status, _ := command_call(command, "storage"); status != .No_Right {
			system.log("disk_start_policy: the command ", root_ring.root_command_names[command], " gives the status ", status, ", not No_Right: WRONG")
			taken += 1
		}
	}
	if taken == 0 {
		system.log("disk_start_policy: Start_Policy_Choice, Start_From_Disk, Disk_Grant and Connect are refused with No_Right: as it must")
	}
	order := ORDER
	for name in order {
		if name != "console" && .Screen not_in parts {
			system.log("disk_start_policy: ", name, " is not started: the machine has no screen")
			continue
		}
		status, _ := command_call(.Start, name)
		if status != .Ok {
			system.log("disk_start_policy: cannot start ", name, ": status ", status)
			if name == "console" {
				system.stop(.Failed)
			}
			continue
		}
		system.log("disk_start_policy: started ", name)
	}
	if status, _ := command_call(.Machine_Usable, ""); status != .Ok {
		system.log("disk_start_policy: the root service refused Machine_Usable: status ", status)
		system.stop(.Failed)
	}
	system.log("disk_start_policy: the console runs: the machine is usable")
	for {
		system.sleep(max(u64))
	}
}

// command_call sends one command of the root ring with a name, and waits
// for its completion. One command is in flight, so the ring has room.
command_call :: proc "contextless" (command: root_ring.Root_Command, name: string) -> (status: system.Status, values: [7]u64) {
	packed := system.name_pack(name)
	tag := next_tag
	next_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(command), tag = tag, values = {packed[0], packed[1], packed[2], packed[3], 0, 0, 0}}) {
		return .No_Slot, {}
	}
	for {
		wait := system.wait_begin()
		if answer, received := system.receive(&requests.completions); received {
			if answer.tag != tag {
				continue
			}
			read, refusal := system.status_of_word(answer.kind)
			if refusal.kind != 0 {
				return .Bad_Operation, {}
			}
			return read, answer.values
		}
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait)
	}
}
