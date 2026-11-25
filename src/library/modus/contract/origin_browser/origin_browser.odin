// Shared contract for per-origin web browser isolation: RFC 6454 origin
// parsing and equality, strict 1-process-per-origin slot allocation, bounded
// back/forward navigation history, and safe form URL encoding
// (src/md/features/desktop_to_browser.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation.
package origin_browser

import "modus:contract/enum_word"

// Format property: RFC 1035 DNS hostname maximum length in bytes.
ORIGIN_HOST_MAX_BYTES :: 253

// Plan value: bounded URL byte length kept in tab navigation history.
URL_MAX_BYTES :: 2048

// Plan value: maximum simultaneous isolated per-origin renderer process slots.
ORIGIN_PROCESS_CAPACITY :: 64

// Plan value: maximum entries kept in one tab's bounded navigation history.
HISTORY_CAPACITY :: 128

// Format property: IANA default ports for HTTP and HTTPS.
HTTP_DEFAULT_PORT :: u16(80)
HTTPS_DEFAULT_PORT :: u16(443)

// Closed set of URL schemes accepted by the light per-origin browser.
// Values cross process borders explicitly.
Url_Scheme :: enum u8 {
	Http  = 1,
	Https = 2,
}

// Closed set of HTML form submission methods.
Form_Method :: enum u8 {
	Get  = 1,
	Post = 2,
}

// Closed set of refusal outcomes returned by origin browser checks and encoders.
Origin_Browser_Refusal :: enum u8 {
	None                = 0,
	Empty_Url           = 1,
	Url_Too_Long        = 2,
	Unsupported_Scheme  = 3,
	Credentials_Refused = 4,
	Missing_Host        = 5,
	Host_Too_Long       = 6,
	Bad_Host_Byte       = 7,
	Bad_Port            = 8,
	Bad_Control_Byte    = 9,
	Table_Full          = 10,
	No_Back_Entry       = 11,
	No_Forward_Entry    = 12,
	Buffer_Too_Small    = 13,
	Null_State          = 14,
	Process_Not_Found   = 15,
	Cross_Origin_Denied = 16,
	Bad_Method          = 17,
}

// RFC 6454 web origin tuple: (scheme, canonical lowercase host, explicit port).
Web_Origin :: struct {
	scheme:   Url_Scheme,
	host:     [ORIGIN_HOST_MAX_BYTES]u8,
	host_len: u16,
	port:     u16,
}

// One active renderer process slot bound to a single Web_Origin.
Origin_Process_Slot :: struct {
	active:     bool,
	process_id: u64,
	origin:     Web_Origin,
}

// Process isolation table enforcing 1-process-per-origin: cross-origin
// navigations never reuse an existing origin's renderer slot.
Origin_Process_Table :: struct {
	slots:           [ORIGIN_PROCESS_CAPACITY]Origin_Process_Slot,
	next_process_id: u64,
}

// One entry in a tab's navigation history.
History_Entry :: struct {
	url:     [URL_MAX_BYTES]u8,
	url_len: u16,
	origin:  Web_Origin,
}

// Bounded back/forward navigation history stack for one browser tab.
History_Stack :: struct {
	entries:       [HISTORY_CAPACITY]History_Entry,
	count:         u16,
	current_index: i32,
}

// One name/value field for application/x-www-form-urlencoded encoding.
Form_Field :: struct {
	name:  string,
	value: string,
}

// url_scheme_of_word converts a transport word into Url_Scheme at a border.
url_scheme_of_word :: proc "contextless" (word: u64) -> (scheme: Url_Scheme, ok: bool) {
	return enum_word.member_of_word(Url_Scheme, word)
}

// form_method_of_word converts a transport word into Form_Method at a border.
form_method_of_word :: proc "contextless" (word: u64) -> (method: Form_Method, ok: bool) {
	return enum_word.member_of_word(Form_Method, word)
}

// origin_host returns the canonical lowercase host slice of `origin`.
origin_host :: proc "contextless" (origin: ^Web_Origin) -> string {
	if origin == nil || int(origin.host_len) > ORIGIN_HOST_MAX_BYTES {
		return ""
	}
	return string(origin.host[:origin.host_len])
}

// history_entry_url returns the URL slice stored in `entry`.
history_entry_url :: proc "contextless" (entry: ^History_Entry) -> string {
	if entry == nil || int(entry.url_len) > URL_MAX_BYTES {
		return ""
	}
	return string(entry.url[:entry.url_len])
}

