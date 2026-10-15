import SwiftUI
import Speech
import AVFoundation
import ShikeCore

@MainActor final class VoiceRecorder: ObservableObject {
    @Published var text = ""
    @Published private(set) var recording = false
    @Published private(set) var preparing = false
    @Published private(set) var finishing = false
    @Published private(set) var error: String?
    @Published private(set) var onDevice = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var finishTask: Task<Void, Never>?
    private var attempt = UUID()
    private var hasTap = false
    private var audioSessionActive = false
    var busy: Bool { preparing || recording || finishing }

    func start() async {
        guard !busy else { return }
        let token = UUID(); attempt = token
        text = ""; preparing = true; error = nil
        defer { if attempt == token { preparing = false } }
        #if DEBUG
        if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-voice-fixture") {
            preparing = false; recording = true; onDevice = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard token == attempt else { return }; text = "明天下午三点开会"
                try await Task.sleep(for: .milliseconds(300))
                guard token == attempt else { return }; text = "明天下午三点开会，地点在三楼。"
            } catch { cancel() }
            return
        }
        #endif
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard token == attempt, !Task.isCancelled else { return }
        guard speech == .authorized else { error = "请在系统设置中允许拾刻计划使用语音识别。"; return }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard token == attempt, !Task.isCancelled else { return }
        guard microphone else { error = "请在系统设置中允许拾刻计划访问麦克风。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            error = "系统语音识别暂不可用，请稍后重试，或直接输入文字。"; return
        }
        do {
            #if !targetEnvironment(macCatalyst)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            audioSessionActive = true
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ShikeError.message("没有可用的麦克风，请检查音频设备。") }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            onDevice = recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = onDevice
            self.request = request
            text = ""
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let message = failure?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == token else { return }
                    if let transcript { self.text = transcript }
                    if isFinal || message != nil {
                        if let message, self.text.isEmpty { self.error = "语音识别未完成：" + message }
                        self.cancel()
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            engine.prepare(); try engine.start(); recording = true
        } catch { self.error = error.localizedDescription; cancel() }
    }
    func stop() {
        guard recording else { return }
        if recognition == nil { cancel(); return }
        stopMicrophone(); recording = false; finishing = true
        request?.endAudio(); recognition?.finish()
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.cancel()
        }
    }
    func cancel() {
        attempt = UUID(); finishTask?.cancel(); finishTask = nil
        stopMicrophone(); request?.endAudio(); recognition?.cancel()
        recognition = nil; request = nil; recording = false; preparing = false; finishing = false
    }
    private func stopMicrophone() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        #if !targetEnvironment(macCatalyst)
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
        #endif
    }
}
