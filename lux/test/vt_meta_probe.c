/*
 * vt_meta_probe — dump the colour metadata FFmpeg/mpv can see for a
 * VideoToolbox-decoded frame, and compare it with the copy-back frame.
 *
 * This is a diagnostic tool for the lux-ffmpeg LGPL build. It links the
 * public FFmpeg API only. Build/run instructions are in lux/test/README.md.
 *
 * Usage:
 *   vt_meta_probe <file> [--copy] [--frames N]
 *
 * Without --copy the decoder outputs AV_PIX_FMT_VIDEOTOOLBOX frames
 * (the zero-copy path). With --copy the probe performs the same
 * av_hwframe_transfer_data() step that mpv's videotoolbox-copy hwdec uses.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreVideo/CoreVideo.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/dovi_meta.h>

static const char *sd_name(enum AVFrameSideDataType type)
{
    const char *name = av_frame_side_data_name(type);
    return name ? name : "?";
}

static void dump_attachments(CVPixelBufferRef pb)
{
    if (!pb) {
        printf("  cv: <null>\n");
        return;
    }

    printf("  cv: pixfmt=%s %zux%zu planes=%zu\n",
           av_fourcc2str(CVPixelBufferGetPixelFormatType(pb)),
           CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
           CVPixelBufferGetPlaneCount(pb));

    const struct {
        const char *label;
        CFStringRef key;
    } keys[] = {
        {"matrix", kCVImageBufferYCbCrMatrixKey},
        {"primaries", kCVImageBufferColorPrimariesKey},
        {"transfer", kCVImageBufferTransferFunctionKey},
        {"chroma", kCVImageBufferChromaLocationTopFieldKey},
        {"cgcolorspace", kCVImageBufferCGColorSpaceKey},
    };

    for (int i = 0; i < (int)(sizeof(keys) / sizeof(keys[0])); i++) {
        CFTypeRef value = CVBufferCopyAttachment(pb, keys[i].key, NULL);
        if (!value) {
            printf("  cv.%s: <none>\n", keys[i].label);
            continue;
        }
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            char buf[256] = {0};
            CFStringGetCString((CFStringRef)value, buf, sizeof(buf),
                               kCFStringEncodingUTF8);
            printf("  cv.%s: %s\n", keys[i].label, buf);
        } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            printf("  cv.%s: %s\n", keys[i].label,
                   CFBooleanGetValue((CFBooleanRef)value) ? "true" : "false");
        } else {
            printf("  cv.%s: <%s>\n", keys[i].label,
                   CFGetTypeID(value) == CFNumberGetTypeID() ? "number" : "other");
        }
        CFRelease(value);
    }
}

static void dump_frame(const char *tag, AVFrame *frame)
{
    printf("%s: fmt=%s %dx%d\n", tag,
           av_get_pix_fmt_name(frame->format), frame->width, frame->height);
    printf("  color: range=%s space=%s primaries=%s trc=%s chroma=%s\n",
           av_color_range_name(frame->color_range),
           av_color_space_name(frame->colorspace),
           av_color_primaries_name(frame->color_primaries),
           av_color_transfer_name(frame->color_trc),
           av_chroma_location_name(frame->chroma_location));
    printf("  side_data: %d\n", frame->nb_side_data);
    for (int i = 0; i < frame->nb_side_data; i++)
        printf("    [%d] %s (%zu bytes)\n", i,
               sd_name(frame->side_data[i]->type),
               frame->side_data[i]->size);

    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX)
        dump_attachments((CVPixelBufferRef)frame->data[3]);

    const AVFrameSideData *sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    if (sd) {
        const AVDOVIMetadata *dovi = (const AVDOVIMetadata *)sd->data;
        const AVDOVIRpuDataHeader *h = av_dovi_get_header(dovi);
        printf("  dovi: rpu_profile=%u bl_bit_depth=%u el_bit_depth=%u "
               "disable_residual=%u\n",
               h->vdr_rpu_profile, h->bl_bit_depth, h->el_bit_depth,
               h->disable_residual_flag);
    }
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    int copy = 0, max_frames = 3;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--copy")) {
            copy = 1;
        } else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            max_frames = atoi(argv[++i]);
        } else if (!path) {
            path = argv[i];
        }
    }
    if (!path) {
        fprintf(stderr, "usage: %s <file> [--copy] [--frames N]\n", argv[0]);
        return 2;
    }

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) {
        fprintf(stderr, "cannot open %s\n", path);
        return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0)
        return 1;

    int vst = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vst < 0)
        return 1;

    AVStream *st = fmt->streams[vst];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->thread_count = 1;

    AVBufferRef *device = NULL;
    if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                               NULL, NULL, 0) < 0) {
        fprintf(stderr, "no VideoToolbox device\n");
        return 1;
    }
    ctx->hw_device_ctx = av_buffer_ref(device);

    if (avcodec_open2(ctx, codec, NULL) < 0) {
        fprintf(stderr, "cannot open decoder\n");
        return 1;
    }

    printf("file: %s\ncopy: %d\n", path, copy);
    printf("stream: %s %dx%d pix_fmt=%s\n", codec->name,
           st->codecpar->width, st->codecpar->height,
           av_get_pix_fmt_name(st->codecpar->format));

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int shown = 0;

    while (shown < max_frames && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != vst) {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(ctx, pkt) < 0) {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);

        while (shown < max_frames && avcodec_receive_frame(ctx, frame) >= 0) {
            char tag[64];
            snprintf(tag, sizeof(tag), "frame %d", shown);
            dump_frame(tag, frame);

            if (copy && frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                AVFrame *sw = av_frame_alloc();
                if (av_hwframe_transfer_data(sw, frame, 0) < 0) {
                    printf("  copy: transfer failed\n");
                } else {
                    av_frame_copy_props(sw, frame);
                    dump_frame("  copy", sw);
                }
                av_frame_free(&sw);
            }

            shown++;
            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    av_buffer_unref(&device);
    avformat_close_input(&fmt);
    return shown ? 0 : 1;
}
