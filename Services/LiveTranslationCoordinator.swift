import Foundation

/// 直播字幕流水线：音频 tap → 分片 → 转录+翻译 → 字幕。
///
/// 相比旧实现的关键改动：
/// - 不再使用 Apple Speech。旧方案依赖 `SFSpeechRecognizer` 的短生命周期任务，
///   对无限长的直播流不适用（配额 + 上下文丢失）。
/// - 请求改为**串行队列**而不是「每次新结果就取消上一个」。旧实现里
///   每个 partial 结果都会 cancel 掉正在进行的翻译请求，导致请求永远跑不完。
/// - 分片固定时长，保证每次请求都能完整跑完并回到主线程更新字幕。
@MainActor
final class LiveTranslationCoordinator {
    private let asr: LiveASRService
    private let sourceLanguage: String
    private let targetLanguageName: String
    private let chunker: AudioChunker

    /// 串行执行转录请求，保证同一时刻只有一个在飞。
    private var isProcessing = false
    private var pendingChunks: [Data] = []
    private let maxPendingChunks = 3

    private var isRunning = false
    private var lastTranslation = ""
    private var contextLine = ""

    var onSubtitle: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?

    /// 是否已配置 API Key。UI 用它决定是否显示「请先填写 Key」。
    var hasAPIKey: Bool { asr.isConfigured }

    init(
        apiKey: String,
        sourceLanguage: String,
        targetLanguageName: String,
        chunkSeconds: Double = 5.0,
        model: String = "whisper-1",
        endpoint: URL? = nil
    ) {
        self.asr = LiveASRService(
            apiKey: apiKey,
            model: model,
            endpoint: endpoint ?? URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        )
        self.sourceLanguage = sourceLanguage
        self.targetLanguageName = targetLanguageName
        self.chunker = AudioChunker(chunkSeconds: chunkSeconds)

        chunker.onChunk = { [weak self] wav in
            Task { @MainActor [weak self] in
                self?.enqueue(wav)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard asr.isConfigured else {
            publishStatus("请先在设置中填写 OpenAI API Key")
            return
        }
        isRunning = true
        publishStatus("正在等待直播声音…")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        chunker.flush()
        chunker.reset()
        pendingChunks.removeAll()
        publishStatus(nil)
    }

    /// 接收音频 tap 的 PCM（单声道 Float32）。
    func appendPCM(_ samples: [Float], sampleRate: Double) {
        guard isRunning else { return }
        chunker.append(samples, sourceSampleRate: sampleRate)
    }

    // MARK: - 请求队列

    private func enqueue(_ wav: Data) {
        guard isRunning else { return }

        // 积压保护：网络跟不上时丢弃最旧的切片，保证字幕接近实时，
        // 而不是越拖越久。这里刻意丢旧而不是丢新。
        if pendingChunks.count >= maxPendingChunks {
            pendingChunks.removeFirst()
        }
        pendingChunks.append(wav)
        drainIfNeeded()
    }

    private func drainIfNeeded() {
        guard isRunning, !isProcessing, !pendingChunks.isEmpty else { return }
        let wav = pendingChunks.removeFirst()
        isProcessing = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing() }

            do {
                let result = try await self.asr.transcribe(
                    wavData: wav,
                    sourceLanguage: self.sourceLanguage,
                    targetLanguageName: self.targetLanguageName,
                    context: self.contextLine
                )

                guard self.isRunning else { return }
                let subtitle = result.translation.isEmpty ? result.transcript : result.translation
                guard !subtitle.isEmpty else {
                    self.publishStatus("正在监听…")
                    return
                }
                guard subtitle != self.lastTranslation else { return }

                self.lastTranslation = subtitle
                self.contextLine = String(subtitle.suffix(120))
                self.onSubtitle?(subtitle)
                self.publishStatus(nil)
            } catch {
                guard self.isRunning else { return }
                self.publishStatus(error.localizedDescription)
            }
        }
    }

    private func finishProcessing() {
        isProcessing = false
        drainIfNeeded()
    }

    private func publishStatus(_ status: String?) {
        onStatus?(status)
    }
}
