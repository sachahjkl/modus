// Pure freestanding CLDR locale data for English (en) and French (fr):
// date/month/weekday names, number formatting separators, CLDR cardinal plural
// categories, bilingual interface message packs, and CLDR QWERTY/AZERTY
// scancode-to-rune keyboard layouts (src/md/features/interface_language.md).
package locale_cldr

import "modus:contract/enum_word"

Locale_Id :: enum u8 {
	En_US = 1,
	Fr_FR = 2,
}

locale_id_of_word :: proc "contextless" (word: u64) -> (l: Locale_Id, ok: bool) {
	return enum_word.member_of_word(Locale_Id, word)
}

Plural_Category :: enum u8 {
	One   = 1,
	Many  = 2,
	Other = 3,
}

Message_Key :: enum u16 {
	Window_Close       = 1,
	Powerbox_Allow     = 2,
	Powerbox_Refuse    = 3,
	Settings_Title     = 4,
	Unlock_Passphrase  = 5,
	Plan_Apply         = 6,
	Plan_Rollback      = 7,
	Search_Placeholder = 8,
}

Keyboard_Layout :: enum u8 {
	En_US_Qwerty = 1,
	Fr_FR_Azerty = 2,
}

keyboard_layout_of_word :: proc "contextless" (word: u64) -> (k: Keyboard_Layout, ok: bool) {
	return enum_word.member_of_word(Keyboard_Layout, word)
}

Number_Format :: struct {
	decimal_sep:  u8,
	grouping_sep: u8,
}

Locale_Data :: struct {
	id:           Locale_Id,
	tag:          string,
	months:       [12]string,
	weekdays:     [7]string, // 0 = Monday .. 6 = Sunday
	numbers:      Number_Format,
	date_order:   u8, // 1 = MDY, 2 = DMY
}

LOCALE_EN_US :: Locale_Data{
	id         = .En_US,
	tag        = "en-US",
	months     = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"},
	weekdays   = {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"},
	numbers    = {decimal_sep = '.', grouping_sep = ','},
	date_order = 1,
}

LOCALE_FR_FR :: Locale_Data{
	id         = .Fr_FR,
	tag        = "fr-FR",
	months     = {"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"},
	weekdays   = {"lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"},
	numbers    = {decimal_sep = ',', grouping_sep = ' '},
	date_order = 2,
}

locale_data :: proc "contextless" (id: Locale_Id) -> Locale_Data {
	switch id {
	case .En_US: return LOCALE_EN_US
	case .Fr_FR: return LOCALE_FR_FR
	}
	return LOCALE_EN_US
}

// cldr_cardinal_plural implements the official CLDR cardinal plural rules:
// English: 1 -> One, else Other.
// French:  0 or 1 -> One, exact millions >= 1_000_000 -> Many, else Other.
cldr_cardinal_plural :: proc "contextless" (id: Locale_Id, n: u64) -> Plural_Category {
	switch id {
	case .En_US:
		return n == 1 ? .One : .Other
	case .Fr_FR:
		if n == 0 || n == 1 {
			return .One
		}
		if n >= 1_000_000 && n % 1_000_000 == 0 {
			return .Many
		}
		return .Other
	}
	return .Other
}

message_text :: proc "contextless" (id: Locale_Id, key: Message_Key) -> string {
	switch id {
	case .En_US:
		switch key {
		case .Window_Close:       return "Close"
		case .Powerbox_Allow:     return "Allow"
		case .Powerbox_Refuse:    return "Refuse"
		case .Settings_Title:     return "Settings"
		case .Unlock_Passphrase:  return "Passphrase"
		case .Plan_Apply:         return "Apply plan"
		case .Plan_Rollback:      return "Roll back"
		case .Search_Placeholder: return "Type a command or window"
		}
	case .Fr_FR:
		switch key {
		case .Window_Close:       return "Fermer"
		case .Powerbox_Allow:     return "Autoriser"
		case .Powerbox_Refuse:    return "Refuser"
		case .Settings_Title:     return "Réglages"
		case .Unlock_Passphrase:  return "Phrase de passe"
		case .Plan_Apply:         return "Appliquer le plan"
		case .Plan_Rollback:      return "Revenir en arrière"
		case .Search_Placeholder: return "Tapez une commande ou une fenêtre"
		}
	}
	return ""
}

// cldr_key_rune maps USB HID Usage ID (0x04..0x1D = A..Z, 0x1E..0x27 = 1..0)
// to its Unicode rune under the selected CLDR keyboard layout.
cldr_key_rune :: proc "contextless" (layout: Keyboard_Layout, hid_usage: u8, shift: bool) -> rune {
	switch layout {
	case .En_US_Qwerty:
		if hid_usage >= 0x04 && hid_usage <= 0x1D {
			base := rune('a' + (hid_usage - 0x04))
			return shift ? base - 32 : base
		}
	case .Fr_FR_Azerty:
		// Key swaps between QWERTY and French AZERTY: Q<->A, W<->Z, M->semicolon, etc.
		switch hid_usage {
		case 0x14: return shift ? 'A' : 'a' // physical Q key -> A
		case 0x1A: return shift ? 'Z' : 'z' // physical W key -> Z
		case 0x04: return shift ? 'Q' : 'q' // physical A key -> Q
		case 0x1D: return shift ? 'W' : 'w' // physical Z key -> W
		case 0x10: return shift ? '?' : ',' // physical M key -> , / ?
		case 0x33: return shift ? 'M' : 'm' // physical ; key -> M
		case 0x1F: return shift ? '2' : 'é' // physical 2 key -> é / 2
		case 0x24: return shift ? '7' : 'è' // physical 7 key -> è / 7
		case 0x26: return shift ? '9' : 'ç' // physical 9 key -> ç / 9
		case 0x27: return shift ? '0' : 'à' // physical 0 key -> à / 0
		}
		if hid_usage >= 0x04 && hid_usage <= 0x1D {
			base := rune('a' + (hid_usage - 0x04))
			return shift ? base - 32 : base
		}
	}
	return 0
}
