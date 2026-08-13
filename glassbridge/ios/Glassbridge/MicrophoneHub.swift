import AVFoundation
import Foundation

/// The single owner of the microphone.
///
/// `AVAudioEngine`'s input node and `AVAudioRecorder` cannot both hold the mic reliably,
/// which is why the old code had to stop the wake word listener before it could record an
/// ask. Everything that needs input audio subscribes here instead of opening its own
/// capture: one tap, many sinks. The recognizer and an in-flight recording can run at the
/// same time, which is what makes barge-in possible.
final class MicrophoneHub: @unchecked Sendable {
    static let shared = MicrophoneHub()

    /// Invoked on the realtime audio thread. Keep the work bounded, allocate as little as
    /// possible, and never touch UI or block. The buffer is reused after you return, so
    /// copy anything you intend to keep.
    typealias Sink = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    enum HubError: LocalizedError {
        case noInputAvailable

        var errorDescription: String? {
            switch self {
            case .noInputAvailable:
                return "No microphone input is available yet. Check the audio route and try again."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sinks: [UUID: Sink] = [:]
    private var isTapped = false

    private init() {}

    /// The format the tap delivers, which is whatever the hardware gives us (usually
    /// 48kHz float). Subscribers that need something else convert on their own.
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// True while at least one subscriber is attached and the engine is running.
    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTapped
    }

    /// Attach a sink, starting the engine if this is the first one.
    /// Hold the returned id and pass it to `removeSink` when you are done.
    func addSink(_ sink: @escaping Sink) throws -> UUID {
        let id = UUID()
        lock.lock()
        sinks[id] = sink
        lock.unlock()

        do {
            try startIfNeeded()
        } catch {
            lock.lock()
            sinks.removeValue(forKey: id)
            lock.unlock()
            throw error
        }
        return id
    }

    /// Detach a sink, stopping the engine once the last one goes away so we are not
    /// holding the mic (and the route) open for nothing.
    func removeSink(_ id: UUID) {
        lock.lock()
        sinks.removeValue(forKey: id)
        let nowEmpty = sinks.isEmpty
        lock.unlock()
        if nowEmpty { stop() }
    }

    private func startIfNeeded() throws {
        // Claim the flag before touching the engine. `engine.start()` can deliver its
        // first buffer before it returns, and the tap takes this same lock, so holding
        // the lock across the start call would deadlock against our own callback.
        lock.lock()
        if isTapped {
            lock.unlock()
            return
        }
        isTapped = true
        lock.unlock()

        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A zero sample rate means the session has not activated a route yet.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw HubError.noInputAvailable
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
                guard let self else { return }
                // Copy the sink list out before invoking any of them: a sink that removes
                // itself mid-callback would otherwise mutate the collection being iterated.
                self.lock.lock()
                let current = Array(self.sinks.values)
                self.lock.unlock()
                for sink in current { sink(buffer, when) }
            }

            engine.prepare()
            try engine.start()
        } catch {
            lock.lock()
            isTapped = false
            lock.unlock()
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    private func stop() {
        lock.lock()
        if !isTapped {
            lock.unlock()
            return
        }
        isTapped = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
