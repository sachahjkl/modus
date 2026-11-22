type: Added

**HTTP/1.1 client, HTTP/3 framing bridge, and per-principal web store.** Added the freestanding `modus:contract/http_client` package with strict HTTP/1.1 smuggling and chunked-decoding guards, RFC 9114 HTTP/3 `HEADERS`/`DATA` framing, and per-principal partitioned `Cookie_Jar` and `Response_Cache` enforcing `Secure`, `HttpOnly`, `SameSite`, `Domain`, `Path`, and `Cache-Control` without cross-principal reads or eviction.
