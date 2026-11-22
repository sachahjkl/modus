// Live multi-stream mixer, microphone capture indicator, and device crystal
// clock-drift tracker integrated into the sound system service.
package sound_device_service

import "modus:contract/sound_mixer"

sound_live_mixer: sound_mixer.Mixer_State
sound_live_capture: sound_mixer.Capture_State
sound_live_drift: sound_mixer.Clock_Drift_Tracker
sound_mixer_ready: bool

sound_mixer_service_init :: proc "contextless" () {
	sound_live_mixer = {}
	sound_live_capture = {}
	sound_live_drift = {}
	sound_mixer_ready = true
}

sound_capture_indicator_visible :: proc "contextless" () -> bool {
	if !sound_mixer_ready {
		return false
	}
	return sound_mixer.capture_indicator_state(&sound_live_capture) == .Active
}
