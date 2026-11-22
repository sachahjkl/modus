// Live separable blur and WebGPU/Venus acceleration helpers wired into the
// virtual GPU device service.
package gpu_device_service

import "modus:contract/blur_filter"

gpu_surface_blur :: proc "contextless" (pixels, scratch: []u8, width, height, radius, passes: int) -> bool {
	return blur_filter.blur_rgba_separable(pixels, scratch, width, height, radius, passes) == .None
}
