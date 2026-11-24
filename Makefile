LUA ?= luajit
STABLE_TL ?= $(LUA) ./tl
NEW_TL ?= env TL_PATH="./?.tl;./?/init.tl;./?.d.tl" $(LUA) extras/dev-tl.lua
TLGENFLAGS = --check --gen-target=5.1
BUSTED_CMD ?= busted
BUSTED = $(BUSTED_CMD) --suppress-pending
STRIPDIR = _temp/strip
STRICT_NIL_PRAGMA = --\#pragma strict_nil off
PACKAGE_PATH := $(shell $(LUA) -e 'print(package.path)')
STRICT_NIL_SUPPORTED := $(shell printf '%s\n' '$(STRICT_NIL_PRAGMA)' 'local x: integer = nil' | $(STABLE_TL) check - >/dev/null 2>&1 && echo yes)
STRIP_STRICT_NIL := $(if $(STRICT_NIL_SUPPORTED),0,1)
STRIP_TL_PATH = $(STRIPDIR)/?.tl;$(STRIPDIR)/?/init.tl;$(STRIPDIR)/?.d.tl;./?.tl;./?/init.tl;./?.d.tl;$(PACKAGE_PATH)
STRIPPED_SOURCES = $(addprefix $(STRIPDIR)/,$(SOURCES))

PRECOMPILED = teal/precompiled/default_env.lua
SOURCES = teal/debug.tl teal/attributes.tl teal/errors.tl teal/lexer.tl \
	teal/reader.tl teal/block.tl \
	teal/util.tl teal/types.tl teal/facts.tl teal/ast.tl teal/parser.tl teal/traversal.tl \
	teal/variables.tl teal/type_reporter.tl \
	teal/macroexps.tl teal/macro_eval.tl teal/metamethods.tl \
	teal/type_errors.tl teal/environment.tl \
	teal/check/context.tl teal/check/visitors.tl teal/check/check.tl \
	teal/check/relations.tl teal/check/special_functions.tl \
	teal/check/type_checker.tl teal/check/node_checker.tl \
	teal/input.tl \
	teal/check/require_file.tl \
	teal/gen/targets.tl teal/gen/lua_generator.tl teal/gen/lua_compat.tl teal/gen/c_bootstrap.tl \
	teal/gen/c_ffi.tl teal/gen/c_generator.tl teal/gen/c_types.tl teal/gen/c_runtime.tl teal/gen/lua_ffi.tl \
	teal/package_loader.tl teal/loader.tl \
	teal/api/v2.tl teal/api/v1.tl \
	teal/init.tl \
	tl.tl \
	tlcli/configuration.tl \
	tlcli/report.tl \
	tlcli/driver.tl \
	tlcli/main.tl \
	tlcli/pack_native.tl \
	tlcli/commands/lsp.tl \
	tlcli/commands/run.tl \
	tlcli/commands/pack.tl \
	tlcli/commands/warnings.tl \
	tlcli/commands/dump_blocks.tl \
	tlcli/commands/types.tl \
	tlcli/commands/check.tl \
	tlcli/commands/gen.tl \
	tlcli/common.tl

all: selfbuild suite

########################################
# Multi-stage bootstrap process:
########################################

$(STRIPDIR)/%.tl: %.tl FORCE
	@mkdir -p `dirname $@`
	@if [ "$(STRIP_STRICT_NIL)" = "1" ]; then \
		sed 's/^[[:space:]]*$(STRICT_NIL_PRAGMA)[[:space:]]*$$//' $< > $@; \
	else \
		cp $< $@; \
	fi

FORCE:

strip_sources: $(STRIPPED_SOURCES) $(STRIPDIR)/precompiler.tl

precompiler.lua: strip_sources $(STRIPDIR)/precompiler.tl
	TL_PATH="$(STRIP_TL_PATH)" $(STABLE_TL) gen $(STRIPDIR)/precompiler.tl -o $@ || { rm $@; exit 1; }

teal/precompiled/default_env.lua: precompiler.lua teal/default/prelude.d.tl teal/default/stdlib.d.tl tl.tl
	$(LUA) precompiler.lua > teal/precompiled/default_env.lua || { rm $@; exit 1; }

