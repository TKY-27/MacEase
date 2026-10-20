import AppKit
import Foundation
import Testing
import WebKit

@testable import Formats

@Suite struct WebMPlaybackTests {
    private func makeWebM() throws -> URL {
        let frames = Fixtures.gradientFrames(count: 45, width: 320, height: 180)
        let encoder = try VPXEncoder(
            settings: VPXEncoder.Settings(
                codec: .vp9, width: 320, height: 180, framesPerSecond: 15, kilobitsPerSecond: 600)
        )
        var videoPackets: [EncodedVideoFrame] = []
        for (index, frame) in frames.enumerated() {
            videoPackets += try encoder.encode(YUVFrame(rgba: frame), index: Int64(index), forceKeyframe: index == 0)
        }
        videoPackets += try encoder.finish()
        let opus = try OpusAudioEncoder(channels: 2, bitrate: 96_000)
        let tone = (0..<(OpusAudioEncoder.sampleRate * 3)).flatMap { sample -> [Float] in
            let value = Float(sin(2 * Double.pi * 440 * Double(sample) / 48_000) * 0.3)
            return [value, value]
        }
        let audioPackets = try opus.encode(tone) + opus.finish()

        var video = MediaTrack(number: 1, kind: .video(width: 320, height: 180), codec: .vp9)
        video.defaultDuration = Nanoseconds.perSecond / 15
        var audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus,
            codecPrivate: opus.identificationHeader
        )
        audio.codecDelay = Int64(opus.preSkip) * Nanoseconds.perSecond / 48_000
        audio.seekPreRoll = 80 * Nanoseconds.perMillisecond
        var packets = videoPackets.map { frame in
            MediaPacket(
                track: 1, timestamp: frame.presentation * Nanoseconds.perSecond / 15, isKeyframe: frame.isKeyframe,
                payload: frame.payload
            )
        }
        packets += audioPackets.enumerated().map { index, payload in
            MediaPacket(
                track: 2, timestamp: Int64(index) * 20 * Nanoseconds.perMillisecond, isKeyframe: true, payload: payload)
        }
        packets.sort { ($0.timestamp, $0.track) < ($1.timestamp, $1.track) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "webm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "clip.webm")
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio], webm: true)
        for packet in packets { try muxer.write(packet) }
        try muxer.finish()
        return url
    }

    @MainActor
    @Test func vp9AndOpusWebMDecodesInWebKit() async throws {
        let movie = try makeWebM()
        // Test processes cannot grant WebKit file access.
        let source = "data:video/webm;base64,\(try Data(contentsOf: movie).base64EncodedString())"
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: frame, configuration: configuration)
        // WebKit loads media only in windows.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        view.loadHTMLString(
            #"<style>body{margin:0}</style><video id="v" muted autoplay src="\#(source)"></video>"#, baseURL: nil)
        let script = #"""
            (() => {
            const v = document.getElementById('v');
            return [v.readyState, v.duration, v.videoWidth, v.error ? v.error.code : 0];
            })()
            """#
        var state: [Double] = []
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(50))
            if let values = try? await view.evaluateJavaScript(script) as? [Double], values.count == 4 {
                state = values
                if values[0] >= 3 { break }
            }
        }
        #expect(state.count == 4 && state[0] >= 3, "\(state)")
        guard state.count == 4 else { return }
        #expect(abs(state[1] - 3) < 0.2)
        #expect(state[2] == 320)
        #expect(state[3] == 0)
        let snapshot = try await view.takeSnapshot(configuration: nil)
        let image = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rendered = try PixelBuffer(cgImage: image)
        let expected = Fixtures.gradientFrames(count: 1, width: 320, height: 180)[0]
        let scale = rendered.width / 320
        let renderedBase = (40 * scale * rendered.width + 160 * scale) * 4
        let base = (40 * 320 + 160) * 4
        for channel in 0..<3 {
            let difference = abs(Int(rendered.rgba[renderedBase + channel]) - Int(expected.rgba[base + channel]))
            #expect(difference < 24, "channel \(channel) differs by \(difference)")
        }
    }

    @Test func demuxerReadsWhatTheEncodersProduced() throws {
        var demuxer = try MatroskaDemuxer(url: try makeWebM())
        let decoder = try VPXDecoder(vp9: true)
        var decodedFrames = 0
        var audioPackets = 0
        let opus = try OpusAudioDecoder(channels: 2)
        while let packet = try demuxer.nextPacket() {
            if packet.track == 1 {
                decodedFrames += try decoder.decode(packet.payload).count
            } else {
                audioPackets += try opus.decode(packet.payload).isEmpty ? 0 : 1
            }
        }
        #expect(decodedFrames == 45)
        #expect(audioPackets == 150)
    }
}
