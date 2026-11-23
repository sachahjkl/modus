// A holder of the role Settings that is not the module of the boot image
// (src/md/features/declarations.md, "The plan of principal 0 at the
// start"). The machine test of the plan of principal 0 names it in a plan
// as the holder of Settings; at the next start of the machine the row
// "settings" of the start list reaches it in place of `settings`.
//
// It declares the exports of the contract of the role Settings, so the
// root service accepts it as a holder, and gives the defaults of the
// settings. It serves none of them: the test needs only the proof that the
// start policy started it, so it writes its line and stops with Done, as
// the boot pass of `settings` does.
//
// **Start**: by the start policy, as the holder of Settings that a plan of
// principal 0 gives. **What a reader sees**: no window; one line
// "settings_stand_in: the start policy started the holder of the role
// Settings for the pass 1" (Boot).
package settings_stand_in

import "modus:contract/errors"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:system"

// set_time_zone refuses each zone: this holder keeps no setting.
//
// The result is a negative number with the error record Unsupported.
@(export, link_name = "set_time_zone")
set_time_zone :: proc "c" (zone: ^string, error: ^errors.Error_Record) -> i64 {
	return errors.fail(error, -1, .Unsupported, .None, 1)
}

// font gives the font of the defaults.
@(export, link_name = "font")
font_get :: proc "c" () -> settings.Font {
	return settings.choice_default().font
}

// appearance gives the appearance of the defaults.
@(export, link_name = "appearance")
appearance_get :: proc "c" () -> settings.Appearance {
	return settings.choice_default().appearance
}

// scale gives the scale of the defaults.
@(export, link_name = "scale")
scale_get :: proc "c" () -> scale_factor.Scale {
	return settings.choice_default().scale
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	pass, known := settings.pass_of_word(ctx.values[settings.VALUE_PASS])
	if !known {
		system.log_fact(.Error, Wrong_Pass{word = ctx.values[settings.VALUE_PASS]})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Started_As_Holder{pass_code = u64(pass)})
	system.stop(.Done)
}
