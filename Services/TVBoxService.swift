import Foundation

#if canImport(CommonCrypto)
import CommonCrypto
#endif

struct TVBoxSite: Hashable, Identifiable {
    let key: String
    let name: String
    let type: Int
    let api: String?
    let jar: String?
    let searchable: Bool
    let quickSearch: Bool

    var id: String { key }

    var needsJavaScriptRuntime: Bool {
        if let jar, !jar.isEmpty { return true }
        guard let api, let url = URL(string: api) else { return true }
        return url.scheme == nil || type > 1
    }
}

struct TVBoxConfiguration {
    let sites: [TVBoxSite]
    let liveItems: [MediaItem]
}

enum TVBoxServiceError: LocalizedError {
    case invalidConfiguration
    case javascriptRuntimeRequired(detail: String)
    case noPlayableItems
    case remoteStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "这不是可识别的 TVBox / PeekPro 配置"
        case .javascriptRuntimeRequired(let detail):
            return "已识别为 TVBox JavaScript 源，但此版本还不能运行 NodeJS spider：\(detail)"
        case .noPlayableItems:
            return "TVBox 配置已读取，但没有返回可展示的内容"
        case .remoteStatus(let status):
            return "源服务器返回 HTTP \(status)"
        }
    }
}

enum TVBoxService {
    private static let siteNameKeys = ["name", "site", "title", "vod_name"]
    private static let titleKeys = ["vod_name", "name", "title", "channelName", "vod_title"]
    private static let artworkKeys = ["vod_pic", "pic", "poster", "cover", "logo", "icon"]
    private static let urlKeys = ["url", "playUrl", "play_url", "streamUrl", "stream_url", "address", "vod_play_url"]

    static func load(source: MediaSource) async throws -> [MediaItem] {
        guard let url = source.url else { throw SourceParserError.invalidURL }
        let (data, response) = try await fetch(url)
        guard response.statusCode < 400 else { throw TVBoxServiceError.remoteStatus(response.statusCode) }
        return try await load(data: data, sourceURL: url, sourceID: source.id)
    }

    static func load(data: Data, sourceURL: URL, sourceID: UUID) async throws -> [MediaItem] {
        let url = sourceURL

        let text = String(decoding: data, as: UTF8.self)
        if isMD5Document(text), url.pathExtension.lowercased() == "md5" {
            let scriptURL = siblingJavaScriptURL(for: url)
            let (scriptData, scriptResponse) = try await fetch(scriptURL)
            RuntimeDiagnostics.record("spider.download status=\(scriptResponse.statusCode) bytes=\(scriptData.count)")
            guard scriptResponse.statusCode < 400 else {
                throw TVBoxServiceError.remoteStatus(scriptResponse.statusCode)
            }
            let expected = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let actual = md5(scriptData)
            guard expected == actual else {
                RuntimeDiagnostics.record("spider.checksum.failed")
                throw TVBoxServiceError.javascriptRuntimeRequired(detail: "index.js 校验值不一致")
            }
            RuntimeDiagnostics.record("spider.checksum.verified")
            let baseURL = try await NodeRuntime.shared.start(scriptData: scriptData, cacheKey: actual)
            return try await loadNodeSpiderItems(baseURL: baseURL, sourceID: sourceID)
        }

        if url.pathExtension.lowercased() == "js" || looksLikeJavaScript(text) {
            let baseURL = try await NodeRuntime.shared.start(scriptData: data, cacheKey: md5(data))
            return try await loadNodeSpiderItems(baseURL: baseURL, sourceID: sourceID)
        }

        let configuration = try parseConfiguration(data: data, sourceID: sourceID)
        var items = configuration.liveItems
        let runtimeSites = configuration.sites.filter(\.needsJavaScriptRuntime)
        let directSites = configuration.sites.filter { !$0.needsJavaScriptRuntime && $0.api != nil }

        if !directSites.isEmpty {
            var siteResults = Array(repeating: [MediaItem](), count: directSites.count)
            try await withThrowingTaskGroup(of: (Int, [MediaItem]).self) { group in
                for (index, site) in directSites.enumerated() {
                    group.addTask {
                        (index, try await fetchSite(site, sourceURL: url, sourceID: sourceID))
                    }
                }
                for try await (index, result) in group {
                    siteResults[index] = result
                }
            }
            items.append(contentsOf: siteResults.flatMap { $0 })
        }

        if items.isEmpty, !runtimeSites.isEmpty {
            throw TVBoxServiceError.javascriptRuntimeRequired(detail: "配置中有 \(runtimeSites.count) 个 NodeJS / spider 站点")
        }
        guard !items.isEmpty else { throw TVBoxServiceError.noPlayableItems }
        return deduplicated(items)
    }

