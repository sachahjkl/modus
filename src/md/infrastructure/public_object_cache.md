# The public object cache

A host on the internet runs `modustool cache-serve` over a folder of objects and realisations, so that a machine of `modus` takes the output of a build that another machine made. Each release fills it with the files of its boot image and one signed realisation ([cache_publication.md](cache_publication.md)). The same program answers a page and a status record over HTTP, on its own address, for a reader who finds the host and does not know `modus`. The terms Object cache, Realisation and Substitution policy are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); the protocol is [../features/recipes.md](../features/recipes.md), "The object cache and its protocol".

## Purpose

An address that a person finds in a plan, in a log or in a search must say what it is. A reader of the page learns, in one screen: what `modus` is, what this host keeps, why nothing that the host says is trusted, which keys it accepts, how to name it in a plan, and what it holds now. The same numbers, in `status.json`, let a monitor of the host watch it with no page to parse.

## Names

- The name of the system is `modus`, in lower case, everywhere on the page, as on the site.
- The host is **an** object cache: any mirror, peer or disk is an object cache, so the page never says "the cache". Its title is "public object cache", under the mark and the name of the site; the `title` element has the form of a page of the site, "public object cache - modus". Refused: "Modus Object Cache", a title in capitals, a product name of its own.

## The chosen form

### One program

`modustool cache-serve --status-listen <host:port>` starts a second listener on its own thread. It answers three paths, and only `GET`:

| Path | Answer |
|---|---|
| `/` | The page, in HTML, written at each request from the numbers in memory |
| `/status.json` | The same facts as a record, for a monitor |
| `/style.css` | The style sheet of the site, made once at the start |

`--endpoint <host:port>` is the public address that the page shows (the host behind a proxy does not know its own name); with none, the page shows the listen address. The deployment passes its public name, `--endpoint cache.modus.systems:5010`: no default claims a host that runs. `--site <address>` is the address of the site; by default, the address that the tool gives the site (`SITE_ADDRESS` of `tools/modustool/site`), so a move of the site changes one constant. The page links to the site and takes the font of the name and the heron from it.

The two values reach a page and a header, so the command refuses them at its border, and the page escapes each use all the same:

- An endpoint is `host:port`. The host is a DNS name (labels of `a` to `z`, `0` to `9` and `-`, none that starts or ends with `-`, joined by single dots), an IPv4 address, or an IPv6 address in brackets. The port is 1 to 65535 in digits, with no leading zero. `host:`, `:5010`, `:::`, `-:1`, `...:1` and `a:05010` are refused.
- A site address starts with `https://` or `http://` and a host, and has no byte below or at the space, no byte past ASCII, and none of `"`, `'`, `<`, `>`, `;`, `?`, `#`, `\`, `` ` ``, `,` and `&`.

Refused: a second program that serves the page (a shell script that scans the store each minute into a file, and `python -m http.server` beside it). A second program in a second language reads the store with its own rules, and its page says what the scan saw a minute ago.

### The counts kept by the server

The server counts the objects, the realisations and their bytes once, when it opens the store: one listing of each folder, entry by entry through the directory iterator, with the size of each entry from the listing, no read of a file. A listing that the system cuts short refuses the open: counts that are too low are worse than no server. The memory of the listing is one entry, whatever the size of the folder; the time is one entry and its size for each file, once at the start. Only the names that are 64 lowercase hexadecimal digits count; the 10 newest realisations by their time are read and decoded for the list of the page. After that, each write of the server changes the counts:

- a write of a name that the store did not hold adds one entry and its bytes;
- a write of a name that the store held (the same object again, or another realisation of one recipe) adds nothing, and moves the time of the last write;
- a refused write changes nothing.

The size of the largest object is kept the same way: the listing at the open gives the largest size of the folder, and each write of a larger object raises it. An upload in progress is a file of `tmp`, not of `objects`, so it counts only after its rename.

The counts sit behind one lock, which the thread of the protocol takes at a write and the thread of the page takes to copy them. A request of the page does no work in proportion to the store.

- **The free space of the disk** comes from one `statfs` of the folder, kept at most 10 seconds: a flood of requests makes at most one call each 10 seconds. A host with no `statfs` shows no free space.
- **Refused: a scan of the store at each request, or each minute.** Its cost grows with the store; a store of a million objects then costs a million entries for each view of a page. A count kept at each write costs one addition.
- **The start of the server and its uptime** come from two clocks: the date of the start from the clock of the date, for the page; the uptime of `status.json` from the monotonic clock, so a step back of the date never gives a negative uptime.
- **The server is the one writer of its folder.** A file that another program puts in the folder is counted at the next start. Two servers on one folder are not a form of the system.

### The reader of a request

The page is a public address behind a proxy, so its reader is the border of a hostile input:

