// Per-principal isolated cookie jar and HTTP response cache.
// Partitioned strictly by principal_id so principals can never read, overwrite,
// or evict each other's cookies or cached responses. Zero heap allocations.
package http_client

import "modus:contract/enum_word"

MAX_STORE_PRINCIPALS :: 8
COOKIES_PER_PRINCIPAL :: 32
CACHE_ENTRIES_PER_PRINCIPAL :: 8
MAX_ORIGIN_HOST_LEN :: 128
MAX_COOKIE_NAME_LEN :: 64
MAX_COOKIE_VALUE_LEN :: 256
MAX_COOKIE_DOMAIN_LEN :: 128
MAX_COOKIE_PATH_LEN :: 128
MAX_CACHE_TARGET_LEN :: 256
MAX_CACHED_BODY_SIZE :: 4096

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

// Single cookie record belonging to one principal partition.
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

// Isolated cookie storage dedicated to a single principal.
Principal_Cookie_Partition :: struct {
	occupied:     bool,
	principal_id: u64,
	entries:      [COOKIES_PER_PRINCIPAL]Cookie_Entry,
}

// Per-principal partitioned cookie jar.
Cookie_Jar :: struct {
	partitions: [MAX_STORE_PRINCIPALS]Principal_Cookie_Partition,
	access_seq: u64,
}

// Single cached HTTP response belonging to one principal partition.
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
	body:            [MAX_CACHED_BODY_SIZE]u8,
	body_len:        u16,
	last_used_seq:   u64,
}

// Isolated cache storage dedicated to a single principal.
Principal_Cache_Partition :: struct {
	occupied:     bool,
	principal_id: u64,
	entries:      [CACHE_ENTRIES_PER_PRINCIPAL]Cache_Entry,
}

// Per-principal partitioned HTTP response cache.
Response_Cache :: struct {
	partitions: [MAX_STORE_PRINCIPALS]Principal_Cache_Partition,
	access_seq: u64,
}

