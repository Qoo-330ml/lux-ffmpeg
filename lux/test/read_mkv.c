/*
 * lux/test/read_mkv.c — F0 最小可运行验证
 *
 * 只用 libavformat/libavcodec/libavutil 的公开 API 读一个 mkv:
 *   - 打印库版本与 avutil_license();
 *   - avformat_open_input + avformat_find_stream_info;
 *   - 打印流数量、每路编码名、时长;
 *   - 找到第一个视频包,打印它是不是关键帧、以及它在文件中的偏移 pos;
 *   - 继续读到 EOF,按流统计包数。
 *
 * 构建与运行见 lux/test/run.sh。F0 只验 macOS arm64 产物(iOS 产物无法在本机运行)。
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>

static const char *type_name(enum AVMediaType type)
{
    switch (type) {
    case AVMEDIA_TYPE_VIDEO:    return "video";
    case AVMEDIA_TYPE_AUDIO:    return "audio";
    case AVMEDIA_TYPE_SUBTITLE: return "subtitle";
    case AVMEDIA_TYPE_DATA:     return "data";
    default: {
        const char *s = av_get_media_type_string(type);
        return s ? s : "other";
    }
    }
}

static void print_error(const char *what, int err)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = { 0 };
    av_strerror(err, buf, sizeof(buf));
    fprintf(stderr, "%s: %s (%d)\n", what, buf, err);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <file.mkv>\n", argv[0]);
        return 2;
    }

    av_log_set_level(AV_LOG_ERROR);

    printf("avutil_license: %s\n", avutil_license());
    printf("libavformat: %u.%u.%u\n",
           LIBAVFORMAT_VERSION_MAJOR, LIBAVFORMAT_VERSION_MINOR, LIBAVFORMAT_VERSION_MICRO);
    printf("libavcodec: %u.%u.%u\n",
           LIBAVCODEC_VERSION_MAJOR, LIBAVCODEC_VERSION_MINOR, LIBAVCODEC_VERSION_MICRO);
    printf("libavutil: %u.%u.%u\n",
           LIBAVUTIL_VERSION_MAJOR, LIBAVUTIL_VERSION_MINOR, LIBAVUTIL_VERSION_MICRO);
    printf("input: %s\n", argv[1]);

    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, argv[1], NULL, NULL);
    if (ret < 0) {
        print_error("avformat_open_input", ret);
        return 1;
    }

    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        print_error("avformat_find_stream_info", ret);
        avformat_close_input(&fmt);
        return 1;
    }

    printf("format: %s (%s)\n",
           fmt->iformat->name ? fmt->iformat->name : "?",
           fmt->iformat->long_name ? fmt->iformat->long_name : "?");
    printf("streams: %d\n", fmt->nb_streams);
    printf("duration: %.3f\n", fmt->duration == AV_NOPTS_VALUE
                               ? -1.0 : fmt->duration / (double)AV_TIME_BASE);

    int video_index = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        const AVCodecParameters *par = st->codecpar;
        const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);
        char extra[128] = "";

        if (par->codec_type == AVMEDIA_TYPE_VIDEO)
            snprintf(extra, sizeof(extra), " %dx%d", par->width, par->height);
        else if (par->codec_type == AVMEDIA_TYPE_AUDIO)
            snprintf(extra, sizeof(extra), " %dHz %dch", par->sample_rate, par->ch_layout.nb_channels);

        printf("stream #%u: type=%s codec=%s encoder_name=%s%s\n",
               i, type_name(par->codec_type),
               desc ? desc->name : avcodec_get_name(par->codec_id),
               par->codec_id == AV_CODEC_ID_NONE ? "?" : avcodec_get_name(par->codec_id),
               extra);

        if (video_index < 0 && par->codec_type == AVMEDIA_TYPE_VIDEO)
            video_index = (int)i;
    }

    /* 第一个视频包:是否关键帧 + 文件内偏移 */
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        fprintf(stderr, "av_packet_alloc failed\n");
        avformat_close_input(&fmt);
        return 1;
    }

    int first_video_seen = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == video_index) {
            printf("first video packet: keyframe=%d pos=%" PRId64 " size=%d pts=%" PRId64 "\n",
                   !!(pkt->flags & AV_PKT_FLAG_KEY), pkt->pos, pkt->size, pkt->pts);
            first_video_seen = 1;
            av_packet_unref(pkt);
            break;
        }
        av_packet_unref(pkt);
    }
    if (!first_video_seen)
        printf("first video packet: <none found>\n");

    /* 读到 EOF,按流计数 */
    long long *counts = calloc(fmt->nb_streams, sizeof(*counts));
    long long total = 0;
    if (!counts) {
        fprintf(stderr, "calloc failed\n");
        av_packet_free(&pkt);
        avformat_close_input(&fmt);
        return 1;
    }
    while ((ret = av_read_frame(fmt, pkt)) >= 0) {
        if (pkt->stream_index < (int)fmt->nb_streams)
            counts[pkt->stream_index]++;
        total++;
        av_packet_unref(pkt);
    }
    if (ret != AVERROR_EOF) {
        print_error("av_read_frame (expected EOF)", ret);
        free(counts);
        av_packet_free(&pkt);
        avformat_close_input(&fmt);
        return 1;
    }

    printf("packets_total: %lld\n", total);
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        printf("packets_stream_%u: %lld\n", i, counts[i]);

    free(counts);
    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    printf("result: ok\n");
    return 0;
}