// origin_parse_url strictly parses an http/https URL into its canonical
// RFC 6454 Web_Origin tuple, refusing control bytes, embedded userinfo/
// credentials, unsupported schemes, malformed hosts, and bad ports.
origin_parse_url :: proc "contextless" (raw_url: string) -> (origin: Web_Origin, refusal: Origin_Browser_Refusal) {
	if len(raw_url) == 0 {
		return {}, .Empty_Url
	}
	if len(raw_url) > URL_MAX_BYTES {
		return {}, .Url_Too_Long
	}
	for i in 0 ..< len(raw_url) {
		b := raw_url[i]
		if b <= 0x20 || b >= 0x7F {
			return {}, .Bad_Control_Byte
		}
	}

	scheme: Url_Scheme
	default_port: u16
	rest: string
	if ascii_has_prefix_fold(raw_url, "http://") {
		scheme = .Http
		default_port = HTTP_DEFAULT_PORT
		rest = raw_url[7:]
	} else if ascii_has_prefix_fold(raw_url, "https://") {
		scheme = .Https
		default_port = HTTPS_DEFAULT_PORT
		rest = raw_url[8:]
	} else {
		return {}, .Unsupported_Scheme
	}

	// Authority ends at first '/', '?', or '#'.
	auth_end := len(rest)
	for i in 0 ..< len(rest) {
		ch := rest[i]
		if ch == '/' || ch == '?' || ch == '#' {
			auth_end = i
			break
		}
	}
	authority := rest[:auth_end]
	if len(authority) == 0 {
		return {}, .Missing_Host
	}

	// Refuse user:pass@host credentials in URLs.
	for i in 0 ..< len(authority) {
		if authority[i] == '@' {
			return {}, .Credentials_Refused
		}
	}

	host_raw: string
	port_raw: string
	has_port := false

	if authority[0] == '[' {
		// Bracketed IPv6 literal: `[::1]` or `[::1]:8080`.
		close_idx := -1
		for i in 1 ..< len(authority) {
			if authority[i] == ']' {
				close_idx = i
				break
			}
		}
		if close_idx <= 1 {
			return {}, .Bad_Host_Byte
		}
		host_raw = authority[:close_idx + 1]
		after := authority[close_idx + 1:]
		if len(after) > 0 {
			if after[0] != ':' {
				return {}, .Bad_Port
			}
			has_port = true
			port_raw = after[1:]
		}
	} else {
		colon_idx := -1
		for i in 0 ..< len(authority) {
			if authority[i] == ':' {
				if colon_idx >= 0 {
					return {}, .Bad_Port
				}
				colon_idx = i
			}
		}
		if colon_idx >= 0 {
			host_raw = authority[:colon_idx]
			has_port = true
			port_raw = authority[colon_idx + 1:]
		} else {
			host_raw = authority
		}
	}

	if len(host_raw) == 0 {
		return {}, .Missing_Host
	}
	if len(host_raw) > ORIGIN_HOST_MAX_BYTES {
		return {}, .Host_Too_Long
	}

	out := Web_Origin{
		scheme   = scheme,
		host_len = u16(len(host_raw)),
		port     = default_port,
	}

	if host_raw[0] == '[' {
		// Validate bracketed IPv6 hex/colon/dot characters and lowercase.
		for i in 0 ..< len(host_raw) {
			b := host_raw[i]
			if i == 0 || i == len(host_raw) - 1 {
				out.host[i] = b
				continue
			}
			low := ascii_lower(b)
			valid := (low >= '0' && low <= '9') || (low >= 'a' && low <= 'f') || low == ':' || low == '.'
			if !valid {
				return {}, .Bad_Host_Byte
			}
			out.host[i] = low
		}
	} else {
		// Validate DNS/IPv4 host characters (no leading/trailing/double dot).
		if host_raw[0] == '.' || host_raw[len(host_raw) - 1] == '.' || host_raw[0] == '-' || host_raw[len(host_raw) - 1] == '-' {
			return {}, .Bad_Host_Byte
		}
		prev_dot := false
		for i in 0 ..< len(host_raw) {
			low := ascii_lower(host_raw[i])
			valid := (low >= 'a' && low <= 'z') || (low >= '0' && low <= '9') || low == '-' || low == '.'
			if !valid {
				return {}, .Bad_Host_Byte
			}
			if low == '.' {
				if prev_dot {
					return {}, .Bad_Host_Byte
				}
				prev_dot = true
			} else {
				prev_dot = false
			}
			out.host[i] = low
		}
	}

	if has_port {
		parsed_port, port_ok := parse_port_u16(port_raw)
		if !port_ok {
			return {}, .Bad_Port
		}
		out.port = parsed_port
	}
	return out, .None
}

