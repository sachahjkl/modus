// The keywords of the extension `u` that a locale holds (UTS #35 part 1,
// "Unicode BCP 47 U Extension"). Each keyword takes a closed set of values,
// which the files bcp47/*.xml of CLDR list, so each is an enum: 0 is
// absent, then one member for each value in the order of its text. A new
// value of CLDR is a new member at the end, so no value moves
// (src/md/features/interface_language.md, "1. The identity of a language").
// The deprecated values and the aliases of CLDR are not members: the
// canonical form never writes them.
//
// The word of a member is a switch, not a table of strings: a table of
// strings holds addresses that a loader writes, and the drawing module,
// which reads the settings page, must have no such data
// (docs/MODULE_CONTRACT.md, "A library as a module").
package language_tag

// The calendar of a locale: the keyword `ca` of the extension `u`.
Calendar :: enum u8 {
	Absent = 0, // The tag names no calendar: the calendar of the language.
	Buddhist = 1,
	Chinese = 2,
	Coptic = 3,
	Dangi = 4,
	Ethioaa = 5,
	Ethiopic = 6,
	Gregory = 7,
	Hebrew = 8,
	Indian = 9,
	Islamic = 10,
	Islamic_Civil = 11,
	Islamic_Rgsa = 12,
	Islamic_Tbla = 13,
	Islamic_Umalqura = 14,
	Iso8601 = 15,
	Japanese = 16,
	Persian = 17,
	Roc = 18,
}

// calendar_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
calendar_word :: proc "contextless" (member: Calendar) -> string {
	switch member {
	case .Absent:
		return ""
	case .Buddhist:
		return "buddhist"
	case .Chinese:
		return "chinese"
	case .Coptic:
		return "coptic"
	case .Dangi:
		return "dangi"
	case .Ethioaa:
		return "ethioaa"
	case .Ethiopic:
		return "ethiopic"
	case .Gregory:
		return "gregory"
	case .Hebrew:
		return "hebrew"
	case .Indian:
		return "indian"
	case .Islamic:
		return "islamic"
	case .Islamic_Civil:
		return "islamic-civil"
	case .Islamic_Rgsa:
		return "islamic-rgsa"
	case .Islamic_Tbla:
		return "islamic-tbla"
	case .Islamic_Umalqura:
		return "islamic-umalqura"
	case .Iso8601:
		return "iso8601"
	case .Japanese:
		return "japanese"
	case .Persian:
		return "persian"
	case .Roc:
		return "roc"
	}
	return ""
}

// The order of a sort: the keyword `co` of the extension `u`.
Collation :: enum u8 {
	Absent = 0, // The tag names no order: the order of the language.
	Big5han = 1,
	Compat = 2,
	Dict = 3,
	Ducet = 4,
	Emoji = 5,
	Eor = 6,
	Gb2312 = 7,
	Phonebk = 8,
	Phonetic = 9,
	Pinyin = 10,
	Search = 11,
	Searchjl = 12,
	Standard = 13,
	Stroke = 14,
	Trad = 15,
	Unihan = 16,
	Zhuyin = 17,
}

// collation_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
collation_word :: proc "contextless" (member: Collation) -> string {
	switch member {
	case .Absent:
		return ""
	case .Big5han:
		return "big5han"
	case .Compat:
		return "compat"
	case .Dict:
		return "dict"
	case .Ducet:
		return "ducet"
	case .Emoji:
		return "emoji"
	case .Eor:
		return "eor"
	case .Gb2312:
		return "gb2312"
	case .Phonebk:
		return "phonebk"
	case .Phonetic:
		return "phonetic"
	case .Pinyin:
		return "pinyin"
	case .Search:
		return "search"
	case .Searchjl:
		return "searchjl"
	case .Standard:
		return "standard"
	case .Stroke:
		return "stroke"
	case .Trad:
		return "trad"
	case .Unihan:
		return "unihan"
	case .Zhuyin:
		return "zhuyin"
	}
	return ""
}

// The first day of the week: the keyword `fw` of the extension `u`.
First_Day :: enum u8 {
	Absent = 0, // The tag names no first day: the day of the region.
	Sun = 1,
	Mon = 2,
	Tue = 3,
	Wed = 4,
	Thu = 5,
	Fri = 6,
	Sat = 7,
}