@(private = "file")
find_or_create_cookie_partition :: proc "contextless" (jar: ^Cookie_Jar, principal_id: u64, create: bool) -> ^Principal_Cookie_Partition {
	for i := 0; i < MAX_STORE_PRINCIPALS; i += 1 {
		if jar.partitions[i].occupied && jar.partitions[i].principal_id == principal_id {
			return &jar.partitions[i]
		}
	}
	if !create {
		return nil
	}
	for i := 0; i < MAX_STORE_PRINCIPALS; i += 1 {
		if !jar.partitions[i].occupied {
			jar.partitions[i].occupied = true
			jar.partitions[i].principal_id = principal_id
			return &jar.partitions[i]
		}
	}
	return nil
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

// cookie_jar_set_from_header parses one Set-Cookie header and stores it strictly inside origin.principal_id's partition.
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
				dom := aval
				if len(dom) > 0 && dom[0] == '.' {
					dom = dom[1:]
				}
				if len(dom) == 0 || len(dom) > MAX_COOKIE_DOMAIN_LEN {
					return .Domain_Mismatch
				}
				has_dot := false
				norm_dom: [MAX_COOKIE_DOMAIN_LEN]u8
				for i := 0; i < len(dom); i += 1 {
					if dom[i] == '.' {
						has_dot = true
					}
					norm_dom[i] = ascii_lower(dom[i])
				}
				if !has_dot {
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
					entry.expires_at_unix = now_unix + ma
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

	if entry.same_site == .None && !entry.secure {
		return .Secure_Required
	}

	partition := find_or_create_cookie_partition(jar, origin.principal_id, !delete_now)
	if partition == nil {
		if delete_now {
			return .None
		}
		return .Principal_Quota_Exceeded
	}

	match_idx := -1
	free_idx := -1
	oldest_idx := 0
	oldest_seq := max(u64)

	for i := 0; i < COOKIES_PER_PRINCIPAL; i += 1 {
		cur := &partition.entries[i]
		if cur.used && cur.has_expiry && now_unix >= cur.expires_at_unix {
			cur.used = false
		}
		if !cur.used {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
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

	if delete_now {
		if match_idx >= 0 {
			partition.entries[match_idx] = {}
		}
		return .None
	}

	jar.access_seq += 1
	entry.last_used_seq = jar.access_seq

	target_idx := match_idx
	if target_idx < 0 {
		target_idx = free_idx if free_idx >= 0 else oldest_idx
	}
	partition.entries[target_idx] = entry
	return .None
}

// cookie_jar_format_header builds the Cookie request header strictly from origin.principal_id's partition.
// Enforces Secure (never on HTTP), HttpOnly (never for script), SameSite, Domain, Path, and expiry.
cookie_jar_format_header :: proc "contextless" (jar: ^Cookie_Jar, origin: ^Origin_Key, request_path: string, is_same_site: bool, is_top_level_nav: bool, for_script: bool, now_unix: i64, out: []u8) -> (written: int, refusal: Store_Refusal) {
	_, s_ok := origin_scheme_of_word(u8(origin.scheme))
	if !s_ok {
		return 0, .Invalid_Scheme
	}
	partition := find_or_create_cookie_partition(jar, origin.principal_id, false)
	if partition == nil {
		return 0, .None
	}

	req_host := origin.host[:origin.host_len]
	req_path := transmute([]u8)request_path
	pos := 0
	count := 0

	for i := 0; i < COOKIES_PER_PRINCIPAL; i += 1 {
		c := &partition.entries[i]
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
find_or_create_cache_partition :: proc "contextless" (cache: ^Response_Cache, principal_id: u64, create: bool) -> ^Principal_Cache_Partition {
	for i := 0; i < MAX_STORE_PRINCIPALS; i += 1 {
		if cache.partitions[i].occupied && cache.partitions[i].principal_id == principal_id {
			return &cache.partitions[i]
		}
	}
	if !create {
		return nil
	}
	for i := 0; i < MAX_STORE_PRINCIPALS; i += 1 {
		if !cache.partitions[i].occupied {
			cache.partitions[i].occupied = true
			cache.partitions[i].principal_id = principal_id
			return &cache.partitions[i]
		}
	}
	return nil
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

// response_cache_store stores a cacheable HTTP response strictly inside origin.principal_id's partition.
// Honors Cache-Control: no-store (never stores and purges prior entry) and max-age.
response_cache_store :: proc "contextless" (cache: ^Response_Cache, origin: ^Origin_Key, target: string, status_code: u16, cache_control: string, body: []u8, now_unix: i64) -> Store_Refusal {
	_, s_ok := origin_scheme_of_word(u8(origin.scheme))
	if !s_ok {
		return .Invalid_Scheme
	}
	tbytes := transmute([]u8)target
	if len(tbytes) == 0 || len(tbytes) > MAX_CACHE_TARGET_LEN || tbytes[0] != '/' {
		return .Invalid_Path
	}
	if len(body) > MAX_CACHED_BODY_SIZE {
		return .Body_Too_Large
	}

	cc := parse_cache_control(cache_control)
	if cc.no_store {
		part := find_or_create_cache_partition(cache, origin.principal_id, false)
		if part != nil {
			for i := 0; i < CACHE_ENTRIES_PER_PRINCIPAL; i += 1 {
				e := &part.entries[i]
				if e.used && e.scheme == origin.scheme && e.port == origin.port &&
				   slice_equal(e.host[:e.host_len], origin.host[:origin.host_len]) &&
				   slice_equal(e.target[:e.target_len], tbytes) {
					e^ = {}
				}
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

	part := find_or_create_cache_partition(cache, origin.principal_id, true)
	if part == nil {
		return .Principal_Quota_Exceeded
	}

	match_idx := -1
	free_idx := -1
	oldest_idx := 0
	oldest_seq := max(u64)

	for i := 0; i < CACHE_ENTRIES_PER_PRINCIPAL; i += 1 {
		e := &part.entries[i]
		if !e.used {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if e.scheme == origin.scheme && e.port == origin.port &&
		   slice_equal(e.host[:e.host_len], origin.host[:origin.host_len]) &&
		   slice_equal(e.target[:e.target_len], tbytes) {
			match_idx = i
			break
		}
		if e.last_used_seq < oldest_seq {
			oldest_seq = e.last_used_seq
			oldest_idx = i
		}
	}

	slot_idx := match_idx
	if slot_idx < 0 {
		slot_idx = free_idx if free_idx >= 0 else oldest_idx
	}

	cache.access_seq += 1
	e := &part.entries[slot_idx]
	e^ = {}
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
	copy(e.body[:len(body)], body)
	e.body_len = u16(len(body))
	e.last_used_seq = cache.access_seq
	return .None
}

// response_cache_lookup retrieves a fresh cached response strictly from origin.principal_id's partition.
response_cache_lookup :: proc "contextless" (cache: ^Response_Cache, origin: ^Origin_Key, target: string, now_unix: i64, body_out: []u8) -> (status_code: u16, body_len: int, hit: bool) {
	part := find_or_create_cache_partition(cache, origin.principal_id, false)
	if part == nil {
		return 0, 0, false
	}
	tbytes := transmute([]u8)target
	for i := 0; i < CACHE_ENTRIES_PER_PRINCIPAL; i += 1 {
		e := &part.entries[i]
		if !e.used || e.principal_id != origin.principal_id {
			continue
		}
		if e.scheme == origin.scheme && e.port == origin.port &&
		   slice_equal(e.host[:e.host_len], origin.host[:origin.host_len]) &&
		   slice_equal(e.target[:e.target_len], tbytes) {
			if e.must_revalidate || now_unix < e.stored_at_unix || now_unix - e.stored_at_unix >= e.max_age_seconds {
				return 0, 0, false
			}
			if int(e.body_len) > len(body_out) {
				return 0, 0, false
			}
			copy(body_out[:e.body_len], e.body[:e.body_len])
			cache.access_seq += 1
			e.last_used_seq = cache.access_seq
			return e.status_code, int(e.body_len), true
		}
	}
	return 0, 0, false
}
