import Accelerate
import AVFoundation
import Foundation

/// Records from `MicrophoneHub` into a 16kHz mono WAV, ending when you stop talking
/// rather than when a timer runs out.
///
/// The old path called `AVAudioRecorder.record(forDuration: 5)`, so a three word question
/// still cost five seconds of standing there and a longer one got clipped mid sentence.
/// It also opened a second claim on the mic, which is why the wake word listener had to be
/// torn down around every ask.
final class MicRecorder: @unchecked Sendable {

    struct Options {
        /// Never stop before this, so a slow start is not mistaken for a finished question.
        var minDuration: TimeInterval = 1.0
        /// Hard ceiling regardless of what the mic is hearing.
        var maxDuration: TimeInterval = 15.0
        /// How much trailing quiet ends the take.
        var trailingSilence: TimeInterval = 0.9
        /// RMS at or below this counts as silence. HFP from the glasses is noisy, so this
        /// sits well above a true digital zero.
        var silenceThreshold: Float = 0.015
        /// When false, record exactly `maxDuration`. Used by the loopback diagnostic,
        /// which wants a predictable length rather than a natural one.
        var endpointOnSilence: Bool = true

        static let ask = Options()

        static func fixed(seconds: TimeInterval) -> Options {
            Options(minDuration: seconds, maxDuration: seconds, endpointOnSilence: false)
        }
    }

    enum RecorderError: LocalizedError {
        case noInput
        case converterUnavailable
        case fileFailed(String)
        case producedNothing

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "No microphone input is available. Check the audio route and try again."
            case .converterUnavailable:
                return "Could not convert microphone audio to the format the backend expects."
            case .fileFailed(let message):
                return "Recorder: \(message)"
            case .producedNothing:
                return "The microphone produced no audio."
            }
        }
    }

    private let hub: MicrophoneHub

    init(hub: MicrophoneHub = .shared) {
        self.hub = hub
    }

    func record(_ options: Options = .ask) async throws -> URL {
        let take = try Take(options: options, inputFormat: hub.inputFormat)
        return try await withCheckedThrowingContinuation { continuation in
            take.begin(hub: hub, continuation: continuation)
        }
    }
}

// MARK: - One recording

/// All the mutable state for a single take, so nothing leaks between recordings and the
/// audio thread has exactly one object to talk to.
private final class Take: @unchecked Sendable {
    private let options: MicRecorder.Options
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let url: URL

    /// File I/O does not belong on the realtime audio thread, so conversion happens inline
    /// (bounded, no I/O) and the finished buffer is handed here to be written.
    private let writeQueue = DispatchQueue(label: "com.kish.glassbridge.mic-write")

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var sinkID: UUID?
    private var hub: MicrophoneHub?
    private var watchdog: Task<Void, Never>?

    private var elapsed: TimeInterval = 0
    private var silenceRun: TimeInterval = 0
    private var heardSpeech = false
    private var wroteAnything = false
    private var done = false

    init(options: MicRecorder.Options, inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicRecorder.RecorderError.noInput
        }
        self.options = options
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassbridge-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw MicRecorder.RecorderError.fileFailed(error.localizedDescription)
        }
        self.outputFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicRecorder.RecorderError.converterUnavailable
        }
        self.converter = converter
    }

    func begin(hub: MicrophoneHub, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        self.hub = hub
        lock.unlock()

        do {
            let id = try hub.addSink { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            lock.lock()
            let alreadyDone = done
            if !alreadyDone { sinkID = id }
            lock.unlock()
            // The take can finish before `addSink` returns if the very first buffer ends
            // it, in which case nobody was holding the id to detach with.
            if alreadyDone {
                hub.removeSink(id)
                return
            }
            startWatchdog()
        } catch {
            finish(.failure(error))
        }
    }

    /// Realtime audio thread.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer), converted.frameLength > 0 else { return }

        let seconds = Double(converted.frameLength) / outputFormat.sampleRate
        let level = rms(converted)

        lock.lock()
        if done {
            lock.unlock()
            return
        }
        elapsed += seconds
        if level > options.silenceThreshold {
            heardSpeech = true
            silenceRun = 0
        } else if heardSpeech {
            silenceRun += seconds
        }
        let hitCeiling = elapsed >= options.maxDuration
        let settled = options.endpointOnSilence
            && heardSpeech
            && silenceRun >= options.trailingSilence
            && elapsed >= options.minDuration
        wroteAnything = true
        lock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.file.write(from: converted)
            } catch {
                self.finish(.failure(MicRecorder.RecorderError.fileFailed(error.localizedDescription)))
            }
        }

        if hitCeiling || settled {
            finish(.success(url))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(channel, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }

    /// If the mic never delivers a buffer the sink never fires, so nothing above would
    /// ever resume the continuation.
    private func startWatchdog() {
        let limit = options.maxDuration + 3.0
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(MicRecorder.RecorderError.producedNothing))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        let sinkID = self.sinkID
        let hub = self.hub
        let producedAudio = wroteAnything
        lock.unlock()

        watchdog?.cancel()
        if let sinkID { hub?.removeSink(sinkID) }

        // Let every queued write land before handing the file back, otherwise the upload
        // can read a WAV that is still missing its tail.
        writeQueue.async {
            switch result {
            case .success(let url):
                if producedAudio {
                    continuation?.resume(returning: url)
                } else {
                    continuation?.resume(throwing: MicRecorder.RecorderError.producedNothing)
                }
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }
}
