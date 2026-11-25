PROJECT := MacEase.xcodeproj
SCHEME := MacEase
DERIVED_DATA := build/DerivedData
PACKAGE := Packages/MacEaseKit
MEDIA_TOOLS := $(CURDIR)/Vendor/build/media-tools/bin
SOURCES := App AppTests FinderSync Packages
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	-derivedDataPath $(DERIVED_DATA)

.PHONY: bootstrap deps media-tools toolkit project build test test-age test-app test-device lint format dmg

bootstrap:
	brew list xcodegen cmake meson ninja pkg-config >/dev/null 2>&1 || brew install xcodegen cmake meson ninja pkg-config
	command -v cargo >/dev/null 2>&1 || brew install rust
	command -v go >/dev/null 2>&1 || brew install go
	command -v python3.11 >/dev/null 2>&1 || brew install python@3.11
	scripts/build-media-tools.sh
	$(MAKE) toolkit
	scripts/build-deps.sh
	xcodegen generate

deps:
	scripts/build-media-tools.sh
	scripts/build-deps.sh

media-tools:
	scripts/build-media-tools.sh

toolkit:
	scripts/build-age.sh
	scripts/build-ai-audio.sh
	scripts/build-upscaler.sh

project:
	for component in media-tools ai-audio macease-age macease-hatchzip; do \
		scripts/sign-bundled-code.sh "$(CURDIR)/Vendor/build/$$component" --sign - || exit; \
	done
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Debug build
	python3 scripts/verify-signing.py "$(DERIVED_DATA)/Build/Products/Debug/MacEase Dev.app" --configuration Debug

test:
	python3 scripts/test-build-deps.py
	"$(MEDIA_TOOLS)/python3" -I -B scripts/verify-js-isolation.py "$(MEDIA_TOOLS)/qjs"
	$(MAKE) test-age
	MACEASE_MEDIA_TOOLS="$(MEDIA_TOOLS)" swift test --no-parallel --package-path $(PACKAGE)

test-age:
	cd Vendor/AgeBridge && GOTOOLCHAIN=local CGO_ENABLED=0 go test -mod=readonly -count=1 ./...

test-app: project
	$(XCODEBUILD) -configuration DebugTests test

# Missing capabilities fail here instead of skipping.
test-device: build
	python3 scripts/test-build-deps.py
	"$(MEDIA_TOOLS)/python3" -I -B scripts/verify-js-isolation.py "$(MEDIA_TOOLS)/qjs"
	$(MAKE) test-age
	MACEASE_DEVICE_TESTS=1 MACEASE_MEDIA_TOOLS="$(MEDIA_TOOLS)" swift test --no-parallel --package-path $(PACKAGE)
	$(MAKE) test-app

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format format --in-place --recursive $(SOURCES)

dmg:
	scripts/make-dmg.sh
