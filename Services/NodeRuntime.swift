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
            return "NodeJS 运行时已结束，请重启流映后再试，并导出诊断日志"
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

    private struct RuntimeFiles {
        let bundleURL: URL
        let bootstrapURL: URL
        let failureURL: URL
    }

    private let port = 9988
    private var activeCacheKey: String?

    func start(scriptData: Data, cacheKey: String) async throws -> URL {
        if let activeCacheKey, activeCacheKey != cacheKey {
            throw NodeRuntimeError.anotherSourceIsRunning
        }

        let files = try save(scriptData: scriptData, cacheKey: cacheKey)

        if !FBNodeRunner.isRunning() {
            do {
                // Clear the previous process's marker before polling can race startup.
                try Data().write(to: files.failureURL, options: .atomic)
                // NSError** is imported by Swift as a throwing method, so the
                // bridge's failure is surfaced here without an extra error
                // argument at the call site.
                RuntimeDiagnostics.record("node.start.requested")
                try FBNodeRunner.start(withScriptPath: files.bootstrapURL.path, port: port)
            } catch {
                RuntimeDiagnostics.record("node.start.rejected")
                throw NodeRuntimeError.launchFailed(error.localizedDescription)
            }
        }

        activeCacheKey = cacheKey
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(baseURL: baseURL, failureURL: files.failureURL)
        return baseURL
    }

    private func save(scriptData: Data, cacheKey: String) throws -> RuntimeFiles {
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
            let bundleURL = directory.appendingPathComponent("index.js")
            let bootstrapURL = directory.appendingPathComponent("flowbox-bootstrap.js")
            let failureURL = directory.appendingPathComponent("startup-failure.txt")
            try scriptData.write(to: bundleURL, options: [.atomic])

            let bootstrap = try NodeBootstrap.make(bundlePath: bundleURL.path, failurePath: failureURL.path)
            guard let bootstrapData = bootstrap.data(using: .utf8) else {
                throw NodeRuntimeError.cannotWriteScript
            }
            try bootstrapData.write(to: bootstrapURL, options: [.atomic])
            return RuntimeFiles(bundleURL: bundleURL, bootstrapURL: bootstrapURL, failureURL: failureURL)
        } catch {
            throw NodeRuntimeError.cannotWriteScript
        }
    }

    private func waitUntilReady(baseURL: URL, failureURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        request.setValue("FlowBox/1.1 NodeRuntime", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<80 {
            try Task.checkCancellation()
            if let failure = try? String(contentsOf: failureURL, encoding: .utf8), !failure.isEmpty {
                RuntimeDiagnostics.record("node.bootstrap.failed: \(failure)")
                throw NodeRuntimeError.launchFailed("脚本异常（\(failure)），请导出诊断日志")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    RuntimeDiagnostics.record("node.health.ready")
                    return
                }
            } catch {
                // The first few requests normally race NodeMobile startup.
            }
            if attempt >= 3, !FBNodeRunner.isRunning() {
                RuntimeDiagnostics.record("node.returned code=\(FBNodeRunner.lastExitCode())")
                throw NodeRuntimeError.runtimeExited
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        RuntimeDiagnostics.record("node.health.timeout")
        throw NodeRuntimeError.startupTimeout
    }
}
