# tests/tests.mk — test apps (build/apps) and test programs (build/tests).

# ---------------------------------------------------------------- test apps
# A test app <Name>: build/apps/<Name>.app with the executable <Name>, built from <Name>_SRC by <Name>_CC with
# <Name>_FLAGS (and <Name>_DEPS, if those name files), <Name>_DIR/Info.plist, and the test apps named in <Name>_WATCH in
# its Watch/ folder, as Xcode embeds an iPhone app's Watch apps; signed.
IOS_SWIFT   = xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios$(1)-simulator -parse-as-library
WATCH_SWIFT = xcrun -sdk watchsimulator swiftc -target arm64-apple-watchos$(1)-simulator -parse-as-library
define test_app
$(APPS)/$(1).app: $$($(1)_SRC) $$($(1)_DIR)/Info.plist $$($(1)_DEPS) $$(patsubst %,$(APPS)/%.app,$$($(1)_WATCH)) | $(APPS)
	@rm -rf $$@ && mkdir -p $$@ && cp $$($(1)_DIR)/Info.plist $$@/
	$$(if $$($(1)_WATCH),@mkdir -p $$@/Watch && cp -R $$(patsubst %,$(APPS)/%.app,$$($(1)_WATCH)) $$@/Watch/)
	$$($(1)_CC) $$($(1)_SRC) $$($(1)_FLAGS) -o $$@/$(1)
	@$$(SIGN) $$@ 2>/dev/null
endef

Hello_DIR      := tests/apps/hello
Hello_SRC      := $(Hello_DIR)/main.m
Hello_CC       := $(SIMCC)
Hello_FLAGS    := -framework UIKit
HIDTest_DIR    := tests/apps/hidtest
HIDTest_SRC    := $(HIDTest_DIR)/main.m
HIDTest_CC     := $(SIMCC)
HIDTest_FLAGS  := -framework UIKit
DragTest_DIR   := tests/apps/dragtest
DragTest_SRC   := $(DragTest_DIR)/main.m
DragTest_CC    := $(SIMCC)
DragTest_FLAGS := -framework UIKit -framework CoreGraphics
WebTest_DIR    := tests/apps/webtest
WebTest_SRC    := $(WebTest_DIR)/main.m
WebTest_CC     := $(SIMCC)
WebTest_FLAGS  := -framework UIKit -framework WebKit -framework QuartzCore
PickerTest_DIR   := tests/apps/pickertest
PickerTest_SRC   := $(PickerTest_DIR)/main.m
PickerTest_CC    := $(SIMCC)
PickerTest_FLAGS := -framework UIKit -framework UniformTypeIdentifiers
# BGDownload: a background URLSession download. Like Xcode's simulator builds, its entitlements (application-identifier,
# which nsurlsessiond takes the client's bundle ID from on iOS 26 and earlier) go in __TEXT,__entitlements.
BGDownload_DIR   := tests/apps/bgdownload
BGDownload_SRC   := $(BGDownload_DIR)/main.m
BGDownload_CC    := $(SIMCC)
BGDownload_DEPS  := $(BGDownload_DIR)/Entitlements.plist
BGDownload_FLAGS := -framework UIKit -Wl,-sectcreate,__TEXT,__entitlements,$(BGDownload_DEPS)
SUI_DIR        := tests/apps/swiftui
SUI_SRC        := $(SUI_DIR)/SUI.swift
SUI_CC         := $(call IOS_SWIFT,17.0)
Glass_DIR      := tests/apps/glass
Glass_SRC      := $(Glass_DIR)/Glass.swift
Glass_CC       := $(call IOS_SWIFT,26.0)
AudioPlayer_DIR := tests/apps/audioplayer
AudioPlayer_SRC := $(AudioPlayer_DIR)/AudioPlayer.swift
AudioPlayer_CC  := $(call IOS_SWIFT,17.0)
# WatchTest: a watch-only SwiftUI app, built for the watchOS Simulator.
WatchTest_DIR  := tests/apps/watchtest
WatchTest_SRC  := $(WatchTest_DIR)/WatchTest.swift
WatchTest_CC   := $(call WATCH_SWIFT,10.0)
# WCPhone and WCWatch: WatchConnectivity between SimRun's iPhone and Apple Watch. WCWatch is WCPhone's watch app, in its
# Watch/ folder as Xcode puts it there (and in build/apps, to run it).
WCWatch_DIR    := tests/apps/wcwatch
WCWatch_SRC    := $(WCWatch_DIR)/WCWatch.swift tests/apps/wcphone/Session.swift
WCWatch_CC     := $(call WATCH_SWIFT,10.0)
WCPhone_DIR    := tests/apps/wcphone
WCPhone_SRC    := $(WCPhone_DIR)/WCPhone.swift $(WCPhone_DIR)/Session.swift
WCPhone_CC     := $(call IOS_SWIFT,17.0)
WCPhone_WATCH  := WCWatch

TEST_APP_NAMES := Hello SUI HIDTest Glass DragTest WebTest BGDownload PickerTest AudioPlayer WatchTest WCPhone
$(foreach a,$(TEST_APP_NAMES) WCWatch,$(eval $(call test_app,$(a))))

