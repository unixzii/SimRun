# mk/common.mk — what every fragment shares: the Xcode to build with, where products go, the toolchains and signing.

# The iOS Simulator SDK comes with Xcode: when xcode-select points at the Command Line Tools, use an installed Xcode.
ifeq ($(origin DEVELOPER_DIR),undefined)
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
XCODE_APP := $(firstword $(wildcard /Applications/Xcode.app) $(shell mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | grep -v ' '))
ifneq ($(XCODE_APP),)
export DEVELOPER_DIR := $(XCODE_APP)/Contents/Developer
endif
endif
endif

BUILD   := build
BIN     := $(BUILD)/bin
LIB     := $(BUILD)/lib
APPS    := $(BUILD)/apps
TBIN    := $(BUILD)/tests

OBJ     := $(BUILD)/obj
GEN     := $(BUILD)/gen

SIM_CLANG := xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0
MAC_CLANG := xcrun -sdk macosx clang -arch arm64
SIMCC   := $(SIM_CLANG) -fobjc-arc -Wno-deprecated-declarations -Iinclude
SIMSWIFT:= xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator
MACCC   := $(MAC_CLANG) -fobjc-arc -Wno-deprecated-declarations -Iinclude
MACSWIFT:= env -u DYLD_ROOT_PATH xcrun -sdk macosx swiftc -O
SIGN    := codesign -s - -f

# Compiling: each source into its own object, $(OBJ)/sim/<its path>.o for the Simulator and $(OBJ)/mac/<its path>.o for
# the Mac, with the headers it read noted next to it (.d, from -MMD), so a change recompiles only the objects it touches.
# A part adds its folder's flags to these, by object path:
#   $(OBJ)/sim/src/sim/shims/app/%.o: CPPFLAGS += -Isrc/sim/shims/app
# and its objects to OBJS, whose .d files the Makefile includes. Products link their objects with *_LINK.
CPPFLAGS  := -Iinclude
CFLAGS    := -Wno-deprecated-declarations
OBJCFLAGS := -fobjc-arc
DEPFLAGS  := -MMD -MP
SIM_LINK  := $(SIM_CLANG) $(OBJCFLAGS)
MAC_LINK  := $(MAC_CLANG) $(OBJCFLAGS)
sim_objs = $(patsubst %,$(OBJ)/sim/%.o,$(basename $(1)))
mac_objs = $(patsubst %,$(OBJ)/mac/%.o,$(basename $(1)))

$(OBJ)/sim/%.o: %.m
	@mkdir -p $(@D)
	$(SIM_CLANG) $(OBJCFLAGS) $(CFLAGS) $(CPPFLAGS) $(DEPFLAGS) -c $< -o $@
$(OBJ)/sim/%.o: %.c
	@mkdir -p $(@D)
	$(SIM_CLANG) $(CFLAGS) $(CPPFLAGS) $(DEPFLAGS) -c $< -o $@
$(OBJ)/mac/%.o: %.m
	@mkdir -p $(@D)
	$(MAC_CLANG) $(OBJCFLAGS) $(CFLAGS) $(CPPFLAGS) $(DEPFLAGS) -c $< -o $@

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@
