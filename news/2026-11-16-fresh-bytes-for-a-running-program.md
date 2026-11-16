title: A running program gets fresh random bytes
date: 2026-11-16
release: next
picture: docs/screenshots/randomness.png
kind: Shown
guide: docs/RANDOMNESS.md

A program gets one random seed at its start, and draws from its own generator. Now the root service also reads the entropy device every 30 seconds, mixes the bytes into its generator, and writes 32 bytes of its stream in a page that only one program reads. The generator of the program mixes them into its key at its next refill, or before it makes a key. A key that a program makes an hour after its start then has bytes from the last 30 seconds. The mix is never done for each draw: the page changes once in 30 seconds, and the same bytes mixed again add nothing. The window of `randomness` shows the count of the mixes in a new row.
