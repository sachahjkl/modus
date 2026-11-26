#+build !freestanding
#+build !modus
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

store_test_jar_grow :: proc "contextless" (jar: ^Cookie_Jar, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	jar.entries, ok = store_test_grown(jar.entries, wanted)
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
	}
	return ok
}

// store_test_jar_make gives a jar that serves a count of principals, each
// with a share of cookies, in memory that grows from the heap.
store_test_jar_make :: proc(principals := 2, share := 64) -> ^Cookie_Jar {
	jar := new(Cookie_Jar)
	jar.grow = store_test_jar_grow
	cookie_jar_init(jar, make([]Principal_Part, principals), 0, share)
	return jar
}

// store_test_cache_make gives a cache that serves a count of principals,
// each with a share of entries and of bytes of bodies.
store_test_cache_make :: proc(principals := 2, entry_share := 32, body_share := 128 << 10) -> ^Response_Cache {
	cache := new(Response_Cache)
	cache.grow = store_test_cache_grow
	response_cache_init(cache, make([]Principal_Part, principals), 0, 0, entry_share, body_share)
	return cache
}

store_test_jar_free :: proc(jar: ^Cookie_Jar) {
	delete(jar.parts)
	free(jar)
}

store_test_cache_free :: proc(cache: ^Response_Cache) {
	delete(cache.parts)
	free(cache)
}

