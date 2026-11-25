import hashlib
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
old_guard = '''    && "$(cat "$stamp_file")" == "$stamp" && -x "$runtime/bin/python3" \\
    && -x "$runtime/bin/qjs" && -x "$runtime/bin/ffmpeg" && -x "$runtime/bin/ffprobe" ]]; then'''
new_guard = '''    && "$(head -n 1 "$stamp_file")" == "$stamp" && -x "$runtime/bin/python3" \\
    && -x "$runtime/bin/qjs" && -x "$runtime/bin/ffmpeg" && -x "$runtime/bin/ffprobe" ]] \\
    && source_digest="$(shasum -a 256 "$source_archive" | cut -d' ' -f1)" \\
    && [[ "$(cat "$stamp_file")" == "$stamp"$'\\n'"$source_digest" ]]; then'''
old_write = '''printf '%s\\n' "$stamp" > "$stamp_file"'''
new_write = '''source_digest="$(shasum -a 256 "$source_archive" | cut -d' ' -f1)"
printf '%s\\n' "$stamp" "$source_digest" > "$stamp_file"'''
assert source.count(old_guard) == source.count(old_write) == 1
candidate = source.replace(old_guard, new_guard).replace(old_write, new_write)
if len(sys.argv) > 2:
    pathlib.Path(sys.argv[2]).write_text(candidate)
paths = ['Vendor/media-tools.lock', 'scripts/build-media-tools.sh', 'scripts/sign-bundled-code.sh',
         'scripts/verify-signing.py', 'scripts/entitlements/fixture.plist', 'docs/media-tools.md',
         'Vendor/patches/lame-media-tools-export.patch', 'Vendor/patches/quickjs-solver-only.patch',
         'Vendor/patches/quickjs-solver.c', 'scripts/verify-js-isolation.py',
         'Tests/JavaScriptIsolation/capabilities.js', 'LICENSE']
marker = '[[ "$(uname -m)" == arm64 ]]'
for label, contents in [('baseline', source), ('candidate', candidate)]:
    prefix = contents.split(marker, 1)[0]
    assert prefix.endswith('fi\n')
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for name in paths:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + '\n')
        script = root / paths[1]
        # Stop at the boundary of native compilation.
        script.write_text(prefix + 'exit 42\n')
        runtime = root / 'Vendor/build/media-tools'
        (runtime / 'bin').mkdir(parents=True)
        for name in ('python3', 'qjs', 'ffmpeg', 'ffprobe'):
            executable = runtime / 'bin' / name
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o755)
        archive = runtime.parent / 'media-tools-sources.tar.xz'
        stamp = runtime / '.stamp'
        original = b'fixture archive bytes'
        input_digest = hashlib.sha256(b''.join((root / p).read_bytes() for p in paths)).hexdigest()
        recorded = input_digest + '\n'
        if label == 'candidate':
            recorded += hashlib.sha256(original).hexdigest() + '\n'
        cases = [('intact', original, recorded, [], 0),
                 ('truncated', original[:5], recorded, [], 42),
                 ('empty', b'', recorded, [], 42),
                 ('same-size mutation', b'X' + original[1:], recorded, [], 42),
                 ('missing', None, recorded, [], 42),
                 ('stale inputs', original, 'stale\n', [], 42),
                 ('forced', original, recorded, ['--force'], 42)]
        if label == 'candidate':
            cases.append(('missing digest', original, input_digest + '\n', [], 42))
        for name, payload, stamp_contents, args, expected in cases:
            archive.unlink(missing_ok=True)
            if payload is not None:
                archive.write_bytes(payload)
            stamp.write_text(stamp_contents)
            result = subprocess.run(['bash', str(script), *args], capture_output=True, text=True, timeout=10)
            print(f'{label}: {name}: exit={result.returncode}, expected={expected}')
            if label == 'candidate':
                assert result.returncode == expected, result.stderr
            else:
                assert result.returncode == (0 if name in {'truncated', 'empty', 'same-size mutation'} else expected)
        # Exercise actual final stamp-writing statements, not native build.
        archive.write_bytes(original)
        write_code = new_write if label == 'candidate' else old_write
        assert write_code in contents
        subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', write_code], check=True,
                       env={'PATH': '/usr/bin:/bin', 'stamp': input_digest, 'stamp_file': str(stamp),
                            'source_archive': str(archive)})
        assert stamp.read_text() == recorded
        print(f'{label}: stamp writer: matches expected contents')
