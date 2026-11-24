import hashlib
import hmac
import io
import pathlib
import struct
import subprocess
import sys
import tarfile
import zipfile
import zlib

PASSWORD = b'fixture-password'
PAYLOAD = b'independent legacy archive payload'


def zipcrypto(plaintext, checksum):
    keys = [0x12345678, 0x23456789, 0x34567890]

    def update(byte):
        keys[0] = zlib.crc32(bytes([byte]), keys[0] ^ 0xffffffff) ^ 0xffffffff
        keys[1] = ((keys[1] + (keys[0] & 0xff)) * 134775813 + 1) & 0xffffffff
        keys[2] = zlib.crc32(bytes([keys[1] >> 24]), keys[2] ^ 0xffffffff) ^ 0xffffffff

    for byte in PASSWORD:
        update(byte)
    encrypted = bytearray()
    for byte in bytes(11) + bytes([checksum >> 24]) + plaintext:
        factor = keys[2] | 2
        encrypted.append(byte ^ (((factor * (factor ^ 1)) >> 8) & 0xff))
        update(byte)
    return bytes(encrypted)


def winzip_aes(plaintext, strength):
    key_bytes = {1: 16, 2: 24, 3: 32}[strength]
    salt = bytes(range(key_bytes // 2))
    derived = hashlib.pbkdf2_hmac('sha1', PASSWORD, salt, 1000, dklen=key_bytes * 2 + 2)
    counters = b''.join(index.to_bytes(16, 'little') for index in range(1, (len(plaintext) + 15) // 16 + 1))
    cipher = subprocess.run(['/usr/bin/openssl', 'enc', f'-aes-{key_bytes * 8}-ecb', '-K', derived[:key_bytes].hex(), '-nopad'], input=counters, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    encrypted = bytes(a ^ b for a, b in zip(plaintext, cipher))
    authentication = hmac.new(derived[key_bytes:key_bytes * 2], encrypted, hashlib.sha1).digest()[:10]
    return salt + derived[-2:] + encrypted + authentication


def write_zip(path, names, *, utf8=False, encryption=None, payload=PAYLOAD, symlink=False):
    local = bytearray()
    central = bytearray()
    for name in names:
        flags = (0x800 if utf8 else 0) | (1 if encryption else 0)
        checksum = zlib.crc32(payload)
        method = 0
        version = 20
        extras = b''
        compressed = payload
        if encryption == 'zipcrypto':
            compressed = zipcrypto(payload, checksum)
        elif encryption and encryption.startswith('aes'):
            strength = {'aes128': 1, 'aes192': 2, 'aes256': 3}[encryption]
            compressed = winzip_aes(payload, strength)
            extras = struct.pack('<HHH2sBH', 0x9901, 7, 2, b'AE', strength, 0)
            checksum = 0
            method = 99
            version = 51
        offset = len(local)
        local += struct.pack('<IHHHHHIIIHH', 0x04034b50, version, flags, method, 0, 0, checksum, len(compressed), len(payload), len(name), len(extras)) + name + extras + compressed
        central += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (3 << 8) | version if symlink else version, version, flags, method, 0, 0, checksum, len(compressed), len(payload), len(name), len(extras), 0, 0, 0, 0o120777 << 16 if symlink else 0, offset) + name + extras
    serialized = local + central
    count = min(len(names), 0xffff)
    if len(names) >= 0xffff:
        zip64_offset = len(serialized)
        serialized += struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, len(names), len(names), len(central), len(local))
        serialized += struct.pack('<IIQI', 0x07064b50, 0, zip64_offset, 1)
    serialized += struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, count, count, len(central), len(local), 0)
    path.write_bytes(serialized)
    if encryption == 'zipcrypto':
        with zipfile.ZipFile(path) as archive:
            assert all(archive.read(header, pwd=PASSWORD) == payload for header in archive.infolist())


def write_tar(path, names, *, encoding='cp932', compressed=False):
    with tarfile.open(path, 'w:gz' if compressed else 'w', format=tarfile.USTAR_FORMAT, encoding=encoding) as archive:
        for name in names:
            header = tarfile.TarInfo(name)
            header.size = len(PAYLOAD)
            archive.addfile(header, io.BytesIO(PAYLOAD))


def fixture(path, format_name, encoding, encryption, variant, size):
    names = ['日本語.txt'] if variant == 'flat' else ['資料/日本語.txt', '表.txt', 'ascii.txt']
    payload = PAYLOAD if size == 0 else bytes(size)
    if variant == 'legacy-link':
        write_zip(path, ['別名'.encode('cp932')], payload='資料.txt'.encode('cp932'), encryption=None if encryption == 'none' else encryption, symlink=True)
        return
    if format_name in ['tar', 'tar.gz']:
        write_tar(path, names, encoding='cp932' if encoding == 'cp932' else 'utf-8', compressed=format_name == 'tar.gz')
        return
    if variant == 'ambiguous':
        encoded = ['¢.txt'.encode('utf-8')]
    elif encoding == 'cp437':
        encoded = [bytes.fromhex('63 61 66 82 2e 74 78 74')]
    elif variant == 'mixed-invalid':
        encoded = ['資料.txt'.encode('cp932'), b'caf\x82.txt']
    elif variant in ['benchmark', 'over-budget']:
        encoded = [f'folder/entry-{index:06d}.txt'.encode('utf-8') for index in range(100001 if variant == 'over-budget' else 100000)]
        payload = b''
    elif variant == 'backslash':
        encoded = [('資料' + chr(92) + '日本語.txt').encode('cp932')]
    else:
        encoded = [name.encode('cp932' if encoding == 'cp932' else 'utf-8') for name in names]
    write_zip(path, encoded, utf8=encoding == 'utf8', encryption=None if encryption == 'none' else encryption, payload=payload)
    if variant == 'zip64':
        serialized = bytearray(path.read_bytes())
        central = serialized.index(b'PK\x01\x02')
        name_length = struct.unpack_from('<H', serialized, central + 28)[0]
        field = struct.pack('<HHQQQ', 1, 24, len(payload), len(payload), 0)
        struct.pack_into('<H', serialized, central + 6, 45)
        struct.pack_into('<I', serialized, central + 20, 0xffffffff)
        struct.pack_into('<I', serialized, central + 24, 0xffffffff)
        struct.pack_into('<I', serialized, central + 42, 0xffffffff)
        struct.pack_into('<H', serialized, central + 30, len(field))
        position = central + 46 + name_length
        serialized[position:position] = field
        end = len(serialized) - 22
        struct.pack_into('<I', serialized, end + 12, end - struct.unpack_from('<I', serialized, end + 16)[0])
        path.write_bytes(serialized)
    if variant == 'unsupported-method':
        serialized = bytearray(path.read_bytes())
        offset = 0
        while True:
            offset = serialized.find(b'PK\x01\x02', offset)
            if offset < 0:
                break
            struct.pack_into('<H', serialized, offset + 10, 9)
            offset += 4
        path.write_bytes(serialized)
    if variant == 'split':
        serialized = path.read_bytes()
        midpoint = len(serialized) // 2
        pathlib.Path(str(path) + '.001').write_bytes(serialized[:midpoint])
        pathlib.Path(str(path) + '.002').write_bytes(serialized[midpoint:])
        path.unlink()


if __name__ == '__main__':
    path = pathlib.Path(sys.argv[1])
    fixture(path, sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]))
