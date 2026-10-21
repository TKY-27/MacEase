#!/bin/sh
# Benchmarks need release optimizations.
set -eu
cd "$(dirname "$0")/.."
swift run -c release --package-path Packages/MacEaseKit Benchmarks "$@"
