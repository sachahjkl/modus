type: Fixed

**The list of the failed parts names the parts that ran.** `modustool screenshots` evaluates the check of the flake once and builds that derivation, so `failed_parts` reads the derivations that the build built: a work tree that changed during the check made it call every part "did not run", the parts that passed too, with no log. A failed host check with no failed step now gives its last failed line, as "odin failed (code 1)", and a list of derivations that nothing built says so.
