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
// **Grants**: the start grant Start_Policy: a root ring for Start, Stop,
// Machine_Usable and Wire, and the machine parts page, read-only. It asks
// for the wiring that the root service refuses to a start policy from the
// disk (wiring_refusals.odin). It has no row in
// `start_grant_sets`.
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
import "modus:contract/value_kinds"
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
	system.log_fact(.Info, Running{})
	ring_status: system.Status
	requests, ring_status = system.ring_open(ctx.handles[system.GRANT_ROOT])
	if ring_status != .Ok {
		system.log_fact(.Info, Root_Ring_Refused{status = ring_status})
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
		system.log_fact(.Info, Context_Checked{})
	} else {
		system.log_fact(.Info, Wrong_Context{other_handles = u64(other), list_bytes = ctx.values[start_list.VALUE_LIST_SIZE]})
	}
	parts, _, _, page_read := start_list.parts_page_read(rawptr(uintptr(start_list.MACHINE_PARTS_PAGE_ADDRESS)))
	if !page_read {
		system.log_fact(.Info, Parts_Page_Refused{})
	}
	// A start policy never starts a start policy: the root service starts
	// it alone.
	if status, _ := command_call(.Start, "start_policy"); status != .Ok {
		system.log_fact(.Info, Start_Policy_Start_Refused{status = status})
	} else {
		system.log_fact(.Info, Wrong_Start_Policy_Start_Taken{})
	}
	// Its root ring sends Start, Stop, Machine_Usable and Wire only: each command
	// of the console is refused with No_Right, before it runs.
	refused := [4]root_ring.Root_Command{.Start_Policy_Choice, .Start_From_Disk, .Disk_Grant, .Connect}
	taken := 0
	for command in refused {
		if status, _ := command_call(command, "storage"); status != .No_Right {
			system.log_fact(.Info, Wrong_Command_Not_Refused{status = status, command = command_field(root_ring.root_command_names[command])})
			taken += 1
		}
	}
	if taken == 0 {
		system.log_fact(.Info, Commands_Refused{})
	}
	order := ORDER
	for name in order {
		if name != "console" && .Screen not_in parts {
			system.log_fact(.Info, Not_Started_Without_Screen{started_process = value_kinds.module_name_field(name)})
			continue
		}
		status, _ := command_call(.Start, name)
		if status != .Ok {
			system.log_fact(.Info, Start_Refused{status = status, started_process = value_kinds.module_name_field(name)})
			if name == "console" {
				system.stop(.Failed)
			}
			continue
		}
		system.log_fact(.Info, Started{started_process = value_kinds.module_name_field(name)})
	}
	// The root service holds the wiring of a start policy, whatever it
	// sends: this one asks for what a start policy from the disk must not
	// get.
	if wiring_refusals() == 0 {
		system.log_fact(.Info, Wiring_Refused{})
	}
	if status, _ := command_call(.Machine_Usable, ""); status != .Ok {
		system.log_fact(.Info, Machine_Usable_Refused{status = status})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Machine_Is_Usable{})
	for {
		system.sleep(max(u64))
	}
}

// command_call sends one command of the root ring with a name, and waits
// for its completion.
command_call :: proc "contextless" (command: root_ring.Root_Command, name: string) -> (status: system.Status, values: [7]u64) {
	packed := system.name_pack(name)
	return call(command, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0})
}

// call sends one command of the root ring with its values, and waits for
// its completion. One command is in flight, so the ring has room.
call :: proc "contextless" (command: root_ring.Root_Command, arguments: [7]u64) -> (status: system.Status, values: [7]u64) {
	tag := next_tag
	next_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(command), tag = tag, values = arguments}) {
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
