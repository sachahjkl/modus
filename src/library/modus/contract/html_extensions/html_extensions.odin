// Shared contract for WHATWG HTML parsing extensions: quirks-mode DOCTYPE
// classification, `<template>` inert stack, `<select>` / `<frameset>` /
// foreign-content insertion modes, SVG and MathML case adjustment tables,
// escaped script-data scanning, and binary-searched named character references
// (src/md/features/desktop_to_browser.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation.
package html_extensions

import "modus:contract/enum_word"

// Plan value: maximum nested `<template>` or insertion-mode stack depth,
// bounding parser state memory on hostile deeply nested HTML documents.
TEMPLATE_MODE_STACK_CAPACITY :: 64

// Closed set of WHATWG DOM namespaces supported by the HTML tree builder.
Html_Namespace :: enum u8 {
	Html   = 0,
	Svg    = 1,
	MathML = 2,
}

// Closed set of WHATWG HTML insertion modes modeled by this contract.
Html_Insertion_Mode :: enum u8 {
	Initial            = 0,
	In_Body            = 1,
	In_Select          = 2,
	In_Template        = 3,
	In_Frameset        = 4,
	In_Foreign_Content = 5,
}

// Closed set of WHATWG document quirks modes.
Html_Quirks_Mode :: enum u8 {
	No_Quirks      = 0,
	Limited_Quirks = 1,
	Quirks         = 2,
}

// Closed set of refusal outcomes returned by HTML extension state transitions
// and decoders.
Html_Extension_Refusal :: enum u8 {
	None                = 0,
	Stack_Overflow      = 1,
	Stack_Underflow     = 2,
	Bad_Mode            = 3,
	Bad_Namespace       = 4,
	Buffer_Too_Small    = 5,
	Entity_Malformed    = 6,
	Entity_Unknown      = 7,
	Script_Unterminated = 8,
	Null_State          = 9,
}

// Closed set of WHATWG script-data escaping states.
Script_Data_State :: enum u8 {
	Data           = 0,
	Escaped        = 1,
	Double_Escaped = 2,
}

// Parsed DOCTYPE token fields fed into quirks-mode classification.
Doctype_Token :: struct {
	name:          string,
	public_id:     string,
	system_id:     string,
	force_quirks:  bool,
	has_public_id: bool,
	has_system_id: bool,
}

// Insertion-mode state machine for `<template>`, `<select>`, `<frameset>`, and
// SVG/MathML foreign content.
Html_Mode_State :: struct {
	mode:           Html_Insertion_Mode,
	original_mode:  Html_Insertion_Mode,
	ns:             Html_Namespace,
	template_stack: [TEMPLATE_MODE_STACK_CAPACITY]Html_Insertion_Mode,
	template_depth: u16,
	select_depth:   u16,
	frameset_ok:    bool,
	quirks:         Html_Quirks_Mode,
}

// One entry in the sorted WHATWG named character reference table.
Named_Entity :: struct {
	name:             string,
	codepoint:        rune,
	second_codepoint: rune,
}

// html_namespace_of_word converts a transport word into Html_Namespace.
html_namespace_of_word :: proc "contextless" (word: u64) -> (ns: Html_Namespace, ok: bool) {
	return enum_word.member_of_word(Html_Namespace, word)
}

// html_insertion_mode_of_word converts a transport word into Html_Insertion_Mode.
html_insertion_mode_of_word :: proc "contextless" (word: u64) -> (mode: Html_Insertion_Mode, ok: bool) {
	return enum_word.member_of_word(Html_Insertion_Mode, word)
}

// html_quirks_mode_of_word converts a transport word into Html_Quirks_Mode.
html_quirks_mode_of_word :: proc "contextless" (word: u64) -> (mode: Html_Quirks_Mode, ok: bool) {
	return enum_word.member_of_word(Html_Quirks_Mode, word)
}

// ---- DOCTYPE quirks-mode classifier (WHATWG HTML 13.2.6.4.1).

@(private = "file", rodata)
QUIRKS_PUBLIC_EXACT := [?]string{
	"-//W3O//DTD W3 HTML Strict 3.0//EN//",
	"-/W3C/DTD HTML 4.0 Transitional/EN",
	"HTML",
}

