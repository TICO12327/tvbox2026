import Foundation

enum SourceParserError: LocalizedError {
    case unsupportedFormat
    case emptySource
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "无法识别这个源的格式"
        case .emptySource: return "源中没有找到可播放项目"
        case .invalidURL: return "只支持 http 或 https 地址"
        }
    }
}

struct SourceParser {
    private struct Entry {
        var title: String
        var subtitle: String
        var category: String
        var artworkURL: String?
        var playbackURL: String
        var kind: MediaKind
    }

    static func parse(data: Data, source: MediaSource) throws -> [MediaItem] {
        guard source.url != nil else { throw SourceParserError.invalidURL }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let format = detectedFormat(text: text, source: source)
        let entries: [Entry]

        switch format {
        case .m3u:
            entries = parseM3U(text)
        case .txt:
            entries = parseTXT(text)
        case .json:
            entries = parseJSON(data)
        case .auto:
            entries = []
        }

        guard !entries.isEmpty else { throw SourceParserError.emptySource }
        return entries.compactMap { entry in
            guard let url = URL(string: entry.playbackURL),
                  url.scheme == "http" || url.scheme == "https" else { return nil }
            return MediaItem(
                title: entry.title,
                subtitle: entry.subtitle,
                category: entry.category,
                artworkURL: entry.artworkURL,
                playbackURL: entry.playbackURL,
                sourceID: source.id,
                kind: entry.kind,
                isLive: entry.kind == .live
            )
        }
    }

    private static func detectedFormat(text: String, source: MediaSource) -> SourceFormat {
        if source.format != .auto { return source.format }
        let lower = text.lowercased()
        if lower.contains("#extm3u") || lower.contains("#extinf") { return .m3u }
        if let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first {
            if first == "{" || first == "[" { return .json }
        }
        if source.url?.pathExtension.lowercased() == "json" { return .json }
        if source.url?.pathExtension.lowercased() == "m3u" || source.url?.pathExtension.lowercased() == "m3u8" {
            return .m3u
        }
        return .txt
    }

    private static func parseM3U(_ text: String) -> [Entry] {
        var result: [Entry] = []
        var metadata: (title: String, category: String, logo: String?)?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                let title = line.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "未命名频道"
                let category = attribute("group-title", in: line) ?? "直播"
                let logo = attribute("tvg-logo", in: line)
                metadata = (title.trimmingCharacters(in: .whitespaces), category, logo)
            } else if !line.hasPrefix("#"), let current = metadata {
                result.append(Entry(
                    title: current.title,
                    subtitle: "来自 M3U 源",
                    category: current.category,
                    artworkURL: current.logo,
                    playbackURL: line,
                    kind: .live
                ))
                metadata = nil
            }
        }
        return result
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func parseTXT(_ text: String) -> [Entry] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: ",", maxSplits: 2).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, let url = URL(string: fields[2]), url.scheme != nil else { return nil }
            return Entry(title: fields[1], subtitle: fields[0], category: fields[0], artworkURL: nil, playbackURL: fields[2], kind: .live)
        }
    }

    private static func parseJSON(_ data: Data) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var dictionaries: [[String: Any]] = []
        collectDictionaries(object, into: &dictionaries)
        return dictionaries.compactMap { dictionary in
            let url = firstString(in: dictionary, keys: ["url", "playUrl", "play_url", "streamUrl", "stream_url", "address"])
            let title = firstString(in: dictionary, keys: ["title", "name", "vod_name", "channelName"]) ?? "未命名项目"
            guard let url, URL(string: url)?.scheme != nil else { return nil }
            let category = firstString(in: dictionary, keys: ["category", "group", "group-title", "type"]) ?? "默认"
            let logo = firstString(in: dictionary, keys: ["logo", "icon", "cover", "pic", "poster"])
            let kind: MediaKind = dictionary["live"] as? Bool == true ? .live : .movie
            return Entry(title: title, subtitle: category, category: category, artworkURL: logo, playbackURL: url, kind: kind)
        }
    }

    private static func collectDictionaries(_ object: Any, into result: inout [[String: Any]]) {
        if let dictionary = object as? [String: Any] {
            let hasMediaFields = dictionary.keys.contains { key in
                ["url", "playUrl", "play_url", "streamUrl", "stream_url", "address"].contains(key)
            }
            if hasMediaFields { result.append(dictionary) }
            for value in dictionary.values { collectDictionaries(value, into: &result) }
        } else if let array = object as? [Any] {
            for value in array { collectDictionaries(value, into: &result) }
        }
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
