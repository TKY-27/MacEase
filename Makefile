PROJECT := MacEase.xcodeproj
SCHEME := MacEase
DERIVED_DATA := build/DerivedData
PACKAGE := Packages/MacEaseKit
MEDIA_TOOLS := $(CURDIR)/Vendor/build/media-tools/bin
SOURCES := App AppTests FinderSync Packages
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	-derivedDataPath $(DERIVED_DATA)

.PHONY: bootstrap deps media-tools project build test test-app test-device lint format dmg

bootstrap:
	brew list xcodegen cmake meson ninja pkg-config >/dev/null 2>&1 || brew install xcodegen cmake meson ninja pkg-config
	command -v cargo >/dev/null 2>&1 || brew install rust
	scripts/build-media-tools.sh
	scripts/build-deps.sh
	xcodegen generate

deps:
	scripts/build-media-tools.sh
	scripts/build-deps.sh

media-tools:
	scripts/build-media-tools.sh

project:
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Debug build

test:
	MACEASE_MEDIA_TOOLS="$(MEDIA_TOOLS)" swift test --package-path $(PACKAGE)

test-app: project
	$(XCODEBUILD) -configuration Debug test

# Missing capabilities fail here instead of skipping.
test-device: build
	MACEASE_DEVICE_TESTS=1 MACEASE_MEDIA_TOOLS="$(MEDIA_TOOLS)" swift test --package-path $(PACKAGE)
	$(MAKE) test-app

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format format --in-place --recursive $(SOURCES)

dmg:
	scripts/make-dmg.sh
