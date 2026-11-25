APP_NAME := AIQuotaHover
BUNDLE_ID := com.local.ai-quota-hover
VERSION ?= 1.0.0
DIST_DIR := dist

.PHONY: all build install package clean

all: build

build:
	swift build -c release

install:
	chmod +x ./install.sh
	./install.sh

package: build
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)/$(APP_NAME).app/Contents/MacOS" "$(DIST_DIR)/$(APP_NAME).app/Contents/Resources"
	cp ".build/release/$(APP_NAME)" "$(DIST_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	chmod +x "$(DIST_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	  '  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '</dict></plist>' > "$(DIST_DIR)/$(APP_NAME).app/Contents/Info.plist"
	cd "$(DIST_DIR)" && ditto -c -k --keepParent "$(APP_NAME).app" "$(APP_NAME)-v$(VERSION)-macOS.zip"
	@echo "✅ Packaged: $(DIST_DIR)/$(APP_NAME)-v$(VERSION)-macOS.zip"

clean:
	swift package clean
	rm -rf "$(DIST_DIR)"
