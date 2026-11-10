/*
 * B+ Vulkan smoke test: create an AVHWDeviceContext of type vulkan.
 *
 * This exercises the full runtime chain:
 *   libavutil/hwcontext_vulkan.c -> dlopen("@rpath/LibMoltenVK.framework/LibMoltenVK")
 *   -> vkCreateInstance -> device selection.
 *
 * Exit codes: 0 = device created, 77 = Vulkan unavailable (skip), 1 = failure.
 */
#include <stdio.h>

#include "libavutil/buffer.h"
#include "libavutil/error.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_vulkan.h"

int main(void)
{
    AVBufferRef *ref = NULL;
    int err = av_hwdevice_ctx_create(&ref, AV_HWDEVICE_TYPE_VULKAN, NULL, NULL, 0);
    if (err < 0) {
        char msg[128];
        av_strerror(err, msg, sizeof(msg));
        printf("vulkan: unavailable (%s)\n", msg);
        return 77;
    }

    AVHWDeviceContext *ctx = (AVHWDeviceContext *)ref->data;
    AVVulkanDeviceContext *vk = ctx->hwctx;
    printf("vulkan: device=%p get_proc_addr=%p\n",
           (void *)vk->phys_dev, (void *)(uintptr_t)vk->get_proc_addr);
    printf("vulkan: device created\n");
    av_buffer_unref(&ref);
    return 0;
}
