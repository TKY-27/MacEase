# Local 2× image upscaler

MacEase uses the [Swin2SR classical SR ×2 model](https://huggingface.co/caidas/swin2SR-classical-sr-x2-64) at revision `cee1c923c6a37361c6e5650b65dcf4be821e5d52`. Its model card identifies the model as Apache-2.0 and describes image super-resolution as its intended use. The card does not include a separate license file, so the build retrieves the [canonical Apache License 2.0 text](https://www.apache.org/licenses/LICENSE-2.0.txt). `Vendor/upscaler.lock` pins SHA-256 for the model card, configuration, preprocessor configuration, 48,460,660-byte weights and license text. MacEase's source remains MIT-licensed. The [Transformers implementation](https://github.com/huggingface/transformers/blob/main/src/transformers/models/swin2sr/modeling_swin2sr.py) is used only while converting the model; no Transformers or PyTorch code or Python runtime is distributed for this feature.

The build-only environment is created under `Vendor/build/upscaler-work`. Its exact pip freeze is recorded in `Vendor/upscaler.lock`; `scripts/build-upscaler.py` checks every installed version before building. Run:

```sh
scripts/build-upscaler.sh
```

The script fetches only the pinned revision, verifies every source hash, traces a fixed 64×64 RGB input, converts it to an ML program for macOS 26, checks a seeded numerical reference against PyTorch, compiles the package and writes `Vendor/build/upscaler/Swin2SR.mlmodelc`. On the current build, Core ML's 8-bit image output had mean absolute channel difference `0.000122` and maximum difference `1` from the rounded PyTorch output on a seeded 64×64 RGB tile. This is a conversion check, not a perceptual quality claim. The script stores a stamp and file-hash manifest; it verifies both before reusing a build. `--force` repeats conversion. A build needs network access to Hugging Face and Apache's license host. Inference does not access the network.

Bundle `Swin2SR.mlmodelc`, `MODEL_CARD.md` and `LICENSE-2.0.txt` from `Vendor/build/upscaler/` under the app's `Contents/Resources/upscaler/` directory. The compiled model measured about 51 MiB on the build machine. Keep the model card and license with the distribution and include their attribution in third-party notices. The package API also accepts a compiled model URL in `ImageEnhancement(modelURL:)`, allowing a package client to supply a locally installed model without shipping Python.

The native operation loads a display-oriented still through `ImageDocument`, rejects animation, multiple pages, HDR, transparency and greater-than-8-bit components, and converts accepted RGB to sRGB. It processes overlapping 64×64 tiles, retaining the central 48×48 region of each 2× output, checks cancellation between tiles and writes a new PNG through the existing staging and derived-output commit path. The original is preserved. Input is limited to 1,000,000 pixels (4,000,000 output pixels). The UI states the limit and unsupported formats. The model only changes image appearance and pixel dimensions; it does not recover ground-truth detail or establish image authenticity.

The Core ML conversion uses Apple's [image input/output guidance](https://apple.github.io/coremltools/docs-guides/source/image-inputs.html) and [ML program format](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html). The model is loaded with `MLModel(contentsOf:configuration:)` on macOS 26. `coremltools` 9 reported that Torch 2.9.1 is newer than its tested Torch range; conversion, compilation and the numerical check passed here. Release packaging and end-to-end app UI verification remain integration checks.

On an Apple M5 with 24 GB, 640×480 took 47.27 seconds and 1000×1000 took
134.42 seconds. The latter reached 1.33 GB resident memory and approximately
641 MB physical footprint. These measurements support the small-image scope;
they are not speed promises for other Macs. Oversized sources are disabled
in the panel and rejected by the engine. No implicit downscale is performed.
