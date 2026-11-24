type: Changed

**The test image carries its own plan file.** Test boot images ship the signed `test_plan_values` resource carrying the budget rows for `limits` and `log_flood`, release boot images exclude it, and the root service removes its hardcoded fallback exception tables.
