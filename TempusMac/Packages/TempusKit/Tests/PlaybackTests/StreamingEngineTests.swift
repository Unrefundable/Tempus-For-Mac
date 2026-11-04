import AVFoundation
import Foundation
@testable import Playback
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
