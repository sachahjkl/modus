package output

// The rule of an asker for one end of a wiring
// (src/md/features/module_outputs.md, "The wiring and its rights"). The
// root service reads the facts from its tables, and this rule decides, so
// a host test reaches each refusal: a machine test cannot make one of them.
// An asker holds a process handle that it can lend only for a process
// that it started, so the machine never shows a lent process that the
// asker did not start.

// What the root service knows of one end and of its asker.
End_Facts :: struct {
	// Started: the asker asked for the start of the process.
	started_by_asker:          bool,
	// Started: the asker is the start policy, and the start policy asked
	// for the start of the process.
	asker_is_start_policy:     bool,
	started_by_start_policy:   bool,
	// Connected: the asker holds the grant to act for the principal.
	asker_acts_for_principal:  bool,
	// Connected: the process serves calls.
	process_is_a_service:      bool,
	// Connected: the asker holds a connection to the process that is not
	// its history store and not one of a row of the client table.
	asker_holds_a_connection:  bool,
}

// start_policy_row_allowed gives whether a holder of the grant
// Start_Policy can ask for a row (src/md/features/module_outputs.md, "The
// decisions of the wiring rows"): only the row of a start list, a writer
// that is the child of its Start and a reader that it started. So a start
// policy reads no stream, as the Asker, and wires no stream of a process
// that runs, as the writer of a Wire: its handle of each process that it
// starts has Give, and a start policy from the disk writes its own list
// page. A Wire of a start policy is then only the list of no row that
// gives back its lent numbers, which the border refuses before this rule.
// field: the end that the rule refuses, Writer_End or Reader_End.
start_policy_row_allowed :: proc "contextless" (form: Wiring_List_Form, writer_end: Wiring_End, reader_end: Wiring_End) -> (field: Wiring_Field, allowed: bool) {
	if form != .Start || writer_end != .Child {
		return .Writer_End, false
	}
	if reader_end != .Started {
		return .Reader_End, false
	}
	return .Whole, true
}

// wiring_end_allowed gives whether an asker can name a process as one end:
// the child of its start and the asker itself always; a Started end a
// process whose start it asked for, or one that the start policy asked for
// when the asker is the start policy; a Connected end a service to which it
// holds a plain connection, when it acts for the principal.
wiring_end_allowed :: proc "contextless" (end: Wiring_End, facts: End_Facts) -> bool {
	switch end {
	case .Child, .Asker:
		return true
	case .Started:
		return facts.started_by_asker || (facts.asker_is_start_policy && facts.started_by_start_policy)
	case .Connected:
		return facts.asker_acts_for_principal && facts.process_is_a_service && facts.asker_holds_a_connection
	case .None:
	}
	return false
}
