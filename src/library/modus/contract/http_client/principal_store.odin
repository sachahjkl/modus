// Per-principal isolated cookie jar and HTTP response cache, in memory of
// the caller that grows. Isolated strictly by principal_id so principals can
// never read, overwrite, or evict each other's cookies or cached responses.
// Zero heap allocations.
package http_client

import "base:intrinsics"
import "modus:contract/enum_word"

// The jar and the cache are in memory of the caller, which grows (the grow
// procedures below): they hold the cookies and the responses of any count
// of principals, and the budget of the caller bounds them. The sizes of
// one cookie are those that RFC 6265 (section 6.1) asks a client to keep:
// 4096 bytes of a name and its value, a host of DNS (RFC 1035) and a path
// of an address of the web.
MAX_ORIGIN_HOST_LEN :: 253
MAX_COOKIE_NAME_LEN :: 256
MAX_COOKIE_VALUE_LEN :: 4096
MAX_COOKIE_DOMAIN_LEN :: 253
MAX_COOKIE_PATH_LEN :: 1024
MAX_CACHE_TARGET_LEN :: 2048

// Scheme of a web origin. Zero is invalid and refused at the border.
Origin_Scheme :: enum u8 {
	Http  = 1,
	Https = 2,
}

// SameSite attribute policy for cookies.
Same_Site_Policy :: enum u8 {
	None   = 1,
	Lax    = 2,
	Strict = 3,
}

// Refusal codes for cookie jar and response cache operations.
Store_Refusal :: enum u8 {
	None                     = 0,
	Invalid_Scheme           = 1,
	Invalid_Host             = 2,
	Invalid_Path             = 3,
	Invalid_Cookie           = 4,
	Domain_Mismatch          = 5,
	Secure_Required          = 6,
	Principal_Quota_Exceeded = 7,
	Buffer_Too_Small         = 8,
	Not_Cacheable            = 9,
	Body_Too_Large           = 10,
}

// Strict border for Origin_Scheme.
origin_scheme_of_word :: proc "contextless" (word: u8) -> (scheme: Origin_Scheme, ok: bool) {
	return enum_word.member_of_word(Origin_Scheme, u64(word))
}

// Tuple identifying a principal and network origin.
Origin_Key :: struct {
	principal_id: u64,
	scheme:       Origin_Scheme,
	host:         [MAX_ORIGIN_HOST_LEN]u8,
	host_len:     u16,
	port:         u16,
}

// origin_key_make constructs and validates a normalized Origin_Key.
origin_key_make :: proc "contextless" (principal_id: u64, scheme: Origin_Scheme, host: string, port: u16) -> (key: Origin_Key, refusal: Store_Refusal) {
	s, s_ok := origin_scheme_of_word(u8(scheme))
	if !s_ok {
		return {}, .Invalid_Scheme
	}
	hbytes := transmute([]u8)host
	if len(hbytes) == 0 || len(hbytes) > MAX_ORIGIN_HOST_LEN {
		return {}, .Invalid_Host
	}
	hok, hinj := is_valid_host(hbytes)
	if !hok || hinj {
		return {}, .Invalid_Host
	}
	key.principal_id = principal_id
	key.scheme = s
	key.port = port
	key.host_len = u16(len(hbytes))
	for i := 0; i < len(hbytes); i += 1 {
		key.host[i] = ascii_lower(hbytes[i])
	}
	return key, .None
}

// Single cookie record belonging to one principal.
Cookie_Entry :: struct {
	used:            bool,
	principal_id:    u64,
	scheme:          Origin_Scheme,
	port:            u16,
	host_only:       bool,
	domain:          [MAX_COOKIE_DOMAIN_LEN]u8,
	domain_len:      u16,
	path:            [MAX_COOKIE_PATH_LEN]u8,
	path_len:        u16,
	name:            [MAX_COOKIE_NAME_LEN]u8,
	name_len:        u16,
	value:           [MAX_COOKIE_VALUE_LEN]u8,
	value_len:       u16,
	secure:          bool,
	http_only:       bool,
	same_site:       Same_Site_Policy,
	has_expiry:      bool,
	expires_at_unix: i64,
	last_used_seq:   u64,
}

