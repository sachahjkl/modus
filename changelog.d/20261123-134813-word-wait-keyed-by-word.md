type: Changed

**A wake reads the waiters of its own word.** The kernel keeps the waited words in a bucket for each page frame and a list for each word, so a wake reads at most the 1024 words of one frame and the waiters of its word, whatever another process waits on. A `Word_Wait` that names a word twice is refused with `Bad_Operation` and the place of the word, and the library then waits once on each word and writes one line. A wait of more than 1024 words registers them in chunks, and frees the lock of its process between two.
