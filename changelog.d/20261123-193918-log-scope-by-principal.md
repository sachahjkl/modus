type: Security

**The log by principal**: a console or `remote` that acts for a principal reads, with `log.records`, `log.value_runs` and `log.fact_records`, the records of the processes of that principal only, and principal 0 also the records of the kernel and of the root service; before, it read the whole log, with the records of each other principal. `log.follow` still gives the whole log.