// Cookie_Jar_Grow makes the jar hold at least wanted entries: it sets
// entries to a longer slice that keeps the entries before it. false: the
// memory cannot grow.
Cookie_Jar_Grow :: #type proc "contextless" (jar: ^Cookie_Jar, wanted: int) -> bool

// The cookie jar of the principals: one list of entries, each with its
// principal, in memory of the caller. A principal reads, replaces and
// evicts only its own entries: past cookies_of_a_principal (0: the memory
// alone bounds it), or when the memory cannot grow, a new cookie takes the
// place of the cookie of the same principal used least. A principal with
// no cookie never takes the place of the cookie of another.
Cookie_Jar :: struct {
	entries:                []Cookie_Entry,
	cookies_of_a_principal: int,
	access_seq:             u64,
	grow:                   Cookie_Jar_Grow,
	grow_data:              rawptr,
}

// Single cached HTTP response belonging to one principal.
Cache_Entry :: struct {
	used:            bool,
	principal_id:    u64,
	scheme:          Origin_Scheme,
	host:            [MAX_ORIGIN_HOST_LEN]u8,
	host_len:        u16,
	port:            u16,
	target:          [MAX_CACHE_TARGET_LEN]u8,
	target_len:      u16,
	status_code:     u16,
	stored_at_unix:  i64,
	max_age_seconds: i64,
	must_revalidate: bool,
	body_offset:     int, // The place of the body in the bodies of the cache.
	body_len:        int,
	last_used_seq:   u64,
}

// The parts of the memory of a response cache.
Cache_Part :: enum u8 {
	Entries = 0,
	Bodies  = 1, // The bytes of the bodies, one after the other.
}

// Response_Cache_Grow makes a part of the cache hold at least wanted
// entries or bytes, as Cookie_Jar_Grow does for a jar.
Response_Cache_Grow :: #type proc "contextless" (cache: ^Response_Cache, part: Cache_Part, wanted: int) -> bool

// The response cache of the principals: one list of entries, each with
// its principal, and the bytes of their bodies, in memory of the caller.
// A body has the size of its response: the memory bounds it. The places
// of the bodies that the cache no longer holds come back when the bodies
// are full (cache_bodies_compact). Eviction is per principal, as in the jar.
Response_Cache :: struct {
	entries:                  []Cache_Entry,
	bodies:                   []u8,
	bodies_used:              int,
	entries_of_a_principal:   int,
	access_seq:               u64,
	grow:                     Response_Cache_Grow,
	grow_data:                rawptr,
}

// The slot that a new entry of a principal takes, or -1: the match, else
// the least used entry of the principal past its quota, else a free
// entry, else a new entry that the memory grows to, else the least used
// entry of the principal.
@(private = "file")
slot_choose :: proc "contextless" (match_idx, free_idx, oldest_idx, owned, quota, held: int, grown: bool) -> int {
	switch {
	case match_idx >= 0:
		return match_idx
	case quota > 0 && owned >= quota && oldest_idx >= 0:
		return oldest_idx
	case free_idx >= 0:
		return free_idx
	case grown:
		return held
	}
	return oldest_idx
}

@(private = "file")
slice_equal :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
host_is_ip_literal :: proc "contextless" (host: []u8) -> bool {
	if len(host) == 0 {
		return true
	}
	// IPv6 literal contains ':' or brackets.
	for b in host {
		if b == ':' || b == '[' || b == ']' {
			return true
		}
	}
	// IPv4 dotted-decimal literal: only digits and dots with 4 non-empty octets.
	dots := 0
	digits_in_label := 0
	for b in host {
		if b == '.' {
			if digits_in_label == 0 {
				return false
			}
			dots += 1
			digits_in_label = 0
		} else if b >= '0' && b <= '9' {
			digits_in_label += 1
		} else {
			return false
		}
	}
	return dots == 3 && digits_in_label > 0
}