// origin_equal checks strict RFC 6454 tuple equality (scheme, host, port).
origin_equal :: proc "contextless" (a, b: ^Web_Origin) -> bool {
	if a == nil || b == nil {
		return false
	}
	if a.scheme != b.scheme || a.port != b.port || a.host_len != b.host_len {
		return false
	}
	if int(a.host_len) > ORIGIN_HOST_MAX_BYTES {
		return false
	}
	for i in 0 ..< int(a.host_len) {
		if a.host[i] != b.host[i] {
			return false
		}
	}
	return true
}

// ---- Strict 1-process-per-origin isolation table.

// origin_table_acquire returns the existing process slot for `origin` or
// allocates a brand-new isolated process slot if none exists. Cross-origin
// navigations never share a slot. Refuses Table_Full without mutating `table`.
origin_table_acquire :: proc "contextless" (
	table: ^Origin_Process_Table,
	origin: Web_Origin,
) -> (process_id: u64, reused: bool, refusal: Origin_Browser_Refusal) {
	if table == nil {
		return 0, false, .Null_State
	}
	if _, ok := enum_word.member_of_argument(origin.scheme); !ok {
		return 0, false, .Unsupported_Scheme
	}
	if origin.host_len == 0 || int(origin.host_len) > ORIGIN_HOST_MAX_BYTES {
		return 0, false, .Missing_Host
	}
	if origin.port == 0 {
		return 0, false, .Bad_Port
	}

	local_origin := origin
	free_slot := -1
	for i in 0 ..< ORIGIN_PROCESS_CAPACITY {
		if table.slots[i].active {
			if origin_equal(&table.slots[i].origin, &local_origin) {
				return table.slots[i].process_id, true, .None
			}
		} else if free_slot < 0 {
			free_slot = i
		}
	}
	if free_slot < 0 {
		return 0, false, .Table_Full
	}

	table.next_process_id += 1
	pid := table.next_process_id
	table.slots[free_slot] = {
		active     = true,
		process_id = pid,
		origin     = local_origin,
	}
	return pid, false, .None
}

// origin_table_may_access enforces strict same-origin confinement: a renderer
// process may access DOM/cookies/storage ONLY for its own bound Web_Origin.
origin_table_may_access :: proc "contextless" (
	table: ^Origin_Process_Table,
	process_id: u64,
	target_origin: Web_Origin,
) -> Origin_Browser_Refusal {
	if table == nil {
		return .Null_State
	}
	if process_id == 0 {
		return .Process_Not_Found
	}
	local_target := target_origin
	for i in 0 ..< ORIGIN_PROCESS_CAPACITY {
		if table.slots[i].active && table.slots[i].process_id == process_id {
			if origin_equal(&table.slots[i].origin, &local_target) {
				return .None
			}
			return .Cross_Origin_Denied
		}
	}
	return .Process_Not_Found
}

// origin_table_release frees a stopped renderer process slot.
origin_table_release :: proc "contextless" (table: ^Origin_Process_Table, process_id: u64) -> Origin_Browser_Refusal {
	if table == nil {
		return .Null_State
	}
	if process_id == 0 {
		return .Process_Not_Found
	}
	for i in 0 ..< ORIGIN_PROCESS_CAPACITY {
		if table.slots[i].active && table.slots[i].process_id == process_id {
			table.slots[i] = {}
			return .None
		}
	}
	return .Process_Not_Found
}

// ---- Bounded tab navigation history stack.

history_init :: proc "contextless" () -> History_Stack {
	return {current_index = -1}
}

// history_navigate parses `raw_url`, truncates forward entries past
// current_index, and appends the new entry (evicting the oldest entry if full).
// Refuses malformed URLs without mutating `stack`.
history_navigate :: proc "contextless" (
	stack: ^History_Stack,
	raw_url: string,
) -> (origin: Web_Origin, refusal: Origin_Browser_Refusal) {
	if stack == nil {
		return {}, .Null_State
	}
	parsed, err := origin_parse_url(raw_url)
	if err != .None {
		return {}, err
	}

	next_pos := int(stack.current_index) + 1
	if next_pos < 0 {
		next_pos = 0
	}
	if next_pos >= HISTORY_CAPACITY {
		// Evict oldest entry to stay within bounded HISTORY_CAPACITY.
		for i in 1 ..< HISTORY_CAPACITY {
			stack.entries[i - 1] = stack.entries[i]
		}
		next_pos = HISTORY_CAPACITY - 1
	}

	entry := History_Entry{
		url_len = u16(len(raw_url)),
		origin  = parsed,
	}
	copy(entry.url[:len(raw_url)], raw_url)
	stack.entries[next_pos] = entry
	stack.current_index = i32(next_pos)
	stack.count = u16(next_pos + 1)
	return parsed, .None
}

