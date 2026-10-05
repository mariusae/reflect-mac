import AVFoundation
import Speech

/// Words spoken, written down: the microphone heard while held, by Apple's
/// own speech recognition — on the device when it can be — what was said
/// so far told as it comes, and all of it when let go.
@MainActor
final class Dictation {
    enum Failure: Error {
        case notAllowed
        case unavailable
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    /// What has been heard so far.
    private(set) var text = ""
    private var finished: CheckedContinuation<Void, Never>?
    private var isFinal = false

    /// Asks, once, to hear and to recognise speech.
    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Listening, from now: `heard` told what has been said so far.
    func start(heard: @escaping @MainActor (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unavailable
        }
        self.recognizer = recognizer
        text = ""
        isFinal = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let said = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let said {
                    self.text = said
                    heard(said)
                }
                if final { self.end() }
            }
        }
    }

    /// Let go: what was said, once the last of it is recognised — waited
    /// for a moment at most.
    func stop() async -> String {
        guard request != nil else { return text }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if !isFinal {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finished = done
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.end() }
            }
        }
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func end() {
        isFinal = true
        finished?.resume()
        finished = nil
    }
}
