# tools/tools.mk — tools for working on SimRun (not part of SimRun.app).

TOOLS := $(BIN)/hostinput
$(BIN)/hostinput: tools/hostinput.swift | $(BIN)
	$(MACSWIFT) $< -o $@
