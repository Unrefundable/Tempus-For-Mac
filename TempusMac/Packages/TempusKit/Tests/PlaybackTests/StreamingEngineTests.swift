import AVFoundation
import Foundation
@testable import Playback
import Synchronization
import Testing

/// The real AudioStreaming engine, playing short local files silently.
@MainActor
@Suite("Streaming engine", .serialized)
struct StreamingEngineTests {
    private static let timeout: TimeInterval = 10

    /// Writes a sine of `seconds` to a WAV file and returns its URL.
    private func sineFile(_ name: String, seconds: Double = 0.6) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< 2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0 ..< Int(frames) {
                samples[frame] = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / 44100))
            }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    @Test("Two queued files play back to back, each reported by its queue entry")
    func backToBack() async throws {
        let engine = StreamingEngine()
        engine.volume = 0
        var events: [EngineEvent] = []
        engine.onEvent = { events.append($0) }
        let first = try EngineItem(id: UUID(), url: sineFile("a"), headers: [:])
        let second = try EngineItem(id: UUID(), url: sineFile("b"), headers: [:])

        engine.play(first)
        engine.setUpcoming(second)
        let deadline = Date() + Self.timeout
        while !events.contains(.finished(second.id, .ended)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        let lifecycle = events.filter {
            if case .stateChanged = $0 {
                false
            } else {
                true
            }
        }
        #expect(lifecycle == [
            .started(first.id), .finished(first.id, .ended), .started(second.id), .finished(second.id, .ended),
        ])
        engine.stop()
    }

    @Test("Replacing the upcoming entry with the same file doesn't stop the playing one")
    func sameFileUpcoming() async throws {
        let engine = StreamingEngine()
        engine.volume = 0
        var events: [EngineEvent] = []
        engine.onEvent = { events.append($0) }
        let url = try sineFile("loop")
        let item = EngineItem(id: UUID(), url: url, headers: [:])

        engine.play(item)
        engine.setUpcoming(item) // repeat one: the same entry again
        engine.setUpcoming(item) // and replaced, which once stopped playback
        let deadline = Date() + Self.timeout
        while events.count(where: { $0 == .finished(item.id, .ended) }) < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(events.count(where: { $0 == .started(item.id) }) == 2)
        #expect(!events.contains(.finished(item.id, .stopped)))
        engine.stop()
    }

    @Test("A FLAC seek plays from the requested time, even where the bitrate varies")
    func flacSeekIsAccurate() async throws {
        // Clicking a lyric seeks to its line. AudioStreaming used to guess the byte offset as if the
        // bitrate were constant, so in a FLAC with a quiet start the audio jumped seconds past the
        // line while the reported position (and the highlighted lyric) said otherwise.
        let engine = StreamingEngine()
        engine.volume = 0
        let pitch = PitchMeter()
        engine.equalizerNode.installTap(onBus: 0, bufferSize: 4410, format: nil, block: pitch.tap)
        defer { engine.equalizerNode.removeTap(onBus: 0) }

        try engine.play(EngineItem(id: UUID(), url: Self.silenceThenSweep(), headers: [:]))
        try await Task.sleep(for: .seconds(1))
        engine.seek(to: 9)
        try await Task.sleep(for: .seconds(0.8))
        let heard = Self.sweepPosition(hearing: pitch.frequency)
        let reported = engine.progress
        engine.stop()

        // A constant-bitrate guess lands near 10.5 s. The tap runs a buffer (0.1 s) ahead of what
        // `progress` has counted as played.
        #expect(abs(reported - 9.8) < 0.5, "reported \(reported)")
        #expect(abs(heard - reported) < 0.4, "heard \(heard), reported \(reported)")
    }

    /// 6 s of silence, which FLAC packs into almost nothing, then a 6 s sweep from 300 to 900 Hz.
    private static func silenceThenSweep() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "sweep.flac")
        let rate = 44100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = AVAudioFrameCount(rate * 12)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< 2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0 ..< Int(frames) {
                let sweepTime = Double(frame) / rate - 6
                // The phase of a tone rising 100 Hz a second from 300 Hz.
                let phase = 2 * Double.pi * (300 * sweepTime + 50 * sweepTime * sweepTime)
                samples[frame] = sweepTime > 0 ? Float(0.3 * sin(phase)) : 0
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
        ]
        // In a scope of its own: the file's header is finished when it closes.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        return url
    }

    /// Where in `silenceThenSweep` a tone of `frequency` plays.
    private static func sweepPosition(hearing frequency: Double) -> Double {
        6 + (frequency - 300) / 100
    }

    @Test("Equalizer bands, ReplayGain and the preamp reach the EQ unit")
    func equalizer() throws {
        let engine = StreamingEngine()
        let profile = try ParametricProfile(parsing: "Preamp: -4 dB\nFilter 1: ON PK Fc 1000 Hz Gain -3 dB Q 1.41")
        engine.apply(equalizer: EqualizerSettings(mode: .parametric, parametric: profile))
        engine.setGain(decibels: -6)

        let band = engine.equalizerNode.bands[0]
        #expect(band.filterType == .parametric)
        #expect(band.frequency == 1000)
        #expect(band.gain == -3)
        #expect(!band.bypass)
        #expect(engine.equalizerNode.bands[1].bypass)
        #expect(engine.equalizerNode.globalGain == -10)

        engine.setGain(decibels: 200)
        #expect(engine.equalizerNode.globalGain == 24)
    }

    @Test("The redirect hook runs off the main thread, where URLSession calls it")
    func redirectOffMainThread() async throws {
        // Internet radio streams nearly always redirect. The hook used to be main-actor isolated
        // and trapped as soon as URLSession's delegate queue called it.
        let handler = StreamingEngine.redirectHandler(reading: PolicyBox(nil))
        let source = try #require(URL(string: "https://radio.example/stream"))
        let target = try #require(URL(string: "https://cdn.example/live.mp3"))
        let response = try #require(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))

        let followed = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handler(response, URLRequest(url: target))?.url)
            }
        }

        #expect(followed == target)
    }
}

/// Measures the pitch of the engine's output, from zero crossings, on the audio thread.
private final class PitchMeter: Sendable {
    private let latest = Mutex<Double>(0)

    var frequency: Double {
        latest.withLock { $0 }
    }

    /// Built outside the main actor: the tap runs on the audio thread, where an isolated closure traps.
    nonisolated var tap: AVAudioNodeTapBlock {
        { [self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 1 else { return }
            let count = Int(buffer.frameLength)
            let crossings = (1 ..< count).count { (samples[$0 - 1] < 0) != (samples[$0] < 0) }
            let seconds = Double(count) / buffer.format.sampleRate
            latest.withLock { $0 = Double(crossings) / 2 / seconds }
        }
    }
}
