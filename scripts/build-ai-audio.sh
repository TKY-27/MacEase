#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python="${MACEASE_AI_BUILD_PYTHON:-python3.11}"
[[ "$(uname -m)" == arm64 ]] || { echo "error: arm64 host required" >&2; exit 1; }
"$python" -I -B - "$root" <<'PY'
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import venv

root = pathlib.Path(sys.argv[1])
lock = json.loads((root / "Vendor/ai-audio.lock").read_text())
cache = root / "Vendor/src/ai-audio"
work = root / "Vendor/build/ai-audio-work"
runtime = root / "Vendor/build/ai-audio"
for directory in (cache, work, runtime / "bin", runtime / "lib", runtime / "models", runtime / "licenses"):
    directory.mkdir(parents=True, exist_ok=True)
for entry in lock["assets"]:
    archive = cache / entry["name"]
    if not archive.exists():
        with urllib.request.urlopen(entry["url"], timeout=60) as response, archive.with_suffix(".part").open("wb") as target:
            shutil.copyfileobj(response, target)
        archive.with_suffix(".part").rename(archive)
    if hashlib.file_digest(archive.open("rb"), "sha256").hexdigest() != entry["sha256"]:
        raise RuntimeError("Checksum mismatch: " + entry["name"])
    if entry["name"].endswith(("LICENSE.txt", "Notices.txt")):
        shutil.copy2(archive, runtime / "licenses" / entry["name"])

for name in ("models/spleeter-verified.json", "manifest.json"):
    (runtime / name).unlink(missing_ok=True)
corresponding_source = runtime / "sources"
corresponding_source.mkdir(exist_ok=True)
for entry in lock["assets"]:
    if entry.get("purpose") == "corresponding-source":
        shutil.copy2(cache / entry["name"], corresponding_source / entry["name"])

archive = cache / "sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts.tar.bz2"
with tarfile.open(archive) as source:
    source.extractall(work, filter="data")
upstream = work / "sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts"
for name in ("sherpa-onnx-offline-denoiser", "sherpa-onnx-offline-source-separation"):
    shutil.copy2(upstream / "bin" / name, runtime / "bin" / name)
shutil.copy2(upstream / "lib/libonnxruntime.dylib", runtime / "lib/libonnxruntime.dylib")
shutil.copy2(cache / "gtcrn.onnx", runtime / "models/gtcrn.onnx")
with tarfile.open(cache / "sherpa-onnx-spleeter-2stems.tar.bz2") as source:
    source.extractall(work, filter="data")
build_python = work / "venv/bin/python"
if not build_python.exists():
    venv.create(work / "venv", with_pip=True)
subprocess.run([str(build_python), "-m", "pip", "install", "--no-index", "--no-deps",
                *[str(cache / entry["name"]) for entry in lock["assets"] if entry.get("purpose") == "build-only"]], check=True)
