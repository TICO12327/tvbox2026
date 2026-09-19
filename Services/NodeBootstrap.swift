import Foundation

/// Kept independent of NodeMobile so CI can execute the actual generated script.
enum NodeBootstrap {
    static func make(bundlePath: String, failurePath: String) throws -> String {
        func literal(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let bundle = try literal(bundlePath)
        let failure = try literal(failurePath)
        return """
        ;(() => {
          const fs = require('fs');
          const failurePath = \(failure);
          // Record only stage/error class: remote exceptions may contain credentials.
          const fail = (stage, error) => {
            const name = error && ['Error', 'TypeError', 'ReferenceError', 'SyntaxError', 'RangeError'].includes(error.name)
              ? error.name : 'Error';
            const summary = stage + ': ' + name;
            try { fs.writeFileSync(failurePath, summary); } catch (_) {}
            console.error('[FlowBox] ' + summary);
          };
          process.on('uncaughtException', error => fail('uncaughtException', error));
          process.on('unhandledRejection', error => fail('unhandledRejection', error));
          process.exit = () => { throw new Error('Process exit is unavailable in embedded Node'); };
          process.abort = () => { throw new Error('Process abort is unavailable in embedded Node'); };
          // Keep the embedded event loop alive after a rejected/failed startup.
          // This does not intercept native aborts, OOM, or operating-system kills.
          setInterval(() => {}, 60000);
          try {
            if (fs.existsSync(failurePath)) fs.unlinkSync(failurePath);
            const bundlePath = \(bundle);
            const port = process.env.PORT || '9988';
            process.env.DEV_HTTP_PORT = port;
            process.env.HOST = '127.0.0.1';
            if (!globalThis.local) {
              const values = Object.create(null);
              globalThis.local = {
                get: (key, fallback) => values[key] === undefined ? (fallback || '') : values[key],
                set: (key, value) => { values[key] = value; },
              };
            }
            globalThis.catDartServerPort = () => 0;
            globalThis.jsProxy = 'http://127.0.0.1:' + port + '/proxy?do=js&url=';
            if (!globalThis.catServerFactory) {
              const http = require('http');
              globalThis.catServerFactory = handler => http.createServer(handler);
            }
            // Leave WebAssembly feature detection truthful; fake exports cannot run WASM.
            process.argv[1] = bundlePath;
            require(bundlePath);
          } catch (error) {
            fail('bundle.startup', error);
          }
        })();
        """
    }
}
