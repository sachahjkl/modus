package browser

import "modus:contract/html_css"
import "modus:graphics"
import "modus:system"

// The addresses and the pages built into the browser. Nothing here reads
// the network: each page is HTML and CSS that this file writes into a
// buffer of the module, and the origin worker parses it as it parses the
// bytes of an answer. The state of each origin is in origin_worker.odin.

// The bytes of an address as the address field holds it.
ADDRESS_CAPACITY :: 160
HOST_CAPACITY :: 64
PATH_CAPACITY :: 64
QUERY_CAPACITY :: 128
FRAGMENT_CAPACITY :: 64

// The bytes of the HTML of one page, before the style sheet of the
// appearance; the document is the style sheet and the page.
PAGE_SOURCE_CAPACITY :: 16384
DOCUMENT_SOURCE_CAPACITY :: 20480

// An address, cut into the parts that the browser reads. The path starts
// with '/', or is empty; the query has no '?'; the fragment has no '#' and
// never leaves the browser. The origin of an address is its scheme, its
// host and its port only.
Address :: struct {
	scheme:         html_css.Document_Scheme,
	port:           u16,
	host:           [HOST_CAPACITY]u8,
	host_count:     int,
	path:           [PATH_CAPACITY]u8,
	path_count:     int,
	query:          [QUERY_CAPACITY]u8,
	query_count:    int,
	fragment:       [FRAGMENT_CAPACITY]u8,
	fragment_count: int,
}

// Why an address is refused. The window shows the sentence of the member.
Address_Problem :: enum u8 {
	None,
	Empty,
	Too_Long,
	Scheme_Unknown,
	Host_Empty,
	Host_Too_Long,
	Host_Byte_Refused,
	Port_Refused,
	Path_Too_Long,
	Query_Too_Long,
	Fragment_Too_Long,
}

@(rodata)
ADDRESS_PROBLEM_SENTENCES := [Address_Problem]string {
	.None              = "",
	.Empty             = "the address is empty",
	.Too_Long          = "the address is longer than the field holds",
	.Scheme_Unknown    = "the address names no scheme that the browser reads: modus, http or https",
	.Host_Empty        = "the address names no host",
	.Host_Too_Long     = "the host of the address is longer than 64 bytes",
	.Host_Byte_Refused = "the host holds a byte that no host name holds",
	.Port_Refused      = "the port of the address is not a number from 1 to 65535",
	.Path_Too_Long     = "the path of the address is longer than 64 bytes",
	.Query_Too_Long    = "the query of the address is longer than 128 bytes",
	.Fragment_Too_Long = "the fragment of the address is longer than 64 bytes",
}

@(rodata)
SCHEME_NAMES := [html_css.Document_Scheme]string {
	.Http  = "http",
	.Https = "https",
	.Modus = "modus",
}

// The port of a scheme when the address names none.
@(rodata)
SCHEME_PORTS := [html_css.Document_Scheme]u16 {
	.Http  = 80,
	.Https = 443,
	.Modus = 0,
}

// The pages built into the browser, by the host of their address. An
// origin is a scheme, a host and a port, so each of them is its own origin.
Built_In_Page :: enum u8 {
	Welcome,
	Properties,
	Guide,
	Forms,
}

@(rodata)
BUILT_IN_HOSTS := [Built_In_Page]string {
	.Welcome    = "welcome",
	.Properties = "properties",
	.Guide      = "guide",
	.Forms      = "forms",
}

// What the page of an address is. The fact of the load names it.
Page_Kind :: enum u8 {
	Built_In,
	Form_Result,
	Cross_Origin_Read,
	Not_Found,
	No_Network,
	Address_Refused,
}

@(rodata)
PAGE_KIND_WORDS := [Page_Kind]string {
	.Built_In          = "a page built into the browser",
	.Form_Result       = "the answer to a form",
	.Cross_Origin_Read = "a read of another origin, refused",
	.Not_Found         = "no such page",
	.No_Network        = "no network in this window",
	.Address_Refused   = "an address that the browser refuses",
}

