import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var sources: [MediaSource] = []
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let itemsKey = "flowbox.items"
    private let sourcesKey = "flowbox.sources"

    init() {
        load()
    }

    var history: [MediaItem] {
        items.filter { $0.progress > 0 && $0.progress < 1 }.sorted { $0.progress > $1.progress }
    }

    var favorites: [MediaItem] {
        items.filter(\.isFavorite)
    }

    func addSource(name: String, urlString: String, format: SourceFormat) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "http" || url.scheme == "https" else {
            lastError = "请输入有效的 http 或 https 地址"
            return
        }
        let sourceName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? "新源") : name
        sources.insert(MediaSource(name: sourceName, urlString: trimmedURL, format: format), at: 0)
        lastError = nil
        persist()
    }

    func removeSource(_ source: MediaSource) {
        sources.removeAll { $0.id == source.id }
        items.removeAll { $0.sourceID == source.id }
        persist()
    }

    func toggleFavorite(_ item: MediaItem) {
        update(item) { $0.isFavorite.toggle() }
    }

    func markPlayed(_ item: MediaItem, progress: Double = 0.08) {
        update(item) { $0.progress = min(max(progress, 0.01), 0.99) }
    }

    func refresh(_ source: MediaSource) async {
        guard !isRefreshing else { return }
        guard let url = source.url else {
            lastError = "源地址无效"
            return
        }
        isRefreshing = true
        RuntimeDiagnostics.record("source.refresh.begin")
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("FlowBox/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            RuntimeDiagnostics.record("source.download status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count)")
            guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else {
                throw URLError(.badServerResponse)
            }
            let parsed: [MediaItem]
            if source.format == .tvbox
                || ["md5", "js"].contains(url.pathExtension.lowercased())
                || TVBoxService.isLikelyConfiguration(data) {
                parsed = try await TVBoxService.load(data: data, sourceURL: url, sourceID: source.id)
            } else {
                parsed = try SourceParser.parse(data: data, source: source)
            }

            // 归属兜底：任何解析路径漏设 sourceID 都会让下面的 removeAll 失效，
            // 导致旧条目反复堆积、persist() 体积失控而崩溃。这里强制回填。
            let normalized = parsed.map { item -> MediaItem in
                var copy = item
                if copy.sourceID != source.id { copy.sourceID = source.id }
                return copy
            }
            let unique = Self.deduplicated(normalized)

            // 只保留本次刷新结果，避免历史条目无限累积。
            items.removeAll { $0.sourceID == source.id }
            items.append(contentsOf: unique)

            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastUpdated = Date()
            }
            lastError = nil
            persist()
            RuntimeDiagnostics.record("source.refresh.success items=\(unique.count)")
        } catch {
            let nsError = error as NSError
            RuntimeDiagnostics.record("source.refresh.failed domain=\(nsError.domain) code=\(nsError.code)")
            lastError = error.localizedDescription
        }
    }

    /// 按标题 + 播放地址去重，防止同一源在多次刷新后重复堆积。
    private static func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            let key = item.title + "\u{1}" + (item.playbackURL ?? "")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func update(_ item: MediaItem, mutation: (inout MediaItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        mutation(&items[index])
        persist()
    }

    private func load() {
        let defaults = UserDefaults.standard
        // 旧版本可能写入了超量数据；解码失败时回退到演示数据，
        // 而不是让半损坏的 items 数组进入后续刷新流程。
        if let data = defaults.data(forKey: itemsKey),
           let saved = try? JSONDecoder().decode([MediaItem].self, from: data),
           saved.count <= Self.maxPersistedItems {
            items = saved
        } else {
            defaults.removeObject(forKey: itemsKey)
            items = DemoCatalog.items
        }
        if let data = defaults.data(forKey: sourcesKey), let saved = try? JSONDecoder().decode([MediaSource].self, from: data) {
            sources = saved
        } else {
            defaults.removeObject(forKey: sourcesKey)
            sources = []
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        // UserDefaults 不适合存放超大 JSON。限制条目总量，避免源刷新后
        // 数据体量失控导致写入/解码失败（表现为刷新时闪退）。
        let capped = Array(items.prefix(Self.maxPersistedItems))
        if capped.count != items.count {
            items = capped
        }
        if let itemData = try? encoder.encode(capped) { UserDefaults.standard.set(itemData, forKey: itemsKey) }
        if let sourceData = try? encoder.encode(sources) { UserDefaults.standard.set(sourceData, forKey: sourcesKey) }
    }

    private static let maxPersistedItems = 1500
}
