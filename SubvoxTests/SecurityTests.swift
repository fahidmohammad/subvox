import AVFoundation
import Darwin
import XCTest
@testable import Subvox

final class SecurityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try PrivateStorage.createDirectory(at: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private static func pcm(frames: AVAudioFrameCount = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.1 }
        return buffer
    }

    func testPrivateAtomicWritesAndDatasetRoundTrip() throws {
        let previous = umask(0)
        defer { umask(previous) }
        let root = try temporaryDirectory()
        let file = root.appending(path: "dataset.json")
        let dataset = Dataset(vocabulary: ["yes", "no"], templates: [])
        TemplateStore.save(dataset, to: file)
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        let loaded = TemplateStore.load(from: file)
        XCTAssertEqual(loaded.vocabulary, dataset.vocabulary)
        XCTAssertEqual(try permissions(file), 0o600)
        TemplateStore.save(.starter, to: file)
        XCTAssertEqual(TemplateStore.load(from: file).vocabulary, Dataset.starter.vocabulary)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["dataset.json"])
    }

    func testSymlinkEndpointsAreRejectedWithoutChangingTheirTargets() throws {
        let root = try temporaryDirectory()
        let target = root.appending(path: "target")
        let link = root.appending(path: "link")
        let original = Data("untouched".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateStorage.read(from: link))
        XCTAssertThrowsError(try PrivateStorage.write(Data("replacement".utf8), to: link))
        XCTAssertThrowsError(try PrivateStorage.createFile(at: link))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try permissions(target), 0o644)

        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        let folderLink = root.appending(path: "folder-link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        XCTAssertThrowsError(try PrivateStorage.createDirectory(at: folderLink))
        XCTAssertEqual(try permissions(folder), 0o755)
    }

    func testExclusiveFilesDoNotOverwriteExistingContent() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "events.csv")
        let handle = try PrivateStorage.createFile(at: file)
        try handle.write(contentsOf: Data("first".utf8))
        try handle.close()
        XCTAssertThrowsError(try PrivateStorage.createFile(at: file))
        XCTAssertEqual(try String(contentsOf: file), "first")
    }

    @MainActor func testSameTimestampSessionsKeepEarlierDataAndDoNotRetainAudio() async throws {
        let previous = umask(0)
        defer { umask(previous) }
        let root = try temporaryDirectory()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = SessionRecorder(root: root, now: { date })
        let sink = AudioSink()
        let segment = [MotionSample(t: 1), MotionSample(t: 2)]
        recorder.start(sink: sink, deviceName: "Synthetic input")
        XCTAssertTrue(recorder.isRecording)
        sink.dispatch(Self.pcm(), AVAudioTime(hostTime: mach_absolute_time()))
        recorder.logEvent(segment, kind: "train", label: "first", confidence: nil)
        recorder.stop()
        XCTAssertNil(recorder.error)
        let first = try XCTUnwrap(recorder.lastSessionURL)
        let firstEvents = try Data(contentsOf: first.appending(path: "events.csv"))
        let firstAudio = try Data(contentsOf: first.appending(path: "audio.caf"))
        XCTAssertEqual(try permissions(first), 0o700)
        for file in ["audio.caf", "motion.csv", "events.csv", "meta.json"] {
            XCTAssertEqual(try permissions(first.appending(path: file)), 0o600)
        }

        recorder.start(sink: nil, deviceName: nil)
        recorder.logEvent(segment, kind: "train", label: "second", confidence: nil)
        recorder.stop()
        let second = try XCTUnwrap(recorder.lastSessionURL)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "events.csv")), firstEvents)
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "audio.caf")), firstAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appending(path: "audio.caf").path))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: second.appending(path: "meta.json"))) as? [String: Any])
        XCTAssertTrue(meta["audioDevice"] is NSNull)
        XCTAssertTrue(meta["audioSampleRate"] is NSNull)
        XCTAssertEqual(recorder.startedAt, date)
    }

    @MainActor func testStoppedWriterCannotReopenOrChangeAudio() async throws {
        let root = try temporaryDirectory()
        let url = root.appending(path: "audio.caf")
        let writer = AudioFileWriter(url: url)
        writer.write(Self.pcm(), AVAudioTime(hostTime: mach_absolute_time()))
        let info = writer.finish()
        XCTAssertEqual(info?.sampleRate, 48000)
        let original = try Data(contentsOf: url)
        writer.write(Self.pcm(frames: 16), AVAudioTime(hostTime: mach_absolute_time()))
        _ = writer.finish()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 480)

        let emptyURL = root.appending(path: "never-started.caf")
        let empty = AudioFileWriter(url: emptyURL)
        XCTAssertNil(empty.finish())
        empty.write(Self.pcm(), AVAudioTime(hostTime: mach_absolute_time()))
        _ = empty.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))
    }

    @MainActor func testCSVTextPreservesCommasAndQuotesWithoutCreatingRecordsOrFormulas() async throws {
        XCTAssertEqual(SessionRecorder.csvText("a,b\"c"), "\"a,b\"\"c\"")
        XCTAssertEqual(SessionRecorder.csvText("a\r\nb\u{2028}c"), "\"a  b c\"")
        for value in ["=1+1", "+1", "-1", "@SUM(A1)", "  =1", "\t=1", "＝1", "＋1", "－1", "＠A1"] {
            XCTAssertTrue(SessionRecorder.csvText(value).hasPrefix("\"\t"))
        }
        let root = try temporaryDirectory()
        let recorder = SessionRecorder(root: root)
        let prompt = "=1+1\nprivate prompt"
        recorder.prompt = prompt
        recorder.start(sink: nil, deviceName: nil)
        recorder.logEvent([MotionSample(t: 1), MotionSample(t: 2)], kind: "train", label: prompt, confidence: nil)
        recorder.stop()
        let session = try XCTUnwrap(recorder.lastSessionURL)
        let csv = try String(contentsOf: session.appending(path: "events.csv"))
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
        XCTAssertTrue(csv.contains("\"\t=1+1 private prompt\""))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.appending(path: "meta.json"))) as? [String: Any])
        XCTAssertEqual(meta["prompt"] as? String, prompt)
    }

    @MainActor func testInFlightSinkCallbackCannotWriteAfterFinish() async throws {
        let root = try temporaryDirectory()
        let url = root.appending(path: "audio.caf")
        let writer = AudioFileWriter(url: url)
        let time = AVAudioTime(hostTime: mach_absolute_time())
        writer.write(Self.pcm(), time)
        let sink = AudioSink()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let id = sink.add { buffer, time in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            writer.write(buffer, time)
        }
        DispatchQueue.global().async {
            sink.dispatch(Self.pcm(frames: 16), time)
            completed.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        sink.remove(id)
        _ = writer.finish()
        let original = try Data(contentsOf: url)
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        _ = writer.finish()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 480)
    }

    @MainActor func testSessionDeletionRequiresACompletedSession() async throws {
        let root = try temporaryDirectory()
        let recorder = SessionRecorder(root: root)
        recorder.start(sink: nil, deviceName: nil)
        recorder.stop()
        let first = try XCTUnwrap(recorder.lastSessionURL)
        recorder.start(sink: nil, deviceName: nil)
        recorder.deleteLastSession()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNotNil(recorder.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        recorder.stop()
        let second = try XCTUnwrap(recorder.lastSessionURL)
        recorder.deleteLastSession()
        XCTAssertNil(recorder.lastSessionURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor func testRecordingStartupAndMetadataErrorsAreVisible() async throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "not-a-directory")
        try Data().write(to: file)
        let invalid = SessionRecorder(root: file)
        invalid.start(sink: nil, deviceName: nil)
        XCTAssertFalse(invalid.isRecording)
        XCTAssertNotNil(invalid.error)
        let recorder = SessionRecorder(root: root.appending(path: "sessions"))
        recorder.start(sink: nil, deviceName: nil)
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appending(path: "sessions"), includingPropertiesForKeys: nil).first)
        try FileManager.default.createDirectory(at: session.appending(path: "meta.json"), withIntermediateDirectories: false)
        recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNotNil(recorder.error)
    }

    @MainActor func testSpeechRequestsRequireLocalSupport() async throws {
        XCTAssertNil(MicTranscriber.onDeviceRequest(supported: false))
        let request = try XCTUnwrap(MicTranscriber.onDeviceRequest(supported: true))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
    }

    @MainActor func testStopInvalidatesPendingMicrophoneAuthorization() async throws {
        var authorization: CheckedContinuation<Bool, Never>?
        var requests = 0
        let audio = AudioService(requestAccess: {
            requests += 1
            return await withCheckedContinuation { authorization = $0 }
        })
        let start = Task { await audio.start() }
        while authorization == nil { await Task.yield() }
        XCTAssertTrue(audio.isStarting)
        await audio.start()
        XCTAssertEqual(requests, 1)
        audio.stop()
        authorization?.resume(returning: true)
        await start.value
        XCTAssertFalse(audio.isRunning)
        XCTAssertFalse(audio.isStarting)
        XCTAssertNil(audio.activeDeviceName)
    }
}