subprocess.run([str(build_python), "-I", "-B", "-c", r'''
import hashlib, json, pathlib, re, struct, subprocess, sys, tarfile, wave
import numpy as np
import onnx
root = pathlib.Path(sys.argv[1])
work = root / 'Vendor/build/ai-audio-work'
runtime = root / 'Vendor/build/ai-audio'
config = json.loads((root / 'Vendor/src/ai-audio/spleeter-source-config.json').read_text())
assert (config['sample_rate'], config['frame_length'], config['frame_step'], config['T'], config['F']) == (44100, 4096, 1024, 512, 1024)
graphs = {}
for label in ('vocals', 'accompaniment'):
    source = work / 'sherpa-onnx-spleeter-2stems' / (label + '.onnx')
    model = onnx.load(source)
    onnx.checker.check_model(model)
    graph = model.graph.SerializeToString()
    shape = model.graph.input[0].type.tensor_type.shape.dim
    assert [shape[i].dim_value for i in (0, 2, 3)] == [2, 512, 1024]
    rate = next((prop for prop in model.metadata_props if prop.key == 'sample_rate'))
    assert rate.value == '41000'
    rate.value = '44100'
    assert model.graph.SerializeToString() == graph
    destination = runtime / 'models' / (label + '.onnx')
    onnx.save(model, destination)
    graphs[label] = {'graph_sha256': hashlib.sha256(graph).hexdigest(), 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}

def varint(b, p):
    value = 0
    shift = 0
    while True:
        byte = b[p]
        p += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return (value, p)
        shift += 7

def entries(block):
    end = len(block) - 4 - 4 * struct.unpack('<I', block[-4:])[0]
    p = 0
    previous = b''
    while p < end:
        shared, p = varint(block, p)
        new, p = varint(block, p)
        length, p = varint(block, p)
        key = previous[:shared] + block[p:p + new]
        p += new
        value = block[p:p + length]
        p += length
        previous = key
        yield (key, value)

def fields(b):
    p = 0
    while p < len(b):
        tag, p = varint(b, p)
        wire = tag & 7
        if wire == 0:
            value, p = varint(b, p)
        elif wire == 1:
            value = b[p:p + 8]
            p += 8
        elif wire == 2:
            size, p = varint(b, p)
            value = b[p:p + size]
            p += size
        elif wire == 5:
            value = b[p:p + 4]
            p += 4
        else:
            raise ValueError(wire)
        yield (tag >> 3, value)
with tarfile.open(root / 'Vendor/src/ai-audio/spleeter-original-2stems.tar.gz') as archive:
    index = archive.extractfile('model.index').read()
    weights = archive.extractfile('model.data-00000-of-00001').read()
    p = len(index) - 48
    _, p = varint(index, p)
    _, p = varint(index, p)
    offset, p = varint(index, p)
    size, p = varint(index, p)
    records = {}
    for key, handle in entries(index[offset:offset + size]):
        offset, p = varint(handle, 0)
        size, p = varint(handle, p)
        assert index[offset + size] == 0
        records.update(entries(index[offset:offset + size]))

def tensor(name):
    record = dict(fields(records[name.encode()]))
    assert record[1] == 1 and record.get(3, 0) == 0
    shape = [dict(fields(value))[1] for n, value in fields(record[2]) if n == 2]
    begin = record.get(4, 0)
    size = record[5]
    return np.frombuffer(weights[begin:begin + size], dtype='<f4').reshape(shape)
matched = {}
for label, offset in [('vocals', 0), ('accompaniment', 7)]:
    model = onnx.load(runtime / 'models' / (label + '.onnx'))
    parameters = {x.name: onnx.numpy_helper.to_array(x) for x in model.graph.initializer}
    for node in model.graph.node:
        if node.op_type == 'Identity' and node.input[0] in parameters:
            parameters[node.output[0]] = parameters[node.input[0]]
    count = 0
    for name, actual in parameters.items():
        layer, part = name.split('.')
        number = int(re.search('\\d+', layer)[0]) if re.search('\\d+', layer) else 0
        if layer.startswith('conv'):
            index = number + offset
            scope = 'conv2d' + ('_' + str(index) if index else '')
        elif layer.startswith('up'):
            if number == 7:
                scope = 'conv2d_' + str(6 + offset)
            else:
                index = number - 1 + (6 if label == 'accompaniment' else 0)
                scope = 'conv2d_transpose' + ('_' + str(index) if index else '')
        elif layer.startswith('bn'):
            index = number + (1 if number >= 5 else 0) + (12 if label == 'accompaniment' else 0)
            scope = 'batch_normalization' + ('_' + str(index) if index else '')
        else:
            raise ValueError(name)
        suffix = ({'weight': 'gamma', 'bias': 'beta', 'running_mean': 'moving_mean', 'running_var': 'moving_variance'} if layer.startswith('bn') else {'weight': 'kernel', 'bias': 'bias'})[part]
        expected = tensor(scope + '/' + suffix)
        if not layer.startswith('bn') and part == 'weight':
            expected = expected.transpose(3, 2, 0, 1)
        assert np.array_equal(actual, expected), (label, name, actual.shape, expected.shape, float(np.max(np.abs(actual - expected))))
        count += 1
    matched[label] = count
rate = 44100
frames = 104517
clock = np.arange(frames) / rate
samples = np.column_stack((np.sin(2 * np.pi * 440 * clock), np.sin(2 * np.pi * 880 * clock))) * 0.2
fixture = work / 'reference.wav'
with wave.open(str(fixture), 'wb') as writer:
    writer.setparams((2, 2, rate, frames, 'NONE', 'not compressed'))
    writer.writeframes((samples * 32767).astype('<i2').tobytes())
outputs = [work / 'reference-vocals.wav', work / 'reference-accompaniment.wav']
subprocess.run([str(runtime / 'bin/sherpa-onnx-offline-source-separation'), '--spleeter-vocals=' + str(runtime / 'models/vocals.onnx'), '--spleeter-accompaniment=' + str(runtime / 'models/accompaniment.onnx'), '--num-threads=1', '--input-wav=' + str(fixture), '--output-vocals-wav=' + str(outputs[0]), '--output-accompaniment-wav=' + str(outputs[1])], check=True)
decoded = []
for output in outputs:
    with wave.open(str(output), 'rb') as reader:
        assert (reader.getframerate(), reader.getnchannels(), reader.getsampwidth()) == (rate, 2, 2)
        decoded.append(np.frombuffer(reader.readframes(reader.getnframes()), dtype='<i2').reshape(-1, 2).astype(np.float64))
assert decoded[0].shape == decoded[1].shape
assert abs(len(decoded[0]) - frames) <= 1024
mixture = decoded[0] + decoded[1]
frequencies = []
for channel, expected in enumerate((440, 880)):
    spectrum = np.abs(np.fft.rfft(mixture[:, channel] * np.hanning(len(mixture))))
    frequency = float(np.argmax(spectrum) * rate / len(mixture))
    assert abs(frequency - expected) < 2, (frequency, expected)
    frequencies.append(frequency)
report = {'source_sample_rate': rate, 'input_frames': frames, 'output_frames': len(mixture), 'peak_frequencies_hz': frequencies, 'models': graphs, 'original_checkpoint_arrays_matched': matched}
(runtime / 'models/spleeter-verified.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

''', str(root)], check=True)
bundled = {}
for directory in (runtime / "bin", runtime / "lib", runtime / "models", runtime / "licenses", corresponding_source):
    for path in sorted(directory.iterdir()):
        if path.is_file():
            bundled[str(path.relative_to(runtime))] = hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
notices = runtime / "THIRD_PARTY_NOTICES.txt"
notices.write_text("\n\n".join(path.read_text() for path in sorted((runtime / "licenses").iterdir())))
bundled[notices.name] = hashlib.file_digest(notices.open("rb"), "sha256").hexdigest()
(runtime / "manifest.json").write_text(json.dumps({"inputs": lock, "bundled_sha256": bundled}, indent=2) + "\n")
print("Wrote " + str(runtime))
PY
