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
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("FlowBox/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
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
            items.removeAll { $0.sourceID == source.id }
            items.append(contentsOf: parsed)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastUpdated = Date()
            }
            lastError = nil
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func update(_ item: MediaItem, mutation: (inout MediaItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        mutation(&items[index])
        persist()
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: itemsKey), let saved = try? JSONDecoder().decode([MediaItem].self, from: data) {
            items = saved
        } else {
            items = DemoCatalog.items
        }
        if let data = defaults.data(forKey: sourcesKey), let saved = try? JSONDecoder().decode([MediaSource].self, from: data) {
            sources = saved
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let itemData = try? encoder.encode(items) { UserDefaults.standard.set(itemData, forKey: itemsKey) }
        if let sourceData = try? encoder.encode(sources) { UserDefaults.standard.set(sourceData, forKey: sourcesKey) }
    }
}
