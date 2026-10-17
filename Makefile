# SimRun — build everything into build/. Each part's rules are in a fragment next to it (src/sim/sim.mk,
# src/host/host.mk, tools/tools.mk, tests/tests.mk), sharing mk/common.mk. They are one dependency graph, so a goal
# builds only what it needs, and -j works across all of it.
#   make                core components, tools and test programs
#   make core           SimRun.app (server + launcher, simns, injected xpcservices.dylib and app.dylib, fake
#                       SimFramebuffer, the same for watchOS) and the simrun CLI
#   make host           simrund and simrun (build/bin; simrund runs from there too)
#   make sim            the sim side, for the iOS and watchOS Simulators (build/bin/simns, build/lib)
#   make tools          tools for working on SimRun (build/bin)
#   make test-apps      sample/test apps (build/apps)
#   make test-programs  test programs (build/tests)
#   make tests          test apps and test programs
#   make install        install build/SimRun.app into /Applications
#   make clean

include mk/common.mk
include src/sim/sim.mk
include src/host/host.mk
include tools/tools.mk
include tests/tests.mk

.DEFAULT_GOAL := all
.PHONY: all core host sim tools test-apps test-programs tests install clean $(APP)
all: core tools test-programs
core: $(APP) $(BIN)/simrun
host: $(BIN)/simrund $(BIN)/simrun
sim: $(BIN)/simns $(SIMLIBS) $(WATCHLIBS)
tools: $(TOOLS)
test-apps: $(TEST_APPS)
test-programs: $(TEST_PROGS)
tests: test-apps test-programs

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