@(private = "file", rodata)
QUIRKS_PUBLIC_PREFIXES := [?]string{
	"+//Silmaril//dtd html Pro v0r11 19970101//",
	"-//AS//DTD HTML 3.0 asWedit + extensions//",
	"-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
	"-//IETF//DTD HTML 2.0 Level 1//",
	"-//IETF//DTD HTML 2.0 Level 2//",
	"-//IETF//DTD HTML 2.0 Strict Level 1//",
	"-//IETF//DTD HTML 2.0 Strict Level 2//",
	"-//IETF//DTD HTML 2.0 Strict//",
	"-//IETF//DTD HTML 2.0//",
	"-//IETF//DTD HTML 2.1E//",
	"-//IETF//DTD HTML 3.0//",
	"-//IETF//DTD HTML 3.2 Final//",
	"-//IETF//DTD HTML 3.2//",
	"-//IETF//DTD HTML 3//",
	"-//IETF//DTD HTML Level 0//",
	"-//IETF//DTD HTML Level 1//",
	"-//IETF//DTD HTML Level 2//",
	"-//IETF//DTD HTML Level 3//",
	"-//IETF//DTD HTML Strict Level 0//",
	"-//IETF//DTD HTML Strict Level 1//",
	"-//IETF//DTD HTML Strict Level 2//",
	"-//IETF//DTD HTML Strict Level 3//",
	"-//IETF//DTD HTML Strict//",
	"-//IETF//DTD HTML//",
	"-//Metrius//DTD Metrius Presentational//",
	"-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
	"-//Microsoft//DTD Internet Explorer 2.0 HTML//",
	"-//Microsoft//DTD Internet Explorer 2.0 Tables//",
	"-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
	"-//Microsoft//DTD Internet Explorer 3.0 HTML//",
	"-//Microsoft//DTD Internet Explorer 3.0 Tables//",
	"-//Netscape Comm. Corp.//DTD HTML//",
	"-//Netscape Comm. Corp.//DTD Strict HTML//",
	"-//O'Reilly and Associates//DTD HTML 2.0//",
	"-//O'Reilly and Associates//DTD HTML Extended 1.0//",
	"-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
	"-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
	"-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
	"-//Spyglass//DTD HTML 2.0 Extended//",
	"-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
	"-//Sun Microsystems Corp.//DTD HotJava HTML//",
	"-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
	"-//W3C//DTD HTML 3 1995-03-24//",
	"-//W3C//DTD HTML 3.2 Draft//",
	"-//W3C//DTD HTML 3.2 Final//",
	"-//W3C//DTD HTML 3.2//",
	"-//W3C//DTD HTML 3.2S Draft//",
	"-//W3C//DTD HTML 4.0 Frameset//",
	"-//W3C//DTD HTML 4.0 Transitional//",
	"-//W3C//DTD HTML Experimental 19960712//",
	"-//W3C//DTD HTML Experimental 970421//",
	"-//W3C//DTD W3 HTML//",
	"-//W3O//DTD W3 HTML 3.0//",
	"-//WebTechs//DTD Mozilla HTML 2.0//",
	"-//WebTechs//DTD Mozilla HTML//",
}

@(private = "file", rodata)
LIMITED_QUIRKS_PUBLIC_PREFIXES := [?]string{
	"-//W3C//DTD XHTML 1.0 Frameset//",
	"-//W3C//DTD XHTML 1.0 Transitional//",
}

@(private = "file", rodata)
CONDITIONAL_QUIRKS_PUBLIC_PREFIXES := [?]string{
	"-//W3C//DTD HTML 4.01 Frameset//",
	"-//W3C//DTD HTML 4.01 Transitional//",
}

@(private = "file")
QUIRKS_SYSTEM_EXACT :: "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"

// doctype_classify_quirks classifies a DOCTYPE token into No_Quirks,
// Limited_Quirks, or Quirks following the WHATWG HTML specification.
doctype_classify_quirks :: proc "contextless" (dt: Doctype_Token) -> Html_Quirks_Mode {
	if dt.force_quirks || !ascii_equal_fold(dt.name, "html") {
		return .Quirks
	}
	if dt.has_system_id && ascii_equal_fold(dt.system_id, QUIRKS_SYSTEM_EXACT) {
		return .Quirks
	}
	if dt.has_public_id {
		for exact in QUIRKS_PUBLIC_EXACT {
			if ascii_equal_fold(dt.public_id, exact) {
				return .Quirks
			}
		}
		for prefix in QUIRKS_PUBLIC_PREFIXES {
			if ascii_has_prefix_fold(dt.public_id, prefix) {
				return .Quirks
			}
		}
		for prefix in LIMITED_QUIRKS_PUBLIC_PREFIXES {
			if ascii_has_prefix_fold(dt.public_id, prefix) {
				return .Limited_Quirks
			}
		}
		for prefix in CONDITIONAL_QUIRKS_PUBLIC_PREFIXES {
			if ascii_has_prefix_fold(dt.public_id, prefix) {
				return dt.has_system_id ? .Limited_Quirks : .Quirks
			}
		}
	}
	return .No_Quirks
}

