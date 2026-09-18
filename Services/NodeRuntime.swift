import Foundation

enum NodeRuntimeError: LocalizedError {
    case cannotCreateCache
    case cannotWriteScript
    case launchFailed(String)
    case anotherSourceIsRunning
    case runtimeExited
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
        case .runtimeExited:
            return "NodeJS 源启动失败，但已阻止它导致应用退出；请检查该源是否兼容 iOS"
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
            do {
                // NSError** is imported by Swift as a throwing method, so the
                // bridge's failure is surfaced here without an extra error
                // argument at the call site.
                try FBNodeRunner.start(withScriptPath: scriptURL.path, port: port)
            } catch {
                throw NodeRuntimeError.launchFailed(error.localizedDescription)
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
            // CatVod bundles normally run as standalone Node processes and may
            // call process.exit(1) when startup fails. NodeMobile runs inside
            // the iOS app process, where that call would terminate FlowBox.
            let hostGuard = """
            ;(() => {
              const flowBoxExit = (code = 0) => {
                const numericCode = Number.isFinite(Number(code)) ? Number(code) : 1;
                console.error(`[FlowBox] blocked process exit (${numericCode})`);
                process.exitCode = numericCode;
              };
              try { process.exit = flowBoxExit; } catch (_) {}
              try { process.abort = () => flowBoxExit(1); } catch (_) {}
            })();

            """
            var guardedScript = Data(hostGuard.utf8)
            guardedScript.append(scriptData)
            try guardedScript.write(to: scriptURL, options: [.atomic])
            return scriptURL
        } catch {
            throw NodeRuntimeError.cannotWriteScript
        }
    }

    private func waitUntilReady(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        request.setValue("FlowBox/1.1 NodeRuntime", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<80 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                // The first few requests normally race NodeMobile startup.
            }
            if attempt >= 3, !FBNodeRunner.isRunning() {
                throw NodeRuntimeError.runtimeExited
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NodeRuntimeError.startupTimeout
    }
}
