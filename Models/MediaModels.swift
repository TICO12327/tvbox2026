import Foundation

enum MediaKind: String, Codable, CaseIterable {
    case movie
    case series
    case live
    case audio
}

struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String
    var category: String
    var artworkURL: String?
    var playbackURL: String?
    var sourceID: UUID?
    var kind: MediaKind
    var isLive: Bool = false
    var progress: Double = 0
    var isFavorite: Bool = false

    var hasPlayableURL: Bool {
        guard let playbackURL, let url = URL(string: playbackURL) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}

struct MediaSource: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var format: SourceFormat
    var enabled: Bool = true
    var lastUpdated: Date?

    var url: URL? {
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }
}

enum SourceFormat: String, Codable, CaseIterable {
    case auto
    case m3u
    case json
    case txt
    case tvbox

    var label: String {
        switch self {
        case .auto: return "自动识别"
        case .m3u: return "M3U / M3U8"
        case .json: return "JSON"
        case .txt: return "TXT"
        case .tvbox: return "TVBox / PeekPro"
        }
    }
}

enum DemoCatalog {
    static let items: [MediaItem] = [
        MediaItem(
            title: "欢迎使用流映",
            subtitle: "移动端媒体源管理器",
            category: "入门",
            artworkURL: nil,
            playbackURL: nil,
            sourceID: nil,
            kind: .movie
        ),
        MediaItem(
            title: "添加你自己的内容源",
            subtitle: "支持 M3U、TXT、JSON 和 TVBox 配置",
            category: "入门",
            artworkURL: nil,
            playbackURL: nil,
            sourceID: nil,
            kind: .series
        ),
        MediaItem(
            title: "隐私优先的播放体验",
            subtitle: "配置只保存在本机",
            category: "特色",
            artworkURL: nil,
            playbackURL: nil,
            sourceID: nil,
            kind: .audio
        )
    ]
}