// ---- Insertion-mode state machine (`<template>`, `<select>`, `<frameset>`, foreign content).

html_mode_init :: proc "contextless" () -> Html_Mode_State {
	return {
		mode        = .Initial,
		ns          = .Html,
		frameset_ok = true,
		quirks      = .No_Quirks,
	}
}

html_mode_is_inert :: proc "contextless" (state: ^Html_Mode_State) -> bool {
	return state != nil && state.template_depth > 0
}

html_mode_on_doctype :: proc "contextless" (state: ^Html_Mode_State, dt: Doctype_Token) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.mode != .Initial {
		return .Bad_Mode
	}
	state.quirks = doctype_classify_quirks(dt)
	state.mode = .In_Body
	return .None
}

html_mode_enter_template :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if int(state.template_depth) >= TEMPLATE_MODE_STACK_CAPACITY {
		return .Stack_Overflow
	}
	state.template_stack[state.template_depth] = state.mode
	state.template_depth += 1
	state.mode = .In_Template
	return .None
}

html_mode_leave_template :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.template_depth == 0 || state.mode != .In_Template {
		return .Stack_Underflow
	}
	state.template_depth -= 1
	state.mode = state.template_stack[state.template_depth]
	return .None
}

html_mode_enter_select :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.mode == .Initial || state.mode == .In_Frameset || state.mode == .In_Foreign_Content {
		return .Bad_Mode
	}
	if int(state.select_depth) >= TEMPLATE_MODE_STACK_CAPACITY {
		return .Stack_Overflow
	}
	if state.select_depth == 0 {
		state.original_mode = state.mode
	}
	state.select_depth += 1
	state.mode = .In_Select
	state.frameset_ok = false
	return .None
}

html_mode_leave_select :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.select_depth == 0 || state.mode != .In_Select {
		return .Stack_Underflow
	}
	state.select_depth -= 1
	if state.select_depth == 0 {
		state.mode = state.original_mode
	}
	return .None
}

html_mode_enter_frameset :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.mode != .In_Body || !state.frameset_ok || state.template_depth > 0 {
		return .Bad_Mode
	}
	state.mode = .In_Frameset
	return .None
}

html_mode_enter_foreign :: proc "contextless" (state: ^Html_Mode_State, ns: Html_Namespace) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if _, ok := enum_word.member_of_argument(ns); !ok || ns == .Html {
		return .Bad_Namespace
	}
	if state.mode == .Initial || state.mode == .In_Frameset || state.mode == .In_Foreign_Content {
		return .Bad_Mode
	}
	state.original_mode = state.mode
	state.mode = .In_Foreign_Content
	state.ns = ns
	state.frameset_ok = false
	return .None
}

html_mode_leave_foreign :: proc "contextless" (state: ^Html_Mode_State) -> Html_Extension_Refusal {
	if state == nil {
		return .Null_State
	}
	if state.mode != .In_Foreign_Content {
		return .Bad_Mode
	}
	state.mode = state.original_mode
	state.ns = .Html
	return .None
}

// html_foreign_breakout_tag reports whether a lowercase HTML start tag forces
// an exit from SVG or MathML foreign content back to HTML (WHATWG 13.2.6.5).
html_foreign_breakout_tag :: proc "contextless" (lower_tag: string) -> bool {
	switch lower_tag {
	case "b", "big", "blockquote", "body", "br", "center", "code", "dd",
	     "div", "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5",
	     "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta",
	     "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong",
	     "strike", "sub", "sup", "table", "tt", "u", "ul", "var":
		return true
	}
	return false
}

// ---- SVG & MathML tag and attribute case adjustment tables (WHATWG 13.2.6.5).

