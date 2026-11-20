title: The console reads the requests of the web server as they come
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

`server`, the web server of the system, now gives the record of each request that it answers to a reader, in place of a line of its log. The console reads them by name: after `connect("server")`, `server.requests |> where(status = 404) |> first(5)` gives the next five requests that found no page, each with its status, its size, its time, its method, its target and its host.

The log kept at most 100 of these lines in each second, and dropped the rest. A reader of `server.requests` loses none in silence: its first row says how many requests came before it joined, and a reader too slow for the server gets a row that says how many records it missed.

A reader chooses how it slows the server. A reader for an audit holds the server until it has read; any other reader never holds it. With one reader of each kind and one fast reader on one server, a test checks the counts exactly: the reader that holds lost nothing and held the server twice, the other missed one whole ring of 32 records and was told so, and the fast reader got all 80 records in order.
