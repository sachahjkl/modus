# The public object cache

A host on the internet runs `modustool cache-serve` over a folder of objects and realisations, so that a machine of `modus` takes the output of a build that another machine made. The same program answers a page and a status record over HTTP, on its own address, for a reader who finds the host and does not know `modus`. The terms Object cache, Realisation and Substitution policy are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); the protocol is [../features/recipes.md](../features/recipes.md), "The object cache and its protocol".

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

`--endpoint <host:port>` is the public address that the page shows (the host behind a proxy does not know its own name); with none, the page shows the listen address. `--site <address>` is the address of the site, `https://modus.systems` by default: the page links to it and takes the font of the name and the heron from it.

Refused: a second program that serves the page (a shell script that scans the store each minute into a file, and `python -m http.server` beside it). A second program in a second language reads the store with its own rules, and its page says what the scan saw a minute ago.

### The counts kept by the server

The server counts the objects, the realisations and their bytes once, when it opens the store: one listing of each folder, with the size of each entry from the listing, no read of a file. Only the names that are 64 lowercase hexadecimal digits count; the 10 newest realisations by their time are read and decoded for the list of the page. After that, each write of the server changes the counts:

- a write of a name that the store did not hold adds one entry and its bytes;
- a write of a name that the store held (the same object again, or another realisation of one recipe) adds nothing, and moves the time of the last write;
- a refused write changes nothing.

The counts sit behind one lock, which the thread of the protocol takes at a write and the thread of the page takes to copy them. A request of the page does no work in proportion to the store.

- **The free space of the disk** comes from one `statfs` of the folder, kept at most 10 seconds: a flood of requests makes at most one call each 10 seconds. A host with no `statfs` shows no free space.
- **Refused: a scan of the store at each request, or each minute.** Its cost grows with the store; a store of a million objects then costs a million entries for each view of a page. A count kept at each write costs one addition.
- **The server is the one writer of its folder.** A file that another program puts in the folder is counted at the next start. Two servers on one folder are not a form of the system.

### The reader of a request

The page is a public address behind a proxy, so its reader is the border of a hostile input:

- One request on one connection. The answer says `Connection: close`, and the server closes after it: bytes after the first head get no answer.
- The head is at most 4096 bytes and ends with an empty line within a deadline, 5 seconds by default (a parameter, so that a test sets it short). A longer head is `431`; a head with no end in time is `408`.
- The request line is `GET <path> HTTP/1.1` or `HTTP/1.0`. Another method is `405` with `Allow: GET`. A path outside the three, a query, a path with `..` or `%2e` is `404`: the path is compared whole with the three, never decoded and never joined to a folder, so no path reaches a file.
- A NUL byte, a control byte other than the end of a line and a tab, a byte past ASCII, a line with no colon in the headers, a `Content-Length` or a `Transfer-Encoding` is `400`. A `GET` has no body, and a body that the server does not read is a way to hide a second request from the proxy.
- No answer repeats a byte of the request. An error answer has no body.
- One connection at a time: the page is a view, not the service. A slow client holds the thread of the page for the deadline at most, and never the thread of the protocol.

Refused: a library of HTTP for three paths; keep-alive, which makes the reader a loop over hostile heads.

### The look

The page uses the style sheet of the site, from the same procedure of the tool (`site_style_sheet` of `tools/modustool/site`): its colors come from the color tokens of the system, its light form follows `prefers-color-scheme`, its bar has the heron and the name of the mark. The tool makes it once at the start and keeps it. The font of the name and the pictures of the heron are files of the site, named by their address on the site.

- **Refused: a style sheet written for the page.** It drifts from the site at the first change of a color.
- **Refused: a link to the `style.css` of the site.** The page of one build then takes the classes of another build.
- **No script.** Each number is in the HTML of the request. A reader reloads the page for new numbers.

### What the page says

Each fact once, in this order:

1. The heading "public object cache", then one sentence on what `modus` is, with a link to the site, and what this host keeps: objects (blobs and trees) by their BLAKE3 hash, and realisations, signed records that say which output a recipe gave.
2. **The trust.** A client trusts a hash or a signer key, never this host: an object is checked against its hash, and a realisation is used only when a key that the substitution policy of the client trusts signed it.
3. **The signer keys**: the hexadecimal form of each key of `--authorized-key` and `--signer-key`, whole. These are the keys whose uploads the host accepts. The page says that this list is no reason to trust a key: a client takes the key of a publisher from the publisher.
4. **The endpoint and the protocol**: the endpoint, what the server speaks today (binary frames `MOCQ` and `MOCR` over TCP), a link to the entry "Object cache" of the glossary on the site, the lines of a substitution policy that name this host, and the command that runs an object cache of one's own.
5. **The store now**: objects, realisations, bytes, free space, the last write, the start of the server.
6. **The last 10 realisations**: the recipe hash, the output hash and its kind, the signer, the time. Each hash shows its first 12 digits; the whole value is in the `title` of its element and in `status.json`.

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

Built: the listener of the page in `tools/modustool/cache_server` (`cache_status.odin`, `cache_status_http.odin`, `cache_status_page.odin`), the counts kept at each write, and host tests of each refusal of the reader and of the counts.