adjust_svg_tag_name :: proc "contextless" (lower_name: string) -> string {
	switch lower_name {
	case "altglyph":            return "altGlyph"
	case "altglyphdef":         return "altGlyphDef"
	case "altglyphitem":        return "altGlyphItem"
	case "animatecolor":        return "animateColor"
	case "animatemotion":       return "animateMotion"
	case "animatetransform":    return "animateTransform"
	case "clippath":            return "clipPath"
	case "feblend":             return "feBlend"
	case "fecolormatrix":       return "feColorMatrix"
	case "fecomponenttransfer": return "feComponentTransfer"
	case "fecomposite":         return "feComposite"
	case "feconvolvematrix":    return "feConvolveMatrix"
	case "fediffuselighting":   return "feDiffuseLighting"
	case "fedisplacementmap":   return "feDisplacementMap"
	case "fedistantlight":      return "feDistantLight"
	case "fedropshadow":        return "feDropShadow"
	case "feflood":             return "feFlood"
	case "fefunca":             return "feFuncA"
	case "fefuncb":             return "feFuncB"
	case "fefuncg":             return "feFuncG"
	case "fefuncr":             return "feFuncR"
	case "fegaussianblur":      return "feGaussianBlur"
	case "feimage":             return "feImage"
	case "femerge":             return "feMerge"
	case "femergenode":         return "feMergeNode"
	case "femorphology":        return "feMorphology"
	case "feoffset":            return "feOffset"
	case "fepointlight":        return "fePointLight"
	case "fespecularlighting":  return "feSpecularLighting"
	case "fespotlight":         return "feSpotLight"
	case "fetile":              return "feTile"
	case "feturbulence":        return "feTurbulence"
	case "foreignobject":       return "foreignObject"
	case "glyphref":            return "glyphRef"
	case "lineargradient":      return "linearGradient"
	case "radialgradient":      return "radialGradient"
	case "textpath":            return "textPath"
	}
	return lower_name
}

adjust_svg_attribute_name :: proc "contextless" (lower_name: string) -> string {
	switch lower_name {
	case "attributename":       return "attributeName"
	case "attributetype":       return "attributeType"
	case "basefrequency":       return "baseFrequency"
	case "calcmode":            return "calcMode"
	case "clippathunits":       return "clipPathUnits"
	case "gradienttransform":   return "gradientTransform"
	case "gradientunits":       return "gradientUnits"
	case "keysplines":          return "keySplines"
	case "keytimes":            return "keyTimes"
	case "lengthadjust":        return "lengthAdjust"
	case "markerheight":        return "markerHeight"
	case "markerunits":         return "markerUnits"
	case "markerwidth":         return "markerWidth"
	case "maskcontentunits":    return "maskContentUnits"
	case "maskunits":           return "maskUnits"
	case "numoctaves":          return "numOctaves"
	case "pathlength":          return "pathLength"
	case "patterntransform":    return "patternTransform"
	case "patternunits":        return "patternUnits"
	case "preserveaspectratio": return "preserveAspectRatio"
	case "refx":                return "refX"
	case "refy":                return "refY"
	case "repeatcount":         return "repeatCount"
	case "repeatdur":           return "repeatDur"
	case "specularconstant":    return "specularConstant"
	case "specularexponent":    return "specularExponent"
	case "spreadmethod":        return "spreadMethod"
	case "startoffset":         return "startOffset"
	case "stddeviation":        return "stdDeviation"
	case "surfacescale":        return "surfaceScale"
	case "tablevalues":         return "tableValues"
	case "targetx":             return "targetX"
	case "targety":             return "targetY"
	case "textlength":          return "textLength"
	case "viewbox":             return "viewBox"
	case "xchannelselector":    return "xChannelSelector"
	case "ychannelselector":    return "yChannelSelector"
	case "zoomandpan":          return "zoomAndPan"
	}
	return lower_name
}

adjust_mathml_attribute_name :: proc "contextless" (lower_name: string) -> string {
	if lower_name == "definitionurl" {
		return "definitionURL"
	}
	return lower_name
}

// ---- WHATWG script-data escaped and double-escaped scanner (13.2.5.15-31).

// script_data_scan_end scans the body of a `<script>` element starting right
// after the opening `>` until its true closing `</script...>` tag, honoring
// HTML comment escapes (`<!--` .. `-->`) and double-escaped nested `<script>`.
script_data_scan_end :: proc "contextless" (
	input: string,
) -> (content_end: int, after_close_tag: int, final_state: Script_Data_State, refusal: Html_Extension_Refusal) {
	state := Script_Data_State.Data
	i := 0
	for i < len(input) {
		switch state {
		case .Data:
			if has_prefix_at(input, i, "<!--") {
				state = .Escaped
				i += 4
				continue
			}
			if close_end, ok := match_script_close_tag(input, i); ok {
				return i, close_end, state, .None
			}
			i += 1
		case .Escaped:
			if has_prefix_at(input, i, "-->") {
				state = .Data
				i += 3
				continue
			}
			if open_end, ok := match_script_open_tag(input, i); ok {
				state = .Double_Escaped
				i = open_end
				continue
			}
			if close_end, ok := match_script_close_tag(input, i); ok {
				return i, close_end, state, .None
			}
			i += 1
		case .Double_Escaped:
			if has_prefix_at(input, i, "-->") {
				state = .Data
				i += 3
				continue
			}
			if close_end, ok := match_script_close_tag(input, i); ok {
				state = .Escaped
				i = close_end
				continue
			}
			i += 1
		}
	}
	return len(input), len(input), state, .Script_Unterminated
}

