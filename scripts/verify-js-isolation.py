#!/usr/bin/env python3
import argparse
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading


INTRINSICS = set('''Object Function Error EvalError RangeError ReferenceError SyntaxError TypeError URIError
InternalError AggregateError SuppressedError Iterator AsyncIterator Array Number BigInt Boolean String Symbol
Math Reflect Proxy Date RegExp JSON ArrayBuffer SharedArrayBuffer Uint8ClampedArray Int8Array Uint8Array
Int16Array Uint16Array Int32Array Uint32Array BigInt64Array BigUint64Array Float16Array Float32Array Float64Array
DataView Map Set WeakMap WeakSet Promise Atomics WeakRef FinalizationRegistry DisposableStack AsyncDisposableStack
parseInt parseFloat isNaN isFinite decodeURI decodeURIComponent encodeURI encodeURIComponent escape unescape
Infinity NaN undefined eval globalThis queueMicrotask DOMException btoa atob performance console'''.split())


def verify(binary):
    fixture = Path(__file__).resolve().parent.parent / 'Tests/JavaScriptIsolation/capabilities.js'
    with tempfile.TemporaryDirectory(prefix='MacEaseJSIsolation-') as folder:
        root = Path(folder)
        scripts = root / 'scripts'
        outside = root / 'outside'
        scripts.mkdir(mode=0o700)
        outside.mkdir()
        marker = 'macease-isolation-probe'
        sentinel = outside / 'sentinel.txt'
        sentinel.write_text(marker)
        module = outside / 'external.mjs'
        module.write_text('export const marker = ' + json.dumps(marker) + ';')
        worker = outside / 'worker.mjs'
        worker.write_text("import * as std from 'qjs:std'; import * as os from 'qjs:os';\n"
                          'std.open(' + json.dumps(str(outside / 'worker-output')) + ', "w").puts("worker");\n'
                          'os.Worker.parent.postMessage(' + json.dumps(marker) + ');')
        requests = []

        class Server(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(marker.encode())

            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            configuration = {'marker': marker, 'sentinel': str(sentinel), 'outside': str(outside),
                             'written': str(outside / 'written'), 'spawned': str(outside / 'spawned'),
                             'module': str(module), 'worker': str(worker),
                             'server': 'http://127.0.0.1:' + str(server.server_port)}
            script = scripts / 'capabilities.js'
            script.write_text('const probeConfig = ' + json.dumps(configuration) + ';\n' + fixture.read_text())
            script.chmod(0o600)
            environment = {'HOME': str(scripts), 'TMPDIR': str(scripts), 'PATH': '/usr/bin:/bin',
                           'MACEASE_ISOLATION_PROBE': marker}
            positive = scripts / 'positive.js'
            positive.write_text('console.log(JSON.stringify({value: eval("20 + 22"), function: new Function("return 42")(), bytes: new Uint8Array([42])[0]}));')
            successful = subprocess.run([str(binary), '--script', str(positive)], input='', text=True,
                                        capture_output=True, cwd=scripts, env=environment, timeout=20, check=True)
            assert not successful.stderr, successful.stderr
            assert json.loads(successful.stdout) == {'value': 42, 'function': 42, 'bytes': 42}
            completed = subprocess.run([str(binary), '--script', str(script)], input='', text=True,
                                       capture_output=True, cwd=scripts, env=environment, timeout=20, check=True)
            assert not completed.stderr, completed.stderr
            report = json.loads(completed.stdout)
            report['staticImports'] = {}
            for name in ('std', 'os', 'qjs:std', 'qjs:os', str(module)):
                static = scripts / 'static.js'
                static.write_text('import * as capability from ' + json.dumps(name) + '; console.log(capability);')
                rejected = subprocess.run([str(binary), '--script', str(static)], input='', text=True,
                                          capture_output=True, cwd=scripts, env=environment, timeout=20)
                report['staticImports'][name] = rejected.returncode != 0 and 'SyntaxError' in rejected.stderr
            enabled = subprocess.run([str(binary), '--std', '--script', str(positive)], input='', text=True,
                                     capture_output=True, cwd=scripts, env=environment, timeout=20)
            report['stdOptionRejected'] = enabled.returncode != 0
            report['networkRequests'] = requests.copy()
            report['writtenFiles'] = [name for name in ('written', 'spawned', 'worker-output') if (outside / name).exists()]
            print(json.dumps(report, indent=2), flush=True)
            assert 'unexpectedError' not in report, report
            assert set(report['modules']) == {'std', 'os', 'bjson', 'qjs:std', 'qjs:os', 'qjs:bjson'}
            assert set(report['operations']) == {'read', 'loadFile', 'write', 'spawn', 'readdir', 'environment',
                                                'urlGet', 'networkProcess', 'popen', 'fileModule', 'httpModule', 'bjson', 'worker'}
            assert not any(report['modules'].values()), 'Native modules are reachable'
            assert not any(report['operations'].values()), 'Host operations are reachable'
            assert not report['writtenFiles'], 'Outside files were modified'
            assert all(report['staticImports'].values()), report['staticImports']
            assert report['stdOptionRejected'], 'The --std option is available'
            assert not requests, 'Network access succeeded'
            assert all(kind == 'undefined' for kind in report['hostGlobals'].values()), report['hostGlobals']
            assert set(report['globals']) <= INTRINSICS | {'Symbol(Symbol.toStringTag)'}, set(report['globals']) - INTRINSICS
            assert report['consoleKeys'] == ['log'], report['consoleKeys']
            assert set(report['performanceKeys']) == {'now', 'timeOrigin'}, report['performanceKeys']
            assert sentinel.read_text() == marker
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    print('JavaScript isolation verified.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    verify(parser.parse_args().binary.resolve())


if __name__ == '__main__':
    main()
