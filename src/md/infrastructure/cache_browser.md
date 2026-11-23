# The browser of an object cache

The page of an object cache ([public_object_cache.md](public_object_cache.md)) says what the host is and what it holds, in numbers. The browser shows each thing that the host holds: a tree and its entries, a blob and what it is, a realisation and the recipe that it answers, the release pointers that a publisher put, and the names that start with a prefix. The same program serves it, on the same listener, with the same reader of a request. The terms Object cache, Realisation, Recipe, Recipe object and Release pointer are in [`docs/glossary/code.md`](../../../docs/glossary/code.md); Tree is in [`docs/glossary/storage.md`](../../../docs/glossary/storage.md).

## Purpose

A hash in a log, a plan or a release note must open to what it names. A reader who follows a hash to this host sees what the object is, checked against its hash at that request, and the hashes that it names, each as a link. No page asks the reader to trust the host: each page says what the server checked, and a signed record says which key signed it.

## Constraints

- **One program, one language.** The browser is pages of `modustool cache-serve`, written in Odin from the same store, with the reader of a request, the style sheet and the bar of the page. A second program in a second language reads the store with its own rules: refused, as for the page ([public_object_cache.md](public_object_cache.md), "One program").
- **No script.** Each page is complete in its HTML. The search is a form with the method `GET`.
- **Bounded work for each request.** A page reads the files of the one thing that it shows, and at most a fixed count of other entries. No request lists a folder.
- **Bounded pages.** A page is at most 1 MiB (`BROWSE_PAGE_BYTES_MOST`). A page that would pass it is replaced by a page that says so; the raw path still gives the bytes.
- **Every byte that a page shows is checked first.** An object is read whole and its hash is computed before any byte of it reaches a page. A recipe and a release pointer are checked the same way. A file that does not have its hash is damaged: the page says so and shows none of its bytes.

## The paths

The reader of a request parses the target at one border, `status_request_parse`, into one form of a closed set (`Status_Path`). A hash in a path is exactly 64 lowercase hexadecimal digits; anything else is `404`. A query is refused, except on the two forms that take one, and there it has one exact name.

| Path | Answer |
|---|---|
| `/` | The page of the object cache |
| `/status.json`, `/style.css` | The status record and the style sheet |
| `/tree/<hash>`, `/tree/<hash>?page=<n>` | A tree: its entries, 100 on a page (`BROWSE_TREE_PAGE_ENTRIES`). `n` is 2 to the last page, with no leading zero: the first page has one address, with no query |
| `/blob/<hash>` | A blob: its size, its kind, a view of its head, and what a module file says |
| `/blob/<hash>/raw` | The bytes of a blob, for a download |
| `/realisation/<recipe hash>` | A realisation, its recipe when the host holds it, its output and its signer |
| `/releases` | The release pointers that the host holds, newest first |
| `/search`, `/search?h=<prefix>` | The names of the store that start with a prefix |

- A path with `..`, a `%`, a `/` at the end, an upper-case digit, a query that its form does not take, or a page `1`, `0`, `01` or past the last page, is `404`. The target is never decoded and never joined to a folder: the border decodes the hash to 32 bytes, and the path of the file is made again from those bytes.
- The border also checks the value of `h`: 1 to 64 digits of `0` to `9` and `a` to `f`. Another value gives the page of the search with one sentence that says what a prefix is. The page shows the prefix only when it passed that check, so no page repeats a byte that the border did not accept.
- An object or a realisation that the host does not hold is `404`, with a page that says so. A request that the reader refuses (a method, a head, a path form) keeps its answer with no body.

## The kind of an object

The store keeps an object by its hash, not by its kind. The browser finds the kind from the bytes: a blob when their BLAKE3 hash is the name, a tree when they are a canonical tree whose tree hash is the name. A tree hash is a derived key of its own domain, so one set of bytes is never both. Neither: the object is damaged.

