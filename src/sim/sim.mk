# src/sim/sim.mk — the sim side: what SimRun puts in Simulator processes, built for the iOS Simulator into build/bin and
# build/lib, and again marked for the watchOS Simulator into build/lib/watchos.
#
# src/sim: one folder per build target, named after it (simfb builds SimFramebuffer); shims/ groups the dylibs that are
# inserted into sim processes, its folders following the same rule. common/ is no target: what the sim libraries share
# (common.h), compiled once and linked into each one that uses it.
SIM   := src/sim
SHIMS := $(SIM)/shims
SIMLIBS := $(LIB)/xpcservices.dylib $(LIB)/app.dylib $(LIB)/SimFramebuffer $(LIB)/simpair $(LIB)/wcd.dylib $(LIB)/containermanagerd.dylib
WATCHLIB  := $(LIB)/watchos
WATCHLIBS := $(WATCHLIB)/simns $(patsubst $(LIB)/%,$(WATCHLIB)/%,$(SIMLIBS))

COMMON_OBJ := $(call sim_objs,$(SIM)/common/common.m)
$(OBJ)/sim/$(SIM)/common/%.o $(OBJ)/sim/$(SHIMS)/xpcservices/%.o: CPPFLAGS += -I$(SIM)/common

# simns: the launchd_sim stand-in (docs/simns.md), run by SimRun as `simns --serve`
SIMNS_OBJ := $(call sim_objs,$(SIM)/simns/simns.c)
$(OBJ)/sim/$(SIM)/simns/%.o: CFLAGS += -Wall
$(BIN)/simns: $(SIMNS_OBJ) | $(BIN)
	$(SIM_CLANG) $^ -framework CoreFoundation -o $@
	@$(SIGN) $@ 2>/dev/null

# simpair: pairs the iPhone and the Apple Watch (docs/pairing.md); its entitlement goes in __TEXT,__entitlements,
# where a sim process's entitlements are read from
SIMPAIR_OBJ := $(call sim_objs,$(SIM)/simpair/simpair.m)
$(LIB)/simpair: $(SIMPAIR_OBJ) $(SIM)/simpair/Entitlements.plist | $(LIB)
	$(SIM_LINK) $(SIMPAIR_OBJ) -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,$(SIM)/simpair/Entitlements.plist -o $@
	@$(SIGN) $@ 2>/dev/null

# SimFramebuffer: the fake SimFramebuffer.framework (SIMULATOR_FRAMEBUFFER_FRAMEWORK)
SIMFB_OBJ := $(call sim_objs,$(SIM)/simfb/simfb.m)
$(LIB)/SimFramebuffer: $(SIMFB_OBJ) | $(LIB)
	$(SIM_LINK) -dynamiclib $^ -framework Foundation -framework IOSurface -framework CoreFoundation -framework CoreGraphics -framework Metal \
	  -install_name @rpath/SimFramebuffer.framework/SimFramebuffer -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/xpcservices: xpcservices.dylib, in the app and every helper it spawns, so Foundation only
XPCSERVICES_OBJ := $(call sim_objs,$(SHIMS)/xpcservices/xpcservices.m)
$(LIB)/xpcservices.dylib: $(XPCSERVICES_OBJ) $(COMMON_OBJ) | $(LIB)
	$(SIM_LINK) -dynamiclib $^ -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/app: app.dylib, the modules SimRun puts in the app (app.h), one folder each, which include each other's headers
# by folder ("hid/hid.h"); script/'s JS modules (js/*.js) are embedded as C arrays (xxd -i: core.js -> core_js[]).
# TCC.framework is linked through a stub (tcc/tcc.tbd; not in the SDK); the other private frameworks' symbols
# (FrontBoardServices, GraphicsServices, BackBoardServices...) are looked up at load.
APP_DIR := $(SHIMS)/app
APP_MODULES := locale container watch render scenes hid textinput pboard drag docpicker keychain webkit mps script tcc audio motion
APP_OBJ := $(call sim_objs,$(APP_DIR)/app.m $(foreach m,$(APP_MODULES),$(wildcard $(APP_DIR)/$(m)/*.m)))
$(OBJ)/sim/$(APP_DIR)/%.o: CPPFLAGS += -I$(SIM)/common -I$(APP_DIR) -I$(GEN)
$(GEN)/script_js.h: $(wildcard $(APP_DIR)/script/js/*.js)
	@mkdir -p $(@D)
	@(cd $(APP_DIR)/script/js && for f in *.js; do xxd -i $$f; done) > $@.tmp && mv $@.tmp $@
$(OBJ)/sim/$(APP_DIR)/script/context.o: $(GEN)/script_js.h
$(LIB)/app.dylib: $(APP_OBJ) $(COMMON_OBJ) $(APP_DIR)/tcc/tcc.tbd | $(LIB)
	$(SIM_LINK) -dynamiclib $^ -framework Foundation \
	  -framework UIKit -framework QuartzCore -framework CoreGraphics -framework IOKit -framework UniformTypeIdentifiers \
	  -framework Security -framework Metal -framework AudioToolbox -framework CoreAudio \
	  -Wl,-undefined,dynamic_lookup -Wl,-w -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/wcd: wcd.dylib, in wcd, the WatchConnectivity daemon (SIMNS_DAEMON_INSERT), what it would ask LaunchServices,
# AppConduit and Carousel
WCD_OBJ := $(call sim_objs,$(SHIMS)/wcd/wcd.m)
$(LIB)/wcd.dylib: $(WCD_OBJ) | $(LIB)
	$(SIM_LINK) -dynamiclib $^ -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

# shims/containermanagerd: containermanagerd.dylib, in containermanagerd (SIMNS_DAEMON_INSERT), which would delete
# apps' data containers as orphans when it starts
CONTAINERMANAGERD_OBJ := $(call sim_objs,$(SHIMS)/containermanagerd/containermanagerd.m)
$(LIB)/containermanagerd.dylib: $(CONTAINERMANAGERD_OBJ) | $(LIB)
	$(SIM_LINK) -dynamiclib $^ -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

OBJS += $(COMMON_OBJ) $(SIMNS_OBJ) $(SIMPAIR_OBJ) $(SIMFB_OBJ) $(XPCSERVICES_OBJ) $(APP_OBJ) $(WCD_OBJ) $(CONTAINERMANAGERD_OBJ)

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
$(WATCHLIB):
	@mkdir -p $@
$(WATCHLIB)/simns: $(BIN)/simns | $(WATCHLIB)
	$(watchos_copy)
$(WATCHLIB)/%: $(LIB)/% | $(WATCHLIB)
	$(watchos_copy)