is_host_byte :: proc "contextless" (byte: u8) -> bool {
	return byte >= 'a' && byte <= 'z' || byte >= '0' && byte <= '9' || byte == '-' || byte == '.'
}

lower :: proc "contextless" (byte: u8) -> u8 {
	return byte >= 'A' && byte <= 'Z' ? byte + 32 : byte
}

text_contains :: proc "contextless" (text: string, part: string) -> (place: int, found: bool) {
	if len(part) == 0 || len(part) > len(text) {
		return 0, false
	}
	for start in 0 ..= len(text) - len(part) {
		if text[start:start + len(part)] == part {
			return start, true
		}
	}
	return 0, false
}

// address_parse reads the text of the address field. A text with no scheme
// is a page built into the browser when it holds no dot, and an address of
// HTTPS when it holds one, as a reader types "guide" or "example.org".
address_parse :: proc "contextless" (text: string) -> (address: Address, problem: Address_Problem) {
	rest := text
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	for len(rest) > 0 && (rest[len(rest) - 1] == ' ' || rest[len(rest) - 1] == '\t') {
		rest = rest[:len(rest) - 1]
	}
	if len(rest) == 0 {
		return {}, .Empty
	}
	if len(rest) > ADDRESS_CAPACITY {
		return {}, .Too_Long
	}
	if place, found := text_contains(rest, "://"); found {
		scheme_text := rest[:place]
		known := false
		for name, scheme in SCHEME_NAMES {
			if len(name) != len(scheme_text) {
				continue
			}
			same := true
			for index in 0 ..< len(name) {
				same &&= lower(scheme_text[index]) == name[index]
			}
			if same {
				address.scheme, known = scheme, true
			}
		}
		if !known {
			return {}, .Scheme_Unknown
		}
		rest = rest[place + 3:]
	} else {
		_, has_dot := text_contains(rest, ".")
		address.scheme = has_dot ? .Https : .Modus
	}
	address.port = SCHEME_PORTS[address.scheme]
	// The fragment is cut first: a '?' or a '/' in it is part of it.
	for index in 0 ..< len(rest) {
		if rest[index] == '#' {
			fragment := rest[index + 1:]
			if len(fragment) > FRAGMENT_CAPACITY {
				return {}, .Fragment_Too_Long
			}
			address.fragment_count = copy(address.fragment[:], fragment)
			rest = rest[:index]
			break
		}
	}
	// The host ends at the first '/', '?' or ':'.
	host_end := 0
	for host_end < len(rest) && rest[host_end] != '/' && rest[host_end] != '?' && rest[host_end] != ':' {
		host_end += 1
	}
	if host_end == 0 {
		return {}, .Host_Empty
	}
	if host_end > HOST_CAPACITY {
		return {}, .Host_Too_Long
	}
	for index in 0 ..< host_end {
		byte := lower(rest[index])
		if !is_host_byte(byte) {
			return {}, .Host_Byte_Refused
		}
		address.host[index] = byte
	}
	address.host_count = host_end
	rest = rest[host_end:]
	if len(rest) > 0 && rest[0] == ':' {
		rest = rest[1:]
		port: u32
		digits := 0
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
			port = port * 10 + u32(rest[digits] - '0')
			digits += 1
			if port > 65535 {
				return {}, .Port_Refused
			}
		}
		if digits == 0 || port == 0 {
			return {}, .Port_Refused
		}
		address.port = u16(port)
		rest = rest[digits:]
	}
	if len(rest) > 0 && rest[0] != '/' && rest[0] != '?' {
		return {}, .Port_Refused
	}
	path_end := 0
	for path_end < len(rest) && rest[path_end] != '?' {
		path_end += 1
	}
	if path_end > PATH_CAPACITY {
		return {}, .Path_Too_Long
	}
	address.path_count = copy(address.path[:], rest[:path_end])
	// A path of "/" alone names the root, as no path does.
	if address.path_count == 1 {
		address.path_count = 0
	}
	if path_end < len(rest) {
		query := rest[path_end + 1:]
		if len(query) > QUERY_CAPACITY {
			return {}, .Query_Too_Long
		}
		address.query_count = copy(address.query[:], query)
	}
	return address, .None
}

