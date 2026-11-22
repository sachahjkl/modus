type: Added

**Mesa Venus Vulkan pipeline objects, barriers, and draw-table translation.** `modus:contract/venus_vulkan` now encodes and decodes `vkCreateImage`, `vkBindImageMemory`, `vkCreateImageView`, `vkCreateRenderPass`, `vkCreateFramebuffer`, `vkCreateShaderModule`, `vkCreatePipelineLayout`, `vkCreateGraphicsPipelines`, `vkCmdPipelineBarrier`, `vkCmdBeginRenderPass`, and `vkCmdCopyImageToBuffer`, and translates 2D `draw_record` tables through `webgpu_subset` into Mesa Venus Vulkan command streams.
