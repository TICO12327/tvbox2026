import Foundation

enum DeepSeekTranslatorError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case remoteStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写 DeepSeek API Key"
        case .invalidResponse:
            return "DeepSeek 返回了无法识别的结果"
        case .remoteStatus(let status, let message):
            return message.isEmpty ? "DeepSeek 请求失败（HTTP \(status)）" : "DeepSeek 请求失败：\(message)"
        }
    }
}

final class DeepSeekTranslator {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    func translate(_ text: String) async throws -> String {
        guard !apiKey.isEmpty else { throw DeepSeekTranslatorError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RequestBody(
            model: "deepseek-chat",
            temperature: 0.1,
            maxTokens: 256,
            messages: [
                Message(
                    role: "system",
                    content: "你是直播字幕翻译器。把用户提供的语音识别原文翻译成自然、简洁的简体中文字幕。只返回译文，不要解释、不要加引号、不要添加说话人标签。专有名词尽量保持准确；如果原文已经是中文，原样返回。"
                ),
                Message(role: "user", content: text)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekTranslatorError.invalidResponse
        }
        guard httpResponse.statusCode < 400 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message ?? ""
            throw DeepSeekTranslatorError.remoteStatus(httpResponse.statusCode, message)
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekTranslatorError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension DeepSeekTranslator {
    struct RequestBody: Encodable {
        let model: String
        let temperature: Double
        let maxTokens: Int
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case temperature
            case maxTokens = "max_tokens"
            case messages
        }
    }

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct ResponseBody: Decodable {
        let choices: [Choice]
    }

    struct Choice: Decodable {
        let message: Message
    }

    struct ErrorResponse: Decodable {
        let error: ErrorMessage?
    }

    struct ErrorMessage: Decodable {
        let message: String?
    }
}
