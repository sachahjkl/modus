type: Changed

**Cookies and a cache of the web client in memory that grows.** The cookie jar and the response cache of `modus:contract/http_client` hold the entries of any count of principals in memory of the caller that grows, with a quota for each principal that the caller sets, in place of 8 principals of 32 cookies and 8 cached answers of 4 KiB: a cookie has 4096 bytes of value, as RFC 6265 asks, and a cached answer has the size of its body. A principal still evicts only its own entries.
