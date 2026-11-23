#+build !freestanding
package http_client

import "base:runtime"

// The memory of the host tests: a jar and a cache whose memory grows from
// the heap, in place, as an arena grows from a budget.

@(private = "file")
STORE_TEST_RESERVE_BYTES :: 64 << 20

@(private = "file")
store_test_grown :: proc(old: []$T, wanted: int) -> (grown: []T, ok: bool) {
	reserve := STORE_TEST_RESERVE_BYTES / size_of(T)
	if wanted > reserve {
		return old, false
	}
	base := raw_data(old)
	if base == nil {
		base = raw_data(make([]T, reserve))
		if base == nil {
			return old, false
		}
	}
	return ([^]T)(base)[:min(max(wanted, 16) * 2, reserve)], true
}

store_test_jar_grow :: proc "contextless" (jar: ^Cookie_Jar, part: Jar_Part, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	switch part {
	case .Entries:
		jar.entries, ok = store_test_grown(jar.entries, wanted)
	case .Principals:
		jar.shares, ok = store_test_grown(jar.shares, wanted)
	}
	return ok
}

store_test_cache_grow :: proc "contextless" (cache: ^Response_Cache, part: Cache_Part, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	switch part {
	case .Entries:
		cache.entries, ok = store_test_grown(cache.entries, wanted)
	case .Bodies:
		cache.bodies, ok = store_test_grown(cache.bodies, wanted)
	case .Principals:
		cache.shares, ok = store_test_grown(cache.shares, wanted)
	}
	return ok
}

store_test_jar_make :: proc() -> ^Cookie_Jar {
	jar := new(Cookie_Jar)
	jar.grow = store_test_jar_grow
	return jar
}

store_test_cache_make :: proc() -> ^Response_Cache {
	cache := new(Response_Cache)
	cache.grow = store_test_cache_grow
	return cache
}
