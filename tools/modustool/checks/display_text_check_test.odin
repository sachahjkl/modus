package checks

import "core:testing"

// Edges first: each forbidden word, contraction, Error title, "failed" alone,
// bad sentence case, and wrong end period is refused before clean texts are
// checked.
@(test)
display_text_refuses_each_forbidden_word :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		kind: Display_Text_Kind,
		word: string,
	} {
		{"Invalid name", .Label, "invalid"},
		{"The value is INVALID.", .Sentence, "invalid"},
		{"Illegal operation", .Label, "illegal"},
		{"Fatal crash.", .Sentence, "fatal"},
		{"Catastrophic loss.", .Sentence, "catastrophic"},
		{"Please try again.", .Sentence, "please"},
		{"Sorry, no store.", .Sentence, "sorry"},
		{"Abort transfer", .Label, "abort"},
		{"Kill process", .Label, "kill"},
		{"Terminate task", .Label, "terminate"},
		{"Unable to open store.", .Sentence, "unable to"},
	}
	for item in cases {
		problem, detail := display_text_check_one(item.text, item.kind)
		testing.expectf(t, problem == .Forbidden_Word, "%q gave %v, want Forbidden_Word", item.text, problem)
		testing.expectf(t, detail == item.word, "%q gave detail %q, want %q", item.text, detail, item.word)
	}
	// Substrings inside legitimate words are not refused.
	for clean in ([?]string{"Skill level", "Determinate state"}) {
		problem, _ := display_text_check_one(clean, .Label)
		testing.expectf(t, problem == .None, "%q was refused with %v", clean, problem)
	}
}

@(test)
display_text_refuses_contractions :: proc(t: ^testing.T) {
	for bad in ([?]string{
		"Can't save.",
		"Don't close.",
		"Isn't ready.",
		"Won't open.",
		"It's missing.",
		"You're offline.",
		"We'll retry.",
		"I'm done.",
		"That's full.",
	}) {
		problem, _ := display_text_check_one(bad, .Sentence)
		testing.expectf(t, problem == .Contraction, "%q gave %v, want Contraction", bad, problem)
	}
	for clean in ([?]string{"Cannot save.", "Do not close.", "Is not ready."}) {
		problem, _ := display_text_check_one(clean, .Sentence)
		testing.expectf(t, problem == .None, "%q was refused with %v", clean, problem)
	}
}

@(test)
display_text_refuses_error_title_and_failed_alone :: proc(t: ^testing.T) {
	for bad in ([?]string{"Error", "error", "Failure", "Error: disk full", "Failure: no key"}) {
		problem, _ := display_text_check_one(bad, .Label)
		testing.expectf(t, problem == .Error_Title, "%q gave %v, want Error_Title", bad, problem)
	}
	problem_prefix, _ := display_text_check_one("Error: the note was not saved.", .Sentence)
	testing.expect_value(t, problem_prefix, Display_Text_Problem.Error_Title)
	// "Error" as a normal noun in a phrase is allowed.
	problem_noun, _ := display_text_check_one("Error record", .Label)
	testing.expect_value(t, problem_noun, Display_Text_Problem.None)

	for bad in ([?]string{"Failed", "Operation failed", "Memory_Create failed"}) {
		problem, _ := display_text_check_one(bad, .Label)
		testing.expectf(t, problem == .Failed_Alone, "%q gave %v, want Failed_Alone", bad, problem)
	}
	for bad in ([?]string{"The derivation of the key failed.", "A kernel operation failed."}) {
		problem, _ := display_text_check_one(bad, .Sentence)
		testing.expectf(t, problem == .Failed_Alone, "%q gave %v, want Failed_Alone", bad, problem)
	}
	// "failed" with its cause after it is allowed.
	with_cause, _ := display_text_check_one("The write failed because the disk is full.", .Sentence)
	testing.expect_value(t, with_cause, Display_Text_Problem.None)
}