# Showcase: a SwiftUI tour of what works under SimRun — the iPhone app (*.swift) and its Watch app (Watch/), which share
# WatchConnectivity code (Shared/) and the Icon Composer icon. Each half is compiled for its own Simulator, with its icon
# compiled for it (Assets.car, and the iPhone's fallback PNGs), in build/showcase; the Watch app is put in the iPhone
# app's Watch/ folder as Xcode embeds it, and both are signed, the Watch app first.
SHOWCASE       := tests/apps/showcase
SHOWCASE_OBJ   := $(BUILD)/showcase
SHOWCASE_WATCH := $(SHOWCASE_OBJ)/ShowcaseWatch.app
SHOWCASE_ICON  := $(SHOWCASE)/AppIcon.icon/icon.json $(wildcard $(SHOWCASE)/AppIcon.icon/Assets/*)
SHOWCASE_PHONE_SRC := $(wildcard $(SHOWCASE)/*.swift $(SHOWCASE)/Shared/*.swift)
SHOWCASE_WATCH_SRC := $(wildcard $(SHOWCASE)/Watch/*.swift $(SHOWCASE)/Shared/*.swift)
$(SHOWCASE_OBJ)/phone/Showcase: $(SHOWCASE_PHONE_SRC)
	@mkdir -p $(@D)
	$(call IOS_SWIFT,26.0) -O $^ -o $@
$(SHOWCASE_OBJ)/watch/ShowcaseWatch: $(SHOWCASE_WATCH_SRC)
	@mkdir -p $(@D)
	$(call WATCH_SWIFT,10.0) -O $^ -o $@
$(SHOWCASE_OBJ)/phone/icon/Assets.car: $(SHOWCASE_ICON)
	@rm -rf $(@D) && mkdir -p $(@D)
	xcrun actool $(SHOWCASE)/AppIcon.icon --compile $(@D) --platform iphonesimulator --minimum-deployment-target 26.0 \
	  --app-icon AppIcon --output-partial-info-plist $(SHOWCASE_OBJ)/phone/icon.plist >/dev/null
$(SHOWCASE_OBJ)/watch/icon/Assets.car: $(SHOWCASE_ICON)
	@rm -rf $(@D) && mkdir -p $(@D)
	xcrun actool $(SHOWCASE)/AppIcon.icon --compile $(@D) --platform watchsimulator --minimum-deployment-target 10.0 \
	  --app-icon AppIcon --output-partial-info-plist $(SHOWCASE_OBJ)/watch/icon.plist >/dev/null
$(SHOWCASE_WATCH): $(SHOWCASE_OBJ)/watch/ShowcaseWatch $(SHOWCASE_OBJ)/watch/icon/Assets.car $(SHOWCASE)/Watch/Info.plist
	@rm -rf $@ && mkdir -p $@
	@cp $(SHOWCASE)/Watch/Info.plist $(SHOWCASE_OBJ)/watch/ShowcaseWatch $@/ && cp $(SHOWCASE_OBJ)/watch/icon/* $@/
	@$(SIGN) $@ 2>/dev/null
$(APPS)/Showcase.app: $(SHOWCASE_OBJ)/phone/Showcase $(SHOWCASE_OBJ)/phone/icon/Assets.car $(SHOWCASE)/Info.plist $(SHOWCASE_WATCH) | $(APPS)
	@rm -rf $@ && mkdir -p $@/Watch
	@cp $(SHOWCASE)/Info.plist $(SHOWCASE_OBJ)/phone/Showcase $@/ && cp $(SHOWCASE_OBJ)/phone/icon/* $@/
	@cp -R $(SHOWCASE_WATCH) $@/Watch/
	@$(SIGN) $@ 2>/dev/null

TEST_APPS := $(patsubst %,$(APPS)/%.app,$(TEST_APP_NAMES) Showcase)

# ---------------------------------------------------------------- test programs
# A test program <name>: build/tests/<name> from <name>_SRC, linked with <name>_FLAGS; signed.
define test_program
$(TBIN)/$(1): $$($(1)_SRC) | $(TBIN)
	$$(SIMCC) $$< $$($(1)_FLAGS) -o $$@
	@$$(SIGN) $$@ 2>/dev/null
endef

nettest_SRC    := tests/net/nettest.m
nettest_FLAGS  := -framework Foundation
nwtest_SRC     := tests/net/nwtest.m
nwtest_FLAGS   := -framework Foundation -framework Network
pbtest_SRC     := tests/pboard/pbtest.m
pbtest_FLAGS   := -framework UIKit
kctest_SRC     := tests/keychain/kctest.m
kctest_FLAGS   := -framework Foundation -framework Security
loctest_SRC    := tests/locale/loctest.m
loctest_FLAGS  := -framework Foundation
mpstest_SRC    := tests/mps/mpstest.m
mpstest_FLAGS  := -framework Foundation -framework Metal -framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph
audiotest_SRC  := tests/audio/audiotest.m
audiotest_FLAGS := -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreMedia
motiontest_SRC := tests/motion/motiontest.m
motiontest_FLAGS := -framework Foundation -framework CoreMotion

TEST_PROGRAM_NAMES := nettest nwtest pbtest kctest loctest mpstest audiotest motiontest
$(foreach p,$(TEST_PROGRAM_NAMES),$(eval $(call test_program,$(p))))

# a viewer without a browser (tests/remote): the same WebRTC, from vendor/
$(TBIN)/remotetest: tests/remote/remotetest.m $(WEBRTC_STAMP) | $(TBIN)
	$(MACCC) -Wall -Fvendor $< -framework Foundation -framework WebRTC -Wl,-rpath,$(abspath vendor) -o $@

TEST_PROGS := $(patsubst %,$(TBIN)/%,$(TEST_PROGRAM_NAMES)) $(TBIN)/remotetest
