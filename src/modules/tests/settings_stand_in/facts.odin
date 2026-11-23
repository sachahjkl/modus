package settings_stand_in

// The log facts of the test module settings_stand_in
// (src/md/features/log_facts.md). No field has the name of a column of the
// head of facts(): number, time, process, level.

// The start policy started this module as the holder of the role Settings.
// pass_code is the settings.Pass of the context: 1 (Boot) when the row
// "settings" of the start list started it.
@(log_fact = "settings_stand_in: the start policy started the holder of the role Settings for the pass {pass_code}")
Started_As_Holder :: struct {
	pass_code: u64,
}

// The context value of the pass names no settings.Pass.
@(log_fact = "settings_stand_in: WRONG: the context value of the pass is {word}, which names no pass")
Wrong_Pass :: struct {
	word: u64,
}