- `/tree/<hash>` of a blob, and `/blob/<hash>` of a tree, give a page with one sentence and a link to the other path: each kind keeps one stable address.
- A file larger than the bound of an object (16 MiB) is damaged, and no byte of it is read: no request reads more than the bound.

## A tree

A row for each entry: its name, its kind, its size, and its hash as a link to its path. The size is one `stat` of the file of the entry, at most 100 for each page. An entry that the host does not hold says so, with no link. A name is shown escaped; the tree format already refuses a control byte, a `/` and a byte that is not UTF-8.

## A blob

- **The size**, then **the kind that the browser finds**, in this order: a module file (the magic of a module file, then `module.validate`), a module past the bounds of this page, a picture (the signature of PNG), a text (UTF-8 with no control byte other than a tab and the end of a line), else other bytes.
- **A module file that does not parse** is a kind of its own: the page names the refusal of `module.validate`, shows the head of the bytes, and shows no field.
- **A module past the bounds of this page.** The check of a module costs work in proportion to its tables, and the page runs within the deadline of one connection. So the page reads the counts of the table directory first, and a module with more than 256 segments, more than 2^20 rebase words or more than 2^16 records in another table is shown as a module past the bounds of this page: not validated, and no field of it shown.
- **The strings of a module file.** A string of a module is an offset and a count into its string table that the module chooses: a hostile module names its whole table in each export. Each name (an export, a parameter, a record, an enum, the entry) is cut to 128 bytes, each summary to 512 and the documentation text to 4096, on a whole character, with a mark at the cut, before the escape. A byte that is not UTF-8 and a control character are replaced by U+FFFD. The list of the exports also stops at the bound of the page.
- **What a module file says**, from the reader of the loader (`modus:contract/module`): its line of documentation, its category, each export with its signature in the form that the console prints (the name, the parameters with their names and types, the result), and the budget that it asks for. The name of a module is not in its file: the tree that names the file gives it.
- **A view of the head**: the first 4096 bytes of a text, cut on a whole character, in a `pre`; the first 256 bytes of other bytes in hexadecimal, 16 on a line, with their offset. A picture is shown from its raw path.
- **The raw path** answers the bytes with the type of their kind (`text/plain; charset=utf-8`, `image/png`, else `application/octet-stream`), `Content-Disposition: attachment` with the name `<hash>.<extension>`, and the policy `default-src 'none'; sandbox`: a blob that holds HTML runs nothing on the address of the host. A damaged blob has no raw answer: `404`.
- **A large blob and the deadline.** The raw answer is written within the one deadline of the connection ([public_object_cache.md](public_object_cache.md), "The reader of a request"). A link too slow to carry 16 MiB in that time gets a reset. `modustool cache-get` is the client for a large object; the raw path is for a reader.

## A realisation and its recipe

- The size of the file is checked first: a file of another size than a record (164 bytes) is damaged, and is not read. Then the record is decoded and checked against its name: its recipe hash is the name of its file.
- **The signature** is checked against the key that the record names, over the bytes that the signer signed. A record whose signature does not verify is damaged: the page shows its hash and that sentence, and none of its fields as a fact and no link to its output. A record that verifies: the page says whether the key is one of the keys of this host now. Then it says that this is the check of this host: a reader trusts a key, not this host, and checks the signature again with the key of the publisher.
- **The recipe.** A realisation names its recipe by hash only. A **recipe object** is the magic `MODRCP01`, then the canonical bytes of a recipe: the bytes over which the recipe hash is the derived key of the recipe domain (`plans_recipes.recipe_object_encode`, `recipe_object_decode`). A publisher puts it as a blob. When the server takes a blob that starts with the magic and decodes as a recipe object, it also keeps the bytes in `recipes/<recipe hash>`, so a realisation finds its recipe by the one hash that it holds. The page decodes the file again, computes its recipe hash, and shows the recipe only when that hash is the name: the builder, the output kind, the date, the block limit, each input with its name, its kind and its hash as a link, and the size of the arguments with their head in hexadecimal.
- **Refused: a third member of `Cache_Object_Kind` for a recipe.** The services of the machine, the mesh and the browser machine read that enum; a member for one page of the tool changes each of them. A recipe object is a blob, and its recipe hash is computed from it.
- **Refused: a decode of each blob as a recipe.** Only a blob that starts with the magic is tried.
- A realisation whose recipe the host does not hold says so, and shows the recipe hash, the output and the signer.

