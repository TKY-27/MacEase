import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index('field() {')
end = source.index('\nunpack() {', start)
original = source[start:end]
assert 'archive="$(fetch "$name")"' in source
candidate = '''field() { awk -v name="$1" -v column="$2" '$1 == name { print $column }' "$lock"; }

fetch() {
    local name="$1" url expected archive candidate actual
    url="$(field "$name" 5)"
    expected="$(field "$name" 4)"
    archive="$archives/$name-$(basename "$url")"
    candidate="$archive"
    if [[ ! -f "$archive" ]]; then
        candidate="$archive.part"
        curl --fail --location --connect-timeout 20 --max-time 300 --retry 3 --output "$candidate" "$url" || return 1
    fi
    actual="$(shasum -a 256 "$candidate" | cut -d' ' -f1)" || return 1
    [[ "$actual" == "$expected" ]] || {
        echo "error: SHA-256 mismatch for $name" >&2; return 1;
    }
    if [[ "$candidate" != "$archive" ]]; then
        mv "$candidate" "$archive" || return 1
    fi
    echo "$archive"
}
'''
if len(sys.argv) > 2:
    Path(sys.argv[2]).write_text(source[:start] + candidate + source[end:])

valid = b'complete fixture archive'
expected = hashlib.sha256(valid).hexdigest()
for label, body in [('baseline', original), ('candidate', candidate)]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        lock = root / 'lock'
        lock.write_text(f'fixture 1 MIT {expected} https://example.invalid/archive.tar -\n')
        archive = root / 'fixture-archive.tar'
        partial = root / 'fixture-archive.tar.part'
        log = root / 'curl.log'
        curl = root / 'curl'
        curl.write_text('''#!/bin/bash
set -eu
while [[ "$1" != --output ]]; do shift; done
printf '%s\\n' "$MODE" >> "$LOG"
case "$MODE" in
    valid) printf %s 'complete fixture archive' > "$2" ;;
    corrupt) printf %s 'partial bytes' > "$2" ;;
    failed-partial) printf %s 'partial bytes' > "$2"; exit 18 ;;
    failed-complete) printf %s 'complete fixture archive' > "$2"; exit 18 ;;
    *) exit 99 ;;
esac
''')
        curl.chmod(0o755)
        script = root / 'fetch.sh'
        script.write_text('set -euo pipefail\n' + body + '\narchive="$(fetch fixture)"\nprintf "%s\\n" "$archive"\n')
        subprocess.run(['bash', '-n', str(script)], check=True)
        def invoke(mode):
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                       MODE=mode, LOG=str(log), lock=str(lock), archives=str(root))
            result = subprocess.run(['bash', str(script)], env=env, text=True,
                                    capture_output=True, timeout=10)
            if result.returncode == 0:
                assert result.stdout.strip() == str(archive)
                assert archive.read_bytes() == valid
            return result.returncode

        cases = [
            # initial mode, initial cache, initial success, retry success, curl calls
            ('valid', None, True, True, 1),
            ('corrupt', None, False, label == 'candidate', 2 if label == 'candidate' else 1),
            ('failed-partial', None, False, label == 'candidate', 2 if label == 'candidate' else 1),
            ('failed-complete', None, label == 'baseline', True, 2 if label == 'candidate' else 1),
            ('unused', valid, True, True, 0),
            ('unused', b'bad existing cache', False, False, 0),
        ]
        for mode, cached, first_ok, retry_ok, calls in cases:
            for path in (archive, partial, log):
                path.unlink(missing_ok=True)
            if cached is not None:
                archive.write_bytes(cached)
            first = invoke(mode)
            published = archive.exists()
            retry = invoke('valid')
            actual_calls = len(log.read_text().splitlines()) if log.exists() else 0
            assert (first == 0, retry == 0, actual_calls) == (first_ok, retry_ok, calls)
            if cached is None and mode != 'valid':
                assert published == (label == 'baseline')
            print(f'{label}: {mode}, cache={cached is not None}: first={first}, '
                  f'published={published}, retry={retry}, downloads={actual_calls}')