address_host :: proc "contextless" (address: ^Address) -> string {
	return string(address.host[:address.host_count])
}

address_path :: proc "contextless" (address: ^Address) -> string {
	return string(address.path[:address.path_count])
}

address_query :: proc "contextless" (address: ^Address) -> string {
	return string(address.query[:address.query_count])
}

address_fragment :: proc "contextless" (address: ^Address) -> string {
	return string(address.fragment[:address.fragment_count])
}

// origin_write writes the origin of an address: its scheme, its host and
// its port when the port is not the one of the scheme.
origin_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	put(writer, SCHEME_NAMES[address.scheme])
	put(writer, "://")
	put(writer, address_host(address))
	if address.port != SCHEME_PORTS[address.scheme] {
		put(writer, ":")
		put_number(writer, u64(address.port))
	}
}

// address_write writes the whole address, as the address field shows it.
address_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	origin_write(writer, address)
	put(writer, address_path(address))
	if address.query_count > 0 {
		put(writer, "?")
		put(writer, address_query(address))
	}
	if address.fragment_count > 0 {
		put(writer, "#")
		put(writer, address_fragment(address))
	}
}

// The principal of the session of this window. The window acts for one
// principal; the address of a page never changes it.
SESSION_PRINCIPAL :: 1

// origin_of gives the document origin of an address: the principal of the
// session, the scheme, the host and the port. Two pages share their state
// only when html_css.origins_equal says that their origins are one.
origin_of :: proc "contextless" (address: ^Address) -> (origin: html_css.Document_Origin) {
	origin.principal_id = SESSION_PRINCIPAL
	origin.scheme = address.scheme
	origin.port = address.port
	origin.host_len = u16(copy(origin.host[:], address.host[:address.host_count]))
	return
}

// address_resolve writes the address of a link, a form action or a
// redirect, read against the address of the page that holds it: an
// address with a scheme stands alone, "//host/path" keeps the scheme of
// the page only, "#name" keeps its path and its query, and each other text
// is a path in the origin of the page.
address_resolve :: proc "contextless" (writer: ^Source_Writer, base: ^Address, reference: string) {
	if _, absolute := text_contains(reference, "://"); absolute {
		put(writer, reference)
		return
	}
	if len(reference) >= 2 && reference[0] == '/' && reference[1] == '/' {
		put(writer, SCHEME_NAMES[base.scheme])
		put(writer, ":")
		put(writer, reference)
		return
	}
	origin_write(writer, base)
	if len(reference) == 0 {
		put(writer, address_path(base))
		return
	}
	if reference[0] == '#' {
		put(writer, address_path(base))
		if base.query_count > 0 {
			put(writer, "?")
			put(writer, address_query(base))
		}
		put(writer, reference)
		return
	}
	if reference[0] != '/' && reference[0] != '?' {
		put(writer, "/")
	}
	put(writer, reference)
}

// The writer of a page: it copies bytes into a buffer of the module and
// remembers when one did not fit, so a page that is cut says so.
Source_Writer :: struct {
	bytes: []u8,
	count: int,
	full:  bool,
}

put :: proc "contextless" (target: ^Source_Writer, text: string) {
	room := len(target.bytes) - target.count
	if len(text) > room {
		target.full = true
	}
	target.count += copy(target.bytes[target.count:], text[:min(len(text), room)])
}

put_number :: proc "contextless" (writer: ^Source_Writer, value: u64) {
	digits: [24]u8
	put(writer, system.format(digits[:], value))
}

// put_escaped writes a text of the reader into HTML: each byte that would
// open a tag, an attribute or a character reference is written as its
// reference, so a query never adds markup to the page.
put_escaped :: proc "contextless" (writer: ^Source_Writer, text: string) {
	for index in 0 ..< len(text) {
		switch text[index] {
		case '<':
			put(writer, "&lt;")
		case '>':
			put(writer, "&gt;")
		case '&':
			put(writer, "&amp;")
		case '"':
			put(writer, "&quot;")
		case '\'':
			put(writer, "&#39;")
		case:
			put(writer, text[index:index + 1])
		}
	}
}

