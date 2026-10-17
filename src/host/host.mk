# src/host/host.mk — the Mac side: SimRun.app (simrund, the server and launcher, with everything it carries) and the
# simrun command line.

# Google's WebRTC, for remote control (remote.md): prebuilt for macOS by github.com/stasel/WebRTC (from the official
# source, unmodified), downloaded into vendor/, checked against its checksum and thinned to arm64. SimRun links it, and
# carries it in Contents/Frameworks.
WEBRTC_VERSION := 154.0.0
WEBRTC_ZIP     := WebRTC-M154.xcframework.zip
WEBRTC_SHA256  := a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16
WEBRTC         := vendor/WebRTC.framework
WEBRTC_STAMP   := vendor/.webrtc-$(WEBRTC_VERSION)
$(WEBRTC_STAMP):
	@mkdir -p vendor/dl
	@test -f vendor/dl/$(WEBRTC_ZIP) || curl -fL --retry 3 -o vendor/dl/$(WEBRTC_ZIP) \
	  https://github.com/stasel/WebRTC/releases/download/$(WEBRTC_VERSION)/$(WEBRTC_ZIP)
	@echo "$(WEBRTC_SHA256)  vendor/dl/$(WEBRTC_ZIP)" | shasum -a 256 -c - >/dev/null || \
	  { echo "$(WEBRTC_ZIP): checksum mismatch"; rm -f vendor/dl/$(WEBRTC_ZIP); exit 1; }
	@rm -rf vendor/dl/WebRTC.xcframework $(WEBRTC) vendor/.webrtc-*
	@unzip -q vendor/dl/$(WEBRTC_ZIP) -d vendor/dl
	@ditto --arch arm64 vendor/dl/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework $(WEBRTC)
	@rm -rf vendor/dl/WebRTC.xcframework && touch $@
	@echo "fetched WebRTC $(WEBRTC_VERSION) into $(WEBRTC)"

# simrund, one folder per part: server/ (the process: SRServer, its menus and clients), device/ (the simulated iPhone and
# Apple Watch: runtimes, device types, data containers, pairing), sim2host/ (the Mac-side services each simns publishes
# to the apps), apps/ (the app library and launch options), session/ (a running app), launcher/, keychain/ (the
# Keychain window), inspector/ (the layer debugger) and remote/ (remote control); imports across folders name the
# folder. It finds WebRTC.framework in the app's Frameworks, or in vendor/ when run as build/bin/simrund.
SIMRUND_OBJ := $(call mac_objs,$(wildcard src/host/simrund/*/*.m))
$(OBJ)/mac/src/host/simrund/%.o: CPPFLAGS += -Isrc/host/simrund -Fvendor
$(SIMRUND_OBJ): | $(WEBRTC_STAMP)
$(BIN)/simrund: $(SIMRUND_OBJ) $(WEBRTC_STAMP) | $(BIN)
	$(MAC_LINK) -Fvendor $(SIMRUND_OBJ) -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal \
	  -framework UniformTypeIdentifiers -framework ImageIO -framework AVFoundation -framework IOKit -framework Security \
	  -framework SystemConfiguration -framework Network -framework CoreVideo -framework WebRTC \
	  -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path/../../vendor -o $@

# App icon: the Icon Composer document compiled into Assets.car (Liquid Glass icon) and AppIcon.icns (fallback).
# Xcode 27 reads "features" and a string specular (outside/inside/...). Xcode 26's actool crashes on
# "features" and only accepts a boolean specular, so on 26 the document is rewritten before compiling.
XCODE_MAJOR := $(shell $(if $(DEVELOPER_DIR),DEVELOPER_DIR=$(DEVELOPER_DIR)) xcodebuild -version | awk 'NR==1 { split($$2, v, "."); print v[1] }')
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

# SimRun.app: the server/launcher executable, the simrun helper, simns, the sim-side libraries, the agent skill, the
# remote-control page and WebRTC.framework.
# Assembled in a staging bundle and swapped in with a rename, so a SimRun that is running from the old bundle keeps
# its (unlinked) files instead of having them overwritten underneath it.
APP := $(BUILD)/SimRun.app
SKILL_FILES := $(shell find skills -type f ! -name .DS_Store)
$(APP): $(SKILL_FILES) $(BIN)/simrund $(BIN)/simrun $(BIN)/simns $(SIMLIBS) $(WATCHLIBS) resources/Info.plist resources/remote.html $(ICON)/Assets.car
	@rm -rf $(BUILD)/.SimRun.app.new $(BUILD)/.SimRun.app.old
	@mkdir -p $(BUILD)/.SimRun.app.new/Contents/MacOS $(BUILD)/.SimRun.app.new/Contents/Helpers $(BUILD)/.SimRun.app.new/Contents/Resources/lib/watchos \
	  $(BUILD)/.SimRun.app.new/Contents/Frameworks
	@cp resources/Info.plist $(BUILD)/.SimRun.app.new/Contents/Info.plist
	@cp $(ICON)/Assets.car $(ICON)/AppIcon.icns resources/remote.html $(BUILD)/.SimRun.app.new/Contents/Resources/
	@cp $(BIN)/simrund $(BUILD)/.SimRun.app.new/Contents/MacOS/SimRun
	@cp $(BIN)/simrun $(BUILD)/.SimRun.app.new/Contents/Helpers/
	@cp $(BIN)/simns $(BUILD)/.SimRun.app.new/Contents/Resources/lib/
	@cp $(SIMLIBS) $(BUILD)/.SimRun.app.new/Contents/Resources/lib/
	@cp $(WATCHLIBS) $(BUILD)/.SimRun.app.new/Contents/Resources/lib/watchos/
	@rsync -a --exclude .DS_Store skills $(BUILD)/.SimRun.app.new/Contents/Resources/
	@ditto $(WEBRTC) $(BUILD)/.SimRun.app.new/Contents/Frameworks/WebRTC.framework
	@cd $(BUILD)/.SimRun.app.new/Contents/Frameworks/WebRTC.framework && rm -rf Headers Modules Versions/A/Headers Versions/A/Modules
	@$(SIGN) --deep $(BUILD)/.SimRun.app.new 2>/dev/null
	@if [ -d $@ ]; then mv $@ $(BUILD)/.SimRun.app.old; fi
	@mv $(BUILD)/.SimRun.app.new $@ && rm -rf $(BUILD)/.SimRun.app.old
	@echo "built $@"

# simrun: the command line, a client of the server's socket (include/simrund_proto.h)
SIMRUN_OBJ := $(call mac_objs,src/host/simrun/simrun.m)
$(OBJ)/mac/src/host/simrun/%.o: CFLAGS += -Wall
$(BIN)/simrun: $(SIMRUN_OBJ) | $(BIN)
	$(MAC_LINK) $^ -framework Foundation -o $@

OBJS += $(SIMRUND_OBJ) $(SIMRUN_OBJ)

