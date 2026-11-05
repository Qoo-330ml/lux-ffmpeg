//
// LuxFFmpegProbeKit — 用 Swift 直接调用 lux-ffmpeg 动态 framework 的最小探针。
//
// 这个文件刻意只使用 FFmpeg 的公开 C API,并同时 import 四个模块:
//   * Libavformat  → avformat_open_input / avformat_find_stream_info / av_read_frame
//   * Libavcodec   → avcodec_find_decoder / avcodec_parameters_to_context / avcodec_send_packet
//   * Libavutil    → avutil_license / avutil_version / AVPacket
//   * Libswresample→ swresample_version(只证明模块可导入)
//
// 它验证的三件事:
//   1. 四个 module 能被 Swift 直接 import,不需要 C shim、-I 或大小写不敏感的卷;
//   2. 跨模块的 C 类型可以互操作(avformat 产出的 AVCodecParameters 交给 avcodec);
//   3. 动态库真的能跑:打开 F0 的合成 mkv、解出第一帧 H.264。
//
import Foundation
#if canImport(Darwin)
import Darwin
#endif

import Libavcodec
import Libavformat
import Libavutil
import Libswresample

public struct ProbeStream: Sendable, Equatable {
    public let index: Int
    public let mediaType: String
    public let codec: String
    public let width: Int32
    public let height: Int32
    public let sampleRate: Int32
    public let channels: Int32
}

public struct ProbeResult: Sendable, Equatable {
    public let license: String
    public let formatName: String
    public let durationSeconds: Double
    public let streams: [ProbeStream]
    public let packetsRead: Int
    public let firstFrame: String
}

public enum ProbeError: Error, CustomStringConvertible {
    case openInput(Int32)
    case findStreamInfo(Int32)
    case noDecoder(String)
    case openDecoder(Int32)
    case noFrame

    public var description: String {
        switch self {
        case .openInput(let code): return "avformat_open_input failed (\(code))"
        case .findStreamInfo(let code): return "avformat_find_stream_info failed (\(code))"
        case .noDecoder(let codec): return "no decoder for \(codec)"
        case .openDecoder(let code): return "avcodec_open2 failed (\(code))"
        case .noFrame: return "decoder produced no frame"
        }
    }
}

