package root

import "base:intrinsics"
import "modus:contract/date"
import "modus:contract/settings"
import "modus:support/appearance"
import "modus:support/system"

// The appearance in force at each edge of the rule of the day
// (src/md/features/appearance.md, "Who writes the appearance in force, and
// when"). With the setting `auto`, the appearance changes at 07:00 and at
// 19:00 of the local time, and the program `settings` runs only while its
// window is open. This service runs always and holds both pages: its loop
// has the next edge as one more deadline, and wakes when the date changes.
// It writes the one word of the appearance in force, and only when the rule
// gives another appearance than the page holds.

appearance_date_page: ^date.Page // The date page, mapped read-only in this service; nil: no date page.
appearance_deadline: u64 = system.WAIT_FOREVER // The time of the system of the next edge of the rule.

// appearance_open maps the date page read-only in this service, for the
// rule of the day. With no date page the rule has no date: dark.
appearance_open :: proc "contextless" () {
	if date_memory == 0 {
		return
	}
	address, status := system.memory_map(date_memory, flags = {})
	if status != .Ok {
		system.log_in("programs", .Warning, "root: the date page is not mapped in this service (status ", status, "): the setting appearance auto is dark")
		return
	}
	appearance_date_page = (^date.Page)(address)
}

// appearance_step runs at each turn of the loop, after wait_begin: it
// computes the rule over the pages of now, writes the appearance in force
// when the settings page holds another one, sets the deadline of the next
// edge, and adds the change count of the date page to the wait: a date that
// comes after the boot pass of `settings`, and a new time zone, change the
// rule. The program `date` writes both, and wakes this word for them
// (src/md/features/time_zone.md).
//
// The program `settings` writes the values and their appearance in one
// change, and can write between the read of this service and its store.
// So after its store this service reads the change count again: when it
// moved, it reads the page again and writes the rule of the new values.
// The other writer computes the same rule, so a few turns end it; the
// bound keeps this loop from a writer that changes the page with no end.
appearance_step :: proc "contextless" (wait: ^system.Wait) {
	appearance_deadline = system.WAIT_FOREVER
	if appearance_date_page != nil {
		system.wait_word(wait, &appearance_date_page.change_count, intrinsics.atomic_load_explicit(&appearance_date_page.change_count, .Acquire))
	}
	if settings_page == nil {
		return
	}
	for _ in 0 ..< settings.READ_TRIES {
		choice, ok := settings.read(settings_page)
		if choice.change_count & 1 != 0 {
			return // A writer stopped in a change: the page has the defaults until its next write.
		}
		// A read that gave up with an even count gives the defaults too: the
		// count then moved after the read, as it only grows. This service
		// does not wait on the settings page, so it reads again in this
		// bounded loop.
		if intrinsics.atomic_load_explicit(&settings_page.change_count, .Acquire) != choice.change_count {
			continue
		}
		if !ok {
			return // A page with a word that names no value: no rule is computed from a value that the page does not hold.
		}
		now := system.time()
		moment := appearance.moment_of(appearance_date_page, now)
		setting := choice.appearance
		in_force := appearance.in_force_of(setting, moment)
		appearance_deadline = system.WAIT_FOREVER
		if setting == .Auto && moment.known {
			appearance_deadline = now + u64(appearance.next_edge(moment) - moment.milliseconds)
		}
		if in_force == choice.appearance_in_force {
			return
		}
		buffer: [192]u8
		system.log("root: ", appearance.sentence_write(buffer[:], setting, moment))
		settings.appearance_in_force_write(settings_page, in_force)
		system.word_wake(&settings_page.change_count, 64)
		if intrinsics.atomic_load_explicit(&settings_page.change_count, .Acquire) == choice.change_count {
			return
		}
	}
}