writer_text :: proc "contextless" (writer: ^Source_Writer) -> string {
	return string(writer.bytes[:writer.count])
}

// The key under which the forms origin keeps the last query that a form
// of it sent.
QUERY_STORAGE_KEY :: "query"

// query_value finds the value of a name in a query, decoded: '+' is a
// space, and %XX is the byte XX. A broken escape is kept as its bytes.
query_value :: proc "contextless" (query: string, name: string, buffer: []u8) -> (value: string, found: bool) {
	rest := query
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != '&' {
			end += 1
		}
		pair := rest[:end]
		rest = end < len(rest) ? rest[end + 1:] : ""
		equal := 0
		for equal < len(pair) && pair[equal] != '=' {
			equal += 1
		}
		if pair[:equal] != name {
			continue
		}
		encoded := equal < len(pair) ? pair[equal + 1:] : ""
		count := 0
		for index := 0; index < len(encoded) && count < len(buffer); index += 1 {
			byte := encoded[index]
			if byte == '+' {
				byte = ' '
			} else if byte == '%' && index + 2 < len(encoded) {
				high, high_ok := hex_digit(encoded[index + 1])
				low, low_ok := hex_digit(encoded[index + 2])
				if high_ok && low_ok {
					byte = high << 4 | low
					index += 2
				}
			}
			buffer[count] = byte
			count += 1
		}
		return string(buffer[:count]), true
	}
	return "", false
}

