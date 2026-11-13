# Offline audio enhancement

MacEase launches native sherpa-onnx 2.0.1 executables, with ONNX Runtime 1.28.2.
No Python, TensorFlow, network request or model download occurs during inference.
The app's source remains MIT. Models and third-party programs retain their own
licenses. SPEC section 24.3 owns the product requirements.

## Build and packaging

Run `scripts/build-ai-audio.sh` on arm64 macOS with Python 3.11. The optional
`MACEASE_AI_BUILD_PYTHON` selects the build interpreter. The script verifies every
download against `Vendor/ai-audio.lock` before using it. Its private environment
uses pinned, hash-verified ONNX 1.17.0, NumPy 1.26.4 and protobuf 7.36.2 wheels.
These build dependencies are not distributed with the app.

The output is `Vendor/build/ai-audio`. Package that entire directory as
`Contents/Resources/ai-audio`, preserving the `bin`/`lib` relationship. Sign the
executables and dylib during normal nested-code signing. Include the notices,
model validation report, manifest and `sources/eigen-5.0.1.tar.gz`. Eigen's
corresponding source is included because its compiled headers use MPL 2.0.
The parent packaging workflow owns copying and signing these resources.

The shipped programs are `sherpa-onnx-offline-denoiser` and
`sherpa-onnx-offline-source-separation`. `otool -L` identifies only one
non-system dynamic dependency: `libonnxruntime.dylib`. Unneeded sherpa C/C++ API
dylibs, microphone programs, headers and Python are not shipped.
`manifest.json` records pre-signing SHA-256 for every binary, model, notice and
corresponding-source archive. Signing changes binary hashes; the release workflow
must separately verify the signed bundle while retaining upstream provenance.
`runtimeComponents` identifies the program and library licenses and source revisions.

## Models and licenses

| Component | License and evidence |
| --- | --- |
| sherpa-onnx 2.0.1 | Apache 2.0; source commit `af2d8d81dbfa61c4cea4c568da78f3982edca005` |
| ONNX Runtime 1.28.2 | MIT; full upstream ThirdPartyNotices.txt accompanies the dylib |
| GTCRN | MIT; author explicitly includes pretrained ONNX weights and commercial redistribution in issue 104 |
| Spleeter 2stems | MIT; Deezer's JOSS paper explicitly includes source and pretrained models |
| Static dependencies | Notices include kaldi-native-fbank, kaldi-decoder, simple-sentencepiece, utf8proc, nlohmann/json, Eigen and KISS FFT |

Primary references:
[sherpa source](https://github.com/k2-fsa/sherpa-onnx/tree/af2d8d81dbfa61c4cea4c568da78f3982edca005),
[ONNX Runtime](https://github.com/microsoft/onnxruntime/tree/v1.28.2),
[GTCRN author's grant](https://github.com/Xiaobin-Rong/gtcrn/issues/104), and
[Deezer paper, page 3](https://joss.theoj.org/papers/10.21105/joss.02154.pdf).
Copies and their hashes are pinned in the lock file.

GTCRN's sherpa-compatible model is 535,638 bytes, SHA-256
`e77603ac0c23dac3227dd2d7135b3a585cbee2679048aecfa886657d3ae1b534`.
The unmodified runtime archive is 18,663,994 bytes, SHA-256
`4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79`.
GitHub release asset 678782072 reports this same digest. The executable's
version command independently reports sherpa commit `af2d8d81` and ORT 1.28.2.

## Spleeter provenance and correction

Do not use the FP16 release: ONNX's standard checker rejects its node order.
The selected FP32 archive is official release asset 257363376, uploaded on
2025-05-23, 74,682,545 bytes. The release API exposes no asset digest.
Its actual SHA-256 is
`e26401d9c1801f43c0229731d78d32c2e80085e3aceedeb25f29d2de5fa68ca2`.
The release's checksum.txt instead advertises
`69b43d35b4cfed03b14c3da6bc64b1cd9e2f75a993f064d953e83d98747828c7`.
This archive/index inconsistency is real; its historical cause is not established.

Adoption therefore requires an independent comparison with Deezer's original
v1.4.0 `2stems.tar.gz`. That original archive matches its published SHA-256,
`f3a90b39dd2874269e8b05a48a86745df897b848c61f3958efc80a39152bd692`.
The build reads its uncompressed TensorBundle index using the published
[table format](https://github.com/google/leveldb/blob/main/doc/table_format.md)
and [BundleEntryProto](https://github.com/tensorflow/tensorflow/blob/v2.21.0/tensorflow/core/protobuf/tensor_bundle.proto).
It compares all 70 parameter/state arrays per stem against the ONNX model,
including the necessary convolution-axis permutation and identity aliases.
Every array must match exactly. No TensorFlow installation is required.

The source configuration requires 44,100 Hz, FFT length 4096, hop 1024,
512 time frames and 1024 frequency bins. The ONNX input graph agrees with
those dimensions, but incorrectly declares sample_rate=41000 in metadata.
The build changes only that metadata to 44100; serialized graph bytes and all
weights remain unchanged. Standard ONNX checking and the independent
checkpoint comparison must pass before `spleeter-verified.json` is written.

The native reference fixture contains 104,517 stereo frames at 44,100 Hz,
with independent 440/880 Hz tones. Observed native output: 104,448 frames,
439.952895/879.905790 Hz peaks. The script repeats these decoded checks on
every build and records actual results, graph hashes and repaired-model hashes.
The CLI truncates to its STFT grid. The engine supplies finite padding and
copies exactly the requested output frames, rather than accepting missing tails.

## Engine contract

`AudioEnhancement(directory:tools:)` supports explicit runtime locations for
development. Production defaults resolve bundled resources.
`makeBatch(source:mode:)` returns a `.audioEnhance` Batch containing a validated
WorkItem. Both modes always return `.derived`, regardless of Replace settings.
All subprocesses use the existing MediaToolProcess and MediaDownloadTools.
FFmpeg only decodes, resamples, downmixes and pads these AI inputs.

| Mode | Input limit | Output |
| --- | --- | --- |
| speech | 600 seconds; mono or stereo | Explicit mono downmix, GTCRN speech cleanup, one 16 kHz WAV |
| stems | 300 seconds; mono or stereo | Both vocals and instrumental, stereo 44.1 kHz WAV |

Multichannel input, missing models, unknown duration and excess duration fail
explicitly. The panel discloses speech downmixing before submission. Outputs
use 32-bit float WAV, but the official native CLI writes 16-bit intermediates;
this container choice does not restore discarded precision. Tags are not copied.
The original file stays untouched. Playback never starts automatically.

Inference runs on CPU with one thread, in ten-second segments with one second
of context on either side. WAV assembly uses an 8192-frame buffer. Neural
workspace depends on the bounded segment, not total song length. Cancellation
uses existing subprocess termination and JobEngine staging cleanup. Generic
commit verification, collision handling and history remain authoritative.

## Verification

Run only the focused subsystem tests with the rebuilt media runtime:

```sh
MACEASE_MEDIA_TOOLS="$PWD/Vendor/build/media-tools/bin" \
  swift test --package-path Packages/MacEaseKit --filter AudioEnhancementTests
```

The tests execute real native inference and FFmpeg, validate decoded format,
frame counts and stereo tone frequencies across a segment boundary, reject
over-limit files, and cancel active inference while verifying staging cleanup
and original retention. Synthetic tones prove timing and channel contracts,
not perceptual denoising or separation quality. Native GUI interaction,
macOS 26 execution and final signed-bundle verification are separate checks.
