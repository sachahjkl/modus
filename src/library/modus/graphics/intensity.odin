package graphics

// The intensity steps of a gauge (docs/DESIGN.md, "The intensity of a
// gauge"; src/md/features/monitor_window.md). A gauge is a bar whose length
// is a share. It takes the color of the concept that it measures while the
// share is low, and a color that asks for attention when it is high: three
// steps with stated thresholds, so that each color keeps one meaning. A
// continuous hue would give each value a color with no meaning.

// The steps, from the lowest share.
Intensity :: enum u8 {
	Normal    = 0, // Under INTENSITY_HIGH_PERCENT: the color of the concept that the gauge measures.
	High      = 1, // From INTENSITY_HIGH_PERCENT: the warning color.
	Very_High = 2, // From INTENSITY_VERY_HIGH_PERCENT: the color of a measure near its limit.
}

// The thresholds, in percent of the whole. A share at a threshold is in the
// higher step.
INTENSITY_HIGH_PERCENT :: 60
INTENSITY_VERY_HIGH_PERCENT :: 85
#assert(INTENSITY_HIGH_PERCENT < INTENSITY_VERY_HIGH_PERCENT)

// intensity_of gives the step of a share in percent. A share past 100 % is
// a measure too (a process with threads on several processors), and it is
// very high.
intensity_of :: proc "contextless" (percent: u64) -> Intensity {
	if percent >= INTENSITY_VERY_HIGH_PERCENT {
		return .Very_High
	}
	if percent >= INTENSITY_HIGH_PERCENT {
		return .High
	}
	return .Normal
}

// intensity_color gives the color of a step in a set of tokens: concept for
// the normal step, the warning for the high step, near_limit for the very
// high step. A window passes `colors`, the tokens of the appearance in force.
intensity_color :: proc "contextless" (intensity: Intensity, concept: Color, tokens: Color_Tokens) -> Color {
	switch intensity {
	case .Normal:
	case .High:
		return tokens.warning
	case .Very_High:
		return tokens.near_limit
	}
	return concept
}