history_back :: proc "contextless" (stack: ^History_Stack) -> (entry: ^History_Entry, refusal: Origin_Browser_Refusal) {
	if stack == nil {
		return nil, .Null_State
	}
	if stack.current_index <= 0 || int(stack.current_index) >= int(stack.count) {
		return nil, .No_Back_Entry
	}
	stack.current_index -= 1
	return &stack.entries[stack.current_index], .None
}

history_forward :: proc "contextless" (stack: ^History_Stack) -> (entry: ^History_Entry, refusal: Origin_Browser_Refusal) {
	if stack == nil {
		return nil, .Null_State
	}
	if stack.current_index < 0 || int(stack.current_index) + 1 >= int(stack.count) {
		return nil, .No_Forward_Entry
	}
	stack.current_index += 1
	return &stack.entries[stack.current_index], .None
}

history_current :: proc "contextless" (stack: ^History_Stack) -> (entry: ^History_Entry, ok: bool) {
	if stack == nil || stack.current_index < 0 || int(stack.current_index) >= int(stack.count) {
		return nil, false
	}
	return &stack.entries[stack.current_index], true
}

// ---- Safe application/x-www-form-urlencoded encoder.

// form_encode_urlencoded encodes `fields` into `out` following WHATWG
// application/x-www-form-urlencoded rules (' ' -> '+', unreserved bytes kept,
// all others uppercase %XX). Refuses Buffer_Too_Small with zero mutation.
form_encode_urlencoded :: proc "contextless" (
	fields: []Form_Field,
	out: []u8,
) -> (written: int, refusal: Origin_Browser_Refusal) {
	// Pass 1: compute exact encoded length before writing any byte.
	needed := 0
	for field, idx in fields {
		if idx > 0 {
			needed += 1
		}
		needed += form_encoded_len(field.name)
		needed += 1
		needed += form_encoded_len(field.value)
	}
	if needed > len(out) {
		return 0, .Buffer_Too_Small
	}

	// Pass 2: emit encoded bytes.
	pos := 0
	for field, idx in fields {
		if idx > 0 {
			out[pos] = '&'
			pos += 1
		}
		pos += form_encode_bytes(field.name, out[pos:])
		out[pos] = '='
		pos += 1
		pos += form_encode_bytes(field.value, out[pos:])
	}
	return pos, .None
}

// ---- Private helpers.

@(private = "file")
ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

@(private = "file")
ascii_has_prefix_fold :: proc "contextless" (s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if ascii_lower(s[i]) != ascii_lower(prefix[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
parse_port_u16 :: proc "contextless" (s: string) -> (port: u16, ok: bool) {
	if len(s) == 0 || len(s) > 5 {
		return 0, false
	}
	val: u32 = 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		val = val * 10 + u32(ch - '0')
		if val > 65535 {
			return 0, false
		}
	}
	if val == 0 {
		return 0, false
	}
	return u16(val), true
}

@(private = "file")
is_form_unreserved :: proc "contextless" (b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') ||
	       b == '*' || b == '-' || b == '.' || b == '_'
}

@(private = "file")
form_encoded_len :: proc "contextless" (s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		b := s[i]
		if b == ' ' || is_form_unreserved(b) {
			n += 1
		} else {
			n += 3
		}
	}
	return n
}

@(private = "file")
form_encode_bytes :: proc "contextless" (s: string, out: []u8) -> int {
	hex := "0123456789ABCDEF"
	pos := 0
	for i in 0 ..< len(s) {
		b := s[i]
		if b == ' ' {
			out[pos] = '+'
			pos += 1
		} else if is_form_unreserved(b) {
			out[pos] = b
			pos += 1
		} else {
			out[pos] = '%'
			out[pos + 1] = hex[b >> 4]
			out[pos + 2] = hex[b & 0x0F]
			pos += 3
		}
	}
	return pos
}