@(private = "file")
origin_valid :: proc "contextless" (origin: ^Origin_Key) -> bool {
	if origin == nil || origin.host_len == 0 || int(origin.host_len) > MAX_ORIGIN_HOST_LEN {
		return false
	}
	_, ok := origin_scheme_of_word(u8(origin.scheme))
	return ok
}

@(private = "file")
domain_matches :: proc "contextless" (request_host: []u8, cookie_domain: []u8, host_only: bool) -> bool {
	if host_only {
		return slice_equal(request_host, cookie_domain)
	}
	if slice_equal(request_host, cookie_domain) {
		return true
	}
	if len(request_host) <= len(cookie_domain) {
		return false
	}
	diff := len(request_host) - len(cookie_domain)
	return request_host[diff - 1] == '.' && slice_equal(request_host[diff:], cookie_domain)
}

@(private = "file")
path_matches :: proc "contextless" (request_path: []u8, cookie_path: []u8) -> bool {
	if len(cookie_path) == 0 || len(request_path) < len(cookie_path) {
		return false
	}
	if !slice_equal(request_path[:len(cookie_path)], cookie_path) {
		return false
	}
	if len(request_path) == len(cookie_path) {
		return true
	}
	if cookie_path[len(cookie_path) - 1] == '/' {
		return true
	}
	return request_path[len(cookie_path)] == '/'
}

@(private = "file")
default_cookie_path :: proc "contextless" (request_path: []u8, out: []u8) -> int {
	if len(request_path) == 0 || request_path[0] != '/' {
		out[0] = '/'
		return 1
	}
	last_slash := 0
	for i := 1; i < len(request_path); i += 1 {
		if request_path[i] == '/' {
			last_slash = i
		}
	}
	if last_slash == 0 {
		out[0] = '/'
		return 1
	}
	n := min(last_slash, len(out))
	copy(out[:n], request_path[:n])
	return n
}

@(private = "file")
parse_signed_i64 :: proc "contextless" (bytes: []u8) -> (val: i64, ok: bool) {
	if len(bytes) == 0 {
		return 0, false
	}
	neg := false
	idx := 0
	if bytes[0] == '-' {
		neg = true
		idx = 1
	} else if bytes[0] == '+' {
		idx = 1
	}
	if idx >= len(bytes) {
		return 0, false
	}
	uval, uok := parse_decimal_u64(bytes[idx:])
	if !uok || uval > u64(max(i64)) {
		return 0, false
	}
	return -i64(uval) if neg else i64(uval), true
}

// parse_http_date_imf parses IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") into Unix seconds.
parse_http_date_imf :: proc "contextless" (text: []u8) -> (unix_sec: i64, ok: bool) {
	if len(text) != 29 {
		return 0, false
	}
	if text[3] != ',' || text[4] != ' ' || text[7] != ' ' || text[11] != ' ' ||
	   text[16] != ' ' || text[19] != ':' || text[22] != ':' || text[25] != ' ' ||
	   text[26] != 'G' || text[27] != 'M' || text[28] != 'T' {
		return 0, false
	}
	day_u, dok := parse_decimal_u64(text[5:7])
	year_u, yok := parse_decimal_u64(text[12:16])
	hour_u, hok := parse_decimal_u64(text[17:19])
	min_u, mok := parse_decimal_u64(text[20:22])
	sec_u, sok := parse_decimal_u64(text[23:25])
	if !dok || !yok || !hok || !mok || !sok {
		return 0, false
	}
	if year_u < 1970 || day_u < 1 || day_u > 31 || hour_u > 23 || min_u > 59 || sec_u > 59 {
		return 0, false
	}
	month: i64 = 0
	mon := text[8:11]
	switch {
	case ascii_equal_ci(mon, "jan"): month = 1
	case ascii_equal_ci(mon, "feb"): month = 2
	case ascii_equal_ci(mon, "mar"): month = 3
	case ascii_equal_ci(mon, "apr"): month = 4
	case ascii_equal_ci(mon, "may"): month = 5
	case ascii_equal_ci(mon, "jun"): month = 6
	case ascii_equal_ci(mon, "jul"): month = 7
	case ascii_equal_ci(mon, "aug"): month = 8
	case ascii_equal_ci(mon, "sep"): month = 9
	case ascii_equal_ci(mon, "oct"): month = 10
	case ascii_equal_ci(mon, "nov"): month = 11
	case ascii_equal_ci(mon, "dec"): month = 12
	case:
		return 0, false
	}
	y := i64(year_u)
	if month <= 2 {
		y -= 1
	}
	era := y / 400
	yoe := y - era * 400
	doy := (153 * (month + (9 if month <= 2 else -3)) + 2) / 5 + i64(day_u) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := era * 146097 + doe - 719468
	return days * 86400 + i64(hour_u) * 3600 + i64(min_u) * 60 + i64(sec_u), true
}

