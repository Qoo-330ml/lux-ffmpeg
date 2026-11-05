//
// lux-ffmpeg-probe — 读取一个媒体文件并打印流信息(F1 的 macOS 自检入口)。
//
//   .build/debug/lux-ffmpeg-probe path/to/file.mkv
//
import Foundation
import LuxFFmpegProbeKit

#if canImport(Darwin)
import Darwin
#endif

let arguments = CommandLine.arguments
let fixture = arguments.count > 1 ? arguments[1] : ProcessInfo.processInfo.environment["LUX_FFMPEG_FIXTURE"] ?? ""
guard !fixture.isEmpty else {
    FileHandle.standardError.write(Data("usage: lux-ffmpeg-probe <file>\n".utf8))
    exit(2)
}

do {
    let result = try runProbe(path: fixture)
    print("versions: \(versions())")
    print("license: \(result.license)")
    print("format: \(result.formatName)")
    print("duration: \(String(format: "%.3f", result.durationSeconds))")
    print("streams: \(result.streams.count)")
    for stream in result.streams {
        print("stream #\(stream.index): type=\(stream.mediaType) codec=\(stream.codec) " +
              "\(stream.width)x\(stream.height) \(stream.sampleRate)Hz \(stream.channels)ch")
    }
    print("packets: \(result.packetsRead)")
    print("first frame: \(result.firstFrame)")
} catch {
    FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
    exit(1)
}
