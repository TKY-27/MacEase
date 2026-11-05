#!/bin/sh
# Benchmarks need release optimizations.
set -eu
cd "$(dirname "$0")/.."
MACEASE_MEDIA_TOOLS="$PWD/Vendor/build/media-tools/bin" swift run -c release --package-path Packages/MacEaseKit Benchmarks "$@"