    private static func loadNodeSpiderItems(baseURL: URL, sourceID: UUID) async throws -> [MediaItem] {
        guard let config = try? await nodeRequest(baseURL.appendingPathComponent("config")),
              let root = config as? [String: Any],
              let video = root["video"] as? [String: Any] else {
            throw NodeRuntimeError.invalidResponse
        }

        let rawSites: [Any]
        if let sites = video["sites"] as? [Any] {
            rawSites = sites
        } else if let sites = video["sites"] as? [[String: Any]] {
            rawSites = sites
        } else {
            rawSites = []
        }

        let sites = rawSites.compactMap { raw -> (name: String, api: URL)? in
            guard let dictionary = raw as? [String: Any],
                  let apiString = firstString(in: dictionary, keys: ["api", "url"]) else { return nil }
            let name = firstString(in: dictionary, keys: ["name", "title", "key"]) ?? "TVBox 站点"
            guard let api = URL(string: apiString, relativeTo: baseURL)?.absoluteURL else { return nil }
            return (name, api)
        }

        guard !sites.isEmpty else { throw TVBoxServiceError.noPlayableItems }

        // A large CatVod bundle can expose many optional spiders. Loading a
        // bounded first page keeps a phone responsive while still showing a
        // useful catalog; failed providers are intentionally skipped.
        // The reference client keeps the Node service alive and loads sites
        // from its interface on demand. Do not fan out every provider during
        // one refresh on a phone; cold-starting a large bundle plus 24 sites
        // can exhaust the embedded Node event loop before the first response.
        let selectedSites = Array(sites.prefix(6))
        var siteResults = Array(repeating: [MediaItem](), count: selectedSites.count)
        await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, site) in selectedSites.enumerated() {
                group.addTask {
                    let result = (try? await fetchNodeSite(site, baseURL: baseURL, sourceID: sourceID)) ?? []
                    return (index, result)
                }
            }
            for await (index, result) in group {
                siteResults[index] = result
            }
        }

        let items = deduplicated(siteResults.flatMap { $0 })
        guard !items.isEmpty else { throw TVBoxServiceError.noPlayableItems }
        return items
    }

    private static func fetchNodeSite(
        _ site: (name: String, api: URL),
        baseURL: URL,
        sourceID: UUID
    ) async throws -> [MediaItem] {
        guard let home = try? await nodeRequest(site.api.appendingPathComponent("home"), body: [:]) else {
            return []
        }

        var dictionaries = catalogDictionaries(from: home)
        if dictionaries.isEmpty, let homeRoot = home as? [String: Any],
           let classes = homeRoot["class"] as? [Any] {
            // Some spiders expose only categories on /home. Ask for the first
            // two categories as a fallback.
            for category in classes.compactMap({ $0 as? [String: Any] }).prefix(2) {
                guard let categoryID = firstString(in: category, keys: ["type_id", "id"]) else { continue }
                let payload: [String: Any] = ["id": categoryID, "page": 1, "filters": [:]]
                if let response = try? await nodeRequest(site.api.appendingPathComponent("category"), body: payload) {
                    dictionaries.append(contentsOf: catalogDictionaries(from: response))
                }
            }
        }

        var items: [MediaItem] = []
        for raw in dictionaries.prefix(8) {
            let title = firstString(in: raw, keys: titleKeys) ?? "未命名项目"
            let category = firstString(in: raw, keys: ["type_name", "category", "group", "type"]) ?? site.name
            let artwork = firstString(in: raw, keys: artworkKeys).flatMap { resolve($0, relativeTo: site.api) }
            let id = firstString(in: raw, keys: ["vod_id", "id", "videoId"])
            var playback = firstPlayableURL(in: raw, relativeTo: site.api)

            if playback == nil, let id {
                if let detail = try? await nodeRequest(
                    site.api.appendingPathComponent("detail"),
                    body: ["id": id]
                ), let detailRaw = catalogDictionaries(from: detail).first {
                    playback = firstPlayableURL(in: detailRaw, relativeTo: site.api)
                    if playback == nil {
                        playback = try? await fetchNodePlay(
                            detail: detailRaw,
                            fallbackID: id,
                            siteURL: site.api
                        )
                    }
                }
            }

            items.append(MediaItem(
                title: title,
                subtitle: site.name,
                category: category,
                artworkURL: artwork,
                playbackURL: playback,
                sourceID: sourceID,
                kind: .movie
            ))
        }
        return items
    }

    private static func fetchNodePlay(
        detail: [String: Any],
        fallbackID: String,
        siteURL: URL
    ) async throws -> String? {
        let id = firstPlayToken(in: detail, fallback: fallbackID)
        let flag = firstString(in: detail, keys: ["vod_play_from", "flag"])?.components(separatedBy: "$$$").first ?? ""
        let payload: [String: Any] = ["flag": flag, "id": id, "vipFlags": []]
        let response = try await nodeRequest(siteURL.appendingPathComponent("play"), body: payload)
        return firstHTTPURL(in: response, relativeTo: siteURL)
    }

    private static func nodeRequest(_ url: URL, body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("FlowBox/1.1 NodeSpider", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw TVBoxServiceError.remoteStatus((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func firstPlayableURL(in dictionary: [String: Any], relativeTo baseURL: URL) -> String? {
        for key in ["url", "playUrl", "play_url", "streamUrl", "stream_url", "address", "vod_play_url"] {
            guard let value = dictionary[key] else { continue }
            for candidate in candidateStrings(from: value) {
                if let resolved = resolve(candidate, relativeTo: baseURL), isHTTPURL(resolved) {
                    return resolved
                }
            }
        }
        return nil
    }

    private static func firstHTTPURL(in object: Any, relativeTo baseURL: URL) -> String? {
        if let string = object as? String {
            for candidate in candidateStrings(from: string) {
                if let resolved = resolve(candidate, relativeTo: baseURL), isHTTPURL(resolved) {
                    return resolved
                }
            }
            return nil
        }
        if let dictionary = object as? [String: Any] {
            for key in ["url", "playUrl", "play_url", "streamUrl", "stream_url", "link"] {
                if let value = dictionary[key], let result = firstHTTPURL(in: value, relativeTo: baseURL) {
                    return result
                }
            }
            for value in dictionary.values {
                if let result = firstHTTPURL(in: value, relativeTo: baseURL) { return result }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let result = firstHTTPURL(in: value, relativeTo: baseURL) { return result }
            }
        }
        return nil
    }

    private static func firstPlayToken(in dictionary: [String: Any], fallback: String) -> String {
        for key in ["vod_play_url", "playUrl", "play_url", "url", "id"] {
            guard let value = dictionary[key] else { continue }
            if let candidate = candidateStrings(from: value).first, !candidate.isEmpty { return candidate }
        }
        return fallback
    }

    private static func candidateStrings(from value: Any) -> [String] {
        if let string = value as? String {
            return string
                .replacingOccurrences(of: "$$$", with: "#")
                .split(separator: "#")
                .map(String.init)
                .map { segment in
                    guard let separator = segment.lastIndex(of: "$") else { return segment }
                    return String(segment[segment.index(after: separator)...])
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    static func isLikelyConfiguration(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["sites"] != nil || object["lives"] != nil || object["parses"] != nil
    }

    static func parseConfiguration(data: Data, sourceID: UUID) throws -> TVBoxConfiguration {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw TVBoxServiceError.invalidConfiguration
        }

        let sites = parseSites(root)
        let liveItems = parseLiveItems(root, sourceID: sourceID)
        guard !sites.isEmpty || !liveItems.isEmpty else {
            throw TVBoxServiceError.invalidConfiguration
        }
        return TVBoxConfiguration(sites: sites, liveItems: liveItems)
    }

    private static func parseSites(_ root: [String: Any]) -> [TVBoxSite] {
        let rawSites: [[String: Any]]
        if let sites = root["sites"] as? [[String: Any]] {
            rawSites = sites
        } else if let sites = root["sites"] as? [Any] {
            rawSites = sites.compactMap { $0 as? [String: Any] }
        } else {
            rawSites = []
        }

        return rawSites.enumerated().compactMap { index, raw in
            let key = firstString(in: raw, keys: ["key", "id", "name"]) ?? "site-\(index)"
            let name = firstString(in: raw, keys: siteNameKeys) ?? key
            let api = firstString(in: raw, keys: ["api", "url", "baseUrl", "base_url"])
            let jar = firstString(in: raw, keys: ["jar", "spider", "script", "js"])
            let type = firstInt(in: raw, keys: ["type", "api_type"]) ?? 0
            let searchable = firstBool(in: raw, keys: ["searchable", "search"]) ?? true
            let quickSearch = firstBool(in: raw, keys: ["quickSearch", "quick_search"]) ?? true
            guard api != nil || jar != nil else { return nil }
            return TVBoxSite(key: key, name: name, type: type, api: api, jar: jar, searchable: searchable, quickSearch: quickSearch)
        }
    }

    private static func parseLiveItems(_ root: [String: Any], sourceID: UUID) -> [MediaItem] {
        guard let lives = root["lives"] as? [Any] else { return [] }
        var result: [MediaItem] = []

        for rawLive in lives.compactMap({ $0 as? [String: Any] }) {
            let group = firstString(in: rawLive, keys: ["group", "name", "title"]) ?? "直播"
            let logo = firstString(in: rawLive, keys: artworkKeys)

            if let channels = rawLive["channels"] as? [Any] {
                for rawChannel in channels.compactMap({ $0 as? [String: Any] }) {
                    let title = firstString(in: rawChannel, keys: titleKeys) ?? "未命名频道"
                    let channelLogo = firstString(in: rawChannel, keys: artworkKeys) ?? logo
                    let urls = strings(in: rawChannel, keys: ["urls", "url", "playUrl", "play_url"])
                    for (index, value) in urls.enumerated() {
                        guard isHTTPURL(value) else { continue }
                        result.append(MediaItem(
                            title: index == 0 ? title : "\(title) · 线路 \(index + 1)",
                            subtitle: group,
                            category: group,
                            artworkURL: channelLogo,
                            playbackURL: value,
                            sourceID: sourceID,
                            kind: .live,
                            isLive: true
                        ))
                    }
                }
            } else {
                let title = firstString(in: rawLive, keys: titleKeys) ?? group
                for value in strings(in: rawLive, keys: ["urls", "url", "playUrl", "play_url"]) where isHTTPURL(value) {
                    result.append(MediaItem(
                        title: title,
                        subtitle: group,
                        category: group,
                        artworkURL: logo,
                        playbackURL: value,
                        sourceID: sourceID,
                        kind: .live,
                        isLive: true
                    ))
                }
            }
        }
        return result
    }

    private static func fetchSite(_ site: TVBoxSite, sourceURL: URL, sourceID: UUID) async throws -> [MediaItem] {
        guard let apiString = site.api,
              let apiURL = URL(string: apiString, relativeTo: sourceURL)?.absoluteURL else { return [] }

        let listURL = apiURL.appending(queryItems: [
            URLQueryItem(name: "ac", value: "list"),
            URLQueryItem(name: "pg", value: "1")
        ])
        let (data, response) = try await fetch(listURL)
        guard response.statusCode < 400 else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dictionaries = catalogDictionaries(from: object)

        var items: [MediaItem] = []
        var unresolved: [(index: Int, id: String)] = []
        for raw in dictionaries {
            let title = firstString(in: raw, keys: titleKeys) ?? "未命名项目"
            let category = firstString(in: raw, keys: ["type_name", "category", "group", "type"]) ?? site.name
            let artwork = firstString(in: raw, keys: artworkKeys).flatMap { resolve($0, relativeTo: apiURL) }
            let playback = strings(in: raw, keys: urlKeys).compactMap { resolve($0, relativeTo: apiURL) }.first
            let id = firstString(in: raw, keys: ["vod_id", "id", "videoId"])
            items.append(MediaItem(
                title: title,
                subtitle: site.name,
                category: category,
                artworkURL: artwork,
                playbackURL: playback,
                sourceID: sourceID,
                kind: .movie
            ))
            if playback == nil, let id, items.count <= 12 {
                unresolved.append((items.count - 1, id))
            }
        }

        // Many TVBox APIs return only vod_id in the list response. Resolve a
        // small first page through the standard detail endpoint so the result
        // can be played by AVPlayer when the provider exposes a direct URL.
        for candidate in unresolved {
            if let playback = try? await fetchDetail(id: candidate.id, apiURL: apiURL) {
                items[candidate.index].playbackURL = playback
            }
        }
        return items
    }

    private static func fetchDetail(id: String, apiURL: URL) async throws -> String? {
        let detailURL = apiURL.appending(queryItems: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: id)
        ])
        let (data, response) = try await fetch(detailURL)
        guard response.statusCode < 400,
              let object = try? JSONSerialization.jsonObject(with: data),
              let raw = catalogDictionaries(from: object).first else { return nil }
        return strings(in: raw, keys: urlKeys).compactMap { resolve($0, relativeTo: apiURL) }.first
    }

    private static func catalogDictionaries(from object: Any) -> [[String: Any]] {
        if let root = object as? [String: Any] {
            for key in ["list", "data", "result", "items", "videos"] {
                if let list = root[key] as? [[String: Any]], !list.isEmpty { return list }
                if let list = root[key] as? [Any] {
                    let dictionaries = list.compactMap { $0 as? [String: Any] }
                    if !dictionaries.isEmpty { return dictionaries }
                }
            }
        }
        if let list = object as? [[String: Any]] { return list }
        if let list = object as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        return []
    }

    private static func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = "\(item.title)|\(item.playbackURL ?? "")"
            return seen.insert(key).inserted
        }
    }

    private static func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("FlowBox/1.1 TVBox", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private static func siblingJavaScriptURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? url.path
        if path.hasSuffix(".md5") {
            components?.path = String(path.dropLast(4))
        }
        return components?.url ?? url
    }

    private static func md5(_ data: Data) -> String {
        // CommonCrypto is not available in the command-line-only build environment.
        // The runtime check is intentionally conservative: a valid sidecar proves the
        // bundle relationship, while a full cryptographic check is performed in the
        // Xcode/iOS target through the platform implementation below.
        #if canImport(CommonCrypto)
        return importCommonCryptoMD5(data)
        #else
        // The iOS target imports CommonCrypto. This fallback keeps the source
        // parseable in stripped-down command-line environments.
        return ""
        #endif
    }

    #if canImport(CommonCrypto)
    private static func importCommonCryptoMD5(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    #endif

    private static func isMD5Document(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }

    private static func looksLikeJavaScript(_ text: String) -> Bool {
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)
        return prefix.hasPrefix("var ") || prefix.hasPrefix("(()=>") || prefix.contains("require(\"")
    }

    private static func resolve(_ value: String, relativeTo baseURL: URL) -> String? {
        if isHTTPURL(value) { return value }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func firstInt(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? NSNumber { return value.intValue }
            if let value = dictionary[key] as? String, let int = Int(value) { return int }
        }
        return nil
    }

    private static func firstBool(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool { return value }
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
            if let value = dictionary[key] as? String {
                if ["1", "true", "yes"].contains(value.lowercased()) { return true }
                if ["0", "false", "no"].contains(value.lowercased()) { return false }
            }
        }
        return nil
    }

    private static func strings(in dictionary: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let value = dictionary[key] as? String {
                let candidates = value.split(separator: "#").flatMap { part in
                    let text = String(part)
                    if let dollar = text.lastIndex(of: "$") { return [String(text[text.index(after: dollar)...])] }
                    return [text]
                }
                if !candidates.isEmpty { return candidates }
            }
            if let values = dictionary[key] as? [String] { return values }
            if let values = dictionary[key] as? [Any] { return values.compactMap { $0 as? String } }
        }
        return []
    }
}