hex_digit :: proc "contextless" (byte: u8) -> (value: u8, ok: bool) {
	switch {
	case byte >= '0' && byte <= '9':
		return byte - '0', true
	case byte >= 'a' && byte <= 'f':
		return byte - 'a' + 10, true
	case byte >= 'A' && byte <= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

// put_query_encoded writes a value of a form field into a query: each byte
// but a letter, a digit, '-', '_' and '.' as %XX, and a space as '+'.
put_query_encoded :: proc "contextless" (writer: ^Source_Writer, value: string) {
	digits := "0123456789ABCDEF"
	for index in 0 ..< len(value) {
		byte := value[index]
		switch {
		case byte >= 'a' && byte <= 'z', byte >= 'A' && byte <= 'Z', byte >= '0' && byte <= '9', byte == '-', byte == '_', byte == '.':
			put(writer, value[index:index + 1])
		case byte == ' ':
			put(writer, "+")
		case:
			escape := [3]u8{'%', digits[byte >> 4], digits[byte & 0xF]}
			put(writer, string(escape[:]))
		}
	}
}

// The style sheet of each appearance. The pages name classes only, so one
// page reads well on the dark and on the light appearance.
@(rodata)
APPEARANCE_STYLES := [graphics.Appearance]string {
	.Dark  = `
body { background: #15181e; color: #d6dbe4; padding: 20px 24px; }
h1 { color: #ffffff; margin-bottom: 8px; }
h2 { color: #e8ecf3; margin-top: 18px; margin-bottom: 8px; }
p { margin-bottom: 10px; }
a { color: #7cb8ff; }
.lead { color: #aab3c2; margin-bottom: 14px; }
.rail { height: 3px; background: #4f9dff; }
.hero { background: #172133; padding: 18px 24px; margin-bottom: 16px; }
.kicker { color: #7cb8ff; font-size: 14px; margin-bottom: 6px; }
.badges { display: flex; flex-direction: row; gap: 8px; }
.badge { background: #24324a; color: #cfe0ff; padding: 3px 10px; }
.badge-ok { background: #183a2a; color: #7ee2a8; }
.actions { display: flex; flex-direction: row; gap: 10px; margin-top: 14px; }
.cta { background: #2f6fe0; padding: 6px 16px; }
.cta-link { color: #ffffff; }
.ghost { background: #232c3b; padding: 6px 16px; }
.cards { display: flex; flex-direction: row; gap: 12px; margin-bottom: 14px; }
.card { background: #1f2531; width: 236px; }
.card-body { padding: 12px 14px; }
.card-kicker { color: #8d96a6; font-size: 14px; margin-bottom: 4px; }
.card-title { color: #ffffff; margin-bottom: 6px; }
.bar { height: 3px; }
.blue-bar { background: #4f9dff; }
.green-bar { background: #3ecf8e; }
.amber-bar { background: #f0b443; }
.stats { display: flex; flex-direction: row; gap: 12px; margin-bottom: 6px; }
.stat { background: #1a1f29; padding: 10px 14px; width: 208px; }
.stat-number { color: #ffffff; font-size: 32px; }
.rows { display: flex; flex-direction: column; gap: 2px; margin-bottom: 14px; }
.row { display: flex; flex-direction: row; background: #1d212b; padding: 6px 8px; }
.head { background: #2b3242; color: #ffffff; }
.number { width: 56px; color: #ffcf6b; }
.mark { width: 6px; height: 6px; background: #7cb8ff; margin-top: 6px; margin-right: 10px; }
.item { display: flex; flex-direction: row; margin-bottom: 4px; }
.box { background: #232836; padding: 12px; margin-bottom: 14px; }
.ok { color: #7ee2a8; }
.refused { color: #ff8a80; }
.dim { color: #8d96a6; }
.code { color: #ffcf6b; }
.button { background: #2f5ea8; color: #ffffff; padding: 4px 14px; }
input { width: 260px; height: 24px; margin-right: 8px; }
.field { display: flex; flex-direction: row; margin-bottom: 8px; }
.label { width: 96px; color: #aab3c2; }
`,
	.Light = `
body { background: #f6f6f2; color: #1d2430; padding: 20px 24px; }
h1 { color: #0d1117; margin-bottom: 8px; }
h2 { color: #18202c; margin-top: 18px; margin-bottom: 8px; }
p { margin-bottom: 10px; }
a { color: #0b57c2; }
.lead { color: #4a5465; margin-bottom: 14px; }
.rail { height: 3px; background: #0b57c2; }
.hero { background: #e6eefb; padding: 18px 24px; margin-bottom: 16px; }
.kicker { color: #0b57c2; font-size: 14px; margin-bottom: 6px; }
.badges { display: flex; flex-direction: row; gap: 8px; }
.badge { background: #d3e1f7; color: #10325e; padding: 3px 10px; }
.badge-ok { background: #d6f0e0; color: #0f5e33; }
.actions { display: flex; flex-direction: row; gap: 10px; margin-top: 14px; }
.cta { background: #0b57c2; padding: 6px 16px; }
.cta-link { color: #ffffff; }
.ghost { background: #ffffff; padding: 6px 16px; }
.cards { display: flex; flex-direction: row; gap: 12px; margin-bottom: 14px; }
.card { background: #ffffff; width: 236px; }
.card-body { padding: 12px 14px; }
.card-kicker { color: #5d6675; font-size: 14px; margin-bottom: 4px; }
.card-title { color: #0d1117; margin-bottom: 6px; }
.bar { height: 3px; }
.blue-bar { background: #0b57c2; }
.green-bar { background: #157a43; }
.amber-bar { background: #a8650f; }
.stats { display: flex; flex-direction: row; gap: 12px; margin-bottom: 6px; }
.stat { background: #ffffff; padding: 10px 14px; width: 208px; }
.stat-number { color: #0d1117; font-size: 32px; }
.rows { display: flex; flex-direction: column; gap: 2px; margin-bottom: 14px; }
.row { display: flex; flex-direction: row; background: #ffffff; padding: 6px 8px; }
.head { background: #e2e6ee; color: #0d1117; }
.number { width: 56px; color: #8a5a00; }
.mark { width: 6px; height: 6px; background: #0b57c2; margin-top: 6px; margin-right: 10px; }
.item { display: flex; flex-direction: row; margin-bottom: 4px; }
.box { background: #ffffff; padding: 12px; margin-bottom: 14px; }
.ok { color: #157a43; }
.refused { color: #b3261e; }
.dim { color: #5d6675; }
.code { color: #8a5a00; }
.button { background: #0b57c2; color: #ffffff; padding: 4px 14px; }
input { width: 260px; height: 24px; margin-right: 8px; }
.field { display: flex; flex-direction: row; margin-bottom: 8px; }
.label { width: 96px; color: #4a5465; }
`,
}

// The navigation that each page built into the browser shows at its top.
NAVIGATION :: `<p class="dim"><a href="modus://welcome">welcome</a> | <a href="modus://properties">properties</a> | <a href="modus://guide">guide</a> | <a href="modus://forms">forms</a></p>`

@(rodata)
BUILT_IN_SOURCES := [Built_In_Page]string {
	.Welcome    = `<title>Welcome</title>
<body>
<div class="rail"></div>
<div class="hero">
<p class="kicker">MODUS / A PAGE BUILT INTO THE BROWSER</p>
<h1>A light browser</h1>
<p class="lead">Each page of this window is HTML and CSS: the browser parses it, computes its styles and its boxes, and paints the boxes into the draw table of the window.</p>
<div class="badges"><span class="badge">the cascade</span><span class="badge">forms and a history</span><span class="badge">block, inline, flex</span><span class="badge badge-ok">one origin for each host</span></div>
<div class="actions"><div class="cta"><a class="cta-link" href="modus://properties">The properties</a></div><div class="ghost"><a href="modus://guide">The guide</a></div><div class="ghost"><a href="modus://forms">A form</a></div></div>
</div>
<div class="cards">
<div class="card"><div class="bar blue-bar"></div><div class="card-body"><p class="card-kicker">01 / PARSE</p><p class="card-title">HTML</p><p>A tokenizer and a tree builder of a subset of the WHATWG algorithm, with fixed pools: at most 512 nodes.</p></div></div>
<div class="card"><div class="bar green-bar"></div><div class="card-body"><p class="card-kicker">02 / STYLE</p><p class="card-title">CSS</p><p>Selectors of a tag, a class and an id, the cascade by specificity, and block, inline and flex layout.</p></div></div>
<div class="card"><div class="bar amber-bar"></div><div class="card-body"><p class="card-kicker">03 / ISOLATE</p><p class="card-title">Origins</p><p>Each host is an origin. A page reads the state of its own origin only.</p></div></div>
</div>
<div class="stats">
<div class="stat"><p class="stat-number">512</p><p class="dim">nodes at most in a page</p></div>
<div class="stat"><p class="stat-number">1</p><p class="dim">grant: its window</p></div>
<div class="stat"><p class="stat-number">0</p><p class="dim">allocations</p></div>
</div>
<h2>Try it</h2>
<div class="item"><div class="mark"></div><p>Follow a link: <a href="modus://properties">the properties of the system</a>.</p></div>
<div class="item"><div class="mark"></div><p>Read <a href="modus://guide">the guide of this window</a>: its keys and its parts.</p></div>
<div class="item"><div class="mark"></div><p>Send <a href="modus://forms">a form</a>, then come back with the back button.</p></div>
<div class="item"><div class="mark"></div><p>Ask for <a href="/peek">the state of the origin of the forms</a> from this origin: the browser refuses.</p></div>
</body>`,
	.Properties = `<title>The properties</title>
<body>
` + NAVIGATION + `
<h1>The properties of modus</h1>
<p class="lead">The fixed constraints of the system. A design that breaks one of them changes the property first.</p>
<div class="rows">
<div class="row head"><span class="number">#</span><span>Property</span></div>
<div class="row"><span class="number">1</span><span>Small kernel with a small, counted interface</span></div>
<div class="row"><span class="number">2</span><span>Sandbox by default</span></div>
<div class="row"><span class="number">6</span><span>One communication mechanism between processes</span></div>
<div class="row"><span class="number">9</span><span>A storage engine with one private store per process</span></div>
<div class="row"><span class="number">14</span><span>Memory is supplied by the caller</span></div>
<div class="row"><span class="number">18</span><span>One 2D interface: the draw table</span></div>
<div class="row"><span class="number">20</span><span>No ambient access: the other holes to close</span></div>
<div class="row"><span class="number">21</span><span>Principals: who acts, without users</span></div>
</div>
<p>This window keeps them: it has no grant but its window, it allocates nothing, and it draws each page through the draw table.</p>
<p><a href="modus://welcome">Back to the welcome page</a></p>
</body>`,
	.Guide      = `<title>The guide</title>
<body>
` + NAVIGATION + `
<h1>The guide of the browser</h1>
<h2>The parts of the window</h2>
<div class="box"><p>The top band: back, forward, reload, the address field, go, and the origin of the page.</p><p>The bookmarks: one button for each page built into the browser.</p><p>The page: the boxes of the document, with a scroll bar.</p><p>The status band: the title, the nodes of the document, its document boxes, and the address of the link under the pointer.</p></div>
<h2>The keys</h2>
<div class="rows">
<div class="row"><span class="number code">Enter</span><span>In the address field: load the address. In a form field: send the form.</span></div>
<div class="row"><span class="number code">PgUp</span><span>Scroll the page up by a view.</span></div>
<div class="row"><span class="number code">PgDn</span><span>Scroll the page down by a view.</span></div>
<div class="row"><span class="number code">Home</span><span>The top of the page.</span></div>
<div class="row"><span class="number code">End</span><span>The bottom of the page.</span></div>
</div>
<h2>The addresses</h2>
<p>A text with no scheme and no dot is a page of the browser: <a href="modus://guide">guide</a> is modus://guide. A text with a dot is an address of HTTPS.</p>
<p class="dim">This window has no grant of the network. For a page of HTTP or HTTPS, the worker of its origin writes the request, and shows it.</p>
</body>`,
	.Forms      = `<title>Forms</title>
<body>
` + NAVIGATION + `
<h1>A form</h1>
<p class="lead">Type in the fields, then press Send or Enter. The browser writes the values into the query of the address of the action, and loads it.</p>
<form action="/result">
<div class="field"><span class="label">name</span><input name="name" value="modus"></div>
<div class="field"><span class="label">query</span><input name="query"><button class="button">Send</button></div>
</form>
`,
}

// built_in_of gives the page built into the browser that a host names.
built_in_of :: proc "contextless" (host: string) -> (page: Built_In_Page, found: bool) {
	for name, candidate in BUILT_IN_HOSTS {
		if name == host {
			return candidate, true
		}
	}
	return {}, false
}

// page_write writes the HTML of the page of an address. Only the scheme
// modus has pages here: an address of HTTP or HTTPS gets the request that
// the worker of its origin builds, and a page that says why it does not
// load, under its own origin.
page_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) -> Page_Kind {
	switch address.scheme {
	case .Http, .Https:
		offline_write(writer, address)
		return .No_Network
	case .Modus:
	}
	page, found := built_in_of(address_host(address))
	if !found {
		put(writer, "<title>No such page</title><body>")
		put(writer, NAVIGATION)
		put(writer, `<h1>No such page</h1><p class="refused">The browser has no page `)
		put_escaped(writer, address_host(address))
		put(writer, `.</p></body>`)
		return .Not_Found
	}
	path := address_path(address)
	switch {
	case page == .Forms && path == "/result":
		form_result_write(writer, address)
		return .Form_Result
	case page == .Welcome && path == "/peek":
		peek_write(writer, address)
		return .Cross_Origin_Read
	}
	put(writer, BUILT_IN_SOURCES[page])
	if page == .Forms {
		// The forms page shows the state of its own origin: the read is
		// given, as the page and the state share one origin.
		own := origin_of(address)
		buffer: [ORIGIN_VALUE_CAPACITY]u8
		value, status := origin_storage_read(&own, &own, QUERY_STORAGE_KEY, buffer[:])
		put(writer, `<h2>The state of this origin</h2><div class="box">`)
		switch status {
		case .Done:
			put(writer, `<p class="ok">The last query of this origin: `)
			put_escaped(writer, value)
			put(writer, `</p>`)
		case .Nothing_Kept:
			put(writer, `<p class="dim">This origin keeps no query yet.</p>`)
		case .Refused_Other_Origin, .Refused_Malformed:
			put(writer, `<p class="refused">Refused: another origin.</p>`)
		}
		put(writer, `</div></body>`)
	}
	return .Built_In
}

// offline_write writes the page of an address of HTTP or HTTPS: the
// request that the worker of its origin builds, with the cookies of that
// origin only, and why the window does not send it.
offline_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	origin_buffer: [ADDRESS_CAPACITY]u8
	origin_text := Source_Writer{bytes = origin_buffer[:]}
	origin_write(&origin_text, address)
	own := origin_of(address)
	cookies := origin_request_make(.Cookie_Header, &own, &own)
	cookie_reply := origin_ask(&cookies)
	request: [REQUEST_CAPACITY]u8
	request_count, problem := fetch_request_write(address, string(cookie_reply.value[:cookie_reply.value_count]), request[:])
	put(writer, "<title>No network</title><body>")
	put(writer, NAVIGATION)
	put(writer, `<h1>No network in this window</h1><div class="box"><p class="refused">The browser loads no page of `)
	put_escaped(writer, writer_text(&origin_text))
	put(writer, `: the window has no grant of the network.</p>`)
	if problem != .None {
		put(writer, `<p class="refused">The request is refused: `)
		put(writer, FETCH_PROBLEM_SENTENCES[problem])
		put(writer, `.</p></div></body>`)
		return
	}
	put(writer, `<p>The worker of this origin wrote its request, `)
	put_number(writer, u64(request_count))
	put(writer, ` bytes of HTTP/1.1`)
	if address.scheme == .Https {
		put(writer, `, for TLS 1.3 over TCP`)
	}
	put(writer, `:</p><pre class="code">`)
	// The request line and the headers, one line each.
	text := string(request[:request_count])
	for len(text) > 0 {
		end := 0
		for end < len(text) && text[end] != '\r' {
			end += 1
		}
		if end > 0 {
			put(writer, `<p>`)
			put_escaped(writer, text[:end])
			put(writer, `</p>`)
		}
		text = text[min(end + 2, len(text)):]
	}
	put(writer, `</pre><p>The process of each origin holds the network grant of that origin only; the window starts none yet.</p></div></body>`)
}

