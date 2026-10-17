# src/host/host.mk — the Mac side: SimRun.app (simrund, the server and launcher, with everything it carries) and the
# simrun command line.

# Google's WebRTC, for remote control (remote.md): prebuilt for macOS by github.com/stasel/WebRTC, downloaded into
# vendor/ and checked against its checksum (mk/fetch-webrtc.sh). SimRun links it, and carries it, without its headers,
# in Contents/Frameworks.
WEBRTC_VERSION := 154.0.0
WEBRTC_ZIP     := WebRTC-M154.xcframework.zip
WEBRTC_SHA256  := a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16
WEBRTC         := vendor/WebRTC.framework
WEBRTC_STAMP   := vendor/.webrtc-$(WEBRTC_VERSION)
$(WEBRTC_STAMP): mk/fetch-webrtc.sh
	@rm -f vendor/.webrtc-*
	@mk/fetch-webrtc.sh $(WEBRTC_VERSION) $(WEBRTC_ZIP) $(WEBRTC_SHA256) $(WEBRTC) && touch $@
$(BUILD)/WebRTC.framework: $(WEBRTC_STAMP)
	@rm -rf $@ && ditto $(WEBRTC) $@
	@cd $@ && rm -rf Headers Modules Versions/A/Headers Versions/A/Modules

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

# App icon: the Icon Composer document compiled into Assets.car (Liquid Glass icon) and AppIcon.icns (fallback). Xcode
# 26's actool can't read what Xcode 27 writes in it, so on 26 the document is rewritten first (mk/downgrade-icon.py).
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
$(ICON_DOC)/icon.json: $(ICON_SRC)/icon.json $(ICON_ASSETS) mk/downgrade-icon.py
	@rm -rf $(ICON_DOC) && mkdir -p $(ICON_DOC) && cp -R $(ICON_SRC)/Assets $(ICON_DOC)/
	@python3 mk/downgrade-icon.py $< $@
	@echo "downgraded AppIcon.icon for Xcode $(XCODE_MAJOR)"
endif
$(ICON)/Assets.car: $(ICON_INPUTS)
	@mkdir -p $(ICON)
	xcrun actool $(ICON_DOC) --compile $(ICON) --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
	  --output-partial-info-plist $(ICON)/partial.plist >/dev/null

# SimRun.app: the server/launcher executable, the simrun helper, simns, the sim-side libraries, the agent skill, the
# remote-control page and WebRTC.framework (mk/bundle.sh assembles and signs it). Made again only when one of those
# changed: the bundle's time is when it was last made.
APP := $(BUILD)/SimRun.app
SKILL_FILES := $(shell find skills -type f ! -name .DS_Store)
$(APP): resources/Info.plist resources/remote.html $(ICON)/Assets.car $(BIN)/simrund $(BIN)/simrun $(BIN)/simns $(SIMLIBS) \
        $(WATCHLIBS) $(SKILL_FILES) $(BUILD)/WebRTC.framework mk/bundle.sh
	@SIGN="$(SIGN)" mk/bundle.sh $@ \
	  Contents/Info.plist=resources/Info.plist \
	  Contents/MacOS/SimRun=$(BIN)/simrund \
	  Contents/Helpers/=$(BIN)/simrun \
	  $(foreach f,$(ICON)/Assets.car $(ICON)/AppIcon.icns resources/remote.html skills,Contents/Resources/=$(f)) \
	  $(foreach f,$(BIN)/simns $(SIMLIBS),Contents/Resources/lib/=$(f)) \
	  $(foreach f,$(WATCHLIBS),Contents/Resources/lib/watchos/=$(f)) \
	  Contents/Frameworks/=$(BUILD)/WebRTC.framework
	@touch $@
	@echo "built $@"

# simrun: the command line, a client of the server's socket (include/simrund_proto.h)
SIMRUN_OBJ := $(call mac_objs,src/host/simrun/simrun.m)
$(OBJ)/mac/src/host/simrun/%.o: CFLAGS += -Wall
$(BIN)/simrun: $(SIMRUN_OBJ) | $(BIN)
	$(MAC_LINK) $^ -framework Foundation -o $@

OBJS += $(SIMRUND_OBJ) $(SIMRUN_OBJ)

