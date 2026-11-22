type: Changed

**A word in place of the enum fields that are left.** The remaining shared-record enum fields (`Event_Rule.kind`, `date.Page.source`, `remote.Request.kind`, `module.Function.parameter_directions`, `module.Described.direction`, `module.Load_Error` stage/error/difference, and `boot_info` memory kind, pixel format, verifier, signing key kind, and measure state) are now raw unsigned words read through strict `enum_word.member_of_word` borders.
