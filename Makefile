VERSION ?= 0.0.0-dev
APP      = dist/MeridianBar.app
BIN      = .build/release/MeridianBar

# Bare CommandLineTools keep Swift Testing out of the default search
# paths (okf/03). Xcode toolchains (CI) need no help, so the flags are
# gated on the selected developer dir.
DEV_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(DEV_DIR),/Library/Developer/CommandLineTools)
CLT_FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_TESTLIB    = /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS = -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
             -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(CLT_TESTLIB)
endif

.PHONY: build test app run install uninstall clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BIN) $(APP)/Contents/MacOS/MeridianBar
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	@FW=$$(find .build -type d -name Sparkle.framework -path '*macos*' | head -1); \
	if [ -n "$$FW" ]; then \
	  cp -R "$$FW" $(APP)/Contents/Frameworks/; \
	  codesign --force -s - $(APP)/Contents/Frameworks/Sparkle.framework; \
	else echo "warning: Sparkle.framework not found in .build — updater will be dead"; fi
	sed 's/__VERSION__/$(VERSION)/g' Support/Info.plist > $(APP)/Contents/Info.plist
	codesign --force -s - $(APP)

run: app
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