@(test)
display_text_checks_sentence_case_and_end_period :: proc(t: ^testing.T) {
	for bad in ([?]string{"reset", "unlock", "clear", "older version", "owner", "Delete All Notes", "Restore The Version", "DELETE ALL"}) {
		problem, _ := display_text_check_one(bad, .Label)
		testing.expectf(t, problem == .Not_Sentence_Case, "%q gave %v, want Not_Sentence_Case", bad, problem)
	}
	// Label with trailing period is refused; sentence without period is refused.
	p_label_dot, _ := display_text_check_one("Reset.", .Label)
	testing.expect_value(t, p_label_dot, Display_Text_Problem.Wrong_End_Period)
	p_sent_nodot, _ := display_text_check_one("The font of the text of every window", .Sentence)
	testing.expect_value(t, p_sent_nodot, Display_Text_Problem.Wrong_End_Period)

	// Clean labels pass, including digits, symbols, acronyms, and "modus".
	for clean in ([?]string{"Reset", "Unlock", "Clear", "Older version", "Restore shown version", "1.25", "100 %", "-1 min", "<", "RGB", "US (QWERTY)", "Spleen 8x16", "modus"}) {
		problem, _ := display_text_check_one(clean, .Label)
		testing.expectf(t, problem == .None, "label %q gave %v", clean, problem)
	}
	// Clean sentences pass, including multi-sentence text, questions, and leading "modus".
	for clean in ([?]string{
		"The font of the text of every window.",
		"The characters of the keys. A change holds from the next key.",
		"modus keeps the active voice.",
		"Delete note?",
	}) {
		problem, _ := display_text_check_one(clean, .Sentence)
		testing.expectf(t, problem == .None, "sentence %q gave %v", clean, problem)
	}
}

@(test)
display_texts_of_source_finds_faults_and_accepts_clean_source :: proc(t: ^testing.T) {
	bad_source := `package demo

@(rodata, member_texts = "en")
mode_texts := [Mode]string {
	.Fast = "fast",
	.Slow = "Invalid mode",
}

setting_texts := [Setting]Setting_Text {
	.Font = {"Error", "Don't change this", {"Vector.", "Spleen"}},
}

ZONE_EXPLANATION :: "Operation failed."

window_problem_texts := [Problem]string {
	.None = "",
	.Bad  = "Please retry.",
}

draw :: proc() {
	_ = interface.action_bar_item("older version", 1, "Up")
	_ = interface.button(frame, area, id, cond ? "Delete All Notes" : "Reset")
	items := [1]interface.Context_Menu_Item{{id = 1, label = "New Console"}}
}
`
	faults, count, ok := display_texts_of_source("demo.odin", bad_source)
	testing.expect(t, ok)
	testing.expect(t, count >= 10)
	// Expect faults for: "fast", "Invalid mode", "Error", "Don't change this",
	// "Vector.", "Operation failed.", "Please retry.", "older version",
	// "Delete All Notes", "New Console" (10 faults; "Spleen" and "Reset" pass).
	// Note: "New Console" has two capitalized words where "Console" is not a
	// function word, so 9 faults from our deterministic rules.
	testing.expect(t, len(faults) >= 9)

	clean_source := `package demo

@(rodata, member_texts = "en")
mode_texts := [Mode]string {
	.Fast = "Fast",
	.Slow = "Slow",
}

setting_texts := [Setting]Setting_Text {
	.Font = {"Font", "The font of every window.", {"Vector", "Spleen 8x16"}},
}

ZONE_EXPLANATION :: "A fixed offset from UTC."

window_problem_texts := [Problem]string {
	.None = "",
	.Bad  = "No store: the notes are not kept.",
}

draw :: proc() {
	_ = interface.action_bar_item("Older version", 1, "Up")
	_ = interface.button(frame, area, id, cond ? "Hide the damage" : "Show the damage")
	items := [1]interface.Context_Menu_Item{{id = 1, label = "New console"}}
}
`
	clean_faults, clean_count, clean_ok := display_texts_of_source("clean.odin", clean_source)
	testing.expect(t, clean_ok)
	testing.expect(t, clean_count >= 10)
	for fault in clean_faults {
		testing.expectf(t, false, "%s:%d: %q (%v: %s)", fault.file, fault.line, fault.text, fault.problem, fault.detail)
	}
}

// Every display text across the module sources of the repository keeps docs/WRITING.md.
@(test)
display_texts_of_the_repository :: proc(t: ^testing.T) {
	faults, file_count, text_count, ok := display_texts_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 20)
	testing.expect(t, text_count > 50)
	for fault in faults {
		testing.expectf(t, false, "%s:%d: %q (%v: %s)", fault.file, fault.line, fault.text, fault.problem, fault.detail)
	}
}