- One request on one connection. The answer says `Connection: close`, and the server closes after it: bytes after the first head get no answer.
- **One deadline for each connection**, 5 seconds by default (a parameter, so that a test sets it short), taken at the accept. It bounds the read of the head, the write of the answer and the read that drops the bytes after the answer, together: each read and each send waits at most the time that remains. A client that never reads, or reads a few bytes at a time, holds the thread for the deadline at most. Refused: a timeout of each send, which a client that reads one byte before each timeout stretches to minutes. Each send is one call of the system, because `net.send_tcp` calls again after a partial send with the whole timeout. An answer that the deadline cuts ends with a reset (`SO_LINGER` of 0), so the system drops the megabytes that it still holds for the slow client. An error answer is a head of less than 200 bytes with no body: it goes in one send of at most a millisecond, also after the deadline, so a `408` reaches the client.
- The head is at most 4096 bytes and ends with an empty line within the deadline. A longer head is `431`; a head with no end in time is `408`.
- The request line is `GET <path> HTTP/1.1` or `HTTP/1.0`. Another method is `405` with `Allow: GET`. A path outside the three, a query, a path with `..` or `%2e` is `404`: the path is compared whole with the three, never decoded and never joined to a folder, so no path reaches a file.
- A NUL byte, a control byte other than the end of a line and a tab, a byte past ASCII, a line with no colon in the headers, a `Content-Length` or a `Transfer-Encoding` is `400`. A `GET` has no body, and a body that the server does not read is a way to hide a second request from the proxy.
- No answer repeats a byte of the request. An error answer has no body.
- After its answer the server ends its side, then reads and drops what the client still sends, at most 16 KiB, until the client closes or the deadline passes: a close with bytes unread makes the system send a reset, which can remove the answer before the client reads it.
- One connection at a time: the page is a view, not the service. A slow client holds the thread of the page for the deadline at most, and never the thread of the protocol.
- **This protection assumes a proxy in front that reads the whole head before it opens a connection to the server**, as the TLS proxy of the deployment does. Exposed with no such proxy, a client that opens one connection after another holds the page for one deadline each: the page then waits, and the protocol does not.
- A refused accept that passes (a connection aborted before the accept, an interrupt, a lack of resources) does not end the thread: it ends only when the server stops or its listener is closed. The stop ends the side of the listener, joins the thread, and only then closes the listener, so the thread never waits on a descriptor that the system gave to another file.

Refused: a library of HTTP for three paths; keep-alive, which makes the reader a loop over hostile heads.

### The look

The page uses the style sheet of the site, from the same procedure of the tool (`site_style_sheet` of `tools/modustool/site`): its colors come from the color tokens of the system, its light form follows `prefers-color-scheme`, its bar has the heron and the name of the mark. The tool makes it once at the start and keeps it. The font of the name and the pictures of the heron are files of the site, named by their address on the site. A font of another host loads only when that host allows it: GitHub Pages sends `Access-Control-Allow-Origin: *` with each answer, and the proxy of Cloudflare passes it ([`docs/SITE.md`](../../../docs/SITE.md), "How the site is published"). A host of the site that does not send it gives a page whose name falls back to the monospace font in the same box.

- **Refused: a style sheet written for the page.** It drifts from the site at the first change of a color.
- **Refused: a link to the `style.css` of the site.** The page of one build then takes the classes of another build.
- **No script.** Each number is in the HTML of the request. A reader reloads the page for new numbers.

### What the page says

Each fact once, in this order:

1. The heading "public object cache", then one sentence on what `modus` is, with a link to the site, and what this host keeps: objects (blobs and trees) by their BLAKE3 hash, and realisations, signed records that say which output a recipe gave.
2. **The trust.** A client trusts a hash or a signer key, never this host: an object is checked against its hash, and a realisation is used only when a key that the substitution policy of the client trusts signed it.
3. **The signer keys**: the hexadecimal form of each key of `--authorized-key` and `--signer-key`, whole. These are the keys whose uploads the host accepts. The page says that this list is no reason to trust a key: a client takes the key of a publisher from the publisher.
4. **The endpoint and the protocol**: the endpoint, what the server speaks today (binary frames `MOCQ` and `MOCR` over TCP; an object of any size travels in frames of 1 MiB, each checked against the hash of the whole object), a link to the entry "Object cache" of the glossary on the site, the lines of a substitution policy that name this host, and the command that runs an object cache of one's own.
5. **The store now**: objects, realisations, bytes, the size of the largest object, free space, the last write, the start of the server.
6. **The last 10 realisations**: the recipe hash, the output hash and its kind, the signer, the time. Each hash shows its first 12 digits; the whole value is in the `title` of its element and in `status.json`. The column of the signer is shown only when the rows name more than one signer: with one, each row repeats one key, which the list of the keys already gives. The heads of the hash columns carry the icon of the kind Version, as the head of the column of the time carries the icon of Time: a column whose cells are all of one kind shows its icon once, in its head ([`docs/SITE.md`](../../../docs/SITE.md), "The kinds of values").

The lines of the policy follow the fields of `Substitution` (`sources`, `signers`, `mode`; [../features/declarations.md](../features/declarations.md), "A record literal is typed by its use") and the table `keys` of the publisher keys that a principal trusts. The literal of a source is not fixed yet ("Open questions").

## Subtle points

- **The page lists keys and is not signed.** A reader who takes a key from the page trusts the host. So the page says where a key comes from, and the client trusts the key of the publisher, not the list.
- **A realisation written again** for one recipe replaces the file, does not change the count of the realisations, and takes the top of the list of the last realisations.
- **The times of the list after a start** are the times of the files; after the start, the time of each write.
- **The thread of the page reads no file.** The style sheet, the keys and the counts are in memory; the one call to the system is the `statfs` of the free space.

## Open questions

- **The literal of a source in Lex**: a text `"host:port"`, or a record with the key of the endpoint, which QUIC needs.
- **The paths of the object cache of the browser machine** (`/blobs/<hash>`, `/realisations/<recipe hash>`; [../features/browser_machine.md](../features/browser_machine.md), "The object cache of the page"): the same listener can serve them read-only, with CORS for the origin of the page.

## State

Built: the listener of the page in `tools/modustool/cache_server` (`cache_status.odin`, `cache_status_http.odin`, `cache_status_page.odin`), the counts kept at each write, and host tests of each refusal of the reader, of the one deadline against a client that never reads and one that reads slowly, of the escape of each value of the page, and of the counts under a concurrent writer.
