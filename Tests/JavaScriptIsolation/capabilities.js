(async () => {
    const result = {modules: {}, operations: {}, globals: Reflect.ownKeys(globalThis).map(String)};
    const attempt = async (name, operation) => {
        try { result.operations[name] = Boolean(await operation()); }
        catch { result.operations[name] = false; }
    };
    const modules = {};
    const load = new Function('name', 'return import(name)');
    for (const name of ['std', 'os', 'bjson', 'qjs:std', 'qjs:os', 'qjs:bjson']) {
        try { modules[name] = await load(name); result.modules[name] = true; }
        catch { result.modules[name] = false; }
    }
    const std = modules['qjs:std'] || modules.std;
    const os = modules['qjs:os'] || modules.os;
    await attempt('read', () => {
        const file = std.open(probeConfig.sentinel, 'r');
        const content = file.readAsString();
        file.close();
        return content === probeConfig.marker;
    });
    await attempt('loadFile', () => std.loadFile(probeConfig.sentinel) === probeConfig.marker);
    await attempt('write', () => {
        const file = std.open(probeConfig.written, 'w');
        file.puts(probeConfig.marker);
        return file.close() === 0;
    });
    await attempt('spawn', () => os.exec(['/usr/bin/touch', probeConfig.spawned], {block: true}) === 0);
    await attempt('readdir', () => os.readdir(probeConfig.outside)[0].includes('sentinel.txt'));
    await attempt('environment', () => std.getenv('MACEASE_ISOLATION_PROBE') === probeConfig.marker);
    await attempt('urlGet', () => std.urlGet(probeConfig.server + '/url-get').includes(probeConfig.marker));
    await attempt('networkProcess', () => {
        const output = std.open('/dev/null', 'w');
        const status = os.exec(['/usr/bin/curl', '--silent', '--fail', probeConfig.server + '/exec-network'], {block: true, stdout: output.fileno()});
        output.close();
        return status === 0;
    });
    await attempt('popen', () => {
        const pipe = std.popen('/usr/bin/printf isolation-probe', 'r');
        const content = pipe.readAsString();
        pipe.close();
        return content === 'isolation-probe';
    });
    await attempt('fileModule', async () => (await load(probeConfig.module)).marker === probeConfig.marker);
    await attempt('httpModule', async () => (await load(probeConfig.server + '/module.js')).marker === probeConfig.marker);
    await attempt('bjson', () => {
        const bjson = modules['qjs:bjson'] || modules.bjson;
        const encoded = bjson.write({marker: probeConfig.marker}, 0);
        return bjson.read(encoded, 0, encoded.byteLength, 0).marker === probeConfig.marker;
    });
    await attempt('worker', () => new Promise(resolve => {
        const worker = new os.Worker(probeConfig.worker);
        worker.onmessage = event => { worker.onmessage = null; resolve(event.data === probeConfig.marker); };
    }));
    result.consoleKeys = Reflect.ownKeys(console).map(String);
    result.performanceKeys = Reflect.ownKeys(performance).map(String);
    result.hostGlobals = Object.fromEntries(['std', 'os', 'bjson', 'loadScript', '__loadScript', 'fetch', 'WebSocket', 'XMLHttpRequest', 'Worker', 'scriptArgs', 'execArgv', 'argv0'].map(name => [name, typeof globalThis[name]]));
    console.log(JSON.stringify(result));
})().catch(error => { console.log(JSON.stringify({unexpectedError: String(error)})); });
