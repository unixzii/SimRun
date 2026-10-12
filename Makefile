# SimRun — build everything into build/.
#   make            core components, tools and test programs
#   make core       SimRun.app (server + launcher, simns, injected rshim.dylib and app.dylib, fake SimFramebuffer) and the simrun CLI
#   make test-apps  sample/test apps (build/apps)
#   make tests      test apps and test programs
#   make install    install build/SimRun.app into /Applications
#   make clean

BUILD   := build
BIN     := $(BUILD)/bin
LIB     := $(BUILD)/lib
APPS    := $(BUILD)/apps
TBIN    := $(BUILD)/tests

SIMCC   := xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations -Iinclude
SIMSWIFT:= xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator
MACCC   := xcrun -sdk macosx clang -arch arm64 -fobjc-arc -Wno-deprecated-declarations -Iinclude
MACSWIFT:= env -u DYLD_ROOT_PATH xcrun -sdk macosx swiftc -O
SIGN    := codesign -s - -f
HDRS    := $(wildcard include/*.h)

APP   := $(BUILD)/SimRun.app
CORE  := $(APP) $(BIN)/simrun
SIMLIBS := $(LIB)/rshim.dylib $(LIB)/app.dylib $(LIB)/SimFramebuffer
PARTS := $(BIN)/simrund $(BIN)/simrun $(BIN)/simns $(SIMLIBS)
TOOLS := $(BIN)/hostinput
TEST_APPS  := $(APPS)/Hello.app $(APPS)/SUI.app $(APPS)/HIDTest.app $(APPS)/Glass.app $(APPS)/DragTest.app $(APPS)/WebTest.app $(APPS)/BGDownload.app $(APPS)/PickerTest.app $(APPS)/Showcase.app $(APPS)/AudioPlayer.app
TEST_PROGS := $(TBIN)/nettest $(TBIN)/nwtest $(TBIN)/pbtest $(TBIN)/kctest $(TBIN)/loctest $(TBIN)/mpstest $(TBIN)/audiotest

.PHONY: all core tools test-apps test-programs tests install clean $(APP)
all: core tools test-programs
core: $(CORE)
tools: $(TOOLS)
test-apps: $(TEST_APPS)
test-programs: $(TEST_PROGS)
tests: test-apps test-programs

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@

# ---------------------------------------------------------------- host (macOS)
# simrund.m, then session/ (a running app), launcher/, services/ (the Mac's side of faked system services) and
# inspector/ (the layer debugger); imports across folders name the folder
SIMRUND_SRC := $(wildcard src/host/simrund/*.m src/host/simrund/*/*.m) src/host/gpuhost/gpuhost.m
$(BIN)/simrund: $(SIMRUND_SRC) $(wildcard src/host/simrund/*/*.h) $(HDRS) | $(BIN)
	$(MACCC) -Isrc/host/simrund $(SIMRUND_SRC) -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal \
	  -framework UniformTypeIdentifiers -framework ImageIO -framework AVFoundation -o $@

# App icon: the Icon Composer document compiled into Assets.car (Liquid Glass icon) and AppIcon.icns (fallback).
# Xcode 27 reads "features" and a string specular (outside/inside/...). Xcode 26's actool crashes on
# "features" and only accepts a boolean specular, so on 26 the document is rewritten before compiling.
XCODE_MAJOR := $(shell xcodebuild -version | awk 'NR==1 { split($$2, v, "."); print v[1] }')
ICON     := $(BUILD)/icon
ICON_SRC := resources/AppIcon.icon
ifeq ($(shell test "$(XCODE_MAJOR)" -ge 27 && echo y),y)
ICON_DOC    := $(ICON_SRC)
ICON_INPUTS := $(ICON_SRC)/icon.json $(ICON_SRC)/Assets
else
ICON_DOC    := $(BUILD)/icon-src/AppIcon.icon
ICON_INPUTS := $(ICON_DOC)/icon.json
ICON_ASSETS := $(shell find $(ICON_SRC)/Assets -type f ! -name .DS_Store | sed 's/ /\\ /g')
define downgrade_icon
import json, sys
source_path, output_path = sys.argv[1], sys.argv[2]
with open(source_path) as source_file:
    document = json.load(source_file)
document.pop("features", None)
def walk(node):
    if isinstance(node, dict):
        specular = node.get("specular")
        if isinstance(specular, str):
            node["specular"] = specular not in ("none", "off", "false")
        for child in node.values():
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)
walk(document)
with open(output_path, "w") as output_file:
    json.dump(document, output_file, indent=2)
    output_file.write("\n")
endef
export downgrade_icon
$(ICON_DOC)/icon.json: $(ICON_SRC)/icon.json $(ICON_ASSETS)
	@rm -rf $(ICON_DOC)
	@mkdir -p $(ICON_DOC)
	@cp -R $(ICON_SRC)/Assets $(ICON_DOC)/
	@python3 -c "$$downgrade_icon" $< $@
	@echo "downgraded AppIcon.icon for Xcode $(XCODE_MAJOR)"
endif
$(ICON)/Assets.car: $(ICON_INPUTS)
	@mkdir -p $(ICON)
	xcrun actool $(ICON_DOC) --compile $(ICON) --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
	  --output-partial-info-plist $(ICON)/partial.plist >/dev/null

# SimRun.app: the server/launcher executable, helpers (simns, simrun), the sim-side libraries and the agent skill.
# Assembled in a staging bundle and swapped in with a rename, so a SimRun that is running from the old bundle keeps
# its (unlinked) files instead of having them overwritten underneath it.
SKILL_FILES := $(shell find skills -type f ! -name .DS_Store)
$(APP): $(SKILL_FILES) $(PARTS) resources/Info.plist $(ICON)/Assets.car
	@rm -rf $(BUILD)/.SimRun.app.new $(BUILD)/.SimRun.app.old
	@mkdir -p $(BUILD)/.SimRun.app.new/Contents/MacOS $(BUILD)/.SimRun.app.new/Contents/Helpers $(BUILD)/.SimRun.app.new/Contents/Resources/lib
	@cp resources/Info.plist $(BUILD)/.SimRun.app.new/Contents/Info.plist
	@cp $(ICON)/Assets.car $(ICON)/AppIcon.icns $(BUILD)/.SimRun.app.new/Contents/Resources/
	@cp $(BIN)/simrund $(BUILD)/.SimRun.app.new/Contents/MacOS/SimRun
	@cp $(BIN)/simns $(BIN)/simrun $(BUILD)/.SimRun.app.new/Contents/Helpers/
	@cp $(SIMLIBS) $(BUILD)/.SimRun.app.new/Contents/Resources/lib/
	@rsync -a --exclude .DS_Store skills $(BUILD)/.SimRun.app.new/Contents/Resources/
	@$(SIGN) --deep $(BUILD)/.SimRun.app.new 2>/dev/null
	@if [ -d $@ ]; then mv $@ $(BUILD)/.SimRun.app.old; fi
	@mv $(BUILD)/.SimRun.app.new $@ && rm -rf $(BUILD)/.SimRun.app.old
	@echo "built $@"

$(BIN)/simrun: src/host/simrun/simrun.m $(HDRS) | $(BIN)
	$(MACCC) -Wall $< -framework Foundation -o $@

$(BIN)/hostinput: tools/hostinput.swift | $(BIN)
	$(MACSWIFT) $< -o $@

# ---------------------------------------------------------------- sim side
# common/: what the sim libraries share (common.h), compiled into each one that uses it
COMMON := src/sim/common/common.m
COMMON_DEPS := $(COMMON) $(wildcard src/sim/common/*.h)
SIMLIB := $(SIMCC) -Isrc/sim/common
$(BIN)/simns: src/sim/simns/simns.c $(HDRS) | $(BIN)
	xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -Wall -Wno-deprecated-declarations -Iinclude $< -framework CoreFoundation -o $@
	@$(SIGN) $@ 2>/dev/null

# rshim.dylib: rshim.m and mic.m (the microphone), linked to TCC.framework through a stub (tcc.tbd; not in the SDK)
RSHIM_SRC := src/sim/rshim/rshim.m src/sim/rshim/mic.m
$(LIB)/rshim.dylib: $(RSHIM_SRC) src/sim/rshim/tcc.tbd $(COMMON_DEPS) $(HDRS) | $(LIB)
	$(SIMLIB) -dynamiclib $(RSHIM_SRC) $(COMMON) src/sim/rshim/tcc.tbd -framework Foundation -framework AudioToolbox -framework CoreAudio -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/SimFramebuffer: src/sim/simfb/simfb.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework IOSurface -framework CoreFoundation -framework CoreGraphics -framework Metal \
	  -install_name @rpath/SimFramebuffer.framework/SimFramebuffer -o $@
	@$(SIGN) $@ 2>/dev/null

# app.dylib: the modules SimRun puts in the app (src/sim/app/app.h), one folder each; script/'s JS modules (js/*.js)
# are embedded as C arrays (xxd -i: core.js -> core_js[]). The private frameworks' symbols (FrontBoardServices,
# GraphicsServices, BackBoardServices...) are looked up at load.
APP_MODULES := render scenes hid pboard drag docpicker keychain webkit mps script
APP_SRC := src/sim/app/app.m $(foreach m,$(APP_MODULES),$(wildcard src/sim/$(m)/*.m))
SCRIPT_JS := $(wildcard src/sim/script/js/*.js)
$(BUILD)/gen/script_js.h: $(SCRIPT_JS)
	@mkdir -p $(@D)
	@(cd src/sim/script/js && for f in *.js; do xxd -i $$f; done) > $@.tmp && mv $@.tmp $@
$(LIB)/app.dylib: $(APP_SRC) $(wildcard src/sim/app/*.h src/sim/script/*.h) $(BUILD)/gen/script_js.h $(COMMON_DEPS) $(HDRS) | $(LIB)
	$(SIMLIB) -Isrc/sim/app -I$(BUILD)/gen -dynamiclib $(APP_SRC) $(COMMON) -framework Foundation -framework UIKit -framework QuartzCore \
	  -framework CoreGraphics -framework IOKit -framework UniformTypeIdentifiers -framework Security -framework Metal \
	  -Wl,-undefined,dynamic_lookup -Wl,-w -o $@
	@$(SIGN) $@ 2>/dev/null

# ---------------------------------------------------------------- tests
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

$(APPS)/AudioPlayer.app: tests/apps/audioplayer/AudioPlayer.swift tests/apps/audioplayer/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/audioplayer/Info.plist $@/
	$(SIMSWIFT) -parse-as-library $< -o $@/AudioPlayer
	@$(SIGN) $@ 2>/dev/null

# Showcase: a SwiftUI tour of what works under SimRun, with its own Icon Composer icon compiled into Assets.car.
SHOWCASE_SRC := $(wildcard tests/apps/showcase/*.swift)
SHOWCASE_ICON := tests/apps/showcase/AppIcon.icon/icon.json $(wildcard tests/apps/showcase/AppIcon.icon/Assets/*)
$(APPS)/Showcase.app: $(SHOWCASE_SRC) $(SHOWCASE_ICON) tests/apps/showcase/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/showcase/Info.plist $@/
	xcrun actool tests/apps/showcase/AppIcon.icon --compile $@ --platform iphonesimulator --minimum-deployment-target 26.0 \
	  --app-icon AppIcon --output-partial-info-plist $(BUILD)/showcase-icon.plist >/dev/null
	xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -parse-as-library -O $(SHOWCASE_SRC) -o $@/Showcase
	@$(SIGN) $@ 2>/dev/null

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
	@$(SIGN) $@ 2>/dev/null

# Install the built bundle into /Applications. ditto keeps the ad-hoc signature.
# A running SimRun must be quit first; the installed bundle is replaced in place.
install: $(APP)
	@if pgrep -qx SimRun; then \
	  echo "SimRun is running. Quit it, then run make install again." >&2; \
	  exit 1; \
	fi
	@rm -rf /Applications/SimRun.app
	@ditto $(APP) /Applications/SimRun.app
	@echo "installed /Applications/SimRun.app"

clean:
	rm -rf $(BUILD)