private func avErrorString(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
    av_strerror(code, &buffer, buffer.count)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func mediaTypeName(_ type: AVMediaType) -> String {
    switch type {
    case AVMEDIA_TYPE_VIDEO: return "video"
    case AVMEDIA_TYPE_AUDIO: return "audio"
    case AVMEDIA_TYPE_SUBTITLE: return "subtitle"
    case AVMEDIA_TYPE_DATA: return "data"
    case AVMEDIA_TYPE_ATTACHMENT: return "attachment"
    default: return "other"
    }
}

/// 打开一个媒体文件,打印/返回流信息,并解码第一帧视频。
public func runProbe(path: String) throws -> ProbeResult {
    av_log_set_level(AV_LOG_ERROR)

    var context: UnsafeMutablePointer<AVFormatContext>? = nil
    var status = avformat_open_input(&context, path, nil, nil)
    guard status == 0, let format = context else {
        throw ProbeError.openInput(status)
    }
    defer { avformat_close_input(&context) }

    status = avformat_find_stream_info(format, nil)
    guard status >= 0 else { throw ProbeError.findStreamInfo(status) }

    var streams: [ProbeStream] = []
    var streamsPointer = format.pointee.streams
    for index in 0..<Int(format.pointee.nb_streams) {
        guard let stream = streamsPointer?[index] else { continue }
        let parameters = stream.pointee.codecpar
        let codecName = parameters.flatMap { avcodec_get_name($0.pointee.codec_id) }
            .map { String(cString: $0) } ?? "unknown"
        streams.append(ProbeStream(
            index: index,
            mediaType: parameters.map { mediaTypeName($0.pointee.codec_type) } ?? "unknown",
            codec: codecName,
            width: parameters?.pointee.width ?? 0,
            height: parameters?.pointee.height ?? 0,
            sampleRate: parameters?.pointee.sample_rate ?? 0,
            channels: parameters?.pointee.ch_layout.nb_channels ?? 0
        ))
    }
    streamsPointer = nil

    let formatName = format.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? "unknown"
    let durationSeconds = format.pointee.duration > 0
        ? Double(format.pointee.duration) / Double(AV_TIME_BASE)
        : 0

    // 找第一路视频,把 avformat 的 AVCodecParameters 交给 avcodec 建解码器。
    // 这一步同时验证两个模块对同一批 C 类型的理解是一致的。
    var decoderContext: UnsafeMutablePointer<AVCodecContext>? = nil
    defer { avcodec_free_context(&decoderContext) }
    var videoStream = -1
    var selected: UnsafeMutablePointer<AVStream>? = nil
    let best = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
    if best >= 0, let streams = format.pointee.streams {
        videoStream = Int(best)
        selected = streams[videoStream]
    }
    guard let video = selected, let parameters = video.pointee.codecpar else {
        throw ProbeError.noDecoder("no video stream")
    }
    let codecID = parameters.pointee.codec_id
    let codecName = String(cString: avcodec_get_name(codecID))
    guard let decoder = avcodec_find_decoder(codecID) else {
        throw ProbeError.noDecoder(codecName)
    }
    decoderContext = avcodec_alloc_context3(decoder)
    guard let decoderContext else { throw ProbeError.openDecoder(-1) }
    status = avcodec_parameters_to_context(decoderContext, parameters)
    guard status >= 0 else { throw ProbeError.openDecoder(status) }
    decoderContext.pointee.pkt_timebase = video.pointee.time_base
    status = avcodec_open2(decoderContext, decoder, nil)
    guard status >= 0 else { throw ProbeError.openDecoder(status) }

    var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    defer {
        av_packet_free(&packet)
        av_frame_free(&frame)
    }
    guard let packet, let frame else { throw ProbeError.openDecoder(-1) }

    var packetsRead = 0
    var firstFrame = "none"
    decode: while true {
        status = av_read_frame(format, packet)
        if status < 0 { break }
        defer { av_packet_unref(packet) }
        packetsRead += 1
        guard packet.pointee.stream_index == Int32(videoStream) else { continue }
        status = avcodec_send_packet(decoderContext, packet)
        if status < 0 && status != -EAGAIN { break }
        status = avcodec_receive_frame(decoderContext, frame)
        if status == 0 {
            let pixelFormat = av_get_pix_fmt_name(AVPixelFormat(rawValue: frame.pointee.format))
                .map { String(cString: $0) } ?? "unknown"
            firstFrame = "\(frame.pointee.width)x\(frame.pointee.height) @\(pixelFormat)"
            break decode
        }
        if status != -EAGAIN { break }
    }
    guard firstFrame != "none" else { throw ProbeError.noFrame }

    return ProbeResult(
        license: String(cString: avutil_license()),
        formatName: formatName,
        durationSeconds: durationSeconds,
        streams: streams,
        packetsRead: packetsRead,
        firstFrame: firstFrame
    )
}

public func versions() -> String {
    "libavformat \(LIBAVFORMAT_VERSION_MAJOR).\(LIBAVFORMAT_VERSION_MINOR).\(LIBAVFORMAT_VERSION_MICRO) / " +
    "libavcodec \(LIBAVCODEC_VERSION_MAJOR).\(LIBAVCODEC_VERSION_MINOR).\(LIBAVCODEC_VERSION_MICRO) / " +
    "libavutil \(LIBAVUTIL_VERSION_MAJOR).\(LIBAVUTIL_VERSION_MINOR).\(LIBAVUTIL_VERSION_MICRO) / " +
    "libswresample \(LIBSWRESAMPLE_VERSION_MAJOR).\(LIBSWRESAMPLE_VERSION_MINOR).\(LIBSWRESAMPLE_VERSION_MICRO) " +
    "(swresample_version()=\(swresample_version()))"
}
