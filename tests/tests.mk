# tests/tests.mk — test apps (build/apps) and test programs (build/tests).

TEST_APPS  := $(APPS)/Hello.app $(APPS)/SUI.app $(APPS)/HIDTest.app $(APPS)/Glass.app $(APPS)/DragTest.app $(APPS)/WebTest.app $(APPS)/BGDownload.app $(APPS)/PickerTest.app $(APPS)/Showcase.app $(APPS)/AudioPlayer.app \
              $(APPS)/WatchTest.app $(APPS)/WCPhone.app
TEST_PROGS := $(TBIN)/nettest $(TBIN)/nwtest $(TBIN)/pbtest $(TBIN)/kctest $(TBIN)/loctest $(TBIN)/mpstest $(TBIN)/audiotest $(TBIN)/motiontest \
              $(TBIN)/remotetest
.PHONY: $(APPS)/Showcase.app

$(APPS)/Hello.app: tests/apps/hello/main.m tests/apps/hello/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hello/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/Hello
	@$(SIGN) $@ 2>/dev/null

$(APPS)/SUI.app: tests/apps/swiftui/SUI.swift tests/apps/swiftui/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/swiftui/Info.plist $@/
	$(SIMSWIFT) -parse-as-library $< -o $@/SUI
	@$(SIGN) $@ 2>/dev/null

$(APPS)/Glass.app: tests/apps/glass/Glass.swift tests/apps/glass/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/glass/Info.plist $@/
	xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -parse-as-library $< -o $@/Glass
	@$(SIGN) $@ 2>/dev/null

$(APPS)/HIDTest.app: tests/apps/hidtest/main.m tests/apps/hidtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hidtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/HIDTest
	@$(SIGN) $@ 2>/dev/null

$(APPS)/DragTest.app: tests/apps/dragtest/main.m tests/apps/dragtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/dragtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework CoreGraphics -o $@/DragTest
	@$(SIGN) $@ 2>/dev/null

$(APPS)/WebTest.app: tests/apps/webtest/main.m tests/apps/webtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/webtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework WebKit -framework QuartzCore -o $@/WebTest
	@$(SIGN) $@ 2>/dev/null

$(APPS)/PickerTest.app: tests/apps/pickertest/main.m tests/apps/pickertest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/pickertest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework UniformTypeIdentifiers -o $@/PickerTest
	@$(SIGN) $@ 2>/dev/null

# BGDownload: a background URLSession download. Like Xcode's simulator builds, its entitlements (application-identifier,
# which nsurlsessiond takes the client's bundle ID from on iOS 26 and earlier) go in __TEXT,__entitlements.
$(APPS)/BGDownload.app: tests/apps/bgdownload/main.m tests/apps/bgdownload/Info.plist tests/apps/bgdownload/Entitlements.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/bgdownload/Info.plist $@/
	$(SIMCC) $< -framework UIKit -Wl,-sectcreate,__TEXT,__entitlements,tests/apps/bgdownload/Entitlements.plist -o $@/BGDownload
	@$(SIGN) $@ 2>/dev/null

# WatchTest: a watch-only SwiftUI app, built for the watchOS Simulator.
$(APPS)/WatchTest.app: tests/apps/watchtest/WatchTest.swift tests/apps/watchtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/watchtest/Info.plist $@/
	xcrun -sdk watchsimulator swiftc -target arm64-apple-watchos10.0-simulator -parse-as-library $< -o $@/WatchTest
	@$(SIGN) $@ 2>/dev/null

# WCPhone and WCWatch: WatchConnectivity between SimRun's iPhone and Apple Watch. WCWatch is WCPhone's watch app, in its
# Watch/ folder as Xcode puts it there (and in build/apps, to run it).
$(APPS)/WCWatch.app: tests/apps/wcwatch/WCWatch.swift tests/apps/wcphone/Session.swift tests/apps/wcwatch/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/wcwatch/Info.plist $@/
	xcrun -sdk watchsimulator swiftc -target arm64-apple-watchos10.0-simulator -parse-as-library tests/apps/wcwatch/WCWatch.swift tests/apps/wcphone/Session.swift -o $@/WCWatch
	@$(SIGN) $@ 2>/dev/null
$(APPS)/WCPhone.app: tests/apps/wcphone/WCPhone.swift tests/apps/wcphone/Session.swift tests/apps/wcphone/Info.plist $(APPS)/WCWatch.app | $(APPS)
	@rm -rf $@ && mkdir -p $@/Watch && cp tests/apps/wcphone/Info.plist $@/ && cp -R $(APPS)/WCWatch.app $@/Watch/
	$(SIMSWIFT) -parse-as-library tests/apps/wcphone/WCPhone.swift tests/apps/wcphone/Session.swift -o $@/WCPhone
	@$(SIGN) $@ 2>/dev/null

$(APPS)/AudioPlayer.app: tests/apps/audioplayer/AudioPlayer.swift tests/apps/audioplayer/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/audioplayer/Info.plist $@/
	$(SIMSWIFT) -parse-as-library $< -o $@/AudioPlayer
	@$(SIGN) $@ 2>/dev/null

# Showcase: a SwiftUI tour of what works under SimRun, with its Watch app; built by its own Makefile.
$(APPS)/Showcase.app: | $(APPS)
	@$(MAKE) --no-print-directory -C tests/apps/showcase BUILD=$(abspath $(BUILD))

$(TBIN)/nettest: tests/net/nettest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/nwtest: tests/net/nwtest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Network -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/pbtest: tests/pboard/pbtest.m | $(TBIN)
	$(SIMCC) $< -framework UIKit -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/kctest: tests/keychain/kctest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Security -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/loctest: tests/locale/loctest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/mpstest: tests/mps/mpstest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Metal -framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/audiotest: tests/audio/audiotest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreMedia -o $@
$(TBIN)/motiontest: tests/motion/motiontest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework CoreMotion -o $@
	@$(SIGN) $@ 2>/dev/null

# a viewer without a browser (tests/remote): the same WebRTC, from vendor/
$(TBIN)/remotetest: tests/remote/remotetest.m $(WEBRTC_STAMP) | $(TBIN)
	$(MACCC) -Wall -Fvendor $< -framework Foundation -framework WebRTC -Wl,-rpath,$(abspath vendor) -o $@