// ---- Binary-searched expanded WHATWG named character reference table.

// Sorted strictly ascending in ASCII byte order for binary search.
@(rodata)
NAMED_ENTITIES := [?]Named_Entity{
	{"Alpha",   0x0391, 0},
	{"Beta",    0x0392, 0},
	{"Delta",   0x0394, 0},
	{"Gamma",   0x0393, 0},
	{"Lambda",  0x039B, 0},
	{"Omega",   0x03A9, 0},
	{"Phi",     0x03A6, 0},
	{"Pi",      0x03A0, 0},
	{"Psi",     0x03A8, 0},
	{"Sigma",   0x03A3, 0},
	{"Theta",   0x0398, 0},
	{"acute",   0x00B4, 0},
	{"alpha",   0x03B1, 0},
	{"amp",     '&',    0},
	{"apos",    '\'',   0},
	{"beta",    0x03B2, 0},
	{"bull",    0x2022, 0},
	{"cent",    0x00A2, 0},
	{"chi",     0x03C7, 0},
	{"copy",    0x00A9, 0},
	{"darr",    0x2193, 0},
	{"deg",     0x00B0, 0},
	{"delta",   0x03B4, 0},
	{"divide",  0x00F7, 0},
	{"epsilon", 0x03B5, 0},
	{"eta",     0x03B7, 0},
	{"euro",    0x20AC, 0},
	{"gamma",   0x03B3, 0},
	{"ge",      0x2265, 0},
	{"gt",      '>',    0},
	{"harr",    0x2194, 0},
	{"hellip",  0x2026, 0},
	{"infin",   0x221E, 0},
	{"iota",    0x03B9, 0},
	{"kappa",   0x03BA, 0},
	{"lambda",  0x03BB, 0},
	{"laquo",   0x00AB, 0},
	{"larr",    0x2190, 0},
	{"ldquo",   0x201C, 0},
	{"le",      0x2264, 0},
	{"lsquo",   0x2018, 0},
	{"lt",      '<',    0},
	{"mdash",   0x2014, 0},
	{"micro",   0x00B5, 0},
	{"middot",  0x00B7, 0},
	{"minus",   0x2212, 0},
	{"mu",      0x03BC, 0},
	{"nbsp",    0x00A0, 0},
	{"ndash",   0x2013, 0},
	{"ne",      0x2260, 0},
	{"not",     0x00AC, 0},
	{"nu",      0x03BD, 0},
	{"omega",   0x03C9, 0},
	{"omicron", 0x03BF, 0},
	{"para",    0x00B6, 0},
	{"phi",     0x03C6, 0},
	{"pi",      0x03C0, 0},
	{"plusmn",  0x00B1, 0},
	{"pound",   0x00A3, 0},
	{"psi",     0x03C8, 0},
	{"quot",    '"',    0},
	{"raquo",   0x00BB, 0},
	{"rarr",    0x2192, 0},
	{"rdquo",   0x201D, 0},
	{"reg",     0x00AE, 0},
	{"rho",     0x03C1, 0},
	{"rsquo",   0x2019, 0},
	{"sect",    0x00A7, 0},
	{"sigma",   0x03C3, 0},
	{"tau",     0x03C4, 0},
	{"theta",   0x03B8, 0},
	{"times",   0x00D7, 0},
	{"trade",   0x2122, 0},
	{"uarr",    0x2191, 0},
	{"upsilon", 0x03C5, 0},
	{"xi",      0x03BE, 0},
	{"yen",     0x00A5, 0},
	{"zeta",    0x03B6, 0},
}

