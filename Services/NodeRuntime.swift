import Foundation

enum NodeRuntimeError: LocalizedError {
    case cannotCreateCache
    case cannotWriteScript
    case launchFailed(String)
    case anotherSourceIsRunning
    case startupTimeout
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cannotCreateCache:
            return "无法创建 NodeJS 缓存目录"
        case .cannotWriteScript:
            return "无法保存 NodeJS 源文件"
        case .launchFailed(let detail):
            return "NodeJS 启动失败：\(detail)"
        case .anotherSourceIsRunning:
            return "已有另一个 JavaScript 源在运行，请重启流映后再切换源"
        case .startupTimeout:
            return "NodeJS 服务启动超时，请检查源文件或网络连接"
        case .invalidResponse:
            return "NodeJS 服务返回了无法识别的数据"
        }
    }
}

/// Owns one embedded NodeMobile process for the app lifetime.
///
/// NodeMobile exposes a process-wide Node event loop and the CatVod bundle
/// auto-starts from `process.argv[1]`. Keeping one runtime avoids trying to
/// launch multiple Node engines inside the same iOS process.
actor NodeRuntime {
    static let shared = NodeRuntime()

    private let port = 9988
    private var activeCacheKey: String?

    func start(scriptData: Data, cacheKey: String) async throws -> URL {
        let scriptURL = try save(scriptData: scriptData, cacheKey: cacheKey)

        if let activeCacheKey, activeCacheKey != cacheKey, FBNodeRunner.isRunning() {
            throw NodeRuntimeError.anotherSourceIsRunning
        }

        if !FBNodeRunner.isRunning() {
            var bridgeError: NSError?
            let didStart = FBNodeRunner.start(
                withScriptPath: scriptURL.path,
                port: port,
                error: &bridgeError
            )
            guard didStart else {
                throw NodeRuntimeError.launchFailed(bridgeError?.localizedDescription ?? "未知错误")
            }
        }

        activeCacheKey = cacheKey
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(baseURL: baseURL)
        return baseURL
    }

    private func save(scriptData: Data, cacheKey: String) throws -> URL {
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NodeRuntimeError.cannotCreateCache
        }
        let directory = caches
            .appendingPathComponent("FlowBox", isDirectory: true)
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let scriptURL = directory.appendingPathComponent("index.js")
            try scriptData.write(to: scriptURL, options: [.atomic])
            return scriptURL
        } catch {
            throw NodeRuntimeError.cannotWriteScript
        }
    }

    private func waitUntilReady(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        request.setValue("FlowBox/1.1 NodeRuntime", forHTTPHeaderField: "User-Agent")

        for _ in 0..<80 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                // The first few requests normally race NodeMobile startup.
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NodeRuntimeError.startupTimeout
    }
}
