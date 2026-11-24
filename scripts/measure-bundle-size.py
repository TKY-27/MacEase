#!/usr/bin/env python3
import argparse
from collections import defaultdict
from pathlib import Path


def component(relative):
    parts = relative.parts
    if parts[:2] == ('Contents', 'MacOS'):
        return 'host'
    if parts[:3] != ('Contents', 'Resources', 'media-tools'):
        if parts[:3] == ('Contents', 'Resources', 'ai-audio'):
            return 'ai-models' if parts[3] == 'models' else 'ai-runtime'
        if parts[:3] == ('Contents', 'Resources', 'upscaler'):
            return 'upscaler'
        return 'other'
    if parts[3:5] in (('bin', 'node'), ('bin', 'qjs')):
        return 'javascript'
    if parts[3:5] == ('lib', 'python3.14') or (parts[3] == 'bin' and parts[4].startswith('python')):
        return 'python'
    if parts[3] == 'lib' or parts[3:5] in (('bin', 'ffmpeg'), ('bin', 'ffprobe')):
        return 'ffmpeg'
    return 'media-notices'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('dmg', type=Path, nargs='?')
    options = parser.parse_args()
    if not (options.app / 'Contents/Info.plist').is_file():
        parser.error('app must be an application bundle')
    totals = defaultdict(lambda: [0, 0])
    seen = set()
    for path in options.app.rglob('*'):
        if not path.is_file() and not path.is_symlink():
            continue
        stamp = path.lstat()
        identity = stamp.st_dev, stamp.st_ino
        if identity in seen:
            continue
        seen.add(identity)
        sizes = totals[component(path.relative_to(options.app))]
        sizes[0] += stamp.st_size
        sizes[1] += stamp.st_blocks * 512
    print('component\tfile_bytes\tallocated_bytes')
    for name, sizes in sorted(totals.items()):
        print(name, *sizes, sep='\t')
    print('app-total', *[sum(sizes[i] for sizes in totals.values()) for i in (0, 1)], sep='\t')
    if options.dmg:
        stamp = options.dmg.stat()
        print('dmg-total', stamp.st_size, stamp.st_blocks * 512, sep='\t')


if __name__ == '__main__':
    main()
