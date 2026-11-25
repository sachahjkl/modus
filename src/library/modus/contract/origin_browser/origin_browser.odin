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
		scheme = scheme,
		port   = default_port,
	}

	if host_raw[0] == '[' {
		// Strict RFC 4291 IPv6 literal parser + RFC 5952 canonical lowercase
		// compressed output so `[::1]` and `[0:0:0:0:0:0:0:1]` normalize identically.
		inner := host_raw[1:len(host_raw) - 1]
		groups, ipv6_ok := parse_ipv6_groups(inner)
		if !ipv6_ok {
			return {}, .Bad_Host_Byte
		}
		written, fmt_ok := format_ipv6_canonical(groups, out.host[:])
		if !fmt_ok {
			return {}, .Host_Too_Long
		}
		out.host_len = u16(written)
	} else {
		// Validate DNS/IPv4 host characters (no leading/trailing/double dot).
		if !normalize_dns_host(host_raw, out.host[:]) {
			return {}, .Bad_Host_Byte
		}
		out.host_len = u16(len(host_raw))
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
	local_origin := origin
	if !origin_host_is_canonical(string(local_origin.host[:local_origin.host_len])) {
		return 0, false, .Bad_Host_Byte
	}
	if local_origin.port == 0 {
		return 0, false, .Bad_Port
	}

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
	if table.next_process_id == max(u64) {
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
	if int(stack.count) > HISTORY_CAPACITY {
		return {}, .Table_Full
	}
	parsed, err := origin_parse_url(raw_url)
	if err != .None {
		return {}, err
	}

	next_pos: int
	if stack.count == 0 {
		// Zero-initialized History_Stack{} starts cleanly at slot 0.
		next_pos = 0
	} else {
		next_pos = int(stack.current_index) + 1
		if next_pos < 0 {
			next_pos = 0
		}
		if next_pos > int(stack.count) {
			next_pos = int(stack.count)
		}
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
hex_digit_value :: proc "contextless" (b: u8) -> (val: u16, ok: bool) {
	switch b {
	case '0' ..= '9':
		return u16(b - '0'), true
	case 'a' ..= 'f':
		return u16(b - 'a' + 10), true
	case 'A' ..= 'F':
		return u16(b - 'A' + 10), true
	}
	return 0, false
}

// parse_ipv6_groups parses a pure RFC 4291 hex IPv6 address (without brackets)
// into 8 x u16 groups, enforcing at most one `::`, 1..4 hex digits per group,
// and exact group count (refusing `[::::]`, `[...]`, `[1.2.3.4]`, `[::1::2]`).
@(private = "file")
parse_ipv6_groups :: proc "contextless" (inner: string) -> (groups: [8]u16, ok: bool) {
	if len(inner) < 2 {
		return {}, false
	}
	left: [8]u16
	right: [8]u16
	left_count := 0
	right_count := 0
	saw_double_colon := false

	i := 0
	if inner[0] == ':' {
		if inner[1] != ':' {
			return {}, false
		}
		saw_double_colon = true
		i = 2
		if i == len(inner) {
			return {}, true
		}
	}

	for i < len(inner) {
		// Parse one 1..4 hex-digit group.
		g_start := i
		val: u16 = 0
		digits := 0
		for i < len(inner) && inner[i] != ':' {
			d, d_ok := hex_digit_value(inner[i])
			if !d_ok || digits >= 4 {
				return {}, false
			}
			val = (val << 4) | d
			digits += 1
			i += 1
		}
		if i == g_start || digits == 0 {
			return {}, false
		}
		if !saw_double_colon {
			if left_count >= 8 {
				return {}, false
			}
			left[left_count] = val
			left_count += 1
		} else {
			if right_count >= 8 {
				return {}, false
			}
			right[right_count] = val
			right_count += 1
		}

		if i == len(inner) {
			break
		}
		// Must be ':' separator or '::' compression marker.
		if inner[i] != ':' {
			return {}, false
		}
		if i + 1 >= len(inner) {
			// Trailing single ':' is malformed.
			return {}, false
		}
		if inner[i + 1] == ':' {
			if saw_double_colon {
				return {}, false
			}
			saw_double_colon = true
			i += 2
			if i == len(inner) {
				break
			}
			if inner[i] == ':' {
				// Triple ':::' is malformed.
				return {}, false
			}
		} else {
			i += 1
		}
	}

	if saw_double_colon {
		// RFC 4291: `::` must compress at least one zero group.
		if left_count + right_count >= 8 {
			return {}, false
		}
		for k in 0 ..< left_count {
			groups[k] = left[k]
		}
		offset := 8 - right_count
		for k in 0 ..< right_count {
			groups[offset + k] = right[k]
		}
		return groups, true
	}

	if left_count != 8 {
		return {}, false
	}
	return left, true
}

// format_ipv6_canonical emits RFC 5952 canonical lowercase compressed `[ipv6]`
// form into `out` (compressing the leftmost longest run of >= 2 zero groups).
@(private = "file")
format_ipv6_canonical :: proc "contextless" (groups: [8]u16, out: []u8) -> (written: int, ok: bool) {
	// Find leftmost longest run of consecutive zero groups of length >= 2.
	best_start := -1
	best_len := 0
	run_start := -1
	run_len := 0
	for i in 0 ..< 8 {
		if groups[i] == 0 {
			if run_start < 0 {
				run_start = i
				run_len = 1
			} else {
				run_len += 1
			}
			if run_len > best_len {
				best_start = run_start
				best_len = run_len
			}
		} else {
			run_start = -1
			run_len = 0
		}
	}
	if best_len < 2 {
		best_start = -1
		best_len = 0
	}

	// Maximum canonical bracketed IPv6 length is `[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]` (41 bytes).
	if len(out) < 41 {
		return 0, false
	}

	hex := "0123456789abcdef"
	pos := 0
	out[pos] = '['
	pos += 1

	i := 0
	for i < 8 {
		if best_len >= 2 && i == best_start {
			out[pos] = ':'
			out[pos + 1] = ':'
			pos += 2
			i += best_len
			continue
		}
		if i > 0 && !(best_len >= 2 && i == best_start + best_len) {
			out[pos] = ':'
			pos += 1
		}
		g := groups[i]
		if g == 0 {
			out[pos] = '0'
			pos += 1
		} else {
			started := false
			for shift := u32(12); ; shift -= 4 {
				nib := (g >> shift) & 0xF
				if nib != 0 || started {
					out[pos] = hex[nib]
					pos += 1
					started = true
				}
				if shift == 0 {
					break
				}
			}
		}
		i += 1
	}

	out[pos] = ']'
	pos += 1
	return pos, true
}

@(private = "file")
normalize_dns_host :: proc "contextless" (host_raw: string, out: []u8) -> bool {
	if len(host_raw) == 0 || len(host_raw) > len(out) {
		return false
	}
	if host_raw[0] == '.' || host_raw[len(host_raw) - 1] == '.' || host_raw[0] == '-' || host_raw[len(host_raw) - 1] == '-' {
		return false
	}
	prev_dot := false
	for i in 0 ..< len(host_raw) {
		low := ascii_lower(host_raw[i])
		valid := (low >= 'a' && low <= 'z') || (low >= '0' && low <= '9') || low == '-' || low == '.'
		if !valid {
			return false
		}
		if low == '.' {
			if prev_dot {
				return false
			}
			prev_dot = true
		} else {
			prev_dot = false
		}
		out[i] = low
	}
	return true
}

// origin_host_is_canonical verifies that a caller-supplied Web_Origin host is
// already in canonical lowercase DNS or RFC 5952 bracketed IPv6 form.
@(private = "file")
origin_host_is_canonical :: proc "contextless" (host: string) -> bool {
	if len(host) == 0 || len(host) > ORIGIN_HOST_MAX_BYTES {
		return false
	}
	if host[0] == '[' {
		if len(host) < 4 || host[len(host) - 1] != ']' {
			return false
		}
		groups, ok := parse_ipv6_groups(host[1:len(host) - 1])
		if !ok {
			return false
		}
		canon_buf: [64]u8
		n, fmt_ok := format_ipv6_canonical(groups, canon_buf[:])
		return fmt_ok && string(canon_buf[:n]) == host
	}
	if host[0] == '.' || host[len(host) - 1] == '.' || host[0] == '-' || host[len(host) - 1] == '-' {
		return false
	}
	prev_dot := false
	for i in 0 ..< len(host) {
		b := host[i]
		valid := (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-' || b == '.'
		if !valid {
			return false
		}
		if b == '.' {
			if prev_dot {
				return false
			}
			prev_dot = true
		} else {
			prev_dot = false
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