// form_result_write writes the answer to a form: each value of the query,
// escaped. The query becomes the state of the origin of the forms.
form_result_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	name_buffer, query_buffer: [ORIGIN_VALUE_CAPACITY]u8
	name, _ := query_value(address_query(address), "name", name_buffer[:])
	query, has_query := query_value(address_query(address), "query", query_buffer[:])
	own := origin_of(address)
	if has_query {
		origin_storage_write(&own, QUERY_STORAGE_KEY, query)
	}
	put(writer, "<title>The form was sent</title><body>")
	put(writer, NAVIGATION)
	put(writer, `<h1>The form was sent</h1><div class="box"><p>name: <span class="code">`)
	put_escaped(writer, name)
	put(writer, `</span></p><p>query: <span class="code">`)
	put_escaped(writer, query)
	put(writer, `</span></p></div><p>The origin modus://forms keeps the query. Only a page of that origin reads it: <a href="modus://forms">the forms page</a> shows it, and <a href="modus://welcome/peek">a page of the welcome origin</a> is refused.</p></body>`)
}

// peek_write writes the page that asks for the state of the origin of the
// forms from the origin of the welcome page: the read is refused.
peek_write :: proc "contextless" (writer: ^Source_Writer, address: ^Address) {
	reader := origin_of(address)
	forms_address, _ := address_parse("modus://forms")
	owner := origin_of(&forms_address)
	buffer: [ORIGIN_VALUE_CAPACITY]u8
	_, status := origin_storage_read(&reader, &owner, QUERY_STORAGE_KEY, buffer[:])
	put(writer, "<title>A read of another origin</title><body>")
	put(writer, NAVIGATION)
	put(writer, `<h1>A read of another origin</h1><div class="box">`)
	switch status {
	case .Refused_Other_Origin:
		put(writer, `<p class="refused">Refused: this page is of modus://welcome, and the state is of modus://forms.</p><p>The page learns nothing of that state, not even whether it exists.</p>`)
	case .Done, .Nothing_Kept, .Refused_Malformed:
		put(writer, `<p class="refused">WRONG: the read was not refused.</p>`)
	}
	put(writer, `</div></body>`)
}
