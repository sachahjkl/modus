// Live tile-delta + LZ4 screen video codec integration for remote_display.
package remote_display_service

import "modus:contract/video_codec"

remote_display_encode_tile_frame :: proc "contextless" (
	width, height: u16,
	current_rgba: []u8,
	prev_rgba: []u8,
	out_wire: []u8,
) -> (written: int, changed_tiles: int, ok: bool) {
	n, changed, refusal := video_codec.encode_frame(width, height, current_rgba, prev_rgba, out_wire)
	return n, changed, refusal == .None
}
