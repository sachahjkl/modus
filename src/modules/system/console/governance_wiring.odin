// Live console pre-call / wide-grant confirmation policy and CLDR en/fr
// localized prompt labels integrated into the console service.
package console

import "modus:contract/console_prompt"
import "modus:contract/locale_cldr"

console_active_locale: locale_cldr.Locale_Id = .En_US

console_action_requires_prompt :: proc "contextless" (act: console_prompt.Act_Kind, wide_grant_active: bool) -> bool {
	return console_prompt.wide_grant_act_policy(act, wide_grant_active) != .Allow_Silent
}

console_localized_label :: proc "contextless" (key: locale_cldr.Message_Key) -> string {
	return locale_cldr.message_text(console_active_locale, key)
}

// locale_command switches or reports the live CLDR locale (en or fr) of the console.
locale_command :: proc "contextless" (arguments: []Value) -> Value {
	tag := arguments[0].text
	switch tag {
	case "", "status":
	case "en", "en-US", "english":
		console_active_locale = .En_US
	case "fr", "fr-FR", "french":
		console_active_locale = .Fr_FR
	case:
		return fail("locale: expected en, fr, or empty text")
	}
	data := locale_cldr.locale_data(console_active_locale)
	return {kind = .Text, text = data.tag}
}
