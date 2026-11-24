import gzip
import io
import pathlib
import struct
import sys
import tarfile
import zlib
import zipfile

source = pathlib.Path(sys.argv[1])
variant = sys.argv[2]
comment_length = int(sys.argv[3])
cp932 = lambda name: name.encode('cp932')
utf8 = lambda name: name.encode('utf-8')
first = b'FIRST'
second = b'SECOND'
entries = []
if variant == 'nested-zip':
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        archive.writestr('file.txt', b'nested payload')
    entries = [(b'nested.zip', buffer.getvalue(), 0)]
elif variant == 'directory-metadata':
    entries = [(b'folder/child.txt', first, 0), (b'folder/', b'', 0)]
elif variant == 'duplicate-cp932':
    entries = [(bytes.fromhex('8754') + b'.txt', first, 0), (bytes.fromhex('fa4a') + b'.txt', second, 0)]
elif variant == 'mixed-names':
    entries = [(utf8('資料.txt'), first, 0x800), (cp932('資料.txt'), second, 0)]
elif variant == 'case':
    entries = [(b'Readme.txt', first, 0), (b'readme.txt', second, 0), (cp932('資料.txt'), b'JP', 0)]
elif variant == 'directory-case':
    entries = [(b'Folder/first.txt', first, 0), (b'folder/second.txt', second, 0), (cp932('資料.txt'), b'JP', 0)]
elif variant == 'normalization':
    entries = [(utf8('が.txt'), first, 0x800), (utf8('か\u3099.txt'), second, 0x800), (cp932('資料.txt'), b'JP', 0)]
elif variant in ['utf8-flag', 'bad-unicode']:
    entries = [(cp932('資料.txt'), first, 0x800 if variant == 'utf8-flag' else 0)]
elif variant in ['symlink', 'zip64-symlink']:
    entries = [(cp932('別名'), cp932('資料.txt'), 0)]
elif variant == 'dos-file':
    entries = [(cp932('資料.txt'), bytes(70 * 1024), 0)]
elif variant in ['large-utf8-tar', 'large-cp932-tar', 'large-cp932-invalid-tar']:
    with tarfile.open(source, 'w:gz', format=tarfile.USTAR_FORMAT, encoding='cp932') as archive:
        name = '資料.txt' if variant != 'large-utf8-tar' else 'first.txt'
        entry = tarfile.TarInfo(name)
        entry.size = len(first)
        archive.addfile(entry, io.BytesIO(first))
        for _ in range(100000):
            directory = tarfile.TarInfo('folder/')
            directory.type = tarfile.DIRTYPE
            archive.addfile(directory)
        if variant == 'large-cp932-invalid-tar':
            header = bytearray(tarfile.TarInfo('bad').tobuf())
            header[:100] = b'bad\x82.txt'.ljust(100, b'\0')
            header[148:156] = b' ' * 8
            header[148:156] = ('%06o' % sum(header)).encode() + b'\0 '
            archive.fileobj.write(header)
        else:
            final = tarfile.TarInfo('last.txt')
            final.size = len(second)
            archive.addfile(final, io.BytesIO(second))
    sys.exit(0)
else:
    entries = [(cp932('資料.txt'), first, 0)]

if source.suffix in ['.tar', '.gz']:
    serialized = bytearray()
    for name, payload, flags in entries:
        declaration = tarfile.TarInfo('placeholder')
        if variant == 'directory-metadata' and name.endswith(b'/'):
            declaration.type = tarfile.DIRTYPE
            declaration.mode = 0o700
            declaration.mtime = 1234567890
        header = bytearray(declaration.tobuf(format=tarfile.USTAR_FORMAT))
        header[:100] = name.ljust(100, b'\0')
        header[124:136] = ('%011o' % len(payload)).encode() + b'\0'
        header[148:156] = b' ' * 8
        header[148:156] = ('%06o' % sum(header)).encode() + b'\0 '
        serialized += header + payload + bytes((-len(payload)) % 512)
    serialized += bytes(1024)
    source.write_bytes(gzip.compress(serialized) if source.suffix == '.gz' else serialized)
    with tarfile.open(source, 'r:*', encoding='utf-8', errors='surrogateescape') as verified:
        assert [entry.name.encode('utf-8', errors='surrogateescape').rstrip(b'/') for entry in verified] == [name.rstrip(b'/') for name, _, _ in entries]
    sys.exit(0)

local = bytearray()
central = bytearray()
for name, payload, flags in entries:
    checksum = zlib.crc32(payload)
    extra = b''
    unix = variant in ['symlink', 'zip64-symlink']
    size = len(payload)
    size_field = 0xffffffff if variant == 'zip64-symlink' else size
    if variant == 'bad-unicode':
        field = b'\x01' + struct.pack('<I', zlib.crc32(name)) + cp932('表.txt')
        extra = struct.pack('<HH', 0x7075, len(field)) + field
    if variant == 'zip64-symlink':
        extra = struct.pack('<HHQQ', 1, 16, size, size)
    offset = len(local)
    local += struct.pack('<IHHHHHIIIHH', 0x04034b50, 45 if variant == 'zip64-symlink' else 20, flags, 0, 0, 0, checksum, size_field, size_field, len(name), len(extra)) + name + extra + payload
    attributes = (0o120777 << 16) if unix or variant == 'dos-file' else 0
    central += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (3 << 8) | 45 if unix else 20, 45 if variant == 'zip64-symlink' else 20, flags, 0, 0, 0, checksum, size_field, size_field, len(name), len(extra), 0, 0, 0, attributes, offset) + name + extra
serialized = local + central
zip64 = variant in ['zip64-comment', 'zip64-symlink']
if zip64:
    record_offset = len(serialized)
    serialized += struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, len(entries), len(entries), len(central), len(local))
    serialized += struct.pack('<IIQI', 0x07064b50, 0, record_offset, 1)
serialized += struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0xffff if zip64 else len(entries), 0xffff if zip64 else len(entries), 0xffffffff if zip64 else len(central), 0xffffffff if zip64 else len(local), comment_length)
serialized += b'x' * comment_length
if variant == 'sfx':
    serialized = b'MZ' + bytes(62) + serialized
source.write_bytes(serialized)
