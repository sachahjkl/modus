type: Added

**SSE2 vector spans for translucent blends, horizontal gradients, and path coverage.** Added bit-for-bit SSE2 vector forms for translucent solid span blending (`blend_span_simd`), horizontal gradients (`horizontal_gradient_span_simd`, `horizontal_gradient_with_alpha_span_simd`, `mix_with_alpha_span_simd`), and path coverage scanline accumulation and compositing (`path_coverage_span_simd`) in `modus:graphics`, wired into `blend_fill`, `gradient`, `gradient_with_alpha`, and draw-table path and gradient execution.
