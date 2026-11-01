import AVFoundation
import Observation

/// Records synchronized motion CSV + microphone audio + labelled segment events for offline
/// analysis (normal speech vs. whisper vs. silent mouthing).
///
/// Output: ~/Library/Application Support/Subvox/Sessions/<timestamp>-<condition>-<id>/
///   motion.csv  — every headphone-motion sample, t relative to session start
///   audio.caf   — microphone audio (if the mic is running)
///   events.csv  — captured segments with their label / prediction
///   meta.json   — condition, prompt, clock offsets
@MainActor @Observable
final class SessionRecorder {
    enum Condition: String, CaseIterable, Identifiable, Codable {
        case normal = "Normal speech"
        case whisper = "Whisper"
        case silent = "Silent mouthing"
        var id: String { rawValue }
        var slug: String {
            switch self {
            case .normal: "normal"
            case .whisper: "whisper"
            case .silent: "silent"
            }
        }
    }

    var condition: Condition = .silent
    var prompt = ""
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var motionCount = 0
    private(set) var eventCount = 0
    private(set) var lastSessionURL: URL?
    private(set) var error: String?

    static var root: URL {
        PrivateStorage.root.appending(path: "Sessions", directoryHint: .isDirectory)
    }

    @ObservationIgnored private let outputRoot: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var startUptime: TimeInterval = 0
    @ObservationIgnored private var motionHandle: FileHandle?
    @ObservationIgnored private var eventsHandle: FileHandle?
    @ObservationIgnored private var audioWriter: AudioFileWriter?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private weak var sink: AudioSink?
    @ObservationIgnored private var audioDeviceName: String?

    init(root: URL? = nil, now: @escaping () -> Date = Date.init) {
        outputRoot = root ?? Self.root
        self.now = now
    }

    func start(audio: AudioService) {
        start(sink: audio.isRunning ? audio.sink : nil, deviceName: audio.activeDeviceName)
    }

    func start(sink: AudioSink?, deviceName: String?) {
        guard !isRecording else { return }
        error = nil
        audioDeviceName = nil
        let date = now()
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let dir = outputRoot.appending(path: "\(stamp)-\(condition.slug)-\(UUID().uuidString)", directoryHint: .isDirectory)
        var created = false
        do {
            if outputRoot == Self.root { try PrivateStorage.createDirectory(at: PrivateStorage.root) }
            try PrivateStorage.createDirectory(at: outputRoot)
            try PrivateStorage.createDirectory(at: dir, exclusive: true)
            created = true
            motionHandle = try Self.makeFile(dir.appending(path: "motion.csv"), header: MotionSample.csvHeader)
            eventsHandle = try Self.makeFile(dir.appending(path: "events.csv"), header: "start,end,kind,label,confidence")
        } catch {
            try? motionHandle?.close()
            try? eventsHandle?.close()
            motionHandle = nil
            eventsHandle = nil
            if created { try? FileManager.default.removeItem(at: dir) }
            self.error = error.localizedDescription
            return
        }

        directory = dir
        startUptime = ProcessInfo.processInfo.systemUptime
        startedAt = date
        motionCount = 0
        eventCount = 0
        if let sink {
            let writer = AudioFileWriter(url: dir.appending(path: "audio.caf"))
            audioWriter = writer
            self.sink = sink
            sinkID = sink.add { buffer, time in writer.write(buffer, time) }
            audioDeviceName = deviceName
        }
        isRecording = true
    }

    func stop() {
        guard isRecording, let directory else { return }
        isRecording = false
        if let sinkID { sink?.remove(sinkID) }
        sinkID = nil
        let audioInfo = audioWriter?.finish()
        if let failure = audioWriter?.error { error = error ?? failure }
        audioWriter = nil
        sink = nil
        do {
            try motionHandle?.close()
            try eventsHandle?.close()
        } catch {
            self.error = self.error ?? error.localizedDescription
        }
        motionHandle = nil
        eventsHandle = nil

        let meta: [String: Any] = [
            "condition": condition.rawValue,
            "prompt": prompt,
            "startedAt": startedAt?.ISO8601Format() ?? "",
            "startUptime": startUptime,
            "durationSeconds": ProcessInfo.processInfo.systemUptime - startUptime,
            "motionSamples": motionCount,
            "events": eventCount,
            "audioDevice": audioDeviceName ?? NSNull(),
            "audioSampleRate": audioInfo?.sampleRate ?? NSNull(),
            "audioStartOffsetSeconds": audioInfo?.firstHostSeconds.map { $0 - startUptime } ?? NSNull(),
            "note": "Motion t and audioStartOffsetSeconds are relative to startUptime (seconds since boot).",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try PrivateStorage.write(data, to: directory.appending(path: "meta.json"))
        } catch {
            self.error = self.error ?? error.localizedDescription
        }
        lastSessionURL = directory
        self.directory = nil
    }

    func record(_ sample: MotionSample) {
        guard isRecording else { return }
        do {
            try motionHandle?.write(contentsOf: Data((sample.csvRow(relativeTo: startUptime) + "\n").utf8))
            motionCount += 1
            if let failure = audioWriter?.error {
                error = failure
                stop()
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func logEvent(_ segment: [MotionSample], kind: String, label: String, confidence: Double?) {
        guard isRecording, let first = segment.first, let last = segment.last else { return }
        let row = [
            String(format: "%.4f", first.t - startUptime),
            String(format: "%.4f", last.t - startUptime),
            Self.csvText(kind),
            Self.csvText(label),
            confidence.map { String(format: "%.3f", $0) } ?? "",
        ].joined(separator: ",")
        do {
            try eventsHandle?.write(contentsOf: Data((row + "\n").utf8))
            eventCount += 1
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func deleteLastSession() {
        guard !isRecording else {
            error = "Stop recording before deleting a session."
            return
        }
        guard let lastSessionURL else { return }
        do {
            try FileManager.default.removeItem(at: lastSessionURL)
            self.lastSessionURL = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Text-only, single-record CSV cells for spreadsheet analysis. JSON keeps the original prompt.
    static func csvText(_ text: String) -> String {
        var value = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        if let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first,
           "=+-@＝＋－＠".contains(first) {
            value = "\t" + value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func makeFile(_ url: URL, header: String) throws -> FileHandle {
        let handle = try PrivateStorage.createFile(at: url)
        do {
            try handle.write(contentsOf: Data((header + "\n").utf8))
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }
}

/// Writes tap buffers to disk from the audio thread.
final class AudioFileWriter: @unchecked Sendable {
    struct Info {
        var sampleRate: Double
        var firstHostSeconds: Double?
    }

    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var info: Info?
    private var closed = false
    private var failure: String?

    var error: String? { lock.withLock { failure } }

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        lock.withLock {
            guard !closed, failure == nil else { return }
            if file == nil {
                do {
                    let handle = try PrivateStorage.createFile(at: url)
                    try handle.close()
                    let format = buffer.format
                    file = try AVAudioFile(
                        forWriting: url, settings: format.settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                    info = Info(
                        sampleRate: format.sampleRate,
                        firstHostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
                } catch {
                    failure = error.localizedDescription
                    return
                }
            }
            do {
                try file?.write(from: buffer)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func finish() -> Info? {
        lock.withLock {
            closed = true
            file = nil
            return info
        }
    }
}
