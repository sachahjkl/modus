type: Changed

**A failed machine test part prints its whole log.** The tool prints each line of the log of the machine that failed, with its facts written as sentences, in place of its last 25 raw lines; `nix log` of the part keeps it whole after the check.
