package root

// The replacement table of the machine, and who may change it
// (docs/MODULE_CONTRACT.md, "Who may replace a module").
//
// A replacement puts the code of another module into each program that
// imports a module, with all its memory and all its handles. The check of
// the loader proves the descriptions of the exports, not what the code
// does. So this service writes a replacement only for a replacement row of
// the boot image whose signature verifies under the signing key of the
// system: the key that verified the system description. The program with
// the role Replace names the two modules; it chooses among the rows that
// the key signed, and gives no row of its own.
//
// The check runs at each request, not at the start: a row that does not
// verify costs nothing until it is asked for, and the refusal then names it.

import "modus:contract/errors"
import "modus:contract/replacement_list"
import "modus:support/replacement_signature"
import "modus:support/system"

// replace changes the replacement table of the machine, for a program with
// the role Replace: where a module imports the module `name`, the loaders
// give the module of entry `by` of the boot image (from 1). 0 removes the
// record. It writes the error record of a refusal in values.
replace :: proc "contextless" (asker: ^Started, name: string, by: u64, values: ^[7]u64) -> system.Status {
	status, decision := replacement_table_change(asker, name, by)
	replace_command := u32(system.Root_Command.Replace)
	switch {
	case status == .Ok:
	case decision == .No_Row || decision == .No_List:
		values^ = errors.ring_fail(replace_command, .Absent, .Records, 2, i64(by))
	case decision == .Not_Authentic:
		values^ = errors.ring_fail(replace_command, .Not_Authentic, .None, 2, i64(by))
	case decision == .List_Not_Valid:
		values^ = errors.ring_fail(replace_command, .Refused, .None, 2, i64(by), 0, i64(status))
	case:
		values^ = refusal(.Replace, name, by, status)
	}
	return status
}

// replacement_table_change does the work of replace. It refuses a chain:
// one replacement for one import, so a loader never follows two records.
// Then it refuses a pair that no row signed by the signing key of the
// system names. decision is Accepted for every other result.
replacement_table_change :: proc "contextless" (asker: ^Started, name: string, by: u64) -> (status: system.Status, decision: replacement_signature.Decision) {
	if .Replace not_in grants_of(system.name_of(asker.name[:])) {
		return .No_Right, .Accepted
	}
	entries := system.image_entries(image)
	from, to: [32]u8
	from_name := ""
	for &entry in entries {
		if system.name_of(entry.name[:]) == name {
			from = entry.hash
			from_name = system.name_of(entry.name[:])
		}
	}
	if from == {} || by > u64(len(entries)) {
		return .Bad_Handle, .Accepted
	}
	if by != 0 {
		to = entries[by - 1].hash
		if to == from {
			return .Bad_Operation, .Accepted
		}
		for item in system.replacements_read(replacement_table, &replacement_records) {
			if item.from == to || item.to == from {
				return .Bad_State, .Accepted
			}
		}
		// The removal of a replacement needs no row: it gives back the
		// module that the importer names, which the system description
		// lists. A new replacement needs one.
		problem: replacement_list.List_Problem
		decision, problem = replacement_signature.system_decision(replacement_list_bytes(), from, to, trust_boot_report.trust.public_key)
		if decision != .Accepted {
			reason := replacement_signature.decision_sentences[decision]
			if decision == .List_Not_Valid {
				reason = replacement_list.list_problem_sentences[problem]
			}
			system.log_in("programs", .Warning, "root: refused the replacement of ", system.Module_Name{from_name}, " by ", system.Module_Name{system.name_of(entries[by - 1].name[:])}, ": ", reason)
			return .No_Right, decision
		}
	}
	if written := system.replacements_write(replacement_table, from, to); written != .Ok {
		return written, .Accepted
	}
	if by == 0 {
		system.log_in("programs", .Info, "root: no replacement of ", system.Module_Name{from_name})
	} else {
		system.log_in("programs", .Info, "root: ", system.Module_Name{system.name_of(entries[by - 1].name[:])}, " replaces ", system.Module_Name{from_name}, " in each load that follows")
	}
	return .Ok, .Accepted
}

// replacement_list_bytes gives the resource replacement_list of the boot
// image, or nil when it has none. The check of the boot image at the start
// compared its hash with the system description, and no program writes
// the pages of the boot image.
replacement_list_bytes :: proc "contextless" () -> []u8 {
	entry := system.image_resource_find(image, replacement_list.RESOURCE_NAME)
	if entry == nil {
		return nil
	}
	return image[entry.offset:][:entry.size]
}
