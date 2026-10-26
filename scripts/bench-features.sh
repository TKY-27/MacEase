#!/bin/sh
set -eu
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 baseline-binary candidate-binary fixtures-directory results-directory" >&2
    exit 1
fi
baseline=$1
candidate=$2
fixtures=$3
results=$4
[ -x "$baseline" ] && [ -x "$candidate" ]
[ -f "$fixtures/logo.png" ] && [ -f "$fixtures/shapes.png" ] && [ -f "$fixtures/browser.zip" ]
mkdir "$results"
{
    date -u
    sw_vers
    uname -m
    sysctl -n machdep.cpu.brand_string hw.ncpu
    uptime
    shasum -a 256 "$baseline" "$candidate" "$fixtures/logo.png" "$fixtures/shapes.png" "$fixtures/browser.zip"
} > "$results/environment.txt"
runs=0
measure() {
    label=$1
    shift
    if ! /usr/bin/time -l "$@" > "$results/$label.stdout" 2> "$results/$label.time"; then
        printf 'Failed run=%s errors=1\n' "$label" >&2
        exit 1
    fi
    runs=$((runs + 1))
}
for iteration in 1 2 3 4 5; do
    for fixture in logo shapes; do
        measure "$fixture-baseline-$iteration" "$baseline" image.convert "$fixtures/$fixture.png" svg
        measure "$fixture-candidate-$iteration" "$candidate" image.convert "$fixtures/$fixture.png" svg
    done
done
for iteration in 1 2 3 4 5; do
    for fixture in logo shapes; do
        measure "$fixture-prepare-$iteration" "$candidate" feature.svg "$fixtures/$fixture.png" 8 standard
    done
    measure "zip-$iteration" "$candidate" feature.zip "$fixtures/browser.zip" selected.txt
done
printf 'Completed runs=%s errors=0\n' "$runs" | tee "$results/completed.txt"
