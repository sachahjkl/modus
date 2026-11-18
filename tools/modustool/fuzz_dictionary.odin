package modustool

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The dictionary of a fuzz target (src/md/infrastructure/fuzzing.md, "The
// mutators"): each constant and each enumerated value that the packages
// under test declare, as the bytes that a reader of a format compares. A
// magic value, a format number, a size or a limit is then one mutation
// away, and the limit plus one too.

// The longest text constant that becomes a word: a longer text is a
// sentence for a reader, not a value of a format.
FUZZ_WORD_TEXT_LIMIT :: 64

// The most words of one dictionary.
FUZZ_DICTIONARY_CAPACITY :: 4096

// fuzz_dictionary_fill adds the words of the packages of a target, and the
// words that the target adds itself, to the dictionary of an engine.
fuzz_dictionary_fill :: proc(engine: ^Fuzz_Engine) {
	values := make([dynamic]i64, context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	for package_folder in engine.target.packages {
		fuzz_constants_of_folder(package_folder, &values, &texts)
	}
	slice.sort(values[:])
	values_unique := slice.unique(values[:])
	for value in values_unique {
		for neighbour in ([2]i64{value, value + 1}) {
			fuzz_dictionary_add_integer(engine, neighbour)
		}
	}
	for text in texts {
		fuzz_dictionary_add(engine, transmute([]u8)text)
	}
	if engine.target.words != nil {
		words := make([dynamic][]u8, context.temp_allocator)
		engine.target.words(&words)
		for word in words {
			fuzz_dictionary_add(engine, word)
		}
	}
}

// fuzz_dictionary_add copies one word into the dictionary, once.
fuzz_dictionary_add :: proc(engine: ^Fuzz_Engine, word: []u8) {
	if len(word) == 0 || len(engine.dictionary) >= FUZZ_DICTIONARY_CAPACITY {
		return
	}
	for item in engine.dictionary {
		if slice.equal(item, word) {
			return
		}
	}
	append(&engine.dictionary, slice.clone(word))
}

// fuzz_dictionary_add_integer adds the forms of one number that a format
// can hold: the smallest size that holds it in each order of bytes, and 4
// and 8 bytes in little-endian order.
fuzz_dictionary_add_integer :: proc(engine: ^Fuzz_Engine, value: i64) {
	bits := u64(value)
	size := 1
	if value >= 0 {
		for size < 8 && bits >> (8 * u64(size)) != 0 {
			size *= 2
		}
	} else {
		size = 8
	}
	bytes: [8]u8
	fuzz_word_write(bytes[:], 0, size, bits, false)
	fuzz_dictionary_add(engine, bytes[:size])
	if size > 1 {
		fuzz_word_write(bytes[:], 0, size, bits, true)
		fuzz_dictionary_add(engine, bytes[:size])
	}
	for wide in ([2]int{4, 8}) {
		if wide > size {
			fuzz_word_write(bytes[:], 0, wide, bits, false)
			fuzz_dictionary_add(engine, bytes[:wide])
		}
	}
}

// fuzz_constants_of_folder reads the constants of each source file of a
// package that is not a test. A file that the parser refuses gives none:
// the build of the system checks its sources.
fuzz_constants_of_folder :: proc(folder: string, values: ^[dynamic]i64, texts: ^[dynamic]string) {
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return
	}
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		path := strings.concatenate({folder, "/", entry.name}, context.temp_allocator)
		source, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			continue
		}
		fuzz_constants_of_file(path, string(source), values, texts)
	}
}

// fuzz_constants_of_file parses one file in an arena of its own, and keeps
// the numbers and the texts of its constants and of its enumerated values.
fuzz_constants_of_file :: proc(path, source: string, values: ^[dynamic]i64, texts: ^[dynamic]string) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	kept_allocator := context.temp_allocator
	{
		context.allocator = virtual.arena_allocator(&arena)
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source
		file.fullpath = path
		reader := parser.default_parser()
		reader.err = foundation.site_code_quiet_error
		reader.warn = foundation.site_code_quiet_error
		if !parser.parse_file(&reader, file) || file.syntax_error_count > 0 {
			return
		}
		for declaration in file.decls {
			value_declaration, is_value := declaration.derived.(^ast.Value_Decl)
			if !is_value || value_declaration.is_mutable {
				continue
			}
			for expression in value_declaration.values {
				fuzz_constants_of_expression(expression, values, texts, kept_allocator)
			}
		}
	}
}

// fuzz_constants_of_expression keeps the value of a constant expression of
// numbers, a text, or the explicit values of an enumeration. The texts are
// copied into kept_allocator: the arena of the parser does not outlive the
// file.
fuzz_constants_of_expression :: proc(expression: ^ast.Expr, values: ^[dynamic]i64, texts: ^[dynamic]string, kept_allocator: runtime.Allocator) {
	if expression == nil {
		return
	}
	if enumeration, is_enumeration := expression.derived.(^ast.Enum_Type); is_enumeration {
		for field in enumeration.fields {
			if item, is_field_value := field.derived.(^ast.Field_Value); is_field_value {
				if value, ok := fuzz_constant_value(item.value); ok {
					append(values, value)
				}
			}
		}
		return
	}
	if literal, is_literal := expression.derived.(^ast.Basic_Lit); is_literal && literal.tok.kind == .String {
		text, allocated, ok := strconv.unquote_string(literal.tok.text, context.allocator)
		_ = allocated
		if ok && len(text) > 0 && len(text) <= FUZZ_WORD_TEXT_LIMIT {
			append(texts, strings.clone(text, kept_allocator))
		}
		return
	}
	if value, ok := fuzz_constant_value(expression); ok {
		append(values, value)
	}
}

// fuzz_constant_value evaluates an expression of integer literals: a
// literal, a sign, a parenthesis, a conversion such as `u64(0x4D)`, and the
// operators + - * << >> | & ~ between two of them.
fuzz_constant_value :: proc(expression: ^ast.Expr) -> (value: i64, ok: bool) {
	if expression == nil {
		return 0, false
	}
	#partial switch item in expression.derived {
	case ^ast.Basic_Lit:
		if item.tok.kind != .Integer {
			return 0, false
		}
		unsigned, parsed := strconv.parse_u64(item.tok.text)
		return i64(unsigned), parsed
	case ^ast.Paren_Expr:
		return fuzz_constant_value(item.expr)
	case ^ast.Unary_Expr:
		inner := fuzz_constant_value(item.expr) or_return
		#partial switch item.op.kind {
		case .Sub:
			return -inner, true
		case .Add:
			return inner, true
		case .Xor:
			return ~inner, true
		}
		return 0, false
	case ^ast.Call_Expr:
		if len(item.args) != 1 {
			return 0, false
		}
		return fuzz_constant_value(item.args[0])
	case ^ast.Binary_Expr:
		left := fuzz_constant_value(item.left) or_return
		right := fuzz_constant_value(item.right) or_return
		#partial switch item.op.kind {
		case .Add:
			return left + right, true
		case .Sub:
			return left - right, true
		case .Mul:
			return left * right, true
		case .Shl:
			return right >= 0 && right < 64 ? left << u64(right) : 0, right >= 0 && right < 64
		case .Shr:
			return right >= 0 && right < 64 ? left >> u64(right) : 0, right >= 0 && right < 64
		case .Or:
			return left | right, true
		case .And:
			return left & right, true
		}
	}
	return 0, false
}
