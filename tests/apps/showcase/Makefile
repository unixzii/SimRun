# Showcase: a SwiftUI tour of what works under SimRun — the iPhone app (*.swift) and its Watch app (Watch/), which share
# WatchConnectivity code (Shared/) and the Icon Composer icon. Each half is compiled for its own Simulator, the Watch app
# is put in the iPhone app's Watch/ folder as Xcode embeds it, and both are signed, the Watch app first.
#   make test-apps (from the top)                         builds this too
#   make -C tests/apps/showcase                           build/apps/Showcase.app
#   make -C tests/apps/showcase clean

BUILD ?= ../../../build
APPS  ?= $(BUILD)/apps
OBJ   := $(BUILD)/showcase

PHONE := $(APPS)/Showcase.app
WATCH := $(OBJ)/ShowcaseWatch.app

SHARED_SRC := $(wildcard Shared/*.swift)
PHONE_SRC  := $(wildcard *.swift) $(SHARED_SRC)
WATCH_SRC  := $(wildcard Watch/*.swift) $(SHARED_SRC)
ICON       := AppIcon.icon/icon.json $(wildcard AppIcon.icon/Assets/*)

PHONE_SWIFT := xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -parse-as-library -O
WATCH_SWIFT := xcrun -sdk watchsimulator swiftc -target arm64-apple-watchos10.0-simulator -parse-as-library -O
SIGN        := codesign -s - -f

.PHONY: all clean
all: $(PHONE)
	@:

$(OBJ)/phone $(OBJ)/watch:
	@mkdir -p $@

# Executables
$(OBJ)/phone/Showcase: $(PHONE_SRC) | $(OBJ)/phone
	$(PHONE_SWIFT) $(PHONE_SRC) -o $@
$(OBJ)/watch/ShowcaseWatch: $(WATCH_SRC) | $(OBJ)/watch
	$(WATCH_SWIFT) $(WATCH_SRC) -o $@

# The icon, compiled for each platform: Assets.car (and the iPhone's fallback PNGs) into <half>/icon/
$(OBJ)/phone/icon/Assets.car: $(ICON) | $(OBJ)/phone
	@rm -rf $(@D) && mkdir -p $(@D)
	xcrun actool AppIcon.icon --compile $(@D) --platform iphonesimulator --minimum-deployment-target 26.0 \
	  --app-icon AppIcon --output-partial-info-plist $(OBJ)/phone/icon.plist >/dev/null
$(OBJ)/watch/icon/Assets.car: $(ICON) | $(OBJ)/watch
	@rm -rf $(@D) && mkdir -p $(@D)
	xcrun actool AppIcon.icon --compile $(@D) --platform watchsimulator --minimum-deployment-target 10.0 \
	  --app-icon AppIcon --output-partial-info-plist $(OBJ)/watch/icon.plist >/dev/null

# Bundles
$(WATCH): $(OBJ)/watch/ShowcaseWatch $(OBJ)/watch/icon/Assets.car Watch/Info.plist
	@rm -rf $@ && mkdir -p $@
	@cp Watch/Info.plist $(OBJ)/watch/ShowcaseWatch $@/ && cp $(OBJ)/watch/icon/* $@/
	@$(SIGN) $@ 2>/dev/null
$(PHONE): $(OBJ)/phone/Showcase $(OBJ)/phone/icon/Assets.car Info.plist $(WATCH)
	@rm -rf $@ && mkdir -p $@/Watch
	@cp Info.plist $(OBJ)/phone/Showcase $@/ && cp $(OBJ)/phone/icon/* $@/
	@cp -R $(WATCH) $@/Watch/
	@$(SIGN) $@ 2>/dev/null
	@echo "built $@"

clean:
	rm -rf $(OBJ) $(PHONE)
