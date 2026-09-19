import Foundation

/// A bounded, local stage log. Never pass source URLs, headers, or remote bodies here.
enum RuntimeDiagnostics {
    private static let queue = DispatchQueue(label: "com.tico.FlowBox.diagnostics")
    private static let limit = 32_768
    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FlowBox-diagnostics.txt")
    }

    static func record(_ event: String) {
        queue.sync {
            guard let url = fileURL else { return }
            let existing = (try? Data(contentsOf: url)) ?? Data()
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
            var data = Data(existing.suffix(limit / 2))
            data.append(Data(line.utf8))
            try? data.write(to: url, options: .atomic)
        }
    }

    static func snapshot() -> String {
        queue.sync {
            guard let url = fileURL,
                  let data = try? Data(contentsOf: url) else { return "暂无诊断日志" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
