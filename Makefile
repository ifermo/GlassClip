APP_NAME := GlassClip
BUNDLE_ID := com.ken.glassclip
VERSION := 0.1.0
BUILD_DIR := .build
DIST_DIR := dist
APP := $(DIST_DIR)/$(APP_NAME).app

.PHONY: all build build-universal app icon dmg install run test clean

all: app

build:
	swift build -c release

build-universal:
	swift build -c release --arch arm64 --arch x86_64

app:
	swift build -c release --arch arm64 --arch x86_64
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD_DIR)/apple/Products/Release/$(APP_NAME) $(APP)/Contents/MacOS/
	# SwiftPM 资源 bundle（状态栏模板图 StatusBarIcon.png 所在）；
	# 缺了它 Bundle.module 在 .app 里寻址失败，会静默退回 SF Symbol。
	cp -R $(BUILD_DIR)/apple/Products/Release/$(APP_NAME)_GlassClip.bundle $(APP)/Contents/Resources/
	cp Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(APP)/Contents/Info.plist
	$(MAKE) icon
	codesign --force --deep -s - $(APP)

icon:
	mkdir -p $(BUILD_DIR)/AppIcon.iconset $(APP)/Contents/Resources
	sips -z 16 16     Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png
	sips -z 32 32     Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png
	sips -z 32 32     Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png
	sips -z 64 64     Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png
	sips -z 128 128   Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png
	sips -z 256 256   Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png
	sips -z 256 256   Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png
	sips -z 512 512   Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png
	sips -z 512 512   Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png
	sips -z 1024 1024 Resources/AppIcon.png --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o $(APP)/Contents/Resources/AppIcon.icns

dmg: app
	rm -f $(DIST_DIR)/$(APP_NAME).dmg
	hdiutil create -volname $(APP_NAME) -srcfolder $(APP) -ov -format UDZO $(DIST_DIR)/$(APP_NAME).dmg

install: app
	ditto $(APP) /Applications/$(APP_NAME).app

run:
	swift run

test:
	swift test

clean:
	swift package clean
	rm -rf $(DIST_DIR)