// cookie_jar_set_from_header parses one Set-Cookie header and stores it strictly among the entries of origin.principal_id.
cookie_jar_set_from_header :: proc "contextless" (jar: ^Cookie_Jar, origin: ^Origin_Key, request_path: string, set_cookie: string, now_unix: i64) -> Store_Refusal {
	_, s_ok := origin_scheme_of_word(u8(origin.scheme))
	if !s_ok {
		return .Invalid_Scheme
	}
	if origin.host_len == 0 || origin.host_len > MAX_ORIGIN_HOST_LEN {
		return .Invalid_Host
	}
	raw := transmute([]u8)set_cookie
	if len(raw) == 0 || has_crlf_or_nul(raw) {
		return .Invalid_Cookie
	}

	semi := -1
	for i := 0; i < len(raw); i += 1 {
		if raw[i] == ';' {
			semi = i
			break
		}
	}
	nv := raw if semi < 0 else raw[:semi]
	eq := -1
	for i := 0; i < len(nv); i += 1 {
		if nv[i] == '=' {
			eq = i
			break
		}
	}
	if eq <= 0 {
		return .Invalid_Cookie
	}
	cname := trim_ows(nv[:eq])
	cval := trim_ows(nv[eq + 1:])
	if len(cname) == 0 || len(cname) > MAX_COOKIE_NAME_LEN || len(cval) > MAX_COOKIE_VALUE_LEN {
		return .Invalid_Cookie
	}
	for b in cname {
		if !is_tchar(b) {
			return .Invalid_Cookie
		}
	}

	entry: Cookie_Entry
	entry.used = true
	entry.principal_id = origin.principal_id
	entry.scheme = origin.scheme
	entry.port = origin.port
	entry.host_only = true
	copy(entry.domain[:origin.host_len], origin.host[:origin.host_len])
	entry.domain_len = origin.host_len
	entry.path_len = u16(default_cookie_path(transmute([]u8)request_path, entry.path[:]))
	copy(entry.name[:len(cname)], cname)
	entry.name_len = u16(len(cname))
	copy(entry.value[:len(cval)], cval)
	entry.value_len = u16(len(cval))
	entry.same_site = .Lax

	has_max_age := false
	delete_now := false

	if semi >= 0 {
		rest := raw[semi + 1:]
		for len(rest) > 0 {
			next_semi := -1
			for i := 0; i < len(rest); i += 1 {
				if rest[i] == ';' {
					next_semi = i
					break
				}
			}
			attr := trim_ows(rest if next_semi < 0 else rest[:next_semi])
			rest = nil if next_semi < 0 else rest[next_semi + 1:]
			if len(attr) == 0 {
				continue
			}

			aeq := -1
			for i := 0; i < len(attr); i += 1 {
				if attr[i] == '=' {
					aeq = i
					break
				}
			}
			aname := trim_ows(attr if aeq < 0 else attr[:aeq])
			aval := trim_ows(nil if aeq < 0 else attr[aeq + 1:])

			if ascii_equal_ci(aname, "secure") {
				entry.secure = true
			} else if ascii_equal_ci(aname, "httponly") {
				entry.http_only = true
			} else if ascii_equal_ci(aname, "domain") {
				if host_is_ip_literal(origin.host[:origin.host_len]) {
					return .Domain_Mismatch
				}
				dom := aval
				if len(dom) > 0 && dom[0] == '.' {
					dom = dom[1:]
				}
				if len(dom) == 0 || len(dom) > MAX_COOKIE_DOMAIN_LEN || dom[0] == '.' || dom[len(dom) - 1] == '.' {
					return .Domain_Mismatch
				}
				has_dot := false
				norm_dom: [MAX_COOKIE_DOMAIN_LEN]u8
				for i := 0; i < len(dom); i += 1 {
					if dom[i] == '.' {
						if i > 0 && dom[i - 1] == '.' {
							return .Domain_Mismatch
						}
						has_dot = true
					}
					norm_dom[i] = ascii_lower(dom[i])
				}
				if !has_dot || host_is_ip_literal(norm_dom[:len(dom)]) {
					return .Domain_Mismatch
				}
				if !domain_matches(origin.host[:origin.host_len], norm_dom[:len(dom)], false) {
					return .Domain_Mismatch
				}
				copy(entry.domain[:len(dom)], norm_dom[:len(dom)])
				entry.domain_len = u16(len(dom))
				entry.host_only = false
			} else if ascii_equal_ci(aname, "path") {
				if len(aval) == 0 || aval[0] != '/' || len(aval) > MAX_COOKIE_PATH_LEN {
					return .Invalid_Path
				}
				copy(entry.path[:len(aval)], aval)
				entry.path_len = u16(len(aval))
			} else if ascii_equal_ci(aname, "samesite") {
				if ascii_equal_ci(aval, "strict") {
					entry.same_site = .Strict
				} else if ascii_equal_ci(aval, "lax") {
					entry.same_site = .Lax
				} else if ascii_equal_ci(aval, "none") {
					entry.same_site = .None
				} else {
					return .Invalid_Cookie
				}
			} else if ascii_equal_ci(aname, "max-age") {
				ma, ma_ok := parse_signed_i64(aval)
				if !ma_ok {
					return .Invalid_Cookie
				}
				has_max_age = true
				entry.has_expiry = true
				if ma <= 0 {
					delete_now = true
				} else {
					delete_now = false
					if now_unix > 0 && ma > max(i64) - now_unix {
						entry.expires_at_unix = max(i64)
					} else {
						entry.expires_at_unix = now_unix + ma
					}
				}
			} else if ascii_equal_ci(aname, "expires") {
				if !has_max_age {
					exp, exp_ok := parse_http_date_imf(aval)
					if exp_ok {
						entry.has_expiry = true
						if exp <= now_unix {
							delete_now = true
						} else {
							entry.expires_at_unix = exp
						}
					}
				}
			}
		}
	}

	if entry.secure && origin.scheme != .Https {
		return .Secure_Required
	}
	if entry.same_site == .None && !entry.secure {
		return .Secure_Required
	}

	match_idx := -1
	free_idx := -1
	oldest_idx := -1
	oldest_seq := max(u64)
	owned := 0

	for i := 0; i < len(jar.entries); i += 1 {
		cur := &jar.entries[i]
		if cur.used && cur.has_expiry && now_unix >= cur.expires_at_unix {
			cur.used = false
		}
		if !cur.used {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if cur.principal_id != origin.principal_id {
			continue
		}
		owned += 1
		if cur.port == entry.port &&
		   slice_equal(cur.name[:cur.name_len], entry.name[:entry.name_len]) &&
		   slice_equal(cur.domain[:cur.domain_len], entry.domain[:entry.domain_len]) &&
		   slice_equal(cur.path[:cur.path_len], entry.path[:entry.path_len]) {
			match_idx = i
			break
		}
		if cur.last_used_seq < oldest_seq {
			oldest_seq = cur.last_used_seq
			oldest_idx = i
		}
	}

	if match_idx >= 0 && jar.entries[match_idx].secure && origin.scheme != .Https {
		return .Secure_Required
	}
	if delete_now {
		if match_idx >= 0 {
			jar.entries[match_idx] = {}
		}
		return .None
	}

	held := len(jar.entries)
	grown := false
	if match_idx < 0 && free_idx < 0 && !(jar.cookies_of_a_principal > 0 && owned >= jar.cookies_of_a_principal) && jar.grow != nil {
		grown = jar.grow(jar, held + 1) && len(jar.entries) > held
	}
	target_idx := slot_choose(match_idx, free_idx, oldest_idx, owned, jar.cookies_of_a_principal, held, grown)
	if target_idx < 0 {
		return .Principal_Quota_Exceeded
	}
	jar.access_seq += 1
	entry.last_used_seq = jar.access_seq
	jar.entries[target_idx] = entry
	return .None
}

// cookie_jar_format_header builds the Cookie request header strictly from the entries of origin.principal_id.
// Enforces Secure (never on HTTP), HttpOnly (never for script), SameSite, Domain, Path, and expiry.
cookie_jar_format_header :: proc "contextless" (jar: ^Cookie_Jar, origin: ^Origin_Key, request_path: string, is_same_site: bool, is_top_level_nav: bool, for_script: bool, now_unix: i64, out: []u8) -> (written: int, refusal: Store_Refusal) {
	if !origin_valid(origin) {
		return 0, .Invalid_Scheme
	}

	req_host := origin.host[:origin.host_len]
	req_path := transmute([]u8)request_path
	pos := 0
	count := 0

	for i := 0; i < len(jar.entries); i += 1 {
		c := &jar.entries[i]
		if !c.used {
			continue
		}
		if c.principal_id != origin.principal_id {
			continue
		}
		if c.has_expiry && now_unix >= c.expires_at_unix {
			c.used = false
			continue
		}
		if c.secure && origin.scheme != .Https {
			continue
		}
		if c.http_only && for_script {
			continue
		}
		switch c.same_site {
		case .Strict:
			if !is_same_site {
				continue
			}
		case .Lax:
			if !is_same_site && !is_top_level_nav {
				continue
			}
		case .None:
			if origin.scheme != .Https {
				continue
			}
		}
		if c.port != origin.port {
			continue
		}
		if !domain_matches(req_host, c.domain[:c.domain_len], c.host_only) {
			continue
		}
		if !path_matches(req_path, c.path[:c.path_len]) {
			continue
		}

		need := int(c.name_len) + 1 + int(c.value_len) + (2 if count > 0 else 0)
		if pos + need > len(out) {
			return 0, .Buffer_Too_Small
		}
		if count > 0 {
			out[pos] = ';'
			out[pos + 1] = ' '
			pos += 2
		}
		copy(out[pos:], c.name[:c.name_len])
		pos += int(c.name_len)
		out[pos] = '='
		pos += 1
		copy(out[pos:], c.value[:c.value_len])
		pos += int(c.value_len)
		count += 1
		jar.access_seq += 1
		c.last_used_seq = jar.access_seq
	}
	return pos, .None
}

@(private = "file")
is_cacheable_status :: proc "contextless" (status: u16) -> bool {
	switch status {
	case 200, 203, 204, 206, 300, 301, 404, 410:
		return true
	}
	return false
}

// Cache-Control directive parse result.
Cache_Directives :: struct {
	no_store:        bool,
	no_cache:        bool,
	has_max_age:     bool,
	max_age_seconds: i64,
}

// parse_cache_control parses Cache-Control directives (no-store, no-cache, max-age).
parse_cache_control :: proc "contextless" (header_value: string) -> Cache_Directives {
	res: Cache_Directives
	rest := transmute([]u8)header_value
	for len(rest) > 0 {
		comma := -1
		for i := 0; i < len(rest); i += 1 {
			if rest[i] == ',' {
				comma = i
				break
			}
		}
		part := trim_ows(rest if comma < 0 else rest[:comma])
		rest = nil if comma < 0 else rest[comma + 1:]
		if len(part) == 0 {
			continue
		}
		eq := -1
		for i := 0; i < len(part); i += 1 {
			if part[i] == '=' {
				eq = i
				break
			}
		}
		dname := trim_ows(part if eq < 0 else part[:eq])
		dval := trim_ows(nil if eq < 0 else part[eq + 1:])
		if ascii_equal_ci(dname, "no-store") {
			res.no_store = true
		} else if ascii_equal_ci(dname, "no-cache") {
			res.no_cache = true
		} else if ascii_equal_ci(dname, "max-age") {
			if ma, ok := parse_decimal_u64(dval); ok && ma <= u64(max(i64)) {
				res.has_max_age = true
				res.max_age_seconds = i64(ma)
			}
		}
	}
	return res
}

// cache_entry_names says if an entry of a principal is the response of an
// origin and a target.
@(private = "file")
cache_entry_names :: proc "contextless" (e: ^Cache_Entry, origin: ^Origin_Key, target: []u8) -> bool {
	return e.used && e.principal_id == origin.principal_id && e.scheme == origin.scheme && e.port == origin.port &&
	       slice_equal(e.host[:e.host_len], origin.host[:origin.host_len]) &&
	       slice_equal(e.target[:e.target_len], target)
}

// cache_bodies_compact moves the bodies of the entries that the cache
// holds to the start of the bodies, in their order, so the places of the
// bodies that it no longer holds come back. Each body moves down, never
// over a body not moved yet: the next body is the one at the lowest place
// past the last one moved.
@(private = "file")
cache_bodies_compact :: proc "contextless" (cache: ^Response_Cache) {
	cursor := 0
	for {
		next := -1
		for &e, index in cache.entries {
			if e.used && e.body_len > 0 && e.body_offset >= cursor && (next < 0 || e.body_offset < cache.entries[next].body_offset) {
				next = index
			}
		}
		if next < 0 {
			break
		}
		e := &cache.entries[next]
		if e.body_offset != cursor {
			intrinsics.mem_copy(&cache.bodies[cursor], &cache.bodies[e.body_offset], e.body_len)
			e.body_offset = cursor
		}
		cursor += e.body_len
	}
	cache.bodies_used = cursor
}

// cache_body_place gives the place of a body of a size: after the bodies,
// in the memory that grows to it, or after a compaction. false: the memory
// of the cache does not hold it.
@(private = "file")
cache_body_place :: proc "contextless" (cache: ^Response_Cache, size: int) -> (place: int, ok: bool) {
	fits :: proc "contextless" (cache: ^Response_Cache, size: int) -> bool {
		return size <= len(cache.bodies) - cache.bodies_used
	}
	if !fits(cache, size) && cache.grow != nil {
		cache.grow(cache, .Bodies, cache.bodies_used + size)
	}
	if !fits(cache, size) {
		cache_bodies_compact(cache)
	}
	if !fits(cache, size) {
		return 0, false
	}
	place = cache.bodies_used
	cache.bodies_used += size
	return place, true
}

// response_cache_store stores a cacheable HTTP response strictly among the entries of origin.principal_id.
// Honors Cache-Control: no-store (never stores and purges prior entry) and max-age. A body has any size
// that the memory of the cache holds; one that it does not hold is Body_Too_Large, and the cache keeps no
// entry of it.
response_cache_store :: proc "contextless" (cache: ^Response_Cache, origin: ^Origin_Key, target: string, status_code: u16, cache_control: string, body: []u8, now_unix: i64) -> Store_Refusal {
	if !origin_valid(origin) {
		return .Invalid_Scheme
	}
	tbytes := transmute([]u8)target
	if len(tbytes) == 0 || len(tbytes) > MAX_CACHE_TARGET_LEN || tbytes[0] != '/' {
		return .Invalid_Path
	}

	cc := parse_cache_control(cache_control)
	if cc.no_store {
		for &e in cache.entries {
			if cache_entry_names(&e, origin, tbytes) {
				e = {}
			}
		}
		return .Not_Cacheable
	}
	if !is_cacheable_status(status_code) {
		return .Not_Cacheable
	}
	if !cc.has_max_age || cc.max_age_seconds <= 0 {
		return .Not_Cacheable
	}

	match_idx := -1
	free_idx := -1
	oldest_idx := -1
	oldest_seq := max(u64)
	owned := 0
	for i := 0; i < len(cache.entries); i += 1 {
		e := &cache.entries[i]
		if !e.used {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if e.principal_id != origin.principal_id {
			continue
		}
		owned += 1
		if cache_entry_names(e, origin, tbytes) {
			match_idx = i
			break
		}
		if e.last_used_seq < oldest_seq {
			oldest_seq = e.last_used_seq
			oldest_idx = i
		}
	}
	held := len(cache.entries)
	grown := false
	if match_idx < 0 && free_idx < 0 && !(cache.entries_of_a_principal > 0 && owned >= cache.entries_of_a_principal) && cache.grow != nil {
		grown = cache.grow(cache, .Entries, held + 1) && len(cache.entries) > held
	}
	slot_idx := slot_choose(match_idx, free_idx, oldest_idx, owned, cache.entries_of_a_principal, held, grown)
	if slot_idx < 0 {
		return .Principal_Quota_Exceeded
	}

	// The entry of the slot ends first: its body is free for the place of
	// the new one.
	e := &cache.entries[slot_idx]
	e^ = {}
	place, placed := cache_body_place(cache, len(body))
	if !placed {
		return .Body_Too_Large
	}
	copy(cache.bodies[place:][:len(body)], body)
	cache.access_seq += 1
	e = &cache.entries[slot_idx]
	e.used = true
	e.principal_id = origin.principal_id
	e.scheme = origin.scheme
	copy(e.host[:origin.host_len], origin.host[:origin.host_len])
	e.host_len = origin.host_len
	e.port = origin.port
	copy(e.target[:len(tbytes)], tbytes)
	e.target_len = u16(len(tbytes))
	e.status_code = status_code
	e.stored_at_unix = now_unix
	e.max_age_seconds = cc.max_age_seconds
	e.must_revalidate = cc.no_cache
	e.body_offset = place
	e.body_len = len(body)
	e.last_used_seq = cache.access_seq
	return .None
}

// response_cache_lookup retrieves a fresh cached response strictly from the entries of origin.principal_id.
response_cache_lookup :: proc "contextless" (cache: ^Response_Cache, origin: ^Origin_Key, target: string, now_unix: i64, body_out: []u8) -> (status_code: u16, body_len: int, hit: bool) {
	if !origin_valid(origin) {
		return 0, 0, false
	}
	tbytes := transmute([]u8)target
	for &e in cache.entries {
		if !cache_entry_names(&e, origin, tbytes) {
			continue
		}
		if e.must_revalidate || now_unix < e.stored_at_unix || now_unix - e.stored_at_unix >= e.max_age_seconds {
			return 0, 0, false
		}
		if e.body_len > len(body_out) {
			return 0, 0, false
		}
		copy(body_out[:e.body_len], cache.bodies[e.body_offset:][:e.body_len])
		cache.access_seq += 1
		e.last_used_seq = cache.access_seq
		return e.status_code, e.body_len, true
	}
	return 0, 0, false
}
