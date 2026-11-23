type: Fixed

**The trusted display shows the difference of a plan to the holder of Plans.** `plans.apply` and `plans.rollback` were refused with `Display_Refused` on each machine, because the display served only a caller that acts for the principal and `plans` acts for nobody. The root service now names the holder of the role Plans in the grant of its connection to the display, and writes that grant again when the roles change, so a module that lost the role is refused.
