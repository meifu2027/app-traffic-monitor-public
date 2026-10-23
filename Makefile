PROJECT        := AppTrafficMonitor.xcodeproj
APP_SCHEME     := AppTrafficMonitor
TEST_SCHEME    := Logic
CONFIG        ?= Debug
XCODEBUILD    ?= xcodebuild
BUILD_DIR     := build
LOCAL_XCCONFIG := Config/Local.xcconfig
APP_PRODUCT   := $(BUILD_DIR)/Build/Products/$(CONFIG)/AppTrafficMonitor.app
SYSEXT        := $(APP_PRODUCT)/Contents/Library/SystemExtensions/TrafficFilterExtension.systemextension
SIGN_IDENTITY ?= Apple Development
APP_NAME      := AppTrafficMonitor
# 与 project.yml MARKETING_VERSION 保持一致（无 BuildSettings 读取手段，改版本两处同步）
APP_VERSION   := 0.1.0
DMG_STAGING   := $(BUILD_DIR)/dmg-staging
DMG_PATH      := $(BUILD_DIR)/$(APP_NAME)-$(APP_VERSION).dmg

.PHONY: all config gen build test sign verify-sign install-app dmg clean

all: config build

config:
	@test -f $(LOCAL_XCCONFIG) || { cp Config/Local.xcconfig.example $(LOCAL_XCCONFIG); \
		echo "已生成 $(LOCAL_XCCONFIG)，请填写 DEVELOPMENT_TEAM 后重新构建"; }

gen: config
	xcodegen generate

build: config
	$(XCODEBUILD) -project $(PROJECT) -scheme $(APP_SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) build

test: config
	$(XCODEBUILD) -project $(PROJECT) -scheme $(TEST_SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) test

# T02：xcodebuild 因受限 entitlement 强制要求 profile 而拒绝签名，
# 改用 codesign CLI + Apple Development 身份手工签名（内层 sysext 先签）。
# 容器 app 不带受限 entitlement（仅扩展持有）。
sign:
	codesign --force --options runtime \
		--entitlements Extension/TrafficFilterExtension.entitlements \
		--sign "$(SIGN_IDENTITY)" "$(SYSEXT)"
	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" "$(APP_PRODUCT)"

verify-sign:
	@echo "== sysext entitlements =="; codesign -d --entitlements - --xml "$(SYSEXT)" 2>/dev/null | plutil -p - || true
	@echo "== app 签名校验 =="; codesign --verify --strict "$(APP_PRODUCT)" && echo "app 签名完整"
	@echo "== sysext 签名校验 =="; codesign --verify --strict "$(SYSEXT)" && echo "sysext 签名完整"

# 实际启用通常要求 app 位于 /Applications（TN3134）
install-app:
	rm -rf /Applications/AppTrafficMonitor.app
	cp -R "$(APP_PRODUCT)" /Applications/AppTrafficMonitor.app

# R01：本机 Mihomo 只读接入验证（开发期工具，非常驻组件）
probe-mihomo: config
	$(XCODEBUILD) -project $(PROJECT) -scheme MihomoProbe -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) build
	"$(BUILD_DIR)/Build/Products/$(CONFIG)/mihomo-probe"

# D 线本地安装：ad-hoc 签名 + 拷贝到 /Applications。
# app 不含系统扩展与受限 entitlement（D5 决策），本地 ad-hoc 即可运行；无需任何账号授权。
install-local:
	rm -rf /Applications/AppTrafficMonitor.app
	cp -R "$(APP_PRODUCT)" /Applications/AppTrafficMonitor.app
	codesign --force --sign - /Applications/AppTrafficMonitor.app
	@echo "已安装：/Applications/AppTrafficMonitor.app（ad-hoc 签名）"

# 可分发拖装包：ad-hoc 签名 .app + /Applications 软链 → UDZO DMG。
# 无 Developer ID（T02 阻塞）不可公证：本机直接可用；拷到其它机器首次打开
# 需「系统设置 → 隐私与安全性 → 仍要打开」，或先 xattr -dr com.apple.quarantine。
# 常用：make CONFIG=Release dmg
dmg: build
	rm -rf $(DMG_STAGING) $(DMG_PATH)
	mkdir -p $(DMG_STAGING)
	cp -R "$(APP_PRODUCT)" "$(DMG_STAGING)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	codesign --force --sign - "$(DMG_STAGING)/$(APP_NAME).app"
	hdiutil create -volname $(APP_NAME) -srcfolder $(DMG_STAGING) -ov -format UDZO "$(DMG_PATH)"
	@echo "已打包：$(DMG_PATH)（打开后拖 app 到 Applications 即装）"

clean:
	rm -rf $(BUILD_DIR)