_temp/%.lua.1: %.tl $(PRECOMPILED) $(STRIPDIR)/%.tl
	@mkdir -p `dirname $@`
	@echo $(STRIPDIR)/$< >> _temp/list1
	@echo $@ >> _temp/list1.1
	@touch $@

_temp/%.lua.2: replace1 %.tl _temp/%.lua.1 $(PRECOMPILED) FORCE
	@mkdir -p `dirname $@`
	@echo $*.tl >> _temp/list2
	@touch $@

build1: newlist $(addprefix _temp/,$(addsuffix .lua.1,$(basename $(SOURCES))))
	if [ -e _temp/list1 ]; \
	then TL_PATH="$(STRIP_TL_PATH)" $(STABLE_TL) gen $(TLGENFLAGS) --root $(STRIPDIR) --custom-ext .lua.1 --output-dir _temp `cat _temp/list1` || { rm `cat _temp/list1.1`; exit 1; };\
	fi

replace1: build1
	extras/make.sh move_1_to_lua
	@rm -f _temp/list2

build2: $(addprefix _temp/,$(addsuffix .lua.2,$(basename $(SOURCES))))
	if [ -e _temp/list2 ]; \
	then $(NEW_TL) gen $(TLGENFLAGS) --root . --custom-ext .lua.2 --output-dir _temp `cat _temp/list2` || extras/make.sh revert; \
	fi

newlist:
	@mkdir -p _temp/
	@rm -f _temp/list1
	@rm -f _temp/list1.1
	@rm -f _temp/list1.2

selfbuild: combine
	extras/make.sh diff_1_and_2 || extras/make.sh revert

########################################
# Test suite:
########################################

suite:
	@if command -v $(BUSTED_CMD) >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory suite-strict; \
	else \
		echo "Busted not found; self-build succeeded, skipping tests (use 'make suite-strict' to require them)."; \
	fi

suite-strict:
	${BUSTED} -v $(TESTFLAGS) spec/lang extras/auxlib/tests
	${BUSTED} -v $(TESTFLAGS) spec/api
	${BUSTED} -v $(TESTFLAGS) spec/cli

########################################
# Utility targets:
########################################

bin:
	$(MAKE) STABLE_TL=_binary/build/tl

binary:
	extras/binary.sh --clean

combine: build2
	$(NEW_TL) run extras/combine.tl teal.api.v2 tl.lua
	$(NEW_TL) run extras/combine.tl teal.init teal.lua

revert:
	git checkout $(PRECOMPILED) $(addsuffix .lua,$(basename $(SOURCES)))

cov:
	rm -f luacov.stats.out luacov.report.out
	${BUSTED} -c
	luacov tl.lua
	cat luacov.report.out

cleantemp:
	rm -rf _temp

clean: cleantemp
# force a recompile of the environment
	rm precompiler.lua

########################################
# Makefile administrivia
########################################

.PHONY: all build1 replace1 build2 selfbuild suite suite-strict \
	suite bin binary cov revert cov cleantemp clean strip_sources FORCE

# Run the compiler fuzzer and its worker with LuaJIT.
FUZZ_LUA ?= luajit
FUZZFLAGS ?=
FUZZ_SOURCES = extras/fuzz/model.tl extras/fuzz/json.tl extras/fuzz/hash.tl \
	extras/fuzz/system.tl extras/fuzz/generator.tl extras/fuzz/runner.tl \
	extras/fuzz/worker.tl extras/fuzz/fuzz.tl extras/fuzz/test_fuzz.tl

fuzz:
	$(FUZZ_LUA) extras/fuzz/fuzz.lua --lua $(LUA) $(FUZZFLAGS)

fuzz-smoke:
	$(FUZZ_LUA) extras/fuzz/fuzz.lua --lua $(LUA) --cases 32 --stop-on-failure $(FUZZFLAGS)

fuzz-test:
	$(FUZZ_LUA) extras/fuzz/test_fuzz.lua

fuzz-check:
	$(STABLE_TL) check $(FUZZ_SOURCES)

fuzz-build: fuzz-check
	$(STABLE_TL) gen --root . --output-dir . --gen-target=5.1 --gen-compat=off $(FUZZ_SOURCES)

.PHONY: fuzz fuzz-smoke fuzz-test fuzz-check fuzz-build

