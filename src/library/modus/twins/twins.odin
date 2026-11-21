// What the process `frames` and its process `twin` agree on (paging,
// second part). `frames` starts each twin with one mode, and reads what the
// twin did.
package twins

// The roles of the context of a twin.
GRANT_PAGE :: 0 // Memory, with Read and Write: one page that `frames` also maps. Twin_Mode.Write_Page only.
VALUE_MODE :: 0 // The word of the Twin_Mode of the twin.

// What a twin does. `frames` writes its word in VALUE_MODE, so each value
// is explicit.
Twin_Mode :: enum u64 {
	Wait       = 0, // Wait with no end: `frames` counts the pages of the twin.
	Write_Page = 1, // Write WORD at the start of the page of GRANT_PAGE, and wake the threads that wait on it.
	Write_Code = 2, // Write to its own code: the kernel stops the twin.
}

// twin_mode_of_word reads the word of VALUE_MODE. A word that names no mode
// is refused: the twin does not guess what `frames` asked for.
twin_mode_of_word :: proc "contextless" (word: u64) -> (mode: Twin_Mode, ok: bool) {
	for member in Twin_Mode {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

WORD :: u32(0x5EA5_1DE5) // The word that Twin_Mode.Write_Page writes, and that `frames` reads back.
