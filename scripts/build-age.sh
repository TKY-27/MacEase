#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$repository/Vendor/build/macease-age"
mkdir -p "$(dirname "$destination")"
cd "$repository/Vendor/AgeBridge"
GOTOOLCHAIN=local CGO_ENABLED=0 go build -mod=readonly -trimpath -buildvcs=false -o "$destination" .
