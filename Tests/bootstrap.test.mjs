import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const scratch = mkdtempSync(join(tmpdir(), 'flowbox-bootstrap-test-'));
const generator = join(scratch, 'generator');
execFileSync('swiftc', ['-module-cache-path', join(scratch, 'modules'),
  join(root, 'Services/NodeBootstrap.swift'), join(root, 'Tests/BootstrapGenerator.swift'), '-o', generator]);
const bundlePath = '/tmp/中文 "quote" \\ folder/index.js';
const failurePath = '/tmp/failure.txt';
const script = execFileSync(generator, [bundlePath, failurePath], { encoding: 'utf8' });

function run(loadBundle = () => {}, stale = false) {
  const files = new Map(stale ? [[failurePath, 'old failure']] : []);
  const handlers = new Map();
  const timers = [];
  const proc = { argv: ['node', 'bootstrap.js'], env: { PORT: '9988' },
    on: (event, handler) => handlers.set(event, handler),
    exit: () => assert.fail('native exit must never be called'),
    abort: () => assert.fail('native abort must never be called') };
  const context = vm.createContext({ process: proc, console: { error() {} },
    WebAssembly: undefined,
    setInterval: (callback, interval) => timers.push({ callback, interval }),
    require: name => {
      if (name === 'fs') return {
        writeFileSync: (path, value) => files.set(path, value),
        existsSync: path => files.has(path), unlinkSync: path => files.delete(path) };
      if (name === 'http') return { createServer: handler => ({ handler }) };
      assert.equal(name, bundlePath, 'Swift must embed the quoted path, not a JS identifier');
      assert.equal(proc.argv[1], bundlePath);
      assert.ok(handlers.has('uncaughtException'), 'install error handlers before remote code');
      loadBundle(proc);
    } });
  vm.runInContext(script, context);
  return { context, files, handlers, timers };
}

test('loads generated path containing Unicode, quotes and backslashes', () => {
  let loaded = false;
  const r = run(() => { loaded = true; }, true);
  assert.ok(loaded);
  assert.equal(r.files.size, 0, 'stale failure is cleared on first startup');
  assert.equal(r.context.WebAssembly, undefined, 'do not fake WASM support');
  assert.equal(r.timers.length, 1, 'preserve embedded event loop');
});
test('synchronous bundle error becomes a local failure marker', () => {
  const r = run(() => { throw new SyntaxError('secret source URL'); });
  assert.equal(r.files.get(failurePath), 'bundle.startup: SyntaxError');
});
for (const operation of ['exit', 'abort']) {
  test(`blocks JS process.${operation} before it reaches the native process`, () => {
    const r = run(proc => proc[operation](1));
    assert.equal(r.files.get(failurePath), 'bundle.startup: Error');
  });
}
for (const event of ['uncaughtException', 'unhandledRejection']) {
  test(`records ${event} without leaking exception contents`, () => {
    const r = run();
    r.handlers.get(event)(new ReferenceError('token=secret'));
    assert.equal(r.files.get(failurePath), `${event}: ReferenceError`);
  });
}
