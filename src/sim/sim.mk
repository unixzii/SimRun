# src/sim/sim.mk — the sim side: what SimRun puts in Simulator processes, built for the iOS Simulator into build/bin and
# build/lib, and again marked for the watchOS Simulator into build/lib/watchos.

# src/sim: one folder per build target, named after it (simfb builds SimFramebuffer); shims/ groups the dylibs that are
# inserted into sim processes, its folders following the same rule. common/ is no target: what the sim libraries share
# (common.h), compiled into each one that uses it.
SIM := src/sim
SHIMS := $(SIM)/shims
COMMON := $(SIM)/common/common.m
COMMON_DEPS := $(COMMON) $(wildcard $(SIM)/common/*.h)
SIMLIB := $(SIMCC) -I$(SIM)/common

# simns: the launchd_sim stand-in (docs/simns.md), run by SimRun as `simns --serve`
$(BIN)/simns: $(SIM)/simns/simns.c $(HDRS) | $(BIN)
	xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -Wall -Wno-deprecated-declarations -Iinclude $< -framework CoreFoundation -o $@
	@$(SIGN) $@ 2>/dev/null

# simpair: pairs the iPhone and the Apple Watch (docs/pairing.md); its entitlement goes in __TEXT,__entitlements,
# where a sim process's entitlements are read from
$(LIB)/simpair: $(SIM)/simpair/simpair.m $(SIM)/simpair/Entitlements.plist | $(LIB)
	$(SIMCC) $< -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,$(SIM)/simpair/Entitlements.plist -o $@
	@$(SIGN) $@ 2>/dev/null

# SimFramebuffer: the fake SimFramebuffer.framework (SIMULATOR_FRAMEBUFFER_FRAMEWORK)
$(LIB)/SimFramebuffer: $(SIM)/simfb/simfb.m $(wildcard $(SIM)/simfb/*.h) $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework IOSurface -framework CoreFoundation -framework CoreGraphics -framework Metal \
	  -install_name @rpath/SimFramebuffer.framework/SimFramebuffer -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/xpcservices: xpcservices.dylib, in the app and every helper it spawns, so Foundation only
$(LIB)/xpcservices.dylib: $(SHIMS)/xpcservices/xpcservices.m $(COMMON_DEPS) $(HDRS) | $(LIB)
	$(SIMLIB) -dynamiclib $< $(COMMON) -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/app: app.dylib, the modules SimRun puts in the app (app.h), one folder each, which include each other's headers
# by folder ("hid/hid.h"); script/'s JS modules (js/*.js) are embedded as C arrays (xxd -i: core.js -> core_js[]).
# TCC.framework is linked through a stub (tcc/tcc.tbd; not in the SDK); the other private frameworks' symbols
# (FrontBoardServices, GraphicsServices, BackBoardServices...) are looked up at load.
APP_DIR := $(SHIMS)/app
APP_MODULES := locale container watch render scenes hid textinput pboard drag docpicker keychain webkit mps script tcc audio motion
APP_SRC := $(APP_DIR)/app.m $(foreach m,$(APP_MODULES),$(wildcard $(APP_DIR)/$(m)/*.m))
SCRIPT_JS := $(wildcard $(APP_DIR)/script/js/*.js)
$(BUILD)/gen/script_js.h: $(SCRIPT_JS)
	@mkdir -p $(@D)
	@(cd $(APP_DIR)/script/js && for f in *.js; do xxd -i $$f; done) > $@.tmp && mv $@.tmp $@
APP_HDRS := $(wildcard $(APP_DIR)/*.h) $(foreach m,$(APP_MODULES),$(wildcard $(APP_DIR)/$(m)/*.h))
$(LIB)/app.dylib: $(APP_SRC) $(APP_HDRS) $(APP_DIR)/tcc/tcc.tbd $(BUILD)/gen/script_js.h $(COMMON_DEPS) $(HDRS) | $(LIB)
	$(SIMLIB) -I$(APP_DIR) -I$(BUILD)/gen -dynamiclib $(APP_SRC) $(COMMON) $(APP_DIR)/tcc/tcc.tbd -framework Foundation \
	  -framework UIKit -framework QuartzCore -framework CoreGraphics -framework IOKit -framework UniformTypeIdentifiers \
	  -framework Security -framework Metal -framework AudioToolbox -framework CoreAudio \
	  -Wl,-undefined,dynamic_lookup -Wl,-w -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/wcd: wcd.dylib, in wcd, the WatchConnectivity daemon (SIMNS_DAEMON_INSERT), what it would ask LaunchServices,
# AppConduit and Carousel
$(LIB)/wcd.dylib: $(SHIMS)/wcd/wcd.m | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/containermanagerd: containermanagerd.dylib, in containermanagerd (SIMNS_DAEMON_INSERT), which would delete
# apps' data containers as orphans when it starts
$(LIB)/containermanagerd.dylib: $(SHIMS)/containermanagerd/containermanagerd.m | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

# watchOS: the same simns and libraries, marked for the watchOS Simulator (LC_BUILD_VERSION), which is all that tells
# them apart. dyld_sim skips an inserted library of another platform without a word, and the watchOS SDK can't build
# them (it has no IOSurface, and marks mach_msg, posix_spawn and UIKit unavailable); what they call exists in the
# watchOS runtime too. In the app, SRIsWatch() says which platform it is in.
WATCH_SDK := $(or $(shell xcrun -sdk watchsimulator --show-sdk-version 2>/dev/null),10.0)
define watchos_copy
	@cp $< $@.tmp && codesign --remove-signature $@.tmp
	xcrun vtool -set-build-version watchossim 10.0 $(WATCH_SDK) -replace -output $@ $@.tmp
	@rm $@.tmp && $(SIGN) $@ 2>/dev/null
endef
SIMLIBS := $(LIB)/xpcservices.dylib $(LIB)/app.dylib $(LIB)/SimFramebuffer $(LIB)/simpair $(LIB)/wcd.dylib $(LIB)/containermanagerd.dylib
WATCHLIB := $(LIB)/watchos
WATCHLIBS := $(WATCHLIB)/simns $(patsubst $(LIB)/%,$(WATCHLIB)/%,$(SIMLIBS))
$(WATCHLIB):
	@mkdir -p $@
$(WATCHLIB)/simns: $(BIN)/simns | $(WATCHLIB)
	$(watchos_copy)
$(WATCHLIB)/%: $(LIB)/% | $(WATCHLIB)
	$(watchos_copy)

