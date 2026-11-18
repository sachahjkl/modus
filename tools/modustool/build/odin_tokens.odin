// The tokens of an Odin source that the declaration index and the colors
// of the code on the site both read: the reader of a word of the language.
package build

import "core:odin/tokenizer"
import "modustool:foundation"

// The built-in types of Odin: a name of this list in code is of the class
// Type.
SITE_CODE_BUILT_IN_TYPES :: [?]string {
	"bool", "b8", "b16", "b32", "b64",
	"int", "uint", "uintptr", "rawptr", "any", "typeid",
	"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "byte",
	"i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
	"i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be",
	"f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
	"complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256",
	"rune", "string", "cstring",
}

// One token of a text of Odin: its kind and its bytes in the text.
Site_Code_Token :: struct {
	kind:  tokenizer.Token_Kind,
	start: int,
	end:   int,
}

// site_code_odin_tokens gives the tokens of a text, or false when the
// tokenizer refuses it (an illegal character, a string or a comment with no
// end). The tokenizer gives comments as tokens and skips the spaces and the
// line feeds; the caller writes the bytes between two tokens as they are.
site_code_odin_tokens :: proc(source: string) -> (tokens: []Site_Code_Token, ok: bool) {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, source, "", foundation.site_code_quiet_error)
	list := make([dynamic]Site_Code_Token, context.temp_allocator)
	position := 0
	for {
		token := tokenizer.scan(&t)
		if token.kind == .EOF {
			break
		}
		start, end := token.pos.offset, t.offset
		// Each token after the one before it, inside the text: else the
		// output would not be the text.
		if token.kind == .Invalid || start < position || end < start || end > len(source) || len(list) > len(source) {
			return nil, false
		}
		append(&list, Site_Code_Token{kind = token.kind, start = start, end = end})
		position = end
	}
	if t.error_count > 0 {
		return nil, false
	}
	return list[:], true
}

// site_code_is_capital tells whether a name starts with a capital letter.
site_code_is_capital :: proc(name: string) -> bool {
	return len(name) > 0 && name[0] >= 'A' && name[0] <= 'Z'
}

// site_code_is_constant_name tells whether a name is in capitals, with at
// least two letters: PAGE_SIZE.
site_code_is_constant_name :: proc(name: string) -> bool {
	letters := 0
	for character in transmute([]u8)name {
		switch {
		case character >= 'a' && character <= 'z':
			return false
		case character >= 'A' && character <= 'Z':
			letters += 1
		}
	}
	return letters >= 2
}
