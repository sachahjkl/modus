type: Security

**A module table of records of no byte is refused.** A module file of 80 bytes could state 67 million segments of no byte: the check of the loader accepted it, then each loop over the table ran for minutes, and the start of the program never ended. The loader now refuses a table that has records and states a record size of 0, so the bytes of the file bound the count of its records. The fuzzing of the module file found it.