## The release pointers

A release pointer is the record that a publisher signs for a name: its key, the name, a number that only grows, the hash of a tree, and the signature ([../features/declarations.md](../features/declarations.md), "Declaration inputs, pins and release pointers"). The protocol carries it with two requests of `modus:contract/object_cache`: `Put_Release_Pointer`, which needs a key of the host and a signature that verifies, and `Get_Release_Pointer`, which takes a publisher key and a name and answers the pointer with the highest number.

- **The server keeps each pointer**, in `release_pointers/<hash of the record>`. The start reads each file of that folder, checks its signature, and keeps the list in memory: a release adds one record of 208 bytes. Refused: only the newest pointer of a name, because the browser lists what each publication put.
- **The number only grows.** A put whose number is not higher than the highest number of the same publisher and name is refused. The same record again is accepted and changes nothing, so a release job that runs again does not fail.
- **The publication of a release** puts, after the files of its boot image: a tree of each file of the image by its name, then the release tree with two entries, `boot.image` (the hash of the whole image, as an object) and `files` (that tree). The image is larger than the bound of one object, so the host does not hold it: the tree names it by hash, and the browser shows that entry as not held. Then the recipe object of the cache test recipe, and last the release pointer, signed with the cache signing key, for the name `release` and the number of the release number `a.b.c` as `a` shifted by 42 bits, `b` by 21 bits, then `c`: each part keeps its order up to 2^22 for `a` and 2^21 for `b` and `c`.
- **A run of the job of an older release** finds on the cache a pointer of the same key with a higher number: the publication is done and puts no pointer, as the check after it accepts a higher pointer.
- **The time of a pointer** on the page is the time of its write on the host. The record holds no time: a time that the publisher writes is a claim of the publisher.
- `/releases` lists the newest 50 pointers (`BROWSE_RELEASE_ROWS`) and the count of the others. Each row says whether its publisher key is a key of this host now; the host checked the signature when it kept the pointer.

## The search

- The server keeps the names of the objects and of the realisations in two sorted arrays in memory. The listing at the start makes them, and each write that adds a name changes them. A search is two binary searches, then at most 20 names of each (`BROWSE_SEARCH_ROWS`), with a sentence when more names match. Refused: a listing of a folder for each search, whose cost grows with the store.
- **The cost of the index** is 32 bytes for each name: a store of a million names holds 32 MiB more. A write that adds a name moves the names after it, at most those 32 MiB; a write of a name that the store holds moves nothing.
- A row of an object links to its path by its first bytes: the magic of a tree, else a blob. The page of the object then checks it whole.

## Subtle points

- **The thread of the page now reads files.** The page `/` still reads none. A page of the browser reads the files of the one thing that it shows, and at most 100 `stat` calls. One connection at a time still holds: a slow reader of a raw blob holds the thread for the deadline at most.
- **The policy of a page** also allows a picture of the host itself (`img-src 'self'`), for the view of a PNG blob, and the search form (`form-action 'self'`).
- **The write of a release pointer is under the lock of the status.** The check of its number against the kept pointers and the keep of the new one must be one step: two puts of one name must not both pass the check. So the file is written while the lock is held, and a view of the page waits for that one write of 208 bytes.
- **The index and the counts change together**, under the one lock of the status, so the counts of the page and the rows of a search agree.

## State

Built: the closed set of paths and its parser, the pages of a tree, a blob, a realisation, the release pointers and the search, the raw answer, the recipe object and its folder, the release pointer in the protocol and its folder, the publication of the files tree, the release tree, the recipe object and the pointer, and host tests that give each parser its refused forms and each page a damaged object, a tree of 512 entries, a module that does not parse, a text with control bytes and a name with HTML.
