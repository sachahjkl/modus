type: Added

**Record streams in the console**: a line names a record output of a process that the console started or connected by its typed name, `output_counter.counts`, and reads it as a value of the kind `Stream`: `where` checks a condition on each record, `first(s, n)` and `table(s)` make a Table of it, and a `Stream` at the end of a line draws each row as it comes, with its joined record and its gaps, until its end or Escape. `record_outputs(module)` lists the record outputs of a module, and `+` gives the rows of two Tables of one record.