// first_day_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
first_day_word :: proc "contextless" (member: First_Day) -> string {
	switch member {
	case .Absent:
		return ""
	case .Sun:
		return "sun"
	case .Mon:
		return "mon"
	case .Tue:
		return "tue"
	case .Wed:
		return "wed"
	case .Thu:
		return "thu"
	case .Fri:
		return "fri"
	case .Sat:
		return "sat"
	}
	return ""
}

// The cycle of the hours: the keyword `hc` of the extension `u`.
Hour_Cycle :: enum u8 {
	Absent = 0, // The tag names no cycle: the cycle of the region.
	H11 = 1,
	H12 = 2,
	H23 = 3,
	H24 = 4,
}

// hour_cycle_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
hour_cycle_word :: proc "contextless" (member: Hour_Cycle) -> string {
	switch member {
	case .Absent:
		return ""
	case .H11:
		return "h11"
	case .H12:
		return "h12"
	case .H23:
		return "h23"
	case .H24:
		return "h24"
	}
	return ""
}

// The system of measures: the keyword `ms` of the extension `u`.
Measurement_System :: enum u8 {
	Absent = 0, // The tag names no system: the system of the region.
	Metric = 1,
	Uksystem = 2,
	Ussystem = 3,
}

// measurement_system_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
measurement_system_word :: proc "contextless" (member: Measurement_System) -> string {
	switch member {
	case .Absent:
		return ""
	case .Metric:
		return "metric"
	case .Uksystem:
		return "uksystem"
	case .Ussystem:
		return "ussystem"
	}
	return ""
}

// The digits of the numbers: the keyword `nu` of the extension `u`.
Numbering_System :: enum u8 {
	Absent = 0, // The tag names no digits: the digits of the language.
	Adlm = 1,
	Ahom = 2,
	Arab = 3,
	Arabext = 4,
	Armn = 5,
	Armnlow = 6,
	Bali = 7,
	Beng = 8,
	Bhks = 9,
	Brah = 10,
	Cakm = 11,
	Cham = 12,
	Cyrl = 13,
	Deva = 14,
	Diak = 15,
	Ethi = 16,
	Fullwide = 17,
	Gara = 18,
	Geor = 19,
	Gong = 20,
	Gonm = 21,
	Grek = 22,
	Greklow = 23,
	Gujr = 24,
	Gukh = 25,
	Guru = 26,
	Hanidays = 27,
	Hanidec = 28,
	Hans = 29,
	Hansfin = 30,
	Hant = 31,
	Hantfin = 32,
	Hebr = 33,
	Hmng = 34,
	Hmnp = 35,
	Java = 36,
	Jpan = 37,
	Jpanfin = 38,
	Jpanyear = 39,
	Kali = 40,
	Kawi = 41,
	Khmr = 42,
	Knda = 43,
	Krai = 44,
	Lana = 45,
	Lanatham = 46,
	Laoo = 47,
	Latn = 48,
	Lepc = 49,
	Limb = 50,
	Mathbold = 51,
	Mathdbl = 52,
	Mathmono = 53,
	Mathsanb = 54,
	Mathsans = 55,
	Mlym = 56,
	Modi = 57,
	Mong = 58,
	Mroo = 59,
	Mtei = 60,
	Mymr = 61,
	Mymrepka = 62,
	Mymrpao = 63,
	Mymrshan = 64,
	Mymrtlng = 65,
	Nagm = 66,
	Newa = 67,
	Nkoo = 68,
	Olck = 69,
	Onao = 70,
	Orya = 71,
	Osma = 72,
	Outlined = 73,
	Rohg = 74,
	Roman = 75,
	Romanlow = 76,
	Saur = 77,
	Segment = 78,
	Shrd = 79,
	Sind = 80,
	Sinh = 81,
	Sora = 82,
	Sund = 83,
	Sunu = 84,
	Takr = 85,
	Talu = 86,
	Taml = 87,
	Tamldec = 88,
	Telu = 89,
	Thai = 90,
	Tibt = 91,
	Tirh = 92,
	Tnsa = 93,
	Tols = 94,
	Vaii = 95,
	Wara = 96,
	Wcho = 97,
}

