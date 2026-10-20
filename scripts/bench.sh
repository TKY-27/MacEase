#!/bin/sh
# Release-build benchmarks for the SPEC section 16 targets; not run in CI.
set -eu
cd "$(dirname "$0")/.."
swift run -c release --package-path Packages/MacEaseKit Benchmarks
