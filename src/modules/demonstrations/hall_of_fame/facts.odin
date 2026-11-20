package hall_of_fame

// The log facts of the demonstration hall_of_fame
// (src/md/features/log_facts.md, "The facts of the demonstrations"). Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. A Text
// field comes last, and holds its longest text and a zero byte.

// A portrait whose pixels are not the size of a portrait: its card shows
// no picture.
@(log_fact = "hall_of_fame: the portrait {portrait} has {pixels} pixels, not {portrait_pixels}: its card shows no picture")
Portrait_Refused :: struct {
	portrait:        u64,
	pixels:          u64,
	portrait_pixels: u64,
}

// A card was chosen.
@(log_fact = "hall_of_fame: chose {chosen_name}")
Card_Chosen :: struct {
	chosen_name: [40]u8,
}

// The first frame that the compositor took: the cards that it drew, and
// the time of its draw.
@(log_fact = "hall_of_fame: ok, the first frame drew {drawn} of the {cards} people in {draw_time} us")
First_Frame_Drawn :: struct {
	drawn:     u64,
	cards:     u64,
	draw_time: u64,
}