// numbering_system_word gives the value of the keyword of a member, as UTS #35
// writes it, or "" for Absent.
numbering_system_word :: proc "contextless" (member: Numbering_System) -> string {
	switch member {
	case .Absent:
		return ""
	case .Adlm:
		return "adlm"
	case .Ahom:
		return "ahom"
	case .Arab:
		return "arab"
	case .Arabext:
		return "arabext"
	case .Armn:
		return "armn"
	case .Armnlow:
		return "armnlow"
	case .Bali:
		return "bali"
	case .Beng:
		return "beng"
	case .Bhks:
		return "bhks"
	case .Brah:
		return "brah"
	case .Cakm:
		return "cakm"
	case .Cham:
		return "cham"
	case .Cyrl:
		return "cyrl"
	case .Deva:
		return "deva"
	case .Diak:
		return "diak"
	case .Ethi:
		return "ethi"
	case .Fullwide:
		return "fullwide"
	case .Gara:
		return "gara"
	case .Geor:
		return "geor"
	case .Gong:
		return "gong"
	case .Gonm:
		return "gonm"
	case .Grek:
		return "grek"
	case .Greklow:
		return "greklow"
	case .Gujr:
		return "gujr"
	case .Gukh:
		return "gukh"
	case .Guru:
		return "guru"
	case .Hanidays:
		return "hanidays"
	case .Hanidec:
		return "hanidec"
	case .Hans:
		return "hans"
	case .Hansfin:
		return "hansfin"
	case .Hant:
		return "hant"
	case .Hantfin:
		return "hantfin"
	case .Hebr:
		return "hebr"
	case .Hmng:
		return "hmng"
	case .Hmnp:
		return "hmnp"
	case .Java:
		return "java"
	case .Jpan:
		return "jpan"
	case .Jpanfin:
		return "jpanfin"
	case .Jpanyear:
		return "jpanyear"
	case .Kali:
		return "kali"
	case .Kawi:
		return "kawi"
	case .Khmr:
		return "khmr"
	case .Knda:
		return "knda"
	case .Krai:
		return "krai"
	case .Lana:
		return "lana"
	case .Lanatham:
		return "lanatham"
	case .Laoo:
		return "laoo"
	case .Latn:
		return "latn"
	case .Lepc:
		return "lepc"
	case .Limb:
		return "limb"
	case .Mathbold:
		return "mathbold"
	case .Mathdbl:
		return "mathdbl"
	case .Mathmono:
		return "mathmono"
	case .Mathsanb:
		return "mathsanb"
	case .Mathsans:
		return "mathsans"
	case .Mlym:
		return "mlym"
	case .Modi:
		return "modi"
	case .Mong:
		return "mong"
	case .Mroo:
		return "mroo"
	case .Mtei:
		return "mtei"
	case .Mymr:
		return "mymr"
	case .Mymrepka:
		return "mymrepka"
	case .Mymrpao:
		return "mymrpao"
	case .Mymrshan:
		return "mymrshan"
	case .Mymrtlng:
		return "mymrtlng"
	case .Nagm:
		return "nagm"
	case .Newa:
		return "newa"
	case .Nkoo:
		return "nkoo"
	case .Olck:
		return "olck"
	case .Onao:
		return "onao"
	case .Orya:
		return "orya"
	case .Osma:
		return "osma"
	case .Outlined:
		return "outlined"
	case .Rohg:
		return "rohg"
	case .Roman:
		return "roman"
	case .Romanlow:
		return "romanlow"
	case .Saur:
		return "saur"
	case .Segment:
		return "segment"
	case .Shrd:
		return "shrd"
	case .Sind:
		return "sind"
	case .Sinh:
		return "sinh"
	case .Sora:
		return "sora"
	case .Sund:
		return "sund"
	case .Sunu:
		return "sunu"
	case .Takr:
		return "takr"
	case .Talu:
		return "talu"
	case .Taml:
		return "taml"
	case .Tamldec:
		return "tamldec"
	case .Telu:
		return "telu"
	case .Thai:
		return "thai"
	case .Tibt:
		return "tibt"
	case .Tirh:
		return "tirh"
	case .Tnsa:
		return "tnsa"
	case .Tols:
		return "tols"
	case .Vaii:
		return "vaii"
	case .Wara:
		return "wara"
	case .Wcho:
		return "wcho"
	}
	return ""
}