// decode_named_entity binary-searches NAMED_ENTITIES for `&name;`.
decode_named_entity :: proc "contextless" (entity: string) -> (r1: rune, r2: rune, refusal: Html_Extension_Refusal) {
	if len(entity) < 3 || entity[0] != '&' || entity[len(entity) - 1] != ';' {
		return 0, 0, .Entity_Malformed
	}
	name := entity[1:len(entity) - 1]
	for i in 0 ..< len(name) {
		ch := name[i]
		is_alnum := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
		if !is_alnum {
			return 0, 0, .Entity_Malformed
		}
	}

	lo := 0
	hi := len(NAMED_ENTITIES)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		cmp := string_compare(NAMED_ENTITIES[mid].name, name)
		if cmp == 0 {
			e := NAMED_ENTITIES[mid]
			return e.codepoint, e.second_codepoint, .None
		}
		if cmp < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return 0, 0, .Entity_Unknown
}

// decode_entity_to_utf8 decodes `&name;` and writes its UTF-8 bytes into `out`.
// Refuses Buffer_Too_Small without writing any byte to `out`.
decode_entity_to_utf8 :: proc "contextless" (entity: string, out: []u8) -> (written: int, refusal: Html_Extension_Refusal) {
	r1, r2, ref := decode_named_entity(entity)
	if ref != .None {
		return 0, ref
	}
	need := utf8_rune_width(r1) + (r2 != 0 ? utf8_rune_width(r2) : 0)
	if need > len(out) {
		return 0, .Buffer_Too_Small
	}
	n := utf8_encode_rune(r1, out)
	if r2 != 0 {
		n += utf8_encode_rune(r2, out[n:])
	}
	return n, .None
}

// ---- Private ASCII / UTF-8 helpers.

@(private = "file")
ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

@(private = "file")
ascii_equal_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if ascii_lower(a[i]) != ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
ascii_has_prefix_fold :: proc "contextless" (s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	return ascii_equal_fold(s[:len(prefix)], prefix)
}

@(private = "file")
has_prefix_at :: proc "contextless" (s: string, at: int, prefix: string) -> bool {
	if at < 0 || at + len(prefix) > len(s) {
		return false
	}
	return s[at:at + len(prefix)] == prefix
}

@(private = "file")
is_tag_boundary :: proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' || b == '/' || b == '>'
}

@(private = "file")
match_script_open_tag :: proc "contextless" (s: string, at: int) -> (end: int, ok: bool) {
	// Matches `<script` followed by a tag boundary (` `, `/`, `>`, newline).
	if at + 8 > len(s) {
		return 0, false
	}
	if !ascii_equal_fold(s[at:at + 7], "<script") || !is_tag_boundary(s[at + 7]) {
		return 0, false
	}
	return at + 8, true
}

@(private = "file")
match_script_close_tag :: proc "contextless" (s: string, at: int) -> (end: int, ok: bool) {
	// Matches `</script` followed by a tag boundary and scans to the closing `>`.
	if at + 9 > len(s) {
		return 0, false
	}
	if !ascii_equal_fold(s[at:at + 8], "</script") || !is_tag_boundary(s[at + 8]) {
		return 0, false
	}
	p := at + 8
	for p < len(s) {
		if s[p] == '>' {
			return p + 1, true
		}
		p += 1
	}
	return 0, false
}

@(private = "file")
string_compare :: proc "contextless" (a, b: string) -> int {
	limit := min(len(a), len(b))
	for i in 0 ..< limit {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

@(private = "file")
utf8_rune_width :: proc "contextless" (r: rune) -> int {
	cp := u32(r)
	switch {
	case cp <= 0x7F:
		return 1
	case cp <= 0x7FF:
		return 2
	case cp <= 0xFFFF:
		return 3
	case:
		return 4
	}
}

@(private = "file")
utf8_encode_rune :: proc "contextless" (r: rune, out: []u8) -> int {
	cp := u32(r)
	switch {
	case cp <= 0x7F:
		out[0] = u8(cp)
		return 1
	case cp <= 0x7FF:
		out[0] = u8(0xC0 | (cp >> 6))
		out[1] = u8(0x80 | (cp & 0x3F))
		return 2
	case cp <= 0xFFFF:
		out[0] = u8(0xE0 | (cp >> 12))
		out[1] = u8(0x80 | ((cp >> 6) & 0x3F))
		out[2] = u8(0x80 | (cp & 0x3F))
		return 3
	case:
		out[0] = u8(0xF0 | (cp >> 18))
		out[1] = u8(0x80 | ((cp >> 12) & 0x3F))
		out[2] = u8(0x80 | ((cp >> 6) & 0x3F))
		out[3] = u8(0x80 | (cp & 0x3F))
		return 4
	}
}
