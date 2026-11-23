package root

// The replacement table of the machine, and who may change it
// (docs/MODULE_CONTRACT.md, "Who may replace a module").
//
// A replacement puts the code of another module into each process that
// imports a module, with all its memory and all its handles. The check of
// the loader proves the descriptions of the exports, not what the code
// does. So this service writes a replacement only for a replacement row of
// the boot image whose signature verifies under the signing key of the
// system: the key that verified the system description. The process with
// the grant Replace names the two modules; it chooses among the rows that
// the key signed, and gives no row of its own.
//
// The check runs at each request, not at the start: a row that does not
// verify costs nothing until it is asked for, and the refusal then names it.

import "modus:contract/call_outcome"
import "modus:contract/replacement_list"
import "internal:root/replacement_rules"
import "internal:root/replacement_signature"
import "modus:contract/root_ring"
import "modus:system"

// replace changes the replacement table of the machine, for a process with
// the grant Replace: where a module imports the module of the name, the
// loaders give the module of entry by of the boot image (from 1). 0
// removes the record. The facts of the state decide each refusal
// (replacement_rules.replace_refusal): a chain, one replacement for one
// import, so that a loader never follows two records, and a pair that no
// row signed by the signing key of the system names. Each refusal writes
// its outcome and its error record in values.
replace :: proc "contextless" (asker: ^Started, name: string, by: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Replace)
	entries := system.image_entries(image)
	from, to: [32]u8
	from_name := ""
	for &entry in entries {
		if system.name_of(entry.name[:]) == name {
			from = entry.hash
			from_name = system.name_of(entry.name[:])
		}
	}
	facts := replacement_rules.Replace_Facts {
		granted       = .Replace in asker.start_grant_set.grants,
		by            = by,
		entry_count   = u64(len(entries)),
		name_in_image = from != {},
	}
	// The facts of a new replacement: the removal of a replacement needs no
	// row, as it gives back the module that the importer names, which the
	// system description lists. The signature is checked only for a sender
	// that may ask.
	if facts.granted && facts.name_in_image && by != 0 && by <= facts.entry_count {
		to = entries[by - 1].hash
		facts.replaces_itself = to == from
		for item in system.replacements_read(replacement_table, &replacement_records) {
			if item.from == to || item.to == from {
				facts.chained = true
			}
		}
		if !facts.replaces_itself {
			facts.decision, facts.problem = replacement_signature.system_decision(replacement_list_bytes(), from, to, trust_boot_report.trust.public_key)
		}
	}
	outcome, refusal, by_signature := replacement_rules.replace_refusal(facts)
	if by_signature {
		reason := replacement_signature.decision_sentences[facts.decision]
		if facts.decision == .List_Not_Valid {
			reason = replacement_list.list_problem_sentences[facts.problem]
		}
		system.log_fact(.Warning, Replacement_Refused{replaced = module_name_field(from_name), replacement = module_name_field(system.name_of(entries[by - 1].name[:])), reason = text_field(reason, 80)})
	}
	if outcome != .Succeeded {
		values^ = refusal
		return outcome
	}
	if written := system.replacements_write(replacement_table, from, to); written != .Ok {
		if written == .No_Slot {
			full_outcome, full_refusal := replacement_rules.table_full_refusal(system.REPLACEMENT_CAPACITY)
			values^ = full_refusal
			return full_outcome
		}
		return kernel_refused(values, kind, written)
	}
	if by == 0 {
		system.log_fact(.Info, Replacement_Ended{replaced = module_name_field(from_name)})
	} else {
		system.log_fact(.Info, Replacement_Made{replacement = module_name_field(system.name_of(entries[by - 1].name[:])), replaced = module_name_field(from_name)})
	}
	return .Succeeded
}

// replacement_list_bytes gives the resource replacement_list of the boot
// image, or nil when it has none, and nil when its bytes do not have the
// hash of its entry (image_entry_give, which names the file on the log):
// a damaged list allows no replacement.
replacement_list_bytes :: proc "contextless" () -> []u8 {
	entry := system.image_resource_find(image, replacement_list.RESOURCE_NAME)
	if entry == nil || !image_entry_give(entry) {
		return nil
	}
	return image[entry.offset:][:entry.size]
}