# Build the compiler and CLI as native C.
C_BUILD_DIR ?= _temp/selfbuild-c
C_LUAJIT_CFLAGS ?= $(shell pkg-config --cflags luajit)
C_LUAJIT_LIBS ?= $(shell pkg-config --variable=libdir luajit)/libluajit-5.1.a -ldl
C_BOOTSTRAP_CFLAGS ?= -O2
C_TEAL ?= $(STABLE_TL)
C_EMITTER ?= $(C_TEAL) run --gen-target=5.1 extras/c/generate.tl
C_ARGPARSE ?= $(shell $(LUA) -e 'local m=require("argparse"); print(debug.getinfo(getmetatable(m).__call,"S").source:sub(2))')
C_ENTRY = extras/c/entry.tl
C_DRIVER = extras/c/generate.tl
C_RUNTIME = main values library strings system lua_bridge
C_TL_PATH = ./?.lua;./?/init.lua;$(PACKAGE_PATH)
C_MODULES = $(SOURCES) $(C_DRIVER) $(PRECOMPILED)
C_UNITS = register tl_entry tl_module_argparse $(foreach src,$(C_MODULES),tl_module_$(subst /,_,$(basename $(src))))
C_OBJECTS = $(addprefix $(C_BUILD_DIR)/obj/,$(addsuffix .o,$(C_UNITS) $(addprefix runtime_,$(C_RUNTIME))))
C_COMPILE = $(CC) $(CPPFLAGS) $(C_BOOTSTRAP_CFLAGS) $(CFLAGS) -std=c11 -I extras/c

selfbuild-c:
	mkdir -p "$(C_BUILD_DIR)/lua" "$(C_BUILD_DIR)/c"
	TL_PATH="$(C_TL_PATH)" $(C_TEAL) gen --gen-target=5.1 --root . --output-dir "$(C_BUILD_DIR)/lua" $(SOURCES) $(C_ENTRY) $(C_DRIVER)
	LUA_PATH="$(C_BUILD_DIR)/lua/?.lua;$(C_BUILD_DIR)/lua/?/init.lua;$(PACKAGE_PATH)" TL_PATH="$(C_TL_PATH)" $(C_EMITTER) "$(C_BUILD_DIR)/c" "$(C_BUILD_DIR)/lua" "$(C_ARGPARSE)" $(C_ENTRY) $(C_MODULES)
	$(MAKE) link-selfbuild-c
	"$(C_BUILD_DIR)/tl" --version

$(C_BUILD_DIR)/obj/%.o: $(C_BUILD_DIR)/c/%.c extras/c/tl_runtime.h
	@mkdir -p "$(@D)"
	$(C_COMPILE) -c "$<" -o "$@"

$(C_BUILD_DIR)/obj/tl_module_teal_precompiled_default_env.o: $(C_BUILD_DIR)/c/tl_module_teal_precompiled_default_env.c extras/c/tl_runtime.h
	@mkdir -p "$(@D)"
	$(C_COMPILE) -O0 -c "$<" -o "$@"

$(C_BUILD_DIR)/obj/runtime_%.o: extras/c/%.c extras/c/tl_runtime.h
	@mkdir -p "$(@D)"
	$(C_COMPILE) -c "$<" -o "$@"

$(C_BUILD_DIR)/obj/runtime_lua_bridge.o: extras/c/lua_bridge.c extras/c/tl_runtime.h
	@mkdir -p "$(@D)"
	$(C_COMPILE) $(C_LUAJIT_CFLAGS) -c "$<" -o "$@"

link-selfbuild-c: $(C_OBJECTS)
	$(CC) $(C_OBJECTS) $(LDFLAGS) $(C_LUAJIT_LIBS) -lm -o "$(C_BUILD_DIR)/tl"

verify-selfbuild-c: selfbuild-c
	$(MAKE) selfbuild-c C_TEAL="$(C_BUILD_DIR)/tl" C_EMITTER="$(C_BUILD_DIR)/tl --emit-bootstrap-c" C_BUILD_DIR="$(C_BUILD_DIR)-stage2"
	diff -r "$(C_BUILD_DIR)/c" "$(C_BUILD_DIR)-stage2/c"
	$(SHELL) extras/c/selftest.sh "$(abspath $(C_BUILD_DIR)-stage2/tl)" $(CC)

.PHONY: selfbuild-c link-selfbuild-c verify-selfbuild-c
