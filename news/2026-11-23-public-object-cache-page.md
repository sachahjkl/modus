title: The page of a public object cache
date: 2026-11-23
release: next
picture: docs/screenshots/public_object_cache.png
kind: Shown
guide: docs/TOOLS.md

An object cache of modus now has a page. `modustool cache-serve --status-listen` serves it beside the cache protocol, in the look of the site, with `status.json` for a monitor.

The page says what the host keeps: objects by their BLAKE3 hash, and signed realisations of recipes. It says that a client trusts a hash or a signer key, never the host. It lists the signer keys that the host accepts, the endpoint and its protocol, the counts of the store, the free space of the disk and the last 10 realisations.

The server counts the store once at its start, then at each write, so a view of the page reads no file.
