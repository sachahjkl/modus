type: Changed

**Declaration files of 16 MiB**: a `.lex` file can have 16 MiB, where 64 KiB was refused. The evaluation sizes its node pool and its text arena from the files that it reads, so a short file costs what it did.
