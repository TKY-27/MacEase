#!/usr/bin/env python3
import io
import hashlib
import shutil
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
EXECUTABLE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'Vendor/build/macease-hatchzip'


def extract(directory, archive=None, *, pause=False, pause_after=0, environment=None, password=None):
    child = subprocess.Popen([str(EXECUTABLE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, env=environment)
    child.stdin.write(json.dumps({'action': 'start' if archive else 'resume',
                                 'directory': str(directory), 'input': str(archive) if archive else None, 'password': password}) + '\n')
    child.stdin.flush()
    events = []
    for line in child.stdout:
        event = json.loads(line)
        events.append(event)
        if pause and event['event'] == 'progress' and event['fraction'] > pause_after:
            child.stdin.write('pause\n')
            child.stdin.flush()
            pause = False
    child.wait(timeout=60)
    child.stdin.close()
    return child.returncode, events


def zip_archive(path, names=None, *, count=5):
    expected = {}
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for index in range(count):
            name = names[index] if names else f'folder/file-{index}.txt'
            content = (f'Independent fixture {index}.\n'.encode() * 10000)
            expected[name] = content
            archive.writestr(name, content)
    return expected


def check_outputs(session, expected):
    manifest = json.loads((session / 'manifest.json').read_text())
    assert manifest['state'] == 'finished', manifest
    output = Path(manifest['output'])
    for name, content in expected.items():
        assert (output / name).read_bytes() == content, name
    return output


with tempfile.TemporaryDirectory(prefix='MacEaseHatchTests-') as sandbox:
    sandbox = Path(sandbox)
    for kind in ['zip', 'tar', 'tar.gz']:
        archive = sandbox / f'valid.{kind}'
        if kind == 'zip':
            expected = zip_archive(archive)
        else:
            expected = {'nested/payload.txt': b'tar payload\n' * 1000}
            with tarfile.open(archive, 'w:gz' if kind == 'tar.gz' else 'w') as writer:
                for name, content in expected.items():
                    header = tarfile.TarInfo(name)
                    header.size = len(content)
                    writer.addfile(header, io.BytesIO(content))
        subprocess.run(['xattr', '-w', 'com.apple.quarantine', '0081;00000000;MacEaseTest;', str(archive)], check=True)
        session = sandbox / f'session-{kind}'
        code, events = extract(session, archive)
        assert code == 0, events
        assert not archive.exists()
        output = check_outputs(session, expected)
        for path in [output, *output.rglob('*')]:
            assert subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', str(path)]).rstrip(b'\n') == b'0081;00000000;MacEaseTest;'

    payload = sandbox / 'seven-payload.txt'
    payload.write_bytes(b'independent seven zip fixture\n' * 1000)
    seven = sandbox / 'valid.7z'
    subprocess.run(['/usr/bin/tar', '--format=7zip', '-cf', str(seven), '-C', str(sandbox), payload.name], check=True)
    seven_bytes = seven.read_bytes()
    expected_seven = {payload.name: payload.read_bytes()}
    session = sandbox / 'session-seven'
    code, events = extract(session, seven)
    assert code == 0, events
    check_outputs(session, expected_seven)
    assert not seven.exists()
    seven_parts = []
    seven_width = len(seven_bytes) // 2
    for index, offset in enumerate(range(0, len(seven_bytes), seven_width), 1):
        part = sandbox / f'split.7z.{index:03}'
        part.write_bytes(seven_bytes[offset:offset + seven_width])
        seven_parts.append(part)
    session = sandbox / 'session-seven-split'
    code, events = extract(session, seven_parts[1])
    assert code == 0, events
    check_outputs(session, expected_seven)
    assert all(not part.exists() for part in seven_parts)

    archive = sandbox / 'split.zip'
    expected = zip_archive(archive)
    archive_bytes = archive.read_bytes()
    archive.unlink()
    width = len(archive_bytes) // 3
    parts = []
    for index, offset in enumerate(range(0, len(archive_bytes), width), 1):
        part = sandbox / f'split.zip.{index:03}'
        part.write_bytes(archive_bytes[offset:offset + width])
        parts.append(part)
    session = sandbox / 'session-split'
    code, events = extract(session, parts[1])
    assert code == 0, events
    check_outputs(session, expected)
    assert all(not part.exists() for part in parts)

    for label, first, second in [
        ('unicode-files', 'cafe\u0301.txt', 'caf\u00e9.txt'),
        ('unicode-directories', 'cafe\u0301/first.txt', 'caf\u00e9/second.txt'),
        ('case-alias', 'Case.txt', 'case.txt'),
    ]:
        archive = sandbox / f'{label}.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as writer:
            writer.writestr(first, b'first content')
            for index in range(512):
                writer.writestr(f'f{index}.txt', b'padding')
            writer.writestr(second, b'second differing content')
        before = archive.read_bytes()
        session = sandbox / f'session-{label}'
        code, events = extract(session, archive)
        assert code != 0 and any(word in events[-1]['message'] for word in ['collide', 'more than once']), events[-3:]
        assert archive.read_bytes() == before and not session.exists()

    for unsafe in ['/absolute.txt', '../escape.txt', 'safe/../escape.txt']:
        archive = sandbox / 'unsafe.zip'
        zip_archive(archive, [unsafe], count=1)
        before = archive.read_bytes()
        code, events = extract(sandbox / f'unsafe-{len(unsafe)}', archive)
        assert code != 0, events
        assert archive.read_bytes() == before
        archive.unlink()

    for kind in ['tar', 'tar.gz']:
        archive = sandbox / f'unsafe.{kind}'
        with tarfile.open(archive, 'w:gz' if kind == 'tar.gz' else 'w') as writer:
            header = tarfile.TarInfo('/absolute/')
            header.type = tarfile.DIRTYPE
            writer.addfile(header)
        before = archive.read_bytes()
        code, events = extract(sandbox / f'unsafe-{kind}', archive)
        assert code != 0, events
        assert archive.read_bytes() == before

    archive = sandbox / 'corrupt.zip'
    zip_archive(archive)
    corrupt = bytearray(archive.read_bytes())
    corrupt[50] ^= 255
    archive.write_bytes(corrupt)
    code, events = extract(sandbox / 'session-corrupt', archive)
    assert code != 0, events
    assert archive.read_bytes() == corrupt

    secret = sandbox / 'secret.txt'
    secret.write_text('password fixture\n' * 1000)
    encrypted = sandbox / 'encrypted.zip'
    subprocess.run(['/usr/bin/zip', '-q', '-P', 'fixture-password', str(encrypted), secret.name], cwd=sandbox, check=True)
    encrypted_bytes = encrypted.read_bytes()
    session = sandbox / 'session-encrypted'
    code, events = extract(session, encrypted)
    assert code != 0 and events[-1]['event'] == 'passwordRequired', events
    assert encrypted.read_bytes() == encrypted_bytes and not session.exists()
    code, events = extract(session, encrypted, password='incorrect')
    assert code != 0 and events[-1]['event'] == 'wrongPassword', events
    assert encrypted.read_bytes() == encrypted_bytes and not session.exists()
    code, events = extract(session, encrypted, password='fixture-password')
    assert code == 0, events
    check_outputs(session, {secret.name: secret.read_bytes()})
    assert b'fixture-password' not in (session / 'manifest.json').read_bytes()
    assert not encrypted.exists()

    archive = sandbox / 'expansion.zip'
    zip_archive(archive, count=1)
    expanded = bytearray(archive.read_bytes())
    central = expanded.index(b'PK\x01\x02')
    struct.pack_into('<I', expanded, central + 24, 2 << 30)
    archive.write_bytes(expanded)
    code, events = extract(sandbox / 'session-expansion', archive)
    assert code != 0 and 'expansion limit' in events[-1]['message'], events
    assert archive.read_bytes() == expanded

    archive = sandbox / 'hardlinked.zip'
    zip_archive(archive)
    linked = sandbox / 'alias.zip'
    os.link(archive, linked)
    before = archive.read_bytes()
    code, events = extract(sandbox / 'session-hardlink', archive)
    assert code != 0, events
    assert archive.read_bytes() == before == linked.read_bytes()

    archive = sandbox / 'missing.zip.001'
    archive.write_bytes(archive_bytes[:width])
    (sandbox / 'missing.zip.003').write_bytes(archive_bytes[2 * width:])
    before = archive.read_bytes()
    code, events = extract(sandbox / 'session-missing-volume', archive)
    assert code != 0, events
    assert archive.read_bytes() == before

    archive = sandbox / 'pause.zip'
    expected = zip_archive(archive, count=2000)
    session = sandbox / 'session-pause'
    code, events = extract(session, archive, pause=True, pause_after=0.3)
    assert code == 0 and events[-1]['event'] == 'paused', events[-3:]
    assert archive.exists()
    journal = json.loads((session / 'journal.json').read_text())
    assert journal['committed_len'] < sum(length for _, length in journal['parts'])
    expected_hashes = {name: hashlib.sha256(content).digest() for name, content in expected.items()}
    manifest = json.loads((session / 'manifest.json').read_text())
    partial_output = Path(manifest['output'])
    recovery_hashes = {path.relative_to(session): hashlib.sha256(path.read_bytes()).digest()
                       for path in session.rglob('*') if path.is_file()}
    partial_hashes = {path.relative_to(partial_output): hashlib.sha256(path.read_bytes()).digest()
                      for path in partial_output.rglob('*') if path.is_file()}
    moved_archive = sandbox / 'moved-pause.zip'
    archive.rename(moved_archive)
    remaining_hash = hashlib.sha256(moved_archive.read_bytes()).digest()
    code, events = extract(session)
    assert code != 0 and 'remaining archive is missing' in events[-1]['message'], events[-3:]
    assert hashlib.sha256(moved_archive.read_bytes()).digest() == remaining_hash
    assert recovery_hashes == {path.relative_to(session): hashlib.sha256(path.read_bytes()).digest()
                               for path in session.rglob('*') if path.is_file()}
    assert partial_hashes == {path.relative_to(partial_output): hashlib.sha256(path.read_bytes()).digest()
                              for path in partial_output.rglob('*') if path.is_file()}
    moved_archive.rename(archive)
    code, events = extract(session)
    assert code == 0, events
    output = check_outputs(session, expected)
    assert all(hashlib.sha256((output / name).read_bytes()).digest() == digest
               for name, digest in expected_hashes.items())
    assert not archive.exists()

    archive = sandbox / 'tampered.zip'
    zip_archive(archive, count=2000)
    session = sandbox / 'session-tampered'
    code, events = extract(session, archive, pause=True)
    assert code == 0 and events[-1]['event'] == 'paused', events[-3:]
    manifest = json.loads((session / 'manifest.json').read_text())
    original_manifest = dict(manifest)
    outside = sandbox / 'outside'
    outside.mkdir()
    sentinel = outside / 'keep.txt'
    sentinel.write_bytes(b'existing user file')
    manifest['output'] = str(outside)
    (session / 'manifest.json').write_text(json.dumps(manifest))
    before = archive.read_bytes()
    code, events = extract(session)
    assert code != 0 and 'directory has changed' in events[-1]['message'], events[-3:]
    assert sentinel.read_bytes() == b'existing user file' and archive.read_bytes() == before
    (session / 'manifest.json').write_text(json.dumps(original_manifest))
    journal_path = session / 'journal.json'
    original_journal = journal_path.read_bytes()
    journal = json.loads(original_journal)
    journal['output'] = str(outside)
    journal_path.write_text(json.dumps(journal))
    code, events = extract(session)
    assert code != 0 and 'journal does not match' in events[-1]['message'], events[-3:]
    assert sentinel.read_bytes() == b'existing user file' and archive.read_bytes() == before
    journal_path.write_bytes(original_journal)
    replacement = sandbox / 'replacement.zip'
    replacement.write_bytes(before)
    replacement.replace(archive)
    code, events = extract(session)
    assert code != 0 and 'volume has changed' in events[-1]['message'], events[-3:]
    assert archive.read_bytes() == before

    if os.environ.get('MACEASE_HATCH_SPACE_TEST') == '1':
        image = sandbox / 'limited-space.sparseimage'
        mount = sandbox / 'limited-space'
        mount.mkdir()
        subprocess.run(['/usr/bin/hdiutil', 'create', '-quiet', '-size', '512m', '-fs', 'APFS', '-type', 'SPARSE', str(image)], check=True)
        subprocess.run(['/usr/bin/hdiutil', 'attach', '-quiet', '-nobrowse', '-mountpoint', str(mount), str(image)], check=True)
        try:
            archive = mount / 'space.zip'
            payload = bytes(range(256)) * 512
            total = 2048 * len(payload)
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as writer:
                for index in range(2048):
                    writer.writestr(f'payload-{index}.bin', payload)
            original_hash = hashlib.sha256(archive.read_bytes()).digest()
            filler = mount / 'reserved-space.bin'
            requested = max(0, shutil.disk_usage(mount).free - 60 * 1024 * 1024)
            with filler.open('wb') as writer:
                block = bytes(1024 * 1024)
                remaining = requested
                while remaining:
                    count = min(remaining, len(block))
                    writer.write(block[:count])
                    remaining -= count
                writer.flush()
                os.fsync(writer.fileno())
            session = sandbox / 'session-space-rejected'
            code, events = extract(session, archive)
            assert code != 0 and 'Insufficient' in events[-1]['message'], events[-3:]
            assert hashlib.sha256(archive.read_bytes()).digest() == original_hash and not session.exists()
            with filler.open('r+b') as writer:
                writer.truncate(max(0, requested - 100 * 1024 * 1024))
                writer.flush()
                os.fsync(writer.fileno())
            available = shutil.disk_usage(mount).free
            assert available < total, (available, total)
            session = sandbox / 'session-space-success'
            code, events = extract(session, archive)
            assert code == 0, events[-3:]
            manifest = json.loads((session / 'manifest.json').read_text())
            output = Path(manifest['output'])
            for index in range(2048):
                assert (output / f'payload-{index}.bin').read_bytes() == payload
            assert not archive.exists()
            print(f'Constrained APFS proof: {available} bytes free for {total} bytes output; refused at 60 MiB, succeeded after freeing 100 MiB.')
        finally:
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)

    if os.environ.get('MACEASE_HATCH_CRASH_TEST') == '1':
        archive = sandbox / 'crash.zip'
        expected = zip_archive(archive, count=700)
        session = sandbox / 'session-crash'
        subprocess.run(['xattr', '-w', 'com.apple.quarantine', '0081;00000000;MacEaseCrashTest;', str(archive)], check=True)
        environment = dict(os.environ, HATCHZIP_CRASH_AT='after-journal')
        code, events = extract(session, archive, environment=environment)
        assert code != 0, events[-3:]
        assert (session / 'journal.json').exists()
        crash_output = Path(json.loads((session / 'manifest.json').read_text())['output'])
        for output_file in [crash_output, *crash_output.rglob('*')]:
            assert subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', str(output_file)]).rstrip(b'\n') == b'0081;00000000;MacEaseCrashTest;'
        code, events = extract(session)
        assert code == 0, events
        check_outputs(session, expected)
        assert not archive.exists()
        for checkpoint in ['stream-after-journal', 'stream-after-punch']:
            archive = sandbox / f'{checkpoint}.tar.gz'
            expected = {f'payload-{index}.bin': os.urandom(150000) for index in range(8)}
            with tarfile.open(archive, 'w:gz') as writer:
                for name, content in expected.items():
                    header = tarfile.TarInfo(name)
                    header.size = len(content)
                    writer.addfile(header, io.BytesIO(content))
            subprocess.run(['xattr', '-w', 'com.apple.quarantine', '0081;00000000;MacEaseCrashTest;', str(archive)], check=True)
            session = sandbox / f'session-{checkpoint}'
            environment = dict(os.environ, HATCHZIP_CRASH_AT=checkpoint, HATCHZIP_STREAM_STEP='65536')
            code, events = extract(session, archive, environment=environment)
            assert code != 0, events[-3:]
            journal = json.loads((session / 'journal.json').read_text())
            assert journal['resume'] is not None
            crash_output = Path(json.loads((session / 'manifest.json').read_text())['output'])
            for output_file in [crash_output, *crash_output.rglob('*')]:
                assert subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', str(output_file)]).rstrip(b'\n') == b'0081;00000000;MacEaseCrashTest;'
            code, events = extract(session)
            assert code == 0, events
            check_outputs(session, expected)
            assert not archive.exists()

print('HatchZip extraction, quarantine, strict paths, source protection, split volumes and pause/resume passed.')
