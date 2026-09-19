import AVFoundation
import Speech

@MainActor
final class LiveTranslationCoordinator {
    private let sourceLanguage: String
    private let translator: DeepSeekTranslator

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var translationTask: Task<Void, Never>?
    private var isRunning = false
    private var receivedSeconds = 0.0
    private var lastScheduledText = ""

    var onSubtitle: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?

    init(sourceLanguage: String, apiKey: String) {
        self.sourceLanguage = sourceLanguage
        self.translator = DeepSeekTranslator(apiKey: apiKey)
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: sourceLanguage))
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        guard translator.isConfigured else {
            isRunning = false
            publishStatus("请先在设置中填写 DeepSeek API Key")
            return
        }

        let authorization = await requestAuthorization()
        guard authorization == .authorized else {
            isRunning = false
            publishStatus(authorization == .denied ? "请在系统设置允许语音识别" : "语音识别权限不可用")
            return
        }
        guard let recognizer else {
            isRunning = false
            publishStatus("当前语言不支持语音识别")
            return
        }
        guard recognizer.isAvailable else {
            isRunning = false
            publishStatus("语音识别服务暂不可用")
            return
        }

        startRecognitionRequest()
    }

    func appendPCM(_ data: Data, sampleRate: Double) {
        guard isRunning, !data.isEmpty else { return }
        guard let request = recognitionRequest else { return }

        let bytesPerSample = MemoryLayout<Float>.size
        let frameCount = data.count / bytesPerSample
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channelData = buffer.floatChannelData?.pointee else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(channelData, baseAddress, data.count)
        }
        request.append(buffer)

        receivedSeconds += Double(frameCount) / sampleRate
        // Apple Speech recognition sessions are short-lived. Restarting at a
        // boundary keeps live streams working instead of waiting for a 60s task
        // to fail with an opaque service error.
        if receivedSeconds >= 45 {
            startRecognitionRequest()
        }
    }

    func stop() {
        isRunning = false
        translationTask?.cancel()
        translationTask = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        receivedSeconds = 0
        lastScheduledText = ""
        publishStatus(nil)
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func startRecognitionRequest() {
        guard isRunning, let recognizer, recognizer.isAvailable else { return }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        receivedSeconds = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = false
        }
        recognitionRequest = request
        publishStatus("正在识别直播声音…")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.handleRecognition(result)
                }
                if let error, self.isRunning {
                    self.publishStatus("语音识别暂时中断，正在重连…")
                    if self.recognitionTask?.state == .completed || self.recognitionTask?.state == .finishing {
                        self.startRecognitionRequest()
                    }
                    _ = error
                }
            }
        }
    }

    private func handleRecognition(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        scheduleTranslation(for: text)
    }

    private func scheduleTranslation(for text: String) {
        guard text != lastScheduledText else { return }
        lastScheduledText = text
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                let translated = try await self.translator.translate(text)
                guard !Task.isCancelled else { return }
                self.onSubtitle?(translated)
                self.publishStatus("实时翻译已连接")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.publishStatus(error.localizedDescription)
            }
        }
    }

    private func publishStatus(_ status: String?) {
        onStatus?(status)
    }
}
