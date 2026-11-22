// Freestanding, zero-allocation PNG and baseline JPEG image decoders with
// SSE2 vector forms for PNG scanline filters, JPEG 2D IDCT, and YCbCr to
// RGBA color conversion (src/md/features/desktop_to_browser.md).
//
// All working memory is supplied by the caller through a scratch slice and
// an output RGBA pixel buffer (4 bytes per pixel: R, G, B, A). Every
// refusal validates headers, checksums, and entropy streams before touching
// output_rgba so a rejected image leaves output_rgba completely unchanged.
package image_decode

import "modus:contract/enum_word"

// Hard safety bounds against memory exhaustion and decompression bombs.
MAX_IMAGE_WIDTH :: 4096
MAX_IMAGE_HEIGHT :: 4096
MAX_IMAGE_PIXELS :: MAX_IMAGE_WIDTH * MAX_IMAGE_HEIGHT
RGBA_BYTES_PER_PIXEL :: 4

// Closed set of supported image formats. Values cross process borders.
Image_Format :: enum u8 {
	Png  = 1,
	Jpeg = 2,
}

// Closed set of refusals returned by image probing and decoding.
Image_Decode_Refusal :: enum u8 {
	None                    = 0,
	Bad_Magic               = 1,
	Truncated               = 2,
	Corrupt_Stream          = 3,
	Unsupported_Variant     = 4,
	Dimensions_Invalid      = 5,
	Decompression_Bomb      = 6,
	Output_Buffer_Too_Small = 7,
	Scratch_Too_Small       = 8,
	Checksum_Mismatch       = 9,
}

// image_format_of_word converts a transport word into an Image_Format at the
// border, refusing any value that names no member.
image_format_of_word :: proc "contextless" (word: u8) -> (format: Image_Format, ok: bool) {
	return enum_word.member_of_word(Image_Format, u64(word))
}

// image_decode_refusal_of_word converts a transport word into an
// Image_Decode_Refusal at the border, refusing any value that names no member.
image_decode_refusal_of_word :: proc "contextless" (word: u8) -> (refusal: Image_Decode_Refusal, ok: bool) {
	return enum_word.member_of_word(Image_Decode_Refusal, u64(word))
}

// Decoded metadata returned by probe and decode procedures.
Image_Header :: struct {
	format:                Image_Format,
	width:                 u32,
	height:                u32,
	output_bytes:          u64,
	minimum_scratch_bytes: u64,
}

// validate_dimensions checks image width and height against zero and the
// hard pixel/dimension bounds without integer overflow.
@(private)
validate_dimensions :: proc "contextless" (width, height: u32) -> (output_bytes: u64, refusal: Image_Decode_Refusal) {
	if width == 0 || height == 0 {
		return 0, .Dimensions_Invalid
	}
	if width > MAX_IMAGE_WIDTH || height > MAX_IMAGE_HEIGHT {
		return 0, .Decompression_Bomb
	}
	pixels := u64(width) * u64(height)
	if pixels > MAX_IMAGE_PIXELS {
		return 0, .Decompression_Bomb
	}
	return pixels * RGBA_BYTES_PER_PIXEL, .None
}

// image_detect_format inspects the leading signature bytes to identify a
// PNG or JPEG stream.
image_detect_format :: proc "contextless" (bytes: []u8) -> (format: Image_Format, refusal: Image_Decode_Refusal) {
	if len(bytes) == 0 {
		return {}, .Truncated
	}
	if bytes[0] == 0x89 {
		sig := PNG_SIGNATURE
		check_len := min(len(bytes), len(sig))
		for i in 0 ..< check_len {
			if bytes[i] != sig[i] {
				return {}, .Bad_Magic
			}
		}
		if len(bytes) < len(sig) {
			return {}, .Truncated
		}
		return .Png, .None
	}
	if bytes[0] == 0xFF {
		if len(bytes) < 2 {
			return {}, .Truncated
		}
		if bytes[1] == u8(Jpeg_Marker.Soi) {
			return .Jpeg, .None
		}
		return {}, .Bad_Magic
	}
	return {}, .Bad_Magic
}

// image_probe detects the format and validates image headers and dimensions
// without decoding pixels.
image_probe :: proc "contextless" (bytes: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) {
	format, detect_refusal := image_detect_format(bytes)
	if detect_refusal != .None {
		return {}, detect_refusal
	}
	switch format {
	case .Png:
		return png_probe(bytes)
	case .Jpeg:
		return jpeg_probe(bytes)
	}
	return {}, .Bad_Magic
}

// image_decode_rgba detects the format and decodes a PNG or baseline JPEG
// into caller-provided output_rgba (4 bytes per pixel, row-major R, G, B, A)
// using caller-provided scratch memory. On any refusal, output_rgba is never
// written.
image_decode_rgba :: proc "contextless" (bytes: []u8, output_rgba: []u8, scratch: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) {
	format, detect_refusal := image_detect_format(bytes)
	if detect_refusal != .None {
		return {}, detect_refusal
	}
	switch format {
	case .Png:
		return png_decode_rgba(bytes, output_rgba, scratch)
	case .Jpeg:
		return jpeg_decode_rgba(bytes, output_rgba, scratch)
	}
	return {}, .Bad_Magic
}
