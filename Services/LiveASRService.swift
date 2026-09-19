import Foundation

/// 音频转录 + 翻译，一步到位。
///
/// 设计说明（为什么不用 Apple Speech）：
/// Apple 的 `SFSpeechRecognizer` 是为「录制一段话转文字」设计的：它有每日配额、
/// 识别任务生命周期很短（约 60 秒），且对连续直播流的支持极差。直播场景下
/// 每次重启都会丢失上下文。这里改为把音频切片直接发给 OpenAI 的转录接口，
/// 在 prompt 中要求「转录并翻译」，一次网络往返同时得到原文和译文。
enum LiveASRError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case invalidResponse
    case remoteStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写 OpenAI API Key"
        case .emptyAudio:
            return "没有采集到音频数据"
        case .invalidResponse:
            return "语音服务返回了无法识别的结果"
        case .remoteStatus(let status, let message):
            return message.isEmpty
                ? "语音服务请求失败（HTTP \(status)）"
                : "语音服务请求失败：\(message)"
        }
    }
}

/// 一次转录请求的结果。
struct LiveASRResult: Sendable {
    /// 原文（模型识别出的语言）。
    let transcript: String
    /// 目标语言译文；当目标语言与源语言一致时与 transcript 相同。
    let translation: String
}

final class LiveASRService: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    /// - Parameters:
    ///   - apiKey: OpenAI API Key。
    ///   - model: 转录模型，默认 `whisper-1`（最稳定、最便宜，且支持 prompt 引导翻译）。
    ///   - endpoint: 允许自建/兼容 OpenAI 的第三方服务覆盖。
    init(
        apiKey: String,
        model: String = "whisper-1",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.endpoint = endpoint

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    /// 把一段 WAV 音频转成「原文 + 目标语言译文」。
    ///
    /// - Parameters:
    ///   - wavData: 16-bit PCM 单声道 WAV 数据。
    ///   - sourceLanguage: 源语言提示（ISO-639-1，如 `en`）；传 nil 让服务自动检测。
    ///   - targetLanguageName: 目标语言的**自然语言名称**（如「简体中文」），用于 prompt。
    ///   - context: 上一段译文，作为上下文提升连贯性（Whisper 的 prompt 机制）。
    func transcribe(
        wavData: Data,
        sourceLanguage: String?,
        targetLanguageName: String,
        context: String?
    ) async throws -> LiveASRResult {
        guard !apiKey.isEmpty else { throw LiveASRError.missingAPIKey }
        guard !wavData.isEmpty else { throw LiveASRError.emptyAudio }

        let boundary = "FlowBoxBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeBody(
            boundary: boundary,
            wavData: wavData,
            sourceLanguage: sourceLanguage,
            prompt: makePrompt(targetLanguageName: targetLanguageName, context: context)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveASRError.invalidResponse
        }
        guard http.statusCode < 400 else {
            let message = Self.extractErrorMessage(from: data)
            throw LiveASRError.remoteStatus(http.statusCode, message)
        }

        guard let text = Self.extractText(from: data) else {
            throw LiveASRError.invalidResponse
        }
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else {
            // 静音片段、纯音乐段落会返回空串，这是正常情况，不算错误。
            return LiveASRResult(transcript: "", translation: "")
        }

        let parsed = Self.splitTranscriptAndTranslation(cleaned)
        return LiveASRResult(transcript: parsed.transcript, translation: parsed.translation)
    }

    // MARK: - Prompt

    /// Whisper 的 `prompt` 会作为「上一段文本」喂给模型，既能引导输出语言，
    /// 也能让译文与上下文保持连贯。这里用它同时承担翻译指令和上下文两个职责。
    private func makePrompt(targetLanguageName: String, context: String?) -> String {
        var lines: [String] = [
            "Task: transcribe the audio, then output only the \(targetLanguageName) translation.",
            "Format: a single line of \(targetLanguageName) subtitle text. No speaker labels, no quotes, no explanations, no original text."
        ]
        if let context, !context.isEmpty {
            lines.append("Previous subtitle for context: \(context)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Multipart

    private func makeBody(
        boundary: String,
        wavData: Data,
        sourceLanguage: String?,
        prompt: String
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func addField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        // 文件字段：必须带扩展名和 MIME，接口依赖它判断容器格式。
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        addField("model", model)
        addField("response_format", "json")
        addField("temperature", "0")
        if let sourceLanguage, !sourceLanguage.isEmpty {
            // 只取 ISO-639-1 主语言码：en-US -> en
            let code = sourceLanguage.split(separator: "-").first.map(String.init) ?? sourceLanguage
            addField("language", code)
        }
        if !prompt.isEmpty {
            addField("prompt", prompt)
        }

        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - 响应解析

    private static func extractText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = object["text"] as? String { return text }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return ""
    }

    /// Whisper 偶尔会加引号、加「字幕：」前缀或换行，统一清理。
    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["字幕：", "字幕:", "译文：", "译文:", "Subtitle:", "Translation:"]
        for prefix in prefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」"))
        // 压掉换行，字幕保持单行
        value = value.replacingOccurrences(of: "\n", with: " ")
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 模型有时仍会同时输出原文和译文。这里尽力拆分，拆不开就整段当译文。
    private static func splitTranscriptAndTranslation(_ text: String) -> (transcript: String, translation: String) {
        let separators = [" => ", " -> ", " ｜ ", " | "]
        for separator in separators {
            let parts = text.components(separatedBy: separator)
            if parts.count >= 2 {
                let transcript = parts.dropLast().joined(separator: separator)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let translation = parts.last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !translation.isEmpty {
                    return (transcript, translation)
                }
            }
        }
        return (text, text)
    }
}
