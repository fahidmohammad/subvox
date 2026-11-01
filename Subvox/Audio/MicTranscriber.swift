import AVFoundation
import Observation
import Speech

/// Continuous speech-to-text from the microphone. Used as the reference ("ground truth")
/// next to the motion decoder, and to test whether whispering is enough for input.
@MainActor @Observable
final class MicTranscriber {
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var text = ""
    private(set) var isOnDevice = false
    private(set) var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let box = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private weak var sink: AudioSink?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingStart: UUID?

    func start(sink: AudioSink) async {
        guard !isRunning, !isStarting else { return }
        error = nil
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            error = "On-device speech recognition is unavailable. No audio will be sent to a server."
            return
        }
        let start = UUID()
        pendingStart = start
        isStarting = true
        defer {
            if pendingStart == start {
                pendingStart = nil
                isStarting = false
            }
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard pendingStart == start else { return }
        guard status == .authorized else {
            error = "Speech recognition not authorized."
            return
        }
        guard recognizer.isAvailable else {
            error = "Speech recognizer unavailable."
            return
        }

        self.sink = sink
        sinkID = sink.add { [box] buffer, _ in box.append(buffer) }
        isRunning = true
        startTask()
    }

    func stop() {
        pendingStart = nil
        isStarting = false
        isRunning = false
        isOnDevice = false
        generation += 1
        if let sinkID { sink?.remove(sinkID) }
        sinkID = nil
        box.set(nil)
        task?.cancel()
        task = nil
    }

    func clear() {
        finalized = ""
        text = ""
        if isRunning { startTask() }
    }

    static func onDeviceRequest(supported: Bool) -> SFSpeechAudioBufferRecognitionRequest? {
        guard supported else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        guard let request = Self.onDeviceRequest(supported: recognizer.supportsOnDeviceRecognition) else {
            stop()
            error = "On-device speech recognition is unavailable. No audio will be sent to a server."
            return
        }
        generation += 1

        isOnDevice = true
        box.set(request)

        task?.cancel()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self, generation: generation))
    }

    private func handle(generation: Int, partial: String?, isFinal: Bool, failed: Bool) {
        guard generation == self.generation, isRunning else { return }
        if let partial {
            text = finalized + partial
        }
        if isFinal || failed {
            if let partial, !partial.isEmpty { finalized += partial + " " }
            text = finalized
            // Recognition tasks end on silence/timeout; keep listening with a fresh one.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(failed ? 500 : 50))
                guard let self, self.generation == generation else { return }
                self.startTask()
            }
        }
    }

    nonisolated private static func resultHandler(owner: MicTranscriber, generation: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void
    {
        { [weak owner] result, error in
            let partial = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                owner?.handle(generation: generation, partial: partial, isFinal: isFinal, failed: failed)
            }
        }
    }
}

/// The current recognition request, appended to from the audio thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}
