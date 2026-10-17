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

SIMCC   := xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations -Iinclude
SIMSWIFT:= xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator
MACCC   := xcrun -sdk macosx clang -arch arm64 -fobjc-arc -Wno-deprecated-declarations -Iinclude
MACSWIFT:= env -u DYLD_ROOT_PATH xcrun -sdk macosx swiftc -O
SIGN    := codesign -s - -f
HDRS    := $(wildcard include/*.h)

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@
