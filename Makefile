VERSION ?= 0.0.0-dev
APP      = dist/MeridianBar.app
BIN      = .build/release/MeridianBar
DIRECT   = .build/direct/MeridianBar
SRC      = Sources/MeridianBar/*.swift

.PHONY: build build-direct test app app-direct run install uninstall clean

build:
	swift build -c release

# Fallback for hosts where the CLT SwiftPM manifest toolchain is broken
# (see okf/STATUS.md). The sources are dependency-free, so a direct
# compile is equivalent.
build-direct:
	mkdir -p .build/direct
	swiftc -O -parse-as-library -swift-version 6 $(SRC) -o $(DIRECT)

test:
	swift test

define bundle
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(1) $(APP)/Contents/MacOS/MeridianBar
	sed 's/__VERSION__/$(VERSION)/g' Support/Info.plist > $(APP)/Contents/Info.plist
	codesign --force -s - $(APP)
endef

app: build
	$(call bundle,$(BIN))

app-direct: build-direct
	$(call bundle,$(DIRECT))

run: app
	open $(APP)

run-direct: app-direct
	open $(APP)

install: app
	rm -rf /Applications/MeridianBar.app
	cp -R $(APP) /Applications/MeridianBar.app
	open /Applications/MeridianBar.app

uninstall:
	osascript -e 'quit app "MeridianBar"' 2>/dev/null || true
	rm -rf /Applications/MeridianBar.app

clean:
	rm -rf .build dist
