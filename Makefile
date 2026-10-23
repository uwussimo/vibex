PROJECT   := Vibex.xcodeproj
SCHEME    := Vibex
DERIVED   := build/DerivedData
XCB       := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -skipPackagePluginValidation
APP       := $(DERIVED)/Build/Products/Debug/Vibex.app

.PHONY: gen icons build run test clean open icon release

# Untitled UI's icons may not be redistributed, so they are fetched, not committed.
icons:
	./scripts/fetch-icons.sh

gen: icons
	xcodegen generate

build: gen
	$(XCB) -configuration Debug build 2>&1 | grep -E "^/.*(error|warning):|^\*\* BUILD" | grep -v SourcePackages || true

run: build
	pkill -x Vibex 2>/dev/null; true
	open $(APP)

test: gen
	$(XCB) -configuration Debug test 2>&1 | grep -E "^/.*error:|✘|✔ Suite|^\*\* TEST" | grep -v SourcePackages || true
	# The test action leaves the host app unsigned for launchd; rebuild it.
	$(XCB) -configuration Debug build 2>&1 | grep -E "^/.*error:|^\*\* BUILD" || true

clean:
	rm -rf $(DERIVED)

open: gen
	open $(PROJECT)

icon:
	./scripts/make-iconset.sh

release:
	./scripts/release.sh
