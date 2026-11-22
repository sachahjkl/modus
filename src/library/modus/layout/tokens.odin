// The element tokens: the colors and the lengths of an element by their
// role, taken from the one table of the color tokens and from the spacing
// tokens of graphics (src/md/features/box_layout.md, "The element tokens").
// This file holds no color value: a second table of values would drift.
package layout

import "modus:graphics"

// The colors and the lengths that an element draws with.
Element_Tokens :: struct {
	// The surfaces.
	surface_background:   graphics.Color, // Under all cards.
	surface_card:         graphics.Color, // A card: a surface over the background.
	surface_recess:       graphics.Color, // A list sunk into a card.
	surface_track:        graphics.Color, // A button, the empty part of a bar.
	surface_pointer_over: graphics.Color, // A button under the pointer or with the focus.
	surface_chosen:       graphics.Color, // A chosen row; a button with the focus under the pointer.
	// The lines.
	divider:              graphics.Color, // A line between two parts that the reader tells apart with no line too: no contrast asked.
	border:               graphics.Color, // A line that a reader needs to see an element: 3 to 1 on each surface.
	focus_outline:        graphics.Color, // The outline of the element with the focus.
	// The texts.
	text:                 graphics.Color,
	text_dim:             graphics.Color, // A text of less weight: a unit, a caption.
	text_strong:          graphics.Color, // The text that an input types.
	text_on_chosen:       graphics.Color, // A text on surface_chosen.
	// The states, each drawn as a text.
	expected:             graphics.Color, // An expected answer; a process that runs.
	warning:              graphics.Color, // A state that asks for attention and is not a failure.
	failed:               graphics.Color, // A failure.
	// The spacing tokens, in logical pixels.
	gap:                  i32,
	margin:               i32,
	title:                i32,
}

// tokens_for gives the element tokens of an appearance and a contrast mode.
// A forced high contrast mode gives its own appearance, whatever the
// appearance asked. false: a value that names no member, and no tokens.
tokens_for :: proc "contextless" (appearance: graphics.Appearance, contrast_mode: graphics.Color_Contrast_Mode) -> (Element_Tokens, bool) {
	if u8(appearance) > u8(max(graphics.Appearance)) || u8(contrast_mode) > u8(max(graphics.Color_Contrast_Mode)) {
		return {}, false
	}
	colors := graphics.colors_for_contrast_mode(contrast_mode, appearance == .Dark)
	return {
		surface_background   = colors.background,
		surface_card         = colors.card_top,
		surface_recess       = colors.recess,
		surface_track        = colors.track,
		// The button of the interface package under the pointer.
		surface_pointer_over = graphics.shade(colors.title, 60),
		surface_chosen       = colors.chosen,
		divider              = colors.point,
		border               = colors.dim,
		focus_outline        = colors.text_strong,
		text                 = colors.text,
		text_dim             = colors.dim,
		text_strong          = colors.text_strong,
		// White on the chosen blue in each appearance; the forced high
		// contrast modes keep a dark blue, so white stays on it too.
		text_on_chosen       = graphics.COLOR_WHITE,
		expected             = colors.process,
		warning              = colors.warning,
		failed               = colors.failed,
		gap                  = graphics.GAP,
		margin               = graphics.MARGIN,
		title                = graphics.TITLE,
	}, true
}

// The records that a token stack holds: a part of a window that draws with
// other tokens, inside another one, inside the window.
TOKEN_STACK_CAPACITY :: 16

// A stack of element tokens. A stack of all zero is empty, and its tokens
// are those of the dark appearance, as a system with no date is dark.
Token_Stack :: struct {
	entries: [TOKEN_STACK_CAPACITY]Element_Tokens,
	depth:   int,
}

// push_tokens makes a record the tokens in force. false: the stack is full,
// and nothing changed.
push_tokens :: proc "contextless" (stack: ^Token_Stack, tokens: Element_Tokens) -> bool {
	if stack.depth < 0 || stack.depth >= TOKEN_STACK_CAPACITY {
		return false
	}
	stack.entries[stack.depth] = tokens
	stack.depth += 1
	return true
}

// pop_tokens gives back the tokens in force before the last push. false: the
// stack is empty, and nothing changed.
pop_tokens :: proc "contextless" (stack: ^Token_Stack) -> bool {
	if stack.depth <= 0 || stack.depth > TOKEN_STACK_CAPACITY {
		return false
	}
	stack.depth -= 1
	return true
}

// tokens_current gives the tokens in force.
tokens_current :: proc "contextless" (stack: ^Token_Stack) -> Element_Tokens {
	if stack.depth <= 0 || stack.depth > TOKEN_STACK_CAPACITY {
		tokens, _ := tokens_for(.Dark, .Standard)
		return tokens
	}
	return stack.entries[stack.depth - 1]
}
