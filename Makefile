PROJECT := MacEase.xcodeproj
SCHEME := MacEase
DERIVED_DATA := build/DerivedData
PACKAGE := Packages/MacEaseKit
SOURCES := App FinderSync Packages
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	-derivedDataPath $(DERIVED_DATA)

.PHONY: bootstrap deps project build test test-device lint format dmg

bootstrap:
	brew list xcodegen cmake meson ninja pkg-config >/dev/null 2>&1 || brew install xcodegen cmake meson ninja pkg-config
	scripts/build-deps.sh
	xcodegen generate

deps:
	scripts/build-deps.sh

project:
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Debug build

test:
	swift test --package-path $(PACKAGE)

# Missing capabilities fail here instead of skipping.
test-device: build
	MACEASE_DEVICE_TESTS=1 swift test --package-path $(PACKAGE)

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format format --in-place --recursive $(SOURCES)

dmg:
	scripts/make-dmg.sh
