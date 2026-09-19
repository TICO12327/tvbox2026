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

    private struct RuntimeFiles {
        let bundleURL: URL
        let bootstrapURL: URL
    }

    private let port = 9988
    private var activeCacheKey: String?

    func start(scriptData: Data, cacheKey: String) async throws -> URL {
        let files = try save(scriptData: scriptData, cacheKey: cacheKey)

        if let activeCacheKey, activeCacheKey != cacheKey, FBNodeRunner.isRunning() {
            throw NodeRuntimeError.anotherSourceIsRunning
        }

        if !FBNodeRunner.isRunning() {
            do {
                // NSError** is imported by Swift as a throwing method, so the
                // bridge's failure is surfaced here without an extra error
                // argument at the call site.
                try FBNodeRunner.start(withScriptPath: files.bootstrapURL.path, port: port)
            } catch {
                throw NodeRuntimeError.launchFailed(error.localizedDescription)
            }
        }

        activeCacheKey = cacheKey
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(baseURL: baseURL)
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
            try scriptData.write(to: bundleURL, options: [.atomic])

            let pathLiteralData = try JSONSerialization.data(
                withJSONObject: bundleURL.path,
                options: [.fragmentsAllowed]
            )
            guard let pathLiteral = String(data: pathLiteralData, encoding: .utf8) else {
                throw NodeRuntimeError.cannotWriteScript
            }
            let bootstrap = """
            ;(() => {
              // iOS NodeMobile runs without JIT. Some bundled HTTP clients probe
              // WebAssembly during startup and otherwise crash the JS runtime.
              if (typeof globalThis.WebAssembly === "undefined") {
                const fakeModule = { exports: { instances: {} } };
                const fakeInstance = { exports: {} };
                globalThis.WebAssembly = {
                  compile: () => Promise.resolve(fakeModule),
                  instantiate: () => Promise.resolve({ module: fakeModule, instance: fakeInstance }),
                  validate: () => true,
                  Module: function() { return fakeModule; },
                  Instance: function() { return fakeInstance; },
                  Memory: function(opts) { this.buffer = new ArrayBuffer((opts.initial || 1) * 65536); },
                  Table: function() {},
                };
              }

              const bundlePath = (pathLiteral);
              const port = process.env.PORT || "9988";
              process.env.DEV_HTTP_PORT = port;
              process.env.HOST = "127.0.0.1";

              const flowBoxExit = (code = 0) => {
                const numericCode = Number.isFinite(Number(code)) ? Number(code) : 1;
                console.error("[FlowBox] blocked process exit (" + numericCode + ")");
                process.exitCode = numericCode;
              };
              try { process.exit = flowBoxExit; } catch (_) {}
              try { process.abort = () => flowBoxExit(1); } catch (_) {}
              process.on("unhandledRejection", error => console.error("[FlowBox] unhandled rejection", error));
              process.on("uncaughtException", error => console.error("[FlowBox] uncaught exception", error));

              if (!globalThis.local) {
                const values = {};
                globalThis.local = {
                  get: (key, fallback) => values[key] === undefined ? (fallback || "") : values[key],
                  set: (key, value) => { values[key] = value; },
                };
              }
              globalThis.catDartServerPort = () => 0;
              globalThis.jsProxy = "http://127.0.0.1:" + port + "/proxy?do=js&url=";
              if (!globalThis.catServerFactory) {
                const http = require("http");
                globalThis.catServerFactory = handler => http.createServer(handler);
              }

              // CatVod standalone bundles only auto-start when argv[1] ends in
              // index.js. Keep that contract while running a safe bootstrap.
              process.argv[1] = bundlePath;
              try {
                require(bundlePath);
              } catch (error) {
                console.error("[FlowBox] bundle startup failed", error);
                process.exitCode = 1;
              }
            })();
            """
            guard let bootstrapData = bootstrap.data(using: .utf8) else {
                throw NodeRuntimeError.cannotWriteScript
            }
            try bootstrapData.write(to: bootstrapURL, options: [.atomic])
            return RuntimeFiles(bundleURL: bundleURL, bootstrapURL: bootstrapURL)
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
